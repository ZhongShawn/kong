local floor = math.floor
local math_random = math.random
local ngx_now = ngx.now
local to_hex = require "resty.string".to_hex
local atoi = require "resty.string".atoi
local random_bytes = require "resty.random".bytes
local new_tab = require "table.new"
local insert = table.insert
local pack = table.pack
local unpack = table.unpack
local ffi = require "ffi"
local C = ffi.C


ffi.cdef[[
    typedef long time_t;
    typedef int clockid_t;

    typedef struct timespec {
            time_t   tv_sec;        /* seconds */
            long     tv_nsec;       /* nanoseconds */
    } nanotime;
    int clock_gettime(clockid_t clk_id, struct timespec *tp);
]]


local function ffi_clock_gettime()
  local pnano = assert(ffi.new("nanotime[?]", 1))
  -- CLOCK_REALTIME -> 0
  C.clock_gettime(0, pnano)
  return pnano[0]
end


local function ffi_time_unix_nano()
  local t = ffi_clock_gettime()
  return tonumber(t.tv_sec) * 1000000000 + tonumber(t.tv_nsec)
end


-- 16 bytes array identifier. All zeroes forbidden
local function generate_trace_id()
  return random_bytes(16)
end


-- 8 bytes array identifier. All zeroes forbidden
local function generate_span_id()
  return random_bytes(8)
end


-- adds `count` number of zeros to the left of the str
local function left_pad_zero(str, count)
  return ('0'):rep(count-#str) .. str
end


local NOOP = "noop"
local FLAG_SAMPLED = 0x0000001


-- SpanKind is the type of span. Can be used to specify additional relationships between spans
-- in addition to a parent/child relationship.
local SPAN_KIND_UNSPECIFIED = 0
local SPAN_KIND_INTERNAL = 1
local SPAN_KIND_SERVER = 2
local SPAN_KIND_CLIENT = 3
local SPAN_KIND_PRODUCER = 4
local SPAN_KIND_CONSUMER = 5


local span_kind_tab
do
  local tab = new_tab(0, 5)
  insert(tab, SPAN_KIND_UNSPECIFIED)
  insert(tab, SPAN_KIND_INTERNAL)
  insert(tab, SPAN_KIND_SERVER)
  insert(tab, SPAN_KIND_CLIENT)
  insert(tab, SPAN_KIND_PRODUCER)
  insert(tab, SPAN_KIND_CONSUMER)
  
  span_kind_tab = tab
end


-- Build-in simple sampler
local function ratio_based_should_sample(sample_ratio)
  return math_random() < sample_ratio
end


local function get_tracing_ctx(ctx)
  if not ctx then
    ctx = ngx.ctx
  end

  if not ctx.tracing then
    ctx.tracing = new_tab(2, 0) -- narr
    ctx.tracing.spans = new_tab(0, 5) -- nrec
  end

  return ctx.tracing
end


-- Extract span from ctx
local function extract_span_from_ctx(ctx)
  local tracing_ctx = get_tracing_ctx(ctx)

  if tracing_ctx.current_span == nil or
     (tracing_ctx.current_span and tracing_ctx.current_span.is_recording == false)
  then
    return tracing_ctx.current_span
  end

  return nil
end


local span_mt = {}
span_mt.__index = span_mt


-- create a new span
-- * kind, start_time_unix_nano are optional
local function new_span(tracer, ctx, name, kind, start_time_unix_nano)
  assert(tracer ~= nil, "invalid tracer")

  if ctx ~= nil then
    assert(type(ctx) == "table", "invalid ctx")
  end

  assert(type(name) == "string" and name ~= "", "invalid span name")
  
  if kind ~= nil then
    assert(span_kind_tab[kind] ~= nil, "invalid span kind")
  end

  -- check start_time_unix_nano if sepecfiec
  if start_time_unix_nano ~= nil then
    assert(type(start_time_unix_nano) == "number" and start_time_unix_nano >= 0,
    "invalid span start_timestamp")
  else
    start_time_unix_nano = ffi_time_unix_nano()
  end

  local parent_span = extract_span_from_ctx(ctx)

  local span = setmetatable({
    tracer = tracer, -- ref
    trace_id = parent_span and parent_span.trace_id or generate_trace_id(),
    span_id = generate_span_id(),
    -- TODO: trace_state
    parent_span_id = parent_span and parent_span.span_id or nil,
    name = name,
    kind = kind,
    start_time_unix_nano = start_time_unix_nano,
    is_recording = true, -- recording span if not sampeld
  }, span_mt)

  local tracing_ctx = get_tracing_ctx(ctx)
  -- XXX: current_span as index (?)
  if tracing_ctx.current_span == nil or 
    (tracing_ctx.current_span ~= nil and tracing_ctx.current_span.is_recording == false)
  then
    tracing_ctx.current_span = span    
  end

  -- store spans
  tracing_ctx.spans[#tracing_ctx.spans + 1] = span

  return span
end


-- Ends a Span
function span_mt:finish(end_time_unix_nano)
  assert(self.end_time_unix_nano == nil, "span already ended")
  if end_time_unix_nano ~= nil then
    assert(type(end_time_unix_nano) == "number" and end_time_unix_nano >= 0,
    "invalid span finish timestamp")
    assert(end_time_unix_nano - self.start_time_unix_nano >= 0, "invalid span duration")
  else
    end_time_unix_nano = ffi_time_unix_nano()
  end
  self.end_time_unix_nano = end_time_unix_nano
  self.is_recording = false
  
  return true
end


-- Set an attribute to a Span
function span_mt:set_attribute(key, value)
  assert(type(key) == "string", "invalid key type")
  assert(type(value) ~= "table", "invalid value type")

  if self.attributes == nil then
    self.attributes = new_tab(0, 1)
  end

  self.attributes[key] = value

  return true
end


-- Adds an event to a Span
function span_mt:add_event(name, time_unix_nano)
  assert(type(name) == "string", "invalid name type")
  
  if time_unix_nano ~= nil then
    assert(type(time_unix_nano) ~= "number" and time_unix_nano >= 0, "invalid timestamp")    
  else
    time_unix_nano = ffi_time_unix_nano()
  end

  if self.events == nil then
    self.events = new_tab(1, 0)
  end

  insert(self.events, {
    name = name,
    time_unix_nano = time_unix_nano,
  })

  return true
end


local tracer_mt = {}
tracer_mt.__index = tracer_mt


-- Creates a new child Span or root Span
function tracer_mt:start_span(...)
  return new_span(self, ...)
end


local _empty_tab = {}


-- get spans from context
function tracer_mt:spans_from_ctx(ctx)
  return get_tracing_ctx(ctx).spans or _empty_tab
end


-- get current running span (usually parent span)
function tracer_mt:get_current_span(ctx)
  local tracing_ctx = get_tracing_ctx(ctx)
  return tracing_ctx.current_span
end


-- Create new Tracer instance
-- TODO namespace scope
local function new_tracer(name, config)
  return setmetatable({ 
    noop = name == NOOP,
    config = config,
  }, tracer_mt)
end

tracer_mt.new = new_tracer


-- kong.db connector overwrite
local function connector_query_wrap(connector)
  local query_orig = connector.query

  local function query(self, sql, ...)

    local span = kong.tracer:start_span(ngx.ctx, "query")
    span:set_attribute("query", sql) -- TODO: skip noop span

    local r = pack(query_orig(self, sql, ...))

    span:finish()

    return unpack(r)
  end

  connector.query = query
end


-- router wrapper
local function wrap_router(router)
  local exec_orig = router.exec

  local function exec(ngx)
    local span = kong.tracer:start_span(ngx.ctx, "router")
    local r = pack(exec_orig(ngx))

    span:finish()

    return unpack(r)
  end

  router.exec = exec
end

return {
  new = function()
    return new_tracer("noop") -- create noop global tracer by default
  end,
  -- helpers
  connector_query_wrap = connector_query_wrap,
  wrap_router = wrap_router,
}

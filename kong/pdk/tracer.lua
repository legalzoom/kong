---
-- Tracer module
--
-- Application-level tracing for Kong.
--
-- @module kong.tracer

local require = require
local bit = require "bit"
local ffi = require "ffi"
local tablepool = require "tablepool"
local new_tab = require "table.new"
local utils = require "kong.tools.utils"
local phase_checker = require "kong.pdk.private.phases"

local error = error
local insert = table.insert
local setmetatable = setmetatable
local ngx = ngx
local rand_bytes = utils.get_rand_bytes
local C = ffi.C
local band = bit.band
local bor = bit.bor
local check_phase = phase_checker.check
local PHASES = phase_checker.phases
local ffi_time_unix_nano = utils.time_ns

local phases_with_ctx =
    phase_checker.new(PHASES.rewrite,
                      PHASES.access,
                      PHASES.header_filter,
                      PHASES.response,
                      PHASES.body_filter,
                      PHASES.log,
                      PHASES.admin_api)


--- Constants
-- @section constants
local span_pool = "kong_span"
local FLAG_SAMPLED = 0x01
local FLAG_RECORDING = 0x02

---
-- SpanKind is the type of span. Can be used to specify additional relationships between spans
-- in addition to a parent/child relationship.
-- @table SPAN_KIND
local SPAN_KIND = {
  UNSPECIFIED = 0,
  INTERNAL = 1,
  SERVER = 2,
  CLIENT = 3,
  PRODUCER = 4,
  CONSUMER = 5,
}


--- Generate trace ID
local function generate_trace_id()
  return rand_bytes(16)
end

--- Generate span ID
local function generate_span_id()
  return rand_bytes(8)
end


--- Span
-- @section span
local span_mt = {}
span_mt.__index = span_mt

-- noop Span metatable
local noop_span_mt = {
  __index = function ()
    return function () end
  end
}


local function new_span(tracer, name, options)
  if tracer == nil then
    error("invalid tracer", 2)
  end

  if type(name) ~= "string" or #name == 0 then
    error("invalid span name", 2)
  end

  if options ~= nil and type(options) ~= "table" then
    error("invalid options type", 2)
  end

  if options ~= nil then
    if options.start_time_ns ~= nil and type(options.start_time_ns) ~= "number" then
      error("invalid start time", 2)
    end

    if options.span_kind ~= nil and type(options.span_kind) ~= "number" then
      error("invalid start kind", 2)
    end

    if options.sampled ~= nil and type(options.sampled) ~= "boolean" then
      error("invalid sampled", 2)
    end

    if options.attributes ~= nil and type(options.attributes) ~= "table" then
      error("invalid attributes", 2)
    end
  end

  options = options or {}

  -- avoid reallocate
  local span = tablepool.fetch(span_pool, 0, 10)
  -- cache tracer ref, to get hooks / span processer
  -- tracer ref will not be cleared when the span table released
  span.tracer = tracer

  -- get parent span from ctx
  -- the ctx could either be stored in ngx.ctx or kong.ctx
  local parent_span = tracer.active_span()

  span.name = name
  span.trace_id = parent_span and parent_span.trace_id
                  or options.trace_id
                  or generate_trace_id()
  span.span_id = generate_span_id()
  span.parent_id = parent_span and parent_span.span_id
                        or options.parent_id

  -- specify span start time manually
  span.start_time_ns = options.start_time_ns or ffi_time_unix_nano()
  span.kind = options.kind or SPAN_KIND.INTERNAL
  span.attributes = options.attributes

  -- indicates whether the span should be reported
  span.sampled = parent_span and parent_span.sampled
                  or options.sampled
                  or band(tracer.sampler(), FLAG_SAMPLED) == FLAG_SAMPLED

  return setmetatable(span, span_mt)
end

--- Ends a Span
--
-- @module Span
-- @tparam number|nil end_time_ns
function span_mt:finish(end_time_ns)
  if self.end_time_ns ~= nil then
    -- span is finished, and processed already
    return
  end

  if end_time_ns ~= nil and type(end_time_ns) ~= "number" then
    error("invalid span end time", 2)
  end

  if end_time_ns and end_time_ns < self.start_time_ns then
    error("invalid span duration", 2)
  end

  self.end_time_ns = end_time_ns or ffi_time_unix_nano()

  if self.tracer.exporter then
    self.tracer.exporter(self)
  end

  tablepool.release(span_pool, self)
end

--- Set an attribute to a Span
--
-- @module Span
-- @tparam string key
-- @tparam string|number|boolean value
function span_mt:set_attribute(key, value)
  if type(key) ~= "string" then
    error("invalid key", 2)
  end

  local vtyp = type(value)
  if vtyp ~= "string" and vtyp ~= "number" and vtyp ~= "boolean" then
    error("invalid value", 2)
  end

  if self.attributes == nil then
    self.attributes = new_tab(0, 1)
  end

  self.attributes[key] = value
end

-- Adds an event to a Span
--
-- @module Span
-- @tparam string name Event name
-- @tparam number|nil time_ns Event timestamp
function span_mt:add_event(name, time_ns)
  if type(name) ~= "string" then
    error("invalid name", 2)
  end

  if self.events == nil then
    self.events = new_tab(1, 0)
  end

  insert(self.events, {
    name = name,
    time_ns = time_ns,
  })
end


--- Tracer
-- @section tracer
local tracer_mt = {}
tracer_mt.__index = tracer_mt

--- Build-in sampler
local always_on_sampler
do
  local flag = bor(FLAG_SAMPLED, FLAG_RECORDING)
  function always_on_sampler()
    return flag
  end
end

--- New Tracer
local function new_tracer(name, options)
  local self = {
    name = name, -- Instrumentation library name
  }

  options = options or {}

  self.noop = options.noop == true
  self.sampler = options.sampler or always_on_sampler
  self.exporter = options.exporter

  --- Get the active span
  -- Returns the root span by default
  --
  -- @function kong.tracer.new_span
  -- @treturn table span
  function self.active_span()
    check_phase(phases_with_ctx)

    return ngx.ctx.active_span
  end

  --- Set the active span
  --
  -- @function kong.tracer.new_span
  -- @tparam table span
  function self.set_active_span(span)
    check_phase(phases_with_ctx)

    ngx.ctx.active_span = span
  end

  --- Create a new Span
  --
  -- @function kong.tracer.new_span
  -- @tparam string name span name
  -- @tparam table options TODO:
  -- @treturn table span
  function self.start_span(...)
    check_phase(phases_with_ctx)

    if self.noop then
      return setmetatable({}, noop_span_mt)
    end

    local span = new_span(self, ...)
    -- set root span
    if not self.active_span() then
      self.set_active_span(span)
    end

    return span
  end

  return setmetatable(self, tracer_mt)
end
tracer_mt.new = new_tracer


return {
  new = function ()
    return new_tracer("core", { noop = true })
  end,
}

--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--    http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local Util = require('skywalking.swutil')
local Span = require('skywalking.span')
local SegmentRef = require('skywalking.segment_ref')
local CorrelationContext = require('skywalking.correlation_context')

local CONTEXT_CARRIER_KEY = 'sw8'
local CONTEXT_CORRELATION_KEY = 'sw8-correlation'

-------------- Internal Object-------------
local Internal = {}
-- Internal Object hosts the methods for SkyWalking LUA internal APIs only.
-- local Internal = {
--     self_generated_trace_id,
--     -- span id starts from 0
--     span_id_seq,
--     -- Owner means the Context instance holding this Internal object.
--     owner,
--     -- The first created span.
--     first_span,
--     -- Created span and still active
--     active_spans,
--     active_count,
--     -- Finished spans
--     finished_spans,
-- }


-- add the segment ref if this is the first ref of this context
local function addRefIfFirst(internal, ref)
    if internal.self_generated_trace_id == true then
        internal.self_generated_trace_id = false
        internal.owner.trace_id = ref.trace_id
    end
end

local function addActive(internal, span)
    if internal.first_span == nil then
        internal.first_span = span
    end

    -- span id starts at 0, to fit LUA, we need to plus one.
    internal.active_spans[span.span_id + 1] = span
    internal.active_count = internal.active_count + 1
    return internal.owner
end

local function finishSpan(internal, span)
    -- span id starts at 0, to fit LUA, we need to plus one.
    internal.active_spans[span.span_id + 1] = nil
    internal.active_count = internal.active_count - 1
    internal.finished_spans[#internal.finished_spans + 1] = span

    return internal.owner
end

-- Generate the next span ID.
local function nextSpanID(internal)
    local nextSpanId = internal.span_id_seq
    internal.span_id_seq = internal.span_id_seq + 1
    return nextSpanId
end

-- Create an internal instance
function Internal.new()
    local internal = Util.tablepool_fetch()

    internal.self_generated_trace_id = true
    internal.span_id_seq = 0
    internal.active_spans = Util.tablepool_fetch()
    internal.active_count = 0
    internal.finished_spans = Util.tablepool_fetch()
    internal.addRefIfFirst = addRefIfFirst
    internal.addActive = addActive
    internal.finishSpan = finishSpan
    internal.nextSpanID = nextSpanID
    return internal
end


local _M = {}

-- local TracingContext = {
--     trace_id,
--     segment_id,
--     service,
--     service_instance,
--     is_noop = false,
--     internal,
-- }

function _M.newNoOP()
    return {is_noop = true}
end

function _M.new(serviceName, serviceInstanceName, requestId)
    if serviceInstanceName == nil or serviceName == nil then
        return _M.newNoOP()
    end

    local segment_id = Util.newID()
    -- use request_id as trace_id if it is present
    local trace_id = requestId
    if trace_id == nil then
        trace_id = segment_id
    end

    local tracing_context = Util.tablepool_fetch()
    tracing_context.trace_id = trace_id
    tracing_context.segment_id = segment_id
    tracing_context.service = serviceName
    tracing_context.service_instance = serviceInstanceName
    tracing_context.internal = Internal.new()
    tracing_context.internal.owner = tracing_context
    return tracing_context
end

-- Delegate to Span.createEntrySpan
-- @param contextCarrier could be nil if there is no downstream propagated context
function _M.createEntrySpan(tracingContext, operationName, parent, contextCarrier)
    if tracingContext.is_noop then
        return Span.newNoOP()
    end

    local correlationData = ''
    if contextCarrier then
        correlationData = contextCarrier[CONTEXT_CORRELATION_KEY]
    end
    tracingContext.correlation = CorrelationContext.fromSW8Value(correlationData)

    return Span.createEntrySpan(operationName, tracingContext, parent, contextCarrier)
end

-- Delegate to Span.createExitSpan
-- @param contextCarrier could be nil if don't need to inject any context to propagate
function _M.createExitSpan(tracingContext, operationName, parent)
    if tracingContext.is_noop then
        return Span.newNoOP()
    end

    return Span.createExitSpan(operationName, tracingContext, parent)
end

-- Inject an exit span context and correlation context into context carrier to propagate
-- @param correlation is used to transport custom data to downstream service
function _M.inject(tracingContext, exitSpan, peer, correlation)
    Span.setPeer(exitSpan, peer)

    local injectableRef = SegmentRef.createInjectableRef(tracingContext, exitSpan)
    local correlationData = tracingContext.correlation
    if correlation then
        for name, value in pairs(correlation) do
            CorrelationContext.put(correlationData, name, value)
        end
    end

    ngx.req.set_header(CONTEXT_CARRIER_KEY, SegmentRef.serialize(injectableRef))
    ngx.req.set_header(CONTEXT_CORRELATION_KEY, CorrelationContext.serialize(correlationData))
end

-- After all active spans finished, this segment will be treated as finished status.
-- Notice, it is different with Java agent, a finished context is still able to recreate new span, and be checked as finished again.
-- This gives the end user more flexibility. Unless it is a real reasonable case, don't call #drainAfterFinished multiple times.
--
-- Return (boolean isSegmentFinished, Segment segment).
-- Segment has value only when the isSegmentFinished is true
-- if isSegmentFinished == false, SpanList = nil
function _M.drainAfterFinished(tracingContext)
    if tracingContext.is_noop then
        return false, nil
    end

    if tracingContext.internal.active_count ~= 0 then
        return false, nil
    else
        local segment = Util.tablepool_fetch()
        segment.trace_id = tracingContext.trace_id
        segment.segment_id = tracingContext.segment_id
        segment.service = tracingContext.service
        segment.service_instance = tracingContext.service_instance
        segment.spans = tracingContext.internal.finished_spans
        return true, segment
    end
end

return _M
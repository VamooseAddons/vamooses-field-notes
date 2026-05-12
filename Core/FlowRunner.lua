-- VFN.FlowRunner
--
-- Coroutine-based multi-step async orchestration ("sagas"). Architecture
-- spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 16.
-- Reference patterns: Defold flow library, redux-saga.
--
-- STATUS: zero consumers in VFN today. Kept for Phase 2 (VamooseUI extraction)
-- when this engine becomes a shared addon-level service used by:
--   * VE -- chest claim detector (multi-event correlation)
--   * VN -- BNet neighbour scan (long-running poll)
--   * VC -- companion summon orchestration (sequential async + tracking)
--   * HDG -- crafting queue + retry-on-fail flows
-- The boot path (FlowRunner:Boot in Init.lua, _onEvent tap in BlizzardEvents)
-- is live so a new module's `flow` field works without engine wiring changes.
-- Removing the engine now would mean re-introducing it for Phase 2; cheaper
-- to keep idle infrastructure (one CreateFrame, one event tap) until then.
--
-- For flows that are saga-shaped:
--   - Multi-event correlation with timeouts (VE chest claim: QUEST_TURNED_IN
--     + HOUSE_LEVEL_FAVOR_UPDATED within 2s window)
--   - Long-running poll loops (VN BNet scan)
--   - Sequential async with conditional branches (VC companion summon ->
--     wait for spell complete -> start tracking)
--
-- Reducers stay pure (reactive). Flows are explicit orchestration coroutines:
--
--   VFN.Modules:Declare({
--       name = "ChestClaimDetector",
--       dependencies = { "Store", "BlizzardEvents", "FlowRunner" },
--       flow = function(store, env)
--           while true do
--               local quest = flow.take("QUEST_TURNED_IN",
--                   function(a) return a.questID == 93262 end)
--               local result = flow.race({
--                   favor   = flow.take("HOUSE_LEVEL_FAVOR_UPDATED",
--                                       function(a) return a.delta == 250 end),
--                   timeout = flow.delay(2),
--               })
--               if result.favor then
--                   store:Dispatch({ type = "CHEST_CLAIMED", houseID = quest.houseID })
--               end
--           end
--       end,
--   })
--
-- Flow API (yielded request shapes the FlowRunner interprets):
--   flow.take(event, predicate?)   -- yield until matching event fires
--   flow.delay(seconds)            -- yield for N seconds
--   flow.race({ a = ..., b = ...}) -- yield until first nested op completes
--   flow.dispatch(action)           -- convenience for store:Dispatch
--   flow.select(name, ...)          -- read state via registered selector
--
-- Rules:
--   1. Flow body MUST NOT mutate state directly -- only via dispatch.
--   2. Stale flows after /reload are cancelled and restarted (transient).
--   3. Combat pauses flows unless combatSafe=true (read state.session.combat.inLockdown
--      to gate work).
--   4. Coroutines pooled where possible (Defold lesson: creation isn't free).

VFN = VFN or {}
VFN.FlowRunner = VFN.FlowRunner or {
    _flows = {},                  -- [moduleName] = { co, status, waitingOn }
    _booted = false,
}

local FR = VFN.FlowRunner

-- ===== Flow API ============================================================
--
-- Two layers (redux-saga-style):
--
-- 1. Yielding wrappers (top-level flow.X): take/delay/race CALL coroutine.yield.
--    Use these as the body of the flow. They look imperative even though
--    they're suspending under the hood.
--
-- 2. Descriptor builders (flow.events.X): take/delay return plain descriptor
--    TABLES. They do NOT yield. Use these inside flow.race / flow.parallel
--    branch tables, where the FlowRunner needs to see the descriptors
--    without each one yielding the moment it's built.
--
-- Example:
--   local quest = flow.take("QUEST_TURNED_IN", pred)         -- yields, returns args
--   local result = flow.race({
--       favor   = flow.events.take("HOUSE_LEVEL_FAVOR_UPDATED", pred),  -- builds descriptor
--       timeout = flow.events.delay(2),
--   })

VFN.flow = {}
local flow = VFN.flow

-- Descriptor builders (no yield).
flow.events = {}
function flow.events.take(event, predicate)
    return { kind = "take", event = event, predicate = predicate }
end
function flow.events.delay(seconds)
    return { kind = "delay", seconds = seconds }
end
function flow.events.untilTrue(predicate)
    return { kind = "until_true", predicate = predicate }
end

-- Yielding wrappers. take/delay/until_true yield directly; race/parallel
-- yield descriptors that the FlowRunner interprets.
function flow.take(event, predicate)
    return coroutine.yield(flow.events.take(event, predicate))
end

function flow.delay(seconds)
    return coroutine.yield(flow.events.delay(seconds))
end

-- Yield until predicate returns true. The runner re-evaluates the predicate
-- after every event dispatch (cheap; just a function call). Useful for
-- "wait until store state holds condition X" without polling a timer.
function flow.until_true(predicate)
    if type(predicate) ~= "function" then
        error("flow.until_true: predicate must be a function", 2)
    end
    -- Fast path: predicate already true, no yield.
    if predicate() then return end
    return coroutine.yield(flow.events.untilTrue(predicate))
end

local function validateBranches(callerName, branches)
    if type(branches) ~= "table" then
        error(("flow.%s: branches must be a table { key = descriptor, ... }"):format(callerName), 3)
    end
    for k, b in pairs(branches) do
        if type(b) ~= "table" or not b.kind then
            error(("flow.%s: branch %q must be a descriptor (use flow.events.take/delay/untilTrue)")
                :format(callerName, tostring(k)), 3)
        end
    end
end

function flow.race(branches)
    validateBranches("race", branches)
    return coroutine.yield({ kind = "race", branches = branches })
end

-- Yield until ALL branches complete. Returns a result table keyed by branch
-- key containing each branch's args/value. Branches run concurrently from
-- the engine's perspective -- each waits on its own event/timer.
function flow.parallel(branches)
    validateBranches("parallel", branches)
    return coroutine.yield({ kind = "parallel", branches = branches })
end

function flow.dispatch(action)
    if VFN.Store and VFN.Store.Dispatch then
        VFN.Store:Dispatch(action)
    end
end

function flow.select(name, ...)
    if VFN.Selectors and VFN.Selectors.Call then
        return VFN.Selectors:Call(name, VFN.Store and VFN.Store:GetState() or nil, ...)
    end
    return nil
end

-- ===== Internal: handle a yielded request ==================================

-- Forward declaration for mutual recursion (resume <-> handleRequest).
local resume

-- Each flow entry's waitingOn carries the descriptor that will be resolved.
-- When an event fires (via _onEvent) or a delay completes, we check the
-- entry's waitingOn and resume the coroutine with the value.

local function packVarargs(...)
    local n = select("#", ...)
    local out = { n = n }
    for i = 1, n do out[i] = (select(i, ...)) end
    return out
end

local function tryResolveTake(entry, event, ...)
    local waitingOn = entry.waitingOn
    if not waitingOn then return false end

    if waitingOn.kind == "take" and waitingOn.event == event then
        if waitingOn.predicate and not waitingOn.predicate(...) then return false end
        entry.waitingOn = nil
        -- flow.take("X") returns the event's args via coroutine.resume's
        -- variadic return. flow body: `local arg1, arg2 = flow.take("X")`.
        resume(entry, ...)
        return true
    end

    if waitingOn.kind == "race" then
        for key, descriptor in pairs(waitingOn.branches) do
            if descriptor.kind == "take" and descriptor.event == event then
                if not descriptor.predicate or descriptor.predicate(...) then
                    entry.waitingOn = nil
                    resume(entry, { [key] = packVarargs(...) })
                    return true
                end
            end
        end
    end

    if waitingOn.kind == "parallel" then
        -- A parallel branch completes when its descriptor's condition fires.
        -- Each completed branch is recorded in waitingOn._completed; when
        -- ALL branches have completed, we resume with the aggregated result.
        local results = waitingOn._completed or {}
        waitingOn._completed = results

        for key, descriptor in pairs(waitingOn.branches) do
            if results[key] == nil and descriptor.kind == "take" and descriptor.event == event then
                if not descriptor.predicate or descriptor.predicate(...) then
                    results[key] = packVarargs(...)
                    -- Check if all branches done
                    local allDone = true
                    for k in pairs(waitingOn.branches) do
                        if results[k] == nil then allDone = false; break end
                    end
                    if allDone then
                        entry.waitingOn = nil
                        resume(entry, results)
                    end
                    return true
                end
            end
        end
    end

    return false
end

-- Re-evaluate until_true predicate after any event. The predicate may now
-- be true (state changed via a reducer that ran in the dispatch chain).
local function tryResolveUntilTrue(entry)
    local waitingOn = entry.waitingOn
    if not waitingOn or waitingOn.kind ~= "until_true" then return false end
    if waitingOn.predicate() then
        entry.waitingOn = nil
        resume(entry)
        return true
    end
    return false
end

-- Schedule a delay descriptor via C_Timer. When the timer fires, resume
-- the coroutine with no value (caller doesn't usually need one).
local function scheduleDelay(entry, seconds, resumeWith)
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(seconds, function()
            if entry.status ~= "running" then return end
            -- Only resume if THIS delay is still what the entry is waiting on
            -- (otherwise a race winner already fired, or flow was cancelled).
            if entry.waitingOn and entry.waitingOn._timerKey == entry._currentTimerKey then
                entry.waitingOn = nil
                resume(entry, resumeWith)
            end
        end)
    end
end

-- Handle a yielded request from the coroutine. Sets entry.waitingOn so the
-- next event fire / timer tick can resolve it.
local function handleRequest(entry, request)
    if request == nil then
        -- Coroutine finished cleanly.
        entry.status = "finished"
        return
    end
    if type(request) ~= "table" or not request.kind then
        entry.status = "errored"
        print(("|cffff5555[FlowRunner] %q yielded invalid request: %s|r")
            :format(entry.name, tostring(request)))
        return
    end

    if request.kind == "take" then
        entry.waitingOn = request

    elseif request.kind == "delay" then
        entry._currentTimerKey = (entry._currentTimerKey or 0) + 1
        request._timerKey = entry._currentTimerKey
        entry.waitingOn = request
        scheduleDelay(entry, request.seconds, nil)

    elseif request.kind == "race" then
        entry._currentTimerKey = (entry._currentTimerKey or 0) + 1
        entry.waitingOn = request

        -- Schedule any delay-branch timers; take-branches resolve on event fire.
        for key, descriptor in pairs(request.branches) do
            if descriptor.kind == "delay" then
                local tkey = entry._currentTimerKey
                if _G.C_Timer and _G.C_Timer.After then
                    _G.C_Timer.After(descriptor.seconds, function()
                        if entry.status ~= "running" then return end
                        if entry.waitingOn ~= request or entry._currentTimerKey ~= tkey then
                            return    -- race already settled
                        end
                        entry.waitingOn = nil
                        resume(entry, { [key] = { delay = descriptor.seconds } })
                    end)
                end
            end
        end

    elseif request.kind == "parallel" then
        entry._currentTimerKey = (entry._currentTimerKey or 0) + 1
        request._completed = {}
        entry.waitingOn = request

        -- Schedule delay-branch timers. take-branches resolve on event fire
        -- via tryResolveTake's parallel case.
        for key, descriptor in pairs(request.branches) do
            if descriptor.kind == "delay" then
                local tkey = entry._currentTimerKey
                if _G.C_Timer and _G.C_Timer.After then
                    _G.C_Timer.After(descriptor.seconds, function()
                        if entry.status ~= "running" then return end
                        if entry.waitingOn ~= request or entry._currentTimerKey ~= tkey then
                            return
                        end
                        request._completed[key] = { n = 0 }
                        -- Check if all branches done
                        local allDone = true
                        for k in pairs(request.branches) do
                            if request._completed[k] == nil then allDone = false; break end
                        end
                        if allDone then
                            entry.waitingOn = nil
                            resume(entry, request._completed)
                        end
                    end)
                end
            end
        end

    elseif request.kind == "until_true" then
        entry.waitingOn = request
        -- The predicate is re-evaluated on every event tick (in _onEvent
        -- via tryResolveUntilTrue). We don't poll on a timer because most
        -- state changes happen via Store dispatch which is typically driven
        -- by events anyway. If predicate is already true at yield time,
        -- flow.until_true short-circuited before yielding (see flow.until_true).

    else
        entry.status = "errored"
        print(("|cffff5555[FlowRunner] %q yielded unknown request.kind: %s|r")
            :format(entry.name, tostring(request.kind)))
    end
end

-- Resume the coroutine with an optional value. Handles the next yielded
-- request (or finishes / errors).
function resume(entry, ...)
    if entry.status ~= "running" then return end
    local ok, request = coroutine.resume(entry.co, ...)
    if not ok then
        entry.status = "errored"
        print(("|cffff5555[FlowRunner] %q errored: %s|r"):format(entry.name, tostring(request)))
        return
    end
    if coroutine.status(entry.co) == "dead" then
        entry.status = "finished"
        return
    end
    handleRequest(entry, request)
end

-- ===== Event integration ==================================================

-- Called when a Blizzard event fires; checks every flow's waitingOn to see
-- if any can resolve. Two passes:
--   1. take/race/parallel branches keyed on the event
--   2. until_true predicates that may now hold (state may have changed via
--      a reducer that ran in the dispatch chain triggered by this event)
function FR:_onEvent(event, ...)
    for _, entry in pairs(self._flows) do
        if entry.status == "running" then
            tryResolveTake(entry, event, ...)
        end
    end
    -- Second pass: re-check any until_true waiters. Done AFTER take resolution
    -- so that an event-driven state change can satisfy until_true on the
    -- same tick rather than waiting for the next event.
    for _, entry in pairs(self._flows) do
        if entry.status == "running" then
            tryResolveUntilTrue(entry)
        end
    end
end

-- ===== Module integration =================================================

-- Start a single flow. Builds the coroutine, primes the first run, and
-- registers the entry.
function FR:Start(moduleName, flowFn, env)
    if self._flows[moduleName] then
        error(("VFN.FlowRunner:Start(%q): already running"):format(moduleName), 2)
    end
    local entry = {
        name = moduleName,
        status = "running",
        co = nil,
        waitingOn = nil,
        _currentTimerKey = 0,
    }
    entry.co = coroutine.create(function()
        flowFn(VFN.Store, env or (VFN.Environment and VFN.Environment._current) or nil)
    end)
    self._flows[moduleName] = entry
    resume(entry)
end

-- Stop a flow. Sets status to "cancelled" so future event-driven resumes
-- short-circuit. The coroutine itself becomes GC-eligible.
function FR:Stop(moduleName)
    local entry = self._flows[moduleName]
    if not entry then return end
    entry.status = "cancelled"
    entry.waitingOn = nil
    entry.co = nil
    self._flows[moduleName] = nil
end

-- Boot: walks every registered module and starts its flow (if declared).
-- Wires the central BlizzardEvents:_internalSubscribe so the FlowRunner
-- sees every event. Called after Modules:Boot Phase 1 completes.
function FR:Boot()
    if self._booted then return end
    self._booted = true

    if not VFN.Modules or not VFN.Modules.GetOrder then return end

    for _, name in ipairs(VFN.Modules:GetOrder() or {}) do
        local def = VFN.Modules:Get(name)
        if type(def.flow) == "function" then
            self:Start(name, def.flow)
        end
    end
end

-- After Boot, hook every event a flow.take referenced. Since takes can be
-- dynamic (predicates change per loop iteration), we wire a single internal
-- listener per event that has at least one current waiter. Simpler:
-- subscribe to every event whose waiter set is non-empty as flows yield
-- take requests. For Phase 1 we go even simpler -- the Modules's blizzardEvents
-- declarations have already wired RegisterEvent for relevant events; we
-- piggyback by routing every dispatched event through _onEvent via
-- BlizzardEvents internal hooks.

-- ===== Test helpers =======================================================

function FR:_GetEntry(moduleName) return self._flows[moduleName] end
function FR:_ResolveEvent(event, ...) self:_onEvent(event, ...) end
function FR:_Reset()
    self._flows = {}
    self._booted = false
end

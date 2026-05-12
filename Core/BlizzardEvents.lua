-- VFN.BlizzardEvents
--
-- Single-frame event router. The input boundary of the architecture.
-- Architecture spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 15.
--
-- Modules declare event subscriptions in their `blizzardEvents` field at
-- Module:Declare time (see Core/Modules.lua). BlizzardEvents:Boot is called
-- by Init.lua AFTER Modules:Boot has run Phase 1 -- by that point every
-- module's def is in the registry and we can wire all subscribers in one
-- pass.
--
-- Three subscription modes (declared per event in a module's blizzardEvents):
--   action  = "STORE_ACTION_TYPE"            -> Store.Dispatch on event fire
--   handler = "methodName" | function        -> Call module:methodName(...) or fn(...)
--   thunk   = function(store, env, ...)      -> Conditional dispatch with full Store/env
--
-- Options on each subscription:
--   debounce  = 0.2     -- seconds; coalesces repeated fires within window
--   filter    = fn(...) -- arg predicate; drops fire if returns false
--   once      = true    -- auto-unsubscribe after first fire
--
-- Hook namespace: events with "hook:" prefix install a `hooksecurefunc`
-- instead of RegisterEvent. Same subscription/debounce/filter semantics.
--
-- Reference patterns:
--   hump.signal -- function-as-own-key subscriber list (LUA_SAMPLES.md section 3a)
--   Rodux Store -- middleware-style dispatch (LUA_SAMPLES.md section 1a)
--   Elm Subscriptions / Neovim autocmd -- declarative per-module subscriptions

VFN = VFN or {}
VFN.BlizzardEvents = VFN.BlizzardEvents or {
    _frame       = nil,                   -- single CreateFrame; built in OnInitialize
    _subscribers = {},                    -- [event] = { { module, mode, opts, ... }, ... }
    _debounceTimers = {},                 -- [event .. ":" .. moduleName] = timer
    _hookInstalled = {},                  -- [funcName] = true
    _registeredEvents = {},               -- [event] = true (events frame:RegisterEvent'd)
    _booted = false,
}

local BE = VFN.BlizzardEvents

-- ===== Closed event taxonomy (high-frequency events that REQUIRE debounce) ==
-- Validator enforces: subscribing to any of these without `debounce` errors.
-- Add rows as the monorepo accumulates evidence of new high-freq events.

BE.DEBOUNCE_REQUIRED = {
    BAG_UPDATE                  = 0.2,
    CURRENCY_DISPLAY_UPDATE     = 0.3,
    UNIT_AURA                   = 0.1,
    CHAT_MSG_LOOT               = 0.5,
    ITEM_PUSH                   = 0.5,
    TRANSMOG_COLLECTION_UPDATED = 0.5,
    PLAYER_INVENTORY_CHANGED    = 0.2,
}

-- Combat regen events are owned by CombatMiddleware; modules cannot subscribe.
BE.FORBIDDEN_MODULE_EVENTS = {
    PLAYER_REGEN_DISABLED = "owned by CombatMiddleware (read state.session.combat.inLockdown)",
    PLAYER_REGEN_ENABLED  = "owned by CombatMiddleware (read state.session.combat.inLockdown)",
}

-- ===== Dispatch helper =====================================================

local function callHandler(mod, handler, ...)
    if type(handler) == "string" then
        local method = mod[handler]
        if type(method) == "function" then
            method(mod, ...)
        else
            error(("blizzardEvents handler %q is not a method on module %q")
                :format(handler, mod.name), 2)
        end
    elseif type(handler) == "function" then
        handler(mod, ...)
    end
end

local function dispatchToSubscriber(sub, event, ...)
    -- Race-safety for `once` subscriptions: an outer _fire snapshots the
    -- subscriber list before iterating. If a handler triggers a re-entrant
    -- _fire for the SAME event, the inner fire creates a fresh snapshot from
    -- the already-cleaned subscriber list, but the outer snapshot still holds
    -- the once-entry and would fire it again. Guard with _once_fired flag
    -- checked at dispatch start.
    if sub._once_fired then return end

    local opts = sub.opts
    if opts.filter and not opts.filter(...) then return end

    -- One-shot subscriptions: mark + detach before firing so re-entrant
    -- dispatch inside the handler doesn't re-fire this subscriber.
    if opts.once then
        sub._once_fired = true
        local subs = BE._subscribers[event]
        for i, s in ipairs(subs) do
            if s == sub then table.remove(subs, i); break end
        end
    end

    if sub.mode == "action" then
        if VFN.Store and VFN.Store.Dispatch then
            VFN.Store:Dispatch({ type = opts.action, payload = { ... } })
        end
    elseif sub.mode == "handler" then
        callHandler(sub.module, opts.handler, ...)
    elseif sub.mode == "thunk" then
        local env = VFN.Environment and VFN.Environment.current or nil
        opts.thunk(VFN.Store, env, ...)
    end
end

-- Coalesce fires within the debounce window. Most-recent args win
-- (Blizzard semantics: BAG_UPDATE(0) then BAG_UPDATE(1) within 0.2s should
-- fire ONCE with bagID=1). At most one timer scheduled per (event, module)
-- key; subsequent fires update the args slot but don't schedule another timer.
local function debouncedFire(sub, event, ...)
    local key = event .. ":" .. sub.module.name
    local pending = BE._debounceTimers[key]
    if pending then
        -- Timer already scheduled. Replace args in place; the existing
        -- timer will pick up the latest values when it fires.
        pending.n = select("#", ...)
        for i = 1, pending.n do pending[i] = select(i, ...) end
        return
    end

    local args = { n = select("#", ...) }
    for i = 1, args.n do args[i] = select(i, ...) end
    BE._debounceTimers[key] = args

    C_Timer.After(sub.opts.debounce, function()
        local current = BE._debounceTimers[key]
        if not current then return end
        BE._debounceTimers[key] = nil
        dispatchToSubscriber(sub, event, unpack(current, 1, current.n))
    end)
end

-- ===== Registration ========================================================

-- Validate one event subscription spec. Errors loudly with module + event name.
local function validateSub(modName, event, spec)
    if BE.FORBIDDEN_MODULE_EVENTS[event] then
        error(("Module %q cannot subscribe to %q: %s")
            :format(modName, event, BE.FORBIDDEN_MODULE_EVENTS[event]), 2)
    end

    -- Shorthand: string value means handler = methodName
    if type(spec) == "string" then
        return { mode = "handler", opts = { handler = spec } }
    end

    if type(spec) ~= "table" then
        error(("Module %q subscription to %q must be a table or handler-name string")
            :format(modName, event), 2)
    end

    local modeCount = 0
    local mode
    if spec.action  ~= nil then modeCount = modeCount + 1; mode = "action" end
    if spec.handler ~= nil then modeCount = modeCount + 1; mode = "handler" end
    if spec.thunk   ~= nil then modeCount = modeCount + 1; mode = "thunk" end

    if modeCount == 0 then
        error(("Module %q subscription to %q must declare one of action / handler / thunk")
            :format(modName, event), 2)
    end
    if modeCount > 1 then
        error(("Module %q subscription to %q declared multiple modes; pick one")
            :format(modName, event), 2)
    end

    -- Validate debounce requirement for high-frequency events
    if BE.DEBOUNCE_REQUIRED[event] and not spec.debounce then
        error(("Module %q subscription to %q requires `debounce` (recommended %.1fs). "
            .. "High-frequency event; see BlizzardEvents.DEBOUNCE_REQUIRED."):format(
            modName, event, BE.DEBOUNCE_REQUIRED[event]), 2)
    end

    if spec.filter ~= nil and type(spec.filter) ~= "function" then
        error(("Module %q subscription to %q: `filter` must be a function"):format(modName, event), 2)
    end

    return { mode = mode, opts = spec }
end

-- Add one event subscription to the registry. Wires RegisterEvent or
-- hooksecurefunc as appropriate. Idempotent on the underlying registration.
local function addSubscription(modDef, event, sub)
    local list = BE._subscribers[event]
    if not list then
        list = {}
        BE._subscribers[event] = list

        local hookPrefix = event:sub(1, 5)
        if hookPrefix == "hook:" then
            local funcName = event:sub(6)
            if not BE._hookInstalled[funcName] then
                BE._hookInstalled[funcName] = true
                hooksecurefunc(funcName, function(...)
                    BE:_fire(event, ...)
                end)
            end
        else
            if BE._frame and not BE._registeredEvents[event] then
                BE._frame:RegisterEvent(event)
                BE._registeredEvents[event] = true
            end
        end
    end
    list[#list + 1] = {
        module = modDef,
        mode   = sub.mode,
        opts   = sub.opts,
    }
end

-- ===== Fire / simulate =====================================================

-- Internal fire: invoked by OnEvent or by tests via _simulate.
function BE:_fire(event, ...)
    -- Internal subscribers (CombatMiddleware etc.) fire BEFORE module
    -- subscribers so combat state is updated before any action dispatches
    -- that depend on it run.
    local internal = self._internalSubs and self._internalSubs[event]
    if internal then
        for _, cb in ipairs(internal) do cb(...) end
    end

    -- FlowRunner taps every event so saga-style flow.take(event, ...) can
    -- resolve regardless of whether a module also subscribed. Cheap
    -- (most flows have no waitingOn for any given event); the engine
    -- short-circuits internally.
    if VFN.FlowRunner and VFN.FlowRunner._onEvent then
        VFN.FlowRunner:_onEvent(event, ...)
    end

    local subs = self._subscribers[event]
    if not subs then return end
    -- Snapshot subscriber list before iteration so one-shot removals during
    -- dispatch don't perturb the loop.
    local snapshot = {}
    for i, s in ipairs(subs) do snapshot[i] = s end
    for _, sub in ipairs(snapshot) do
        if sub.opts.debounce then
            debouncedFire(sub, event, ...)
        else
            dispatchToSubscriber(sub, event, ...)
        end
    end
end

-- Test helper: drive the engine without a real frame event.
function BE:_simulate(event, ...)
    self:_fire(event, ...)
end

-- Internal subscribe: bypasses the module-validator. Used by sibling engines
-- (CombatMiddleware) that need to listen for events modules can't subscribe
-- to (the regen events). Callback signature: function(...) -- raw event args.
-- Caller is responsible for its own debouncing/filtering.
--
-- Wired RegisterEvent if the event isn't already registered. Safe to call
-- multiple times for the same event; each callback runs independently.
function BE:_internalSubscribe(event, callback)
    if not self._frame then self:OnInitialize() end
    local list = self._internalSubs or {}
    self._internalSubs = list
    list[event] = list[event] or {}
    table.insert(list[event], callback)

    if not self._registeredEvents[event] and event:sub(1, 5) ~= "hook:" then
        self._frame:RegisterEvent(event)
        self._registeredEvents[event] = true
    end
end

-- ===== Boot ================================================================

-- Eager frame init at TOC load (spec section 15.3: "one module, one frame,
-- all events"). The engine is ready to accept _internalSubscribe calls
-- AND declarative module subscriptions immediately after this file loads,
-- which is what lets Init.lua route ADDON_LOADED / PLAYER_LOGIN /
-- PLAYER_LOGOUT through the engine instead of carrying a sibling frame.
local function ensureFrame()
    if BE._frame then return end
    BE._frame = CreateFrame("Frame")
    BE._frame:SetScript("OnEvent", function(_, event, ...) BE:_fire(event, ...) end)
end
ensureFrame()

-- OnInitialize stays as an idempotent no-op for tests that do
-- _Reset(); OnInitialize() round-trips. Production code does not need
-- to call this -- the frame is live from TOC load.
function BE:OnInitialize()
    ensureFrame()
end

-- Boot is called after Modules:Boot Phase 1 completes. Walks every module's
-- blizzardEvents field, validates, and wires the subscriber lists. Errors
-- collected and reported loudly; one bad subscription doesn't silently
-- skip its neighbors.
function BE:Boot()
    if self._booted then return end
    self._booted = true

    local errors = {}
    for _, modName in ipairs(VFN.Modules:GetOrder() or {}) do
        local def = VFN.Modules:Get(modName)
        local events = def.blizzardEvents
        if events then
            for event, spec in pairs(events) do
                local ok, subOrErr = pcall(validateSub, def.name, event, spec)
                if ok then
                    addSubscription(def, event, subOrErr)
                else
                    errors[#errors + 1] = tostring(subOrErr)
                end
            end
        end
    end

    if #errors > 0 then
        error("VFN.BlizzardEvents:Boot validation failures:\n  " ..
            table.concat(errors, "\n  "), 2)
    end
end

-- ===== Test / debug helpers ===============================================

function BE:_Reset()
    if self._frame and self._frame.UnregisterAllEvents then
        self._frame:UnregisterAllEvents()
    end
    self._frame = nil
    self._subscribers = {}
    self._internalSubs = {}
    self._debounceTimers = {}
    self._hookInstalled = {}
    self._registeredEvents = {}
    self._booted = false
end

function BE:_GetSubscribers(event)
    return self._subscribers[event]
end

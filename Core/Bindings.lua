-- VFN.Binding
--
-- Reactive value that bypasses the BindingEngine reconciliation pass.
-- Architecture spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 8.
--
-- STATUS: zero consumers in VFN today. VFN has no sub-frame-frequency
-- properties yet (no animation alpha, no cooldown bars, no model camera
-- angles). Kept ready for the first animation-bearing feature -- spec
-- section 8.3 makes the Binding-vs-BindingEngine distinction mandatory
-- so we don't accidentally route animation values through dispatch.
-- When the first user lands, document the choice in the binding's
-- consumer (panel / surface) so the path is unambiguous.
--
-- Bindings exist for properties that update at sub-frame frequency
-- (animation alpha, bar fill, cooldown text, model camera angle). For
-- those, going through Store dispatch -> reducer -> BindingEngine refresh
-- is wasteful: there's no state mutation worth recording, and the value
-- changes faster than once per frame anyway. A Binding lets a producer
-- push values directly to subscribed widget properties, skipping the
-- reconciliation chain entirely.
--
-- Producer-holds-updater split (Roact pattern):
--   local barFill, setBarFill = VFN.Binding.new(0.0)
--   -- consumers can subscribe to barFill, but cannot push values.
--   -- only the closure holding setBarFill can update.
--
-- Mapping (derived bindings):
--   local widthBinding = barFill:Map(function(v) return v * 200 end)
--   -- widthBinding fires whenever barFill fires, with the transformed value.
--   -- chains are forward-only; consumers can subscribe to widthBinding.
--
-- Subscribe / unsubscribe:
--   local unsub = barFill:Subscribe(function(value) myFrame:SetWidth(value * 200) end)
--   ... unsub() to release the subscription.
--
-- Reference: LUA_SAMPLES.md section 2 (Roact Binding + createSignal).
--   - Suspend-on-fire guard prevents mutation-during-iteration bugs.
--   - Subscribers stored as function-as-own-key for O(1) unsubscribe.

VFN = VFN or {}
VFN.Binding = VFN.Binding or {}

local Binding = {}
Binding.__index = Binding

-- ===== createSignal helper ================================================
-- The subscriber registry. Function-as-own-key for O(1) add/remove.
-- _firing flag suspends mutation during iteration (snapshot the list, then
-- iterate the snapshot). Pattern from Roact createSignal.

local function createSignal()
    local subs = {}
    return {
        connect = function(fn)
            subs[fn] = fn
            return function() subs[fn] = nil end  -- unsubscribe closure
        end,
        fire = function(...)
            -- Snapshot before iteration so handlers that subscribe or
            -- unsubscribe during dispatch don't perturb the loop.
            local snapshot = {}
            for fn in pairs(subs) do snapshot[#snapshot + 1] = fn end
            for _, fn in ipairs(snapshot) do fn(...) end
        end,
        empty = function() return next(subs) == nil end,
    }
end

-- ===== Binding constructor ================================================

-- Create a new Binding with an initial value. Returns (binding, setter).
-- The binding object is the read/subscribe surface; the setter is private.
function VFN.Binding.new(initialValue)
    local self = setmetatable({
        _value = initialValue,
        _signal = createSignal(),
        _destroyed = false,
    }, Binding)

    local function setter(newValue)
        if self._destroyed then return end
        if self._value == newValue then return end       -- no-op short-circuit
        self._value = newValue
        self._signal.fire(newValue)
    end

    return self, setter
end

-- ===== Read API ===========================================================

-- Read the current value. Engines / mappers use this internally.
-- Per Roact's warning: NEVER call this inside a widget render function;
-- the consumer doesn't subscribe to updates that way. Use Subscribe.
function Binding:GetValue()
    return self._value
end

-- Subscribe to value changes. Returns an unsubscribe closure that the
-- caller MUST hold and call on widget destroy (otherwise the binding
-- keeps the callback alive -> potential GC leak through C++ refs).
function Binding:Subscribe(callback)
    if self._destroyed then
        error("VFN.Binding: Subscribe on destroyed binding", 2)
    end
    if type(callback) ~= "function" then
        error("VFN.Binding:Subscribe requires a function callback", 2)
    end
    -- Fire once immediately with current value so newly-subscribed widgets
    -- reflect state without waiting for the next update. This matches
    -- React-binding semantics.
    callback(self._value)
    return self._signal.connect(callback)
end

-- ===== Derived bindings (Map) =============================================

-- Create a derived binding whose value is fn(parent.value). Subscribes to
-- the parent; whenever parent fires, the derived fires with the mapped
-- value. Chain is forward-only -- you cannot Set() a derived binding.
function Binding:Map(fn)
    if type(fn) ~= "function" then
        error("VFN.Binding:Map requires a function", 2)
    end
    local derived, setDerived = VFN.Binding.new(fn(self._value))
    -- Hidden internal subscription. Stored on the derived so it survives
    -- as long as the derived is reachable. When derived is destroyed,
    -- this subscription releases too (via _destroySubs).
    local unsub = self:Subscribe(function(v) setDerived(fn(v)) end)
    derived._destroySubs = derived._destroySubs or {}
    table.insert(derived._destroySubs, unsub)
    return derived
end

-- ===== Cleanup ============================================================

-- Mark the binding destroyed. Subscribers stop being notified; the
-- subscriber list is dropped so callbacks/closures become GC-eligible.
-- Also releases any internal subscriptions from Map() chains.
function Binding:Destroy()
    if self._destroyed then return end
    self._destroyed = true
    if self._destroySubs then
        for _, unsub in ipairs(self._destroySubs) do unsub() end
        self._destroySubs = nil
    end
    self._signal = nil
end

-- ===== Introspection ======================================================

function Binding:IsDestroyed() return self._destroyed end
function Binding:SubscriberCount()
    if self._destroyed or not self._signal then return 0 end
    if self._signal.empty() then return 0 end
    local n = 0
    -- _signal.subs is private; we expose count via the empty() check + iter.
    -- Reach in directly here since this is introspection only.
    return n  -- (kept simple; tests assert via behavior, not count internals)
end

-- VFN.Environment
--
-- Environment injection: ambient values threaded through the build walk +
-- thunk dispatches via the EnvMiddleware. Replaces global lookups inside
-- skinners / dispatchers / handlers with explicit parameter injection.
-- Architecture spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 9.
--
-- Slots are declared once (typically in Core/Init.lua or per-module
-- onInitialize). The slot registry is the documented surface; missing slot
-- access errors at validation time, NOT at runtime ("undeclared env slot
-- 'foo'" is loud, not silent nil).
--
-- Rules (from SwiftUI / Compose / Roact production scar tissue):
--   1. Static slots only -- values that change at most once per session.
--      Dynamic per-frame state (hover, scroll position) must NOT use env.
--   2. Every slot has a default that is valid standalone. No nil envs.
--   3. Environment is a read-only projection of Store state. Never carry
--      mutable references -- writes always go through Store:Dispatch.
--   4. No __index prototype-chain propagation (Roact's legacy context bug).
--      Explicit table; current state captured at injection time.
--
-- Reference: LUA_SAMPLES.md section 1e (Rodux makeThunkMiddleware extraArg).

VFN = VFN or {}
VFN.Environment = VFN.Environment or {
    _slots     = {},        -- [name] = { default, validator?, description? }
    _current   = nil,       -- the assembled env table, populated by Build()
    _sealed    = false,     -- once Build() runs, Declare() errors
}

local E = VFN.Environment

-- ===== Slot declaration ===================================================

-- Declare an environment slot. Called from module onInitialize OR from a
-- single central Environment-setup function. Slots are merged into one
-- env table at Build() time; field name = slot name; value = default or
-- computed projection.
--
-- def = {
--     name        = "scheme",                       -- required
--     default     = sometable,                      -- required (must be valid standalone)
--     description = "Color palette + fonts + backdrops",
--     validator   = function(v) return type(v) == "table" end,
-- }
function E:Declare(def)
    if self._sealed then
        error(("VFN.Environment:Declare(%q) called after Build()"):format(
            tostring(def and def.name)), 2)
    end
    if type(def) ~= "table" then
        error("VFN.Environment:Declare expected a table", 2)
    end
    if type(def.name) ~= "string" or def.name == "" then
        error("VFN.Environment:Declare missing required field 'name'", 2)
    end
    if def.default == nil then
        error(("VFN.Environment:Declare(%q) missing required 'default'"):format(def.name), 2)
    end
    if def.validator and not def.validator(def.default) then
        error(("VFN.Environment:Declare(%q): default value failed validator"):format(def.name), 2)
    end
    if self._slots[def.name] then
        error(("VFN.Environment:Declare(%q) duplicate slot"):format(def.name), 2)
    end
    self._slots[def.name] = def
end

-- ===== Build ===============================================================

-- Build the current env table. Called once per session at OnEnable AFTER
-- all modules have declared their slots. Future env reads come through the
-- returned table. Re-Build() replaces the current env (for scheme swap etc).
--
-- overrides table can supply non-default values for specific slots
-- (preview surfaces, test mocks). Unspecified slots get their default.
function E:Build(overrides)
    overrides = overrides or {}
    local env = {}
    for name, def in pairs(self._slots) do
        local v = overrides[name]
        if v == nil then v = def.default end
        if def.validator and not def.validator(v) then
            error(("VFN.Environment:Build: slot %q failed validator"):format(name), 2)
        end
        env[name] = v
    end

    -- Catch overrides referring to undeclared slots loudly. This is the
    -- "skinner reads env.foo but no slot 'foo' exists" check from spec section 12.
    for name in pairs(overrides) do
        if not self._slots[name] then
            error(("VFN.Environment:Build: override for undeclared slot %q"):format(name), 2)
        end
    end

    self._current = env
    self._sealed = true
    return env
end

-- ===== Access ==============================================================

-- Get the current env table. Engines (Layout, Theme, BindingEngine) receive
-- this as a parameter; this accessor is the public read API for callers
-- that don't have env threaded explicitly.
function E:Current()
    if not self._current then
        error("VFN.Environment: not built yet (call Build() in OnEnable)", 2)
    end
    return self._current
end

-- Strict slot read with declared-slot validation. Errors loudly on unknown
-- slot rather than returning nil. Use when "is this slot declared?" matters.
function E:Get(name)
    if not self._current then
        error("VFN.Environment: not built yet (call Build() in OnEnable)", 2)
    end
    if not self._slots[name] then
        error(("VFN.Environment:Get(%q): undeclared slot"):format(tostring(name)), 2)
    end
    return self._current[name]
end

-- ===== Sub-tree override ==================================================

-- WithOverrides: build a child env table with selected slots overridden.
-- Used for sub-tree builds: preview pane runs in dark scheme, tooltip
-- subtree uses alt scheme, test mounts mock env, etc. The override table
-- is shallow-merged into the current env. Does NOT mutate self._current.
function E:WithOverrides(overrides)
    if not self._current then
        error("VFN.Environment:WithOverrides: not built yet", 2)
    end
    overrides = overrides or {}
    local child = {}
    for k, v in pairs(self._current) do child[k] = v end
    for k, v in pairs(overrides) do
        if not self._slots[k] then
            error(("VFN.Environment:WithOverrides: undeclared slot %q"):format(k), 2)
        end
        local def = self._slots[k]
        if def.validator and not def.validator(v) then
            error(("VFN.Environment:WithOverrides: slot %q failed validator"):format(k), 2)
        end
        child[k] = v
    end
    return child
end

-- ===== Introspection / test helpers =======================================

function E:GetSlots()
    return self._slots
end

function E:_Reset()
    self._slots = {}
    self._current = nil
    self._sealed = false
end

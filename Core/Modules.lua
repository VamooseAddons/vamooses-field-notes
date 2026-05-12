-- VFN.Modules
--
-- Module declaration registry + dependency topo-sort + two-phase loader.
-- Architecture spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 14.
--
-- Modules declare themselves at file-load time via Modules:Declare(def).
-- After all module files have loaded, Modules:Boot() is called by Init.lua
-- on ADDON_LOADED. Boot performs:
--   1. Topo-sort registered modules by `dependencies` field
--   2. Phase 1 (Init): call onInitialize on each module in dependency order
--   3. Phase 2 (Start): call onEnable on each module in dependency order,
--      deferred one frame each via C_Timer.After so individual onEnable
--      failures don't block other modules from starting.
--
-- Knit's two-phase invariant: onInitialize MUST NOT call into other modules
-- (they may not be initialized yet). Use onEnable for cross-module wiring.
--
-- Lua reference: Project Documentation/sample-lua-references/LUA_SAMPLES_LIFECYCLE.md
--   section 1 (Knit two-phase lifecycle) + section 4 (AwesomeWM topo-sort).

VFN = VFN or {}
VFN.Modules = VFN.Modules or {
    _registry = {},                 -- [name] = def
    _order    = nil,                -- topo-sorted list, populated by Boot()
    _booted   = false,
    _initDone = false,
    _started  = false,
}

local M = VFN.Modules

-- ===== Topological sort (AwesomeWM-derived) ===============================
-- DFS with HANDLING (in current path -> cycle) and DONE (already emitted)
-- sentinel states. Returns (orderedList, nil) on success or (nil, cycleNode)
-- on cycle detection.

local HANDLING, DONE = 1, 2

local function visit(result, edges, state, node)
    if state[node] == DONE then return end
    if state[node] == HANDLING then
        result._cycle = node
        return true
    end

    state[node] = HANDLING
    for dep in pairs(edges[node] or {}) do
        if visit(result, edges, state, dep) then return true end
    end
    state[node] = DONE
    result[#result + 1] = node
end

local function toposort(registry)
    local edges = {}
    for name, def in pairs(registry) do
        edges[name] = {}
        for _, dep in ipairs(def.dependencies or {}) do
            edges[name][dep] = true
        end
    end
    local result, state = {}, {}
    for node in pairs(edges) do
        if visit(result, edges, state, node) then
            return nil, result._cycle
        end
    end
    return result
end

-- ===== Public API =========================================================

-- Register a module. Called from each module file at TOC load time.
-- def = {
--     name         = "ModuleName",           -- required, unique
--     dependencies = { "Other", "Module" },  -- list of module names
--     onInitialize = function(self) end,     -- Phase 1: self-setup only
--     onEnable     = function(self) end,     -- Phase 2: cross-module wiring
-- }
function M:Declare(def)
    if type(def) ~= "table" then
        error("VFN.Modules:Declare expected a table, got " .. type(def), 2)
    end
    if type(def.name) ~= "string" or def.name == "" then
        error("VFN.Modules:Declare missing required field 'name'", 2)
    end
    if self._booted then
        error(("VFN.Modules:Declare(%q) called after Boot()"):format(def.name), 2)
    end
    if self._registry[def.name] then
        error(("VFN.Modules:Declare(%q) duplicate registration"):format(def.name), 2)
    end
    if def.dependencies ~= nil and type(def.dependencies) ~= "table" then
        error(("VFN.Modules:Declare(%q): dependencies must be a list"):format(def.name), 2)
    end
    self._registry[def.name] = def
end

-- Boot: topo-sort + Phase 1 (Init) + Phase 2 (Start).
-- Called from Init.lua's OnInitialize handler.
function M:Boot()
    if self._booted then return end
    self._booted = true

    -- Verify all referenced dependencies are registered.
    for name, def in pairs(self._registry) do
        for _, dep in ipairs(def.dependencies or {}) do
            if not self._registry[dep] then
                error(("Module %q depends on unregistered module %q"):format(name, dep), 2)
            end
        end
    end

    local order, cycle = toposort(self._registry)
    if not order then
        error(("VFN.Modules: dependency cycle involving %q"):format(tostring(cycle)), 2)
    end
    self._order = order

    -- Phase 1: synchronous Init in dependency order. All Init calls must
    -- complete before any onEnable runs (Knit invariant).
    for _, name in ipairs(self._order) do
        local def = self._registry[name]
        if def.onInitialize then
            local ok, err = pcall(def.onInitialize, def)
            if not ok then
                error(("Module %q onInitialize failed: %s"):format(name, tostring(err)), 2)
            end
        end
    end
    self._initDone = true

    -- Phase 2: Start. Each onEnable is deferred one frame via C_Timer.After
    -- so a single module's onEnable failure doesn't block siblings.
    for _, name in ipairs(self._order) do
        local def = self._registry[name]
        if def.onEnable then
            C_Timer.After(0, function()
                local ok, err = pcall(def.onEnable, def)
                if not ok then
                    print(("|cffff5555[VFN] Module %q onEnable failed: %s|r")
                        :format(name, tostring(err)))
                end
            end)
        end
    end
    self._started = true
end

-- Get a registered module's definition. Used by sibling modules in onEnable
-- to access each other; safe after Phase 1 completes.
function M:Get(name)
    local def = self._registry[name]
    if not def then
        error(("VFN.Modules:Get(%q): module not registered. Check spelling or TOC order."):format(tostring(name)), 2)
    end
    return def
end

-- Test/debug helper. Returns the topo-sorted order (or nil if Boot hasn't run).
function M:GetOrder()
    return self._order
end

-- Test helper: reset registry between test runs. NEVER call in production.
function M:_Reset()
    self._registry = {}
    self._order    = nil
    self._booted   = false
    self._initDone = false
    self._started  = false
end

-- VFN.ControllerHelpers.Mechanics
--
-- The "talk to the Store" half of CH. State readers + dispatch wrappers +
-- domain actions. No widget access, no paint, no UI workflow.
--
-- All Store mutation goes through here -- controllers don't reach into
-- VFN.Store directly. Single choke point for cross-cutting concerns
-- (debug logging, future throttling, audit trail).

VFN = VFN or {}
VFN.ControllerHelpers = VFN.ControllerHelpers or {}
VFN.ControllerHelpers.Mechanics = VFN.ControllerHelpers.Mechanics or {}

local Mech = VFN.ControllerHelpers.Mechanics

-- ===== State readers ======================================================

function Mech.GetState()
    return VFN.Store and VFN.Store.GetState and VFN.Store:GetState() or nil
end

-- Merged read-only UI view: union of account.ui (persisted) + session.ui
-- (transient). Keys live in EXACTLY ONE bucket, but callers shouldn't have
-- to know which -- they read selectedSetID and selectedGroupKey the same way.
-- The reducer (VFN_UI_SET) routes writes to the correct bucket via its
-- PERSISTENT_UI_KEYS / SESSION_UI_KEYS tables.
function Mech.GetUI()
    local s = Mech.GetState()
    if not s then return {} end
    local merged = {}
    if s.account and s.account.ui then
        for k, v in pairs(s.account.ui) do merged[k] = v end
    end
    if s.session and s.session.ui then
        for k, v in pairs(s.session.ui) do merged[k] = v end
    end
    return merged
end

-- Explicit accessors for the rare case a caller really does need to know
-- which bucket a value lives in (debugging, persistence inspection).
function Mech.GetAccountUI()
    local s = Mech.GetState()
    return s and s.account and s.account.ui or {}
end
function Mech.GetSessionUI()
    local s = Mech.GetState()
    return s and s.session and s.session.ui or {}
end

-- View-local scratch state lives at state.session.viewLocal[view][key].
-- Use this instead of reaching into state.session.* directly.
function Mech.GetViewLocal(view)
    local s = Mech.GetState()
    if not (s and s.session and s.session.viewLocal) then return {} end
    return s.session.viewLocal[view] or {}
end

function Mech.GetSelectedSet()
    local s = Mech.GetState()
    if not s then return nil, nil, nil end
    local selectedSetID = s.account and s.account.ui and s.account.ui.selectedSetID
    local set = selectedSetID and s.account.sets and s.account.sets[selectedSetID] or nil
    if not set or set.deletedAt then return nil, nil, s end
    return selectedSetID, set, s
end

-- Player's current map ID. Returns nil in test environments without C_Map.
function Mech.GetCurrentMapID()
    local C_MapAPI = _G and _G.C_Map
    return C_MapAPI and C_MapAPI.GetBestMapForUnit and C_MapAPI.GetBestMapForUnit("player") or nil
end

function Mech.GetConfigValue(key, fallback)
    local s = Mech.GetState()
    local cfg = s and s.account and s.account.config or nil
    local v = cfg and cfg[key] or nil
    if v == nil then return fallback end
    return v
end

-- ===== Dispatch wrappers + domain actions =================================

-- Generic action dispatch wrapper. Single throat for cross-cutting concerns.
function Mech.Dispatch(action, payload)
    if VFN.Store and VFN.Store.Dispatch then
        VFN.Store:Dispatch(action, payload)
    end
end

function Mech.DispatchUI(key, value)
    if VFN.Store and VFN.Store.Dispatch then
        VFN.Store:Dispatch("VFN_UI_SET", { key = key, value = value })
    end
end

function Mech.DispatchViewLocal(view, key, value)
    if VFN.Store and VFN.Store.Dispatch then
        VFN.Store:Dispatch("VFN_VIEWLOCAL_SET", { view = view, key = key, value = value })
    end
end

function Mech.CloseSet()
    if VFN.Store and VFN.Store.CloseSet then VFN.Store:CloseSet() end
end

function Mech.OpenSet(setID)
    if VFN.Store and VFN.Store.OpenSet then VFN.Store:OpenSet(setID) end
end

function Mech.DeleteSet(setID)
    if VFN.Store and VFN.Store.DeleteSet then VFN.Store:DeleteSet(setID) end
end

-- CreateSet returns the created { setID, set } table so callers can chain
-- (e.g. open the new set immediately).
function Mech.CreateSet(payload)
    if VFN.Store and VFN.Store.CreateSet then return VFN.Store:CreateSet(payload) end
    return nil
end

-- ===== Cycle helpers ======================================================

-- Advance an enum-style config value to the next entry in `order`. Used by
-- cycle buttons (waypointBackend, characterFilter, etc).
function Mech.CycleConfigValue(key, order, fallback)
    local current = Mech.GetConfigValue(key, fallback)
    local nextIndex = 1
    for index, value in ipairs(order) do
        if value == current then nextIndex = index + 1; break end
    end
    if nextIndex > #order then nextIndex = 1 end
    local nextValue = order[nextIndex]
    Mech.Dispatch("VFN_CONFIG_SET", { key = key, value = nextValue })
    return nextValue
end

-- Same shape but for UI-state keys (sendScope etc).
function Mech.CycleUIValue(key, order)
    local ui = Mech.GetUI()
    local current = ui[key]
    local nextIndex = 1
    for index, value in ipairs(order) do
        if value == current then nextIndex = index + 1; break end
    end
    if nextIndex > #order then nextIndex = 1 end
    Mech.DispatchUI(key, order[nextIndex])
end

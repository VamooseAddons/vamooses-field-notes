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
    return VFN.Store:GetState()
end

-- Merged read-only UI view: union of account.ui (persisted) + session.ui
-- (transient). Keys live in EXACTLY ONE bucket, but callers shouldn't have
-- to know which -- they read selectedSetID and selectedGroupKey the same
-- way. WRITES go through the explicit bucket-aware helpers below
-- (SetUIPersistent / SetUITransient / SetUITransientView) which dispatch
-- to UI_SET_PERSISTENT / UI_SET_TRANSIENT actions -- the bucket choice
-- lives at the call site, not in a routing table.
--
-- Note: session.ui has nested sub-tables (.library / .stream / .config)
-- for per-view scratch state. The merge exposes those as merged.library /
-- merged.stream / merged.config -- but typical callers use the explicit
-- per-view reader Mech.GetUIView(view) instead.
function Mech.GetUI()
    local s = Mech.GetState()
    local merged = {}
    for k, v in pairs(s.account.ui) do merged[k] = v end
    for k, v in pairs(s.session.ui) do merged[k] = v end
    return merged
end

-- Per-view scratch state lives at state.session.ui[view][key] after the
-- viewLocal/ui bucket merge (#11.2). Use this instead of reaching into the
-- session tree directly so future renames are local to this helper.
function Mech.GetUIView(view)
    return Mech.GetState().session.ui[view] or {}
end

function Mech.GetSelectedSet()
    local s = Mech.GetState()
    local selectedSetID = s.account.ui.selectedSetID
    local set = selectedSetID and s.account.sets[selectedSetID] or nil
    if not set or set.deletedAt then return nil, nil, s end
    return selectedSetID, set, s
end

-- Player's current map ID. Returns nil in test environments without C_Map.
function Mech.GetCurrentMapID()
    local C_MapAPI = _G and _G.C_Map
    return C_MapAPI and C_MapAPI.GetBestMapForUnit and C_MapAPI.GetBestMapForUnit("player") or nil
end

function Mech.GetConfigValue(key, fallback)
    local v = Mech.GetState().account.config[key]
    if v == nil then return fallback end
    return v
end

-- ===== Dispatch wrappers + domain actions =================================

-- Generic action dispatch wrapper. Single throat for cross-cutting concerns.
-- Accepts (actionType, payload) positional form for caller ergonomics and
-- bundles into the canonical { type, payload } table Store:Dispatch expects.
function Mech.Dispatch(actionType, payload)
    VFN.Store:Dispatch({ type = actionType, payload = payload })
end

-- UI state has two buckets:
--   account.ui  -- persists across /reload (selection, layout prefs)
--   session.ui  -- cleared on /reload (transient nav state)
-- Pick the right helper at the call site -- the bucket choice is now part
-- of the action's name, not an external routing table.
function Mech.SetUIPersistent(key, value)
    VFN.Store:Dispatch({
        type = VFN.Constants.ACTIONS.UI_SET_PERSISTENT,
        payload = { key = key, value = value },
    })
end

function Mech.SetUITransient(key, value)
    VFN.Store:Dispatch({
        type = VFN.Constants.ACTIONS.UI_SET_TRANSIENT,
        payload = { key = key, value = value },
    })
end

-- Per-view variant. Same action; payload.view picks the sub-bucket.
-- session.ui[view][key] = value. Used by Library / Stream controllers
-- for find-state, dropdown selections, edit staging, etc.
function Mech.SetUITransientView(view, key, value)
    VFN.Store:Dispatch({
        type = VFN.Constants.ACTIONS.UI_SET_TRANSIENT,
        payload = { view = view, key = key, value = value },
    })
end

function Mech.CloseSet()
    VFN.Store:CloseSet()
end

function Mech.OpenSet(setID)
    VFN.Store:OpenSet(setID)
end

function Mech.DeleteSet(setID)
    VFN.Store:DeleteSet(setID)
end

-- CreateSet returns the created { setID, set } table so callers can chain
-- (e.g. open the new set immediately).
function Mech.CreateSet(payload)
    return VFN.Store:CreateSet(payload)
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
    Mech.Dispatch(VFN.Constants.ACTIONS.CONFIG_SET, { key = key, value = nextValue })
    return nextValue
end

-- Same shape but for transient UI keys (sendScope etc). Reads from session.ui
-- and writes via SetUITransient. If a future cycle needs a persistent UI
-- key, add a CycleUIPersistent twin -- explicit beats clever.
function Mech.CycleUIValue(key, order)
    local current = VFN.Store:GetState().session.ui[key]
    local nextIndex = 1
    for index, value in ipairs(order) do
        if value == current then nextIndex = index + 1; break end
    end
    if nextIndex > #order then nextIndex = 1 end
    Mech.SetUITransient(key, order[nextIndex])
end

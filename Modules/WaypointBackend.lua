VFN = VFN or {}
VFN.WaypointBackend = VFN.WaypointBackend or {}

local ADDON_TAG = "VFN"
local DEFAULT_PROVIDER = "auto"
local PROVIDER_BLIZZARD = "blizzard"
local PROVIDER_TOMTOM = "tomtom"
local MIN_COORD = 0
local MAX_COORD = 1
local COORD_EPSILON = 0.000001

function VFN.WaypointBackend:Initialize()
end

local function AddError(result, code)
    result.errors[#result.errors + 1] = code
end

local function NewResult(provider)
    return {
        ok = false,
        provider = provider,
        sent = 0,
        activeEntryID = nil,
        errors = {},
    }
end

local function GetConfig()
    local state = VFN.Store and VFN.Store.GetState and VFN.Store:GetState() or nil
    local account = state and state.account or nil
    return account and account.config or state and state.config or nil
end

local function GetConfiguredProvider()
    local config = GetConfig()
    return config and config.waypointBackend or DEFAULT_PROVIDER
end

local function TomTomUsable()
    local tomtom = _G and _G.TomTom or nil
    return tomtom and type(tomtom.AddWaypoint) == "function"
end

local function BlizzardSendUsable()
    local mapAPI = _G and _G.C_Map or nil
    local pointAPI = _G and _G.UiMapPoint or nil
    return mapAPI
        and type(mapAPI.SetUserWaypoint) == "function"
        and pointAPI
        and type(pointAPI.CreateFromCoordinates) == "function"
end

local function BlizzardClearUsable()
    local mapAPI = _G and _G.C_Map or nil
    return mapAPI and type(mapAPI.ClearUserWaypoint) == "function"
end

local function IsValidEntry(entry)
    if type(entry) ~= "table" then return false end
    if type(entry.coordMapID) ~= "number" then return false end
    if type(entry.x) ~= "number" or type(entry.y) ~= "number" then return false end
    return entry.x >= MIN_COORD and entry.x <= MAX_COORD and entry.y >= MIN_COORD and entry.y <= MAX_COORD
end

function VFN.WaypointBackend:IsValidEntry(entry)
    return IsValidEntry(entry)
end

local function GetValidEntries(entries)
    local out = {}
    for _, entry in ipairs(entries or {}) do
        if IsValidEntry(entry) then
            out[#out + 1] = entry
        end
    end
    return out
end

local function GetEntryID(entry, index)
    return entry.id or ("entry:" .. tostring(index))
end

local function GetEntryIDSet(entries)
    local out = {}
    local count = 0
    local validEntries = GetValidEntries(entries)
    for index, entry in ipairs(validEntries) do
        local entryID = GetEntryID(entry, index)
        if not out[entryID] then
            out[entryID] = true
            count = count + 1
        end
    end
    return out, count
end

local function GetTitle(entry, set)
    if entry.label and entry.label ~= "" then return entry.label end
    if entry.mapName and entry.mapName ~= "" then return entry.mapName end
    if set and set.title and set.title ~= "" then return set.title end
    return "Field Note"
end

local function EnsureSendState(set)
    if type(set) ~= "table" then return nil end
    set.sendState = set.sendState or {}
    return set.sendState
end

local function ClearSendState(sendState)
    if not sendState then return end
    sendState.backend = nil
    sendState.sentAt = nil
    sendState.sentEntryIDs = nil
    sendState.activeEntryID = nil
    sendState.activeMapID = nil
    sendState.activeX = nil
    sendState.activeY = nil
    sendState.waypoints = nil
end

local function RefreshPinState(validEntries, set)
    local pins = VFN and VFN.WorldMapPins or nil
    if not pins then return end

    if type(pins.SetSentEntries) == "function" then
        pcall(function()
            pins:SetSentEntries(validEntries or {}, set)
        end)
    elseif type(pins.Refresh) == "function" then
        pcall(function()
            pins:Refresh()
        end)
    end
end

local function MarkStoreDirty()
    if VFN.Store and VFN.Store.QueueSave then
        VFN.Store:QueueSave()
    end
end

local function StoreSendState(set, provider, validEntries, activeEntryID, handles)
    local sendState = EnsureSendState(set)
    if not sendState then return end

    sendState.backend = provider
    sendState.sentAt = time and time() or nil
    sendState.sentEntryIDs = {}
    for index, entry in ipairs(validEntries or {}) do
        sendState.sentEntryIDs[#sendState.sentEntryIDs + 1] = GetEntryID(entry, index)
    end
    sendState.activeEntryID = activeEntryID
    local activeEntry = validEntries and validEntries[1] or nil
    sendState.activeMapID = activeEntry and activeEntry.coordMapID or nil
    sendState.activeX = activeEntry and activeEntry.x or nil
    sendState.activeY = activeEntry and activeEntry.y or nil
    sendState.waypoints = handles
    RefreshPinState(validEntries, set)
    MarkStoreDirty()
end

local function ClearStoredState(set)
    local sendState = EnsureSendState(set)
    ClearSendState(sendState)
    RefreshPinState({}, set)
    MarkStoreDirty()
end

local function RemoveScopedSentIDs(sendState, scopedIDs)
    local remaining = {}
    local removed = 0
    for _, entryID in ipairs(sendState and sendState.sentEntryIDs or {}) do
        if scopedIDs[entryID] then
            removed = removed + 1
        else
            remaining[#remaining + 1] = entryID
        end
    end
    if sendState then
        sendState.sentEntryIDs = remaining
    end
    return removed, remaining
end

local function KeepStateIfSentIDsRemain(set, remainingIDs)
    if remainingIDs and #remainingIDs > 0 then
        RefreshPinState({}, set)
        MarkStoreDirty()
        return
    end
    ClearStoredState(set)
end

local function ReadMapPoint(point)
    if type(point) ~= "table" and type(point) ~= "userdata" then return nil, nil, nil end

    local mapID = point.mapID or point.uiMapID
    if type(point.GetMapID) == "function" then
        local ok, value = pcall(function()
            return point:GetMapID()
        end)
        if ok then mapID = value end
    end

    local x = point.x
    local y = point.y
    if type(point.GetXY) == "function" then
        local ok, px, py = pcall(function()
            return point:GetXY()
        end)
        if ok then
            x = px
            y = py
        end
    end

    return mapID, x, y
end

local function SameCoord(a, b)
    if type(a) ~= "number" or type(b) ~= "number" then return false end
    return math.abs(a - b) <= COORD_EPSILON
end

local function CurrentUserWaypointMatches(sendState)
    local mapAPI = _G and _G.C_Map or nil
    if not mapAPI or type(mapAPI.GetUserWaypoint) ~= "function" then return false, "unverifiable" end

    local ok, point = pcall(function()
        return mapAPI.GetUserWaypoint()
    end)
    if not ok or not point then return false, "no_current_waypoint" end

    local mapID, x, y = ReadMapPoint(point)
    if mapID == sendState.activeMapID and SameCoord(x, sendState.activeX) and SameCoord(y, sendState.activeY) then
        return true
    end
    return false, "current_waypoint_mismatch"
end

local function RemoveTomTomHandles(handles, scopedIDs)
    local tomtom = _G and _G.TomTom or nil
    if not tomtom or type(tomtom.RemoveWaypoint) ~= "function" then return 0 end

    local count = 0
    local remaining = {}
    for _, record in ipairs(handles or {}) do
        local handle = record and record.handle or record
        local entryID = record and record.entryID or handle and handle.entryID
        if entryID and scopedIDs[entryID] then
            local ok = pcall(function()
                tomtom:RemoveWaypoint(handle)
            end)
            if ok then count = count + 1 end
        else
            remaining[#remaining + 1] = record
        end
    end
    return count, remaining
end

local function RemoveTomTomHandleList(handles)
    local tomtom = _G and _G.TomTom or nil
    if not tomtom or type(tomtom.RemoveWaypoint) ~= "function" then return 0 end

    local count = 0
    for _, handle in ipairs(handles or {}) do
        local ok = pcall(function()
            tomtom:RemoveWaypoint(handle)
        end)
        if ok then count = count + 1 end
    end
    return count
end

local function RemoveTomTomTaggedWaypoints(scopedIDs)
    local tomtom = _G and _G.TomTom or nil
    if not tomtom or type(tomtom.RemoveWaypoint) ~= "function" or type(tomtom.waypoints) ~= "table" then
        return 0
    end

    local toRemove = {}
    for _, waypoints in pairs(tomtom.waypoints) do
        if type(waypoints) == "table" then
            for _, waypoint in pairs(waypoints) do
                if type(waypoint) == "table" and waypoint.from == ADDON_TAG and waypoint.entryID and scopedIDs[waypoint.entryID] then
                    toRemove[#toRemove + 1] = waypoint
                end
            end
        end
    end

    return RemoveTomTomHandleList(toRemove)
end

function VFN.WaypointBackend:GetProvider()
    local configured = GetConfiguredProvider()
    if configured == PROVIDER_BLIZZARD then return PROVIDER_BLIZZARD end
    if configured == PROVIDER_TOMTOM then
        return TomTomUsable() and PROVIDER_TOMTOM or PROVIDER_BLIZZARD
    end
    return TomTomUsable() and PROVIDER_TOMTOM or PROVIDER_BLIZZARD
end

function VFN.WaypointBackend:Send(entries, set)
    local provider = self:GetProvider()
    local result = NewResult(provider)
    -- Combat guard: SetUserWaypoint + super-track manipulation are not
    -- protected today but TomTom and other backends touch user UI that
    -- has hooked secure handlers. Fail soft with a clear error rather
    -- than silently tainting.
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        AddError(result, "in_combat")
        return result
    end
    local validEntries = GetValidEntries(entries)
    if #validEntries == 0 then
        AddError(result, "no_valid_entries")
        return result
    end

    if provider == PROVIDER_TOMTOM then
        local tomtom = _G and _G.TomTom or nil
        if not tomtom or type(tomtom.AddWaypoint) ~= "function" then
            AddError(result, "tomtom_unavailable")
            return result
        end

        local handles = {}
        for index, entry in ipairs(validEntries) do
            local entryID = GetEntryID(entry, index)
            local ok, handle = pcall(function()
                return tomtom:AddWaypoint(entry.coordMapID, entry.x, entry.y, {
                    title = GetTitle(entry, set),
                    from = ADDON_TAG,
                    persistent = false,
                    entryID = entryID,
                })
            end)
            if ok and handle then
                handles[#handles + 1] = { handle = handle, entryID = entryID }
            else
                AddError(result, "tomtom_add_failed")
            end
        end

        result.sent = #handles
        result.ok = result.sent > 0
        result.activeEntryID = validEntries[1] and GetEntryID(validEntries[1], 1) or nil
        if result.ok then
            StoreSendState(set, PROVIDER_TOMTOM, validEntries, result.activeEntryID, handles)
        end
        return result
    end

    if not BlizzardSendUsable() then
        AddError(result, "blizzard_unavailable")
        return result
    end

    local first = validEntries[1]
    local mapAPI = _G.C_Map
    if mapAPI.CanSetUserWaypointOnMap then
        local canSetOK, canSet = pcall(function()
            return mapAPI.CanSetUserWaypointOnMap(first.coordMapID)
        end)
        if not canSetOK or not canSet then
            AddError(result, "map_unsupported")
            return result
        end
    end

    local ok, point = pcall(function()
        return _G.UiMapPoint.CreateFromCoordinates(first.coordMapID, first.x, first.y)
    end)
    if not ok or not point then
        AddError(result, "point_create_failed")
        return result
    end

    ok = pcall(function()
        mapAPI.SetUserWaypoint(point)
    end)
    if not ok then
        AddError(result, "blizzard_set_failed")
        return result
    end

    local superTrack = _G and _G.C_SuperTrack or nil
    if superTrack and type(superTrack.SetSuperTrackedUserWaypoint) == "function" then
        pcall(function()
            superTrack.SetSuperTrackedUserWaypoint(true)
        end)
    end

    result.ok = true
    result.sent = 1
    result.activeEntryID = GetEntryID(first, 1)
    StoreSendState(set, PROVIDER_BLIZZARD, validEntries, result.activeEntryID, nil)
    return result
end

function VFN.WaypointBackend:Remove(entries, set)
    local sendState = set and set.sendState or nil
    local provider = sendState and sendState.backend or self:GetProvider()
    local result = NewResult(provider)
    local scopedIDs, scopedCount = GetEntryIDSet(entries)
    if scopedCount == 0 then
        AddError(result, "no_scoped_waypoints")
        return result
    end

    if provider == PROVIDER_TOMTOM then
        local tomtom = _G and _G.TomTom or nil
        if not tomtom or type(tomtom.RemoveWaypoint) ~= "function" then
            AddError(result, "tomtom_unavailable")
            return result
        end

        local removed, remainingHandles = RemoveTomTomHandles(sendState and sendState.waypoints or nil, scopedIDs)
        if removed == 0 then
            removed = RemoveTomTomTaggedWaypoints(scopedIDs)
        end
        if sendState then
            sendState.waypoints = remainingHandles or {}
        end
        local removedIDs, remainingIDs = RemoveScopedSentIDs(sendState, scopedIDs)
        if sendState and sendState.activeEntryID and scopedIDs[sendState.activeEntryID] then
            sendState.activeEntryID = remainingIDs[1]
        end
        result.sent = removed
        result.ok = removed > 0 or removedIDs > 0
        if result.ok then
            KeepStateIfSentIDsRemain(set, remainingIDs)
        else
            AddError(result, "no_vfn_waypoint")
        end
        return result
    end

    if not sendState or sendState.backend ~= PROVIDER_BLIZZARD then
        AddError(result, "no_vfn_waypoint")
        return result
    end

    local activeInScope = sendState.activeEntryID and scopedIDs[sendState.activeEntryID] == true
    if activeInScope then
        local matches = CurrentUserWaypointMatches(sendState)
        if matches and BlizzardClearUsable() then
            pcall(function()
                _G.C_Map.ClearUserWaypoint()
            end)
            result.sent = 1
        end
        sendState.activeEntryID = nil
        sendState.activeMapID = nil
        sendState.activeX = nil
        sendState.activeY = nil
    end

    local removedIDs, remainingIDs = RemoveScopedSentIDs(sendState, scopedIDs)
    result.ok = activeInScope or removedIDs > 0
    result.activeEntryID = sendState.activeEntryID
    if result.ok then
        KeepStateIfSentIDsRemain(set, remainingIDs)
    else
        AddError(result, "no_vfn_waypoint")
    end
    return result
end

function VFN.WaypointBackend:SetWaypoint(entry, set)
    local result = self:Send(entry and { entry } or {}, set)
    return result.ok, result.errors[1]
end

function VFN.WaypointBackend:ClearWaypoint()
    local result = self:Remove({}, nil)
    return result.ok, result.errors[1]
end

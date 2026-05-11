VFN = VFN or {}

local API_VERSION = 1

local function Trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function NonEmpty(value)
    local text = Trim(value)
    if text == "" then return nil end
    return text
end

local function PositiveMapID(value)
    local numeric = tonumber(value)
    if numeric and numeric > 0 and numeric == math.floor(numeric) then
        return numeric
    end
    return nil
end

local function Now()
    if type(time) == "function" then return time() end
    return 0
end

local function CopyRef(ref)
    if type(ref) ~= "table" then
        return { addon = nil, type = nil, id = nil, payloadVersion = nil }
    end

    return {
        addon = ref.addon,
        type = ref.type,
        id = ref.id,
        payloadVersion = ref.payloadVersion,
    }
end

local function CopyCurrency(currency)
    if type(currency) ~= "table" then
        return { id = nil, amount = nil }
    end

    return {
        id = currency.id,
        amount = currency.amount,
    }
end

local function SourceFromPayload(payload)
    local source = type(payload.source) == "table" and payload.source or {}
    local addon = NonEmpty(payload.sourceAddon) or NonEmpty(source.addon) or NonEmpty(payload.owner) or NonEmpty(source.owner)

    return {
        type = NonEmpty(payload.sourceType) or NonEmpty(source.type) or "api",
        owner = NonEmpty(payload.owner) or NonEmpty(source.owner) or addon,
        addon = addon,
        key = NonEmpty(payload.sourceKey) or NonEmpty(source.key),
        version = payload.sourceVersion or source.version or payload.version or API_VERSION,
    }
end

local function VisibilityFromPayload(payload)
    local visibility = type(payload.visibility) == "table" and payload.visibility or {}

    return {
        scope = payload.scope or visibility.scope or "account",
        character = payload.character or visibility.character,
    }
end

local function MapNameFor(mapID, mapName)
    if mapName then return mapName end
    if VFN.MapAliasDB and VFN.MapAliasDB.mapNames and VFN.MapAliasDB.mapNames[mapID] then
        return VFN.MapAliasDB.mapNames[mapID]
    end
    return "Map " .. tostring(mapID)
end

-- Public callers send display coordinates 0..100 by default. Set
-- normalized=true with x/y in 0..1 to preserve normalized coordinates.
local function NormalizeCoords(entry)
    local x = tonumber(entry.x)
    local y = tonumber(entry.y)
    if not x or not y then return nil end

    if entry.normalized == true and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
        return x, y, x * 100, y * 100
    end

    if x >= 0 and x <= 100 and y >= 0 and y <= 100 then
        return x / 100, y / 100, x, y
    end

    return nil
end

local function NormalizeEntry(entry, idIndex, defaultMapID)
    if type(entry) ~= "table" then return nil end

    local mapID = PositiveMapID(entry.mapID or entry.coordMapID or defaultMapID)
    if not mapID then return nil end

    local x, y, rawX, rawY = NormalizeCoords(entry)
    if not x then return nil end

    local now = Now()
    return {
        id = entry.id or ("coord_" .. tostring(idIndex)),
        kind = entry.kind or "coordinate",
        entity = entry.entity or { type = "location", id = nil, name = entry.label },
        rawLine = entry.rawLine,
        lineNo = entry.lineNo,
        rawMapHint = entry.mapName,
        rawMapID = PositiveMapID(entry.mapID or entry.coordMapID),
        mapName = MapNameFor(mapID, entry.mapName),
        coordMapID = mapID,
        displayMapID = PositiveMapID(entry.displayMapID) or mapID,
        x = x,
        y = y,
        rawX = rawX,
        rawY = rawY,
        label = entry.label,
        note = entry.note,
        ref = CopyRef(entry.ref),
        payload = entry.payload,
        status = "new",
        resolution = entry.resolution or "api",
        confidence = tonumber(entry.confidence) or 1.0,
        resolverVersion = entry.resolverVersion or API_VERSION,
        visits = {},
        visitCount = 0,
        lastVisitedAt = nil,
        createdAt = now,
        updatedAt = now,
        archived = false,
        deletedAt = nil,
        tags = entry.tags or {},
        display = entry.display or { color = nil, icon = nil },
    }
end

local function NormalizeItem(item, idIndex)
    if type(item) ~= "table" or not NonEmpty(item.name) then return nil end

    return {
        id = item.id or ("item_" .. tostring(idIndex)),
        ref = CopyRef(item.ref),
        name = item.name,
        quantity = tonumber(item.quantity) or 1,
        currency = CopyCurrency(item.currency),
        costText = item.costText,
        vendorEntryID = item.vendorEntryID,
        vendorRef = CopyRef(item.vendorRef),
        completed = item.completed == true,
        payload = item.payload,
    }
end

local function ExistingSetIDFor(source)
    if not source.addon or not source.key or not VFN.Store or not VFN.Store.GetState then
        return nil
    end

    local state = VFN.Store:GetState()
    local bySource = state
        and state.account
        and state.account.cache
        and state.account.cache.bySource

    return bySource and bySource[source.addon] and bySource[source.addon][source.key] or nil
end

local function BuildResult(setID, accepted, acceptedItems, duplicates, invalid, invalidItems, capped, replaced, shown, errors)
    return {
        setID = setID,
        accepted = accepted,
        acceptedItems = acceptedItems,
        duplicates = duplicates,
        invalid = invalid,
        invalidItems = invalidItems,
        capped = capped,
        replaced = replaced,
        shown = shown,
        errors = errors or {},
    }
end

local function AddResultFields(result, fields)
    for key, value in pairs(fields or {}) do
        result[key] = value
    end
    return result
end

local function ErrorResult(setID, code)
    return BuildResult(setID, 0, 0, 0, 0, 0, 0, false, false, { code })
end

local function GetSet(setID)
    if not setID or not VFN.Store or not VFN.Store.GetState then return nil end

    local state = VFN.Store:GetState()
    local sets = state and state.account and state.account.sets or nil
    local set = sets and sets[setID] or nil
    if not set or set.deletedAt then return nil end
    return set
end

local function IsValidWaypointEntry(entry)
    if VFN.WaypointBackend and VFN.WaypointBackend.IsValidEntry then
        return VFN.WaypointBackend:IsValidEntry(entry)
    end
    if type(entry) ~= "table" then return false end
    if type(entry.coordMapID) ~= "number" then return false end
    if type(entry.x) ~= "number" or type(entry.y) ~= "number" then return false end
    return entry.x >= 0 and entry.x <= 1 and entry.y >= 0 and entry.y <= 1
end

local function AddValidEntry(out, entry)
    if IsValidWaypointEntry(entry) then
        out[#out + 1] = entry
    end
end

local function GetActiveEntryID(set)
    if set and set.activeEntryID then return set.activeEntryID end
    if set and set.sendState and set.sendState.activeEntryID then return set.sendState.activeEntryID end

    local state = VFN.Store and VFN.Store.GetState and VFN.Store:GetState() or nil
    local ui = state and state.account and state.account.ui or nil
    return ui and ui.activeEntryID or nil
end

local function EntriesForScope(set, scope)
    local entries = set and set.entries or {}
    local out = {}
    scope = scope or "set"

    if scope == "set" then
        for _, entry in ipairs(entries) do
            AddValidEntry(out, entry)
        end
        return out, nil
    end

    if scope == "selected" then
        local activeEntryID = GetActiveEntryID(set)
        if activeEntryID then
            for _, entry in ipairs(entries) do
                if entry.id == activeEntryID then
                    AddValidEntry(out, entry)
                    return out, nil
                end
            end
        end
        for _, entry in ipairs(entries) do
            AddValidEntry(out, entry)
            if #out > 0 then return out, nil end
        end
        return out, nil
    end

    if scope == "map" then
        local mapID = PositiveMapID(set and (set.defaultMapID or set.displayMapID))
        if mapID then
            for _, entry in ipairs(entries) do
                if entry.coordMapID == mapID or entry.displayMapID == mapID then
                    AddValidEntry(out, entry)
                end
            end
        end
        return out, nil
    end

    return out, "invalid_scope"
end

local function BackendResult(setID, action, entries, set)
    local backend = VFN.WaypointBackend
    local method = action == "remove" and "Remove" or "Send"
    if not backend or type(backend[method]) ~= "function" then
        return ErrorResult(setID, "backend_unavailable")
    end

    local result = backend[method](backend, entries, set) or {}
    local errors = result.errors or {}
    local out = BuildResult(setID, #entries, 0, 0, 0, 0, 0, false, false, errors)
    return AddResultFields(out, {
        ok = result.ok == true,
        provider = result.provider,
        sent = result.sent or 0,
        activeEntryID = result.activeEntryID,
    })
end

VFN.API = { version = API_VERSION }

function VFN.API:AddCoord(coord)
    if coord == nil then
        coord = {}
    elseif type(coord) ~= "table" then
        return BuildResult(nil, 0, 0, 0, 0, 0, 0, false, false, { "invalid_payload" })
    end

    return self:AddCoordSet({
        title = coord.title or coord.label,
        sourceType = coord.sourceType,
        owner = coord.owner,
        sourceAddon = coord.sourceAddon,
        sourceKey = coord.sourceKey,
        sourceVersion = coord.sourceVersion,
        scope = coord.scope,
        character = coord.character,
        replaceExisting = coord.replaceExisting,
        external = coord.external,
        show = coord.show,
        defaultMapID = coord.defaultMapID or coord.mapID or coord.coordMapID,
        sourceText = coord.sourceText or coord.rawLine,
        sourceLines = coord.sourceLines,
        tags = coord.tags,
        display = coord.setDisplay,
        payload = coord.setPayload,
        entries = { coord },
    })
end

function VFN.API:AddCoordSet(payload)
    if payload == nil then
        payload = {}
    elseif type(payload) ~= "table" then
        return BuildResult(nil, 0, 0, 0, 0, 0, 0, false, false, { "invalid_payload" })
    end

    local source = SourceFromPayload(payload)
    local entries = {}
    local items = {}
    local invalid = 0
    local invalidItems = 0
    local capped = 0
    local maxEntries = (VFN.Constants and VFN.Constants.MAX_COORDS_PER_SET) or 999

    local payloadEntries = payload.entries
    if payloadEntries ~= nil and type(payloadEntries) ~= "table" then
        return BuildResult(nil, 0, 0, 0, 0, 0, 0, false, false, { "invalid_entries" })
    end

    local payloadItems = payload.items
    if payloadItems ~= nil and type(payloadItems) ~= "table" then
        return BuildResult(nil, 0, 0, 0, 0, 0, 0, false, false, { "invalid_items" })
    end

    for _, entry in ipairs(payloadEntries or {}) do
        local normalized = NormalizeEntry(entry, #entries + 1, payload.defaultMapID)
        if normalized then
            if #entries < maxEntries then
                entries[#entries + 1] = normalized
            else
                capped = capped + 1
            end
        else
            invalid = invalid + 1
        end
    end

    for _, item in ipairs(payloadItems or {}) do
        local normalized = NormalizeItem(item, #items + 1)
        if normalized then
            items[#items + 1] = normalized
        else
            invalidItems = invalidItems + 1
        end
    end

    local hasTitle = NonEmpty(payload.title) ~= nil
    local hasSourceIdentity = source.addon ~= nil and source.key ~= nil
    if not hasTitle and not hasSourceIdentity and #entries == 0 and #items == 0 then
        return BuildResult(nil, 0, 0, 0, invalid, invalidItems, capped, false, false, { "empty_set" })
    end

    local replaced = false
    if payload.replaceExisting == true then
        local existingSetID = ExistingSetIDFor(source)
        if existingSetID and VFN.Store and VFN.Store.DeleteSet then
            replaced = VFN.Store:DeleteSet(existingSetID) == true
        end
    end

    local set = {
        title = payload.title or "Imported Field Note",
        source = source,
        external = CopyRef(payload.external),
        checklist = {
            mode = type(payload.checklist) == "table" and payload.checklist.mode or nil,
            completedEntryIDs = {},
            completedItemIDs = {},
        },
        visibility = VisibilityFromPayload(payload),
        sourceText = payload.sourceText,
        sourceLines = payload.sourceLines or {},
        tags = payload.tags or {},
        display = payload.display or { color = nil, icon = nil, collapsedMaps = {} },
        sendState = { backend = nil, sentAt = nil, sentEntryIDs = {} },
        defaultMapID = PositiveMapID(payload.defaultMapID),
        payload = payload.payload,
        entries = entries,
        items = items,
    }

    local created = VFN.Store and VFN.Store.CreateSet and VFN.Store:CreateSet(set) or { error = "store_unavailable" }
    if not created or not created.setID then
        return BuildResult(nil, 0, 0, 0, invalid, invalidItems, capped, replaced, false, { created and created.error or "create_failed" })
    end

    local shown = false
    if payload.show == true and VFN.Store and type(VFN.Store.OpenSet) == "function" then
        VFN.Store:OpenSet(created.setID)
        shown = true
    end

    return BuildResult(created.setID, #entries, #items, 0, invalid, invalidItems, capped, replaced, shown, {})
end

function VFN.API:ClearSet(setID)
    if not setID or not VFN.Store or not VFN.Store.DeleteSet then
        return ErrorResult(setID, "invalid_set")
    end

    local deleted = VFN.Store:DeleteSet(setID) == true
    if not deleted then
        return AddResultFields(ErrorResult(setID, "not_found"), { deleted = 0 })
    end

    return AddResultFields(BuildResult(setID, 1, 0, 0, 0, 0, 0, false, false, {}), { deleted = 1 })
end

function VFN.API:ClearSource(sourceAddon)
    sourceAddon = NonEmpty(sourceAddon)
    if not sourceAddon or not VFN.Store or not VFN.Store.GetState or not VFN.Store.DeleteSet then
        return AddResultFields(ErrorResult(nil, "invalid_source"), { deleted = 0 })
    end

    local state = VFN.Store:GetState()
    local sets = state and state.account and state.account.sets or {}
    local toDelete = {}
    for setID, set in pairs(sets) do
        local source = set and set.source or nil
        if set and not set.deletedAt and source and source.addon == sourceAddon then
            toDelete[#toDelete + 1] = setID
        end
    end

    local deleted = 0
    local errors = {}
    for _, setID in ipairs(toDelete) do
        if VFN.Store:DeleteSet(setID) then
            deleted = deleted + 1
        else
            errors[#errors + 1] = "delete_failed:" .. tostring(setID)
        end
    end
    if deleted == 0 and #errors == 0 then errors[#errors + 1] = "not_found" end
    return AddResultFields(BuildResult(nil, deleted, 0, 0, 0, 0, 0, false, false, errors), { deleted = deleted })
end

function VFN.API:ClearSetBySourceKey(sourceAddon, sourceKey)
    sourceAddon = NonEmpty(sourceAddon)
    sourceKey = NonEmpty(sourceKey)
    if not sourceAddon or not sourceKey or not VFN.Store or not VFN.Store.GetState or not VFN.Store.DeleteSet then
        return AddResultFields(ErrorResult(nil, "invalid_source"), { deleted = 0 })
    end

    local state = VFN.Store:GetState()
    local sets = state and state.account and state.account.sets or {}
    local deleted = 0
    local errors = {}
    for setID, set in pairs(sets) do
        local source = set and set.source or nil
        if set and not set.deletedAt and source and source.addon == sourceAddon and source.key == sourceKey then
            if VFN.Store:DeleteSet(setID) then
                deleted = deleted + 1
            else
                errors[#errors + 1] = "delete_failed:" .. tostring(setID)
            end
        end
    end
    if deleted == 0 and #errors == 0 then errors[#errors + 1] = "not_found" end
    return AddResultFields(BuildResult(nil, deleted, 0, 0, 0, 0, 0, false, false, errors), { deleted = deleted })
end

function VFN.API:ShowSet(setID)
    if not setID or not VFN.Store or type(VFN.Store.OpenSet) ~= "function" then
        return ErrorResult(setID, "invalid_set")
    end

    local shown = VFN.Store:OpenSet(setID) == true
    if not shown then
        return ErrorResult(setID, "not_found")
    end
    return BuildResult(setID, 0, 0, 0, 0, 0, 0, false, true, {})
end

function VFN.API:SendSet(setID, scope)
    local set = GetSet(setID)
    if not set then return ErrorResult(setID, "not_found") end

    local entries, scopeError = EntriesForScope(set, scope)
    if scopeError then return ErrorResult(setID, scopeError) end
    if #entries == 0 then return ErrorResult(setID, "no_valid_entries") end

    return BackendResult(setID, "send", entries, set)
end

function VFN.API:RemoveSent(setID, scope)
    local set = GetSet(setID)
    if not set then return ErrorResult(setID, "not_found") end

    local entries, scopeError = EntriesForScope(set, scope)
    if scopeError then return ErrorResult(setID, scopeError) end
    if #entries == 0 then return ErrorResult(setID, "no_valid_entries") end

    return BackendResult(setID, "remove", entries, set)
end

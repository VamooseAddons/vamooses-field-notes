VFN = VFN or {}
VFN.CoordResolver = {}

local RESOLVER_VERSION = 1
local DEDUP_DISPLAY_COORD_FORMAT = "%.4f"
local MAX_EXPLICIT_MAP_ID = 99999

local function Trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function NormalizeHint(hint)
    if hint == nil then return nil end
    local out = Trim(hint):lower()
    if out == "" then return nil end
    return out
end

local function PositiveMapID(value)
    local numeric = tonumber(value)
    if numeric and numeric > 0 and numeric == math.floor(numeric) then
        return numeric
    end
    return nil
end

local function ExplicitMapID(value)
    local mapID = PositiveMapID(value)
    if mapID and mapID <= MAX_EXPLICIT_MAP_ID then
        return mapID
    end
    return nil
end

local function MapNameFor(db, mapID)
    if db.mapNames[mapID] then return db.mapNames[mapID] end
    -- MapAliasDB only covers known/aliased maps. For everything else fall
    -- back to the live API; WoW caches GetMapInfo internally so this is
    -- cheap. Without this fallback, entries get mapName = "Map 2352".
    local C_MapAPI = _G and _G.C_Map
    local info = C_MapAPI and C_MapAPI.GetMapInfo and C_MapAPI.GetMapInfo(mapID)
    if info and info.name and info.name ~= "" then return info.name end
    return "Map " .. tostring(mapID)
end

local function RawMapID(candidate)
    return PositiveMapID(candidate.mapHint)
end

-- =============================================================================
-- Label enrichment (subzone + nearest POI)
-- =============================================================================
-- For entries the user pasted as bare "X Y" without a label, we look up the
-- subzone name at that coord (via C_Map.GetMapInfoAtPosition) and the
-- nearest area POI (via C_AreaPoiInfo) and use whichever is more specific
-- as the entry label. So pasting "42.1 56.8" on Eversong Woods auto-fills
-- the label as "Lord Sleeve" or "Sunsail Anchorage" depending on what's
-- nearby. User-provided labels are never overwritten.

local POI_SNAP_THRESHOLD = 0.05   -- 5% of map width = strong "near this POI"

local function SubzoneNameFor(mapID, normX, normY)
    local C_MapAPI = _G and _G.C_Map
    if not (C_MapAPI and C_MapAPI.GetMapInfoAtPosition) then return nil end
    local ok, info = pcall(C_MapAPI.GetMapInfoAtPosition, mapID, normX, normY)
    if ok and info and info.name and info.name ~= ""
        and info.mapID and info.mapID ~= mapID then
        return info.name
    end
    return nil
end

local function GetPOIListForMap(cache, mapID)
    if cache[mapID] ~= nil then return cache[mapID] end
    local poiAPI = _G and _G.C_AreaPoiInfo
    if not (poiAPI and poiAPI.GetAreaPOIForMap and poiAPI.GetAreaPOIInfo) then
        cache[mapID] = {}
        return cache[mapID]
    end
    local list = {}
    local poiIDs = poiAPI.GetAreaPOIForMap(mapID) or {}
    for _, poiID in ipairs(poiIDs) do
        local poi = poiAPI.GetAreaPOIInfo(mapID, poiID)
        if poi and poi.position and poi.name and poi.name ~= "" then
            local px, py
            if type(poi.position) == "table" then
                if poi.position.GetXY then
                    px, py = poi.position:GetXY()
                else
                    px, py = poi.position.x, poi.position.y
                end
            end
            if type(px) == "number" and type(py) == "number" then
                list[#list + 1] = { name = poi.name, x = px, y = py }
            end
        end
    end
    cache[mapID] = list
    return list
end

local function NearestPOIName(pois, normX, normY)
    local bestName, bestDist = nil, POI_SNAP_THRESHOLD
    for _, poi in ipairs(pois) do
        local dx = poi.x - normX
        local dy = poi.y - normY
        local d = math.sqrt(dx * dx + dy * dy)
        if d < bestDist then
            bestDist = d
            bestName = poi.name
        end
    end
    return bestName
end

local function EnrichEntryLabel(entry, poiCache)
    if entry.label and entry.label ~= "" then return end  -- user label wins

    local mapID = entry.coordMapID
    local nx, ny = entry.x, entry.y
    if not (mapID and nx and ny) then return end

    -- Nearest POI first -- specific names like "Lord Sleeve" or "Sunsail Anchorage Innkeeper"
    local poiName = NearestPOIName(GetPOIListForMap(poiCache, mapID), nx, ny)
    if poiName then
        entry.label = poiName
        entry.labelSource = "poi"
        return
    end

    -- Fall back to subzone -- broader context like "Cave of the Ancients"
    local subzone = SubzoneNameFor(mapID, nx, ny)
    if subzone then
        entry.label = subzone
        entry.labelSource = "subzone"
    end
end

local function CurrentTime(opts)
    if type(opts.now) == "number" then return opts.now end
    if type(time) == "function" then return time() end
    return 0
end

local function CopySourceLines(lines)
    local out = {}
    for _, line in ipairs(lines or {}) do
        out[#out + 1] = {
            lineNo = line.lineNo,
            text = line.text,
            rawLine = line.rawLine or line.text,
            status = line.status,
        }
    end
    return out
end

local function ResolveExactMap(db, hint)
    if not hint then return nil, nil, nil end
    local exact = db.exactNames and db.exactNames[Trim(hint)]
    if not exact and db.exactNameLookup then
        exact = db.exactNameLookup[NormalizeHint(hint)]
    end
    if exact then
        return exact.mapID, exact.name, "exact"
    end
    return nil, nil, nil
end

-- Lazy session-scoped cache mapping lowercase map name -> uiMapID. Walks
-- the entire WoW map tree once via C_Map.GetMapChildrenInfo (cosmic root,
-- allDescendants=true) the first time a name lookup misses MapAliasDB.
-- Lets the resolver handle every named zone the client knows about, not
-- just the small set we ship in the alias DB.
local _liveNameCache
local function GetLiveNameCache()
    if _liveNameCache then return _liveNameCache end
    local cache = {}
    _liveNameCache = cache
    local C_MapAPI = _G and _G.C_Map
    if not (C_MapAPI and C_MapAPI.GetMapChildrenInfo) then return cache end
    local rootID = (C_MapAPI.GetFallbackWorldMapID and C_MapAPI.GetFallbackWorldMapID()) or 946
    -- nil mapType + allDescendants=true gives a flat list of every map under
    -- the cosmic root. Each entry has { mapID, name, mapType, parentMapID }.
    local descendants = C_MapAPI.GetMapChildrenInfo(rootID, nil, true) or {}
    -- Same-named zones get re-used across expansions with new mapIDs (e.g.
    -- Midnight reuses "Eversong Woods" / "Silvermoon City" with new IDs).
    -- Prefer the HIGHEST mapID seen for a given name -- newer = current
    -- expansion, which is what Wowhead worldmap links also reference.
    -- Without this, the cache stops at the first hit (likely the original
    -- TBC version) and pasted /way coords land in a different group from
    -- the matching worldmap-link coords.
    for _, info in ipairs(descendants) do
        if info.name and info.name ~= "" and info.mapID then
            local key = info.name:lower()
            local existing = cache[key]
            if not existing or info.mapID > existing then
                cache[key] = info.mapID
            end
        end
    end
    -- Also include the root itself so "cosmos" / "azeroth" type lookups work.
    if C_MapAPI.GetMapInfo then
        local rootInfo = C_MapAPI.GetMapInfo(rootID)
        if rootInfo and rootInfo.name and rootInfo.name ~= "" then
            cache[rootInfo.name:lower()] = rootID
        end
    end
    return cache
end

local function LiveNameLookup(db, hint)
    local cache = GetLiveNameCache()
    local mapID = cache[NormalizeHint(hint)]
    if mapID then return mapID, MapNameFor(db, mapID) end
    return nil, nil
end

local function ResolveExplicitMap(db, hint)
    local mapID = ExplicitMapID(hint)
    if mapID then
        return mapID, MapNameFor(db, mapID), "mapID"
    end

    local exactMapID, exactMapName, exactResolution = ResolveExactMap(db, hint)
    if exactMapID then
        return exactMapID, exactMapName, exactResolution
    end

    local alias = db.aliases[NormalizeHint(hint)]
    if alias then
        return alias.mapID, alias.name, "alias"
    end

    -- Live API fallback: walk the WoW map tree for any name the alias DB
    -- doesn't know. Covers every old-world zone (Eversong Woods, Silvermoon
    -- City, etc.) without us shipping an exhaustive alias DB.
    local liveID, liveName = LiveNameLookup(db, hint)
    if liveID then
        return liveID, liveName, "liveAPI"
    end

    return nil, nil, "invalid"
end

local function ResolveHeadingMap(db, hint)
    local mapID = ExplicitMapID(hint)
    if mapID then
        return mapID, MapNameFor(db, mapID), "heading"
    end

    local exactMapID, exactMapName = ResolveExactMap(db, hint)
    if exactMapID then
        return exactMapID, exactMapName, "heading"
    end

    local alias = db.aliases[NormalizeHint(hint)]
    if alias then
        return alias.mapID, alias.name, "heading"
    end

    local liveID, liveName = LiveNameLookup(db, hint)
    if liveID then
        return liveID, liveName, "heading"
    end

    return nil, nil, "invalid"
end

local function ResolveMap(candidate, opts)
    local db = VFN.MapAliasDB or { aliases = {}, mapNames = {} }
    db.exactNames = db.exactNames or {}
    db.exactNameLookup = db.exactNameLookup or {}
    db.aliases = db.aliases or {}
    db.mapNames = db.mapNames or {}

    if candidate.mapHint then
        return ResolveExplicitMap(db, candidate.mapHint)
    end

    if candidate.headingHint then
        return ResolveHeadingMap(db, candidate.headingHint)
    end

    local mapID = PositiveMapID(opts.currentMapID)
    if mapID then
        return mapID, MapNameFor(db, mapID), "currentMap"
    end

    mapID = PositiveMapID(opts.defaultMapID)
    if mapID then
        return mapID, MapNameFor(db, mapID), "currentMap"
    end

    -- Parent-map normalization stays outside this pure resolver until VFN has
    -- verified local parent-map data. Do not call C_Map here.
    return nil, nil, "invalid"
end

local function AddInvalid(out, lineNo, rawLine, reason)
    out.invalid[#out.invalid + 1] = {
        lineNo = lineNo,
        rawLine = rawLine,
        reason = reason,
    }
end

local function DuplicateKey(mapID, rawX, rawY)
    -- Exact dedup is defined against pasted display coordinates. Four decimal
    -- places exceeds normal /way precision while making the policy explicit.
    return tostring(mapID)
        .. ":"
        .. string.format(DEDUP_DISPLAY_COORD_FORMAT, rawX)
        .. ":"
        .. string.format(DEDUP_DISPLAY_COORD_FORMAT, rawY)
end

function VFN.CoordResolver:Resolve(parsed, opts)
    opts = opts or {}
    parsed = parsed or {}

    local out = {
        entries = {},
        invalid = {},
        duplicates = 0,
        sourceLines = CopySourceLines(parsed.lines),
    }
    local seen = {}
    -- Per-Resolve POI cache so multiple entries on the same map share one
    -- C_AreaPoiInfo.GetAreaPOIForMap call. Empty in test environments
    -- (graceful: NearestPOIName returns nil, falls through to subzone).
    local poiCache = {}

    for _, candidate in ipairs(parsed.candidates or {}) do
        local mapID, mapName, resolution = ResolveMap(candidate, opts)
        local reason = nil

        if not mapID then
            reason = "map"
        elseif type(candidate.x) ~= "number" or candidate.x < 0 or candidate.x > 100 then
            reason = "x_range"
        elseif type(candidate.y) ~= "number" or candidate.y < 0 or candidate.y > 100 then
            reason = "y_range"
        end

        if reason then
            AddInvalid(out, candidate.lineNo, candidate.rawLine, reason)
        else
            local normalizedX = candidate.x / 100
            local normalizedY = candidate.y / 100
            local key = DuplicateKey(mapID, candidate.x, candidate.y)

            if seen[key] then
                out.duplicates = out.duplicates + 1
            else
                local now = CurrentTime(opts)
                seen[key] = true
                out.entries[#out.entries + 1] = {
                    id = "coord_" .. tostring(#out.entries + 1),
                    kind = "coordinate",
                    entity = {
                        type = "location",
                        id = nil,
                        name = candidate.label,
                    },
                    rawLine = candidate.rawLine,
                    lineNo = candidate.lineNo,
                    rawMapHint = candidate.mapHint or candidate.headingHint,
                    rawMapID = RawMapID(candidate),
                    mapName = mapName,
                    coordMapID = mapID,
                    displayMapID = mapID,
                    x = normalizedX,
                    y = normalizedY,
                    rawX = candidate.x,
                    rawY = candidate.y,
                    label = candidate.label,
                    note = nil,
                    ref = {
                        addon = nil,
                        type = nil,
                        id = nil,
                        payloadVersion = nil,
                    },
                    payload = nil,
                    status = "new",
                    resolution = resolution,
                    confidence = 1.0,
                    resolverVersion = RESOLVER_VERSION,
                    visits = {},
                    visitCount = 0,
                    lastVisitedAt = nil,
                    createdAt = now,
                    updatedAt = now,
                    archived = false,
                    deletedAt = nil,
                    tags = {},
                    display = {
                        color = nil,
                        icon = nil,
                    },
                }
                -- Auto-label enrichment: nearest POI / subzone name when the
                -- user didn't paste their own label. Skipped silently if the
                -- C_Map / C_AreaPoiInfo APIs aren't available (test env).
                EnrichEntryLabel(out.entries[#out.entries], poiCache)
            end
        end
    end

    for _, line in ipairs(out.sourceLines) do
        if line.status == "invalid" then
            AddInvalid(out, line.lineNo, line.rawLine or line.text, "source")
        end
    end

    return out
end

function VFN.CoordResolver:ResolveCandidates(parsed, opts)
    return self:Resolve(parsed, opts)
end

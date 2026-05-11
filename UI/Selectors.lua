-- VFN.Selectors
--
-- Pure read-only functions over Store state. They take state (or a set table)
-- and return view-model objects the surfaces render. No mutation, no events,
-- no Blizzard APIs, no widgets -- so they can be unit-tested in isolation.
--
-- Surfaces (DetailView, StreamSurface) call these at Refresh time. New
-- selectors go here, not in surface modules.

VFN = VFN or {}
VFN.Selectors = VFN.Selectors or {}

local Selectors = VFN.Selectors

-- Group identity ------------------------------------------------------------

-- Module-level cache so we resolve C_Map.GetMapInfo once per map ID per
-- session. Cheap enough to not bother invalidating; map IDs don't change
-- mid-session.
local mapNameCache = {}
local function resolveMapName(mapID)
    if not mapID then return nil end
    local cached = mapNameCache[mapID]
    if cached ~= nil then return cached end
    local C_MapAPI = _G and _G.C_Map
    local info = C_MapAPI and C_MapAPI.GetMapInfo and C_MapAPI.GetMapInfo(mapID)
    local name = info and info.name
    if name and name ~= "" then
        mapNameCache[mapID] = name
        return name
    end
    -- Cache the negative so we don't keep retrying for unknown IDs.
    mapNameCache[mapID] = false
    return nil
end

function Selectors.GetEntryGroupName(entry)
    -- entry.mapName starting with "Map " followed by a number is the resolver's
    -- placeholder when the alias DB had no entry. Re-resolve via the live API
    -- so previously-saved entries show real names too.
    if entry and entry.mapName and entry.mapName ~= ""
        and not entry.mapName:match("^Map %d+$") then
        return entry.mapName
    end
    if entry and entry.coordMapID then
        local resolved = resolveMapName(entry.coordMapID)
        if resolved then return resolved end
        return "Map " .. tostring(entry.coordMapID)
    end
    return "Unknown Map"
end

function Selectors.GetEntryGroupKey(entry)
    if entry and entry.coordMapID then return "map:" .. tostring(entry.coordMapID) end
    return "name:" .. Selectors.GetEntryGroupName(entry)
end

function Selectors.EntryInGroup(entry, key)
    return entry and (not key or Selectors.GetEntryGroupKey(entry) == key)
end

-- Aggregations --------------------------------------------------------------

function Selectors.BuildMapGroups(set)
    local groups, byKey = {}, {}
    for _, entry in ipairs((set and set.entries) or {}) do
        local key = Selectors.GetEntryGroupKey(entry)
        local g = byKey[key]
        if not g then
            g = {
                key = key,
                groupName = Selectors.GetEntryGroupName(entry),
                coordMapID = entry.coordMapID,
                count = 0,
            }
            byKey[key] = g
            groups[#groups + 1] = g
        end
        g.count = g.count + 1
    end
    return groups
end

-- Returns pure-data coord items for the source pane scrollbox. No color
-- escapes -- the rendering layer (Controller_Detail.coordRowFactory) paints
-- each field with the appropriate Theme token. `coords` and `label` are
-- separate strings so the row can render them in distinct FontStrings.
function Selectors.BuildCoordinateItems(set, key)
    local items = {}
    for index, entry in ipairs((set and set.entries) or {}) do
        if not key or Selectors.GetEntryGroupKey(entry) == key then
            local rawX = entry.rawX or ((entry.x or 0) * 100)
            local rawY = entry.rawY or ((entry.y or 0) * 100)
            local label = entry.label and entry.label ~= "" and entry.label or ""
            items[#items + 1] = {
                index  = index,
                entry  = entry,
                coords = string.format("%.1f, %.1f", rawX, rawY),
                label  = label,
            }
        end
    end
    return items
end

function Selectors.BuildSourceLineItems(set)
    local items = {}
    if set and set.sourceLines and #set.sourceLines > 0 then
        for _, line in ipairs(set.sourceLines) do
            items[#items + 1] = {
                text = tostring(line.lineNo or #items + 1) .. ": " .. tostring(line.text or ""),
            }
        end
        return items
    end
    local sourceText = set and set.sourceText or ""
    local lineNo = 0
    for line in tostring(sourceText):gmatch("([^\n]*)\n?") do
        if line == "" and lineNo > 0 then break end
        lineNo = lineNo + 1
        items[#items + 1] = { text = tostring(lineNo) .. ": " .. line }
    end
    return items
end

-- Display formatting --------------------------------------------------------

-- Build view model for the drawer's "current card" (selected pin detail).
-- Returns four strings + hasSelection flag. Pure; takes the entry directly so
-- callers can supply nil for "nothing selected" without special-casing here.
function Selectors.BuildCurrentCardModel(entry)
    if not entry then
        return {
            hasSelection = false,
            map = "Select a pin",
            coords = "",
            note = "",
            source = "",
        }
    end
    local rawX = entry.rawX or ((entry.x or 0) * 100)
    local rawY = entry.rawY or ((entry.y or 0) * 100)
    local label = entry.label
    if label and label ~= "" and label:lower() == "coordinate" then label = nil end
    return {
        hasSelection = true,
        map    = Selectors.GetEntryGroupName(entry),
        coords = string.format("%.1f, %.1f", rawX, rawY),
        note   = label or "",
        source = entry.sourceLine or "",
    }
end

-- Format a clock-time prefix for apply log lines (matches mockup's [10:22 pm]
-- styling). Falls back to relative time if WoW's date() helper is missing
-- (test environments).
local function formatClockTime(timestamp)
    if not timestamp or timestamp <= 0 then return "" end
    if _G and _G.date then
        local ok, formatted = pcall(_G.date, "[%I:%M %p]", timestamp)
        if ok and formatted then return formatted:lower():gsub("^%[0", "[") end
    end
    return ""
end

-- Build view-model items for the drawer's apply log. Returns newest-first
-- so the most recent send/remove is at the top of the scrollbox. When the
-- log is empty, returns one placeholder row so the panel doesn't read as
-- broken.
-- Library view: index column (list of libraries with set counts).
function Selectors.BuildLibraryIndexItems(state)
    local items = {}
    if not state or not state.account then return items end
    local libs = state.account.libraries or {}
    local sel = state.session and state.session.viewLocal
        and state.session.viewLocal.library
        and state.session.viewLocal.library.selectedLibraryID
    for libID, lib in pairs(libs) do
        if not lib.deletedAt then
            items[#items + 1] = {
                libraryID = libID,
                name      = lib.name or "Untitled",
                count     = lib.setIDs and #lib.setIDs or 0,
                isDefault = lib.isDefault == true,
                selected  = (sel == libID),
            }
        end
    end
    table.sort(items, function(a, b)
        if a.isDefault ~= b.isDefault then return a.isDefault end  -- Default first
        return a.name:lower() < b.name:lower()
    end)
    return items
end

-- Status chips for a library card. Returns a list of semantic chip names
-- (strings) ordered consistently for display. The renderer paints colour
-- via Theme.Skinners.StatusChip; this function is pure-data.
--
-- Chip semantics:
--   "ready"    : set has at least one entry that resolves to a real mapID
--                (i.e. waypoints can be dispatched)
--   "blocked"  : set has zero entries OR all entries lack a coordMapID
--                (cannot send -- a card needs attention)
--   "has_note" : set.payload.note is non-empty (after trim)
--   "source"   : set was captured from paste (Wowhead / chat link / etc)
--   "default"  : set lives in the Default library (auto-save inbox vs a
--                user-curated collection)
function Selectors.GetSetStatusChips(set, defaultLibraryID)
    if not set then return {} end
    local chips = {}
    local entries = set.entries or {}
    local hasResolvedEntry = false
    for _, e in ipairs(entries) do
        if e.coordMapID then hasResolvedEntry = true; break end
    end
    if hasResolvedEntry then
        chips[#chips + 1] = "ready"
    else
        chips[#chips + 1] = "blocked"
    end
    local note = set.payload and set.payload.note or ""
    if type(note) == "string" and note:gsub("%s+", "") ~= "" then
        chips[#chips + 1] = "has_note"
    end
    local source = set.source or {}
    if source.type == "paste" then
        chips[#chips + 1] = "source"
    end
    if defaultLibraryID and set.libraryID == defaultLibraryID then
        chips[#chips + 1] = "default"
    end
    return chips
end

-- Apply find-state (search query / filter / sort) to a raw card list.
-- Pure-data; called by BuildLibraryCardItems' caller after the raw list
-- is built. find = { query = string?, filter = "all"|"has_note"|"ready"|"blocked", sort = "recent"|"alpha"|"size" }.
local function ApplyFind(items, find, sets)
    find = find or {}
    local query = type(find.query) == "string" and find.query:lower():match("^%s*(.-)%s*$") or ""
    local filter = find.filter or "all"
    local sort = find.sort or "recent"

    -- Filter
    if filter ~= "all" or query ~= "" then
        local filtered = {}
        for _, item in ipairs(items) do
            local pass = true
            if filter == "has_note" then
                pass = (item.noteText or "") ~= ""
            elseif filter == "ready" then
                pass = false
                for _, chip in ipairs(item.statusChips or {}) do
                    if chip == "ready" then pass = true; break end
                end
            elseif filter == "blocked" then
                pass = false
                for _, chip in ipairs(item.statusChips or {}) do
                    if chip == "blocked" then pass = true; break end
                end
            end
            if pass and query ~= "" then
                local hay = ((item.title or "") .. " " .. (item.mapsLabel or "") ..
                    " " .. (item.sourceLabel or "") .. " " .. (item.noteText or "")):lower()
                pass = hay:find(query, 1, true) ~= nil
            end
            if pass then filtered[#filtered + 1] = item end
        end
        items = filtered
    end

    -- Sort
    table.sort(items, function(a, b)
        if sort == "alpha" then
            return (a.title or ""):lower() < (b.title or ""):lower()
        elseif sort == "size" then
            return (a.coordCount or 0) > (b.coordCount or 0)
        else  -- "recent" (default)
            local sa = sets[a.setID] or {}
            local sb = sets[b.setID] or {}
            local ka = sa.updatedAt or sa.createdAt or 0
            local kb = sb.updatedAt or sb.createdAt or 0
            return ka > kb
        end
    end)
    return items
end

-- Library view: cards column (sets in the selected library).
-- Optional `find` arg = { query, filter, sort } applies search / filter / sort
-- transforms. Nil = raw list, most-recent-first.
function Selectors.BuildLibraryCardItems(state, libraryID, find)
    local items = {}
    if not state or not state.account or not libraryID then return items end
    local lib = state.account.libraries[libraryID]
    if not lib then return items end
    local defaultLibID = state.account.defaultLibraryID
    local sel = state.session and state.session.viewLocal
        and state.session.viewLocal.library
        and state.session.viewLocal.library.selectedSetID
    for _, setID in ipairs(lib.setIDs or {}) do
        local set = state.account.sets[setID]
        if set and not set.deletedAt then
            local entries = set.entries or {}
            local visibility = set.visibility or {}
            local source = set.source or {}
            local payload = set.payload or {}
            local noteText = payload.note
            if type(noteText) ~= "string" then noteText = "" end
            noteText = noteText:gsub("\n", " "):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
            -- Pre-compute the primary map name for search + display.
            local primaryMapName = ""
            for _, e in ipairs(entries) do
                local name = Selectors.GetEntryGroupName(e)
                if name and name ~= "" then primaryMapName = name; break end
            end
            local sourceLabel = (source.type == "paste") and "Wowhead" or "manual"
            items[#items + 1] = {
                setID        = setID,
                title        = Selectors.GetSetTitle(set),
                coordCount   = #entries,
                mapCount     = (function()
                    local seen, n = {}, 0
                    for _, e in ipairs(entries) do
                        local k = e.coordMapID or e.mapName
                        if k and not seen[k] then seen[k] = true; n = n + 1 end
                    end
                    return n
                end)(),
                mapsLabel    = primaryMapName,
                sourceLabel  = sourceLabel,
                character    = visibility.character,
                noteText     = noteText,
                isManual     = (source.type == "manual"),
                statusChips  = Selectors.GetSetStatusChips(set, defaultLibID),
                updatedAt    = set.updatedAt or set.createdAt,
                selected     = (sel == setID),
            }
        end
    end
    if find then items = ApplyFind(items, find, state.account.sets) end
    return items
end

-- (BuildLibraryItems removed -- legacy entry point from before the library
-- tab was split into BuildLibraryIndexItems + BuildLibraryCardItems. Had
-- zero callers when the audit found it.)

function Selectors.BuildApplyLogItems(state, _now)
    local items = {}
    -- Apply log moved from account to session bucket -- it's session-scoped
    -- history (cleared on /reload), not persisted account data.
    local log = state and state.session and state.session.applyLog or {}
    for i = #log, 1, -1 do
        local entry = log[i]
        if entry and entry.line then
            local prefix = formatClockTime(entry.at)
            items[#items + 1] = { line = entry.line, at = entry.at, prefix = prefix }
        end
    end
    if #items == 0 then
        items[1] = { empty = true, line = "No send/remove actions yet.", prefix = "" }
    end
    return items
end

function Selectors.FormatEntrySummary(entry)
    if not entry then return "No coordinate selected" end
    local mapName = Selectors.GetEntryGroupName(entry)
    local label = entry.label and entry.label ~= "" and entry.label or "Coordinate"
    local rawX = entry.rawX or ((entry.x or 0) * 100)
    local rawY = entry.rawY or ((entry.y or 0) * 100)
    return string.format("%s - %s - %.1f, %.1f", mapName, label, rawX, rawY)
end

-- Validity ------------------------------------------------------------------

function Selectors.IsSendableEntry(entry)
    if VFN.WaypointBackend and VFN.WaypointBackend.IsValidEntry then
        return VFN.WaypointBackend:IsValidEntry(entry)
    end
    if type(entry) ~= "table" then return false end
    if type(entry.coordMapID) ~= "number" then return false end
    if type(entry.x) ~= "number" or type(entry.y) ~= "number" then return false end
    return entry.x >= 0 and entry.x <= 1 and entry.y >= 0 and entry.y <= 1
end

-- Selection helpers (return defaults; do NOT mutate) ------------------------

function Selectors.FindGroupByKey(groups, key)
    for _, g in ipairs(groups or {}) do
        if g.key == key then return g end
    end
    return nil
end

function Selectors.FirstGroupKey(groups)
    return groups and groups[1] and groups[1].key or nil
end

function Selectors.FindEntryInGroup(set, key, fallbackIndex)
    local entries = set and set.entries or {}
    if fallbackIndex and Selectors.EntryInGroup(entries[fallbackIndex], key) then
        return fallbackIndex, entries[fallbackIndex]
    end
    for index, entry in ipairs(entries) do
        if Selectors.EntryInGroup(entry, key) then
            return index, entry
        end
    end
    return nil, nil
end

-- Scoped entry lists --------------------------------------------------------

function Selectors.EntriesForScope(set, scope, key)
    local out = {}
    if not set then return out end
    if scope == "selected" then
        return out  -- caller picks the selected entry; selectors don't know UI state
    end
    for _, entry in ipairs(set.entries or {}) do
        if Selectors.IsSendableEntry(entry) and (scope == "set" or Selectors.EntryInGroup(entry, key)) then
            out[#out + 1] = entry
        end
    end
    return out
end

-- Stream list ---------------------------------------------------------------

function Selectors.GetSetTitle(set)
    if set and set.title and set.title ~= "" then return set.title end
    return "Untitled Field Note"
end

local function setIDInList(list, value)
    for _, existing in ipairs(list or {}) do
        if existing == value then return true end
    end
    return false
end

function Selectors.SetVisibleForCharacter(set, characterFilter, currentCharacter, knownCharacters)
    local visibility = set and set.visibility or {}
    local character = visibility.character
    if characterFilter == "all" then return true end
    if characterFilter == "known" then
        return not character or setIDInList(knownCharacters, character)
    end
    return not character or character == currentCharacter
end

-- Local: shorten "Name-Realm" to "Name" for compact display in stream rows.
local function shortCharacter(characterKey)
    if type(characterKey) ~= "string" or characterKey == "" then return nil end
    local dash = characterKey:find("-", 1, true)
    if dash then return characterKey:sub(1, dash - 1) end
    return characterKey
end

-- Local: count distinct resolved maps in a set's entries.
local function distinctMapCount(set)
    local seen, n = {}, 0
    for _, entry in ipairs(set and set.entries or {}) do
        local key = entry.coordMapID or entry.mapName
        if key and not seen[key] then seen[key] = true; n = n + 1 end
    end
    return n
end

-- Build the stream's view-model items from state. Pure: takes state +
-- currentCharacter (which the caller derives from WoW APIs). Each item carries
-- the data the streamRow factory renders directly -- no further set lookups
-- in the row factory.
function Selectors.BuildStreamItems(state, currentCharacter)
    local items = {}
    if not state or not state.account then return items end
    local sets = state.account.sets or {}
    local ui = state.account.ui or {}
    local config = state.account.config or {}
    local characterFilter = config.characterFilter
        or (VFN.Constants and VFN.Constants.CYCLES and VFN.Constants.CYCLES.characterFilter and VFN.Constants.CYCLES.characterFilter.default)
        or "current"

    local knownCharacters = {}
    for character in pairs(state.characters or {}) do
        knownCharacters[#knownCharacters + 1] = character
    end

    local visibleIDs = (VFN.Store and VFN.Store.GetVisibleSetIDs and VFN.Store:GetVisibleSetIDs()) or {}
    for _, setID in ipairs(visibleIDs) do
        local set = sets[setID]
        if set and not set.deletedAt
            and Selectors.SetVisibleForCharacter(set, characterFilter, currentCharacter, knownCharacters) then
            local entries = set.entries or {}
            local source = set.source or {}
            local visibility = set.visibility or {}
            local payload = set.payload or {}
            local noteText = payload.note
            if type(noteText) ~= "string" then noteText = "" end
            noteText = noteText:gsub("\n", " "):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
            items[#items + 1] = {
                setID = setID,
                title = Selectors.GetSetTitle(set),
                coordCount = #entries,
                mapCount = distinctMapCount(set),
                character = shortCharacter(visibility.character),
                noteText = noteText,
                isManual = (source.type == "manual"),
                selected = ui.selectedSetID == setID,
            }
        end
    end
    return items
end

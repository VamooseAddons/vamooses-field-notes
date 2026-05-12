-- VFN.Selectors
--
-- Pure read-only functions over Store state. They take state (or a set table)
-- and return view-model objects the surfaces render. No mutation, no events,
-- no Blizzard APIs, no widgets -- so they can be unit-tested in isolation.
--
-- Surfaces (DetailView, StreamSurface) call these at Refresh time. New
-- selectors go here, not in surface modules.
--
-- ===== Memoization status (deferred to Phase 2) ============================
-- Spec section 11 prescribes VFN.Memo wrapping for non-trivial selectors so
-- repeated calls within a Refresh cycle return cached results. We do NOT
-- memoize today because the reducer in Core/Store.lua mutates state tables
-- in place (e.g. `library.setIDs[#library.setIDs+1] = setID`). Memo's
-- reference-equality model would see unchanged table refs and return stale
-- results across mutations.
--
-- Cost analysis: deferred-notify (spec section 7.2) already batches
-- subscriber fan-out to once per frame. Each Refresh resolves each binding
-- once; since each selector is bound to exactly one binding name today,
-- the memo cache would never hit within a frame. The real win comes from
-- caching across frames when no dispatch happened -- and that requires
-- knowing when state changed, which a tick counter could do but a proper
-- immutable-update reducer (Phase 2 / VamooseUI extraction) does cleanly.
--
-- When VamooseUI lands, refactor the reducer to return new state objects
-- on mutation. Memo then composes correctly per spec section 11 rule 1.
-- VFN.Memo (Core/Memo.lua) is ready and tested; only consumer wiring waits.

VFN = VFN or {}
VFN.Selectors = VFN.Selectors or {}

local Selectors = VFN.Selectors

-- ===== Selector registry (for the binding engine) ==========================
-- Bindings reference selectors by name (e.g. "library.cardItems"). Each
-- registered selector takes (state, ctx) and returns the value the widget
-- should display. Legacy Selectors.BuildXItems(...) functions still exist;
-- registered names wrap them and extract args from state/ctx.
Selectors._registry = Selectors._registry or {}

function Selectors:Register(name, fn)
    self._registry[name] = fn
end

function Selectors:Call(name, state, ctx)
    local fn = self._registry[name]
    if not fn then
        error("selector not registered: " .. tostring(name), 2)
    end
    return fn(state, ctx)
end

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
    local sel = state.session and state.session.ui
        and state.session.ui.library
        and state.session.ui.library.selectedLibraryID
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
    local sel = state.session and state.session.ui
        and state.session.ui.library
        and state.session.ui.library.selectedSetID
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

    -- Stream-view library override: session.ui.stream.libraryID picks which
    -- library's cards to show. Falls back to the default library.
    local streamLib = (state.session and state.session.ui
        and state.session.ui.stream
        and state.session.ui.stream.libraryID) or nil
    local libraries = state.account.libraries or {}
    local activeLibraryID = (streamLib and libraries[streamLib] and not libraries[streamLib].deletedAt)
        and streamLib or state.account.defaultLibraryID

    local visibleIDs = (activeLibraryID and libraries[activeLibraryID] and libraries[activeLibraryID].setIDs) or {}
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


-- ===========================================================================
-- Registered selectors (for the binding engine).
-- Each takes (state, ctx) and returns the value to push to a widget. Most
-- wrap the BuildXItems(...) helpers above; the wrappers exist so bindings
-- reference one stable name while the helpers keep their per-arg shapes
-- (called directly from controllers for refresh-time queries).
-- ===========================================================================

local function libUI(state)
    return (state and state.session and state.session.ui and state.session.ui.library) or {}
end

local function activeLibrary(state)
    local lib = libUI(state)
    local libs = state.account.libraries or {}
    local id = lib.selectedLibraryID
    if id and libs[id] and not libs[id].deletedAt then return id, libs[id] end
    id = state.account.defaultLibraryID
    return id, libs[id]
end

local function selectedSet(state)
    local lib = libUI(state)
    local id = lib.selectedSetID
    return id and state.account.sets and state.account.sets[id] or nil
end

local SORT_LABELS = { recent = "Recent", alpha = "A - Z", size = "Largest" }

-- --- Library tab: index column -------------------------------------------
Selectors:Register("library.indexItems", function(state)
    return Selectors.BuildLibraryIndexItems(state)
end)

-- --- Library tab: finder column ------------------------------------------
Selectors:Register("library.cardItems", function(state)
    local id = activeLibrary(state)
    local lib = libUI(state)
    return Selectors.BuildLibraryCardItems(state, id, {
        query = lib.searchQuery, filter = lib.activeFilter, sort = lib.sortOrder,
    })
end)

Selectors:Register("library.cardsHeaderText", function(state)
    local id, lib = activeLibrary(state)
    local items = Selectors:Call("library.cardItems", state)
    local total = (lib and lib.setIDs and #lib.setIDs) or 0
    return string.format("%s  -  %d/%d", (lib and lib.name) or "Library", #items, total)
end)

Selectors:Register("library.subtitleText", function(state)
    local libs = state.account.libraries or {}
    local totalSets, totalLibs = 0, 0
    for _, lib in pairs(libs) do
        if not lib.deletedAt then
            totalLibs = totalLibs + 1
            for _, _ in ipairs(lib.setIDs or {}) do totalSets = totalSets + 1 end
        end
    end
    return string.format("%d field notes across %d %s. Right-click a card to move libraries.",
        totalSets, totalLibs, totalLibs == 1 and "library" or "libraries")
end)

Selectors:Register("library.sortLabel", function(state)
    return SORT_LABELS[libUI(state).sortOrder] or "Recent"
end)

-- --- Library tab: curator column ----------------------------------------
Selectors:Register("library.previewItems", function(state)
    return Selectors.BuildCoordinateItems(selectedSet(state))
end)

Selectors:Register("library.previewHeaderText", function(state)
    local set = selectedSet(state)
    if not set then return "Coordinates" end
    local items = Selectors.BuildCoordinateItems(set)
    return string.format("Coordinates (%d)", #items)
end)

Selectors:Register("library.statCoordsValue", function(state)
    local set = selectedSet(state)
    local n = (set and set.entries and #set.entries) or 0
    return tostring(n)
end)

Selectors:Register("library.statMapsValue", function(state)
    local set = selectedSet(state)
    if not set then return "-" end
    local seen, n = {}, 0
    for _, e in ipairs(set.entries or {}) do
        local k = e.coordMapID or e.mapName
        if k and not seen[k] then seen[k] = true; n = n + 1 end
    end
    return n > 0 and tostring(n) or "-"
end)

Selectors:Register("library.statStatusValue", function(state)
    local set = selectedSet(state)
    if not set then return "-" end
    local entries = set.entries or {}
    if #entries == 0 then return "Empty" end
    for _, e in ipairs(entries) do
        if e.coordMapID then return "Ready" end
    end
    return "Blocked"
end)

-- --- Library tab: edit boxes (dirty-aware) ------------------------------
-- The session staging fields (editingTitle/Note + editsDirty) are set by
-- OnTextChanged in Controller_Library. While dirty, the selectors return
-- the staged value; while clean, they return the persisted set.title/note.
Selectors:Register("library.titleEditValue", function(state)
    local lib = libUI(state)
    if lib.editsDirty then return lib.editingTitle or "" end
    local set = selectedSet(state)
    return (set and set.title) or ""
end)

Selectors:Register("library.noteEditValue", function(state)
    local lib = libUI(state)
    if lib.editsDirty then return lib.editingNote or "" end
    local set = selectedSet(state)
    local payload = set and set.payload or {}
    return (type(payload.note) == "string" and payload.note) or ""
end)

-- --- Library tab: button enabled states ---------------------------------
local function hasSelectedSet(state)
    return selectedSet(state) ~= nil
end

local function hasReadyEntries(state)
    local set = selectedSet(state)
    if not set then return false end
    for _, e in ipairs(set.entries or {}) do
        if e.coordMapID then return true end
    end
    return false
end

Selectors:Register("library.saveEnabled",        hasSelectedSet)
Selectors:Register("library.restoreEnabled",     hasSelectedSet)
Selectors:Register("library.moveCardEnabled",    hasSelectedSet)
Selectors:Register("library.deleteCardEnabled",  hasSelectedSet)
Selectors:Register("library.sendCardEnabled",    hasReadyEntries)
Selectors:Register("library.copyCoordsEnabled",  hasReadyEntries)

-- ===========================================================================
-- Stream tab selectors
-- ===========================================================================

local function streamLibraryID(state)
    local viewLib = state.session and state.session.ui and state.session.ui.stream and state.session.ui.stream.libraryID
    local libs = state.account.libraries or {}
    if viewLib and libs[viewLib] and not libs[viewLib].deletedAt then return viewLib end
    return state.account.defaultLibraryID
end

local function currentCharacterKey()
    if not (_G.UnitName and _G.GetRealmName) then return nil end
    local name, realm = _G.UnitName("player"), _G.GetRealmName()
    if name and name ~= "" and realm and realm ~= "" then return name .. "-" .. realm end
    return nil
end

Selectors:Register("stream.items", function(state)
    return Selectors.BuildStreamItems(state, currentCharacterKey())
end)

Selectors:Register("stream.statusText", function(state)
    local items = Selectors:Call("stream.items", state)
    local count = #items
    if count > 0 then
        return tostring(count) .. " " .. (count == 1 and "field note" or "field notes")
    end
    return "no saved field notes"
end)

Selectors:Register("stream.libraryDropdownLabel", function(state)
    local libs = state.account.libraries or {}
    local id = streamLibraryID(state)
    local name = (id and libs[id] and libs[id].name) or "Library"
    return name .. "  v"
end)

-- View-toggle "active" markers on the three header buttons.
Selectors:Register("stream.captureActive", function(state)
    return state.account.ui.view == "capture"
end)
Selectors:Register("stream.libraryActive", function(state)
    return state.account.ui.view == "library"
end)
Selectors:Register("stream.configActive", function(state)
    return state.account.ui.view == "config"
end)
Selectors:Register("stream.backActive", function(state)
    local ui = state.account.ui
    return (ui.selectedSetID == nil) and (ui.view == nil)
end)

-- ===========================================================================
-- Detail tab selectors
-- ===========================================================================

local function detailSelectedSet(state)
    local id = state.account.ui.selectedSetID
    return id and state.account.sets and state.account.sets[id] or nil
end

local function detailGroupKey(state)
    return state.session and state.session.ui and state.session.ui.selectedGroupKey or nil
end

local function detailSelectedEntry(state)
    local set = detailSelectedSet(state)
    if not set then return nil end
    local idx = state.session and state.session.ui and state.session.ui.selectedEntryIndex
    return idx and (set.entries or {})[idx] or nil
end

Selectors:Register("detail.mapGroupItems", function(state)
    local set = detailSelectedSet(state)
    if not set then return {} end
    local groups = Selectors.BuildMapGroups(set)
    local key = detailGroupKey(state)
    for _, g in ipairs(groups) do g.selected = (g.key == key) end
    return groups
end)

Selectors:Register("detail.coordItems", function(state)
    local set = detailSelectedSet(state)
    if not set then return {} end
    local key = detailGroupKey(state)
    local items = Selectors.BuildCoordinateItems(set, key)
    local idx = state.session and state.session.ui and state.session.ui.selectedEntryIndex
    for _, item in ipairs(items) do item.selected = (item.index == idx) end
    return items
end)

Selectors:Register("detail.sourceItems", function(state)
    local set = detailSelectedSet(state)
    return Selectors.BuildSourceLineItems(set)
end)

Selectors:Register("detail.coordSummary", function(state)
    return Selectors.FormatEntrySummary(detailSelectedEntry(state)) or ""
end)

Selectors:Register("detail.subtitle", function(state)
    local entry = detailSelectedEntry(state)
    if not entry then return "" end
    local card = Selectors.BuildCurrentCardModel(entry)
    if not (card and card.hasSelection) then return "" end
    return string.format("%s - Coordinate - %s", card.map or "", card.coords or "")
end)

Selectors:Register("detail.sourceToggleLabel", function(state)
    return state.session.ui.showSourceText and "Coordinates" or "Source Text"
end)

-- Visibility selectors for the spec-driven Layout `visible` flag (spec
-- section 6 -- declarative visibility replaces controller-imposed Hide).
-- The toggle button writes showSourceText; these two pick whichever list
-- the user wants to see.
Selectors:Register("detail.coordListVisible", function(state)
    return not state.session.ui.showSourceText
end)

Selectors:Register("detail.sourceListVisible", function(state)
    return state.session.ui.showSourceText == true
end)

Selectors:Register("detail.scopeButtonLabel", function(state)
    local CYCLES = VFN.Constants.CYCLES
    local scope = state.session.ui.sendScope or CYCLES.sendScope.default
    return CYCLES.sendScope.labels[scope] or scope
end)

-- ===========================================================================
-- Config tab selectors
-- ===========================================================================

local function configValue(state, key)
    return state.account.config and state.account.config[key]
end

Selectors:Register("config.backendLabel", function(state)
    local CYCLES = VFN.Constants.CYCLES
    local v = configValue(state, "waypointBackend") or CYCLES.waypointBackend.default
    return CYCLES.waypointBackend.labels[v] or v
end)

Selectors:Register("config.charactersLabel", function(state)
    local CYCLES = VFN.Constants.CYCLES
    local v = configValue(state, "characterFilter") or CYCLES.characterFilter.default
    return CYCLES.characterFilter.labels[v] or v
end)

Selectors:Register("config.minimapLabel", function(state)
    return configValue(state, "showMinimapButton") and "Hide Minimap Button" or "Show Minimap Button"
end)

Selectors:Register("config.debugLabel", function(state)
    return state.account.config.debug and "Debug: on" or "Debug: off"
end)

Selectors:Register("config.backendHint", function(state)
    local CYCLES = VFN.Constants.CYCLES
    local v = state.account.config.waypointBackend or CYCLES.waypointBackend.default
    return (CYCLES.waypointBackend.hints and CYCLES.waypointBackend.hints[v]) or ""
end)

-- Theme picker: one active-state selector per available theme. The button
-- binding reads `config.theme.active.<Name>` and the Skinner flips to the
-- "active" treatment, so the current theme reads as pressed.
local THEME_NAMES = (VFN_SchemeConstants and VFN_SchemeConstants._meta and VFN_SchemeConstants._meta.order) or {}
for _, name in ipairs(THEME_NAMES) do
    local pick = name  -- capture per-iteration name in the closure
    Selectors:Register("config.theme.active." .. pick, function(state)
        return state.account.config.scheme == pick
    end)
end

-- ===========================================================================
-- Drawer (map preview panel) selectors
-- ===========================================================================

local function drawerSet(state)
    local id = state.account.ui.selectedSetID
    return id and state.account.sets and state.account.sets[id] or nil
end

local function drawerKey(state)
    return state.session and state.session.ui and state.session.ui.selectedGroupKey or nil
end

-- Count entries matching the active group key (or all when key is nil).
-- Used by both the title (first matching entry's group name) and subtitle
-- ("N pins"). Keeping the walk in one place so the two stay in sync.
local function drawerMatching(state)
    local set, key = drawerSet(state), drawerKey(state)
    local entries = (set and set.entries) or {}
    local count, groupName = 0, nil
    for _, entry in ipairs(entries) do
        local match = (not key) or Selectors.GetEntryGroupKey(entry) == key
        if match and entry.x and entry.y then
            count = count + 1
            if not groupName then groupName = Selectors.GetEntryGroupName(entry) end
        end
    end
    return count, groupName
end

Selectors:Register("drawer.title", function(state)
    local _, groupName = drawerMatching(state)
    return groupName or "Map Drawer"
end)

Selectors:Register("drawer.subtitle", function(state)
    local count = drawerMatching(state)
    return tostring(count) .. " " .. (count == 1 and "pin" or "pins")
end)

local function drawerCard(state)
    local set, key = drawerSet(state), drawerKey(state)
    if not set then return Selectors.BuildCurrentCardModel(nil) end
    local _, entry = Selectors.FindEntryInGroup(set, key, state.session.ui.selectedEntryIndex)
    return Selectors.BuildCurrentCardModel(entry)
end

Selectors:Register("drawer.currentCardMap",    function(state) return drawerCard(state).map    or "" end)
Selectors:Register("drawer.currentCardCoords", function(state) return drawerCard(state).coords or "" end)
Selectors:Register("drawer.currentCardNote",   function(state) return drawerCard(state).note   or "" end)
Selectors:Register("drawer.currentCardSource", function(state) return drawerCard(state).source or "" end)

-- ===========================================================================
-- Detail tab: mapPreviewButton active state (was Theme:RegisterVariant)
-- ===========================================================================

Selectors:Register("detail.mapPreviewActive", function(state)
    local map = state.account.ui.map
    return not map or map.shown ~= false
end)

-- ===========================================================================
-- Library tab: per-filter-chip active state (was PaintFilterChips imperative)
-- ===========================================================================

local function libFilterIs(name)
    return function(state)
        local lib = libUI(state)
        return (lib.activeFilter or "all") == name
    end
end
Selectors:Register("library.filterAllActive",     libFilterIs("all"))
Selectors:Register("library.filterReadyActive",   libFilterIs("ready"))
Selectors:Register("library.filterHasNoteActive", libFilterIs("has_note"))
Selectors:Register("library.filterBlockedActive", libFilterIs("blocked"))

-- Drawer setNoteBody + applyLog (last imperative pushes retired from Drawer:Refresh).
Selectors:Register("drawer.setNoteBody", function(state)
    local set = drawerSet(state)
    local note = set and set.payload and set.payload.note or ""
    return note ~= "" and note or "No note for this set. Edit in Library."
end)

Selectors:Register("drawer.applyLog", function(state)
    return Selectors.BuildApplyLogItems(state)
end)

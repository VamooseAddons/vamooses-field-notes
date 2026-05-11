VFN = VFN or {}

local function DeepCopy(value)
    if type(value) ~= "table" then return value end

    local out = {}
    for k, v in pairs(value) do
        out[k] = DeepCopy(v)
    end
    return out
end

local function ClearTable(t)
    if wipe then
        wipe(t)
        return t
    end

    for k in pairs(t) do
        t[k] = nil
    end
    return t
end

local function NewCache()
    return {
        indexesVersion = VFN.Constants.INDEXES_VERSION,
        byCharacter = {},
        byLibrary = {},
        bySource = {},
        byMap = {},
        byTag = {},
        byEntity = {},
        byExternalRef = {},
    }
end

local function NewConfig()
    return {
        debug = false,
        showMinimapButton = true,
        characterFilter = "current",
        waypointBackend = "auto",
    }
end

-- Account-persisted UI state: things that should survive /reload.
-- Selection (which set is open), layout preferences (map shown), per-account
-- character pinning. NOT: transient nav like which group is highlighted or
-- whether the source-text toggle is on this session -- those live in
-- session.ui (see NewSessionUIState below).
local function NewUIState()
    return {
        streamCharacter = nil,
        selectedSetID = nil,
        view = nil,                 -- which tab is active ("library" | "config" | nil)
        map = {
            mode = "docked",
            shown = true,
            scale = 1.0,
            pos = nil,
        },
    }
end

-- Session-only UI state: never persisted to SavedVariables. Reset to
-- defaults on every /reload. Lives here for the same reasons account.ui
-- exists (one place to look) but the bucket name documents the lifetime.
local function NewSessionUIState()
    return {
        selectedGroupKey   = nil,
        selectedEntryIndex = nil,
        sendScope          = "selected",
        showSourceText     = false,
    }
end

-- Per-view scratch space (search text, scroll position, etc). Each view
-- gets its own subtable. Library tracks the user's currently-selected
-- library + card within library view (independent of detail-view selection).
local function NewSessionViewLocal()
    return {
        library = {
            selectedLibraryID = nil,    -- which library is shown in center
            selectedSetID     = nil,    -- which card is shown in right (coords)
            -- Find-state: search/filter/sort applied to the middle "Finder"
            -- column. Pure session scratch -- not persisted across /reloads.
            searchQuery  = "",                 -- editbox text (lowercased at filter time)
            activeFilter = "all",              -- "all" | "ready" | "has_note" | "blocked"
            sortOrder    = "recent",           -- "recent" | "alpha" | "size"
        },
        stream  = {
            -- Which library's cards the stream-history list shows. nil =
            -- defaultLibraryID (matches the legacy behaviour).
            libraryID = nil,
        },
        config  = {},
    }
end

local function NewDefaultSession()
    return {
        ui        = NewSessionUIState(),
        viewLocal = NewSessionViewLocal(),
        applyLog  = {},   -- moved out of account; rolling history is session-scoped
    }
end

local function NewDefaultState()
    local state = {
        account = {
            schemaVersion = VFN.Constants.SCHEMA_VERSION,
            libraries = {},
            defaultLibraryID = VFN.Constants.DEFAULT_LIBRARY_ID,
            sets = {},
            cache = NewCache(),
            config = NewConfig(),
            ui = NewUIState(),
        },
        session = NewDefaultSession(),
        characters = {},
    }

    state.config = state.account.config
    state.ui = state.account.ui
    return state
end

local function ApplyRootAliases(state)
    state.config = state.account.config
    state.ui = state.account.ui
end

local function EnsureConfig(account)
    local defaults = NewConfig()
    account.config = account.config or {}
    for key, value in pairs(defaults) do
        if account.config[key] == nil then
            account.config[key] = value
        end
    end
end

local function EnsureUI(account)
    local defaults = NewUIState()
    account.ui = account.ui or {}
    for key, value in pairs(defaults) do
        if account.ui[key] == nil then
            account.ui[key] = DeepCopy(value)
        end
    end
    account.ui.map = account.ui.map or DeepCopy(defaults.map)
    for key, value in pairs(defaults.map) do
        if account.ui.map[key] == nil then
            account.ui.map[key] = DeepCopy(value)
        end
    end
end

-- Session bucket: created on first call, then validated each time. Critical
-- that this is IDEMPOTENT -- EnsureStateShape runs at the start of every
-- Dispatch, so a "always reset" implementation would wipe transient state
-- on every state-change and create infinite refresh loops (any controller
-- that dispatches during Refresh would trigger Refresh again with reset state).
-- Session is rebuilt fresh on /reload via NewDefaultState, NOT here.
local function EnsureSession(state)
    state.session = state.session or NewDefaultSession()
    state.session.ui        = state.session.ui        or NewSessionUIState()
    state.session.viewLocal = state.session.viewLocal or NewSessionViewLocal()
    state.session.applyLog  = state.session.applyLog  or {}
end

local function EnsureCache(state)
    state.account.cache = state.account.cache or NewCache()

    local cache = state.account.cache
    cache.indexesVersion = VFN.Constants.INDEXES_VERSION
    cache.byCharacter = cache.byCharacter or {}
    cache.byLibrary = cache.byLibrary or {}
    cache.bySource = cache.bySource or {}
    cache.byMap = cache.byMap or {}
    cache.byTag = cache.byTag or {}
    cache.byEntity = cache.byEntity or {}
    cache.byExternalRef = cache.byExternalRef or {}
end

local function EnsureDefaultLibrary(state)
    local account = state.account
    local id = account.defaultLibraryID or VFN.Constants.DEFAULT_LIBRARY_ID
    account.defaultLibraryID = id
    account.libraries = account.libraries or {}
    account.libraries[id] = account.libraries[id] or {
        id = id,
        name = "Default",
        visibility = { scope = "account", character = nil },
        setIDs = {},
        createdAt = time(),
        updatedAt = time(),
        lastOpenedAt = nil,
        archived = false,
        deletedAt = nil,
        isDefault = true,    -- protected from deletion
        tags = {},
        display = { color = nil, icon = nil },
    }
    account.libraries[id].setIDs = account.libraries[id].setIDs or {}
    account.libraries[id].isDefault = true
end

local function EnsureStateShape(state)
    state.account = state.account or {}
    state.account.schemaVersion = VFN.Constants.SCHEMA_VERSION
    state.account.libraries = state.account.libraries or {}
    state.account.defaultLibraryID = state.account.defaultLibraryID or VFN.Constants.DEFAULT_LIBRARY_ID
    state.account.sets = state.account.sets or {}
    state.characters = state.characters or {}

    EnsureConfig(state.account)
    EnsureUI(state.account)
    EnsureCache(state)
    EnsureDefaultLibrary(state)
    EnsureSession(state)
    ApplyRootAliases(state)
end

local function AddToList(list, value)
    for _, existing in ipairs(list) do
        if existing == value then return end
    end
    list[#list + 1] = value
end

local function RemoveFromList(list, value)
    local i = 1
    while i <= #list do
        if list[i] == value then
            table.remove(list, i)
        else
            i = i + 1
        end
    end
end

local function CountTable(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

local function GenerateSetID(state, library)
    local suffix = CountTable(state.account.sets) + #library.setIDs + 1
    local id = "set_" .. tostring(time()) .. "_" .. tostring(suffix)

    while state.account.sets[id] do
        suffix = suffix + 1
        id = "set_" .. tostring(time()) .. "_" .. tostring(suffix)
    end

    return id
end

-- TriggerStateChanged forward-declared here so reducers below can call it.
-- Real fan-out lives on the Store table (defined after VFN.Store exists);
-- this stub redirects to it.
local function TriggerStateChanged(action)
    if VFN.Store and VFN.Store._Notify then VFN.Store:_Notify(action) end
end

local function AddExternalRef(cache, ref, setID, entryID, itemID)
    if not ref or not ref.addon or not ref.type or not ref.id then return end

    cache.byExternalRef[ref.addon] = cache.byExternalRef[ref.addon] or {}
    cache.byExternalRef[ref.addon][ref.type] = cache.byExternalRef[ref.addon][ref.type] or {}
    cache.byExternalRef[ref.addon][ref.type][ref.id] = cache.byExternalRef[ref.addon][ref.type][ref.id] or {}

    local out = { setID = setID }
    if entryID then out.entryID = entryID end
    if itemID then out.itemID = itemID end

    local list = cache.byExternalRef[ref.addon][ref.type][ref.id]
    list[#list + 1] = out
end

local function IndexSet(state, set, libraryIDOverride)
    local cache = state.account.cache
    local setID = set.id
    local libraryID = libraryIDOverride or set.libraryID or state.account.defaultLibraryID

    AddExternalRef(cache, set.external, setID)

    cache.byLibrary[libraryID] = cache.byLibrary[libraryID] or {}
    AddToList(cache.byLibrary[libraryID], setID)

    local character = set.visibility and set.visibility.character
    if character then
        cache.byCharacter[character] = cache.byCharacter[character] or {}
        AddToList(cache.byCharacter[character], setID)
    end

    local source = set.source or {}
    if source.addon and source.key then
        cache.bySource[source.addon] = cache.bySource[source.addon] or {}
        cache.bySource[source.addon][source.key] = setID
    end

    for _, tag in ipairs(set.tags or {}) do
        cache.byTag[tag] = cache.byTag[tag] or {}
        AddToList(cache.byTag[tag], setID)
    end

    for entryIndex, entry in ipairs(set.entries or {}) do
        local entryID = entry.id or ("entry_" .. tostring(entryIndex))
        if entry.coordMapID then
            cache.byMap[entry.coordMapID] = cache.byMap[entry.coordMapID] or {}
            cache.byMap[entry.coordMapID][#cache.byMap[entry.coordMapID] + 1] = {
                setID = setID,
                entryID = entryID,
            }
        end

        if entry.entity and entry.entity.type and entry.entity.id then
            local entityType = entry.entity.type
            local entityID = entry.entity.id
            cache.byEntity[entityType] = cache.byEntity[entityType] or {}
            cache.byEntity[entityType][entityID] = cache.byEntity[entityType][entityID] or {}
            cache.byEntity[entityType][entityID][#cache.byEntity[entityType][entityID] + 1] = {
                setID = setID,
                entryID = entryID,
            }
        end

        AddExternalRef(cache, entry.ref, setID, entryID)
    end

    for itemIndex, item in ipairs(set.items or {}) do
        local itemID = item.id or ("item_" .. tostring(itemIndex))
        AddExternalRef(cache, item.ref, setID, nil, itemID)
        AddExternalRef(cache, item.vendorRef, setID, nil, itemID)
    end
end

VFN.Store = {
    state = NewDefaultState(),
    reducers = {},
    saveTimer = nil,
    _subscribers = {},
}

-- Subscribe/Unsubscribe/_Notify -- Redux-style fan-out. Every Dispatch calls
-- _Notify(action) which fans out to every registered subscriber with the
-- action name. Errors in one subscriber don't break the others (pcall).
-- Subscribers receive (action) -- no payload, no diff hint. They re-read
-- state from scratch and reconcile their widgets to it.
function VFN.Store:Subscribe(fn)
    if type(fn) ~= "function" then return nil end
    self._subscribers[fn] = true
    return fn
end

function VFN.Store:Unsubscribe(fn)
    if fn then self._subscribers[fn] = nil end
end

function VFN.Store:_Notify(action)
    for fn in pairs(self._subscribers) do
        local ok, err = pcall(fn, action)
        if not ok then
            local printer = _G and _G.print or function() end
            printer("|cffff5555[VFN Store] subscriber error: " .. tostring(err) .. "|r")
        end
    end
end

function VFN.Store:GetState()
    return self.state
end

function VFN.Store:EnsureDefaultLibrary()
    EnsureDefaultLibrary(self.state)
end

function VFN.Store:EnsureCache()
    EnsureCache(self.state)
end

function VFN.Store:RebuildIndexes()
    EnsureCache(self.state)

    local cache = self.state.account.cache
    ClearTable(cache.byCharacter)
    ClearTable(cache.byLibrary)
    ClearTable(cache.bySource)
    ClearTable(cache.byMap)
    ClearTable(cache.byTag)
    ClearTable(cache.byEntity)
    ClearTable(cache.byExternalRef)

    for libraryID, library in pairs(self.state.account.libraries) do
        for _, setID in ipairs(library.setIDs or {}) do
            local set = self.state.account.sets[setID]
            if set and not set.deletedAt then
                IndexSet(self.state, set, libraryID)
            end
        end
    end
end

function VFN.Store:LoadFromSavedVariables()
    VFN_DB = VFN_DB or {}

    self.state = NewDefaultState()
    if VFN_DB.account then
        self.state.account = VFN_DB.account
    end
    if VFN_DB.characters then
        self.state.characters = VFN_DB.characters
    end

    EnsureStateShape(self.state)
    self:RebuildIndexes()
end

function VFN.Store:QueueSave()
    if self.saveTimer and self.saveTimer.Cancel then
        self.saveTimer:Cancel()
    end

    if C_Timer and C_Timer.NewTimer then
        local store = self
        self.saveTimer = C_Timer.NewTimer(1, function()
            store:Flush()
        end)
    else
        self:Flush()
    end
end

-- Per-set fields that are runtime-only and must be stripped from
-- SavedVariables. `sendState` carries TomTom waypoint handles + transient
-- "we just dispatched these entries" markers -- meaningless after /reload.
-- Persisting it leaves dead state on disk and makes the SavedVariables file
-- larger than it should be. Add new transient fields here as they appear.
local SET_TRANSIENT_FIELDS = {
    sendState = true,
}

-- Build a persisted snapshot of state.account by deep-copying sets minus
-- their transient fields. Other branches of account (libraries, ui, config,
-- applyLog/cache as appropriate) pass through by reference. Pure-data; no
-- side effects on self.state.
local function BuildPersistedAccount(account)
    if not account then return account end
    local out = {}
    for k, v in pairs(account) do out[k] = v end
    if account.sets then
        local sets = {}
        for setID, set in pairs(account.sets) do
            local copy = {}
            for sk, sv in pairs(set) do
                if not SET_TRANSIENT_FIELDS[sk] then copy[sk] = sv end
            end
            sets[setID] = copy
        end
        out.sets = sets
    end
    return out
end

function VFN.Store:Flush()
    VFN_DB = VFN_DB or {}
    VFN_DB.account = BuildPersistedAccount(self.state.account)
    VFN_DB.characters = self.state.characters
    self.saveTimer = nil
end

-- Named mutators now funnel through Dispatch -- the reducer's elseif chain
-- is the single mutation surface. These wrappers exist so call-sites can
-- read `Store:CreateSet(set)` instead of `Store:Dispatch(ACTIONS.SET_CREATE, set)`,
-- and so a future caller can ignore the action constant entirely.
function VFN.Store:CreateSet(set)
    return self:Dispatch(VFN.Constants.ACTIONS.SET_CREATE, set or {})
end

function VFN.Store:DeleteSet(setID)
    local result = self:Dispatch(VFN.Constants.ACTIONS.SET_DELETE, { setID = setID })
    return result and result.ok or false
end

function VFN.Store:OpenSet(setID)
    local result = self:Dispatch(VFN.Constants.ACTIONS.SET_OPEN, { setID = setID })
    return result and result.ok or false
end

function VFN.Store:CloseSet()
    local result = self:Dispatch(VFN.Constants.ACTIONS.SET_CLOSE)
    return result and result.ok or false
end

function VFN.Store:Dispatch(action, payload)
    EnsureStateShape(self.state)

    if action == VFN.Constants.ACTIONS.CONFIG_SET then
        payload = payload or {}
        if payload.key then
            self.state.account.config[payload.key] = payload.value
            ApplyRootAliases(self.state)
            self:QueueSave()
            TriggerStateChanged(action)
        end
    elseif action == VFN.Constants.ACTIONS.HARD_RESET then
        self.state = NewDefaultState()
        EnsureStateShape(self.state)
        self:QueueSave()
        TriggerStateChanged(action)
    elseif action == VFN.Constants.ACTIONS.UI_SET_PERSISTENT then
        -- account.ui write (persists across /reload). The caller picked the
        -- bucket -- no routing table, no key-allowlist lookup. Typos at the
        -- call site land in account.ui without warning, but they're typos
        -- in named code rather than typos in dispatch strings.
        payload = payload or {}
        local key = payload.key
        if key == nil then return end
        if self.state.account.ui[key] ~= payload.value then
            self.state.account.ui[key] = payload.value
            self:QueueSave()
            TriggerStateChanged(action)
        end
    elseif action == VFN.Constants.ACTIONS.UI_SET_TRANSIENT then
        -- session.ui write (cleared on /reload). No QueueSave -- the whole
        -- session bucket is rebuilt fresh at addon load.
        payload = payload or {}
        local key = payload.key
        if key == nil then return end
        if self.state.session.ui[key] ~= payload.value then
            self.state.session.ui[key] = payload.value
            TriggerStateChanged(action)
        end
    elseif action == VFN.Constants.ACTIONS.UI_TOGGLE_MAP then
        local map = self.state.account.ui.map or {}
        map.shown = (map.shown == false)
        self.state.account.ui.map = map
        self:QueueSave()
        TriggerStateChanged(action)
    elseif action == VFN.Constants.ACTIONS.APPLY_LOG_APPEND then
        -- Apply log: bounded ring buffer of recent send / remove events.
        -- Lives in session.applyLog (transient -- fresh history each
        -- session). Drawer-side rendering reads it; Controller_Detail
        -- dispatches. NOT persisted -- no QueueSave.
        payload = payload or {}
        local line = payload.line
        if type(line) ~= "string" or line == "" then return end
        local log = self.state.session.applyLog or {}
        log[#log + 1] = { line = line, at = (time and time()) or 0 }
        local MAX = 50
        if #log > MAX then
            local drop = #log - MAX
            for i = 1, MAX do log[i] = log[i + drop] end
            for i = MAX + 1, #log do log[i] = nil end
        end
        self.state.session.applyLog = log
        TriggerStateChanged(action)
    elseif action == VFN.Constants.ACTIONS.VIEWLOCAL_SET then
        -- Per-view scratch space writes (e.g. library's selectedLibraryID /
        -- selectedSetID). Path is { view, key } -- session.viewLocal[view][key].
        payload = payload or {}
        local view, key = payload.view, payload.key
        if type(view) ~= "string" or type(key) ~= "string" then return end
        local bucket = self.state.session.viewLocal[view]
        if not bucket then
            bucket = {}
            self.state.session.viewLocal[view] = bucket
        end
        if bucket[key] ~= payload.value then
            bucket[key] = payload.value
            -- Session writes do NOT persist.
            TriggerStateChanged(action)
        end
    elseif action == VFN.Constants.ACTIONS.LIBRARY_CREATE then
        payload = payload or {}
        local name = type(payload.name) == "string" and payload.name:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if name == "" then return nil end
        local libID = "lib_" .. tostring(time()) .. "_" .. tostring(math.random(1000, 9999))
        -- seedKey: optional stable identifier for libraries planted by the
        -- LibrarySeeder. Survives rename, so the seeder can find-and-skip
        -- by key instead of by display name. Absent on user-created libs.
        local seedKey = type(payload.seedKey) == "string" and payload.seedKey ~= "" and payload.seedKey or nil
        self.state.account.libraries[libID] = {
            id = libID,
            name = name,
            seedKey = seedKey,
            visibility = { scope = "account", character = nil },
            setIDs = {},
            createdAt = time(),
            updatedAt = time(),
            isDefault = false,
            archived = false,
            deletedAt = nil,
            tags = {},
            display = { color = nil, icon = nil },
        }
        self:QueueSave()
        TriggerStateChanged(action)
        return { libraryID = libID }
    elseif action == VFN.Constants.ACTIONS.LIBRARY_DELETE then
        payload = payload or {}
        local libID = payload.libraryID
        local lib = libID and self.state.account.libraries[libID] or nil
        if not lib or lib.isDefault then return end  -- Default is protected
        local defaultID = self.state.account.defaultLibraryID
        local defaultLib = self.state.account.libraries[defaultID]
        if not defaultLib then return end
        -- Move all sets in this library to the Default library before deletion.
        for _, setID in ipairs(lib.setIDs or {}) do
            local set = self.state.account.sets[setID]
            if set then set.libraryID = defaultID end
            defaultLib.setIDs[#defaultLib.setIDs + 1] = setID
        end
        defaultLib.updatedAt = time()
        self.state.account.libraries[libID] = nil
        self:QueueSave()
        TriggerStateChanged(action)
    elseif action == VFN.Constants.ACTIONS.LIBRARY_RENAME then
        payload = payload or {}
        local lib = payload.libraryID and self.state.account.libraries[payload.libraryID] or nil
        local name = type(payload.name) == "string" and payload.name:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if not lib or name == "" then return end
        lib.name = name
        lib.updatedAt = time()
        self:QueueSave()
        TriggerStateChanged(action)
    elseif action == VFN.Constants.ACTIONS.SET_CREATE then
        -- Reducer body for Store:CreateSet (which dispatches to this case).
        -- Returns { setID = id } on success, { error = "..." } on rejection.
        local set = payload or {}
        local libraryID = set.libraryID or self.state.account.defaultLibraryID
        local library = self.state.account.libraries[libraryID]
        if not library then
            libraryID = self.state.account.defaultLibraryID
            library = self.state.account.libraries[libraryID]
        end

        local id = set.id or GenerateSetID(self.state, library)
        if set.id and self.state.account.sets[id] then
            return { error = "duplicate_id" }
        end
        if #library.setIDs >= VFN.Constants.MAX_SETS_PER_LIBRARY then
            return { error = "library_cap" }
        end

        local copy = DeepCopy(set)
        copy.id = id
        copy.libraryID = libraryID
        copy.title      = copy.title      or "Untitled Field Note"
        copy.source     = copy.source     or { type = "manual" }
        copy.visibility = copy.visibility or { scope = "account", character = nil }
        copy.entries    = copy.entries    or {}
        copy.items      = copy.items      or {}
        copy.createdAt  = copy.createdAt  or time()
        copy.updatedAt  = time()
        copy.deletedAt  = nil

        self.state.account.sets[id] = copy
        RemoveFromList(library.setIDs, id)
        table.insert(library.setIDs, 1, id)
        library.updatedAt = time()

        self:RebuildIndexes()
        self:QueueSave()
        TriggerStateChanged(action)
        return { setID = id }
    elseif action == VFN.Constants.ACTIONS.SET_DELETE then
        local setID = payload and payload.setID
        local set = setID and self.state.account.sets[setID] or nil
        if not set then return { ok = false } end

        set.deletedAt = time()
        set.updatedAt = time()

        local libraryID = set.libraryID or self.state.account.defaultLibraryID
        local library = self.state.account.libraries[libraryID]
        if library and library.setIDs then
            RemoveFromList(library.setIDs, setID)
            library.updatedAt = time()
        end
        if self.state.account.ui.selectedSetID == setID then
            self.state.account.ui.selectedSetID = nil
        end

        self:RebuildIndexes()
        self:QueueSave()
        TriggerStateChanged(action)
        return { ok = true }
    elseif action == VFN.Constants.ACTIONS.SET_OPEN then
        local setID = payload and payload.setID
        local set = setID and self.state.account.sets[setID] or nil
        if not set or set.deletedAt then return { ok = false } end

        self.state.account.ui.selectedSetID = setID
        set.lastOpenedAt = time()
        self:QueueSave()
        TriggerStateChanged(action)
        return { ok = true }
    elseif action == VFN.Constants.ACTIONS.SET_CLOSE then
        self.state.account.ui.selectedSetID = nil
        self:QueueSave()
        TriggerStateChanged(action)
        return { ok = true }
    elseif action == VFN.Constants.ACTIONS.SET_UPDATE then
        -- Replace a set's editable triple (title / sourceText / note) AND
        -- the derived sourceLines + entries (post re-parse). The triple
        -- ALWAYS arrives as a complete object at payload.fields -- partial
        -- updates aren't supported. Controllers do the impure parse/resolve
        -- work and pass the resolved entries here so the reducer stays
        -- pure-data.
        payload = payload or {}
        local set = payload.setID and self.state.account.sets[payload.setID] or nil
        local fields = payload.fields
        if not (set and type(fields) == "table") then return end
        set.title = type(fields.title) == "string" and fields.title or ""
        set.sourceText = type(fields.sourceText) == "string" and fields.sourceText or ""
        set.payload = set.payload or {}
        set.payload.note = type(fields.note) == "string" and fields.note or ""
        if type(payload.sourceLines) == "table" then set.sourceLines = payload.sourceLines end
        if type(payload.entries) == "table"     then set.entries     = payload.entries     end
        set.updatedAt = time()
        self:RebuildIndexes()  -- entries changed -> map/dedup indexes too
        self:QueueSave()
        TriggerStateChanged(action)
    elseif action == VFN.Constants.ACTIONS.SET_MOVE_LIBRARY then
        payload = payload or {}
        local setID = payload.setID
        local toID  = payload.toLibraryID
        local set   = setID and self.state.account.sets[setID] or nil
        local toLib = toID and self.state.account.libraries[toID] or nil
        if not (set and toLib) then return end
        local fromID  = set.libraryID or self.state.account.defaultLibraryID
        if fromID == toID then return end
        local fromLib = self.state.account.libraries[fromID]
        if fromLib and fromLib.setIDs then
            for i, id in ipairs(fromLib.setIDs) do
                if id == setID then table.remove(fromLib.setIDs, i); break end
            end
            fromLib.updatedAt = time()
        end
        toLib.setIDs = toLib.setIDs or {}
        toLib.setIDs[#toLib.setIDs + 1] = setID
        toLib.updatedAt = time()
        set.libraryID = toID
        set.updatedAt = time()
        self:QueueSave()
        TriggerStateChanged(action)
    end
end

VFN = VFN or {}
VFN.WorldMapPins = VFN.WorldMapPins or {}
VFNWorldMapPinMixin = VFNWorldMapPinMixin or {}

local WMP = VFN.WorldMapPins
local PIN_TEMPLATE = "VFNWorldMapPinTemplate"
local INVALID_STATUSES = {
    invalid = true,
    unresolved = true,
    deleted = true,
    archived = true,
}

local provider
local refreshQueued = false
local initialized = false
local sentEntryIDs = {}
local REFRESH_ACTIONS = {
    VFN_SET_CREATE = true,
    VFN_SET_DELETE = true,
    VFN_SET_OPEN = true,
    VFN_SET_CLOSE = true,
    VFN_HARD_RESET = true,
    VFN_PIN_STATE_CHANGED = true,
    VFN_WAYPOINTS_SENT = true,
    VFN_WAYPOINTS_REMOVED = true,
}

local function Defer(fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(0, fn)
    else
        fn()
    end
end

local function IsInCombat()
    return InCombatLockdown and InCombatLockdown()
end

-- Defer pin refreshes that arrive during combat. Per spec section 15.7,
-- PLAYER_REGEN_* events are owned by CombatMiddleware; modules NEVER call
-- _internalSubscribe for the regen events themselves. CombatMiddleware
-- dispatches VFN_COMBAT_EXIT through the chain on combat-end; the Store
-- subscription below (onInitialize) sees that action and replays the
-- queued refresh.
local function QueueCombatRefresh()
    refreshQueued = true
end

local function GetSelectedSet()
    local account = VFN.Store:GetState().account
    local selectedSetID = account.ui.selectedSetID
    local set = selectedSetID and account.sets[selectedSetID] or nil
    if not set or set.deletedAt or set.archived then return nil, nil end
    return selectedSetID, set
end

local function IsRenderableEntry(entry)
    if type(entry) ~= "table" then return false end
    if entry.deletedAt or entry.archived then return false end
    if INVALID_STATUSES[entry.status] then return false end
    if type(entry.coordMapID) ~= "number" then return false end
    if type(entry.x) ~= "number" or type(entry.y) ~= "number" then return false end
    return entry.x >= 0 and entry.x <= 1 and entry.y >= 0 and entry.y <= 1
end

local function EntryMatchesMap(entry, currentMapID)
    return entry.displayMapID == currentMapID or entry.coordMapID == currentMapID
end

local function SetPinColor(pin, entryID)
    if not pin or not pin.Dot then return end
    -- Stash sent state on the texture and route paint through
    -- Theme.Skinners.PinDot so a palette swap repaints automatically.
    -- (PinDot uses _vfnSelected to pick warning-vs-accent; for world-map
    -- pins "sent" maps to the warning/highlight semantic.)
    VFN.Theme:Register(pin.Dot, "PinDot", { selected = sentEntryIDs[entryID] and true or false })
    if pin.Dot.SetAlpha then
        local constants = VFN.Constants or {}
        local alpha = sentEntryIDs[entryID] and constants.WORLD_MAP_PIN_SENT_ALPHA or constants.WORLD_MAP_PIN_ALPHA
        if alpha then pin.Dot:SetAlpha(alpha) end
    end
end

local function RenderPins(mapProvider, currentMapID)
    local setID, set = GetSelectedSet()
    if not set then return end
    local map = mapProvider:GetMap()

    for index, entry in ipairs(set.entries or {}) do
        local entryID = entry.id or ("entry:" .. tostring(index))
        if IsRenderableEntry(entry) and EntryMatchesMap(entry, currentMapID) then
            local pin = map:AcquirePin(PIN_TEMPLATE)
            pin:SetPosition(entry.x, entry.y)
            if pin.SetEntry then
                pin:SetEntry(entry, set, setID, entryID)
            else
                pin._entry = entry
                pin._set = set
                pin._setID = setID
                pin._entryID = entryID
                pin._title = entry.label or set.title or "Field Note"
            end
            SetPinColor(pin, entryID)
        end
    end
end

local function AttachProvider()
    if provider or not WorldMapFrame or not MapCanvasDataProviderMixin or not CreateFromMixins then return end

    provider = CreateFromMixins(MapCanvasDataProviderMixin)

    function provider:RemoveAllData()
        self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
    end

    function provider:RefreshAllData()
        if IsInCombat() then
            QueueCombatRefresh()
            return
        end

        self:RemoveAllData()
        local map = self:GetMap()
        local mapID = map and map.GetMapID and map:GetMapID() or nil
        if not mapID then return end
        RenderPins(self, mapID)
    end

    WorldMapFrame:AddDataProvider(provider)
end

-- ADDON_LOADED handler for Blizzard_WorldMap. Now wired declaratively via
-- Modules:Declare's blizzardEvents (see bottom of file). This function is
-- the handler body; it runs when the engine fires the subscription.
local function OnBlizzardWorldMapLoaded(_self)
    if not WorldMapFrame then return end
    AttachProvider()
    WMP:Refresh()
end

function VFN.WorldMapPins:Refresh()
    if not provider then return end
    if IsInCombat() then
        QueueCombatRefresh()
        return
    end
    provider:RefreshAllData()
end

function VFNWorldMapPinMixin:OnLoad()
    if self.UseFrameLevelType then self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI") end
    if self.SetScalingLimits then self:SetScalingLimits(1, 1.0, 1.2) end
    if self.EnableMouse then self:EnableMouse(true) end
    if self.RegisterForClicks then self:RegisterForClicks("LeftButtonUp") end
    if self.SetScript then
        self:SetScript("OnEnter", self.OnMouseEnter)
        self:SetScript("OnLeave", self.OnMouseLeave)
        self:SetScript("OnClick", self.OnClick)
    end
end

function VFNWorldMapPinMixin:SetPassThroughButtons()
end

function VFNWorldMapPinMixin:CheckMouseButtonPassthrough()
    return false
end

function VFNWorldMapPinMixin:SetEntry(entry, set, setID, entryID)
    self._entry = entry
    self._set = set
    self._setID = setID
    self._entryID = entryID
    self._title = entry.label or entry.mapName or set.title or "Field Note"
    self._mapName = entry.mapName
    self._rawX = entry.rawX
    self._rawY = entry.rawY
end

function VFNWorldMapPinMixin:OnMouseEnter()
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self._title or "Field Note", 1, 1, 1)
    if self._mapName then
        GameTooltip:AddLine(self._mapName, 0.7, 0.7, 0.7)
    end
    local entry = self._entry or {}
    local x = self._rawX or (type(entry.x) == "number" and entry.x * 100) or nil
    local y = self._rawY or (type(entry.y) == "number" and entry.y * 100) or nil
    if x and y then
        GameTooltip:AddLine(string.format("%.1f, %.1f", x, y), 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine("Left-click: open Field Notes", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

function VFNWorldMapPinMixin:OnMouseLeave()
    if GameTooltip then GameTooltip:Hide() end
end

function VFNWorldMapPinMixin:OnClick(button)
    if button and button ~= "LeftButton" then return end
    if self._setID then VFN.Store:OpenSet(self._setID) end
    Defer(function()
        -- C_Timer.After(0, ...) fires next frame, possibly during combat.
        -- Toggle ultimately Show/Hides VFN_MainFrame -- guard so we don't
        -- mutate the UI tree under combat lockdown (RefreshMainWindow has
        -- a queue-replay for this case, but ToggleMainWindow itself does
        -- not, so we bail here cleanly).
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        VFN:ToggleMainWindow()
    end)
end

-- Module registration: onInitialize attaches if WorldMapFrame is already
-- present; otherwise the blizzardEvents subscription fires when the map
-- module loads later. No legacy Init() entry point -- Modules:Boot owns
-- the lifecycle.
VFN.Modules:Declare({
    name = "WorldMapPins",
    -- Spec section 14: `dependencies` lists OTHER registered modules whose
    -- onInitialize must run first. Engine singletons (Store, Theme,
    -- BlizzardEvents, Constants) are NOT modules -- they boot in Init.lua
    -- before Modules:Boot runs, so depending on them is implicit. Today
    -- WorldMapPins has no peer-module deps.
    dependencies = {},
    OnBlizzardWorldMapLoaded = OnBlizzardWorldMapLoaded,
    blizzardEvents = {
        ADDON_LOADED = {
            handler = "OnBlizzardWorldMapLoaded",
            filter  = function(addonName) return addonName == "Blizzard_WorldMap" end,
            once    = true,
        },
    },
    onInitialize = function()
        if initialized then return end
        initialized = true

        if WorldMapFrame then
            AttachProvider()
        end

        -- Subscribe to Store changes. We DO care about action granularity
        -- here (only specific actions invalidate pin paint), so we filter
        -- on action. VFN_COMBAT_EXIT is the spec-aligned replacement for
        -- the old direct _internalSubscribe -- when combat ends and a
        -- refresh was queued mid-combat, replay it.
        local A = VFN.Constants.ACTIONS
        VFN.Store:Subscribe(function(action)
            if action == A.COMBAT_EXIT then
                if refreshQueued then
                    refreshQueued = false
                    WMP:Refresh()
                end
            elseif REFRESH_ACTIONS[action] then
                WMP:Refresh()
            end
        end)
    end,
})

function WMP:SetSentEntries(entries, set)
    wipe(sentEntryIDs)

    local sendState = set and set.sendState or nil
    if sendState and type(sendState.sentEntryIDs) == "table" then
        for _, entryID in ipairs(sendState.sentEntryIDs) do
            sentEntryIDs[entryID] = true
        end
    else
        for index, entry in ipairs(entries or {}) do
            sentEntryIDs[entry.id or ("entry:" .. tostring(index))] = true
        end
    end

    self:Refresh()
end

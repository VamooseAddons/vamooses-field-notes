VFN = VFN or {}
VFN.Minimap = VFN.Minimap or {}

local Minimap = VFN.Minimap
local ADDON_KEY = "VamoosesFieldNotes"
local ICON_PATH = "Interface\\Icons\\INV_Misc_Note_01"

local launcher
local dbIcon
local initialized = false

local function EnsureMinimapDB()
    VFN_DB = VFN_DB or {}
    if type(VFN_DB.minimap) ~= "table" then
        VFN_DB.minimap = {
            minimapPos = VFN.Constants.MINIMAP_DEFAULT_POSITION,
            hide = false,
            lock = false,
        }
    end
    VFN_DB.minimap.minimapPos = VFN_DB.minimap.minimapPos or VFN.Constants.MINIMAP_DEFAULT_POSITION
    VFN_DB.minimap.lock = VFN_DB.minimap.lock or false
    if VFN_DB.minimap.hide == nil then
        VFN_DB.minimap.hide = VFN.Store:GetState().account.config.showMinimapButton == false
    end
    return VFN_DB.minimap
end

local function ToggleWindow()
    if VFN.ToggleMainWindow then
        VFN:ToggleMainWindow()
    end
end

function VFN.Minimap:Initialize()
    if initialized then
        self:Refresh()
        return
    end
    initialized = true

    local minimapDB = EnsureMinimapDB()
    if not LibStub then
        self:RegisterCompartment()
        return
    end

    local LDB = LibStub("LibDataBroker-1.1", true)
    if LDB and LDB.NewDataObject then
        launcher = LDB:NewDataObject(ADDON_KEY, {
            type = "launcher",
            icon = ICON_PATH,
            label = "Field Notes",
            OnClick = function(_, button)
                if button == "LeftButton" then ToggleWindow() end
            end,
            OnTooltipShow = function(tooltip)
                tooltip:AddLine("|cFF1E88E5Vamoose's Field Notes|r")
                tooltip:AddLine("Left-click: open or toggle Field Notes", 0.7, 0.7, 0.7)
                tooltip:AddLine("Drag: move button", 0.7, 0.7, 0.7)
            end,
        })
    end

    dbIcon = LibStub("LibDBIcon-1.0", true)
    if dbIcon and launcher then
        dbIcon:Register(ADDON_KEY, launcher, minimapDB)
        self:UpdateVisibility()
    end

    self:RegisterCompartment()

    VFN.Store:Subscribe(function() Minimap:Refresh() end)
end

function VFN.Minimap:Refresh()
    self:UpdateVisibility()
end

function VFN.Minimap:UpdateVisibility()
    if not dbIcon or not dbIcon.IsRegistered or not dbIcon:IsRegistered(ADDON_KEY) then return end

    local minimapDB = EnsureMinimapDB()
    local show = VFN.Store:GetState().account.config.showMinimapButton
    if show == nil then show = not minimapDB.hide end

    minimapDB.hide = not show
    if show then
        dbIcon:Show(ADDON_KEY)
    else
        dbIcon:Hide(ADDON_KEY)
    end
end

function VFN.Minimap:RegisterCompartment()
    if not AddonCompartmentFrame or not AddonCompartmentFrame.RegisterAddon then return end

    AddonCompartmentFrame:RegisterAddon({
        text = "Vamoose's Field Notes",
        icon = ICON_PATH,
        notCheckable = true,
        func = function()
            ToggleWindow()
        end,
        funcOnEnter = function(menuItem)
            if not GameTooltip then return end
            GameTooltip:SetOwner(menuItem, "ANCHOR_RIGHT")
            GameTooltip:AddLine("|cFF1E88E5Vamoose's Field Notes|r", 1, 1, 1)
            GameTooltip:AddLine("Left-click: open or toggle Field Notes", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end,
        funcOnLeave = function()
            if GameTooltip then GameTooltip:Hide() end
        end,
    })
end

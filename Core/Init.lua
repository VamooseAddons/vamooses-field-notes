VFN = VFN or {}
VFN.frame = CreateFrame("Frame")
VFN.frame:RegisterEvent("ADDON_LOADED")
VFN.frame:RegisterEvent("PLAYER_LOGIN")
VFN.frame:RegisterEvent("PLAYER_LOGOUT")

function VFN:OnInitialize()
    VFN_DB = VFN_DB or {}
    if VFN.Store and VFN.Store.LoadFromSavedVariables then
        VFN.Store:LoadFromSavedVariables()
    end
    if VFN.Theme and VFN.Theme.Initialize then
        VFN.Theme:Initialize()
    end
    -- Run all registered seeders AFTER the Store has loaded SavedVariables --
    -- seeders are idempotent and bail fast if their target library exists.
    if VFN.LibrarySeeder and VFN.LibrarySeeder.Run then
        VFN.LibrarySeeder:Run()
    end
end

function VFN:OnEnable()
    if VFN.CreateMainWindow then VFN:CreateMainWindow() end
    if VFN.Minimap and VFN.Minimap.Initialize then VFN.Minimap:Initialize() end
    if VFN.WorldMapPins and VFN.WorldMapPins.Init then VFN.WorldMapPins:Init() end
end

VFN.frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "VamoosesFieldNotes" then
        VFN:OnInitialize()
    elseif event == "PLAYER_LOGIN" then
        VFN:OnEnable()
    elseif event == "PLAYER_LOGOUT" and VFN.Store and VFN.Store.Flush then
        VFN.Store:Flush()
    end
end)

SLASH_VFN1 = "/vfn"
SlashCmdList["VFN"] = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "debug" and VFN.Store then
        VFN.Store:Dispatch("VFN_CONFIG_SET", { key = "debug", value = not VFN.Store:GetState().config.debug })
    elseif msg == "minimap" and VFN.Store then
        VFN.Store:Dispatch("VFN_CONFIG_SET", { key = "showMinimapButton", value = not VFN.Store:GetState().config.showMinimapButton })
    elseif msg == "hardreset" and VFN.Store then
        VFN.Store:Dispatch("VFN_HARD_RESET")
    elseif msg == "seed" and VFN.LibrarySeeder then
        VFN.LibrarySeeder:Run()
    elseif msg == "" or msg == "toggle" then
        if VFN.ToggleMainWindow then VFN:ToggleMainWindow() end
    elseif VFN.ToggleMainWindow then
        VFN:ToggleMainWindow()
    end
end

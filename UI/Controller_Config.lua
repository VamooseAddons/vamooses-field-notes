-- VFN.ConfigController
--
-- Behaviour layer for the config panel:
--   - cycle buttons for waypointBackend + characterFilter
--   - debug toggle
--   - hard-reset destructive action (CH.UI.Confirm popup)
--
-- All settings live in state.account.config (persisted) -- this controller
-- just dispatches CycleConfigValue / value-set actions to the Store.
-- Per-mode hint strings come from VFN.Constants.CYCLES.<cycle>.hints.

VFN = VFN or {}
VFN.ConfigController = VFN.ConfigController or {}

local ConfigController = VFN.ConfigController
local CH = VFN.ControllerHelpers

local CYCLES = VFN.Constants.CYCLES

function ConfigController:Wire(rootFrame)
    CH.UI.OnClick(rootFrame, "configPanel.backendButton", function()
        CH.Mechanics.CycleConfigValue("waypointBackend", CYCLES.waypointBackend.order, CYCLES.waypointBackend.default)
    end)
    CH.UI.OnClick(rootFrame, "configPanel.charsButton", function()
        CH.Mechanics.CycleConfigValue("characterFilter", CYCLES.characterFilter.order, CYCLES.characterFilter.default)
    end)
    CH.UI.OnClick(rootFrame, "configPanel.debugButton", function()
        local cur = CH.Mechanics.GetConfigValue("debug", false)
        CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.CONFIG_SET, { key = "debug", value = not cur })
    end)
    CH.UI.OnClick(rootFrame, "configPanel.resetButton", function()
        CH.UI.Confirm({
            id     = VFN.Constants.ACTIONS.HARD_RESET,
            text   = "Wipe ALL Field Notes and settings?\n\nThis cannot be undone.",
            accept = "Wipe",
            onAccept = function() CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.HARD_RESET) end,
        })
    end)

    -- Theme picker buttons. Each one dispatches CONFIG_SET so the choice
    -- persists (PersistenceMiddleware queues the save) AND repaints via
    -- Theme:LoadScheme so the swap is immediate. The button's active
    -- state comes from `config.theme.active.<Name>` (Selectors.lua).
    local function pickTheme(name)
        CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.CONFIG_SET,
            { key = "scheme", value = name })
        VFN.Theme:LoadScheme(name)
    end
    local THEME_BUTTONS = {
        { id = "configPanel.themeColorblindSafe",  name = "ColorblindSafe" },
        { id = "configPanel.themeMocha",           name = "Mocha" },
        { id = "configPanel.themeTokyonightNight", name = "TokyonightNight" },
        { id = "configPanel.themeRosePineMain",    name = "RosePineMain" },
        { id = "configPanel.themeGruvboxDarkHard", name = "GruvboxDarkHard" },
    }
    for _, entry in ipairs(THEME_BUTTONS) do
        local target = entry.name
        CH.UI.OnClick(rootFrame, entry.id, function() pickTheme(target) end)
    end
end

-- (No Refresh -- every config-tab widget value flows through bindings:
--  backendButton -> config.backendLabel; backendHint -> config.backendHint;
--  charsButton -> config.charactersLabel; debugButton -> config.debugLabel.)

VFN.Controllers:Register("config", ConfigController)

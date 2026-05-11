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
local W, SetText = CH.UI.W, CH.UI.SetText

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
end

-- Refresh is empty -- every config-tab widget value flows through bindings:
--   backendButton -> config.backendLabel
--   backendHint   -> config.backendHint
--   charsButton   -> config.charactersLabel
--   debugButton   -> config.debugLabel
function ConfigController:Refresh(_rootFrame, _ctx)
end

VFN.Controllers:Register("config", ConfigController)

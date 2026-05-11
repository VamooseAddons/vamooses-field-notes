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
        CH.Mechanics.Dispatch("VFN_CONFIG_SET", { key = "debug", value = not cur })
    end)
    CH.UI.OnClick(rootFrame, "configPanel.resetButton", function()
        CH.UI.Confirm({
            id     = "VFN_HARD_RESET",
            text   = "Wipe ALL Field Notes and settings?\n\nThis cannot be undone.",
            accept = "Wipe",
            onAccept = function() CH.Mechanics.Dispatch("VFN_HARD_RESET") end,
        })
    end)
end

function ConfigController:Refresh(rootFrame, _ctx)
    local be = CH.Mechanics.GetConfigValue("waypointBackend", CYCLES.waypointBackend.default)
    CH.UI.SetButtonText(W(rootFrame, "configPanel.backendButton"), CYCLES.waypointBackend.labels[be])
    SetText(W(rootFrame, "configPanel.backendHint"),
        (CYCLES.waypointBackend.hints and CYCLES.waypointBackend.hints[be]) or "")

    local cf = CH.Mechanics.GetConfigValue("characterFilter", CYCLES.characterFilter.default)
    CH.UI.SetButtonText(W(rootFrame, "configPanel.charsButton"), CYCLES.characterFilter.labels[cf])

    local debug = CH.Mechanics.GetConfigValue("debug", false)
    CH.UI.SetButtonText(W(rootFrame, "configPanel.debugButton"), debug and "Debug: on" or "Debug: off")
end

VFN.Controllers:Register("config", ConfigController)

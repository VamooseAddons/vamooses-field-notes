-- VFN.DetailController
--
-- Behaviour layer for the main panel:
--   - registers row behaviours for groupRow / coordRow / sourceLineRow
--   - :Wire(rootFrame)    attaches handlers to spec-built buttons
--   - :Refresh(rootFrame) updates labels, lists, summary, scope/back/delete

VFN = VFN or {}
VFN.DetailController = VFN.DetailController or {}

local DetailController = VFN.DetailController
local CH = VFN.ControllerHelpers
local W, SetText = CH.UI.W, CH.UI.SetText
local GetUI = CH.Mechanics.GetUI
local SetUITransient, GetSelectedSet = CH.Mechanics.SetUITransient, CH.Mechanics.GetSelectedSet

-- Cycle definitions live in VFN.Constants.CYCLES so they can grow / be
-- localised in one place. We just reference them here.
local CYCLES = VFN.Constants.CYCLES

-- Row behaviours (templates live in LayoutConfig.rows.<name>) ---------------

-- Custom group-row factory: housing-map-deed icon + zone name + count badge
-- (mockup pass). Each row is a Button with three children: a left-anchored
-- atlas texture, a stretching FontString for the zone name, and a
-- right-anchored count chip.
local function groupRowFactory(template)
    local titleFont = template.font or "body"
    return {
        Configure = function(row, ed)
            ed = ed or {}
            if not row._vfnLaidOut and row.CreateTexture then
                -- ARTWORK sublayer 5: above row chrome's watercolor (sublayer 0)
                -- and gloss (sublayer 1) which are SetAllPoints and would
                -- otherwise obscure the 16x16 icon. Same-layer draw order is
                -- creation order; the chrome is created AFTER the icon (via
                -- PaintRowChrome below), so the icon needs an explicit higher
                -- sublayer to win.
                local icon = row:CreateTexture(nil, "ARTWORK", nil, 5)
                icon:SetSize(16, 16)
                icon:SetPoint("LEFT", 6, 0)
                if icon.SetAtlas then icon:SetAtlas("housing-map-deed") end
                row.vfnIcon = icon

                local title = row:CreateFontString(nil, "OVERLAY")
                title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
                title:SetPoint("RIGHT", -36, 0)
                title:SetJustifyH("LEFT")
                title:SetWordWrap(false)
                VFN.UI.applyFontRole(title, titleFont)
                VFN.Theme:Register(title, "Text")
                row.vfnTitle = title

                local badge = row:CreateFontString(nil, "OVERLAY")
                badge:SetPoint("RIGHT", -8, 0)
                badge:SetJustifyH("RIGHT")
                VFN.UI.applyFontRole(badge, "small")
                VFN.Theme:Register(badge, "TextDim")
                row.vfnBadge = badge

                VFN.Theme:Register(row, "Button")
                row._vfnLaidOut = true
            end

            local titleText = ed.groupName or "Unknown Map"
            if row.vfnTitle then row.vfnTitle:SetText(titleText) end
            if row.vfnBadge then row.vfnBadge:SetText(tostring(ed.count or 0)) end
            -- Card-style chrome (BG fill + 4 edges) so group rows read as
            -- distinct rows in the rail rather than flat text. Repainted per
            -- Configure call so selected state pops with accent border.
            CH.UI.PaintRowChrome(row, ed.selected)

            if row.SetHeight then row:SetHeight(template.height) end
            if row.SetScript then
                row:SetScript("OnClick", function()
                    SetUITransient("selectedGroupKey", ed.key)
                    SetUITransient("selectedEntryIndex", nil)
                end)
            end
        end,
        Reset = function(row)
            if row.SetScript then row:SetScript("OnClick", nil) end
            if row.vfnTitle then row.vfnTitle:SetText("") end
            if row.vfnBadge then row.vfnBadge:SetText("") end
        end,
    }
end

VFN.Rows:Register("groupRow", {
    font   = "body",
    height = 34,
    factory = groupRowFactory,
    key    = function(spec, _ctx) return tostring(spec and spec.key or spec) end,  -- per-group identifier
})

-- Custom coord-row factory: numbered badge on the left + yellow coords +
-- label (mockup pass). Badge is a small filled-square texture with the
-- row's index centred -- gives the eye a quick visual guide for how many
-- coords there are and which one's selected.
-- Custom coord-row factory. Layout (left-to-right):
--   [ amber/blue selection badge ]  [ coord text -- amber ]  [ label text -- dim ]
-- All colours come from Theme.Skinners; nothing is painted inline. Selectors
-- returns structured data (coords + label as separate strings) so this
-- factory composes a two-FontString row instead of a single colour-escaped
-- FontString.
local function coordRowFactory(template)
    local titleFont = template.font or "body"
    return {
        Configure = function(row, ed)
            ed = ed or {}
            if not row._vfnLaidOut and row.CreateTexture then
                local badgeBg = row:CreateTexture(nil, "ARTWORK")
                badgeBg:SetSize(20, 20)
                badgeBg:SetPoint("LEFT", 6, 0)

                local badgeText = row:CreateFontString(nil, "OVERLAY")
                badgeText:SetPoint("CENTER", badgeBg, "CENTER", 0, 0)
                badgeText:SetJustifyH("CENTER")
                VFN.UI.applyFontRole(badgeText, "small")

                row._vfnBadge = { frame = badgeBg, text = badgeText }

                -- Coords (amber, semantic.warning). Sits right of the badge.
                local coords = row:CreateFontString(nil, "OVERLAY")
                coords:SetPoint("LEFT", badgeBg, "RIGHT", 8, 0)
                coords:SetJustifyH("LEFT")
                VFN.UI.applyFontRole(coords, titleFont)
                local warn = VFN.Theme:GetColor("semantic.warning")
                coords:SetTextColor(warn.r, warn.g, warn.b, 1)
                row.vfnCoords = coords

                -- Label (dim) follows the coord text. Right-anchored to row
                -- so long labels truncate gracefully.
                local label = row:CreateFontString(nil, "OVERLAY")
                label:SetPoint("LEFT", coords, "RIGHT", 8, 0)
                label:SetPoint("RIGHT", -8, 0)
                label:SetJustifyH("LEFT")
                label:SetWordWrap(false)
                VFN.UI.applyFontRole(label, titleFont)
                VFN.Theme:Register(label, "TextDim")
                row.vfnLabel = label

                VFN.Theme:Register(row, "Button")
                row._vfnLaidOut = true
            end

            -- Selection-variant badge: bg flips accent <-> panel_header,
            -- text flips inverse <-> primary, all routed through BadgePill.
            VFN.Theme:Register(row, "BadgePill", {
                text = tostring(ed.index or "?"),
                variant = "selection",
                selected = ed.selected and true or false,
            })

            if row.vfnCoords then row.vfnCoords:SetText(ed.coords or "") end
            if row.vfnLabel  then row.vfnLabel:SetText(ed.label or "")  end
            if row.SetHeight then row:SetHeight(template.height) end
            if row.SetScript then
                row:SetScript("OnClick", function() SetUITransient("selectedEntryIndex", ed.index) end)
            end
        end,
        Reset = function(row)
            if row.SetScript then row:SetScript("OnClick", nil) end
            if row.vfnCoords then row.vfnCoords:SetText("") end
            if row.vfnLabel  then row.vfnLabel:SetText("")  end
        end,
    }
end

VFN.Rows:Register("coordRow", {
    font   = "body",
    height = 34,
    factory = coordRowFactory,
    key    = function(spec, _ctx) return tostring(spec and spec.index or "?") end,
})

VFN.Rows:Register("sourceLineRow", {
    font   = "small",
    height = 34,
    deriveText = function(ed) return ed.text or "" end,
    -- no onClick: source lines are static
    key    = function(spec, _ctx) return tostring(spec and spec.lineNumber or spec and spec.text or "?") end,
})

-- State helpers ---------------------------------------------------------------
--
-- (EnsureSelectedGroup / EnsureSelectedEntry retired in #11.1 -- the Store's
-- reducer enforces those invariants now via NormaliseSelection. By the time
-- Refresh runs, state.session.ui.selectedGroupKey + selectedEntryIndex are
-- guaranteed to be either nil or valid for the current selectedSetID.)

local function GetEntriesForScope(set)
    if not set then return {} end
    local scope = GetUI().sendScope
    local key = GetUI().selectedGroupKey
    if scope == "selected" then
        local _, entry = VFN.Selectors.FindEntryInGroup(set, key, GetUI().selectedEntryIndex)
        if VFN.Selectors.IsSendableEntry(entry) then return { entry } end
        return {}
    end
    return VFN.Selectors.EntriesForScope(set, scope, key)
end

-- Action status / format ---------------------------------------------------

local function SetActionStatus(rootFrame, text)
    SetText(W(rootFrame, "mainPanel.actionStatus"), text)
end

-- Send / remove status text is also appended to the drawer's apply log so
-- it persists as a rolling history. The transient mainPanel.actionStatus
-- still flashes the latest message; the log keeps the audit trail.
local function LogAndStatus(rootFrame, text)
    SetActionStatus(rootFrame, text)
    CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.APPLY_LOG_APPEND, { line = text })
end

local function FormatWaypointAction(action, result)
    if not (result and result.ok) then
        local err = result and result.errors and result.errors[1] or nil
        if err then return "Waypoint backend unavailable: " .. tostring(err) .. "." end
        return "Waypoint backend unavailable."
    end
    local provider = result.provider or "backend"
    local count = result.sent or 0
    local noun = count == 1 and "waypoint" or "waypoints"
    if action == "remove" then
        return string.format("Removed %d %s %s.", count, provider, noun)
    end
    return string.format("Sent %d %s %s.", count, provider, noun)
end

-- Delete confirmation popup ------------------------------------------------

local function ConfirmDeleteSet(_rootFrame, setID)
    if not setID then return end
    CH.UI.Confirm({
        id     = "VFN_DELETE_SET",
        text   = "Delete this field note set?",
        accept = "Delete",
        data   = setID,
        onAccept = function(_, data) CH.Mechanics.DeleteSet(data) end,
    })
end

-- Public API ----------------------------------------------------------------

function DetailController:Wire(rootFrame)
    CH.UI.OnClick(rootFrame, "mainPanel.backButton", function() CH.Mechanics.CloseSet() end)

    CH.UI.OnClick(rootFrame, "mainPanel.deleteButton", function()
        local id = GetSelectedSet()
        ConfirmDeleteSet(rootFrame, id)
    end)

    -- (Backend cycle wiring moved to Controller_Config.)

    CH.UI.OnClick(rootFrame, "mainPanel.mapPreviewButton", function()
        CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.UI_TOGGLE_MAP)
    end)

    CH.UI.OnClick(rootFrame, "mainPanel.sourceToggleButton", function()
        SetUITransient("showSourceText", not GetUI().showSourceText)
    end)

    CH.UI.OnClick(rootFrame, "mainPanel.scopeButton", function()
        CH.Mechanics.CycleUIValue("sendScope", CYCLES.sendScope.order)
    end)

    CH.UI.OnClick(rootFrame, "mainPanel.sendButton", function()
        local _, set = GetSelectedSet()
        if not set then return end
        if VFN.WaypointBackend and VFN.WaypointBackend.Send then
            local result = VFN.WaypointBackend:Send(GetEntriesForScope(set), set)
            LogAndStatus(rootFrame, FormatWaypointAction("send", result))
        else
            LogAndStatus(rootFrame, "Waypoint backend unavailable.")
        end
    end)

    CH.UI.OnClick(rootFrame, "mainPanel.removeSentButton", function()
        local _, set = GetSelectedSet()
        if not set then return end
        if VFN.WaypointBackend and VFN.WaypointBackend.Remove then
            local result = VFN.WaypointBackend:Remove(GetEntriesForScope(set), set)
            LogAndStatus(rootFrame, FormatWaypointAction("remove", result))
        else
            LogAndStatus(rootFrame, "Waypoint backend unavailable.")
        end
    end)
end

-- Refresh is empty now: coordinateList / sourceLineList visibility is
-- declarative on the widget specs (`visible = "detail.coordListVisible"`
-- / "detail.sourceListVisible"), resolved by Layout:Compute per spec
-- section 6. No imperative Show/Hide here. Keeping the function so the
-- Controllers:RefreshAll iteration doesn't need to check for nil.
function DetailController:Refresh(_rootFrame, _ctx)
end

VFN.Controllers:Register("detail", DetailController)

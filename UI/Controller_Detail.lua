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
local DispatchUI, GetSelectedSet = CH.Mechanics.DispatchUI, CH.Mechanics.GetSelectedSet

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
                local icon = row:CreateTexture(nil, "ARTWORK")
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
                    DispatchUI("selectedGroupKey", ed.key)
                    DispatchUI("selectedEntryIndex", nil)
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
                row:SetScript("OnClick", function() DispatchUI("selectedEntryIndex", ed.index) end)
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
})

VFN.Rows:Register("sourceLineRow", {
    font   = "small",
    height = 34,
    deriveText = function(ed) return ed.text or "" end,
    -- no onClick: source lines are static
})

-- State helpers (selected group / entry / scope) ---------------------------

local function EnsureSelectedGroup(groups)
    local ui = GetUI()
    local found = VFN.Selectors.FindGroupByKey(groups, ui.selectedGroupKey)
    if found then return found end
    DispatchUI("selectedGroupKey", VFN.Selectors.FirstGroupKey(groups))
    return groups and groups[1] or nil
end

local function EnsureSelectedEntry(set, key)
    local ui = GetUI()
    local index, entry = VFN.Selectors.FindEntryInGroup(set, key, ui.selectedEntryIndex)
    if index ~= ui.selectedEntryIndex then
        DispatchUI("selectedEntryIndex", index)
    end
    return index, entry
end

local function GetEntriesForScope(set)
    if not set then return {} end
    local scope = GetUI().sendScope
    local key = GetUI().selectedGroupKey
    if scope == "selected" then
        local _, entry = EnsureSelectedEntry(set, key)
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
    if VFN.Store and VFN.Store.Dispatch then
        CH.Mechanics.Dispatch("VFN_APPLY_LOG_APPEND", { line = text })
    end
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
        CH.Mechanics.Dispatch("VFN_UI_TOGGLE_MAP")
    end)

    CH.UI.OnClick(rootFrame, "mainPanel.sourceToggleButton", function()
        DispatchUI("showSourceText", not GetUI().showSourceText)
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

local function setVis(widget, shown)
    if not widget then return end
    if shown then if widget.Show then widget:Show() end
    else if widget.Hide then widget:Hide() end end
end

function DetailController:Refresh(rootFrame, ctx)
    ctx = ctx or {}
    local hasSelection = ctx.hasSelection == true
    local _, set = GetSelectedSet()
    local ui = GetUI()

    -- (Backend label refresh moved to Controller_Config along with the cycle
    -- button itself.)

    local map = ui.map
    local mapShown = not map or map.shown ~= false
    -- Map Preview button: text stays constant, variant flips to "primary"
    -- (accent fill) when the preview is showing so the toggle state reads
    -- visually without a text change.
    local mapBtn = W(rootFrame, "mainPanel.mapPreviewButton")
    if mapBtn and VFN.Theme and VFN.Theme.RegisterVariant then
        VFN.Theme:RegisterVariant(mapBtn, "Button", mapShown and "primary" or "tertiary")
    end
    CH.UI.SetButtonText(W(rootFrame, "mainPanel.sourceToggleButton"),
        ui.showSourceText and "Coordinates" or "Source Text")

    local scope = ui.sendScope or CYCLES.sendScope.default
    CH.UI.SetButtonText(W(rootFrame, "mainPanel.scopeButton"), CYCLES.sendScope.labels[scope])

    if not hasSelection then return end

    local groups = VFN.Selectors.BuildMapGroups(set)
    EnsureSelectedGroup(groups)
    local key = GetUI().selectedGroupKey
    local selectedIdx, selectedEntry = EnsureSelectedEntry(set, key)
    local coordItems = VFN.Selectors.BuildCoordinateItems(set, key)
    local sourceItems = VFN.Selectors.BuildSourceLineItems(set)

    for _, g in ipairs(groups) do
        g.selected = (g.key == key)
    end
    for _, item in ipairs(coordItems) do
        item.selected = (item.index == selectedIdx)
    end

    SetText(W(rootFrame, "mainPanel.coordSummary"), VFN.Selectors.FormatEntrySummary(selectedEntry))

    -- Detail-header subtitle: selected entry's location + coord ("Founder's
    -- Point - Coordinate - 50.0, 33.3"). Mirrors the drawer's current card
    -- but lives in the header so the user always sees context next to the
    -- title.
    local card = VFN.Selectors.BuildCurrentCardModel(selectedEntry)
    local subtitle = ""
    if card.hasSelection then
        subtitle = string.format("%s - Coordinate - %s", card.map or "", card.coords or "")
    end
    SetText(W(rootFrame, "mainPanel.subtitle"), subtitle)

    local groupList  = W(rootFrame, "mainPanel.mapGroupList")
    local coordList  = W(rootFrame, "mainPanel.coordinateList")
    local sourceList = W(rootFrame, "mainPanel.sourceLineList")
    if groupList  and groupList.SetItems  then groupList:SetItems(groups, true) end
    if coordList  and coordList.SetItems  then coordList:SetItems(coordItems, true) end
    if sourceList and sourceList.SetItems then sourceList:SetItems(sourceItems, true) end

    setVis(coordList,  not ui.showSourceText)
    setVis(sourceList, ui.showSourceText)
end

VFN.Controllers:Register("detail", DetailController)

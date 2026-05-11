-- VFN.LibraryController
--
-- Behaviour layer for the library panel (3-column "find + curate" workspace):
--   - left:   library index               (click = switch active library)
--   - center: finder for the active lib   (search/filter/sort + cards + actions)
--   - right:  curator for the selected set (stats, title/note edit, coord preview)
--
-- Header buttons:
--   "+ New"   -- create a new library
--   "Rename"  -- rename the active library (Default protected)
--   "Delete"  -- delete the active library (Default protected)
--
-- Card-row right-click opens "Move to..." (CH.UI.ShowMenu).
--
-- Selection + find state lives in state.session.viewLocal.library (transient).
-- Read via CH.Mechanics.GetViewLocal("library"); write via CH.DispatchViewLocal.

VFN = VFN or {}
VFN.LibraryController = VFN.LibraryController or {}

local LibraryController = VFN.LibraryController
local CH = VFN.ControllerHelpers
local W, SetText = CH.UI.W, CH.UI.SetText

-- ===== Library-row context menu (right-click on a library) =================
-- Rename / Delete -- both gated for the protected Default library. Mirrors
-- the card-row "Move to..." menu pattern so library-level actions live where
-- the user reaches for them (right-click on the thing being acted on).
local function ShowLibraryMenu(libraryID, ownerFrame)
    local state = CH.Mechanics.GetState()
    if not (state and libraryID) then return end
    local lib = state.account.libraries[libraryID]
    if not lib then return end
    local protected = lib.isDefault == true

    local items = { { text = lib.name or "Library", isTitle = true } }
    items[#items + 1] = {
        text = "Rename",
        disabled = protected,
        callback = function()
            CH.UI.Confirm({
                id       = VFN.Constants.ACTIONS.LIBRARY_RENAME,
                text     = "Rename library %q:",
                textArg1 = lib.name or "library",
                accept   = "Rename",
                input    = true,
                data     = libraryID,
                onAccept = function(name, data)
                    CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.LIBRARY_RENAME, { libraryID = data, name = name })
                end,
            })
        end,
    }
    items[#items + 1] = {
        text = "Delete",
        disabled = protected,
        callback = function()
            CH.UI.Confirm({
                id       = VFN.Constants.ACTIONS.LIBRARY_DELETE,
                text     = "Delete library %q?\n\nField notes inside will move to the Default library.",
                textArg1 = lib.name or "library",
                accept   = "Delete",
                data     = libraryID,
                onAccept = function(_, data)
                    CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.LIBRARY_DELETE, { libraryID = data })
                end,
            })
        end,
    }
    CH.UI.ShowMenu(ownerFrame, items)
end

-- ===== Move-to menu (right-click on a card) =================================

local function ShowMoveMenu(setID, ownerFrame)
    local state = CH.Mechanics.GetState()
    if not (state and state.account and state.account.libraries and setID) then return end
    local set = state.account.sets[setID]
    if not set then return end
    local fromID = set.libraryID or state.account.defaultLibraryID

    local libs = state.account.libraries
    local destinations = {}
    for libID, lib in pairs(libs) do
        if libID ~= fromID and not lib.deletedAt then
            destinations[#destinations + 1] = {
                id = libID, name = lib.name or "?", isDefault = lib.isDefault == true,
            }
        end
    end
    table.sort(destinations, function(a, b)
        if a.isDefault ~= b.isDefault then return a.isDefault end
        return a.name:lower() < b.name:lower()
    end)

    local items = { { text = "Move to...", isTitle = true } }
    if #destinations == 0 then
        items[#items + 1] = { text = "(no other libraries)", disabled = true }
    end
    for _, lib in ipairs(destinations) do
        local libID = lib.id
        items[#items + 1] = {
            text = lib.name .. (lib.isDefault and "  (Default)" or ""),
            callback = function()
                CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.SET_MOVE_LIBRARY, { setID = setID, toLibraryID = libID })
            end,
        }
    end
    CH.UI.ShowMenu(ownerFrame, items)
end

-- ===== Discard-edits guard ===================================================

-- Edit-box dirty state lives in viewLocal.library, NOT on the controller --
-- pure-data so the title/note binding selectors can read it without
-- inspecting widgets. Helpers wrap the dispatch + read calls so the
-- routing change is local if we ever rename the state path.
local function editsDirty()
    local libUI = CH.Mechanics.GetViewLocal("library")
    return libUI.editsDirty == true
end

local function clearEditsDirty()
    CH.Mechanics.DispatchViewLocal("library", "editsDirty", false)
    CH.Mechanics.DispatchViewLocal("library", "editingTitle", nil)
    CH.Mechanics.DispatchViewLocal("library", "editingNote", nil)
end

-- Wrap a selection-changing dispatch so we prompt before clobbering unsaved
-- typing in the right-column edit boxes. wouldDiscard is the caller's check
-- for whether the action would actually move selection (no point prompting
-- when clicking the already-selected row). On accept we clear the dirty
-- flag here so the title/note bindings re-resolve to the persisted values.
local function withDirtyGuard(wouldDiscard, doAction)
    if not (wouldDiscard and editsDirty()) then
        doAction()
        return
    end
    CH.UI.Confirm({
        id       = "VFN_LIBRARY_DISCARD_EDITS",
        text     = "Discard unsaved edits to the current card?",
        accept   = "Discard",
        onAccept = function()
            clearEditsDirty()
            doAction()
        end,
    })
end

-- ===== Row factories ========================================================

-- Index column row: library name + count badge. Card-style chrome matches
-- streamRow / groupRow so all selection rows in the addon read consistently.
-- Right-click opens the library context menu (Rename / Delete).
local function libraryIndexRowFactory(template)
    return {
        Configure = function(row, ed)
            ed = ed or {}
            CH.UI.ensureRowText(row, template.font)
            local label = ed.name or "?"
            if ed.isDefault then label = label .. "  (Default)" end
            label = label .. "    " .. tostring(ed.count or 0)
            if row.vfnText then row.vfnText:SetText(label) end
            if row.SetHeight then row:SetHeight(template.height) end
            CH.UI.PaintRowChrome(row, ed.selected)
            if row.RegisterForClicks then
                row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            end
            if row.SetScript then
                row:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        ShowLibraryMenu(ed.libraryID, self)
                        return
                    end
                    local cur = CH.Mechanics.GetViewLocal("library")
                    local wouldDiscard = (cur.selectedLibraryID ~= ed.libraryID)
                                         or cur.selectedSetID ~= nil
                    withDirtyGuard(wouldDiscard, function()
                        CH.Mechanics.DispatchViewLocal("library", "selectedLibraryID", ed.libraryID)
                        CH.Mechanics.DispatchViewLocal("library", "selectedSetID", nil)
                    end)
                end)
            end
        end,
        Reset = CH.UI.clearRow,
    }
end

-- Card row: title + meta + note (3 stacked FontStrings) + chip strip below.
-- Chip strip is a small list of mini VFN.UI:Chip widgets reused across rows
-- (recycled via row._vfnChipPool). Each chip carries semantic colour by
-- variant -- see Theme.Skinners.StatusChip.
local function buildLibraryCardMeta(ed)
    local parts = {}
    local n = tonumber(ed.coordCount) or 0
    parts[#parts + 1] = string.format("%d %s", n, n == 1 and "coord" or "coords")
    local m = tonumber(ed.mapCount) or 0
    if m > 0 then parts[#parts + 1] = string.format("%d %s", m, m == 1 and "map" or "maps") end
    if ed.character and ed.character ~= "" then parts[#parts + 1] = ed.character end
    return table.concat(parts, " - ")
end

local _libraryCardRowBase = CH.UI.MakeStackedRowFactory({
    lines = {
        { fontRole = "body",    deriveText = function(ed) return ed.title or "Untitled" end, themeRole = "Text" },
        { fontRole = "caption", deriveText = buildLibraryCardMeta,                            themeRole = "TextDim" },
        { fontRole = "small",   deriveText = function(ed) return ed.noteText or "" end,       themeRole = "TextDim", hideIfEmpty = true },
    },
    onClick = function(ed)
        return function()
            local cur = CH.Mechanics.GetViewLocal("library")
            local wouldDiscard = (cur.selectedSetID ~= ed.setID)
            withDirtyGuard(wouldDiscard, function()
                CH.Mechanics.DispatchViewLocal("library", "selectedSetID", ed.setID)
            end)
        end
    end,
    rightClick = function(ed)
        return function(self) ShowMoveMenu(ed.setID, self) end
    end,
})

local function ensureChipStrip(row)
    if row._vfnChipPool then return row._vfnChipPool end
    row._vfnChipPool = {}
    return row._vfnChipPool
end

-- Render the row's status chips left-aligned along the bottom edge of the
-- row. Pooled per-row so swap-Configure (same row, new data) just shows/hides
-- existing chips instead of recreating.
local function renderRowChips(row, chips)
    chips = chips or {}
    local pool = ensureChipStrip(row)
    local prev = nil
    for i, variant in ipairs(chips) do
        local chip = pool[i]
        local labelByVariant = {
            ready    = "ready",
            blocked  = "blocked",
            has_note = "note",
            source   = "source",
            default  = "default",
        }
        local labelText = labelByVariant[variant] or variant
        if not chip then
            chip = VFN.UI:Chip(row, labelText, variant)
            pool[i] = chip
        end
        if chip then
            chip:SetChipText(labelText)
            chip:SetVariant(variant)
            if chip.ClearAllPoints then chip:ClearAllPoints() end
            if chip.SetPoint then
                if not prev then
                    chip:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 4)
                else
                    chip:SetPoint("LEFT", prev, "RIGHT", 4, 0)
                end
            end
            if chip.SetWidth then
                -- Width = text width + horizontal padding. Min 32.
                local textWidth = (chip._vfnChipText and chip._vfnChipText.GetStringWidth)
                    and chip._vfnChipText:GetStringWidth() or 0
                chip:SetWidth(math.max(32, math.floor(textWidth + 16)))
            end
            chip:Show()
            prev = chip
        end
    end
    -- Hide any leftover chips from a prior render.
    for j = #chips + 1, #pool do
        if pool[j] and pool[j].Hide then pool[j]:Hide() end
    end
end

local function libraryCardRowFactory(template)
    local base = _libraryCardRowBase(template)
    return {
        Configure = function(row, ed)
            base.Configure(row, ed)
            renderRowChips(row, ed and ed.statusChips)
            CH.UI.PaintRowChrome(row, ed and ed.selected)
        end,
        Reset = function(row)
            base.Reset(row)
            if row._vfnChipPool then
                for _, chip in ipairs(row._vfnChipPool) do
                    if chip and chip.Hide then chip:Hide() end
                end
            end
        end,
    }
end

-- Coord-preview row (right column): coords amber + label dim. Reads the
-- exact shape Selectors.BuildCoordinateItems produces (same as the Detail
-- view's coordRow), so entry data lives on ed.entry. Click sends a single
-- waypoint via the backend.
local function libraryCoordPreviewRowFactory(template)
    local titleFont = template.font or "body"
    return {
        Configure = function(row, ed)
            ed = ed or {}
            if not row._vfnLaidOut and row.CreateFontString then
                local coords = row:CreateFontString(nil, "OVERLAY")
                coords:SetPoint("LEFT", 10, 0)
                coords:SetJustifyH("LEFT")
                VFN.UI.applyFontRole(coords, titleFont)
                local warn = VFN.Theme:GetColor("semantic.warning")
                coords:SetTextColor(warn.r, warn.g, warn.b, 1)
                row.vfnCoords = coords

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
            if row.vfnCoords then row.vfnCoords:SetText(ed.coords or "") end
            if row.vfnLabel  then row.vfnLabel:SetText(ed.label or "")  end
            if row.SetHeight then row:SetHeight(template.height) end
            if row.SetScript then
                row:SetScript("OnClick", function()
                    local entry = ed.entry
                    if not (entry and entry.coordMapID) then return end
                    if not (VFN.WaypointBackend and VFN.WaypointBackend.Send) then return end
                    VFN.WaypointBackend:Send({ entry }, nil)
                end)
            end
        end,
        Reset = function(row)
            if row.SetScript then row:SetScript("OnClick", nil) end
            if row.vfnCoords then row.vfnCoords:SetText("") end
            if row.vfnLabel  then row.vfnLabel:SetText("")  end
        end,
    }
end

VFN.Rows:Register("libraryIndexRow", {
    font   = "body",
    height = 28,
    factory = libraryIndexRowFactory,
})
VFN.Rows:Register("libraryCardRow", {
    font   = "body",
    height = 78,
    factory = libraryCardRowFactory,
})
VFN.Rows:Register("libraryCoordPreviewRow", {
    font   = "body",
    height = 22,
    factory = libraryCoordPreviewRowFactory,
})

-- ===== Editable triple (title + note) =======================================
--
-- Title + note live on `set` at canonical paths (set.title, set.payload.note).
-- The Curator's title/note widgets are bound to library.titleEditValue /
-- library.noteEditValue selectors, which return the staged viewLocal value
-- while editsDirty is true and the persisted set value otherwise.

local function SetActionStatus(rootFrame, text)
    SetText(W(rootFrame, "libraryPanel.coordsActionStatus"), text or "")
end

local function SaveEdits(rootFrame)
    local libUI = CH.Mechanics.GetViewLocal("library")
    local setID = libUI.selectedSetID
    if not setID then
        SetActionStatus(rootFrame, "Select a card first.")
        return
    end
    local state = CH.Mechanics.GetState()
    local set = state and state.account.sets and state.account.sets[setID]
    -- Pull title/note from the viewLocal staging slots (not from the widget)
    -- so the source of truth is consistent with what the title/note bindings
    -- already read.
    local titleText = libUI.editingTitle
    local noteText  = libUI.editingNote
    if titleText == nil then titleText = (set and set.title) or "" end
    if noteText  == nil then noteText  = (set and set.payload and set.payload.note) or "" end
    -- Preserve sourceText (no longer editable here -- reducer's complete-triple
    -- contract clobbers it to "" when absent from the payload). Omit
    -- sourceLines/entries so the reducer keeps the existing parsed entries.
    CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.SET_UPDATE, {
        setID  = setID,
        fields = {
            title      = titleText,
            note       = noteText,
            sourceText = (set and type(set.sourceText) == "string") and set.sourceText or "",
        },
    })
    clearEditsDirty()
    SetActionStatus(rootFrame, "Saved.")
end

local function RestoreEdits(rootFrame)
    clearEditsDirty()
    SetActionStatus(rootFrame, "Reverted to saved values.")
end

-- ===== Find-state helpers ===================================================

local SORT_CYCLE  = { recent = "alpha",  alpha  = "size", size = "recent" }
local FILTERS     = { "all", "ready", "has_note", "blocked" }

local function GetFindState()
    local lib = CH.Mechanics.GetViewLocal("library") or {}
    return {
        query  = lib.searchQuery  or "",
        filter = lib.activeFilter or "all",
        sort   = lib.sortOrder    or "recent",
    }
end

-- ===== Public API ===========================================================

function LibraryController:Wire(rootFrame)
    CH.UI.OnClick(rootFrame, "libraryPanel.coordsSaveButton",    function() SaveEdits(rootFrame) end)
    CH.UI.OnClick(rootFrame, "libraryPanel.coordsRestoreButton", function() RestoreEdits(rootFrame) end)

    -- Editbox OnTextChanged: stage the current text into viewLocal's editing
    -- slots and flip the dirty flag. The title/note bindings see editsDirty
    -- and return the staged value, leaving in-progress typing intact. Save
    -- commits the staged value via SET_UPDATE; Restore just clears the flag.
    local function makeStager(field)
        return function(box, userInput)
            if not userInput then return end
            CH.Mechanics.DispatchViewLocal("library", field, box:GetText() or "")
            CH.Mechanics.DispatchViewLocal("library", "editsDirty", true)
            SetActionStatus(rootFrame, "Unsaved edits -- click Save or Restore.")
        end
    end
    local titleBox = W(rootFrame, "libraryPanel.titleBox")
    if titleBox and titleBox.SetScript then
        titleBox:SetScript("OnTextChanged", makeStager("editingTitle"))
    end
    local noteBox = W(rootFrame, "libraryPanel.noteBox")
    if noteBox and noteBox.SetScript then
        noteBox:SetScript("OnTextChanged", makeStager("editingNote"))
    end

    -- Search box: every keystroke writes searchQuery, which triggers a Refresh
    -- via Store notify -> cards list rebuilds with new filter.
    local searchBox = W(rootFrame, "libraryPanel.searchBox")
    if searchBox and searchBox.SetScript then
        searchBox:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                CH.Mechanics.DispatchViewLocal("library", "searchQuery", self:GetText() or "")
            end
        end)
    end

    -- Sort cycle button.
    CH.UI.OnClick(rootFrame, "libraryPanel.sortButton", function()
        local cur = GetFindState()
        CH.Mechanics.DispatchViewLocal("library", "sortOrder", SORT_CYCLE[cur.sort] or "recent")
    end)

    -- Filter chips -- each writes activeFilter, Refresh repaints variants.
    for _, filter in ipairs(FILTERS) do
        local widgetId = "libraryPanel.filter" ..
            (filter == "has_note" and "HasNote" or (filter:sub(1, 1):upper() .. filter:sub(2)))
        CH.UI.OnClick(rootFrame, widgetId, function()
            CH.Mechanics.DispatchViewLocal("library", "activeFilter", filter)
        end)
    end

    -- Cards-action row: Send Waypoints / Move to / Delete (operate on selected card).
    CH.UI.OnClick(rootFrame, "libraryPanel.sendWaypointsButton", function()
        local libUI = CH.Mechanics.GetViewLocal("library")
        local state = CH.Mechanics.GetState()
        local set = libUI.selectedSetID and state and state.account.sets[libUI.selectedSetID]
        if not (set and set.entries and #set.entries > 0) then return end
        if not (VFN.WaypointBackend and VFN.WaypointBackend.Send) then
            SetActionStatus(rootFrame, "Waypoint backend unavailable.")
            return
        end
        local result = VFN.WaypointBackend:Send(set.entries, set)
        if result and result.ok then
            local count = result.sent or #set.entries
            SetActionStatus(rootFrame, string.format(
                "Sent %d %s.", count, count == 1 and "waypoint" or "waypoints"))
        else
            local err = result and result.errors and result.errors[1] or nil
            SetActionStatus(rootFrame, "Send failed" .. (err and (": " .. tostring(err)) or "") .. ".")
        end
    end)

    CH.UI.OnClick(rootFrame, "libraryPanel.moveToButton", function(btn)
        local libUI = CH.Mechanics.GetViewLocal("library")
        if libUI.selectedSetID then ShowMoveMenu(libUI.selectedSetID, btn) end
    end)

    CH.UI.OnClick(rootFrame, "libraryPanel.deleteCardButton", function()
        local libUI = CH.Mechanics.GetViewLocal("library")
        local setID = libUI.selectedSetID
        if not setID then return end
        CH.UI.Confirm({
            id       = "VFN_LIBRARY_DELETE_CARD",
            text     = "Delete this field note?",
            accept   = "Delete",
            data     = setID,
            onAccept = function(_, data)
                if VFN.Store and VFN.Store.DeleteSet then
                    VFN.Store:DeleteSet(data)
                    -- Clear selected-set so curator panel resets cleanly.
                    CH.Mechanics.DispatchViewLocal("library", "selectedSetID", nil)
                end
            end,
        })
    end)

    -- "Copy coords": pops a multi-line copy frame pre-filled with one
    -- /way line per entry. StaticPopup's editbox is single-line so we
    -- build a proper frame the first time it's needed and reuse it after.
    CH.UI.OnClick(rootFrame, "libraryPanel.previewCopyButton", function()
        local libUI = CH.Mechanics.GetViewLocal("library")
        local state = CH.Mechanics.GetState()
        local set = libUI.selectedSetID and state and state.account.sets[libUI.selectedSetID]
        local entries = (set and set.entries) or {}
        if #entries == 0 then
            SetActionStatus(rootFrame, "Nothing to copy.")
            return
        end
        local lines = {}
        for _, e in ipairs(entries) do
            local label = (e.label and e.label ~= "" and (" " .. e.label)) or ""
            lines[#lines + 1] = string.format("/way %d %.1f %.1f%s",
                e.coordMapID, e.rawX, e.rawY, label)
        end
        local text = table.concat(lines, "\n")
        local dialog = VFN.UI:CopyDialog()
        if dialog and dialog.Open then dialog:Open("Copy coordinates", text) end
        SetActionStatus(rootFrame, string.format(
            "Copy: %d %s. Ctrl+C in the dialog.", #lines,
            #lines == 1 and "line" or "lines"))
    end)

    -- Create-library prompt: text input via CH.UI.Confirm.
    -- (Rename + Delete moved to right-click on a library row -- see
    -- ShowLibraryMenu.)
    CH.UI.OnClick(rootFrame, "libraryPanel.newLibraryButton", function()
        CH.UI.Confirm({
            id      = VFN.Constants.ACTIONS.LIBRARY_CREATE,
            text    = "Name the new library:",
            accept  = "Create",
            input   = true,
            onAccept = function(name)
                CH.Mechanics.Dispatch(VFN.Constants.ACTIONS.LIBRARY_CREATE, { name = name })
            end,
        })
    end)
end

-- ===== Refresh ==============================================================

-- Paint filter-chip selection: the active filter gets variant "primary",
-- inactive get "tertiary". Sort label syncs with viewLocal.sortOrder.
local function PaintFilterChips(rootFrame, activeFilter)
    for _, filter in ipairs(FILTERS) do
        local widgetId = "libraryPanel.filter" ..
            (filter == "has_note" and "HasNote" or (filter:sub(1, 1):upper() .. filter:sub(2)))
        local btn = W(rootFrame, widgetId)
        if btn and btn.SetVariant then
            btn:SetVariant(filter == activeFilter and "primary" or "tertiary")
        end
    end
end

-- Refresh is now imperative-only -- all widget value pushes (scrollbox
-- items, label text, stat cards, button enabled, edit-box text) flow
-- through the BindingEngine via the widget specs' `binding` field. What
-- remains here is the two pieces of imperative state that can't (yet) be
-- expressed as a pure-data binding:
--
--   1. selectedLibraryID fallback -- if the user's pick is stale, write the
--      defaultLibraryID into viewLocal. Bindings are read-only so they
--      can't make this self-healing write.
--   2. Filter-chip variant paint -- the filter widgets are kind="button",
--      and Button factory doesn't expose SetVariant. The binding fires but
--      the button's dispatcher silently ignores the variant field. Until
--      these widgets get migrated to kind="chip" (or Button grows a
--      variant method), PaintFilterChips stays imperative.
function LibraryController:Refresh(rootFrame, ctx)
    local state = (ctx and ctx.state) or CH.Mechanics.GetState()
    if not state then return end

    local libUI = CH.Mechanics.GetViewLocal("library")
    local libs = state.account.libraries or {}
    if not (libUI.selectedLibraryID and libs[libUI.selectedLibraryID]) then
        CH.Mechanics.DispatchViewLocal("library", "selectedLibraryID", state.account.defaultLibraryID)
    end

    -- Filter-chip variants. Once the filter widgets become kind="chip", this
    -- whole block deletes -- the bindings on each chip already exist.
    PaintFilterChips(rootFrame, GetFindState().filter)
end

VFN.Controllers:Register("library", LibraryController)

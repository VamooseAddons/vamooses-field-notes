-- VFN.StreamController
--
-- Behaviour layer for the stream panel:
--   - registers row behaviour for "streamRow"
--   - :Wire(rootFrame)    attaches handlers to spec-built widgets
--   - :Refresh(rootFrame) pushes derived items into the stream list

VFN = VFN or {}
VFN.StreamController = VFN.StreamController or {}

local StreamController = VFN.StreamController
local CH = VFN.ControllerHelpers
local W, SetText = CH.UI.W, CH.UI.SetText

-- File-local upvalues for hot WoW globals (spec section 13.3 -- ~2x faster
-- than per-call lookup). UnitName / GetRealmName are loaded by the time
-- this file runs (mock-test ordering matches production WoW boot order).
-- C_Map stays as an inline _G.C_Map lookup because some test fixtures
-- mock C_Map AFTER Controller_Stream loads; capturing it as a file-local
-- here would freeze a stale nil reference.
local UnitName     = _G.UnitName
local GetRealmName = _G.GetRealmName

-- Player-state helpers (WoW API access; not pure but localised here) -------

local function GetCurrentCharacterKey()
    if not (UnitName and GetRealmName) then return nil end
    local name, realm = UnitName("player"), GetRealmName()
    if name and name ~= "" and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return nil
end

local function Trim(s) return tostring(s or ""):match("^%s*(.-)%s*$") end

local function GetWidgetText(widget)
    return widget and widget.GetText and widget:GetText() or ""
end

-- Row behaviour (template lives in LayoutConfig.rows.streamRow) -------------
--
-- Custom factory: each stream row shows three lines -- title, meta, note --
-- so it can't use the simple single-line MakeRowFactory.
--
--   +--- 4px pad ---+
--   |  Test note 1                    <- title (subheading)
--   |  10 coords - 3 maps - Vamoose   <- meta (caption, dim)
--   |  cave entrance under roots      <- note (small, dim) [hidden if empty]
--   +---------------+
--
-- Selection state is conveyed via CH.UI.PaintRowChrome (accent border + tinted
-- fill) -- title text is unchanged.

local function buildMetaLine(ed)
    local parts = {}
    local n = tonumber(ed.coordCount) or 0
    parts[#parts + 1] = string.format("%d %s", n, n == 1 and "coord" or "coords")
    local m = tonumber(ed.mapCount) or 0
    if m > 0 then
        parts[#parts + 1] = string.format("%d %s", m, m == 1 and "map" or "maps")
    end
    if ed.character and ed.character ~= "" then
        parts[#parts + 1] = ed.character
    end
    if ed.isManual then parts[#parts + 1] = "manual" end
    return table.concat(parts, " - ")
end

-- Card chrome paint moved to CH.UI.PaintRowChrome (shared with groupRow etc).

-- Stream row layout (title + meta + note) is built via the shared
-- MakeStackedRowFactory helper; what's unique here is the per-row card
-- chrome paint (bg texture + 4 edge strips, selected/normal variants).
-- We wrap the base factory's Configure with a post-step that paints chrome.
local _streamRowBase = CH.UI.MakeStackedRowFactory({
    lines = {
        { fontRole = "subheading", themeRole = "Text",
          deriveText = function(ed) return ed.title or "Untitled Field Note" end },
        { fontRole = "caption", themeRole = "TextDim",
          deriveText = function(ed) return buildMetaLine(ed) end },
        { fontRole = "small", themeRole = "TextDim", hideIfEmpty = true,
          deriveText = function(ed) return ed.noteText or "" end },
    },
    onClick = function(ed)
        return function()
            local s = CH.Mechanics.GetState()
            if not s then return end
            local selectedSetID = s.account and s.account.ui and s.account.ui.selectedSetID
            if selectedSetID == ed.setID then
                CH.Mechanics.CloseSet()
            else
                -- Clear any active library/config view so the mode picker
                -- falls through to "detail" once the set is selected.
                CH.Mechanics.SetUIPersistent("view", nil)
                CH.Mechanics.OpenSet(ed.setID)
            end
        end
    end,
})

local function streamRowFactory(template)
    local base = _streamRowBase(template)
    return {
        Configure = function(row, ed)
            base.Configure(row, ed)
            CH.UI.PaintRowChrome(row, ed and ed.selected)
            -- Amber count pill top-right. Additive to the inline meta count
            -- so a glance picks up coord count without parsing the meta string.
            -- Guard against 0 -- tostring(0) is truthy, so an empty set would
            -- render a "0" pill which is meaningless.
            local count = ed and tonumber(ed.coordCount) or 0
            CH.UI.PaintRowBadge(row, count > 0 and count or nil)
        end,
        Reset = base.Reset,
    }
end

VFN.Rows:Register("streamRow", {
    font   = "body",
    height = 60,
    factory = streamRowFactory,
    key    = function(ed) return tostring(ed and ed.setID or "?") end,
})

-- Status text helpers --------------------------------------------------------
--
-- captureForm.status is the SINGLE status field for the whole capture form.
-- It replaces the old "Unsaved draft" header + "Save to add to stream" hint
-- + the per-input "Draft - paste coordinates below..." footer text. One
-- field, one message, one place to look. Messages cover:
--   - empty source                 -> initial paste prompt
--   - source has text, valid      -> draft ready, X coords parsed
--   - source has text, invalid     -> no valid coords found
--   - after save                   -> saved confirmation
--   - after Use Current Location  -> captured + reminder to save
--   - errors / backend unavailable -> error message

local function SetDraftStatus(rootFrame, text)
    SetText(W(rootFrame, "captureForm.status"), text)
end

-- Save / current location ---------------------------------------------------

-- Auto-generate a title from the first resolved entry. Format:
--   "<map name> <X.X, Y.Y>"   e.g. "Eversong Woods 66.4, 52.5"
-- The capture mode hides the title field entirely; this kicks in there.
-- Anywhere else, the title field defaults to empty too, so a user who
-- doesn't bother filling it in still gets a meaningful label.
local function AutoTitle(entries)
    local first = entries and entries[1]
    if not first then return "Untitled Field Note" end
    local mapName = VFN.Selectors.GetEntryGroupName(first) or "Unknown Map"
    local rawX = first.rawX or ((first.x or 0) * 100)
    local rawY = first.rawY or ((first.y or 0) * 100)
    return string.format("%s %.1f, %.1f", mapName, rawX, rawY)
end

local function BuildSetPayload(rootFrame, resolved)
    local title = Trim(GetWidgetText(W(rootFrame, "captureForm.titleBox")))
    local sourceText = GetWidgetText(W(rootFrame, "captureForm.sourceBox"))
    local noteText = GetWidgetText(W(rootFrame, "captureForm.noteBox"))
    local sourceProvenance = rootFrame._draftFromCurrentLocation
        and VFN.Constants.SOURCE.manual
        or VFN.Constants.SOURCE.paste

    return {
        title = title ~= "" and title or AutoTitle(resolved.entries),
        source = sourceProvenance,
        visibility = { scope = "account", character = GetCurrentCharacterKey() },
        sourceText = sourceText,
        sourceLines = resolved.sourceLines,
        entries = resolved.entries,
        items = {},
        payload = { note = noteText },
    }
end

-- Send: the single capture-form commit action. Parses the paste box, creates
-- a new field note in the Default library, dispatches waypoints for every
-- resolved entry, then clears the form. There is no separate "Save" step --
-- if the user wants to keep their paste, they hit Send. If they don't,
-- nothing persists.
local function Send(rootFrame)
    local sourceText = GetWidgetText(W(rootFrame, "captureForm.sourceBox"))
    local parsed = VFN.CoordParser:Parse(sourceText)
    local resolved = VFN.CoordResolver:Resolve(parsed, { currentMapID = CH.Mechanics.GetCurrentMapID() })

    if #resolved.entries == 0 then
        SetDraftStatus(rootFrame, "No valid coordinates found.")
        return
    end

    local payload = BuildSetPayload(rootFrame, resolved)
    local created = CH.Mechanics.CreateSet(payload)
    if not (created and created.setID) then
        SetDraftStatus(rootFrame, "Field note was not saved.")
        return
    end

    -- Clear the form so the next paste starts fresh.
    SetText(W(rootFrame, "captureForm.titleBox"), "")
    SetText(W(rootFrame, "captureForm.sourceBox"), "")
    SetText(W(rootFrame, "captureForm.noteBox"), "")
    rootFrame._draftFromCurrentLocation = false

    local s = CH.Mechanics.GetState()
    local selectedSetID = s and s.account and s.account.ui and s.account.ui.selectedSetID
    if selectedSetID then CH.Mechanics.CloseSet() end
    local set = created.set or (s and s.account and s.account.sets and s.account.sets[created.setID])

    if not (VFN.WaypointBackend and VFN.WaypointBackend.Send) then
        SetDraftStatus(rootFrame, "Saved. Waypoint backend unavailable.")
        if VFN.RefreshMainWindow then VFN:RefreshMainWindow() end
        return
    end

    local sendResult = VFN.WaypointBackend:Send(resolved.entries, set)
    if sendResult and sendResult.ok then
        local provider = sendResult.provider or "backend"
        local count = sendResult.sent or #resolved.entries
        local noun = count == 1 and "waypoint" or "waypoints"
        SetDraftStatus(rootFrame, string.format(
            "Saved + sent %d %s %s.", count, provider, noun))
    else
        local err = sendResult and sendResult.errors and sendResult.errors[1] or nil
        SetDraftStatus(rootFrame, "Saved. Send failed"
            .. (err and (": " .. tostring(err)) or "") .. ".")
    end
    if VFN.RefreshMainWindow then VFN:RefreshMainWindow() end
end

-- Pin Here: one-click save the player's current location as a single-entry
-- field note. Independent of the paste box -- the user is saying "I'm here
-- now, save this coord." Goes to the Default library. No Send required.
local function UseCurrentLocation(rootFrame)
    local mapAPI = _G.C_Map
    if not (mapAPI and mapAPI.GetBestMapForUnit and mapAPI.GetPlayerMapPosition) then
        SetDraftStatus(rootFrame, "Current location unavailable.")
        return
    end

    local mapID = mapAPI.GetBestMapForUnit("player")
    local pos = mapID and mapAPI.GetPlayerMapPosition(mapID, "player") or nil
    if not (mapID and pos and pos.GetXY) then
        SetDraftStatus(rootFrame, "Current location unavailable.")
        return
    end

    local x, y = pos:GetXY()
    if not (x and y) then
        SetDraftStatus(rootFrame, "Current location unavailable.")
        return
    end

    -- Build a synthetic single-entry resolved set + commit. Parser/Resolver
    -- are bypassed since we already have a valid coord direct from the map
    -- API; running them would just re-validate what we know is good.
    local entry = {
        coordMapID = mapID,
        x = x, y = y,
        rawX = x * 100, rawY = y * 100,
    }
    local resolved = {
        entries = { entry },
        sourceLines = {
            { lineNo = 1, text = string.format("/way %d %.1f %.1f", mapID, x * 100, y * 100) },
        },
    }

    -- Pin Here is independent of the form fields -- it's a one-click commit
    -- of the player's current location. Build the payload directly so we
    -- don't accidentally inherit stale title/note text from a previous draft.
    local payload = {
        title       = AutoTitle(resolved.entries),
        source      = VFN.Constants.SOURCE.manual,
        visibility  = { scope = "account", character = GetCurrentCharacterKey() },
        sourceText  = resolved.sourceLines[1].text,
        sourceLines = resolved.sourceLines,
        entries     = resolved.entries,
        items       = {},
        payload     = { note = "" },
    }
    local created = CH.Mechanics.CreateSet(payload)
    if not (created and created.setID) then
        SetDraftStatus(rootFrame, "Pin failed.")
        return
    end

    SetDraftStatus(rootFrame, "Saved current location.")
    if VFN.RefreshMainWindow then VFN:RefreshMainWindow() end
end

-- Bare-coord auto-note --------------------------------------------------------
-- When the user pastes coordinates with no map context (no `/way Mapname`
-- header, no Wowhead `worldmap:MAPID:` link), the resolver uses the
-- player's CURRENT map for those coords. Auto-suggest a note saying so
-- (e.g. "Eversong Woods mapID:1234") so the user knows what they'll get
-- when they click Save. Only writes if the note field is empty -- never
-- overwrite user input.

local function CountBareCoordCandidates(sourceText)
    if not (VFN.CoordParser and VFN.CoordParser.Parse) then return 0, 0 end
    local parsed = VFN.CoordParser:Parse(sourceText)
    local total, bare = 0, 0
    for _, cand in ipairs(parsed.candidates or {}) do
        total = total + 1
        if not cand.mapHint then bare = bare + 1 end
    end
    return total, bare
end

local function CurrentMapNameAndID()
    local mapAPI = _G.C_Map
    if not (mapAPI and mapAPI.GetBestMapForUnit and mapAPI.GetMapInfo) then return nil, nil end
    local mapID = mapAPI.GetBestMapForUnit("player")
    if not mapID then return nil, nil end
    local info = mapAPI.GetMapInfo(mapID)
    return info and info.name, mapID
end

local function AutoSuggestNoteForBareCoords(rootFrame, sourceText)
    local noteBox = W(rootFrame, "captureForm.noteBox")
    if not noteBox then return end
    if Trim(GetWidgetText(noteBox)) ~= "" then return end  -- never overwrite user input

    local total, bare = CountBareCoordCandidates(sourceText)
    if total == 0 or bare == 0 then return end
    -- Only auto-suggest if MOST of the coords are bare. Mixed pastes
    -- (some with maps, some bare) usually mean the player knows what
    -- they're doing and a generic note would be misleading.
    if bare < total then return end

    local mapName, mapID = CurrentMapNameAndID()
    if not (mapName and mapID) then return end
    local suggested = string.format("%s mapID:%d", mapName, mapID)
    SetText(noteBox, suggested)
end

-- Public API ----------------------------------------------------------------

-- View switcher click: dispatches the view change. Click on the active view
-- toggles back to nil (returns to detail/collapsed via MainFrame's mode picker).
-- NOTE: written as if/else, not `cond and a or b`, because the "true" branch
-- is nil -- the ternary idiom would short-circuit to the "false" branch and
-- the active-view click would become a no-op.
local function ToggleView(target)
    return function()
        local current = CH.Mechanics.GetUI().view
        if current == target then
            CH.Mechanics.SetUIPersistent("view", nil)
        else
            CH.Mechanics.SetUIPersistent("view", target)
        end
    end
end

-- Library dropdown above the stream list -- click pops a context menu of
-- every non-deleted library; selecting one writes the choice into
-- session.ui.stream.libraryID and BuildStreamItems re-filters.
local function ShowStreamLibraryMenu(ownerFrame)
    local state = CH.Mechanics.GetState()
    if not (state and state.account) then return end
    local libs = state.account.libraries or {}
    local defaultID = state.account.defaultLibraryID

    local entries = {}
    for libID, lib in pairs(libs) do
        if not lib.deletedAt then
            entries[#entries + 1] = {
                id = libID, name = lib.name or "?",
                isDefault = lib.isDefault == true,
                count = lib.setIDs and #lib.setIDs or 0,
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.isDefault ~= b.isDefault then return a.isDefault end
        return a.name:lower() < b.name:lower()
    end)

    local items = { { text = "Stream library", isTitle = true } }
    for _, e in ipairs(entries) do
        local libID = e.id
        items[#items + 1] = {
            text = string.format("%s%s  (%d)",
                e.name, e.isDefault and "  [Default]" or "", e.count),
            callback = function()
                -- Default = nil sentinel so a fresh session falls back cleanly.
                CH.Mechanics.SetUITransientView("stream", "libraryID",
                    (libID == defaultID) and nil or libID)
            end,
        }
    end
    CH.UI.ShowMenu(ownerFrame, items)
end

function StreamController:Wire(rootFrame)
    CH.UI.OnClick(rootFrame, "captureForm.sendButton",            function() Send(rootFrame) end)
    CH.UI.OnClick(rootFrame, "captureForm.currentLocationButton", function() UseCurrentLocation(rootFrame) end)
    CH.UI.OnClick(rootFrame, "streamPanel.captureButton", ToggleView("capture"))
    CH.UI.OnClick(rootFrame, "streamPanel.libraryButton", ToggleView("library"))
    CH.UI.OnClick(rootFrame, "streamPanel.configButton",  ToggleView("config"))
    CH.UI.OnClick(rootFrame, "streamPanel.libraryDropdown", function(btn)
        ShowStreamLibraryMenu(btn)
    end)
    -- Bidirectional toggle:
    --   atStream  (arrow points right) -> click opens the most recent set's
    --                                     detail (top of the stream list).
    --   otherwise (arrow points left)  -> click closes any active set +
    --                                     clears explicit view, falling
    --                                     back to "collapsed" (rail only).
    CH.UI.OnClick(rootFrame, "streamPanel.backButton", function()
        local s = CH.Mechanics.GetState()
        local ui = s and s.account and s.account.ui or {}
        local selectedSetID = ui.selectedSetID
        local view = ui.view
        local atStream = (selectedSetID == nil) and (view == nil)
        if atStream then
            -- Open the most-recently-touched set so detail has something to
            -- show. BuildStreamItems is already sorted newest-first.
            local items = VFN.Selectors.BuildStreamItems(s, GetCurrentCharacterKey())
            local first = items and items[1]
            if first and first.setID then CH.Mechanics.OpenSet(first.setID) end
        else
            if selectedSetID then CH.Mechanics.CloseSet() end
            CH.Mechanics.SetUIPersistent("view", nil)
        end
    end)

    local sourceBox = W(rootFrame, "captureForm.sourceBox")
    if sourceBox and sourceBox.SetScript then
        sourceBox:SetScript("OnTextChanged", function(_, userInput)
            if not userInput then return end
            rootFrame._draftFromCurrentLocation = false
            local sourceText = Trim(GetWidgetText(sourceBox))
            local sourceLabel = W(rootFrame, "captureForm.sourceLabel")
            if sourceText == "" then
                SetDraftStatus(rootFrame, "Paste coordinates, then click Send Waypoints.")
                if sourceLabel and sourceLabel.SetHint then sourceLabel:SetHint("") end
                return
            end
            -- Parse to give live feedback: how many candidates? any valid?
            -- Lets the player see "5 coordinates ready" before they save.
            local total = select(1, CountBareCoordCandidates(sourceText))
            if total == 0 then
                SetDraftStatus(rootFrame, "No valid coordinates found - check format.")
            elseif total == 1 then
                SetDraftStatus(rootFrame, "Draft ready - 1 coordinate. Click Send.")
            else
                SetDraftStatus(rootFrame, string.format(
                    "Draft ready - %d coordinates. Click Send.", total))
            end
            -- Live count chip in the right-side hint of the PASTE COORDINATES label.
            if sourceLabel and sourceLabel.SetHint then
                sourceLabel:SetHint(total > 0 and (tostring(total) .. " parsed") or "no coords yet")
            end
            AutoSuggestNoteForBareCoords(rootFrame, sourceText)
        end)
    end
end

-- (No Refresh -- every stream-tab widget value flows through bindings:
--  streamList -> stream.items; streamStatus -> stream.statusText;
--  libraryDropdown -> stream.libraryDropdownLabel; the four icon buttons
--  -> stream.{capture,library,config,back}Active.)

VFN.Controllers:Register("stream", StreamController)

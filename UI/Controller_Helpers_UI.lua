-- VFN.ControllerHelpers.UI
--
-- The "manipulate visible surfaces" half of CH. Widget access, row factory
-- builders, row paint facades, and workflow dialogs (Confirm, ShowMenu).
-- No state reads, no Store dispatch, no domain actions.
--
-- Row chrome + badge paint facades delegate to VFN.UI:EnsureRowChrome /
-- :EnsureRowBadge (Components.lua) for construction and to
-- VFN.Theme.Skinners.RowChrome / .BadgePill for paint. The facades exist so
-- callers in row factories don't have to do a four-line dance per row.

VFN = VFN or {}
VFN.ControllerHelpers = VFN.ControllerHelpers or {}
VFN.ControllerHelpers.UI = VFN.ControllerHelpers.UI or {}

local UI = VFN.ControllerHelpers.UI

-- ===== Widget access =====================================================

function UI.W(rootFrame, id)
    return rootFrame and rootFrame.widgets and rootFrame.widgets[id] or nil
end

-- Set a button's text AND refresh its intrinsic width so the next layout
-- pass can grow/shrink it to fit the new label. Use for cycle buttons whose
-- label changes at runtime when `width = "auto"` is set on the spec.
-- For static-text buttons, plain UI.SetText is fine -- the factory measured
-- them once at construction.
function UI.SetButtonText(widget, text)
    if not widget then return end
    if widget.SetText then widget:SetText(text or "") end
    if widget.RefreshIntrinsicWidth then widget:RefreshIntrinsicWidth() end
end

function UI.SetText(widget, text)
    if widget and widget.SetText then widget:SetText(text or "") end
end

-- OnClick(rootFrame, widgetId, fn) -- safe attachment of OnClick to a widget
-- looked up by id. Common pattern across all controllers.
function UI.OnClick(rootFrame, widgetId, fn)
    local w = UI.W(rootFrame, widgetId)
    if w and w.SetScript then w:SetScript("OnClick", fn) end
end

-- ===== Workflow dialogs ==================================================

-- StaticPopup-based confirm dialog. Replaces ad-hoc StaticPopupDialogs.VFN_*
-- entries scattered across controllers. opts shape:
--   id        unique key (string) -- popup registered under StaticPopupDialogs[id].
--   text      prompt text. May contain %s/%d for textArg1/textArg2.
--   accept    label for primary button (default "OK")
--   cancel    label for secondary button (default "Cancel")
--   onAccept  function(value, data) called when accepted. For input dialogs
--             value = entered text. For confirm-only dialogs value = nil.
--   input     bool -- true to show a text input (StaticPopup hasEditBox)
--   maxLetters input length cap (default 64)
--   data      passed verbatim to StaticPopup_Show as the data arg
--   textArg1, textArg2  string format args for `text`
function UI.Confirm(opts)
    if type(opts) ~= "table" then return end
    local popupDialogs = _G.StaticPopupDialogs
    local popupShow    = _G.StaticPopup_Show
    if not (popupDialogs and popupShow) then return end
    local id = opts.id or "VFN_CONFIRM"
    popupDialogs[id] = popupDialogs[id] or {
        text       = opts.text   or "Confirm?",
        button1    = opts.accept or "OK",
        button2    = opts.cancel or "Cancel",
        hasEditBox = opts.input == true,
        maxLetters = opts.maxLetters or 64,
        OnAccept   = function(self, data)
            if opts.input then
                local box = self.editBox or (self.GetEditBox and self:GetEditBox())
                local val = box and box.GetText and box:GetText() or ""
                if opts.onAccept then opts.onAccept(val, data) end
            else
                if opts.onAccept then opts.onAccept(nil, data) end
            end
        end,
        EditBoxOnEnterPressed = opts.input and function(self)
            local val = self:GetText() or ""
            if opts.onAccept then opts.onAccept(val) end
            self:GetParent():Hide()
        end or nil,
        EditBoxOnEscapePressed = opts.input and function(self)
            self:GetParent():Hide()
        end or nil,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
    popupShow(id, opts.textArg1, opts.textArg2, opts.data)
end

-- Modern context-menu helper. WoW 11.0+ replaced UIDropDownMenu / EasyMenu
-- with the MenuUtil API; this wraps it so controllers don't have to know.
-- items: list of:
--   { text, callback }            -- normal button
--   { text, isTitle = true }      -- title row (non-clickable header)
--   { isDivider = true }          -- separator
--   { text, callback, disabled }  -- disabled button (still shown)
-- owner: the frame to anchor the menu against (typically the row that was
-- right-clicked). The menu pops at the cursor.
function UI.ShowMenu(owner, items)
    local menuUtil = _G.MenuUtil
    if not (menuUtil and menuUtil.CreateContextMenu) then return end
    menuUtil.CreateContextMenu(owner, function(_, root)
        for _, item in ipairs(items or {}) do
            if item.isDivider then
                if root.CreateDivider then root:CreateDivider() end
            elseif item.isTitle then
                if root.CreateTitle then root:CreateTitle(item.text or "") end
            else
                local btn = root:CreateButton(item.text or "", item.callback or function() end)
                if item.disabled and btn and btn.SetEnabled then btn:SetEnabled(false) end
            end
        end
    end)
end

-- ===== Row factory builders ==============================================

-- Lazily create a row's text FontString, with the right font role applied
-- BEFORE any SetText is called on it (FontString without inheritsFrom errors
-- on SetText until SetFontObject is applied).
function UI.ensureRowText(row, font)
    if row.vfnText or not row.CreateFontString then return end
    row.vfnText = row:CreateFontString(nil, "OVERLAY")
    if row.vfnText.SetPoint then
        row.vfnText:SetPoint("LEFT", 8, 0); row.vfnText:SetPoint("RIGHT", -8, 0)
    end
    if row.vfnText.SetJustifyH then row.vfnText:SetJustifyH("LEFT") end
    if row.vfnText.SetWordWrap then row.vfnText:SetWordWrap(false) end
    if VFN.UI and VFN.UI.applyFontRole then
        VFN.UI.applyFontRole(row.vfnText, font)
    end
    VFN.Theme:Register(row.vfnText, "Text")
end

function UI.clearRow(row)
    if row.SetScript then row:SetScript("OnClick", nil) end
    if row.vfnText then row.vfnText:SetText("") end
    if row.SetText then row:SetText("") end
end

-- Generic row factory builder. Returns a function (font) -> { Configure, Reset }
-- matching the LayoutRegistry "row:<name>" contract. Pass:
--   opts.deriveText(elementData)  -- text for this element
--   opts.onClick(elementData)     -- optional; returns OnClick handler
--   opts.height                   -- row height
function UI.MakeRowFactory(opts)
    if type(opts) ~= "table" then error("MakeRowFactory: opts table required", 2) end
    if type(opts.deriveText) ~= "function" then error("MakeRowFactory: opts.deriveText required", 2) end
    if type(opts.height) ~= "number" then error("MakeRowFactory: opts.height required", 2) end

    return function(font)
        return {
            Configure = function(row, ed)
                ed = ed or {}
                local text = opts.deriveText(ed) or ""
                UI.ensureRowText(row, font)
                if row.vfnText then row.vfnText:SetText(text) end
                if row.SetText then row:SetText(text) end
                if row.SetHeight then row:SetHeight(opts.height) end
                VFN.Theme:Register(row, "Button")
                if row.SetScript then
                    local handler = opts.onClick and opts.onClick(ed) or nil
                    row:SetScript("OnClick", handler)
                end
            end,
            Reset = UI.clearRow,
        }
    end
end

-- Multi-line row factory. Builds rows with N stacked FontStrings (title +
-- meta + note style). Replaces the per-controller boilerplate that
-- streamRow / libraryCardRow each duplicated. Spec:
--
--   opts = {
--       lines = {
--           { fontRole = "subheading", deriveText = fn, themeRole = "Text" },
--           { fontRole = "caption",    deriveText = fn, themeRole = "TextDim" },
--           { fontRole = "small",      deriveText = fn, themeRole = "TextDim",
--             hideIfEmpty = true },
--       },
--       onClick      = function(ed) return function() ... end end,  -- LMB
--       rightClick   = function(ed) return function(self) ... end end,  -- RMB
--       insetLeft    = 10,  insetRight = -10, insetTop = -8,  -- chrome padding
--       lineGap      = 2,                       -- vertical gap between FontStrings
--   }
function UI.MakeStackedRowFactory(opts)
    if type(opts) ~= "table" or type(opts.lines) ~= "table" or #opts.lines == 0 then
        error("MakeStackedRowFactory: opts.lines list required", 2)
    end
    local insetL    = opts.insetLeft  or 10
    local insetR    = opts.insetRight or -10
    local insetTop  = opts.insetTop   or -8
    local lineGap   = opts.lineGap    or 2

    return function(template)
        return {
            Configure = function(row, ed)
                ed = ed or {}
                if not row._vfnLaidOut and row.CreateFontString then
                    local prevFs = nil
                    for i, line in ipairs(opts.lines) do
                        local fs = row:CreateFontString(nil, "OVERLAY")
                        if i == 1 then
                            fs:SetPoint("TOPLEFT",  insetL, insetTop)
                            fs:SetPoint("TOPRIGHT", insetR, insetTop)
                        else
                            fs:SetPoint("TOPLEFT", prevFs, "BOTTOMLEFT", 0, -lineGap)
                            fs:SetPoint("RIGHT",   insetR, 0)
                        end
                        fs:SetJustifyH("LEFT")
                        fs:SetWordWrap(line.wrap == true)
                        if VFN.UI and VFN.UI.applyFontRole then
                            VFN.UI.applyFontRole(fs, line.fontRole or template.font)
                        end
                        VFN.Theme:Register(fs, line.themeRole or "Text")
                        row["vfnLine" .. i] = fs
                        prevFs = fs
                    end
                    VFN.Theme:Register(row, "Button")
                    row._vfnLaidOut = true
                end

                for i, line in ipairs(opts.lines) do
                    local fs = row["vfnLine" .. i]
                    if fs then
                        local text = line.deriveText(ed) or ""
                        fs:SetText(text)
                        if line.hideIfEmpty then
                            if text == "" then fs:Hide() else fs:Show() end
                        end
                    end
                end

                if row.SetHeight then row:SetHeight(template.height) end

                if row.SetScript then
                    if opts.rightClick then
                        if row.RegisterForClicks then
                            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                        end
                        row:SetScript("OnClick", function(self, button)
                            if button == "RightButton" then
                                local h = opts.rightClick(ed); if h then h(self) end
                            elseif opts.onClick then
                                local h = opts.onClick(ed); if h then h() end
                            end
                        end)
                    elseif opts.onClick then
                        row:SetScript("OnClick", opts.onClick(ed))
                    end
                end
            end,
            Reset = function(row)
                if row.SetScript then row:SetScript("OnClick", nil) end
                local i = 1
                while row["vfnLine" .. i] do
                    row["vfnLine" .. i]:SetText("")
                    i = i + 1
                end
            end,
        }
    end
end

-- ===== Row chrome + badge paint facades ==================================
--
-- Construction lives in VFN.UI:EnsureRowChrome / :EnsureRowBadge (Components).
-- Paint lives in VFN.Theme.Skinners.RowChrome / .BadgePill. These thin
-- wrappers stash the per-row state and register with the Theme registry so
-- Theme:Reload() repaints every registered row via ApplyAll automatically.

function UI.EnsureRowChrome(row)
    return VFN.UI and VFN.UI.EnsureRowChrome and VFN.UI:EnsureRowChrome(row) or nil
end

function UI.PaintRowChrome(row, selected)
    if not row then return end
    if VFN.UI and VFN.UI.EnsureRowChrome then VFN.UI:EnsureRowChrome(row) end
    if VFN.Theme and VFN.Theme.Register then
        VFN.Theme:Register(row, "RowChrome", { selected = selected and true or false })
    end
end

function UI.PaintRowBadge(row, text)
    if not row then return end
    if VFN.UI and VFN.UI.EnsureRowBadge then VFN.UI:EnsureRowBadge(row) end
    if VFN.Theme and VFN.Theme.Register then
        VFN.Theme:Register(row, "BadgePill", {
            text = (text ~= nil and text ~= "") and text or nil,
            variant = "count",
        })
    end
end

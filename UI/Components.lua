-- VFN.UI Components
--
-- The curated palette of standard UI elements. Two responsibilities, kept in
-- one file per element so they always change together:
--
--   1. Constructor (VFN.UI:Button, :EditBox, :ScrollBox, ...) -- WoW-aware
--      build of the widget with theme registration and sane defaults.
--   2. VFN.WidgetTypes:Register("kind", { build, skin, dispatch, ... }) --
--      closed-taxonomy registration; Layout:BuildAll routes by spec.kind.
--
-- Build the addon around this standard. The bar for adding a new component
-- is high: prefer extending an existing one (more spec.options fields) over
-- a new kind. New kinds should represent a genuinely new visual / interactive
-- shape, not a configuration of an existing one.

VFN = VFN or {}
VFN.UI = VFN.UI or {}

local CreateScrollBoxListLinearView = _G.CreateScrollBoxListLinearView
local ScrollUtil = _G.ScrollUtil
local CreateDataProvider = _G.CreateDataProvider
local ScrollBoxConstants = _G.ScrollBoxConstants

local function SetDataProvider(scrollBox, provider, retainScroll)
    if scrollBox.SetDataProvider then
        scrollBox:SetDataProvider(provider, retainScroll)
    else
        scrollBox.provider = provider
        scrollBox.retainScroll = retainScroll
    end
end

-- Apply a Theme font role to a widget. Errors loudly if role is missing --
-- validator catches that at startup, runtime should never see it. If the
-- widget lacks SetFontObject (test mock) the call is a no-op on PURPOSE so
-- tests don't have to mock the font system; production widgets always
-- expose SetFontObject.
local function applyFontRole(widget, role)
    if not widget then return end
    if not role then
        error("applyFontRole: font role is required (validator should have caught this)", 2)
    end
    local fo = VFN.Theme:GetFont(role)
    if not fo then
        error(("applyFontRole: unknown font role %q"):format(tostring(role)), 2)
    end
    if widget.SetFontObject and type(fo) == "table" and fo.GetFont then
        widget:SetFontObject(fo)
    elseif widget.SetFont and type(fo) == "table" and fo.file then
        widget:SetFont(fo.file, fo.size, fo.flags or "")
    end
end
VFN.UI.applyFontRole = applyFontRole

-- Apply font role to a FontString (separate path because FontStrings don't
-- have the same SetFontObject signature behaviour as Frames in some test
-- mocks, but real WoW handles both identically).
local function applyFontToFS(fs, role)
    applyFontRole(fs, role)
end

-- ===== Shared dispatchers (binding push functions) ========================
-- Per spec section 3 + LUA_SAMPLES.md / BindingEngine: each WidgetType
-- declares `dispatch = { fields = {...}, push = function(widget, values) end }`.
-- The push function MUST be idempotent and cheap on no-op. These shared
-- functions are referenced from multiple kinds (label family share one).

local function dispatchText(widget, values)
    if values.text ~= nil and widget.SetText then widget:SetText(tostring(values.text)) end
end

local function dispatchButton(widget, values)
    if values.text ~= nil then
        if widget.RefreshIntrinsicWidth then
            widget:SetText(tostring(values.text))
            widget:RefreshIntrinsicWidth()
        elseif widget.SetText then
            widget:SetText(tostring(values.text))
        end
    end
    if values.enabled ~= nil and widget.SetEnabled then
        widget:SetEnabled(values.enabled and true or false)
    end
    if values.active ~= nil and widget.SetActive then
        widget:SetActive(values.active and true or false)
    end
end

local function dispatchEditbox(widget, values)
    if values.text == nil or not widget.SetText then return end
    -- Skip the SetText if the current widget text already matches the desired
    -- value -- prevents cursor resets and OnTextChanged loops when the user
    -- is mid-typing and a state notify fires.
    local current = widget.GetText and widget:GetText() or nil
    if current ~= tostring(values.text) then
        widget:SetText(tostring(values.text))
        if widget._vfnPlaceholderRefresh then widget._vfnPlaceholderRefresh() end
    end
end

local function dispatchChip(widget, values)
    if values.text ~= nil and widget.SetChipText then widget:SetChipText(tostring(values.text)) end
    if values.status ~= nil and widget.SetStatus then widget:SetStatus(values.status) end
end

local function dispatchStatCard(widget, values)
    if values.value ~= nil and widget.SetValue then widget:SetValue(tostring(values.value)) end
    if values.label ~= nil and widget.SetLabel then widget:SetLabel(tostring(values.label)) end
end

local function dispatchScrollbox(widget, values)
    if values.items ~= nil and widget.SetItems then
        widget:SetItems(values.items, true)
    end
end

-- FieldLabel dispatches both text (left primary) and hint (right dim).
-- Routed through SetText / SetHint on the composed widget. Hint is optional;
-- a binding can update text only without touching hint and vice versa.
local function dispatchFieldLabel(widget, values)
    if values.text ~= nil and widget.SetText then widget:SetText(tostring(values.text)) end
    if values.hint ~= nil and widget.SetHint then widget:SetHint(tostring(values.hint)) end
end

-- Universal destroy path per spec section 3.6: every widget that registers
-- script handlers must declare destroy so Lua GC can collect through C++
-- frame refs. This clears the standard mouse/keyboard/edit/event scripts
-- and unregisters any RegisterEvent subscriptions. Theme registry uses
-- weak keys for the widget so no manual unregister is needed there.
local DESTROY_SCRIPTS = {
    "OnClick", "OnEnter", "OnLeave", "OnMouseDown", "OnMouseUp",
    "OnEnterPressed", "OnEscapePressed", "OnTabPressed", "OnChar",
    "OnTextChanged", "OnEditFocusGained", "OnEditFocusLost",
    "OnKeyDown", "OnKeyUp", "OnDragStart", "OnDragStop",
    "OnShow", "OnHide", "OnUpdate", "OnEvent",
}

local function destroyWidget(widget)
    if not widget then return end
    if widget.SetScript then
        for _, ev in ipairs(DESTROY_SCRIPTS) do
            pcall(widget.SetScript, widget, ev, nil)
        end
    end
    if widget.UnregisterAllEvents then pcall(widget.UnregisterAllEvents, widget) end
end

-- ===== Frame: bare-minimum primitive (used as a fallback container) =====

function VFN.UI:Frame(parent)
    -- Theme:Register is owned by Layout's buildKind via the WidgetType's
    -- `skin = "Frame"` declaration (spec section 5). When VFN.UI:Frame is
    -- called outside Layout (one-off / test), the caller must register.
    return CreateFrame("Frame", nil, parent, "BackdropTemplate")
end

VFN.WidgetTypes:Register("frame", {
    build = function(parent, _spec) return VFN.UI:Frame(parent) end,
    skin  = "Frame",
})

-- ===== Spacer: invisible flex Frame =====

function VFN.UI:Spacer(parent)
    return CreateFrame("Frame", nil, parent)
end

VFN.WidgetTypes:Register("spacer", { build = function(parent, _spec)
    return VFN.UI:Spacer(parent)
end })

-- ===== Label: regular text FontString =====

function VFN.UI:Label(parent, text, font, justifyH, optsTable)
    if not parent or not parent.CreateFontString then return nil end
    local fs = parent:CreateFontString(nil, "OVERLAY")
    -- Font MUST be set before SetText -- a FontString created without
    -- inheritsFrom has no font assigned, and SetText errors with
    -- "Font not set" until SetFontObject/SetFont applies one.
    applyFontToFS(fs, font)
    if fs.SetText then fs:SetText(text or "") end
    -- Default LEFT so form labels (TITLE, PASTE COORDINATES) hug the left
    -- edge of their flex slot. Override with `justifyH = "CENTER" / "RIGHT"`
    -- in the spec when needed (panel titles, status badges).
    if fs.SetJustifyH then fs:SetJustifyH(justifyH or "LEFT") end

    -- Tag-driven theme role (spec section 3.7):
    --   no tag     -> "Text"      (primary text colour)
    --   "dim"      -> "TextDim"   (dim/secondary)
    --   "status"   -> "TextStatus"(accent status colour)
    local opts = optsTable or {}
    local role = "Text"
    if opts.tags then
        for _, t in ipairs(opts.tags) do
            if     t == "dim"    then role = "TextDim";    break
            elseif t == "status" then role = "TextStatus"; break
            end
        end
    end
    -- Vertical justify + wrap. The dim tag historically implied TOP justify
    -- (multi-line description text); preserve that default unless the caller
    -- overrides via opts.justifyV. Wrap is explicit opt-in.
    local justifyV = opts.justifyV
    if justifyV == nil and role == "TextDim" and fs.SetJustifyV then justifyV = "TOP" end
    if justifyV and fs.SetJustifyV then fs:SetJustifyV(justifyV) end
    if opts.wrap and fs.SetWordWrap then fs:SetWordWrap(true) end

    VFN.Theme:Register(fs, role)
    return fs
end

-- Skin is intentionally omitted here (and on statCard below). Spec section 3
-- makes `skin` optional; it identifies a single paint role for the widget.
-- Label maps to ONE of three roles (Text / TextDim / TextStatus) chosen at
-- build time from spec.tags. statCard owns two FontStrings (value + label)
-- with independent paint roles. In both cases, Theme:Register is called
-- directly on each FontString -- no kind-level skin string would describe
-- the multi-role / tag-resolved pattern. This is a deliberate divergence
-- from the skin-role convention, not an oversight.
VFN.WidgetTypes:Register("label", {
    build = function(parent, spec)
        local opts = spec.options or {}
        return VFN.UI:Label(parent, spec.text or "", spec.font, spec.justifyH, {
            tags     = spec.tags,
            wrap     = opts.wrap or spec.wrap,
            justifyV = opts.justifyV or spec.justifyV,
        })
    end,
    dispatch = { fields = { "text" }, push = dispatchText },
})

-- ===== Divider: 1px horizontal hairline rule, theme-coloured ==============

function VFN.UI:Divider(parent)
    if not (parent and CreateFrame) then return nil end
    local frame = CreateFrame("Frame", nil, parent)
    if frame.SetHeight then frame:SetHeight(1) end
    if frame.CreateTexture then
        local tex = frame:CreateTexture(nil, "ARTWORK")
        if tex.SetAllPoints then tex:SetAllPoints() end
        -- Register with Theme.Skinners.Divider so theme repaints flow through.
        VFN.Theme:Register(tex, "Divider")
    end
    return frame
end

VFN.WidgetTypes:Register("divider", {
    build = function(parent, _spec) return VFN.UI:Divider(parent) end,
    skin  = "Divider",
})

-- ===== StatusBanner: chromed status row -- 3px accent left bar + tinted bg ==
-- Used for the persistent capture form prompt ("Paste coordinates, then..."
-- and live status messages). Visually distinct from inline labels so the eye
-- catches it as a status surface, not body text.
-- Forwards SetText to the inner FontString so controllers can update it.

function VFN.UI:StatusBanner(parent, text, font)
    if not (parent and CreateFrame) then return nil end
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    -- Tinted accent fill + 3px left bar. Both textures register with the
    -- Theme registry so palette swaps repaint automatically.
    if frame.CreateTexture then
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        if bg.SetAllPoints then bg:SetAllPoints() end
        VFN.Theme:Register(bg, "AccentBg")

        local bar = frame:CreateTexture(nil, "ARTWORK")
        if bar.SetPoint then
            bar:SetPoint("TOPLEFT", 0, 0)
            bar:SetPoint("BOTTOMLEFT", 0, 0)
        end
        if bar.SetWidth then bar:SetWidth(3) end
        VFN.Theme:Register(bar, "AccentBar")
    end
    -- FontString inset from the left bar.
    local fs = frame:CreateFontString(nil, "OVERLAY")
    applyFontToFS(fs, font)
    if fs.SetText then fs:SetText(text or "") end
    if fs.SetJustifyH then fs:SetJustifyH("LEFT") end
    if fs.SetPoint then
        fs:SetPoint("LEFT", 10, 0)
        fs:SetPoint("RIGHT", -8, 0)
    end
    VFN.Theme:Register(fs, "Text")
    -- Forward SetText so callers can treat the frame as the text widget.
    function frame:SetText(t)
        self.text = t or ""               -- mirrors mock's .text convention
        if fs.SetText then fs:SetText(t or "") end
    end
    function frame:GetText() return (fs.GetText and fs:GetText()) or "" end
    frame.text = text or ""
    return frame
end

VFN.WidgetTypes:Register("statusBanner", {
    build = function(parent, spec)
        return VFN.UI:StatusBanner(parent, spec.text or "", spec.font)
    end,
    -- Live status text flows via the binding engine instead of imperative
    -- SetText (spec section 3 action 4 -- content-slot contract).
    dispatch = { fields = { "text" }, push = dispatchText },
})

-- ===== FieldLabel: uppercase label on left + dim hint span on right ========
-- Used for capture form section headers (TITLE / PASTE COORDINATES / NOTE).
-- The right hint is set at construction or live-updated via SetHint().

function VFN.UI:FieldLabel(parent, text, font, hint)
    if not (parent and CreateFrame) then return nil end
    local frame = CreateFrame("Frame", nil, parent)
    local label = frame:CreateFontString(nil, "OVERLAY")
    applyFontToFS(label, font)
    if label.SetText then label:SetText(text or "") end
    if label.SetJustifyH then label:SetJustifyH("LEFT") end
    if label.SetPoint then label:SetPoint("LEFT", 0, 0) end
    VFN.Theme:Register(label, "Text")

    local hintFs = frame:CreateFontString(nil, "OVERLAY")
    applyFontToFS(hintFs, "small")
    if hintFs.SetText then hintFs:SetText(hint or "") end
    if hintFs.SetJustifyH then hintFs:SetJustifyH("RIGHT") end
    if hintFs.SetPoint then hintFs:SetPoint("RIGHT", 0, 0) end
    VFN.Theme:Register(hintFs, "TextDim")

    function frame:SetText(t)
        self.text = t or ""               -- mirrors mock's .text convention
        if label.SetText then label:SetText(t or "") end
    end
    function frame:SetHint(t) if hintFs.SetText then hintFs:SetText(t or "") end end
    -- Seed .text so introspection at construction time sees the initial value.
    frame.text = text or ""
    return frame
end

VFN.WidgetTypes:Register("fieldLabel", {
    build = function(parent, spec)
        local hint = (spec.options and spec.options.hint) or spec.hint or ""
        return VFN.UI:FieldLabel(parent, spec.text or "", spec.font, hint)
    end,
    -- Both the primary text and the right-side dim hint flow through bindings;
    -- callers that need live hint updates do so declaratively, not via SetHint.
    dispatch = { fields = { "text", "hint" }, push = dispatchFieldLabel },
})

-- ===== Atlas: Frame with a single Texture set to a Blizzard atlas =====

function VFN.UI:Atlas(parent, atlasName, texturePath)
    local frame = CreateFrame("Frame", nil, parent)
    if frame.CreateTexture then
        local tex = frame:CreateTexture(nil, "ARTWORK")
        if tex.SetAllPoints then tex:SetAllPoints() end
        if tex.SetAtlas and atlasName then
            tex:SetAtlas(atlasName, false)
        elseif tex.SetTexture and texturePath then
            tex:SetTexture(texturePath)
        end
        frame.texture = tex
    end
    return frame
end

VFN.WidgetTypes:Register("atlas", { build = function(parent, spec)
    return VFN.UI:Atlas(parent, spec.atlas, spec.texture)
end })

function VFN.UI:Button(parent, text, font)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    if button.SetText then button:SetText(text or "") end
    -- Theme:Register owned by Layout via WidgetType.skin = "Button"
    -- (spec section 5). Direct callers outside Layout must register manually.
    applyFontRole(button, font)
    -- Universal state mutator. Used by the BindingEngine to push `active`
    -- (and any future flags) from selectors. The skinner reads state from
    -- VFN.Theme.states[widget] and combines it with the design-time variant
    -- stashed at construction. See Theme.Skinners.Button.
    function button:SetState(updates) VFN.Theme:SetState(self, updates) end
    function button:SetActive(value) VFN.Theme:SetState(self, { active = value and true or false }) end
    -- Intrinsic width = text width + ~28px padding for left/right chrome.
    -- Read by the layout engine when spec.width == "auto"; ignored otherwise.
    -- Buttons whose text changes (cycle buttons) should call RefreshIntrinsicWidth
    -- after SetText so the layout reflows on the next Refresh.
    button.RefreshIntrinsicWidth = function(btn)
        if btn.GetTextWidth then
            local w = btn:GetTextWidth() or 0
            if w > 0 then btn._intrinsicWidth = math.ceil(w) + 28 end
        end
    end
    button:RefreshIntrinsicWidth()
    return button
end

-- (Unified `button` WidgetTypes registration lives below buildToggleButton
--  so all four internal builders are in scope when the closure is created.)

-- ===== CloseButton: bare button with atlas-icon child (VSS pattern) =====
-- Use for X close buttons in panel headers. Different SHAPE from a standard
-- button (no text label, square icon child), so it gets its own kind rather
-- than being a button variant.

local function buildCloseButton(parent, opts)
    opts = opts or {}
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(opts.size or 22, opts.size or 22)

    if button.CreateTexture then
        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetSize(opts.iconSize or 16, opts.iconSize or 16)
        icon:SetPoint("CENTER")
        if icon.SetAtlas then icon:SetAtlas(opts.atlas or "XMarksTheSpot") end
        local dim = VFN.Theme:GetColor("text.dim")
        if dim and icon.SetVertexColor then
            icon:SetVertexColor(dim.r, dim.g, dim.b, 1)
        end
        button.icon = icon

        button:SetScript("OnEnter", function(btn)
            local hi = VFN.Theme:GetColor("text.heading")
            if btn.icon and btn.icon.SetVertexColor then
                btn.icon:SetVertexColor(hi.r, hi.g, hi.b, 1)
            end
        end)
        button:SetScript("OnLeave", function(btn)
            local d = VFN.Theme:GetColor("text.dim")
            if d and btn.icon and btn.icon.SetVertexColor then
                btn.icon:SetVertexColor(d.r, d.g, d.b, 1)
            end
        end)
    end

    return button
end

-- (Legacy `closebutton` kind retired in #10.6 -- use kind="button" with
--  options.close = true. The VFN.UI:CloseButton constructor stays as an
--  internal helper called by the unified `button` WidgetTypes entry.)

-- ===== IconButton: 3-state Blizzard atlas button (HDG MakeIconButton pattern)
-- Use for header tab toggles where an icon reads cleaner than a text label.
-- Spec atlasBase = "decor-controls-settings" expects three atlases to exist:
--   <base>-default | <base>-pressed | <base>-active
-- SetActive(bool) swaps the normal atlas to -active so the button reads
-- its toggle state without relying on text prefixes.

-- Tooltip wiring shared by both icon-button factories. Delegates to the
-- TooltipEngine (HookScripts -- composes with the atlas hover-color OnEnter
-- in buildAtlasButton). Per spec section 17.3, this is the standard shape:
-- declare the tooltip data, engine drives GameTooltip.
local function attachIconTooltip(button, opts)
    if not opts.tooltip then return end
    VFN.TooltipEngine:Attach(button, {
        title  = opts.tooltip,
        body   = opts.tooltipBody,
        anchor = "ANCHOR_BOTTOMRIGHT",
    })
end

-- AtlasButton: SINGLE-base Blizzard atlas button (3 suffixes:
-- -default / -pressed / -active). SetActive(bool) swaps the normal atlas
-- to "<base>-active". Use for tab-toggles where one atlas family covers
-- both states (e.g. decor-controls-settings, decor-placement-list).
local function buildAtlasButton(parent, opts)
    opts = opts or {}
    local size = opts.size or 24
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(size, size)

    local base = opts.atlas or "decor-controls-settings"
    button._iconBase = base
    button._iconActive = false
    if button.SetNormalAtlas then
        button:SetNormalAtlas(base .. "-default")
        button:SetPushedAtlas(base .. "-pressed")
        button:SetHighlightAtlas(base .. "-active")
    end

    function button:SetActive(state)
        self._iconActive = state and true or false
        if self.SetNormalAtlas then
            self:SetNormalAtlas(self._iconBase .. (self._iconActive and "-active" or "-default"))
        end
    end

    attachIconTooltip(button, opts)
    return button
end

-- ToggleButton: TWO-base Blizzard atlas button. Default state uses
-- opts.atlas; active state swaps to opts.activeAtlas entirely. Both bases
-- ship with -default and -highlight suffixes (no -pressed; pressed falls
-- back to highlight). Optional rotation in radians applies to all three
-- texture states. Use for direction toggles (arrow-down <-> arrow-up,
-- expanded <-> collapsed, etc).
local function buildToggleButton(parent, opts)
    opts = opts or {}
    local size = opts.size or 24
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(size, size)

    button._iconBase = opts.atlas or error("ToggleButton: opts.atlas required", 2)
    button._iconActiveBase = opts.activeAtlas or error("ToggleButton: opts.activeAtlas required", 2)
    button._iconRotation = opts.rotation
    button._iconActive = false

    local function applyRotation(tex)
        if tex and button._iconRotation and tex.SetRotation then
            tex:SetRotation(button._iconRotation)
        end
    end
    local function applyAtlases(self)
        if not self.SetNormalAtlas then return end
        local current = self._iconActive and self._iconActiveBase or self._iconBase
        self:SetNormalAtlas(current .. "-default")
        self:SetPushedAtlas(current .. "-highlight")
        self:SetHighlightAtlas(current .. "-highlight")
        -- SetAtlas resets the texture state; reapply rotation each time.
        applyRotation(self.GetNormalTexture and self:GetNormalTexture())
        applyRotation(self.GetPushedTexture and self:GetPushedTexture())
        applyRotation(self.GetHighlightTexture and self:GetHighlightTexture())
    end
    applyAtlases(button)

    function button:SetActive(state)
        self._iconActive = state and true or false
        applyAtlases(self)
    end

    attachIconTooltip(button, opts)
    return button
end

-- Unified `button` WidgetTypes entry. One spec kind, four internal
-- shapes routed by options:
--
--   options.close = true            -> close-style (X icon, no template)
--   options.atlas + options.activeAtlas -> toggle (two-base atlas swap)
--   options.atlas (no activeAtlas)  -> atlas (single-base, 3-suffix atlases)
--   (no options.atlas)              -> text button (UIPanelButtonTemplate)
--
-- Text buttons participate in the variant + state.active model from #10.3.
-- Icon buttons keep their existing SetActive (atlas swap) -- different
-- physical mechanism but the same conceptual flag.
VFN.WidgetTypes:Register("button", {
    build = function(parent, spec)
        local opts = spec.options or {}
        -- Promote top-level spec.tooltip (spec section 3 structured form
        -- { title, body, anchor }) into opts.tooltip / opts.tooltipBody so
        -- the existing button factories (which read opts.* for backwards
        -- compatibility) get the same hover text.
        if spec.tooltip and type(spec.tooltip) == "table" then
            local merged = {}
            for k, v in pairs(opts) do merged[k] = v end
            merged.tooltip     = merged.tooltip     or spec.tooltip.title
            merged.tooltipBody = merged.tooltipBody or spec.tooltip.body
            opts = merged
        end
        if opts.close then
            return buildCloseButton(parent, opts)
        elseif opts.atlas and opts.activeAtlas then
            return buildToggleButton(parent, opts)
        elseif opts.atlas then
            return buildAtlasButton(parent, opts)
        end
        -- Text-button path: standard template + variant identity.
        local button = VFN.UI:Button(parent, spec.text or "", spec.font)
        if button then
            button._vfnVariant = spec.variant or "default"
            -- Theme:Register handled by Layout post-build via WidgetType.skin
            -- (spec section 5); no explicit Apply needed.
        end
        return button
    end,
    dispatch = { fields = { "text", "enabled", "active" }, push = dispatchButton },
    skin = "Button",
    -- Close variant SetScripts OnEnter/OnLeave internally; controllers attach
    -- OnClick to every button. Declaring input.events makes the script surface
    -- visible to the validator and triggers the mandatory-destroy check.
    input = { events = { OnClick = true, OnEnter = true, OnLeave = true } },
    destroy = destroyWidget,
    -- Icon-only variants (options.close / options.atlas) render an atlas
    -- instead of text -- no `font` role required. Text-button paths (no
    -- atlas/close) do need a font. The validator (Layout) consults this
    -- predicate instead of peeking at spec.options itself; spec section 5.
    requiresFont = function(spec)
        local opts = spec and spec.options
        if not opts then return true end
        return not (opts.close == true or opts.atlas ~= nil)
    end,
})

function VFN.UI:EditBox(parent, opts, font)
    opts = opts or {}

    -- Local helper: attach a placeholder FontString to an editbox-shaped
    -- widget. The placeholder shows when the editbox is empty and not
    -- focused; it hides on focus or as soon as the user types. WoW EditBox
    -- has no native placeholder, so we paint one as an OVERLAY FontString.
    local function attachPlaceholder(host, edit, text, placeFn)
        if not (text and text ~= "" and host.CreateFontString) then return end
        local ph = host:CreateFontString(nil, "OVERLAY")
        applyFontToFS(ph, font)
        if ph.SetText then ph:SetText(text) end
        if ph.SetWordWrap then ph:SetWordWrap(true) end
        if ph.SetJustifyH then ph:SetJustifyH("LEFT") end
        if ph.SetJustifyV then ph:SetJustifyV("TOP") end
        VFN.Theme:Register(ph, "TextDim")
        placeFn(ph)
        local function refresh()
            local hasText = (edit.GetText and edit:GetText() or "") ~= ""
            local focused = edit.HasFocus and edit:HasFocus()
            if hasText or focused then ph:Hide() else ph:Show() end
        end
        if edit.HookScript then
            edit:HookScript("OnEditFocusGained", refresh)
            edit:HookScript("OnEditFocusLost",   refresh)
            edit:HookScript("OnTextChanged",     refresh)
        end
        -- Stash a direct refresh handle so callers can force a re-evaluation
        -- after programmatic SetText. OnTextChanged-via-SetText is not
        -- guaranteed across all WoW client versions, so this is the belt
        -- to the hook's suspenders.
        host._vfnPlaceholderRefresh = refresh
        edit._vfnPlaceholderRefresh = refresh
        refresh()
    end

    -- SINGLE-LINE: bare EditBox with backdrop. Standard WoW pattern -- one
    -- frame, native cursor behaviour, no template wrappers. Chrome comes
    -- from the EditBox theme skinner (canvas bg + visible border).
    if opts.multiline ~= true then
        local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
        if box.SetAutoFocus then box:SetAutoFocus(false) end
        if box.SetMultiLine then box:SetMultiLine(false) end
        if box.SetMaxLetters then box:SetMaxLetters(opts.maxLetters or 4000) end
        if box.SetJustifyH then box:SetJustifyH(opts.justifyH or "LEFT") end
        if box.SetJustifyV then box:SetJustifyV(opts.justifyV or "MIDDLE") end
        if box.EnableMouse then box:EnableMouse(true) end
        box:SetScript("OnEnterPressed", function(eb) eb:ClearFocus() end)
        box:SetScript("OnEscapePressed", function(eb) eb:ClearFocus() end)
        -- Theme:Register owned by Layout via WidgetType.skin = "EditBox".
        applyFontRole(box, font)
        if box.SetTextInsets then box:SetTextInsets(8, 8, 4, 4) end
        attachPlaceholder(box, box, opts.placeholder, function(ph)
            ph:SetPoint("LEFT", 8, 0)
            ph:SetPoint("RIGHT", -8, 0)
        end)
        return box
    end

    -- MULTI-LINE: ScrollFrame container + auto-growing inner EditBox. Without
    -- the wrapper a multi-line WoW EditBox auto-grows to fit content (no
    -- fixed size, no scroll). InputScrollFrameTemplate is Blizzard's standard
    -- multi-line text input -- ScrollFrame clips to a fixed size, EditBox
    -- inside grows, scrollbar appears when content overflows.
    --
    -- This template is multi-line-only by design. Don't try to use it for
    -- single-line inputs (cursor positioning misbehaves; see git history).
    local container = CreateFrame("ScrollFrame", nil, parent, "InputScrollFrameTemplate")
    container.multiLine = true  -- marker for tests + introspection
    if container.CharCount then container.CharCount:Hide() end
    -- Theme:Register owned by Layout via WidgetType.skin = "EditBox".
    if container.EnableMouse then container:EnableMouse(true) end

    local edit = container.EditBox
    if not edit then return container end  -- mock environments without the template

    container:SetScript("OnMouseDown", function() edit:SetFocus() end)

    -- Force EditBox width on container resize. The template's OnSizeChanged
    -- updates the ScrollChild but the EditBox anchored inside doesn't always
    -- propagate -- without this, the EditBox stays at its template default
    -- width (~100px) and any non-space char wraps to the next line. Use
    -- HookScript so we don't overwrite the template's own handler.
    container:HookScript("OnSizeChanged", function(sf, w)
        if sf.EditBox and sf.EditBox.SetWidth then
            sf.EditBox:SetWidth(math.max(1, (w or 0) - 24))  -- room for scrollbar
        end
    end)

    edit:SetAutoFocus(false)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(opts.maxLetters or 4000)
    edit:SetJustifyH(opts.justifyH or "LEFT")
    edit:SetJustifyV(opts.justifyV or "TOP")
    applyFontRole(edit, font)

    attachPlaceholder(container, edit, opts.placeholder, function(ph)
        ph:SetPoint("TOPLEFT", 8, -8)
        ph:SetPoint("RIGHT", -24, 0)  -- leave room for the scrollbar
    end)

    -- Forward SetText / GetText / SetScript / SetFocus / ClearFocus to the
    -- inner editbox so controllers can treat the container as the editbox.
    -- (Layout:Apply still calls SetSize on the container, which is what we
    -- want -- the visible viewport stays the spec'd size.)
    function container:SetText(text)
        edit:SetText(text or "")
        -- Reset scroll so loading a short value after a long one doesn't leave
        -- the viewport scrolled past the new content (would render as a
        -- mostly-empty box with stale top region from the previous content).
        if container.SetVerticalScroll then container:SetVerticalScroll(0) end
    end
    function container:GetText() return edit:GetText() end
    function container:SetFocus() edit:SetFocus() end
    function container:ClearFocus() edit:ClearFocus() end
    function container:HasFocus() return edit:HasFocus() end
    -- Forward script handlers to the inner edit (where text events fire).
    -- OnSizeChanged stays on the container so the engine's SetSize works.
    local TEXT_EVENTS = {
        OnTextChanged = true, OnEditFocusGained = true, OnEditFocusLost = true,
        OnEnterPressed = true, OnEscapePressed = true, OnTabPressed = true,
        OnTextSet = true, OnChar = true,
    }
    local containerSetScript = container.SetScript
    function container:SetScript(name, fn)
        if TEXT_EVENTS[name] then return edit:SetScript(name, fn) end
        return containerSetScript(self, name, fn)
    end

    return container
end

VFN.WidgetTypes:Register("editbox", {
    build = function(parent, spec)
        return VFN.UI:EditBox(parent, spec.options or {}, spec.font)
    end,
    dispatch = { fields = { "text" }, push = dispatchEditbox },
    skin = "EditBox",
    -- VFN.UI:EditBox SetScripts OnEnterPressed/OnEscapePressed/OnTextChanged
    -- and OnMouseDown (container focus delegate). Declaring input.events
    -- engages the validator's mandatory-destroy check.
    input = {
        events = {
            OnEnterPressed = true, OnEscapePressed = true, OnTextChanged = true,
            OnEditFocusGained = true, OnEditFocusLost = true, OnMouseDown = true,
        },
    },
    destroy = destroyWidget,
})

function VFN.UI:ScrollBox(parent, opts)
    opts = opts or {}

    local host = CreateFrame("Frame", nil, parent)
    local scrollBox = CreateFrame("Frame", nil, host, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", 0, 0)
    scrollBox:SetPoint("BOTTOMRIGHT", -20, 0)

    local scrollBar = CreateFrame("EventFrame", nil, host, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 2, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 2, 0)

    local view = CreateScrollBoxListLinearView(0, 0, 0, 0, opts.spacing or 0)
    if type(opts.rowHeight) == "function" then
        view:SetElementExtentCalculator(opts.rowHeight)
    elseif type(opts.rowHeight) == "number" then
        view:SetElementExtent(opts.rowHeight)
    else
        error("ScrollBox: opts.rowHeight is required (number or function)", 2)
    end

    view:SetElementInitializer(opts.template or "Button", function(row, elementData)
        if row.SetWidth and scrollBox.GetWidth then
            row:SetWidth(scrollBox:GetWidth())
        end
        if opts.initializer then
            opts.initializer(row, elementData)
        end
    end)

    if opts.resetter then
        view:SetElementResetter(opts.resetter)
    end

    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    local provider = CreateDataProvider()
    SetDataProvider(scrollBox, provider)

    host.scrollBox = scrollBox
    host.scrollBar = scrollBar
    host.view = view
    host.provider = provider

    function host:SetItems(items, retainScroll)
        local newProvider = CreateDataProvider(items or {})
        SetDataProvider(self.scrollBox, newProvider, retainScroll and ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition or nil)
        self.provider = newProvider
        return newProvider
    end

    function host:Refresh(items)
        if self.provider and self.provider.Flush and self.provider.InsertTable then
            self.provider:Flush()
            if items and #items > 0 then
                self.provider:InsertTable(items)
            end
            return self.provider
        end

        return self:SetItems(items, true)
    end

    -- Custom ApplyLayout: position + force the inner WowScrollBoxList to
    -- recompute its viewport. WowScrollBoxList listens to OnSizeChanged on
    -- its own frame, but the host -> scrollBox propagation can lag a frame;
    -- calling :Update() (or re-applying the data provider) here guarantees
    -- the visible row range expands to fill the new rect immediately.
    function host:ApplyLayout(region)
        if not region then return end
        if self.ClearAllPoints then self:ClearAllPoints() end
        if self.SetPoint then self:SetPoint("TOPLEFT", region.x, -region.y) end
        if self.SetSize then self:SetSize(region.width, region.height) end
        local sb = self.scrollBox
        if sb then
            if sb.Update then sb:Update()
            elseif sb.FullUpdate then sb:FullUpdate() end
        end
    end

    return host
end

VFN.WidgetTypes:Register("scrollbox", {
    build = function(parent, spec)
        local opts = spec.options or {}
        local rowKind = opts.rowKind

        -- Single source for row definition: VFN.Rows registry contains the
        -- full shape (font, height) + behaviour (factory OR deriveText/onClick)
        -- in one entry. Validator guarantees the entry exists when rowKind set.
        local row, def
        if rowKind then
            def = VFN.Rows and VFN.Rows:Get(rowKind) or nil
            if not def then
                error(("scrollbox factory: row %q not registered in VFN.Rows"):format(rowKind), 2)
            end
            if type(def.factory) == "function" then
                row = def.factory(def)
            else
                local rowFactory = VFN.ControllerHelpers.UI.MakeRowFactory({
                    height     = def.height,
                    deriveText = def.deriveText,
                    onClick    = def.onClick,
                })
                row = rowFactory(def.font)
            end
        end

        local scrollOpts = {
            rowHeight = def and def.height,
            spacing   = opts.spacing or 0,
            template  = opts.template or "Button",
        }
        if not scrollOpts.rowHeight then
            error("scrollbox factory: rowHeight required (set via row entry in VFN.Rows or spec.options.rowHeight)", 2)
        end
        if row then
            scrollOpts.initializer = row.Configure
            scrollOpts.resetter    = row.Reset
        end

        local box = VFN.UI:ScrollBox(parent, scrollOpts)
        if box then
            box.rowKind = rowKind
            -- Theme:Register owned by Layout via WidgetType.skin = "Frame".
        end
        return box
    end,
    dispatch = { fields = { "items" }, push = dispatchScrollbox },
    skin = "Frame",
})

-- ===== StatCard: big-number + dim-label stat tile ========================
-- Used in the library curator's COORDS / MAP / STATUS row at the top of
-- the right column. Two FontStrings stacked: big number/value on top
-- (heading font, text.primary), dim label below (small, text.dim).
-- SetValue(s) / SetLabel(s) for runtime updates.
function VFN.UI:StatCard(parent, value, label)
    if not (parent and CreateFrame) then return nil end
    local frame = CreateFrame("Frame", nil, parent)
    if frame.CreateFontString then
        local v = frame:CreateFontString(nil, "OVERLAY")
        if v.SetPoint then
            v:SetPoint("TOPLEFT", 8, -6)
            v:SetPoint("TOPRIGHT", -8, -6)
        end
        if v.SetJustifyH then v:SetJustifyH("LEFT") end
        applyFontRole(v, "heading")
        if v.SetText then v:SetText(tostring(value or "")) end
        VFN.Theme:Register(v, "Text")
        frame._vfnStatValue = v

        local l = frame:CreateFontString(nil, "OVERLAY")
        if l.SetPoint then
            l:SetPoint("BOTTOMLEFT", 8, 4)
            l:SetPoint("BOTTOMRIGHT", -8, 4)
        end
        if l.SetJustifyH then l:SetJustifyH("LEFT") end
        applyFontRole(l, "caption")
        if l.SetText then l:SetText(tostring(label or "")) end
        VFN.Theme:Register(l, "TextDim")
        frame._vfnStatLabel = l
    end
    function frame:SetValue(s)
        if self._vfnStatValue and self._vfnStatValue.SetText then
            self._vfnStatValue:SetText(tostring(s or ""))
        end
    end
    function frame:SetLabel(s)
        if self._vfnStatLabel and self._vfnStatLabel.SetText then
            self._vfnStatLabel:SetText(tostring(s or ""))
        end
    end
    return frame
end

VFN.WidgetTypes:Register("statCard", {
    build = function(parent, spec)
        local opts = spec.options or {}
        return VFN.UI:StatCard(parent, opts.value or spec.value, opts.label or spec.label)
    end,
    dispatch = { fields = { "value", "label" }, push = dispatchStatCard },
})

-- ===== Status chip: small text pill painted by Theme.Skinners.StatusChip ==
-- A chip's "status" is data-driven semantic category (ready/blocked/has_note
-- /source/default) -- not a design-time color family like a button's variant.
-- The Skinner reads `_vfnChipBg` / `_vfnChipText` references stashed on the
-- frame plus the current status to pick the tint.
function VFN.UI:Chip(parent, text, status)
    if not (parent and CreateFrame) then return nil end
    local frame = CreateFrame("Frame", nil, parent)
    if frame.SetHeight then frame:SetHeight(16) end

    if frame.CreateTexture then
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        if bg.SetAllPoints then bg:SetAllPoints() end
        frame._vfnChipBg = bg
    end
    if frame.CreateFontString then
        local fs = frame:CreateFontString(nil, "OVERLAY")
        if fs.SetPoint then
            fs:SetPoint("LEFT", 6, 0)
            fs:SetPoint("RIGHT", -6, 0)
        end
        if fs.SetJustifyH then fs:SetJustifyH("CENTER") end
        applyFontRole(fs, "caption")
        if fs.SetText then fs:SetText(text or "") end
        frame._vfnChipText = fs
    end

    function frame:SetStatus(s) VFN.Theme:SetState(self, { status = s }) end
    function frame:SetState(updates) VFN.Theme:SetState(self, updates) end
    function frame:SetChipText(t) if self._vfnChipText then self._vfnChipText:SetText(t or "") end end
    -- Theme:Register is the caller's responsibility. Layout's buildKind
    -- handles it for spec-built chips via WidgetType.skin. Direct callers
    -- (Controller_Library row factories) use VFN.Theme:RegisterKind(chip,
    -- "chip", { status = ... }) so the role string lives in ONE place.
    return frame
end

VFN.WidgetTypes:Register("chip", {
    build = function(parent, spec)
        local opts = spec.options or {}
        return VFN.UI:Chip(parent, spec.text or opts.text or "", opts.status)
    end,
    dispatch = { fields = { "text", "status" }, push = dispatchChip },
    skin = "StatusChip",
    initialState = function(spec)
        local opts = spec and spec.options or {}
        return { status = (opts and opts.status) or (spec and spec.status) or "ready" }
    end,
})

-- ===== CopyDialog: shared multi-line "Ctrl+C to copy" popup =================
--
-- WoW's StaticPopup edit field is single-line, so any time we need the user
-- to copy multi-line text (waypoint lists, source paste, exports, etc) we
-- pop this dialog instead. Lazy-singleton: first call builds the frame and
-- caches it on VFN.UI; subsequent calls just populate + show.
--
-- Usage:
--     VFN.UI:CopyDialog():Show("Copy coordinates", text)

function VFN.UI:CopyDialog()
    if self._copyDialog then return self._copyDialog end
    if not (CreateFrame and UIParent) then return nil end

    local f = CreateFrame("Frame", "VFN_CopyDialog", UIParent, "BackdropTemplate")
    f:SetSize(420, 280)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    VFN.Theme:Register(f, "Frame")

    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetPoint("TOPLEFT", 12, -10)
    applyFontRole(title, "heading")
    VFN.Theme:Register(title, "Text")
    f._title = title

    local hint = f:CreateFontString(nil, "OVERLAY")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    applyFontRole(hint, "small")
    hint:SetText("Ctrl+C to copy. Esc to close.")
    VFN.Theme:Register(hint, "TextDim")

    local sf = CreateFrame("ScrollFrame", nil, f, "InputScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 12, -50)
    sf:SetPoint("BOTTOMRIGHT", -12, 40)
    if sf.CharCount then sf.CharCount:Hide() end
    VFN.Theme:Register(sf, "EditBox")
    local edit = sf.EditBox
    if edit then
        edit:SetAutoFocus(false)
        edit:SetMultiLine(true)
        edit:SetMaxLetters(0)
        edit:SetJustifyH("LEFT")
        applyFontRole(edit, "body")
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
    end
    sf:HookScript("OnSizeChanged", function(self_, w)
        if self_.EditBox and self_.EditBox.SetWidth then
            self_.EditBox:SetWidth(math.max(1, (w or 0) - 24))
        end
    end)
    f._edit = edit

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(80, 22); close:SetPoint("BOTTOMRIGHT", -12, 10)
    close:SetText("Close")
    close:SetScript("OnClick", function() f:Hide() end)

    local rawShow = f.Show
    function f:Open(titleText, bodyText)
        if self._title and self._title.SetText then self._title:SetText(titleText or "Copy") end
        if self._edit then
            self._edit:SetText(bodyText or "")
            if self._edit.HighlightText then self._edit:HighlightText() end
            if self._edit.SetFocus then self._edit:SetFocus() end
        end
        rawShow(self)
    end

    self._copyDialog = f
    return f
end

-- ===== Row chrome / badge / map pin constructors ==========================
-- These build the textures + child frames for a scrollbox row (or map pin)
-- ONCE and cache them on the row. They DO NOT read theme colours -- that's
-- the Theme.Skinners.RowChrome / .RowBadge layer. Idempotent: re-calling on
-- an already-built row returns the cached struct.

local ROW_TEX_PATH = "Interface\\AddOns\\VamoosesFieldNotes\\textures\\vfn_row_tex"
local WHITE_TEX    = "Interface\\Buttons\\WHITE8x8"

function VFN.UI:EnsureRowChrome(row)
    if not row then return nil end
    if row._vfnChrome then return row._vfnChrome end
    if not row.CreateTexture then return nil end

    local watercolor = row:CreateTexture(nil, "ARTWORK", nil, 0)
    if watercolor.SetAllPoints then watercolor:SetAllPoints() end
    if watercolor.SetTexture then watercolor:SetTexture(ROW_TEX_PATH) end

    local gloss = row:CreateTexture(nil, "ARTWORK", nil, 1)
    if gloss.SetAllPoints then gloss:SetAllPoints() end
    if gloss.SetTexture then gloss:SetTexture(WHITE_TEX) end
    if gloss.SetBlendMode then gloss:SetBlendMode("ADD") end
    if gloss.SetGradient and _G.CreateColor then
        gloss:SetGradient("VERTICAL", _G.CreateColor(1, 1, 1, 0), _G.CreateColor(1, 1, 1, 0.15))
    end

    local selectedBg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    if selectedBg.SetAllPoints then selectedBg:SetAllPoints() end
    if selectedBg.SetTexture then selectedBg:SetTexture(WHITE_TEX) end
    if selectedBg.Hide then selectedBg:Hide() end

    local accentBar = row:CreateTexture(nil, "OVERLAY")
    if accentBar.SetPoint then
        accentBar:SetPoint("TOPLEFT", 0, 0)
        accentBar:SetPoint("BOTTOMLEFT", 0, 0)
    end
    if accentBar.SetWidth then accentBar:SetWidth(2) end
    if accentBar.SetTexture then accentBar:SetTexture(WHITE_TEX) end
    if accentBar.Hide then accentBar:Hide() end

    -- Mouseover overlay -- always-on white 6%. Lives outside Theme since
    -- it's a fixed semantic (no scheme override planned).
    local hover = row:CreateTexture(nil, "HIGHLIGHT")
    if hover.SetAllPoints then hover:SetAllPoints() end
    if hover.SetTexture then hover:SetTexture(WHITE_TEX) end
    if hover.SetVertexColor then hover:SetVertexColor(1, 1, 1, 0.06) end

    row._vfnChrome = {
        watercolor = watercolor,
        gloss      = gloss,
        selectedBg = selectedBg,
        accentBar  = accentBar,
        hover      = hover,
    }
    return row._vfnChrome
end

function VFN.UI:EnsureRowBadge(row)
    if not row then return nil end
    if row._vfnBadge then return row._vfnBadge end
    if not (row.CreateTexture and row.CreateFontString) then return nil end

    local frame = row:CreateTexture(nil, "OVERLAY")
    if frame.SetPoint then frame:SetPoint("TOPRIGHT", -8, -7) end
    if frame.SetSize then frame:SetSize(28, 16) end
    if frame.SetTexture then frame:SetTexture(WHITE_TEX) end
    if frame.Hide then frame:Hide() end

    local fs = row:CreateFontString(nil, "OVERLAY")
    if fs.SetPoint then fs:SetPoint("CENTER", frame, "CENTER", 0, 0) end
    applyFontRole(fs, "small")
    if fs.SetJustifyH then fs:SetJustifyH("CENTER") end
    if fs.Hide then fs:Hide() end

    row._vfnBadge = { frame = frame, text = fs }
    return row._vfnBadge
end

-- MapPin: pin frame for the drawer map. Pure construction -- positions, sizes,
-- and pin colours are driven by DrawerController at refresh time (via the
-- Theme tokens it reads). Lives in Components so controllers don't construct
-- frames -- they call this factory and decorate the returned frame.
function VFN.UI:MapPin(parent)
    if not (parent and _G.CreateFrame) then return nil end
    local pin = _G.CreateFrame("Frame", nil, parent)
    if pin.EnableMouse then pin:EnableMouse(true) end

    if pin.CreateTexture then
        local dot = pin:CreateTexture(nil, "OVERLAY")
        if dot.SetPoint then dot:SetPoint("CENTER") end
        if dot.SetAtlas then dot:SetAtlas("WhiteCircle-RaidBlips") end
        pin._dot = dot
    end

    -- Index label centred on the dot. FRIZQT__ ascender/descender asymmetry
    -- shifts digits slightly low -- Y offset +1 compensates so "2" looks as
    -- centred as "1".
    if pin.CreateFontString then
        local label = pin:CreateFontString(nil, "OVERLAY")
        if label.SetPoint then label:SetPoint("CENTER", 0, 1) end
        if label.SetJustifyH then label:SetJustifyH("CENTER") end
        if label.SetJustifyV then label:SetJustifyV("MIDDLE") end
        pin._label = label
    end

    return pin
end

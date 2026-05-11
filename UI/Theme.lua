-- VFN.Theme
--
-- The chrome contract. Owns everything visual: colors, fonts, metrics.
-- Components hand widgets to Theme; Theme paints them. Surfaces never call
-- SetBackdropColor / SetTextColor / SetFont directly -- always through Theme.
--
-- Three accessor APIs:
--   :GetColor(path)         "button.primary.bg.hover" -> {r,g,b,a}
--   :GetFont(role)          "heading" -> Font object (real FontObject)
--   :GetMetric(path)        "spacing.md" -> number
--
-- Two skin APIs:
--   :Register(widget, kind)              legacy shim (Frame|Button|Text|TextDim)
--   :RegisterVariant(widget, kind, var)  apply a variant overlay (danger/primary)
--
-- Future re-skin: swap VFN_SchemeConstants.ColorblindSafe for another scheme,
-- call Theme:Reload(), every registered widget repaints. No surface code change.

VFN = VFN or {}
VFN.Theme = {
    registry = setmetatable({}, { __mode = "k" }),
    fontObjects = {},  -- role name -> FontObject (created at Initialize)
}

VFN.Theme.BACKDROP_FLAT = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 },
}

-- Path resolution helpers ---------------------------------------------------

local function resolvePath(root, path)
    if not root or type(path) ~= "string" then return nil end
    local cursor = root
    for segment in path:gmatch("[^.]+") do
        if type(cursor) ~= "table" then return nil end
        cursor = cursor[segment]
    end
    return cursor
end

local function applyColor(setter, frame, color)
    if frame and setter and color then
        setter(frame, color.r, color.g, color.b, color.a or 1)
    end
end

local function setBackdrop(frame, backdrop)
    if frame and frame.SetBackdrop then frame:SetBackdrop(backdrop) end
end

local function setBackdropColor(frame, color)
    if frame and frame.SetBackdropColor and color then
        frame:SetBackdropColor(color.r, color.g, color.b, color.a or 1)
    end
end

local function setBackdropBorderColor(frame, color)
    if frame and frame.SetBackdropBorderColor and color then
        frame:SetBackdropBorderColor(color.r, color.g, color.b, color.a or 1)
    end
end

local function setTextColor(text, color)
    if text and text.SetTextColor and color then
        text:SetTextColor(color.r, color.g, color.b, color.a or 1)
    end
end

-- Suppress unused-local warnings for helpers we expose to Skinners.
local _ = applyColor

-- Public API ----------------------------------------------------------------

function VFN.Theme:Initialize()
    self.currentScheme = (VFN.Constants and VFN.Constants.THEME)
        or (VFN_SchemeConstants and VFN_SchemeConstants.ColorblindSafe)
        or {}
    self:BuildFontObjects()
end

function VFN.Theme:GetScheme()
    if not self.currentScheme then self:Initialize() end
    return self.currentScheme
end

-- LoadScheme: swap `currentScheme` to a different scheme block and repaint
-- every registered widget. Drives palette swaps -- the entire architecture
-- (Skinners reading via :GetColor, state cached weak-keyed per widget) is
-- built around this single call working.
--
-- Pass either a scheme name (looked up in VFN_SchemeConstants) or a scheme
-- table directly. Rebuilds FontObjects too so font role swaps propagate.
function VFN.Theme:LoadScheme(schemeOrName)
    local scheme
    if type(schemeOrName) == "string" then
        scheme = VFN_SchemeConstants and VFN_SchemeConstants[schemeOrName]
        if not scheme then
            error(("Theme:LoadScheme: scheme %q not found in VFN_SchemeConstants"):format(schemeOrName), 2)
        end
    elseif type(schemeOrName) == "table" then
        scheme = schemeOrName
    else
        error("Theme:LoadScheme: expected scheme name (string) or scheme table", 2)
    end
    self.currentScheme = scheme
    self:BuildFontObjects()
    self:ApplyAll()
end

-- :GetColor("text") returns legacy top-level color (back-compat).
-- :GetColor("button.primary.bg.hover") returns nested V2 path.
function VFN.Theme:GetColor(path)
    local scheme = self:GetScheme()
    if not scheme then return nil end
    return resolvePath(scheme, path)
end

-- :GetMetric("spacing.md") -> number
function VFN.Theme:GetMetric(path)
    local scheme = self:GetScheme()
    return resolvePath(scheme and scheme.metrics, path)
end

-- :GetFont(role) -> Font object (real FontObject created at Initialize).
-- Falls back to the matching Blizzard FontObject if our object isn't built
-- yet (e.g. mocks in tests where CreateFont is absent).
function VFN.Theme:GetFont(role)
    if not role then return nil end
    local fo = self.fontObjects and self.fontObjects[role]
    if fo then return fo end
    -- Test / no-CreateFont fallback: return the role descriptor; callers can
    -- inspect file/size/flags directly.
    local scheme = self:GetScheme()
    return scheme and scheme.fonts and scheme.fonts[role] or nil
end

-- BuildFontObjects creates real FontObjects from scheme.fonts so widgets
-- can reference them via SetFontObject(VFN.Theme:GetFont("heading")).
-- Re-callable; second call repoints existing FontObjects to new font files.
function VFN.Theme:BuildFontObjects()
    local scheme = self:GetScheme()
    local fonts = scheme and scheme.fonts or {}
    local createFont = _G and _G.CreateFont or nil
    if not createFont then return end

    for role, desc in pairs(fonts) do
        local globalName = "VFN_Font_" .. role
        local fo = self.fontObjects[role]
        if not fo then
            fo = _G[globalName] or createFont(globalName)
            self.fontObjects[role] = fo
        end
        if not desc or not desc.file or not desc.size then
            error(("Theme:BuildFontObjects: scheme font role %q must declare {file, size, flags}"):format(role), 2)
        end
        if fo and fo.SetFont then
            fo:SetFont(desc.file, desc.size, desc.flags or "")
        end
    end
end

-- Skinners: per-widgetType paint functions. Read from scheme paths.
-- Adding a new widget kind means registering a new Skinner here, NOT mutating
-- callers. New surfaces never write SetBackdropColor etc. directly.
VFN.Theme.Skinners = {
    Frame = function(frame, _scheme)
        setBackdrop(frame, VFN.Theme.BACKDROP_FLAT)
        setBackdropColor(frame, VFN.Theme:GetColor("surface.panel"))
        setBackdropBorderColor(frame, VFN.Theme:GetColor("border.default"))
    end,

    -- Button: combines design-time variant (immutable, stashed on the widget
    -- at construction) with runtime state.active (mutable, from bindings via
    -- SetActive / SetState). One paint pass reads both. There is no separate
    -- variant-overlay step for buttons anymore -- the Theme.Variants table
    -- still exists for other widget kinds, but Button bakes its variant once.
    --
    -- State shape: { active = bool }. Active wins paint -- the button reads
    -- as the "selected/on" treatment regardless of variant family. Variants:
    --   primary / danger / tertiary / ghost / default (default when missing)
    Button = function(button, _scheme, state)
        local variant = button._vfnVariant or "default"
        local active  = state and state.active and true or false
        setBackdrop(button, VFN.Theme.BACKDROP_FLAT)
        if active then
            local accent = VFN.Theme:GetColor("semantic.accent")
            local inverse = VFN.Theme:GetColor("text.inverse")
            setBackdropColor(button, { r = accent.r, g = accent.g, b = accent.b, a = 0.85 })
            setBackdropBorderColor(button, accent)
            setTextColor(button, inverse)
        else
            local bg     = VFN.Theme:GetColor("button." .. variant .. ".bg.normal")     or VFN.Theme:GetColor("button.default.bg.normal")
            local border = VFN.Theme:GetColor("button." .. variant .. ".border.normal") or VFN.Theme:GetColor("button.default.border.normal")
            local text   = VFN.Theme:GetColor("button." .. variant .. ".text.normal")   or VFN.Theme:GetColor("button.default.text.normal")
            setBackdropColor(button, bg)
            setBackdropBorderColor(button, border)
            setTextColor(button, text)
        end
    end,

    Text = function(text, _scheme)
        setTextColor(text, VFN.Theme:GetColor("text.primary"))
    end,

    TextDim = function(text, _scheme)
        setTextColor(text, VFN.Theme:GetColor("text.dim"))
    end,

    -- Status text: accent-coloured FontString. For things like the capture
    -- form's status row -- distinguished from normal body text so the eye
    -- catches it immediately.
    TextStatus = function(text, _scheme)
        setTextColor(text, VFN.Theme:GetColor("semantic.accent"))
    end,

    -- New V2 skinners --------------------------------------------------------

    -- RowChrome: per-row painterly bg + selected-state accents. Construction
    -- of the underlying textures lives in VFN.UI:EnsureRowChrome (Components).
    -- State (selected bool) is passed via Theme:Register's 3rd arg and cached
    -- so Theme:Reload repaints every registered row with the correct state.
    RowChrome = function(row, _scheme, state)
        if not (row and row._vfnChrome) then return end
        local chrome = row._vfnChrome
        local selected = state and state.selected and true or false

        local accent = VFN.Theme:GetColor("semantic.accent")
        local sunken = VFN.Theme:GetColor("surface.sunken")

        if chrome.watercolor and chrome.watercolor.SetVertexColor then
            if selected then
                chrome.watercolor:SetVertexColor(accent.r * 0.55, accent.g * 0.55, accent.b * 0.55, 1)
            else
                -- Unselected rows tint to surface.sunken so they read as
                -- recessed wells in the panel body rather than floating
                -- gray cards. Selected rows get the accent treatment for
                -- contrast (recessed dim -> lit-up bright).
                chrome.watercolor:SetVertexColor(sunken.r, sunken.g, sunken.b, 1)
            end
        end

        if chrome.selectedBg then
            if selected and chrome.selectedBg.SetVertexColor then
                chrome.selectedBg:SetVertexColor(accent.r, accent.g, accent.b, 0.15)
                if chrome.selectedBg.Show then chrome.selectedBg:Show() end
            elseif chrome.selectedBg.Hide then
                chrome.selectedBg:Hide()
            end
        end

        if chrome.accentBar then
            if selected and chrome.accentBar.SetVertexColor then
                chrome.accentBar:SetVertexColor(accent.r, accent.g, accent.b, 1)
                if chrome.accentBar.Show then chrome.accentBar:Show() end
            elseif chrome.accentBar.Hide then
                chrome.accentBar:Hide()
            end
        end
    end,

    -- BadgePill: unified badge skinner for count + selection chips.
    -- State (3rd arg): { text = string|nil, variant = "count"|"selection",
    --                    selected = bool? }
    -- Construction lives at VFN.UI:EnsureRowBadge / inline (coord rows);
    -- the host widget exposes `_vfnBadge = { frame, text }` either way.
    -- Variants:
    --   "count"     : amber semantic.warning fill + text (static).
    --   "selection" : square chip; accent <-> panel_header by state.selected,
    --                 text inverse <-> primary.
    BadgePill = function(host, _scheme, state)
        if not (host and host._vfnBadge) then return end
        local badge = host._vfnBadge
        local text = state and state.text
        if not text or text == "" then
            if badge.frame and badge.frame.Hide then badge.frame:Hide() end
            if badge.text  and badge.text.Hide  then badge.text:Hide()  end
            return
        end
        if badge.frame and badge.frame.Show then badge.frame:Show() end
        if badge.text  and badge.text.Show  then badge.text:Show()  end
        if badge.text and badge.text.SetText then badge.text:SetText(tostring(text)) end

        local variant = (state and state.variant) or "count"
        if variant == "selection" then
            local selected = state and state.selected
            local bgC = selected and VFN.Theme:GetColor("semantic.accent")
                or VFN.Theme:GetColor("surface.panel_header")
            local txC = selected and VFN.Theme:GetColor("text.inverse")
                or VFN.Theme:GetColor("text.primary")
            if badge.frame and badge.frame.SetColorTexture then
                badge.frame:SetColorTexture(bgC.r, bgC.g, bgC.b, bgC.a or 1)
            end
            if badge.text and badge.text.SetTextColor then
                badge.text:SetTextColor(txC.r, txC.g, txC.b, 1)
            end
        else
            -- "count" -- amber static.
            local c = VFN.Theme:GetColor("semantic.warning")
            if badge.frame and badge.frame.SetVertexColor then
                badge.frame:SetVertexColor(c.r, c.g, c.b, 0.16)
            end
            if badge.text and badge.text.SetTextColor then
                badge.text:SetTextColor(c.r, c.g, c.b, 1)
            end
        end
    end,

    -- AccentBg: small tinted-fill at low alpha (status banner body, etc).
    -- Reads semantic.accent and paints the texture's color at 8.5% alpha.
    AccentBg = function(tex, _scheme)
        if not (tex and tex.SetColorTexture) then return end
        local accent = VFN.Theme:GetColor("semantic.accent")
        tex:SetColorTexture(accent.r, accent.g, accent.b, 0.085)
    end,

    -- AccentBar: solid accent fill (status banner left bar).
    AccentBar = function(tex, _scheme)
        if not (tex and tex.SetColorTexture) then return end
        local accent = VFN.Theme:GetColor("semantic.accent")
        tex:SetColorTexture(accent.r, accent.g, accent.b, 1)
    end,

    -- Divider: 1px hairline, border.subtle colour.
    Divider = function(tex, _scheme)
        if not (tex and tex.SetColorTexture) then return end
        local c = VFN.Theme:GetColor("border.subtle")
        tex:SetColorTexture(c.r, c.g, c.b, c.a or 0.55)
    end,

    -- SectionBgTint: paint a tinted bg for chromed sections. State: { token }.
    -- Theme:Reload picks up palette swaps automatically via the cached state.
    SectionBgTint = function(tex, _scheme, state)
        if not (tex and tex.SetColorTexture) then return end
        local token = (state and state.token) or "surface.panel"
        local c = VFN.Theme:GetColor(token)
        tex:SetColorTexture(c.r, c.g, c.b, c.a or 1)
    end,

    -- StatusChip: small text-chip painted by status-chip semantic category.
    -- Used by library card rows + coord preview rows. State: { status }.
    --   "ready"    -> success (teal)   tint + text
    --   "blocked"  -> error (magenta)  tint + text
    --   "has_note" -> warning (amber)  tint + text
    --   "source"   -> accent (blue)    tint + text
    --   "default"  -> text.dim         tint + text (low contrast, library marker)
    -- The chip widget is a Frame with { bg = texture, text = fontstring }
    -- on it; this skinner reads status and paints both.
    StatusChip = function(chip, _scheme, state)
        if not (chip and chip._vfnChipBg and chip._vfnChipText) then return end
        -- Back-compat: accept either status (new name) or variant (legacy)
        -- so unmigrated call sites keep working while we sweep them.
        local status = (state and (state.status or state.variant)) or "ready"
        local roleColor = {
            ready    = VFN.Theme:GetColor("semantic.success"),
            blocked  = VFN.Theme:GetColor("semantic.error"),
            has_note = VFN.Theme:GetColor("semantic.warning"),
            source   = VFN.Theme:GetColor("semantic.accent"),
            default  = VFN.Theme:GetColor("text.dim"),
        }
        local c = roleColor[status] or roleColor.ready
        if chip._vfnChipBg.SetColorTexture then
            chip._vfnChipBg:SetColorTexture(c.r, c.g, c.b, 0.18)
        end
        if chip._vfnChipText.SetTextColor then
            chip._vfnChipText:SetTextColor(c.r, c.g, c.b, 1)
        end
    end,

    -- PinDot: map-pin texture in the drawer + world map pins. State:
    -- { selected }. Selected = warning amber, default = accent blue.
    PinDot = function(dot, _scheme, state)
        if not (dot and dot.SetVertexColor) then return end
        local fill
        if state and state.selected then
            fill = VFN.Theme:GetColor("semantic.warning")
        else
            fill = VFN.Theme:GetColor("pin.default.fill")
        end
        dot:SetVertexColor(fill.r, fill.g, fill.b, 1)
    end,

    PanelHeader = function(frame, _scheme)
        -- SetBackdrop on these chrome frames has been unreliable -- WoW's
        -- older Backdrop API gets stale between reskins and the bg sometimes
        -- never paints. Direct CreateTexture is the universally-reliable
        -- alternative: one bg texture filling the slot rect, one 1px bottom
        -- divider line that visually separates header from panel body.
        local bg = frame._vfnHeaderBg
        if not bg and frame.CreateTexture then
            bg = frame:CreateTexture(nil, "BACKGROUND")
            if bg.SetAllPoints then bg:SetAllPoints() end
            frame._vfnHeaderBg = bg
        end
        local bgColor = VFN.Theme:GetColor("surface.panel_header")
        if bg and bg.SetColorTexture and bgColor then
            bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 1)
        end

        local edge = frame._vfnHeaderEdge
        if not edge and frame.CreateTexture then
            edge = frame:CreateTexture(nil, "BORDER")
            if edge.SetPoint then
                edge:SetPoint("BOTTOMLEFT", 0, 0)
                edge:SetPoint("BOTTOMRIGHT", 0, 0)
            end
            if edge.SetHeight then edge:SetHeight(1) end
            frame._vfnHeaderEdge = edge
        end
        local edgeColor = VFN.Theme:GetColor("border.subtle")
        if edge and edge.SetColorTexture and edgeColor then
            edge:SetColorTexture(edgeColor.r, edgeColor.g, edgeColor.b, edgeColor.a or 0.55)
        end
    end,

    -- Inputs need clear visual contrast against the panel so the box outline
    -- reads as a distinct workspace, not an invisible smear. Uses canvas
    -- (darker than panel, more obvious) + full-strength border.
    EditBox = function(frame, _scheme)
        setBackdrop(frame, VFN.Theme.BACKDROP_FLAT)
        setBackdropColor(frame, VFN.Theme:GetColor("surface.canvas"))
        setBackdropBorderColor(frame, VFN.Theme:GetColor("border.default"))
        setTextColor(frame, VFN.Theme:GetColor("text.primary"))
    end,

    PanelFooter = function(frame, _scheme)
        setBackdrop(frame, VFN.Theme.BACKDROP_FLAT)
        setBackdropColor(frame, VFN.Theme:GetColor("surface.panel_footer"))
        setBackdropBorderColor(frame, VFN.Theme:GetColor("border.subtle"))
    end,

    Sunken = function(frame, _scheme)
        setBackdrop(frame, VFN.Theme.BACKDROP_FLAT)
        setBackdropColor(frame, VFN.Theme:GetColor("surface.sunken"))
        setBackdropBorderColor(frame, VFN.Theme:GetColor("border.subtle"))
    end,

    TextHeading = function(text, _scheme)
        setTextColor(text, VFN.Theme:GetColor("text.heading"))
    end,

    TextSubheading = function(text, _scheme)
        setTextColor(text, VFN.Theme:GetColor("text.subheading"))
    end,

    TextMuted = function(text, _scheme)
        setTextColor(text, VFN.Theme:GetColor("text.muted"))
    end,

    TextNumeric = function(text, _scheme)
        setTextColor(text, VFN.Theme:GetColor("text.numeric"))
    end,
}

-- Register a widget with a Skinner. Optional `state` argument is a small
-- table of per-widget paint state (selected flag, variant name, token
-- override, etc) that the Skinner reads instead of stashing on `_vfn*`
-- fields directly. State is cached weak-keyed so Theme:Reload can re-run
-- the Skinner with the same state -- callers don't need to re-register.
-- Passing state again on the same widget replaces the cached state.
function VFN.Theme:Register(widget, widgetType, state)
    if not widget or not widgetType then return false end
    self.registry[widget] = widgetType
    if state ~= nil then
        self.states = self.states or setmetatable({}, { __mode = "k" })
        self.states[widget] = state
    end
    local skin = self.Skinners and self.Skinners[widgetType]
    if skin then
        skin(widget, self:GetScheme(), self.states and self.states[widget])
    end
    return true
end

function VFN.Theme:Apply(widget, widgetType)
    if not widget then return false end
    local resolvedType = widgetType or self.registry[widget]
    local skin = self.Skinners and self.Skinners[resolvedType]
    if not skin then return false end
    skin(widget, self:GetScheme(), self.states and self.states[widget])
    return true
end

function VFN.Theme:ApplyAll()
    for widget, widgetType in pairs(self.registry) do
        self:Apply(widget, widgetType)
    end
end

-- Merge updates into the widget's stored state and re-apply the skinner.
-- Universal mutation point for runtime state -- replaces ad-hoc patterns
-- like Theme:Register(..., { variant = "X" }) (which works but reads as
-- registering rather than mutating) and ad-hoc setters that re-register
-- the whole state object. Used by widget:SetState() in factories.
--
-- The state arg merges field-by-field, so SetState({ active = true })
-- doesn't wipe selected=true previously set on the same widget. Use nil
-- to clear a field: SetState({ active = nil }) -- BUT Lua tables don't
-- distinguish absent-from-table from key=nil, so passing nil values has
-- no effect; explicitly set to false instead.
function VFN.Theme:SetState(widget, updates)
    if not widget then return end
    local widgetType = self.registry[widget]
    if not widgetType then return end
    self.states = self.states or setmetatable({}, { __mode = "k" })
    local current = self.states[widget] or {}
    if type(updates) == "table" then
        for k, v in pairs(updates) do current[k] = v end
    end
    self.states[widget] = current
    self:Apply(widget, widgetType)
end

-- Variant skinning: apply a base skin then a variant overlay. Variants live
-- under VFN.Theme.Variants keyed by name. Each variant function receives
-- (widget, scheme).
VFN.Theme.Variants = {
    primary = function(widget, _scheme)
        local bg = VFN.Theme:GetColor("button.primary.bg.normal")
        local border = VFN.Theme:GetColor("button.primary.border.normal")
        local text = VFN.Theme:GetColor("button.primary.text.normal")
        if bg and widget.SetBackdropColor then widget:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 1) end
        if border and widget.SetBackdropBorderColor then widget:SetBackdropBorderColor(border.r, border.g, border.b, border.a or 1) end
        if text and widget.SetTextColor then widget:SetTextColor(text.r, text.g, text.b, text.a or 1) end
    end,
    danger = function(widget, _scheme)
        local bg = VFN.Theme:GetColor("button.danger.bg.normal")
        local border = VFN.Theme:GetColor("button.danger.border.normal")
        local text = VFN.Theme:GetColor("button.danger.text.normal")
        if bg and widget.SetBackdropColor then widget:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 1) end
        if border and widget.SetBackdropBorderColor then widget:SetBackdropBorderColor(border.r, border.g, border.b, border.a or 1) end
        if text and widget.SetTextColor then widget:SetTextColor(text.r, text.g, text.b, text.a or 1) end
    end,
    ghost = function(widget, _scheme)
        local bg = VFN.Theme:GetColor("button.ghost.bg.normal")
        local border = VFN.Theme:GetColor("button.ghost.border.normal")
        local text = VFN.Theme:GetColor("button.ghost.text.normal")
        if bg and widget.SetBackdropColor then widget:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 1) end
        if border and widget.SetBackdropBorderColor then widget:SetBackdropBorderColor(border.r, border.g, border.b, border.a or 1) end
        if text and widget.SetTextColor then widget:SetTextColor(text.r, text.g, text.b, text.a or 1) end
    end,
    -- Atlas-rendered variant: replaces backdrop with Blizzard's tertiary
    -- button atlas family. Clears backdrop so the atlas paints clean.
    tertiary = function(widget, _scheme)
        local v = VFN.Theme:GetScheme().button and VFN.Theme:GetScheme().button.tertiary
        if not (v and v.atlas) then return end
        local atlas = v.atlas
        if widget.SetNormalAtlas    then widget:SetNormalAtlas(atlas.normal) end
        if widget.SetHighlightAtlas then widget:SetHighlightAtlas(atlas.hover) end
        if widget.SetPushedAtlas    then widget:SetPushedAtlas(atlas.pressed) end
        if widget.SetDisabledAtlas  then widget:SetDisabledAtlas(atlas.disabled) end
        -- Clear backdrop so atlas shows clean (would otherwise stack underneath).
        if widget.SetBackdrop then widget:SetBackdrop(nil) end
        local text = v.text and v.text.normal
        if text and widget.SetTextColor then widget:SetTextColor(text.r, text.g, text.b, text.a or 1) end
    end,
}

function VFN.Theme:RegisterVariant(widget, widgetType, variant)
    if not widget or not variant then return false end
    self:Register(widget, widgetType)
    local apply = self.Variants and self.Variants[variant]
    if apply then apply(widget, self:GetVariant(variant)) end
    widget.themeVariant = variant
    return true
end

-- Resolve a scheme by variant name. Currently one scheme; reserved entry
-- point for compact density / alt palettes.
function VFN.Theme:GetVariant(_name)
    return self:GetScheme()
end

-- :Reload() -- swap scheme, rebuild FontObjects, repaint every registered
-- widget. Future re-skin entry point.
function VFN.Theme:Reload()
    self:Initialize()
    self:ApplyAll()
end

-- VFN Scheme Constants
--
-- 100% skinner palette. Every category a Theme might need to paint, organised
-- by purpose so a re-skin only swaps tokens. No legacy aliases -- this is the
-- first build, the structure is the contract.
--
-- ColorblindSafe is the only ship scheme. Lineage:
--   - Originally copied from VPP (VamoosesPetPatrol)
--   - Adopted SELECTIVELY from HDG: panel_header (separate header shade),
--     OUTLINE font flag, atlas references for the few housing widgets we use
--   - Extended for VFN: per-state per-variant button maps, pin states,
--     region colors, named font roles, design metrics
--
-- Colorblind discipline:
--   - Based on David Math Logic colorblind-safe palette.
--   - Distinguishable across deuteranopia, protanopia, tritanopia.
--   - Four reliable colour channels: blue / teal / amber / pink.
--   - No pure red, no pure green.
--   - WCAG AA+ contrast on all text/bg pairs.
--   - State distinctions use luminance + glow, not just hue.
--
-- Access through Theme APIs:
--   VFN.Theme:GetColor("button.primary.bg.hover")
--   VFN.Theme:GetFont("heading")
--   VFN.Theme:GetMetric("spacing.md")

local function rgba(r, g, b, a) return { r = r, g = g, b = b, a = a or 1 } end
local function withAlpha(c, a) return { r = c.r, g = c.g, b = c.b, a = a } end

-- Base palette (shared values used across categories) ----------------------

local C = {
    -- Surfaces -- colorblind-safe slate cartographer console palette.
    -- Mockup tokens (vfn-colorblind-ui-mockup.html) drive these values.
    -- Tone ramp (darkest -> lightest): sunken < canvas < panel_soft < panel
    --                                < panel_footer < panel_header < raised
    -- "sunken" and "raised" name the extremes; intermediate tokens cluster
    -- around `panel`. Each step ~6-12 RGB units so the eye reads them as
    -- distinct surfaces under WoW's dark-room rendering.
    sunken          = rgba(0.047, 0.067, 0.086, 1.00), -- #0C1116 inset (inputs / source pane)
    bg              = rgba(0.063, 0.078, 0.094, 0.95), -- #101418 canvas (outer page bg)
    panel_soft      = rgba(0.082, 0.114, 0.153, 1.00), -- #151D27 card chrome (recessed, between panel and sunken)
    panel           = rgba(0.094, 0.125, 0.161, 1.00), -- #182029 panel body
    panel_footer    = rgba(0.118, 0.161, 0.204, 1.00), -- #1E2934 soft footer
    panel_header    = rgba(0.133, 0.173, 0.212, 1.00), -- #222C36 header (mockup value)
    raised          = rgba(0.196, 0.255, 0.302, 1.00), -- #32414D raised buttons / row chrome base (one step above header)

    -- Borders
    border          = rgba(0.275, 0.318, 0.365, 1.00), -- #46515D divider

    -- Typography (WCAG AA+ on canvas)
    text            = rgba(0.945, 0.961, 0.976, 1.00), -- #F1F5F9 primary
    text_header     = rgba(1.000, 1.000, 1.000, 1.00), -- pure white headings
    text_label      = rgba(0.667, 0.714, 0.765, 1.00), -- #AAB6C3 muted (labels)
    text_dim        = rgba(0.494, 0.545, 0.600, 1.00), -- #7E8B99 dim (captions / meta)
    text_disabled   = rgba(0.373, 0.416, 0.459, 1.00), -- #5F6A75 disabled
    text_inverse    = rgba(1.000, 1.000, 1.000, 1.00), -- #FFFFFF on accent fills

    -- Buttons (default neutral) -- raised slate, lighter than panel.
    button_normal   = rgba(0.196, 0.255, 0.302, 1.00), -- #32414D raised
    button_hover    = rgba(0.235, 0.298, 0.349, 1.00), -- #3C4C59 slightly lighter
    button_active   = rgba(0.094, 0.125, 0.161, 1.00), -- #182029 panel
    button_disabled = rgba(0.196, 0.255, 0.302, 0.40), -- raised @ 40%

    -- Semantic (colorblind-safe four channels)
    accent          = rgba(0.306, 0.639, 0.945, 1.00), -- #4EA3F1 Blue
    accent_brighter = rgba(0.576, 0.773, 0.992, 1.00), -- #93C5FD blue-ring (selected emphasis)
    accent_darker   = rgba(0.114, 0.310, 0.459, 1.00), -- #1D4F75 blue-deep (selected bg / primary button)
    accent_hover    = rgba(0.141, 0.243, 0.333, 1.00), -- #243E55 row-selected hover

    success         = rgba(0.000, 0.659, 0.588, 1.00), -- #00A896 Teal
    warning         = rgba(0.949, 0.788, 0.298, 1.00), -- #F2C94C Amber
    error           = rgba(0.847, 0.298, 0.545, 1.00), -- #D84C8B Magenta
    error_deep      = rgba(0.561, 0.176, 0.349, 1.00), -- #8F2D59 magenta-deep (danger button fill)
}

-- Font files used by the scheme. Centralised so a font swap touches one
-- place. FRIZQT for headings + body (matches Blizzard chrome). ARIALN for
-- compact small/caption.
local FONT_HEADING = "Fonts\\FRIZQT__.TTF"
local FONT_BODY    = "Fonts\\FRIZQT__.TTF"
local FONT_SMALL   = "Fonts\\ARIALN.TTF"

VFN_SchemeConstants = {

    ColorblindSafe = {

        -- ===== Surfaces (backgrounds) =====
        surface = {
            canvas       = C.bg,
            panel        = C.panel,
            panel_header = C.panel_header,
            panel_footer = C.panel_footer,
            panel_soft   = C.panel_soft,    -- card chrome bg (#151D27 -- recessed, darker than panel)
            raised       = C.raised,        -- raised chrome bg (#32414D -- lighter than panel_header; buttons / row chrome base)
            sunken       = C.sunken,
            hover        = withAlpha(C.accent, 0.12),  -- accent tint, low alpha
            selected     = withAlpha(C.accent, 0.18),  -- accent tint, stronger
            overlay      = withAlpha(C.bg, 0.60),      -- modal scrim
            divider      = withAlpha(C.border, 0.55),
        },

        -- ===== Borders =====
        border = {
            default      = C.border,
            subtle       = withAlpha(C.border, 0.55),
            strong       = C.text_dim,
            focus        = C.accent,
            selected     = withAlpha(C.accent, 0.95),
        },

        -- ===== Text colors =====
        text = {
            primary      = C.text,
            heading      = C.text_header,
            subheading   = C.text_dim,
            muted        = C.text_label,
            dim          = C.text_dim,
            disabled     = C.text_disabled,
            link         = C.accent,
            link_hover   = C.accent_brighter,
            inverse      = C.text_inverse,
            numeric      = C.warning,    -- amber for tabular coords
        },

        -- ===== Semantic colours (the four colorblind-safe channels) =====
        semantic = {
            accent       = C.accent,
            success      = C.success,
            warning      = C.warning,
            error        = C.error,
        },

        -- ===== Button per-state per-variant =====
        button = {
            default = {
                bg     = { normal = C.button_normal, hover = C.button_hover, active = C.button_active, disabled = C.button_disabled },
                text   = { normal = C.text, hover = C.text_inverse, disabled = C.text_disabled },
                border = { normal = C.border, hover = withAlpha(C.accent, 0.50), focus = C.accent },
            },
            primary = {
                bg     = { normal = C.accent, hover = C.accent_brighter, active = C.accent_darker, disabled = withAlpha(C.accent, 0.40) },
                text   = { normal = C.text_inverse, hover = C.text_inverse, disabled = C.text_disabled },
                border = { normal = C.accent, hover = C.accent_brighter, focus = C.text_inverse },
            },
            danger = {
                -- Magenta-deep fill + brighter magenta border. Visually
                -- distinct from primary (blue) and isolated by hue so
                -- destructive clicks read as "this is the dangerous one"
                -- without relying on position alone.
                bg     = { normal = C.error_deep, hover = C.error, active = C.error_deep, disabled = withAlpha(C.error_deep, 0.40) },
                text   = { normal = C.text_inverse, hover = C.text_inverse, disabled = C.text_disabled },
                border = { normal = C.error, hover = C.accent_brighter, focus = C.text_inverse },
            },
            ghost = {
                bg     = { normal = rgba(0, 0, 0, 0), hover = withAlpha(C.accent, 0.10), active = withAlpha(C.accent, 0.18), disabled = rgba(0, 0, 0, 0) },
                text   = { normal = C.text, hover = C.accent, disabled = C.text_disabled },
                border = { normal = rgba(0, 0, 0, 0), hover = withAlpha(C.accent, 0.45), focus = C.accent },
            },
            -- Atlas-rendered variant: Blizzard's "tertiary" button family.
            -- Sits with the dark theme better than red UIPanelButtonTemplate.
            -- The variant skinner reads `atlas` and SetNormalAtlas / etc. --
            -- backdrop is cleared so the atlas paints clean.
            tertiary = {
                atlas = {
                    normal   = "common-button-tertiary-normal",
                    hover    = "common-button-tertiary-hover",
                    pressed  = "common-button-tertiary-pressed",
                    disabled = "common-button-tertiary-disabled",
                },
                text = {
                    normal   = C.text,
                    hover    = C.text_header,
                    disabled = C.text_disabled,
                },
            },
        },

        -- ===== Chip per-variant =====
        chip = {
            default = { bg = C.panel_header, border = withAlpha(C.border, 0.65), text = C.text_dim, icon = C.text_dim },
            new     = { bg = withAlpha(C.warning, 0.18), border = C.warning, text = C.warning, icon = C.warning },
            atlas   = { bg = C.panel_header, border = withAlpha(C.border, 0.65), text = C.text_label, icon = C.text_label },
        },

        -- ===== Map drawer pin states =====
        -- Distinguished by FILL + GLOW + DESATURATION (not just hue) so
        -- monochrome viewers can still tell selected from done.
        pin = {
            default  = { fill = C.accent, border = C.text_inverse },
            selected = { fill = C.accent, border = C.text_inverse, glow = withAlpha(C.accent, 0.65) },
            applied  = { fill = C.success, border = C.text_inverse, glow = withAlpha(C.success, 0.55) },
            done     = { fill = C.text_dim, border = C.border },
            invalid  = { fill = C.error, border = C.text_inverse },
        },

        -- ===== Region overlays (the colored ovals in map mockup) =====
        region = {
            a = withAlpha(C.success, 0.22),  -- teal
            b = withAlpha(C.accent, 0.20),   -- blue
            c = withAlpha(C.warning, 0.12),  -- amber, paler
        },

        -- ===== Fonts (named roles -- components reference role, not Blizzard FontObject names) =====
        fonts = {
            heading      = { file = FONT_HEADING, size = 16, flags = "" },
            subheading   = { file = FONT_HEADING, size = 13, flags = "" },
            body         = { file = FONT_BODY,    size = 12, flags = "" },
            body_strong  = { file = FONT_BODY,    size = 12, flags = "OUTLINE" },
            small        = { file = FONT_SMALL,   size = 11, flags = "" },
            caption      = { file = FONT_SMALL,   size = 10, flags = "" },
            button       = { file = FONT_BODY,    size = 12, flags = "" },
            numeric      = { file = FONT_BODY,    size = 12, flags = "" },
        },

        -- ===== Design metrics (beyond colour) =====
        -- The spacing scale covers every value that actually appears in
        -- LayoutConfig padding/gap fields. New panels MUST use a token name
        -- ("md", "lg", etc) -- raw pixels are reserved for one-off geometry
        -- (widget height, fixed widths). A future "compact mode" toggle
        -- swaps this whole block and the layout engine re-resolves.
        metrics = {
            radius    = { sm = 2, md = 4, lg = 6 },
            spacing   = {
                xs   = 2,    -- micro insets (rarely used)
                sm   = 4,    -- tight list gap, captureButton spacing
                md   = 6,    -- header element gap
                lg   = 8,    -- DOMINANT: panel-body padding, row gaps
                xl   = 10,   -- panel-header H-padding, window cell gap
                xxl  = 12,   -- window outer padding, card chrome padding
                huge = 20,   -- (reserved; not currently used)
            },
            elevation = { panel = 1, popup = 2, modal = 3 },
        },

        -- ===== Atlas references (housing widgets we use) =====
        atlas = {
            checkmark   = "common-icon-checkmark",
            close       = "communities-icon-redx",
            housingDeed = "housing-map-deed",
        },
    },
}

-- VFN Scheme Constants
--
-- The composer takes a flat palette (~30 colors) and assembles the full
-- nested scheme (surface / border / text / semantic / button / chip /
-- pin / region / fonts / metrics / atlas). Each theme is therefore just
-- a palette table -- one source of truth for the colors, shared shape
-- for everything else.
--
-- Themes:
--   ColorblindSafe   - WCAG AA, deuteranopia/protanopia/tritanopia safe
--   Mocha            - Catppuccin Mocha (the dark default)
--   TokyonightNight  - Tokyonight Night (the original)
--   RosePineMain     - Rose Pine main (the dark default)
--   GruvboxDarkHard  - Gruvbox dark + hard contrast
--
-- Add a theme: provide a palette table + BuildScheme(palette).
-- Switch at runtime: VFN.Theme:LoadScheme("Mocha").
--
-- Access via Theme APIs:
--   VFN.Theme:GetColor("button.primary.bg.hover")
--   VFN.Theme:GetFont("heading")
--   VFN.Theme:GetMetric("spacing.md")

local function rgba(r, g, b, a) return { r = r, g = g, b = b, a = a or 1 } end
local function withAlpha(c, a) return { r = c.r, g = c.g, b = c.b, a = a } end

-- Parse "#RRGGBB" (or "#RRGGBBAA") to an rgba table. Lets palette tables
-- mirror the hex strings published by upstream themes -- easier to verify
-- against the source.
local function hex(s, a)
    local r = tonumber(s:sub(2, 3), 16) / 255
    local g = tonumber(s:sub(4, 5), 16) / 255
    local b = tonumber(s:sub(6, 7), 16) / 255
    if a == nil and #s >= 9 then
        a = tonumber(s:sub(8, 9), 16) / 255
    end
    return { r = r, g = g, b = b, a = a or 1 }
end

-- Fonts are shared across all themes. Per-theme fonts overrides are possible
-- (palette.fonts) but rarely worth it -- WoW's font set is thin enough that
-- the same trio works for every palette.
local FONT_HEADING = "Fonts\\FRIZQT__.TTF"
local FONT_BODY    = "Fonts\\FRIZQT__.TTF"
local FONT_SMALL   = "Fonts\\ARIALN.TTF"

local DEFAULT_FONTS = {
    heading      = { file = FONT_HEADING, size = 16, flags = "" },
    subheading   = { file = FONT_HEADING, size = 13, flags = "" },
    body         = { file = FONT_BODY,    size = 12, flags = "" },
    body_strong  = { file = FONT_BODY,    size = 12, flags = "OUTLINE" },
    small        = { file = FONT_SMALL,   size = 11, flags = "" },
    caption      = { file = FONT_SMALL,   size = 10, flags = "" },
    button       = { file = FONT_BODY,    size = 12, flags = "" },
    numeric      = { file = FONT_BODY,    size = 12, flags = "" },
}

local DEFAULT_METRICS = {
    radius    = { sm = 2, md = 4, lg = 6 },
    spacing   = {
        xs = 2, sm = 4, md = 6, lg = 8, xl = 10, xxl = 12, huge = 20,
    },
    elevation = { panel = 1, popup = 2, modal = 3 },
}

local DEFAULT_ATLAS = {
    checkmark   = "common-icon-checkmark",
    close       = "communities-icon-redx",
    housingDeed = "housing-map-deed",
}

-- BuildScheme: take a flat palette (~30 named colors) + return a nested
-- scheme matching what Theme.Skinners + LayoutConfig + selectors expect.
-- The shape of the OUTPUT is the contract; the shape of the INPUT is
-- "give me values for every name in PALETTE_KEYS." Missing values error.
local PALETTE_KEYS = {
    -- Surfaces (darkest -> lightest, 7 steps)
    "sunken", "bg", "panel_soft", "panel", "panel_footer", "panel_header", "raised",
    -- Border
    "border",
    -- Text
    "text", "text_header", "text_label", "text_dim", "text_disabled", "text_inverse",
    -- Buttons (default neutral chrome)
    "button_normal", "button_hover", "button_active", "button_disabled",
    -- Semantic (4 channels: accent / success / warning / error)
    "accent", "accent_brighter", "accent_darker", "accent_hover",
    "success", "warning", "error", "error_deep",
}

local function BuildScheme(palette)
    -- Validate every key is present. Missing one is a bug; loud error
    -- beats silent nil during paint.
    for _, key in ipairs(PALETTE_KEYS) do
        if palette[key] == nil then
            error(("BuildScheme: palette missing required key %q"):format(key), 2)
        end
    end
    local C = palette

    return {
        surface = {
            canvas       = C.bg,
            panel        = C.panel,
            panel_header = C.panel_header,
            panel_footer = C.panel_footer,
            panel_soft   = C.panel_soft,
            raised       = C.raised,
            sunken       = C.sunken,
            hover        = withAlpha(C.accent, 0.12),
            selected     = withAlpha(C.accent, 0.18),
            overlay      = withAlpha(C.bg,     0.60),
            divider      = withAlpha(C.border, 0.55),
        },

        border = {
            default      = C.border,
            subtle       = withAlpha(C.border, 0.55),
            strong       = C.text_dim,
            focus        = C.accent,
            selected     = withAlpha(C.accent, 0.95),
        },

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
            numeric      = C.warning,
        },

        semantic = {
            accent       = C.accent,
            success      = C.success,
            warning      = C.warning,
            error        = C.error,
        },

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
                bg     = { normal = C.error_deep, hover = C.error, active = C.error_deep, disabled = withAlpha(C.error_deep, 0.40) },
                text   = { normal = C.text_inverse, hover = C.text_inverse, disabled = C.text_disabled },
                border = { normal = C.error, hover = C.accent_brighter, focus = C.text_inverse },
            },
            ghost = {
                bg     = { normal = rgba(0, 0, 0, 0), hover = withAlpha(C.accent, 0.10), active = withAlpha(C.accent, 0.18), disabled = rgba(0, 0, 0, 0) },
                text   = { normal = C.text, hover = C.accent, disabled = C.text_disabled },
                border = { normal = rgba(0, 0, 0, 0), hover = withAlpha(C.accent, 0.45), focus = C.accent },
            },
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

        chip = {
            default = { bg = C.panel_header, border = withAlpha(C.border, 0.65), text = C.text_dim, icon = C.text_dim },
            new     = { bg = withAlpha(C.warning, 0.18), border = C.warning, text = C.warning, icon = C.warning },
            atlas   = { bg = C.panel_header, border = withAlpha(C.border, 0.65), text = C.text_label, icon = C.text_label },
        },

        pin = {
            default  = { fill = C.accent, border = C.text_inverse },
            selected = { fill = C.accent, border = C.text_inverse, glow = withAlpha(C.accent, 0.65) },
            applied  = { fill = C.success, border = C.text_inverse, glow = withAlpha(C.success, 0.55) },
            done     = { fill = C.text_dim, border = C.border },
            invalid  = { fill = C.error, border = C.text_inverse },
        },

        region = {
            a = withAlpha(C.success, 0.22),
            b = withAlpha(C.accent,  0.20),
            c = withAlpha(C.warning, 0.12),
        },

        fonts   = palette.fonts   or DEFAULT_FONTS,
        metrics = palette.metrics or DEFAULT_METRICS,
        atlas   = palette.atlas   or DEFAULT_ATLAS,
    }
end

-- ===== Palettes =============================================================
--
-- Each palette is ~30 keys (the contract in PALETTE_KEYS above). Hex strings
-- mirror the upstream theme sources for direct comparison.
--
-- Mapping conventions:
--   sunken          -> deepest inset shade (crust / bg_dark / base / bg0_h)
--   bg              -> canvas / outer page (base / bg / base / bg0)
--   panel_soft      -> recessed card chrome (one step darker than panel)
--   panel           -> panel body (surface0 / bg_highlight / surface / bg1)
--   panel_footer    -> footer accent (one step lighter than panel)
--   panel_header    -> header accent
--   raised          -> button base (one step lighter than header)
--   accent          -> primary brand color (blue family in most themes)
--   accent_brighter -> hover state for accent
--   accent_darker   -> pressed / selected state
--   success         -> green channel
--   warning         -> yellow/amber channel
--   error           -> red/magenta channel
--   error_deep      -> darker red for danger button fills

local Palettes = {}

-- ----- ColorblindSafe (original VFN palette) -------------------------------
Palettes.ColorblindSafe = {
    sunken          = rgba(0.047, 0.067, 0.086, 1.00),
    bg              = rgba(0.063, 0.078, 0.094, 0.95),
    panel_soft      = rgba(0.082, 0.114, 0.153, 1.00),
    panel           = rgba(0.094, 0.125, 0.161, 1.00),
    panel_footer    = rgba(0.118, 0.161, 0.204, 1.00),
    panel_header    = rgba(0.133, 0.173, 0.212, 1.00),
    raised          = rgba(0.196, 0.255, 0.302, 1.00),
    border          = rgba(0.275, 0.318, 0.365, 1.00),
    text            = rgba(0.945, 0.961, 0.976, 1.00),
    text_header     = rgba(1.000, 1.000, 1.000, 1.00),
    text_label      = rgba(0.667, 0.714, 0.765, 1.00),
    text_dim        = rgba(0.494, 0.545, 0.600, 1.00),
    text_disabled   = rgba(0.373, 0.416, 0.459, 1.00),
    text_inverse    = rgba(1.000, 1.000, 1.000, 1.00),
    button_normal   = rgba(0.196, 0.255, 0.302, 1.00),
    button_hover    = rgba(0.235, 0.298, 0.349, 1.00),
    button_active   = rgba(0.094, 0.125, 0.161, 1.00),
    button_disabled = rgba(0.196, 0.255, 0.302, 0.40),
    accent          = rgba(0.306, 0.639, 0.945, 1.00),  -- #4EA3F1
    accent_brighter = rgba(0.576, 0.773, 0.992, 1.00),  -- #93C5FD
    accent_darker   = rgba(0.114, 0.310, 0.459, 1.00),  -- #1D4F75
    accent_hover    = rgba(0.141, 0.243, 0.333, 1.00),  -- #243E55
    success         = rgba(0.000, 0.659, 0.588, 1.00),  -- #00A896 teal
    warning         = rgba(0.949, 0.788, 0.298, 1.00),  -- #F2C94C amber
    error           = rgba(0.847, 0.298, 0.545, 1.00),  -- #D84C8B magenta
    error_deep      = rgba(0.561, 0.176, 0.349, 1.00),  -- #8F2D59 magenta-deep
}

-- ----- Catppuccin Mocha -----------------------------------------------------
-- Source: https://github.com/catppuccin/catppuccin#-palette
Palettes.Mocha = {
    sunken          = hex("#11111b"),                   -- crust
    bg              = hex("#1e1e2e", 0.95),             -- base
    panel_soft      = hex("#181825"),                   -- mantle
    panel           = hex("#313244"),                   -- surface0
    panel_footer    = hex("#45475a"),                   -- surface1
    panel_header    = hex("#45475a"),                   -- surface1 (header reuses)
    raised          = hex("#585b70"),                   -- surface2
    border          = hex("#6c7086"),                   -- overlay0
    text            = hex("#cdd6f4"),                   -- text
    text_header     = hex("#cdd6f4"),                   -- text
    text_label      = hex("#bac2de"),                   -- subtext1
    text_dim        = hex("#a6adc8"),                   -- subtext0
    text_disabled   = hex("#6c7086"),                   -- overlay0
    text_inverse    = hex("#1e1e2e"),                   -- base
    button_normal   = hex("#45475a"),                   -- surface1
    button_hover    = hex("#585b70"),                   -- surface2
    button_active   = hex("#313244"),                   -- surface0
    button_disabled = hex("#45475a", 0.40),
    accent          = hex("#89b4fa"),                   -- blue
    accent_brighter = hex("#b4befe"),                   -- lavender
    accent_darker   = hex("#1e66f5"),                   -- darker blue
    accent_hover    = hex("#3a5070"),
    success         = hex("#a6e3a1"),                   -- green
    warning         = hex("#f9e2af"),                   -- yellow
    error           = hex("#f38ba8"),                   -- red
    error_deep      = hex("#9d4060"),                   -- darker red
}

-- ----- Tokyonight Night ----------------------------------------------------
-- Source: https://github.com/folke/tokyonight.nvim (extras/lua/tokyonight_night.lua)
Palettes.TokyonightNight = {
    sunken          = hex("#16161e"),                   -- bg_dark
    bg              = hex("#1a1b26", 0.95),             -- bg
    panel_soft      = hex("#1f2335"),                   -- bg + slight lift
    panel           = hex("#292e42"),                   -- bg_highlight
    panel_footer    = hex("#3b4261"),                   -- fg_gutter
    panel_header    = hex("#414868"),                   -- terminal_black
    raised          = hex("#545c7e"),                   -- dark3
    border          = hex("#3b4261"),                   -- fg_gutter
    text            = hex("#c0caf5"),                   -- fg
    text_header     = hex("#c0caf5"),                   -- fg
    text_label      = hex("#a9b1d6"),                   -- fg_dark
    text_dim        = hex("#737aa2"),                   -- dark5
    text_disabled   = hex("#565f89"),                   -- comment
    text_inverse    = hex("#1a1b26"),                   -- bg
    button_normal   = hex("#3b4261"),                   -- fg_gutter
    button_hover    = hex("#414868"),                   -- terminal_black
    button_active   = hex("#292e42"),                   -- bg_highlight
    button_disabled = hex("#3b4261", 0.40),
    accent          = hex("#7aa2f7"),                   -- blue
    accent_brighter = hex("#89ddff"),                   -- blue5
    accent_darker   = hex("#3d59a1"),                   -- blue0
    accent_hover    = hex("#394b70"),                   -- blue7
    success         = hex("#9ece6a"),                   -- green
    warning         = hex("#e0af68"),                   -- yellow
    error           = hex("#f7768e"),                   -- red
    error_deep      = hex("#db4b4b"),                   -- red1
}

-- ----- Rose Pine Main -------------------------------------------------------
-- Source: https://github.com/rose-pine/rose-pine-theme (palette/main.md)
Palettes.RosePineMain = {
    sunken          = hex("#191724"),                   -- base (darkest)
    bg              = hex("#1f1d2e", 0.95),             -- surface
    panel_soft      = hex("#21202e"),                   -- highlightLow
    panel           = hex("#26233a"),                   -- overlay
    panel_footer    = hex("#403d52"),                   -- highlightMed
    panel_header    = hex("#403d52"),                   -- highlightMed
    raised          = hex("#524f67"),                   -- highlightHigh
    border          = hex("#6e6a86"),                   -- muted
    text            = hex("#e0def4"),                   -- text
    text_header     = hex("#e0def4"),                   -- text
    text_label      = hex("#908caa"),                   -- subtle
    text_dim        = hex("#6e6a86"),                   -- muted
    text_disabled   = hex("#524f67"),                   -- highlightHigh
    text_inverse    = hex("#191724"),                   -- base
    button_normal   = hex("#403d52"),                   -- highlightMed
    button_hover    = hex("#524f67"),                   -- highlightHigh
    button_active   = hex("#26233a"),                   -- overlay
    button_disabled = hex("#403d52", 0.40),
    accent          = hex("#9ccfd8"),                   -- foam
    accent_brighter = hex("#ebbcba"),                   -- rose
    accent_darker   = hex("#31748f"),                   -- pine
    accent_hover    = hex("#403d52"),                   -- highlightMed
    success         = hex("#31748f"),                   -- pine
    warning         = hex("#f6c177"),                   -- gold
    error           = hex("#eb6f92"),                   -- love
    error_deep      = hex("#9d4d68"),                   -- darker love
}

-- ----- Gruvbox Dark Hard ----------------------------------------------------
-- Source: https://github.com/morhetz/gruvbox (gruvbox-palettes.png)
Palettes.GruvboxDarkHard = {
    sunken          = hex("#1d2021"),                   -- bg0_h (hard contrast)
    bg              = hex("#282828", 0.95),             -- bg0
    panel_soft      = hex("#32302f"),                   -- bg0_s
    panel           = hex("#3c3836"),                   -- bg1
    panel_footer    = hex("#504945"),                   -- bg2
    panel_header    = hex("#504945"),                   -- bg2
    raised          = hex("#665c54"),                   -- bg3
    border          = hex("#7c6f64"),                   -- bg4
    text            = hex("#ebdbb2"),                   -- fg1
    text_header     = hex("#fbf1c7"),                   -- fg0 (brightest)
    text_label      = hex("#d5c4a1"),                   -- fg2
    text_dim        = hex("#bdae93"),                   -- fg3
    text_disabled   = hex("#a89984"),                   -- fg4
    text_inverse    = hex("#282828"),                   -- bg0
    button_normal   = hex("#504945"),                   -- bg2
    button_hover    = hex("#665c54"),                   -- bg3
    button_active   = hex("#3c3836"),                   -- bg1
    button_disabled = hex("#504945", 0.40),
    accent          = hex("#83a598"),                   -- blue (gruvbox's "cool" tone)
    accent_brighter = hex("#8ec07c"),                   -- aqua
    accent_darker   = hex("#458588"),                   -- blue neutral
    accent_hover    = hex("#4a5d56"),
    success         = hex("#b8bb26"),                   -- green
    warning         = hex("#fabd2f"),                   -- yellow
    error           = hex("#fb4934"),                   -- red bright
    error_deep      = hex("#cc241d"),                   -- red neutral
}

-- ===== Scheme exports =======================================================
-- Each scheme is the BuildScheme output for its palette. Theme:LoadScheme
-- takes the name; the global table here is the registry.

VFN_SchemeConstants = {
    ColorblindSafe  = BuildScheme(Palettes.ColorblindSafe),
    Mocha           = BuildScheme(Palettes.Mocha),
    TokyonightNight = BuildScheme(Palettes.TokyonightNight),
    RosePineMain    = BuildScheme(Palettes.RosePineMain),
    GruvboxDarkHard = BuildScheme(Palettes.GruvboxDarkHard),
}

-- Display metadata for the slash command + future Config tab dropdown.
-- Order = order of presentation. ColorblindSafe stays first as the
-- accessibility default.
VFN_SchemeConstants._meta = {
    order = { "ColorblindSafe", "Mocha", "TokyonightNight", "RosePineMain", "GruvboxDarkHard" },
    labels = {
        ColorblindSafe  = "Colorblind Safe (default)",
        Mocha           = "Catppuccin Mocha",
        TokyonightNight = "Tokyonight Night",
        RosePineMain    = "Rose Pine",
        GruvboxDarkHard = "Gruvbox Dark Hard",
    },
}

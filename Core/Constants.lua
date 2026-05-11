VFN = VFN or {}
VFN.Constants = {
    ADDON_NAME = "VamoosesFieldNotes",
    DB_NAME = "VFN_DB",
    SCHEMA_VERSION = 1,
    INDEXES_VERSION = 1,
    MAX_COORDS_PER_SET = 999,
    MAX_SETS_PER_LIBRARY = 999,
    MAX_VISITS_PER_COORD = 25,
    MINIMAP_DEFAULT_POSITION = 200,
    MAP_PARENT_WALK_LIMIT = 8,
    WORLD_MAP_PIN_MIN_MAP_TYPE = 3,
    WORLD_MAP_PIN_COLOR = { 0.12, 0.54, 0.88, 1 },
    WORLD_MAP_PIN_SENT_COLOR = { 0.18, 0.72, 0.42, 1 },
    WORLD_MAP_PIN_ALPHA = 0.9,
    WORLD_MAP_PIN_SENT_ALPHA = 1,
    DEFAULT_LIBRARY_ID = "default",
    DEBUG_PREFIX = "|cFF1E88E5[VFN]|r ",
    THEME = VFN_SchemeConstants.ColorblindSafe,

    -- Cycle definitions (order + labels + default) for enum-style controls
    -- (cycle buttons today, dropdowns later). Controllers read from here so a
    -- new value or label is one config edit, not a search-and-replace.
    CYCLES = {
        characterFilter = {
            order   = { "current", "all", "known" },
            labels  = {
                current = "Chars: current",
                all     = "Chars: all",
                known   = "Chars: known",
            },
            default = "current",
        },
        waypointBackend = {
            order   = { "auto", "blizzard", "tomtom" },
            labels  = {
                auto     = "Backend: auto",
                blizzard = "Backend: blizzard",
                tomtom   = "Backend: tomtom",
            },
            -- Per-mode hint text shown under the cycle button in Config.
            -- Keep here (not in controller) so a localiser only edits one
            -- file and re-skinners can swap copy without touching code.
            hints = {
                auto     = "Auto: TomTom when available, otherwise Blizzard pins plus one active waypoint.",
                blizzard = "Blizzard: VFN pins for the set, one active user waypoint.",
                tomtom   = "TomTom: multiple removable waypoints tagged as VFN.",
            },
            default = "auto",
        },
        sendScope = {
            order   = { "selected", "group", "set" },
            -- Bare-value labels (no "Scope:" prefix). The button context
            -- makes the meaning clear; the prefix was eating header width.
            labels  = {
                selected = "selected",
                group    = "current map",
                set      = "all",
            },
            default = "selected",
        },
    },

    -- Source provenance shapes. Set's `source` field is one of these. Used
    -- by controllers when building a new set payload.
    SOURCE = {
        manual = { type = "manual", owner = "VFN",   addon = "VFN",   key = nil, version = 1 },
        paste  = { type = "paste",  owner = "paste", addon = "paste", key = nil, version = 1 },
    },

    -- (EXPLICIT_VIEWS removed -- each mode in LayoutConfig.window.views
    -- declares its own `explicit = true` flag now. Single source of truth.)
}

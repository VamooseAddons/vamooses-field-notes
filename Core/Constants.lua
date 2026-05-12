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

    -- Action / notification name constants. The Store reducer's elseif chain
    -- branches on these for dispatched actions; subscribers (Controllers,
    -- WorldMapPins, etc.) read them to decide whether to react. Reach for the
    -- constant rather than the bare string so typos become "undefined field"
    -- errors at load instead of silent no-ops at runtime.
    --
    -- Convention: a true Dispatch action is in ACTIONS; a notification that's
    -- only TriggerStateChanged'd from a direct mutator is in NOTIFICATIONS.
    -- Both share the namespace -- subscribers don't care which side the name
    -- came from, just what to do with it.
    ACTIONS = {
        CONFIG_SET          = "VFN_CONFIG_SET",
        HARD_RESET          = "VFN_HARD_RESET",
        UI_SET_PERSISTENT   = "VFN_UI_SET_PERSISTENT",  -- writes to account.ui (saved)
        UI_SET_TRANSIENT    = "VFN_UI_SET_TRANSIENT",   -- writes to session.ui (cleared on /reload). payload.view optional for per-view sub-tables.
        UI_TOGGLE_MAP       = "VFN_UI_TOGGLE_MAP",
        MAIN_WINDOW_TOGGLE  = "VFN_MAIN_WINDOW_TOGGLE",  -- account.ui.mainWindowShown flip; SSoT for the addon's open/closed state across /reload
        SESSION_END         = "VFN_SESSION_END",         -- dispatched at PLAYER_LOGOUT; reducer closes the window so next login starts clean
        APPLY_LOG_APPEND    = "VFN_APPLY_LOG_APPEND",
        LIBRARY_CREATE      = "VFN_LIBRARY_CREATE",
        LIBRARY_DELETE      = "VFN_LIBRARY_DELETE",
        LIBRARY_RENAME      = "VFN_LIBRARY_RENAME",
        SET_CREATE          = "VFN_SET_CREATE",       -- collapsed from Store:CreateSet
        SET_DELETE          = "VFN_SET_DELETE",       -- collapsed from Store:DeleteSet
        SET_OPEN            = "VFN_SET_OPEN",         -- collapsed from Store:OpenSet
        SET_CLOSE           = "VFN_SET_CLOSE",        -- collapsed from Store:CloseSet
        SET_UPDATE          = "VFN_SET_UPDATE",
        SET_MOVE_LIBRARY    = "VFN_SET_MOVE_LIBRARY",
        -- Combat-state lifecycle. Dispatched by CombatMiddleware on
        -- PLAYER_REGEN_DISABLED / PLAYER_REGEN_ENABLED. Reducer is the
        -- single mutation point for session.combat.inLockdown (SSoT --
        -- middleware does NOT mutate state directly; spec section 4.4).
        COMBAT_ENTER        = "VFN_COMBAT_ENTER",
        COMBAT_EXIT         = "VFN_COMBAT_EXIT",
    },
    NOTIFICATIONS = {
        WAYPOINTS_SENT      = "VFN_WAYPOINTS_SENT",
        WAYPOINTS_REMOVED   = "VFN_WAYPOINTS_REMOVED",
        LIBRARY_SEEDED      = "VFN_LIBRARY_SEEDED",
        -- SET_CREATE/DELETE/OPEN/CLOSE moved to ACTIONS -- they're now true
        -- dispatched actions, not bare notifications. The reducer fires
        -- TriggerStateChanged with the same name so any existing subscriber
        -- (e.g., WorldMapPins) keeps working.
    },

    -- (EXPLICIT_VIEWS removed -- each mode in LayoutConfig.window.views
    -- declares its own `explicit = true` flag now. Single source of truth.)
}

VFN = VFN or {}

-- Action metadata for the middleware chain. Single source of truth that the
-- CombatMiddleware + PersistenceMiddleware consult. Keep aligned with the
-- reducer chain in Core/Store.lua:_RawDispatch -- when an action mutates
-- account state, mark it persists=true; when it touches secure frames,
-- combatUnsafe=true. VFN's UI is non-secure today, so no actions are
-- combat-unsafe at the state-mutation level (the combat queue applies to
-- UI refresh in MainFrame, not to dispatches).
local function BuildActionMeta()
    local A = VFN.Constants.ACTIONS
    return {
        [A.CONFIG_SET]        = { persists = true  },
        [A.HARD_RESET]        = { persists = true  },
        [A.UI_SET_PERSISTENT] = { persists = true  },
        [A.UI_SET_TRANSIENT]  = { persists = false },
        [A.UI_TOGGLE_MAP]     = { persists = true  },
        [A.MAIN_WINDOW_TOGGLE]= { persists = true  },
        [A.SESSION_END]       = { persists = true  },
        [A.APPLY_LOG_APPEND]  = { persists = false },
        [A.LIBRARY_CREATE]    = { persists = true  },
        [A.LIBRARY_DELETE]    = { persists = true  },
        [A.LIBRARY_RENAME]    = { persists = true  },
        [A.SET_CREATE]        = { persists = true  },
        [A.SET_DELETE]        = { persists = true  },
        [A.SET_OPEN]          = { persists = true  },
        [A.SET_CLOSE]         = { persists = true  },
        [A.SET_UPDATE]        = { persists = true  },
        [A.SET_MOVE_LIBRARY]  = { persists = true  },
        [A.COMBAT_ENTER]      = { persists = false },
        [A.COMBAT_EXIT]       = { persists = false },
    }
end

-- Declare every environment slot up-front (spec section 9 + 12). Static slots
-- only -- per-frame state (hover, scroll position) is forbidden. Each slot
-- has a valid standalone default so missing injection never produces nil
-- env entries. The thunk middleware passes the built env table as the 2nd
-- arg to function-shaped actions: `action(store, env)`.
local function DeclareEnvironmentSlots()
    if not VFN.Environment or not VFN.Environment.Declare then return end
    VFN.Environment:Declare({
        name        = "scheme",
        default     = (VFN.Theme and VFN.Theme.GetScheme and VFN.Theme:GetScheme()) or {},
        validator   = function(v) return type(v) == "table" end,
        description = "Active colour scheme + fonts + backdrops",
    })
    VFN.Environment:Declare({
        name        = "locale",
        default     = VFN.L or {},
        validator   = function(v) return type(v) == "table" end,
        description = "Localisation strings (GetLocale-keyed)",
    })
    VFN.Environment:Declare({
        name        = "debug",
        default     = function()
            local cfg = VFN.Store and VFN.Store.GetState and VFN.Store:GetState().account.config
            return cfg and cfg.debug == true or false
        end,
        validator   = function(v) return type(v) == "function" end,
        description = "Live debug-mode predicate read from account.config.debug",
    })
    VFN.Environment:Declare({
        name        = "layer",
        default     = "main",
        validator   = function(v) return type(v) == "string" end,
        description = "Render layer identifier (main / preview / tooltip)",
    })
end

function VFN:OnInitialize()
    VFN_DB = VFN_DB or {}
    VFN.Store:LoadFromSavedVariables()
    VFN.Theme:Initialize()
    -- Seeders run AFTER the Store has loaded SavedVariables -- idempotent,
    -- bail fast if their target library exists.
    VFN.LibrarySeeder:Run()

    -- v0.6 foundation Boot sequence. Order matters; each step assumes its
    -- predecessors have completed. See UI_WIDGET_TAXONOMY.md section 18
    -- (Adoption Plan / Phase 1 step list).
    -- BlizzardEvents frame was eager-created at TOC load (spec section 15.3);
    -- the OnInitialize call here is now a defensive no-op for tests that
    -- _Reset() the engine between cases.
    if VFN.BlizzardEvents and VFN.BlizzardEvents.OnInitialize then
        VFN.BlizzardEvents:OnInitialize()
    end
    -- Build the environment table BEFORE middleware so EnvMiddleware can
    -- close over the right env. Slots declared first, then assembled into
    -- one read-only table; further DeclareSlot calls error after Build.
    DeclareEnvironmentSlots()
    local env = VFN.Environment and VFN.Environment.Build and VFN.Environment:Build() or {}
    if VFN.Middleware and VFN.Middleware.Apply then
        -- Install the middleware chain BEFORE modules boot so their
        -- onInitialize-time dispatches flow through Logger / Combat /
        -- Persistence. Requires BlizzardEvents (CombatMiddleware subscribes
        -- to PLAYER_REGEN_*); placement after BlizzardEvents:OnInitialize
        -- is load-bearing.
        VFN.Middleware.Apply(VFN.Store, VFN.Middleware.StandardChain({
            actionMeta = BuildActionMeta(),
            env        = env,
        }))
    end
    if VFN.Modules and VFN.Modules.Boot then
        VFN.Modules:Boot()                              -- topo-sort + Phase 1 (onInitialize) + Phase 2 (onEnable)
    end
    if VFN.BlizzardEvents and VFN.BlizzardEvents.Boot then
        VFN.BlizzardEvents:Boot()                       -- wires module blizzardEvents declarations
    end
    if VFN.WidgetTypes and VFN.WidgetTypes.Flush then
        VFN.WidgetTypes:Flush()                         -- processes deferred registrations + validator
    end
    if VFN.FlowRunner and VFN.FlowRunner.Boot then
        VFN.FlowRunner:Boot()                           -- starts any module's flow function
    end

    -- Apply the saved scheme. Theme:Initialize loaded the default; if the
    -- user has chosen something else (state.account.config.scheme), swap
    -- to it now -- before any widgets are built. Skinners then paint on
    -- the right palette from the first frame.
    local cfg = VFN.Store:GetState().account.config
    local schemeName = cfg.scheme
    if schemeName and schemeName ~= "" and VFN_SchemeConstants[schemeName] then
        VFN.Theme:LoadScheme(schemeName)
    end
end

function VFN:OnEnable()
    VFN:CreateMainWindow()
    VFN.Minimap:Initialize()
    -- WorldMapPins lifecycle is owned by Modules:Boot (declared as a Module
    -- in Modules/WorldMapPins.lua). No explicit Init call needed here.
    --
    -- Restore the main window's open/closed state from SavedVariables. The
    -- pipeline's FrameVisibility stage reads state.account.ui.mainWindowShown
    -- and Show/Hides accordingly, so running a single Refresh is enough.
    VFN:RefreshMainWindow()
end

-- Lifecycle bootstrap routes through the BlizzardEvents engine per spec
-- section 15. The engine eager-inits at TOC load (Core/BlizzardEvents.lua)
-- so it can accept these subscriptions immediately -- no second event
-- frame is needed. _internalSubscribe is the spec-sanctioned attach point
-- for sibling-engine + lifecycle code (CombatMiddleware uses the same
-- surface for PLAYER_REGEN_*). Regular feature modules go through
-- declarative `blizzardEvents = {...}` instead, but those declarations
-- are wired by BE:Boot() which itself runs inside OnInitialize -- so
-- the lifecycle events that drive OnInitialize cannot use that path.
VFN.BlizzardEvents:_internalSubscribe("ADDON_LOADED", function(name)
    if name == "VamoosesFieldNotes" then VFN:OnInitialize() end
end)
VFN.BlizzardEvents:_internalSubscribe("PLAYER_LOGIN", function()
    VFN:OnEnable()
end)
VFN.BlizzardEvents:_internalSubscribe("PLAYER_LOGOUT", function()
    -- Dispatch SESSION_END first so the reducer mutates state (e.g.
    -- forces mainWindowShown = false) BEFORE Flush writes to disk.
    -- Subscribers (including any future modules that need shutdown
    -- behaviour) see the action via the standard Store:Subscribe path.
    if VFN.Store and VFN.Store.Dispatch then
        VFN.Store:Dispatch({ type = VFN.Constants.ACTIONS.SESSION_END })
    end
    if VFN.Store and VFN.Store.Flush then VFN.Store:Flush() end
end)

SLASH_VFN1 = "/vfn"
SlashCmdList["VFN"] = function(msg)
    msg = strtrim(msg or "")
    local lower = msg:lower()
    local first, rest = lower:match("^(%S+)%s*(.*)$")
    if lower == "debug" then
        local cfg = VFN.Store:GetState().account.config
        VFN.Store:Dispatch({
            type = VFN.Constants.ACTIONS.CONFIG_SET,
            payload = { key = "debug", value = not cfg.debug },
        })
    elseif lower == "minimap" then
        local cfg = VFN.Store:GetState().account.config
        VFN.Store:Dispatch({
            type = VFN.Constants.ACTIONS.CONFIG_SET,
            payload = { key = "showMinimapButton", value = not cfg.showMinimapButton },
        })
    elseif lower == "hardreset" then
        VFN.Store:Dispatch({ type = VFN.Constants.ACTIONS.HARD_RESET })
    elseif first == "theme" then
        -- /vfn theme            -- list available themes
        -- /vfn theme <name>     -- switch theme (case-insensitive prefix match)
        local meta = VFN_SchemeConstants._meta
        if rest == "" then
            print("|cffffb060[VFN]|r Available themes:")
            local cur = VFN.Store:GetState().account.config.scheme
            for _, name in ipairs(meta.order) do
                local marker = (name == cur) and "|cffffb060*|r " or "  "
                print(("%s|cffcdd6f4%s|r  |cff999999%s|r"):format(marker, name, meta.labels[name] or ""))
            end
            print("|cff666666Usage: /vfn theme <Name>|r")
        else
            -- Case-insensitive prefix match against the registry.
            local match
            local lowerArg = rest:lower():gsub("%s", "")
            for _, name in ipairs(meta.order) do
                if name:lower():sub(1, #lowerArg) == lowerArg then
                    match = name; break
                end
            end
            if not match then
                print(("|cffff5555[VFN]|r unknown theme %q -- run /vfn theme to list"):format(rest))
            else
                VFN.Store:Dispatch({
                    type = VFN.Constants.ACTIONS.CONFIG_SET,
                    payload = { key = "scheme", value = match },
                })
                VFN.Theme:LoadScheme(match)
                print(("|cffffb060[VFN]|r theme -> |cffcdd6f4%s|r"):format(match))
            end
        end
    elseif lower == "seed" then
        VFN.LibrarySeeder:Run()
    else
        VFN:ToggleMainWindow()
    end
end

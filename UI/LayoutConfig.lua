-- VFN.LayoutConfig
--
-- Pure data describing the entire UI shape. Read by VFN.Layout to build the
-- frame tree and compute placement rectangles. Adding a new widget means
-- adding ONE entry to this file -- no formula edits anywhere.
--
-- Concept hierarchy:
--   window           -- modes (collapsed / expanded), grid template per mode,
--                       named cells the panels can occupy.
--   panels[id]       -- chrome containers. Bind to a window cell per mode.
--                       Optionally declare slots: header / body / footer.
--   sections[id]     -- virtual layout boxes inside a panel slot or another
--                       section. layout = vertical | horizontal | fill.
--   widgets[id]      -- leaf nodes. kind names a factory in LayoutRegistry.
--
-- Routing:
--   Every section / widget declares
--     in   = "<parentPanelOrSectionId>"
--     slot = "header" | "body" | "footer"  (default "body"; only meaningful
--                                            when parent is a panel)
--
-- Sizing vocabulary:
--   number           -- fixed pixels
--   "fill"           -- consume remaining space (split equally among siblings)
--   "content"        -- behaves as fill today (TODO: pre-pass for true content)
--
-- Padding / gap vocabulary:
--   "xs" / "sm" / "md" / "lg" / "xl" / "xxl" / "huge"
--                   -- spacing tokens. Resolve via Theme.metrics.spacing.
--                      Use these for any padding/gap field. Adding a new value
--                      means adding a token to SchemeConstants, NOT a magic
--                      number here.
--   number          -- one-off geometry escape hatch (panel-slot height,
--                      explicit widget width, etc). Should be rare in
--                      padding/gap fields -- if you reach for a number,
--                      add a token instead.
-- Padding can be a single value or a sub-table { top, right, bottom, left }.
--
-- Per-mode visibility:
--   visibleInViews = { "modeA", "modeB", ... }   (optional)
-- Declared on any panel, section, OR widget. If present, the layout engine
-- skips the entry entirely when the current mode isn't listed -- it gets no
-- placement and its frame is hidden. Used to opt sections out of `capture`
-- mode (e.g. stream.streamList) or hide buttons in specific views.

VFN = VFN or {}

VFN.LayoutConfig = {

    window = {
        padding = "xxl",
        gap = "xl",
        -- Window mode = view. Each tab/view owns its own width + height +
        -- cell layout. streamPanel keeps its 360px rail in every mode so
        -- the stream rows render identically wherever the right area takes
        -- you. The right area changes per view: detail = main + drawer,
        -- library = single wide content panel, config = narrow content
        -- panel, capture = no right area (minimal mode).
        --
        -- `explicit = true` marks views the user can switch to directly via
        -- a header button (state.account.ui.view = "library" etc). Modes
        -- WITHOUT `explicit` are derived from selection state (detail when
        -- a set is selected, otherwise collapsed). MainFrame's view picker
        -- reads the flag to decide whether `ui.view` is honored.
        views = {
            collapsed = {
                width = 384,    -- 360 stream + 24 padding (12 each side)
                height = 760,
                columns = { 360 },
                rows = { "fill" },
                cells = { rail = { col = 1, row = 1 } },
            },
            -- "detail" view: a set is selected. Right side = main panel
            -- (top) + drawer panel (bottom). Same dimensions as the old
            -- "expanded" mode -- just renamed for view-clarity.
            detail = {
                width = 1220,
                height = 760,
                columns = { 360, "fill" },
                rows = { "fill", 370 },
                cells = {
                    rail   = { col = 1, row = 1, rowSpan = 2 },
                    main   = { col = 2, row = 1 },
                    drawer = { col = 2, row = 2 },
                },
            },
            -- "library" view: 3-column workspace inside the library panel
            -- (index | cards | coords). Same window width as detail so
            -- switching tabs doesn't resize the frame; column widths
            -- rebalanced internally for index/coords space.
            library = {
                explicit = true,
                width = 1220,
                height = 760,
                columns = { 360, "fill" },
                rows = { "fill" },
                cells = {
                    rail    = { col = 1, row = 1 },
                    content = { col = 2, row = 1 },
                },
            },
            -- "config" view: settings column. Genuinely narrower than
            -- detail/library -- it's a vertical settings list, doesn't
            -- need a wide canvas or a map drawer.
            config = {
                explicit = true,
                width = 720,
                height = 760,
                columns = { 360, "fill" },
                rows = { "fill" },
                cells = {
                    rail    = { col = 1, row = 1 },
                    content = { col = 2, row = 1 },
                },
            },
            -- "capture" view: minimal Paste-like floating utility. Just the
            -- streamPanel's capture form -- no history list, no detail rail,
            -- no library/config workspace. Window height matches the form's
            -- fixed-height widgets (status + labels + sourceBox 160 + noteBox
            -- 40 + actions 24 + padding/gaps + panel header). No flex
            -- widgets here, so the window is sized to content directly --
            -- if you add a widget, bump this.
            capture = {
                explicit = true,
                width  = 384,
                height = 376,
                columns = { 360 },
                rows = { "fill" },
                cells = { rail = { col = 1, row = 1 } },
            },
        },
        defaultView = "collapsed",
    },

    panels = {
        -- streamPanel is the constant in every view -- it's the home rail.
        -- Cell name "rail" is reused across modes; the engine scopes cell
        -- names to the mode so there's no naming clash.
        streamPanel = {
            kind = "panel",
            cell = { collapsed = "rail", detail = "rail", library = "rail", config = "rail", capture = "rail" },
            visibleInViews = { "collapsed", "detail", "library", "config", "capture" },
            slots = {
                header = {
                    height = 34, layout = "horizontal", gap = "md",
                    padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
                    chrome = "PanelHeader",
                },
            },
        },
        -- mainPanel + drawerPanel are detail-view only. They were in
        -- "expanded" before the view split; same panels, just a renamed mode.
        mainPanel = {
            kind = "panel",
            cell = { detail = "main" },
            visibleInViews = { "detail" },
            slots = {
                header = {
                    height = 34, layout = "horizontal", gap = "md",
                    padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
                    -- Distinct header background -- separates the title +
                    -- action buttons from the body content visually.
                    chrome = "PanelHeader",
                },
            },
        },
        drawerPanel = {
            kind = "panel",
            cell = { detail = "drawer" },
            visibleInViews = { "detail" },
            slots = {
                header = {
                    height = 34, layout = "horizontal", gap = "md",
                    padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
                    chrome = "PanelHeader",
                },
            },
        },
        -- libraryPanel and configPanel are stubs for now -- panels declared,
        -- but no widgets/sections inside yet. Adding content is the next
        -- step (Controller_Library, Controller_Config).
        libraryPanel = {
            kind = "panel",
            cell = { library = "content" },
            visibleInViews = { "library" },
            slots = {
                header = {
                    height = 34, layout = "horizontal", gap = "md",
                    padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
                    chrome = "PanelHeader",
                },
            },
        },
        configPanel = {
            kind = "panel",
            cell = { config = "content" },
            visibleInViews = { "config" },
            slots = {
                header = {
                    height = 34, layout = "horizontal", gap = "md",
                    padding = { top = 0, right = "xl", bottom = 0, left = "xl" },
                    chrome = "PanelHeader",
                },
            },
        },
    },

    sections = {
        -- ===== Stream panel body =====
        ["stream.capture"] = {
            ["in"] = "streamPanel",
            layout = "vertical",
            -- Match main.coordPane / drawer.body so the inset from the
            -- panel header reads consistently across all three panels.
            padding = "lg",
            gap = "sm",
            height = "content",
            order = 10,
        },
        ["stream.captureButtons"] = {
            ["in"] = "stream.capture",
            layout = "horizontal",
            height = 24,
            gap = "lg",
            order = 100,
        },
        ["stream.streamList"] = {
            ["in"] = "streamPanel",
            layout = "vertical",
            padding = "lg",
            gap = "sm",
            order = 20,
            -- Hidden in capture mode -- "minimal" view shows only the
            -- capture form, the rolling history list collapses away.
            visibleInViews = { "collapsed", "detail", "library", "config" },
        },
        -- (No filter row in stream mode -- character filter dropped per
        -- design. The setting still exists in state.account.config and
        -- defaults to "current"; if we ever want to expose it again, slap
        -- a cycle button into a settings panel instead of the stream rail.)

        -- ===== Main panel body =====
        -- (contextBar dropped -- backend button moved to mainPanel header)
        ["main.body"] = {
            ["in"] = "mainPanel",
            layout = "horizontal",
            order = 20,
        },
        ["main.groupRail"] = {
            ["in"] = "main.body",
            layout = "vertical",
            width = 268,    -- 50% wider than the original 178 to fit longer zone names
            padding = "lg",
            gap = "sm",
            order = 10,
        },
        ["main.coordPane"] = {
            ["in"] = "main.body",
            layout = "vertical",
            padding = "lg",
            gap = "lg",
            order = 20,
        },
        ["main.coordBar"] = {
            ["in"] = "main.coordPane",
            layout = "horizontal",
            height = 28,
            gap = "lg",
            order = 10,
        },
        ["main.coordList"] = {
            ["in"] = "main.coordPane",
            layout = "fill",
            order = 20,
            -- Sunken InsetFrame chrome for the coord list -- gives the pane
            -- a "code editor" / recessed feel that distinguishes data from
            -- surrounding chrome.
            chrome = "inset",
        },
        ["main.actionRow"] = {
            ["in"] = "main.coordPane",
            layout = "horizontal",
            height = 32,
            gap = "lg",
            order = 30,
        },

        -- ===== Drawer panel body =====
        ["drawer.body"] = {
            ["in"] = "drawerPanel",
            layout = "horizontal",
            -- Matches main.coordPane's padding so the map + side cards have
            -- the same inset from the drawer header as the source pane has
            -- from the main panel header.
            padding = "lg",
            gap = "lg",
        },
        ["drawer.map"] = {
            ["in"] = "drawer.body",
            layout = "fill",
            order = 10,
        },
        ["drawer.side"] = {
            ["in"] = "drawer.body",
            layout = "vertical",
            width = 320,
            -- Top padding 0 so the current-card chrome flush-aligns with the
            -- map's top edge. Right/bottom/left keep breathing room.
            padding = { top = 0, right = "lg", bottom = "lg", left = "lg" },
            gap = "md",
            order = 20,
        },
        ["drawer.currentCard"] = {
            ["in"] = "drawer.side",
            layout = "vertical",
            height = 96,
            padding = "xxl",    -- room inside the chrome NineSlice border
            gap = "sm",
            order = 10,
            chrome = "card", -- TooltipBorderedFrameTemplate -- matches editboxes
        },
        -- Set-level note (read-only). Edit happens in library tab. Flexes to
        -- absorb the slack between the fixed currentCard above and the
        -- now-fixed applyLog below.
        ["drawer.setNoteCard"] = {
            ["in"] = "drawer.side",
            layout = "vertical",
            padding = "xl",
            gap = "sm",
            order = 15,
            chrome = "card",
        },
        ["drawer.applyLog"] = {
            ["in"] = "drawer.side",
            layout = "vertical",
            -- Shrunk to ~3 visible apply-log rows + padding so the set note
            -- panel above it gets the lion's share of the side column.
            height = 64,
            padding = "xl",
            gap = "sm",
            order = 20,
            chrome = "card",
        },

        -- ===== Library panel body: 3-column "find + curate" workspace =====
        --   index   = libraries list           (left,  width 200)
        --   cards   = finder for selected lib  (mid,   width 360) -- search/filter/sort + cards + quick actions
        --   coords  = curator for selected set (right, fill)      -- edit metadata + preview coords
        ["library.body"] = {
            ["in"] = "libraryPanel",
            layout = "horizontal",
            padding = "lg",
            gap = "lg",
            order = 10,
        },
        ["library.index"] = {
            ["in"] = "library.body",
            layout = "vertical",
            width = 200,
            padding = "lg",
            gap = "sm",
            order = 10,
            chrome = "card",
        },
        ["library.cards"] = {
            ["in"] = "library.body",
            layout = "vertical",
            width = 360,
            padding = "lg",
            gap = "sm",
            order = 20,
            chrome = "card",
        },
        ["library.coords"] = {
            ["in"] = "library.body",
            layout = "vertical",
            padding = "lg",
            gap = "sm",
            order = 30,
            chrome = "card",
        },
        -- Left column: action row (New / Rename / Delete) pinned at bottom.
        ["library.indexActions"] = {
            ["in"] = "library.index",
            layout = "horizontal",
            height = 24,
            gap = "md",
            order = 100,
        },
        -- Middle column: search/sort row, filter chip row, action row (bottom).
        ["library.searchRow"] = {
            ["in"] = "library.cards",
            layout = "horizontal",
            height = 24,
            gap = "md",
            order = 10,
        },
        ["library.filterRow"] = {
            ["in"] = "library.cards",
            layout = "horizontal",
            height = 22,
            gap = "sm",
            order = 20,
        },
        ["library.cardsActions"] = {
            ["in"] = "library.cards",
            layout = "horizontal",
            height = 24,
            gap = "md",
            order = 100,
        },
        -- Right column: stat-card row + coord-preview viewer + action row.
        ["library.statRow"] = {
            ["in"] = "library.coords",
            layout = "horizontal",
            height = 46,
            gap = "md",
            order = 5,
        },
        -- "Coordinates" label + Copy button on the same row, above the
        -- coord-preview list. The Copy button writes the raw paste (the
        -- original source text) to the clipboard via the system editbox.
        ["library.previewHeaderRow"] = {
            ["in"] = "library.coords",
            layout = "horizontal",
            height = 18,
            gap = "md",
            order = 50,
        },
        ["library.coordsActions"] = {
            ["in"] = "library.coords",
            layout = "horizontal",
            height = 24,
            gap = "lg",
            order = 100,
        },

        -- ===== Config panel body =====
        ["config.body"] = {
            ["in"] = "configPanel",
            layout = "vertical",
            padding = "lg",
            gap = 14,
            order = 10,
        },
        ["config.actions"] = {
            ["in"] = "config.body",
            layout = "horizontal",
            height = 24,
            gap = "lg",
            order = 100,
        },
    },

    -- ===== Row templates (data) =====
    -- (Row definitions now live in the VFN.Rows registry -- each controller
    -- registers its rows with shape + behaviour in one declaration.
    -- Scrollboxes reference rows via options.rowKind = "<name>".)

    widgets = {
        -- ===== Panel headers (title + subtitle widgets per panel) =====
        ["streamPanel.title"] = {
            kind = "label", ["in"] = "streamPanel", slot = "header",
            text = "Field Notes", font = "heading",
            height = 18, order = 40,
            -- width omitted -> flex; title takes available space, naturally
            -- pushing the close button to the right edge.
        },
        -- (streamPanel.subtitle "coordinate inbox" removed -- decorative,
        -- no information value, ate header width that the title needs.)
        -- View switcher: Library + Config buttons. Tertiary chrome unless
        -- active (Controller_Stream rewrites the label with a marker prefix
        -- on Refresh). Click toggles -- click again on the active view
        -- returns to detail/collapsed.
        ["streamPanel.captureButton"] = {
            kind = "toggleButton", ["in"] = "streamPanel", slot = "header",
            width = 24, height = 24, order = 50,
            -- Two-base atlas: arrow-down for "minimize me", arrow-up for
            -- "expand me back." Active state (view = capture) swaps to up.
            options = {
                atlas = "housing-stair-arrow-down",
                activeAtlas = "housing-stair-arrow-up",
                size = 24,
                tooltip = "Minimize / Expand",
            },
        },
        -- Back-to-stream toggle. Same housing-stair-arrow atlases as the
        -- capture button, rotated 90 degrees clockwise so down -> left and
        -- up -> right. Left arrow = "click to collapse right panel back to
        -- just the stream rail." Right arrow = "we're already collapsed."
        -- pi/2 radians clockwise = -math.pi/2 in WoW's flipped Y space.
        ["streamPanel.backButton"] = {
            kind = "toggleButton", ["in"] = "streamPanel", slot = "header",
            width = 24, height = 24, order = 60,
            options = {
                atlas = "housing-stair-arrow-down",     -- rotated: points left
                activeAtlas = "housing-stair-arrow-up", -- rotated: points right
                size = 24,
                rotation = -1.5707963,                  -- -pi/2 (90 deg CW)
                tooltip = "Back to Stream",
            },
        },
        ["streamPanel.libraryButton"] = {
            kind = "atlasButton", ["in"] = "streamPanel", slot = "header",
            width = 24, height = 24, order = 20,
            -- List icon -- "library" reads as a list of saved sets.
            -- Hidden in capture mode -- minimal view keeps just Expand + close.
            visibleInViews = { "collapsed", "detail", "library", "config" },
            options = { atlas = "decor-placement-list", size = 24, tooltip = "Library" },
        },
        ["streamPanel.configButton"] = {
            kind = "atlasButton", ["in"] = "streamPanel", slot = "header",
            width = 24, height = 24, order = 30,
            -- Cog -- mirrors HDG HouseTab's Customise / Settings toggle.
            visibleInViews = { "collapsed", "detail", "library", "config" },
            options = { atlas = "decor-controls-settings", size = 24, tooltip = "Config" },
        },
        ["streamPanel.closeButton"] = {
            kind = "closebutton", ["in"] = "streamPanel", slot = "header",
            width = 22, height = 22, order = 10,
            options = { atlas = "XMarksTheSpot", iconSize = 14 },
        },

        ["mainPanel.title"] = {
            kind = "label", ["in"] = "mainPanel", slot = "header",
            text = "Captured Set", font = "heading",
            height = 18, width = "auto", order = 10,
        },
        -- Selected-entry context. Updated by Controller_Detail with the
        -- currently focused coord (e.g. "Founder's Point - Coordinate - 50.0, 33.3").
        -- width omitted -> flex; sits between the title and the right-side
        -- action buttons.
        ["mainPanel.subtitle"] = {
            kind = "labelDim", ["in"] = "mainPanel", slot = "header",
            text = "", font = "small",
            height = 14, order = 20,
        },

        ["drawerPanel.title"] = {
            kind = "label", ["in"] = "drawerPanel", slot = "header",
            text = "Map Drawer", font = "subheading",
            height = 16, width = 180, order = 10,
        },
        ["drawerPanel.subtitle"] = {
            kind = "labelDim", ["in"] = "drawerPanel", slot = "header",
            text = "auto preview", font = "small",
            height = 12, width = 140, order = 20,
        },

        -- ===== Stream capture form =====
        -- Single status row at the top of the capture form. Replaces the
        -- old "Unsaved draft" header + "Save to add to stream" hint + the
        -- per-input "Draft - paste coordinates below..." footer text. One
        -- field, one place to look. Controller_Stream owns the messages.
        -- kind = "labelStatus" -> accent-coloured FontString (semantic.accent)
        -- so the eye catches it as a status notification, not body text.
        ["captureForm.status"] = {
            kind = "statusBanner", ["in"] = "stream.capture", font = "body",
            text = "Paste coordinates, then click Send Waypoints.",
            height = 24, order = 1,
        },
        -- Title field hidden in capture mode -- the minimal-view goal is "paste
        -- and Send, zero ceremony." Empty title at Send auto-generates one
        -- from the first parsed coord (see Controller_Stream BuildSetPayload).
        ["captureForm.titleLabel"] = {
            kind = "fieldLabel", ["in"] = "stream.capture", text = "TITLE", font = "subheading",
            height = 16, order = 10,
            options = { hint = "optional" },
            visibleInViews = { "collapsed", "detail", "library", "config" },
        },
        ["captureForm.titleBox"] = {
            kind = "editbox", ["in"] = "stream.capture", font = "body",
            height = 24, order = 20, options = { multiline = false },
            visibleInViews = { "collapsed", "detail", "library", "config" },
        },
        ["captureForm.sourceLabel"] = {
            -- Hint right-side updates live from Controller_Stream's parse pass
            -- ("15 parsed" / "no coords yet").
            kind = "fieldLabel", ["in"] = "stream.capture", text = "PASTE COORDINATES", font = "subheading",
            height = 16, order = 30,
            options = { hint = "" },
        },
        ["captureForm.sourceBox"] = {
            kind = "editbox", ["in"] = "stream.capture", font = "body",
            height = 160, order = 40, options = { multiline = true },
        },
        ["captureForm.noteLabel"] = {
            kind = "fieldLabel", ["in"] = "stream.capture", text = "NOTE", font = "subheading",
            height = 16, order = 50,
            options = { hint = "source or context" },
        },
        ["captureForm.noteBox"] = {
            kind = "editbox", ["in"] = "stream.capture", font = "body",
            height = 40, order = 60,
            options = {
                multiline = true,
                placeholder = "e.g. paste the source URL here, or any context worth keeping.",
            },
        },
        -- Two actions:
        --   Pin Here = inject player's current location into the paste box
        --   Send     = commit field note to Default library + dispatch waypoints
        --
        -- There is no explicit Save -- everything saves on Send. If you don't
        -- click Send, the paste box content is transient (lost on /reload).
        ["captureForm.currentLocationButton"] = {
            kind = "button", ["in"] = "stream.captureButtons", font = "button",
            text = "Pin Here", width = "auto", order = 10, variant = "tertiary",
        },
        ["captureForm.sendButton"] = {
            kind = "button", ["in"] = "stream.captureButtons", font = "button",
            text = "Send Waypoints", width = "fill", order = 20, variant = "primary",
        },

        -- Hairline divider between the capture form (order 10) and the history
        -- list (order 20). Hides in capture mode along with the list itself.
        ["streamPanel.captureDivider"] = {
            kind = "divider", ["in"] = "streamPanel",
            height = 1, order = 15,
            visibleInViews = { "collapsed", "detail", "library", "config" },
        },

        -- ===== Stream list =====
        -- Header row: library dropdown (LEFT, flex) + count subtitle (RIGHT).
        ["stream.streamListHeader"] = {
            ["in"] = "stream.streamList",
            layout = "horizontal",
            height = 22,
            gap = "md",
            order = 5,
        },
        ["streamPanel.libraryDropdown"] = {
            kind = "button", ["in"] = "stream.streamListHeader", font = "button",
            text = "Default", width = "auto", height = 20, order = 10, variant = "tertiary",
        },
        ["streamPanel.streamStatus"] = {
            kind = "labelDim", ["in"] = "stream.streamListHeader", font = "small",
            justifyH = "RIGHT", width = "fill", height = 14, order = 20,
            text = "no saved field notes",
        },
        ["streamPanel.streamList"] = {
            kind = "scrollbox", ["in"] = "stream.streamList",
            order = 20,
            options = { rowKind = "streamRow", spacing = 2 },
        },

        -- ===== Main panel header slot actions =====
        -- Back arrow is leftmost (icon-style toggle matching the stream-panel
        -- arrows), title fills the middle, Delete Set is rightmost (magenta).
        ["mainPanel.backButton"] = {
            kind = "toggleButton", ["in"] = "mainPanel", slot = "header",
            width = 24, height = 24, order = 5,
            options = {
                atlas = "housing-stair-arrow-down",     -- rotated: points left
                activeAtlas = "housing-stair-arrow-up", -- rotated: points right
                size = 24,
                rotation = -1.5707963,                  -- -pi/2 (90 deg CW)
                tooltip = "Back to Stream",
            },
        },
        ["mainPanel.deleteButton"] = {
            kind = "button", ["in"] = "mainPanel", slot = "header", font = "button",
            text = "Delete Set", width = 96, height = 22, order = 70, variant = "danger",
        },

        -- (Backend button + character filter moved to Config tab. Both are
        -- settings that change rarely; they don't belong in the per-set
        -- detail header next to immediate-action buttons like Delete Set.)

        -- ===== Main panel body =====
        ["mainPanel.mapGroupList"] = {
            kind = "scrollbox", ["in"] = "main.groupRail",
            options = { rowKind = "groupRow", spacing = 1 },
        },
        ["mainPanel.mapPreviewButton"] = {
            kind = "button", ["in"] = "main.coordBar", font = "button",
            text = "Map Preview", width = "auto", order = 10, variant = "tertiary",
        },
        ["mainPanel.sourceToggleButton"] = {
            kind = "button", ["in"] = "main.coordBar", font = "button",
            text = "Source Text", width = "auto", order = 20, variant = "tertiary",
        },
        ["mainPanel.coordSummary"] = {
            kind = "labelDim", ["in"] = "main.coordBar", font = "small",
            order = 30, text = "",
        },
        ["mainPanel.coordinateList"] = {
            kind = "scrollbox", ["in"] = "main.coordList",
            options = { rowKind = "coordRow", spacing = 4 },
        },
        ["mainPanel.sourceLineList"] = {
            kind = "scrollbox", ["in"] = "main.coordList",
            options = { rowKind = "sourceLineRow", spacing = 4 },
        },
        ["mainPanel.scopeButton"] = {
            kind = "button", ["in"] = "main.actionRow", font = "button",
            text = "Scope: selected coordinate", width = "auto", height = 24, order = 10, variant = "tertiary",
        },
        ["mainPanel.sendButton"] = {
            kind = "button", ["in"] = "main.actionRow", font = "button",
            text = "Send Waypoints", width = 124, height = 24, order = 20, variant = "tertiary",
        },
        ["mainPanel.removeSentButton"] = {
            kind = "button", ["in"] = "main.actionRow", font = "button",
            text = "Remove Sent", width = 112, height = 24, order = 30, variant = "tertiary",
        },
        ["mainPanel.actionStatus"] = {
            kind = "labelDim", ["in"] = "main.actionRow", font = "small",
            order = 40, text = "",
        },

        -- ===== Drawer body =====
        ["drawerPanel.mapBody"] = {
            kind = "frame", ["in"] = "drawer.map",
        },
        ["drawerPanel.currentCardMap"] = {
            kind = "labelDim", ["in"] = "drawer.currentCard", font = "subheading",
            text = "Select a pin", height = 16, order = 10,
        },
        ["drawerPanel.currentCardCoords"] = {
            kind = "label", ["in"] = "drawer.currentCard", font = "heading",
            text = "", height = 22, order = 20,
        },
        ["drawerPanel.currentCardNote"] = {
            kind = "labelDim", ["in"] = "drawer.currentCard", font = "body",
            text = "", height = 14, order = 30,
        },
        ["drawerPanel.currentCardSource"] = {
            kind = "labelDim", ["in"] = "drawer.currentCard", font = "caption",
            text = "", height = 12, order = 40,
        },
        ["drawerPanel.setNoteTitle"] = {
            kind = "label", ["in"] = "drawer.setNoteCard", font = "subheading",
            text = "Note", height = 16, order = 10,
        },
        ["drawerPanel.setNoteBody"] = {
            kind = "labelDim", ["in"] = "drawer.setNoteCard", font = "body",
            text = "", order = 20,
            options = { wrap = true },
        },
        ["drawerPanel.applyLogTitle"] = {
            kind = "labelDim", ["in"] = "drawer.applyLog", font = "caption",
            text = "Apply Log", height = 12, order = 10,
        },
        ["drawerPanel.applyLogList"] = {
            kind = "scrollbox", ["in"] = "drawer.applyLog",
            order = 20,
            options = { rowKind = "applyLogRow", spacing = 0 },
        },

        -- ===== Library panel header =====
        ["libraryPanel.title"] = {
            kind = "label", ["in"] = "libraryPanel", slot = "header",
            text = "Library", font = "heading", height = 18, order = 10,
        },
        ["libraryPanel.subtitle"] = {
            kind = "labelDim", ["in"] = "libraryPanel", slot = "header",
            text = "all field notes across all characters", font = "body",
            height = 14, order = 20,
        },

        -- ===== Library: index column (left) =====
        -- Header (order 1) -> divider (order 2) -> list fills (order 10) ->
        -- actions pinned bottom (order 100). All three need explicit orders
        -- -- a scrollbox without one defaults to 0 and gets sorted ABOVE the
        -- header.
        ["libraryPanel.indexHeader"] = {
            kind = "label", ["in"] = "library.index", font = "subheading",
            text = "Libraries", height = 16, order = 1,
        },
        ["libraryPanel.indexDivider"] = {
            kind = "divider", ["in"] = "library.index",
            height = 1, order = 2,
        },
        ["libraryPanel.indexList"] = {
            kind = "scrollbox", ["in"] = "library.index",
            order = 10,
            options = { rowKind = "libraryIndexRow", spacing = 1 },
        },
        -- Library-level actions: "+ New" inline; Rename and Delete live on
        -- right-click of each library row (matches the card-row "Move to..."
        -- pattern, and keeps this narrow 200px column from over-spec'ing).
        ["libraryPanel.newLibraryButton"] = {
            kind = "button", ["in"] = "library.indexActions", font = "button",
            text = "+ New library", width = "auto", height = 22, order = 10, variant = "tertiary",
        },

        -- ===== Library: finder column (middle) =====
        -- Column header: static "Finder" label (matches the spec naming
        -- alongside Libraries / Curator). Divider, then dynamic count
        -- subtitle ("<libname> - <visible>/<total>") updated via Refresh.
        ["libraryPanel.cardsColumnHeader"] = {
            kind = "label", ["in"] = "library.cards", font = "subheading",
            text = "Finder", justifyH = "LEFT", height = 16, order = 1,
        },
        ["libraryPanel.cardsDivider"] = {
            kind = "divider", ["in"] = "library.cards",
            height = 1, order = 2,
        },
        ["libraryPanel.cardsHeader"] = {
            kind = "labelStatus", ["in"] = "library.cards", font = "small",
            text = "", justifyH = "LEFT", height = 12, order = 3,
        },
        ["libraryPanel.searchBox"] = {
            kind = "editbox", ["in"] = "library.searchRow", font = "body",
            height = 22, order = 10, options = { placeholder = "Search title or notes..." },
        },
        ["libraryPanel.sortButton"] = {
            kind = "button", ["in"] = "library.searchRow", font = "button",
            text = "Recent", width = 80, height = 22, order = 20, variant = "tertiary",
        },
        -- Filter chips -- variant carries semantic colour (see Theme.Skinners.StatusChip).
        -- Controller toggles the active chip via SetVariant.
        ["libraryPanel.filterAll"] = {
            kind = "button", ["in"] = "library.filterRow", font = "caption",
            text = "All", width = "auto", height = 20, order = 10, variant = "tertiary",
        },
        ["libraryPanel.filterReady"] = {
            kind = "button", ["in"] = "library.filterRow", font = "caption",
            text = "Ready", width = "auto", height = 20, order = 20, variant = "tertiary",
        },
        ["libraryPanel.filterHasNote"] = {
            kind = "button", ["in"] = "library.filterRow", font = "caption",
            text = "Has Note", width = "auto", height = 20, order = 30, variant = "tertiary",
        },
        ["libraryPanel.filterBlocked"] = {
            kind = "button", ["in"] = "library.filterRow", font = "caption",
            text = "Blocked", width = "auto", height = 20, order = 40, variant = "tertiary",
        },
        ["libraryPanel.cardsList"] = {
            kind = "scrollbox", ["in"] = "library.cards",
            order = 30,
            options = { rowKind = "libraryCardRow", spacing = 2 },
        },
        ["libraryPanel.sendWaypointsButton"] = {
            kind = "button", ["in"] = "library.cardsActions", font = "button",
            text = "Send Waypoints", width = "auto", height = 24, order = 10, variant = "primary",
        },
        ["libraryPanel.moveToButton"] = {
            kind = "button", ["in"] = "library.cardsActions", font = "button",
            text = "Move to...", width = "auto", height = 24, order = 20, variant = "tertiary",
        },
        ["libraryPanel.deleteCardButton"] = {
            kind = "button", ["in"] = "library.cardsActions", font = "button",
            text = "Delete", width = "auto", height = 24, order = 30, variant = "danger",
        },

        -- ===== Library: curator column (right) =====
        -- Column header -> divider -> stat row (3 cards) -> Title editbox ->
        -- Note editbox -> coord preview header row -> coord preview list ->
        -- save status -> actions.
        ["libraryPanel.coordsColumnHeader"] = {
            kind = "label", ["in"] = "library.coords", font = "subheading",
            text = "Curator", justifyH = "LEFT", height = 16, order = 1,
        },
        ["libraryPanel.coordsDivider"] = {
            kind = "divider", ["in"] = "library.coords",
            height = 1, order = 2,
        },
        ["libraryPanel.statCoords"] = {
            kind = "statCard", ["in"] = "library.statRow",
            options = { value = "0", label = "COORDS" },
            order = 10,
        },
        ["libraryPanel.statMaps"] = {
            kind = "statCard", ["in"] = "library.statRow",
            options = { value = "-", label = "MAP" },
            order = 20,
        },
        ["libraryPanel.statStatus"] = {
            kind = "statCard", ["in"] = "library.statRow",
            options = { value = "-", label = "STATUS" },
            order = 30,
        },
        ["libraryPanel.titleHeader"] = {
            kind = "label", ["in"] = "library.coords", font = "subheading",
            text = "Title", height = 16, order = 10,
        },
        ["libraryPanel.titleBox"] = {
            kind = "editbox", ["in"] = "library.coords", font = "body",
            height = 28, order = 11, options = { placeholder = "Untitled Field Note" },
        },
        ["libraryPanel.noteHeader"] = {
            kind = "label", ["in"] = "library.coords", font = "subheading",
            text = "Note", height = 16, order = 20,
        },
        ["libraryPanel.noteBox"] = {
            kind = "editbox", ["in"] = "library.coords", font = "body",
            height = 60, order = 21, options = { multiline = true, placeholder = "Add a note..." },
        },
        ["libraryPanel.previewHeader"] = {
            kind = "label", ["in"] = "library.previewHeaderRow", font = "subheading",
            text = "Coordinates", justifyH = "LEFT", width = "fill", height = 16, order = 10,
        },
        ["libraryPanel.previewCopyButton"] = {
            kind = "button", ["in"] = "library.previewHeaderRow", font = "button",
            text = "Copy coords", width = "auto", height = 18, order = 20, variant = "tertiary",
        },
        ["libraryPanel.coordsPreviewList"] = {
            kind = "scrollbox", ["in"] = "library.coords",
            order = 60,
            options = { rowKind = "libraryCoordPreviewRow", spacing = 1 },
        },
        ["libraryPanel.coordsActionStatus"] = {
            kind = "labelStatus", ["in"] = "library.coords", font = "small",
            text = "", justifyH = "LEFT", height = 14, order = 80,
        },
        ["libraryPanel.coordsSaveButton"] = {
            kind = "button", ["in"] = "library.coordsActions", font = "button",
            text = "Save", width = "auto", height = 24, order = 10, variant = "primary",
        },
        ["libraryPanel.coordsRestoreButton"] = {
            kind = "button", ["in"] = "library.coordsActions", font = "button",
            text = "Restore", width = "auto", height = 24, order = 20, variant = "tertiary",
        },

        -- ===== Config panel header + body =====
        ["configPanel.title"] = {
            kind = "label", ["in"] = "configPanel", slot = "header",
            text = "Config", font = "heading", height = 18, order = 10,
        },
        -- Section: waypoint backend
        ["configPanel.backendHeader"] = {
            kind = "label", ["in"] = "config.body", font = "subheading",
            text = "Waypoint Backend", justifyH = "LEFT", height = 16, order = 10,
        },
        ["configPanel.backendButton"] = {
            kind = "button", ["in"] = "config.body", font = "button",
            text = "Backend: auto", width = "auto", height = 24, order = 11, variant = "tertiary",
        },
        ["configPanel.backendHint"] = {
            kind = "labelDim", ["in"] = "config.body", font = "small",
            text = "", height = 14, order = 12,
        },
        -- Section: stream filter
        ["configPanel.charsHeader"] = {
            kind = "label", ["in"] = "config.body", font = "subheading",
            text = "Stream Filter", justifyH = "LEFT", height = 16, order = 20,
        },
        ["configPanel.charsButton"] = {
            kind = "button", ["in"] = "config.body", font = "button",
            text = "Chars: current", width = "auto", height = 24, order = 21, variant = "tertiary",
        },
        ["configPanel.charsHint"] = {
            kind = "labelDim", ["in"] = "config.body", font = "small",
            text = "Which characters' field notes show in the stream rail.",
            height = 14, order = 22,
        },
        -- Section: debug
        ["configPanel.debugHeader"] = {
            kind = "label", ["in"] = "config.body", font = "subheading",
            text = "Debug", justifyH = "LEFT", height = 16, order = 30,
        },
        ["configPanel.debugButton"] = {
            kind = "button", ["in"] = "config.body", font = "button",
            text = "Debug: off", width = "auto", height = 24, order = 31, variant = "tertiary",
        },
        -- Section: actions (destructive)
        ["configPanel.resetButton"] = {
            kind = "button", ["in"] = "config.actions", font = "button",
            text = "Hard Reset", width = 120, height = 24, order = 10, variant = "danger",
        },
        ["configPanel.resetHint"] = {
            kind = "labelDim", ["in"] = "config.actions", font = "small",
            text = "Wipes ALL Field Notes and settings. Cannot be undone.",
            height = 14, order = 20,
        },
    },
}

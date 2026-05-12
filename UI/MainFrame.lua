-- VFN MainFrame
--
-- Shell. Owns the outer frame and orchestrates the layout pipeline:
--   1. Layout:BuildAll          -- spec-driven widget construction
--   2. Controllers:WireAll      -- attach event handlers to spec'd widgets
--   3. EventBus                 -- VFN_STATE_CHANGED triggers Refresh
--   4. Refresh                  -- Layout:Compute -> Layout:Apply ->
--                                  Controllers:RefreshAll

VFN = VFN or {}

local function GetSelectedSet()
    if not VFN.Store or not VFN.Store.GetState then return nil end
    local state = VFN.Store:GetState()
    local id = state and state.account and state.account.ui and state.account.ui.selectedSetID
    local set = id and state.account.sets and state.account.sets[id] or nil
    if not set or set.deletedAt then return nil, nil, state end
    return id, set, state
end

local function GetSetTitle(set)
    if set and set.title and set.title ~= "" then return set.title end
    return "Untitled Field Note"
end

function VFN:CreateMainWindow()
    if self.mainFrame then return self.mainFrame end
    if not CreateFrame then return nil end

    local config = VFN.LayoutConfig
    local window = config.window
    local parent = _G and _G.UIParent or nil
    local frame = CreateFrame("Frame", "VFN_MainFrame", parent, "BackdropTemplate")
    if not frame then return nil end

    if frame.SetSize then
        local defaultView = window.views[window.defaultView]
        frame:SetSize(defaultView.width, defaultView.height)
    end
    if frame.SetPoint then frame:SetPoint("CENTER") end
    if frame.EnableMouse then frame:EnableMouse(true) end
    if frame.SetMovable then frame:SetMovable(true) end
    if frame.RegisterForDrag then frame:RegisterForDrag("LeftButton") end
    if frame.SetScript then
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    end
    VFN.Theme:Register(frame, "Frame")
    if frame.Hide then frame:Hide() end

    self.mainFrame = frame
    self:BuildMainWindow(frame)

    -- Subscribe to Store changes. Redux-style: every dispatch wakes us up
    -- and we re-derive from current state. Pipeline's FrameVisibility stage
    -- short-circuits the rest when the frame is hidden, so calling
    -- RefreshMainWindow on every action is cheap when the window is closed.
    VFN.Store:Subscribe(function() VFN:RefreshMainWindow() end)

    return frame
end

function VFN:ToggleMainWindow()
    local frame = self.mainFrame or self:CreateMainWindow()
    if not frame then return nil end
    -- SSoT: window shown-state lives in state.account.ui.mainWindowShown.
    -- Dispatching MAIN_WINDOW_TOGGLE flips it; the Store subscription
    -- triggers RefreshMainWindow, whose first stage (FrameVisibility) is
    -- the SOLE owner of Show/Hide reconciliation. Slash, minimap, and any
    -- future surface all converge on the same pipeline.
    VFN.Store:Dispatch({ type = VFN.Constants.ACTIONS.MAIN_WINDOW_TOGGLE })
    return frame
end

function VFN:BuildMainWindow(parent)
    if not parent then return end

    -- 0. Validate the spec; loud failures are better than silent typos.
    if VFN.Layout and VFN.Layout.Validate then
        local errors = VFN.Layout:Validate(VFN.LayoutConfig)
        if errors and #errors > 0 then
            local printer = _G and _G.print or function() end
            printer("|cffff5555[VFN] LayoutConfig validation errors:|r")
            for _, msg in ipairs(errors) do printer("|cffff5555  - " .. tostring(msg) .. "|r") end
        end
    end

    -- 1. Build the entire frame tree from LayoutConfig.
    if VFN.Layout and VFN.Layout.BuildAll then
        VFN.Layout:BuildAll(parent, VFN.LayoutConfig)
    end

    -- 2. Wire the close button -- spec'd as a widget on the streamPanel header
    --    so it goes through the same construction path as everything else.
    local closeButton = parent.widgets and parent.widgets["streamPanel.closeButton"]
    if closeButton and closeButton.SetScript then
        closeButton:SetScript("OnClick", function()
            if parent.Hide then parent:Hide() end
        end)
    end

    -- 3. Controllers wire behaviour to spec'd widgets.
    if VFN.Controllers and VFN.Controllers.WireAll then VFN.Controllers:WireAll(parent) end

    -- 4. Tag bound widgets so the binding engine can push values during Refresh.
    if VFN.BindingEngine and VFN.BindingEngine.Build then
        VFN.BindingEngine:Build(parent, VFN.LayoutConfig)
    end

    self:RefreshMainWindow()
end

-- ===== Pipeline stages per UI_WIDGET_TAXONOMY.md section 6 ================
-- Refresh is a sequential stage runner. Each stage receives a shared `ctx`
-- table; stages mutate ctx fields they own and read fields prior stages
-- populated. The runner walks PIPELINE_STAGES in declaration order; if any
-- stage's `predicate` returns false, that stage skips and the chain proceeds.

local PIPELINE_STAGES = {}

-- Stage 0: FrameVisibility -- reconcile the main frame's Show/Hide with
-- state.account.ui.mainWindowShown (SSoT for whether the addon UI is open).
-- This replaces the standalone _ReconcileMainWindowVisibility helper so the
-- spec section 6 pipeline owns the Show/Hide transition. The rest of the
-- pipeline always runs -- when the parent frame is hidden, WoW skips child
-- rendering anyway, so the cost is only the layout math (negligible at
-- our scale). Avoiding short-circuit keeps test paths exercising the full
-- pipeline regardless of saved visibility state.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "FrameVisibility",
    run  = function(ctx)
        local frame = ctx.frame
        local desired = false
        if VFN.Store and VFN.Store.GetState then
            local s = VFN.Store:GetState()
            desired = s and s.account and s.account.ui and s.account.ui.mainWindowShown == true or false
        end
        local isShown = frame.IsShown and frame:IsShown() or false
        if desired and not isShown then
            if frame.Show then frame:Show() end
        elseif not desired and isShown then
            if frame.Hide then frame:Hide() end
        end
    end,
}

-- Stage 1: PrepareContext -- derive view, target size, current state. Read-
-- only over the Store. Always runs.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "PrepareContext",
    run  = function(ctx)
        local config = VFN.LayoutConfig
        local _, selectedSet, state = GetSelectedSet()
        local hasSelection = selectedSet ~= nil
        local mapState = state and state.account and state.account.ui and state.account.ui.map or nil
        local mapShown = hasSelection and (not mapState or mapState.shown ~= false) or false

        local activeView = state and state.account and state.account.ui and state.account.ui.view or nil
        local activeViewSpec = activeView and config.window.views[activeView] or nil
        local view
        if activeViewSpec and activeViewSpec.explicit then
            view = activeView
        elseif hasSelection then
            view = "detail"
        else
            view = "collapsed"
        end

        local viewSpec = config.window.views[view]
        ctx.config       = config
        ctx.state        = state
        ctx.set          = selectedSet
        ctx.hasSelection = hasSelection
        ctx.visible      = mapShown and hasSelection
        ctx.view         = view
        ctx.viewSpec     = viewSpec
        ctx.targetWidth  = viewSpec.width
        ctx.targetHeight = viewSpec.height
        ctx.mapShown     = mapShown
        ctx.groupKey     = state and state.session and state.session.ui and state.session.ui.selectedGroupKey or nil
    end,
}

-- Stage 2: ResizeFrame -- apply target size + preserve top-left. Separated
-- from LAYOUT so the frame has its final dimensions before any layout pass.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "ResizeFrame",
    run  = function(ctx)
        local frame = ctx.frame
        local preservedL, preservedT
        if frame.GetLeft and frame.GetTop then
            preservedL, preservedT = frame:GetLeft(), frame:GetTop()
        end
        if frame.SetSize then frame:SetSize(ctx.targetWidth, ctx.targetHeight) end
        if preservedL and preservedT and frame.ClearAllPoints and frame.SetPoint and _G.UIParent then
            frame:ClearAllPoints()
            frame:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", preservedL, preservedT)
        end
    end,
}

-- Stage 3: BIND -- BindingEngine pushes state values into bound widgets.
-- Must run BEFORE LAYOUT so intrinsics reflect current state, not last frame.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "Bind",
    predicate = function() return VFN.BindingEngine and VFN.BindingEngine.Apply end,
    run = function(ctx)
        VFN.BindingEngine:Apply(ctx.frame, ctx.state, ctx)
    end,
}

-- Stage 4: HeaderText -- header titles aren't bound via BindingEngine; they
-- update from selection state directly.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "HeaderText",
    run  = function(ctx)
        local w = ctx.frame.widgets and ctx.frame.widgets["mainPanel.title"]
        if not (w and w.SetText) then return end
        w:SetText(ctx.hasSelection and GetSetTitle(ctx.set) or "Captured Set")
    end,
}

-- Stage 5: CONTROLLER_REFRESH -- imperative side effects (pin painting,
-- map drawer canvas, etc.) that can't be expressed declaratively. Runs
-- BEFORE Layout per spec section 6: visibility is now declarative (the
-- `visible` field on widget specs, resolved by Layout:Compute), so
-- controllers no longer need to win Show/Hide races against Layout.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "ControllerRefresh",
    predicate = function() return VFN.Controllers and VFN.Controllers.RefreshAll end,
    run = function(ctx)
        VFN.Controllers:RefreshAll(ctx.frame, ctx)
    end,
}

-- Stage 6: LAYOUT -- harvest intrinsics (now reflecting BIND-stage values),
-- compute placements (with declarative visibility resolution), apply to widgets.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "Layout",
    predicate = function() return VFN.Layout ~= nil end,
    run = function(ctx)
        local frame = ctx.frame
        local intrinsics
        if frame.widgets then
            intrinsics = {}
            for id, widget in pairs(frame.widgets) do
                if widget._intrinsicWidth or widget._intrinsicHeight then
                    intrinsics[id] = { width = widget._intrinsicWidth, height = widget._intrinsicHeight }
                end
            end
        end
        local placements = VFN.Layout:Compute(ctx.config, {
            view         = ctx.view,
            width        = ctx.targetWidth,
            height       = ctx.targetHeight,
            intrinsics   = intrinsics,
            panelVisible = { drawerPanel = ctx.mapShown },
            state        = ctx.state,  -- enables Layout's `visible` selector resolution
        })
        frame.placements = placements
        VFN.Layout:Apply(frame, placements)
    end,
}

-- Stage 7: THEME -- terminal paint stage per spec section 6. Paint is
-- event-driven today (Theme:Register at build, Theme:SetState during Bind),
-- so this stage is a documented no-op until a paint-dirty queue exists.
PIPELINE_STAGES[#PIPELINE_STAGES + 1] = {
    name = "Theme",
    predicate = function() return false end,
    run = function(_ctx) end,
}

-- Pipeline runner. Iterates stages in spec section 6 order. Each stage is
-- pcall-wrapped per spec audit finding C2 so a crash in (e.g.) Bind doesn't
-- silently skip Layout / ControllerRefresh and leave the UI half-refreshed.
local function runPipeline(frame)
    local ctx = { frame = frame }
    for _, stage in ipairs(PIPELINE_STAGES) do
        if not stage.predicate or stage.predicate(ctx) then
            local ok, err = pcall(stage.run, ctx)
            if not ok then
                local printer = _G and _G.print or function() end
                printer(("|cffff5555[VFN] pipeline stage %s error: %s|r"):format(
                    tostring(stage.name), tostring(err)))
            end
        end
    end
end

function VFN:RefreshMainWindow()
    local frame = self.mainFrame
    if not frame or not VFN.Layout then return end

    -- Combat guard: SetSize / SetPoint / Show / Hide on UIParent-parented
    -- frames can taint if any descendant uses a secure template. Queue the
    -- refresh and replay on combat-exit rather than letting it land
    -- mid-combat. Per spec section 15.7, PLAYER_REGEN_* are owned by
    -- CombatMiddleware; modules/components observe state.session.combat
    -- transitions via Store:Subscribe and react when COMBAT_EXIT fires.
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        self._pendingRefresh = true
        if not self._combatSubscribed and VFN.Store and VFN.Store.Subscribe then
            self._combatSubscribed = true
            local A = VFN.Constants.ACTIONS
            VFN.Store:Subscribe(function(actionType)
                if actionType == A.COMBAT_EXIT and self._pendingRefresh then
                    self._pendingRefresh = false
                    self:RefreshMainWindow()
                end
            end)
        end
        return
    end

    runPipeline(frame)
end

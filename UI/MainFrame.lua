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

    -- Subscribe to Store changes. Redux-style: every dispatch (regardless of
    -- action) wakes us up; we re-derive everything from current state.
    if VFN.Store and VFN.Store.Subscribe then
        VFN.Store:Subscribe(function() if VFN.RefreshMainWindow then VFN:RefreshMainWindow() end end)
    end

    return frame
end

function VFN:ToggleMainWindow()
    local frame = self.mainFrame or self:CreateMainWindow()
    if not frame then return nil end
    if frame.IsShown and frame:IsShown() then
        if frame.Hide then frame:Hide() end
    else
        if frame.Show then frame:Show() end
        self:RefreshMainWindow()
    end
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

function VFN:RefreshMainWindow()
    local frame = self.mainFrame
    if not frame or not VFN.Layout then return end

    -- Combat guard: SetSize / SetPoint / Show / Hide on UIParent-parented
    -- frames can taint if any descendant uses a secure template (waypoint
    -- buttons, etc -- not used today but future-proofs). Queue the refresh
    -- and replay on PLAYER_REGEN_ENABLED rather than letting it land mid-combat.
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        self._pendingRefresh = true
        if not self._combatHook and frame.RegisterEvent then
            frame:RegisterEvent("PLAYER_REGEN_ENABLED")
            frame:HookScript("OnEvent", function(_, evt)
                if evt == "PLAYER_REGEN_ENABLED" and self._pendingRefresh then
                    self._pendingRefresh = false
                    self:RefreshMainWindow()
                end
            end)
            self._combatHook = true
        end
        return
    end

    local config = VFN.LayoutConfig
    local _, selectedSet, state = GetSelectedSet()
    local hasSelection = selectedSet ~= nil
    -- mapShown is canonical state on the Store; read directly so MainFrame
    -- isn't coupled to a controller's API.
    local mapState = state and state.account and state.account.ui and state.account.ui.map or nil
    local mapShown = hasSelection and (not mapState or mapState.shown ~= false) or false
    -- Resolve the current view. Views with `explicit = true` in
    -- LayoutConfig.window.views are tabs the user can switch to directly via
    -- `ui.view` ("library", "config", "capture"). Otherwise the view is
    -- derived from selection state ("detail" when a set is selected, else
    -- "collapsed"). Adding a new tab = one entry in window.views (with
    -- `explicit = true`) + a panel + a controller.
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
    local targetWidth = viewSpec.width
    local targetHeight = viewSpec.height

    -- Preserve top-left across resizes: a frame anchored CENTER would shift
    -- as it grows. We want growth to extend rightward (and downward) from the
    -- frame's current top-left, so the user doesn't have to chase the rail.
    local preservedL, preservedT
    if frame.GetLeft and frame.GetTop then
        preservedL, preservedT = frame:GetLeft(), frame:GetTop()
    end
    if frame.SetSize then frame:SetSize(targetWidth, targetHeight) end
    if preservedL and preservedT and frame.ClearAllPoints and frame.SetPoint and _G.UIParent then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", preservedL, preservedT)
    end

    -- Harvest auto-sized widgets' intrinsics so the engine can resolve
    -- spec.width = "auto" / height = "auto" against actual measured sizes.
    local intrinsics
    if frame.widgets then
        intrinsics = {}
        for id, widget in pairs(frame.widgets) do
            if widget._intrinsicWidth or widget._intrinsicHeight then
                intrinsics[id] = { width = widget._intrinsicWidth, height = widget._intrinsicHeight }
            end
        end
    end

    -- 1. Compute placements.
    local placements = VFN.Layout:Compute(config, {
        view = view,
        width = targetWidth,
        height = targetHeight,
        intrinsics = intrinsics,
        -- panelVisible is for RUNTIME overrides only -- per-view visibility
        -- comes from the panel's `cell` map (a panel without a cell entry
        -- for the current view auto-hides). mainPanel/libraryPanel/etc.
        -- show or hide based on which view is active. drawerPanel hides
        -- explicitly when the user toggled the map off.
        panelVisible = {
            drawerPanel = mapShown,
        },
    })
    frame.placements = placements

    -- 2. Update header text widgets dynamically.
    local function setText(id, text)
        local w = frame.widgets and frame.widgets[id]
        if w and w.SetText then w:SetText(text or "") end
    end
    if hasSelection then
        setText("mainPanel.title", GetSetTitle(selectedSet))
    else
        setText("mainPanel.title", "Captured Set")
    end

    -- 3. Apply placements to all panels and widgets.
    VFN.Layout:Apply(frame, placements)

    -- 4. Controllers refresh content. Each receives the same shared ctx and
    --    pulls what it needs.
    local ctx = {
        state = state,
        view = view,
        hasSelection = hasSelection,
        set = selectedSet,
        visible = mapShown and hasSelection,
        -- selectedGroupKey lives in session.ui (transient nav), not account.ui.
        groupKey = state and state.session and state.session.ui and state.session.ui.selectedGroupKey or nil,
    }
    -- Binding engine pushes state -> bound widgets BEFORE controllers refresh.
    -- Controllers' Refresh handles only imperative side-effect work (canvas
    -- pin painting, dirty editbox guarding, etc.) that can't be expressed as
    -- a pure-data binding.
    if VFN.BindingEngine and VFN.BindingEngine.Apply then
        VFN.BindingEngine:Apply(frame, state, ctx)
    end
    if VFN.Controllers and VFN.Controllers.RefreshAll then
        VFN.Controllers:RefreshAll(frame, ctx)
    end
end

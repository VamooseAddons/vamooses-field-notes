-- VFN.Layout
--
-- Pure layout engine. Reads VFN.LayoutConfig + a ctx state table, produces a
-- flat placement map keyed by panel/section/widget id. Also builds the frame
-- tree by walking the same spec data via the LayoutRegistry.
--
-- Concepts (in order of containment):
--   window           outer frame; rendered in modes (collapsed | expanded)
--   panel            top-level container with an optional chrome (slots)
--   slot             named region inside a panel: "header" | "body" | "footer"
--   section          virtual layout box. Stacks (vertical | horizontal | fill)
--                    its children. May contain other sections or widgets.
--   widget           leaf node. kind names a factory in VFN.LayoutRegistry.
--
-- Routing: a section / widget declares
--     in   = "<parentPanelOrSectionId>"
--     slot = "header" | "body" | "footer"   (default "body"; ignored when
--                                            the parent is a section, not a panel)
-- which tells the engine where it lives. Slots only exist on panels.
--
-- Public API:
--   Layout:Compute(config, ctx)          -> placements
--   Layout:Apply(rootFrame, placements)
--   Layout:BuildAll(rootFrame, config)
--   Layout:Validate(config)              -> { errors }

VFN = VFN or {}
VFN.Layout = VFN.Layout or {}

local Layout = VFN.Layout

local DEFAULT_HEADER_HEIGHT = 34
local DEFAULT_FOOTER_HEIGHT = 28

-- Templates for chromed sections. Sections opt in via spec.chrome = "<name>".
--   card    -> Tooltip-style NineSlice border (matches InputScrollFrameTemplate)
--   inset   -> Flat sunken sub-panel, NO Blizzard template chrome. Just a
--              themed bg texture (surface.sunken) + 1px border drawn by us.
--              We avoid InsetFrameTemplate here because its NineSlice fights
--              custom bg tints and leaves a brown/lit edge no matter what.
--   tooltip -> Same as card, alias
-- A `false` value means "create a plain Frame with no inheritsFrom" and rely
-- on the bg-tint texture + optional border textures for visuals.
local CHROME_TEMPLATES = {
    card    = "TooltipBorderedFrameTemplate",
    inset   = false,
    tooltip = "TooltipBorderedFrameTemplate",
}
Layout.CHROME_TEMPLATES = CHROME_TEMPLATES

-- Helpers --------------------------------------------------------------------

local function clamp(value)
    if not value or value < 0 then return 0 end
    return value
end

local function rect(x, y, w, h)
    return { x = x or 0, y = y or 0, width = clamp(w), height = clamp(h) }
end

-- Resolve a spacing value to a number. Accepts:
--   number          -> returned as-is (one-off geometry escape hatch)
--   "lg" / "md"...  -> looked up via Theme:GetMetric("spacing.<name>")
--   nil             -> 0
-- Unknown tokens fail loud so a typo doesn't silently render zero.
local function resolveSpacing(value)
    if value == nil then return 0 end
    if type(value) == "number" then return value end
    if type(value) == "string" then
        local n = VFN.Theme and VFN.Theme.GetMetric
            and VFN.Theme:GetMetric("spacing." .. value) or nil
        if not n then
            error(("Layout: unknown spacing token %q (expected one of: xs/sm/md/lg/xl/xxl/huge)"):format(value), 3)
        end
        return n
    end
    return 0
end
Layout._resolveSpacing = resolveSpacing  -- exported for tests

local function normalizePadding(p)
    if p == nil then
        return { top = 0, right = 0, bottom = 0, left = 0 }
    end
    if type(p) == "number" or type(p) == "string" then
        local n = resolveSpacing(p)
        return { top = n, right = n, bottom = n, left = n }
    end
    if type(p) == "table" then
        return {
            top    = resolveSpacing(p.top),
            right  = resolveSpacing(p.right),
            bottom = resolveSpacing(p.bottom),
            left   = resolveSpacing(p.left),
        }
    end
    return { top = 0, right = 0, bottom = 0, left = 0 }
end

local function specFor(config, id)
    return (config.sections and config.sections[id])
        or (config.widgets and config.widgets[id])
        or (config.panels and config.panels[id])
end

-- getAlong returns the spec's primary-axis size. Three forms:
--   number    -> fixed
--   "fill"    -> flex (shares slack with siblings)
--   "auto"    -> resolve from runtime intrinsics (see Layout._intrinsics);
--                falls back to "fill" if the widget hasn't reported one yet.
--   "content" -> sum descendants (handled in measureContent caller path)
--   nil       -> treated as "fill"
local function getAlong(spec, axis, id)
    local val = (axis == "vertical") and spec.height or spec.width
    if val == "auto" then
        local intrinsics = Layout._intrinsics
        local entry = id and intrinsics and intrinsics[id]
        if entry then
            local v = (axis == "vertical") and entry.height or entry.width
            if type(v) == "number" then return v end
        end
        return "fill"  -- intrinsic not (yet) reported -> behave as flex
    end
    return val
end

local function getCross(spec, axis)
    if axis == "vertical" then return spec.width end
    return spec.height
end

-- Window grid ----------------------------------------------------------------

local function computeWindowCells(config, view, ctx)
    local windowCfg = config.window
    local viewSpec = windowCfg.views[view]
    local pad = clamp(resolveSpacing(windowCfg.padding))
    local gap = clamp(resolveSpacing(windowCfg.gap))
    local frameW = viewSpec.width
    local frameH = viewSpec.height
    local contentW = clamp(frameW - pad * 2)
    local contentH = clamp(frameH - pad * 2)

    local cols = viewSpec.columns or { "fill" }
    local rows = viewSpec.rows or { "fill" }

    -- Determine which rows / cols have at least one visible panel as their
    -- PRIMARY track. rowSpan / colSpan cells grow into whatever tracks are
    -- available -- they don't require the spanned tracks to stay live, so
    -- we mark only the (col, row) anchor here. A row that's only being
    -- spanned (not primary for any visible panel) collapses.
    local liveRows, liveCols = {}, {}
    for panelId, panelSpec in pairs(config.panels or {}) do
        local visible = ctx == nil or ctx.panelVisible == nil
            or ctx.panelVisible[panelId] ~= false
        local cellName = panelSpec.cell and panelSpec.cell[view] or nil
        local cellSpec = cellName and (viewSpec.cells or {})[cellName] or nil
        if visible and cellSpec then
            liveRows[cellSpec.row or 1] = true
            liveCols[cellSpec.col or 1] = true
        end
    end

    local function resolveTracks(template, total, liveMask)
        local fixedSum, flex, liveCount = 0, 0, 0
        for i, t in ipairs(template) do
            local live = not liveMask or liveMask[i]
            if live then
                liveCount = liveCount + 1
                if t == "fill" then flex = flex + 1
                else fixedSum = fixedSum + (tonumber(t) or 0) end
            end
        end
        local gapTotal = math.max(0, liveCount - 1) * gap
        local flexSize = flex > 0 and math.max(0, (total - fixedSum - gapTotal) / flex) or 0
        local sizes, offsets = {}, {}
        local cursor = 0
        for i, t in ipairs(template) do
            local live = not liveMask or liveMask[i]
            if live then
                sizes[i] = (t == "fill") and flexSize or (tonumber(t) or 0)
                offsets[i] = cursor
                cursor = cursor + sizes[i] + gap
            else
                sizes[i] = 0
                offsets[i] = cursor
            end
        end
        return sizes, offsets
    end

    local colSizes, colOffsets = resolveTracks(cols, contentW, liveCols)
    local rowSizes, rowOffsets = resolveTracks(rows, contentH, liveRows)

    local cells = {}
    for cellName, cellSpec in pairs(viewSpec.cells or {}) do
        local col = cellSpec.col or 1
        local row = cellSpec.row or 1
        local colSpan = cellSpec.colSpan or 1
        local rowSpan = cellSpec.rowSpan or 1
        local x = pad + (colOffsets[col] or 0)
        local y = pad + (rowOffsets[row] or 0)
        -- Add gap only between non-collapsed (size > 0) tracks. Avoids
        -- overshooting when a panel spans rows / cols where the neighbour
        -- has been collapsed by track-collapse.
        local w, hasW = 0, false
        for i = col, col + colSpan - 1 do
            local s = colSizes[i] or 0
            if s > 0 then
                if hasW then w = w + gap end
                w = w + s; hasW = true
            end
        end
        local h, hasH = 0, false
        for i = row, row + rowSpan - 1 do
            local s = rowSizes[i] or 0
            if s > 0 then
                if hasH then h = h + gap end
                h = h + s; hasH = true
            end
        end
        cells[cellName] = rect(x, y, w, h)
    end

    return cells, frameW, frameH
end

-- Child indexing -- routed by (parentId, slot). Default slot = "body". -------

local function buildChildIndex(config, view)
    local index = {}
    local function add(parentId, childId, order, slot)
        if not parentId then return end
        slot = slot or "body"
        index[parentId] = index[parentId] or {}
        index[parentId][slot] = index[parentId][slot] or {}
        local bucket = index[parentId][slot]
        bucket[#bucket + 1] = { id = childId, order = order or 0 }
    end

    -- Per-view visibility for sections and widgets. If `visibleInViews` is
    -- declared, the spec is excluded from the index when current view isn't
    -- listed -- it gets no placement and the engine's section/widget Apply
    -- pass auto-hides its frame. Mirrors the panel cell-map mechanism.
    local function visibleInView(spec)
        local v = spec.visibleInViews
        if v == nil then return true end
        for _, m in ipairs(v) do if m == view then return true end end
        return false
    end

    for id, spec in pairs(config.sections or {}) do
        if visibleInView(spec) then add(spec["in"], id, spec.order, spec.slot) end
    end
    for id, spec in pairs(config.widgets or {}) do
        if visibleInView(spec) then add(spec["in"], id, spec.order, spec.slot) end
    end

    for _, slots in pairs(index) do
        for slotName, children in pairs(slots) do
            table.sort(children, function(a, b) return (a.order or 0) < (b.order or 0) end)
            local ordered = {}
            for _, e in ipairs(children) do ordered[#ordered + 1] = e.id end
            slots[slotName] = ordered
        end
    end

    return index
end

-- Slots ----------------------------------------------------------------------

local function getPanelSlots(panelSpec)
    local declared = panelSpec.slots
    if not declared then
        return { body = { layout = panelSpec.bodyLayout or "vertical" } }
    end

    -- Default each slot's layout if missing.
    local slots = {}
    for name, slotSpec in pairs(declared) do
        local merged = {}
        for k, v in pairs(slotSpec) do merged[k] = v end
        if not merged.layout then
            if name == "header" or name == "footer" then merged.layout = "horizontal"
            else merged.layout = "vertical" end
        end
        if name == "header" and not merged.height then merged.height = DEFAULT_HEADER_HEIGHT end
        if name == "footer" and not merged.height then merged.height = DEFAULT_FOOTER_HEIGHT end
        slots[name] = merged
    end
    -- Body slot is always implicit if not declared.
    if not slots.body then
        slots.body = { layout = panelSpec.bodyLayout or "vertical" }
    end
    return slots
end

local function computeSlotRects(panelRect, slots)
    local headerH = slots.header and clamp(slots.header.height) or 0
    local footerH = slots.footer and clamp(slots.footer.height) or 0
    local bodyH = clamp(panelRect.height - headerH - footerH)

    local out = {}
    if slots.header then
        out.header = rect(0, 0, panelRect.width, headerH)
    end
    out.body = rect(0, headerH, panelRect.width, bodyH)
    if slots.footer then
        out.footer = rect(0, headerH + bodyH, panelRect.width, footerH)
    end
    return out
end

-- Stack / fill layout (used by sections AND panel slots) ---------------------

local layoutContainer  -- forward

local function applyPadding(r, paddingSpec)
    local pad = normalizePadding(paddingSpec)
    return rect(r.x + pad.left, r.y + pad.top,
                r.width - pad.left - pad.right,
                r.height - pad.top - pad.bottom)
end

-- Pre-pass: sum descendants for "content" sized children. Walks the spec tree
-- (sections + widgets) under the given id, summing fixed sizes and gaps along
-- the parent's axis. Returns nil if any descendant is "fill"/nil (indeterminate).
local function measureContent(id, axis, config, index)
    local spec = specFor(config, id)
    if not spec then return 0 end

    local own = getAlong(spec, axis, id)
    if type(own) == "number" then return own end

    local slots = index[id] or {}
    -- Sections store all children under "body" key (slots only matter on panels).
    local children = slots.body
    if not children or #children == 0 then return 0 end

    local localAxis = spec.layout == "horizontal" and "horizontal"
        or spec.layout == "vertical" and "vertical"
        or axis  -- inherit from parent for "fill" sections
    local total = 0
    for _, childId in ipairs(children) do
        local cspec = specFor(config, childId)
        if not cspec then return nil end
        local s = getAlong(cspec, localAxis, childId)
        if s == "content" then
            s = measureContent(childId, localAxis, config, index)
        end
        if type(s) ~= "number" then return nil end
        total = total + s
    end
    local gap = clamp(resolveSpacing(spec.gap))
    total = total + math.max(0, #children - 1) * gap

    local pad = normalizePadding(spec.padding)
    if localAxis == axis and axis == "vertical" then
        total = total + pad.top + pad.bottom
    elseif localAxis == axis and axis == "horizontal" then
        total = total + pad.left + pad.right
    end
    return total
end

local function layoutStack(specOrSlot, parentRect, children, placements, config, index, containerId)
    local inner = applyPadding(parentRect, specOrSlot.padding)
    local layout = specOrSlot.layout or "vertical"
    local axis = (layout == "horizontal") and "horizontal" or (layout == "fill" and "fill" or "vertical")

    if axis == "fill" then
        for _, childId in ipairs(children) do
            layoutContainer(childId, inner, placements, config, index, false)
        end
        return
    end

    local along = (axis == "vertical") and inner.height or inner.width
    local gap = clamp(resolveSpacing(specOrSlot.gap))
    local fixedSum, flexCount, contentSum = 0, 0, 0
    local sizes = {}
    for _, childId in ipairs(children) do
        local cspec = specFor(config, childId)
        local s = cspec and getAlong(cspec, axis, childId)
        if s == "content" then
            s = measureContent(childId, axis, config, index) or "fill"
        end
        if s == nil or s == "fill" then
            flexCount = flexCount + 1
            sizes[#sizes + 1] = "fill"
        else
            sizes[#sizes + 1] = s
            fixedSum = fixedSum + s
            contentSum = contentSum + s
        end
    end
    local gapTotal = math.max(0, #children - 1) * gap
    local flexAvail = math.max(0, along - fixedSum - gapTotal)

    -- Over-spec warning: fixed children sum + gaps exceed available space.
    -- Children will overflow past the container edge. Drop a fixed width or
    -- split the row. Dedupe per-Compute so we don't spam each refresh.
    if axis == "horizontal" and (fixedSum + gapTotal) > along + 1 then
        Layout._overSpecWarned = Layout._overSpecWarned or {}
        local key = (containerId or "?") .. "|" .. tostring(along)
        if not Layout._overSpecWarned[key] then
            Layout._overSpecWarned[key] = true
            local printer = _G and _G.print or function() end
            printer(string.format(
                "|cffff5555[VFN Layout] over-spec in %q: %dpx available but children need %dpx (fixed=%d, gap=%d, %d flex). Drop a fixed width or split the row.|r",
                containerId or "(unknown)", math.floor(along + 0.5),
                math.floor(fixedSum + gapTotal + 0.5), math.floor(fixedSum + 0.5),
                math.floor(gapTotal + 0.5), flexCount))
        end
    end
    local flexSize = flexCount > 0 and (flexAvail / flexCount) or 0

    local cursor = (axis == "vertical") and inner.y or inner.x
    -- align="right" only meaningful when the cluster doesn't already fill the
    -- slot. With flex children, those absorb the slack and natural left-anchor
    -- already produces the right result; applying the shift would overflow.
    if specOrSlot.align == "right" and axis == "horizontal" and flexCount == 0 then
        cursor = inner.x + inner.width - (contentSum + gapTotal)
    end
    for i, childId in ipairs(children) do
        local size = sizes[i] == "fill" and flexSize or sizes[i]
        local cspec = specFor(config, childId)
        local crossSize = cspec and getCross(cspec, axis)

        local childRect
        if axis == "vertical" then
            local w = inner.width
            local x = inner.x
            if type(crossSize) == "number" then
                w = crossSize
                x = inner.x + (inner.width - w) / 2  -- center horizontally
            end
            childRect = rect(x, cursor, w, size)
        else
            local h = inner.height
            local y = inner.y
            if type(crossSize) == "number" then
                h = crossSize
                y = inner.y + (inner.height - h) / 2  -- center vertically
            end
            childRect = rect(cursor, y, size, h)
        end

        layoutContainer(childId, childRect, placements, config, index, false)
        cursor = cursor + size + gap
    end
end

-- Container layout -----------------------------------------------------------

layoutContainer = function(id, parentRect, placements, config, index, isPanel)
    placements[id] = parentRect
    local spec = specFor(config, id)
    if not spec then return end

    if isPanel then
        local slots = getPanelSlots(spec)
        local slotRects = computeSlotRects(parentRect, slots)
        local panelChildren = index[id] or {}

        for slotName, slotSpec in pairs(slots) do
            local slotRect = slotRects[slotName]
            if slotRect then
                placements[id .. "." .. slotName] = slotRect
                local children = panelChildren[slotName] or {}
                layoutStack(slotSpec, slotRect, children, placements, config, index,
                            id .. "." .. slotName)
            end
        end
        return
    end

    -- Non-panel: standard stack/fill of all children. If the section has
    -- chrome, reset child coords to (0, 0, w, h) -- children are parented to
    -- the section frame, not the enclosing panel, so SetPoint must be
    -- section-relative (mirrors how panel slot rects work).
    --
    -- `~= nil` so the `inset` sentinel value (CHROME_TEMPLATES["inset"] = false,
    -- meaning "plain Frame, no template inheritance") is still recognised --
    -- otherwise widgets inside an inset section would be section-parented but
    -- get panel-relative placements, anchoring them outside the section rect.
    local slots = index[id] or {}
    local children = slots.body or {}
    if spec.chrome and CHROME_TEMPLATES[spec.chrome] ~= nil then
        local localRect = rect(0, 0, parentRect.width, parentRect.height)
        layoutStack(spec, localRect, children, placements, config, index, id)
    else
        layoutStack(spec, parentRect, children, placements, config, index, id)
    end
end

-- Public API -----------------------------------------------------------------

function Layout:Compute(config, ctx)
    config = config or VFN.LayoutConfig
    if not config then error("Layout:Compute: no config (pass one or set VFN.LayoutConfig)", 2) end
    ctx = ctx or {}
    local view = ctx.view or config.window.defaultView
    local cells = computeWindowCells(config, view, ctx)

    local placements = {}
    local index = buildChildIndex(config, view)

    -- Reset over-spec warning cache so we re-evaluate per Compute pass (after
    -- a view swap or panel-vis change the geometry may differ).
    Layout._overSpecWarned = nil
    -- Intrinsics for `width = "auto"` / `height = "auto"` widgets, harvested
    -- by the caller (MainFrame) from each widget's _intrinsicWidth/Height.
    Layout._intrinsics = ctx.intrinsics

    for panelId, panelSpec in pairs(config.panels or {}) do
        local cellName = panelSpec.cell and panelSpec.cell[view] or nil
        local visible = ctx.panelVisible == nil or ctx.panelVisible[panelId] ~= false
        local cellRect = cellName and cells[cellName] or nil
        if cellName and cellRect and visible then
            layoutContainer(panelId, cellRect, placements, config, index, true)
        else
            placements[panelId] = nil
        end
    end

    return placements
end

local function rectsEqual(a, b)
    if not a or not b then return false end
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height
end

local function ApplyOne(widget, region)
    if not widget or not region then return end
    -- Diffing stub: skip if the rect is identical to the last applied. Cheap
    -- win for full-Refresh-on-every-state-change patterns; foundation for a
    -- proper reactive-update layer later (compare prev placements -> only
    -- touch widgets whose rects changed).
    if rectsEqual(widget._lastRect, region) then return end
    widget._lastRect = { x = region.x, y = region.y, width = region.width, height = region.height }

    if widget.ApplyLayout then widget:ApplyLayout(region); return end
    if widget.ClearAllPoints then widget:ClearAllPoints() end
    if widget.SetPoint then widget:SetPoint("TOPLEFT", region.x, -region.y) end
    if widget.SetSize then widget:SetSize(region.width, region.height) end

    -- Hook for animation / transition layer (no-op today). Surfaces or themes
    -- can attach :OnLayoutChanged(rect) to a widget to react to placement.
    if widget.OnLayoutChanged then
        local ok, err = pcall(widget.OnLayoutChanged, widget, region)
        if not ok then
            local printer = _G and _G.print or function() end
            printer("|cffff5555[VFN] OnLayoutChanged error: " .. tostring(err) .. "|r")
        end
    end
end

local function SetVisible(widget, visible)
    if not widget then return end
    if visible then if widget.Show then widget:Show() end
    else if widget.Hide then widget:Hide() end end
end

function Layout:Apply(rootFrame, placements)
    if not rootFrame or not placements then return end

    for panelId, panel in pairs(rootFrame.panels or {}) do
        local r = placements[panelId]
        if r then ApplyOne(panel, r); SetVisible(panel, true)
        else SetVisible(panel, false) end
    end

    -- Position chromed section frames at their section's panel-relative rect.
    -- (Their child widgets get section-relative placements via layoutContainer.)
    for sectionId, sectionFrame in pairs(rootFrame.sections or {}) do
        local r = placements[sectionId]
        if r then ApplyOne(sectionFrame, r); SetVisible(sectionFrame, true)
        else SetVisible(sectionFrame, false) end
    end

    -- Position chromed panel-slot frames at their slot's panel-relative
    -- rect (placements[panelId..".slotName"]). Pure backdrop -- widgets
    -- inside the slot still parent to the panel.
    for slotKey, chromeFrame in pairs(rootFrame.slotChromes or {}) do
        local r = placements[slotKey]
        if r then
            ApplyOne(chromeFrame, r); SetVisible(chromeFrame, true)
            -- Deferred skinner application -- runs ONCE per slot chrome, the
            -- first time the frame has a real rect. See BuildAll's
            -- chrome._pendingSkin assignment for why.
            if chromeFrame._pendingSkin and VFN.Theme and VFN.Theme.Register then
                VFN.Theme:Register(chromeFrame, chromeFrame._pendingSkin)
                chromeFrame._pendingSkin = nil
            end
        else SetVisible(chromeFrame, false) end
    end

    for widgetId, widget in pairs(rootFrame.widgets or {}) do
        local r = placements[widgetId]
        if r then ApplyOne(widget, r); SetVisible(widget, true)
        else SetVisible(widget, false) end
    end
end

-- Build phase ----------------------------------------------------------------

local function findEnclosingPanel(id, config)
    local visited = {}
    local cursor = id
    while cursor and not visited[cursor] do
        visited[cursor] = true
        if config.panels and config.panels[cursor] then return cursor end
        local spec = (config.sections and config.sections[cursor])
                  or (config.widgets and config.widgets[cursor])
        cursor = spec and spec["in"] or nil
    end
    return nil
end

-- Walks up the in-chain returning the FIRST chromed section (or panel) that
-- encloses the widget. Used to determine widget parent: chromed sections
-- bear a real Frame and become widget parents; ordinary sections are virtual
-- and their child widgets parent through to the enclosing panel.
local function findEnclosingContainer(id, config)
    local visited = {}
    local cursor = (config.widgets and config.widgets[id]) and config.widgets[id]["in"] or nil
    while cursor and not visited[cursor] do
        visited[cursor] = true
        if config.panels and config.panels[cursor] then return cursor, "panel" end
        local sectionSpec = config.sections and config.sections[cursor]
        -- Note: `CHROME_TEMPLATES[chrome]` may be `false` (the `inset` sentinel
        -- meaning "plain Frame, no template inheritance"). Use `~= nil` so we
        -- recognise the section as a valid widget container in that case --
        -- otherwise widgets inside an inset section would walk past it and
        -- end up parented to the enclosing panel with panel-relative coords.
        if sectionSpec and sectionSpec.chrome and CHROME_TEMPLATES[sectionSpec.chrome] ~= nil then
            return cursor, "section"
        end
        cursor = sectionSpec and sectionSpec["in"] or nil
    end
    return nil, nil
end

function Layout:BuildAll(rootFrame, config)
    if not rootFrame then return end
    config = config or VFN.LayoutConfig or {}
    rootFrame.panels = rootFrame.panels or {}
    rootFrame.widgets = rootFrame.widgets or {}
    rootFrame.sections = rootFrame.sections or {}

    local Registry = VFN.LayoutRegistry
    if not Registry or not Registry.Build then return end

    for panelId, panelSpec in pairs(config.panels or {}) do
        -- defaultEnabled = false skips construction entirely (A/B flags hook).
        if panelSpec.defaultEnabled ~= false and not rootFrame.panels[panelId] then
            local panel = Registry:Build(panelSpec.kind or "panel", rootFrame, panelSpec)
            if panel then
                panel.id = panelId
                rootFrame.panels[panelId] = panel
            end
        end
    end

    -- Build chrome frames for sections that opted in (`chrome = "card"|"inset"|...`).
    -- The frame parents to the enclosing panel and becomes the parent for any
    -- widgets inside the section. Coords for those widgets become section-
    -- relative (handled in layoutContainer).
    --
    -- Theme tinting: Blizzard chrome templates ship with their own bg textures
    -- (brown/wood for older templates, slate for modern ones). We tint the
    -- chrome's internal .Bg via theme tokens so the section reads with the
    -- rest of the addon palette instead of bleeding through.
    local CHROME_BG_TOKEN = {
        card    = "surface.panel_soft",  -- recessed darker than panel so cards read distinct
        tooltip = "surface.panel_soft",
        inset   = "surface.sunken",
    }
    if CreateFrame then
        for sectionId, sectionSpec in pairs(config.sections or {}) do
            local chrome = sectionSpec.chrome
            local hasChrome = chrome ~= nil and CHROME_TEMPLATES[chrome] ~= nil
            local template = hasChrome and CHROME_TEMPLATES[chrome] or nil
            -- `template == false` means "create plain Frame, no inheritance"
            -- (used by `inset` so we can paint our own sunken look without
            -- fighting Blizzard's NineSlice borders).
            local inheritsFrom = (type(template) == "string") and template or nil
            if hasChrome and not rootFrame.sections[sectionId] then
                local panelId = findEnclosingPanel(sectionId, config)
                local panelFrame = panelId and rootFrame.panels[panelId] or rootFrame
                local sectionFrame = CreateFrame("Frame", nil, panelFrame, inheritsFrom)
                if sectionFrame then
                    sectionFrame.id = sectionId
                    rootFrame.sections[sectionId] = sectionFrame
                    -- Create a BACKGROUND-layer-1 texture and route paint
                    -- through Theme.Skinners.SectionBgTint. The skinner reads
                    -- `tex._vfnBgToken` for the surface token to look up so a
                    -- single Skinner handles all chrome bg variants. Sits ON
                    -- TOP of Blizzard template defaults so NineSlice borders
                    -- and mismatched template bgs can't bleed through.
                    local bgToken = CHROME_BG_TOKEN[chrome]
                    if bgToken and sectionFrame.CreateTexture then
                        local tint = sectionFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
                        if tint then
                            if tint.SetAllPoints then tint:SetAllPoints() end
                            if VFN.Theme and VFN.Theme.Register then
                                VFN.Theme:Register(tint, "SectionBgTint", { token = bgToken })
                            end
                            sectionFrame._vfnBgTint = tint
                        end
                    end
                end
            end
        end
    end

    -- Build chrome frames for panel SLOTS that opted in (`chrome = "header"`
    -- or other Theme.Skinners key). These are pure backdrop frames -- widgets
    -- in the slot still parent to the panel as before. The chrome frame
    -- sits at a LOWER frame level so widgets render on top. Used to give
    -- panel headers a distinct background from the panel body.
    rootFrame.slotChromes = rootFrame.slotChromes or {}
    if CreateFrame then
        for panelId, panelSpec in pairs(config.panels or {}) do
            local panelFrame = rootFrame.panels[panelId]
            if panelFrame and panelSpec.slots then
                for slotName, slotSpec in pairs(panelSpec.slots) do
                    local skinName = slotSpec.chrome
                    local key = panelId .. "." .. slotName
                    if skinName and not rootFrame.slotChromes[key] then
                        local chrome = CreateFrame("Frame", nil, panelFrame, "BackdropTemplate")
                        if chrome then
                            -- Sit BEHIND widgets that get added later. Lower
                            -- frame level keeps widget click-handling intact.
                            if chrome.SetFrameLevel and panelFrame.GetFrameLevel then
                                chrome:SetFrameLevel(panelFrame:GetFrameLevel())
                            end
                            -- DEFER skinner application until after the first
                            -- Layout:Apply has sized the chrome frame. Running
                            -- the skinner at zero size lets CreateTexture-based
                            -- skinners (PanelHeader) anchor SetAllPoints into
                            -- a 0x0 rect and the bg never paints until the
                            -- next refresh -- visible as a header flicker.
                            chrome._pendingSkin = skinName
                            rootFrame.slotChromes[key] = chrome
                        end
                    end
                end
            end
        end
    end

    for widgetId, widgetSpec in pairs(config.widgets or {}) do
        if widgetSpec.defaultEnabled ~= false and not rootFrame.widgets[widgetId] then
            -- Walk up: stops at the first chromed section OR enclosing panel.
            -- Widget's parent is whichever real Frame is closest.
            local containerId, containerKind = findEnclosingContainer(widgetId, config)
            local parent
            if containerKind == "section" then
                parent = rootFrame.sections[containerId] or rootFrame
            else
                parent = (containerId and rootFrame.panels[containerId]) or rootFrame
            end
            local widget = Registry:Build(widgetSpec.kind, parent, widgetSpec)
            if widget then
                widget.id = widgetId
                rootFrame.widgets[widgetId] = widget
                if widgetSpec.themeOverride and VFN.Theme and VFN.Theme.RegisterVariant then
                    VFN.Theme:RegisterVariant(widget, widgetSpec.kind, widgetSpec.themeOverride)
                end
            end
        end
    end
end

-- Validation -- catches typos in `in`, `slot`, `kind`, `cell`. --------------

function Layout:Validate(config)
    config = config or VFN.LayoutConfig or {}
    local errors = {}
    local Registry = VFN.LayoutRegistry

    local function err(msg) errors[#errors + 1] = msg end

    -- Validate window shape: missing height / mode / mode.width would silently
    -- become 0 at runtime without these checks (now that we removed defensive
    -- defaults). Catch them at startup instead.
    local windowCfg = config.window
    if not windowCfg then
        err("config.window is missing")
    else
        if not windowCfg.views or type(windowCfg.views) ~= "table" then
            err("config.window.views must be a table")
        else
            if not windowCfg.defaultView then
                err("config.window.defaultView is required")
            elseif not windowCfg.views[windowCfg.defaultView] then
                err(("config.window.defaultView = %q does not exist in window.views"):format(tostring(windowCfg.defaultView)))
            end
            for viewName, viewSpec in pairs(windowCfg.views) do
                if type(viewSpec.width) ~= "number" then
                    err(("config.window.views.%s.width must be a number"):format(viewName))
                end
                if type(viewSpec.height) ~= "number" then
                    err(("config.window.views.%s.height must be a number"):format(viewName))
                end
                if not viewSpec.columns then
                    err(("config.window.views.%s.columns is required"):format(viewName))
                end
                if not viewSpec.rows then
                    err(("config.window.views.%s.rows is required"):format(viewName))
                end
            end
        end
    end

    -- Index containers (panels, sections) for `in` resolution.
    local containerIds = {}
    for id in pairs(config.panels or {}) do containerIds[id] = "panel" end
    for id in pairs(config.sections or {}) do containerIds[id] = "section" end

    -- Per-panel slot allow-list.
    local panelSlots = {}
    for id, spec in pairs(config.panels or {}) do
        panelSlots[id] = { body = true }
        for slotName in pairs(spec.slots or {}) do
            panelSlots[id][slotName] = true
        end
    end

    -- Validate panels.
    for id, spec in pairs(config.panels or {}) do
        if spec.kind and Registry and Registry.Get and not Registry:Get(spec.kind) then
            err(("panel %q: kind %q has no factory"):format(id, spec.kind))
        end
        for view, cellName in pairs(spec.cell or {}) do
            local viewSpec = (config.window and config.window.views or {})[view]
            if not viewSpec then
                err(("panel %q: cell view %q does not exist in window.views"):format(id, view))
            elseif not (viewSpec.cells and viewSpec.cells[cellName]) then
                err(("panel %q: cell %q does not exist in window.views.%s.cells"):format(id, cellName, view))
            end
        end
    end

    -- Validate sections.
    for id, spec in pairs(config.sections or {}) do
        local parent = spec["in"]
        if not parent then
            err(("section %q: missing `in` field"):format(id))
        elseif not containerIds[parent] then
            err(("section %q: `in` = %q does not resolve to a panel or section"):format(id, parent))
        elseif spec.slot then
            if containerIds[parent] == "panel" and not panelSlots[parent][spec.slot] then
                err(("section %q: slot %q not declared on panel %q"):format(id, spec.slot, parent))
            elseif containerIds[parent] == "section" then
                err(("section %q: slot %q is ignored because parent %q is a section, not a panel"):format(id, spec.slot, parent))
            end
        end
    end

    -- Kinds whose construction requires a `font` field on the spec.
    local TEXT_BEARING_KINDS = {
        label = true, labelDim = true, labelStatus = true,
        button = true, editbox = true,
        chip = true,  -- chip has a label
    }

    -- Validate widgets.
    for id, spec in pairs(config.widgets or {}) do
        if not spec.kind then
            err(("widget %q: missing `kind` field"):format(id))
        elseif Registry and Registry.Get and not Registry:Get(spec.kind) then
            err(("widget %q: kind %q has no factory"):format(id, spec.kind))
        end
        local parent = spec["in"]
        if not parent then
            err(("widget %q: missing `in` field"):format(id))
        elseif not containerIds[parent] then
            err(("widget %q: `in` = %q does not resolve to a panel or section"):format(id, parent))
        elseif spec.slot then
            if containerIds[parent] == "panel" and not panelSlots[parent][spec.slot] then
                err(("widget %q: slot %q not declared on panel %q"):format(id, spec.slot, parent))
            elseif containerIds[parent] == "section" then
                err(("widget %q: slot %q is ignored because parent %q is a section, not a panel"):format(id, spec.slot, parent))
            end
        end
        -- Text-bearing widgets must declare a font role. Theme:GetFont(role)
        -- resolves it; missing -> default Blizzard font (and a typo would be
        -- silent). Validation forces explicit declaration.
        if spec.kind and TEXT_BEARING_KINDS[spec.kind] and not spec.font then
            err(("widget %q: kind %q is text-bearing and requires a `font` role"):format(id, spec.kind))
        end

        -- Scrollboxes that reference a rowKind must resolve to a registered
        -- VFN.Rows entry with both shape (font, height) and behaviour
        -- (factory OR deriveText). Scrollboxes without rowKind require
        -- options.rowHeight inline.
        if spec.kind == "scrollbox" then
            local opts = spec.options or {}
            if opts.rowKind then
                local def = VFN.Rows and VFN.Rows.Get and VFN.Rows:Get(opts.rowKind) or nil
                if not def then
                    err(("widget %q: scrollbox rowKind %q not registered in VFN.Rows"):format(id, opts.rowKind))
                end
            elseif not opts.rowHeight then
                err(("widget %q: scrollbox without rowKind requires options.rowHeight"):format(id))
            end
        end
    end

    return errors
end

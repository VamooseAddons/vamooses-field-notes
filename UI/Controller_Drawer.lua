-- VFN.DrawerController
--
-- Behaviour layer for the drawer panel:
--   - paints pins onto drawerPanel.mapBody from the selected set's entries
--   - updates drawer panel header (map name + pin count)
--
-- The map body, current-card and apply-log frames are spec-built by the
-- layout engine. DrawerController never creates them; it just paints pins
-- and pushes header text.

VFN = VFN or {}
VFN.DrawerController = VFN.DrawerController or {}

local DrawerController = VFN.DrawerController
local CH = VFN.ControllerHelpers
local W = CH.UI.W

-- Pin sizing matches VPP's MapDrawer:
--   PIN_SIZE_PX = visible dot diameter
--   PIN_HIT_PX  = mouse hit area (slightly larger so hover/click feels right)
--   PIN_LABEL_PX = font size for the index number drawn inside the dot
-- All sized in canvas-coords / canvasScale at render time so they keep the
-- same screen-pixel size regardless of map zoom.
local PIN_SIZE_PX  = 18
local PIN_HIT_PX   = 22
local PIN_LABEL_PX = 11

-- Row behaviour for the apply log scrollbox. Static lines, no onClick.
-- Selectors.BuildApplyLogItems supplies { line, prefix, empty } per item;
-- deriveText composes the visible string. Empty-state placeholder shows
-- without the relative-time prefix.
VFN.Rows:Register("applyLogRow", {
    font   = "small",
    height = 18,
    deriveText = function(ed)
        if not ed then return "" end
        if ed.empty then return ed.line end
        if ed.prefix and ed.prefix ~= "" then
            return ed.prefix .. " - " .. ed.line
        end
        return ed.line
    end,
    -- Log entries don't have a stable id; use the `at` timestamp + line
    -- text as a composite identity. Two identical lines logged at the
    -- same second are treated as the same row -- acceptable for an
    -- append-only debug log.
    key = function(ed)
        if not ed then return "?" end
        return tostring(ed.at or "?") .. ":" .. tostring(ed.line or "")
    end,
})

local function HideDots(body)
    for _, dot in ipairs(body.dots or {}) do
        if dot.Hide then dot:Hide() end
    end
end

-- Lazily fetch / construct the Nth pin in the body's pool. The Frame +
-- Texture + FontString construction lives in VFN.UI:MapPin (Components); this
-- function only manages the pool and the controller-owned bits (hover script,
-- frame level, reparenting on map re-render).
local function ensurePin(body, parent, n)
    local pin = body.dots[n]
    if pin then
        if pin.SetParent and pin:GetParent() ~= parent then pin:SetParent(parent) end
        return pin
    end
    pin = VFN.UI and VFN.UI.MapPin and VFN.UI:MapPin(parent) or nil
    if not pin then return nil end

    if pin.SetFrameLevel and parent.GetFrameLevel then
        pin:SetFrameLevel(parent:GetFrameLevel() + 10)  -- above map textures
    end
    -- Hover affordance: scale the dot up 1.4x while hovered.
    pin:SetScript("OnEnter", function(self)
        if self._dot and self._pinSize then
            self._dot:SetSize(self._pinSize * 1.4, self._pinSize * 1.4)
        end
    end)
    pin:SetScript("OnLeave", function(self)
        if self._dot and self._pinSize then
            self._dot:SetSize(self._pinSize, self._pinSize)
        end
    end)
    -- Tooltip: function-form def so the engine re-evaluates pin._data on
    -- each hover (dot data updates between hovers as the layer reconfigures).
    -- TooltipEngine HookScripts on top of the scale-OnEnter above; both fire.
    VFN.TooltipEngine:Attach(pin, function(self)
        local d = self._data
        if not d then return nil end
        local def = {
            extraLines = {
                {
                    text = string.format("%s  %.1f, %.1f", d.mapName or "", d.rawX or 0, d.rawY or 0),
                    r = 0.7, g = 0.7, b = 0.7,
                },
            },
        }
        if d.label and d.label ~= "" then def.title = d.label end
        return def
    end)
    body.dots[n] = pin
    return pin
end

function DrawerController:Refresh(rootFrame, ctx)
    ctx = ctx or {}
    if not ctx.visible then return end
    local body = W(rootFrame, "drawerPanel.mapBody")
    local drawerPanel = rootFrame.panels and rootFrame.panels.drawerPanel
    if not (body and drawerPanel) then return end

    body.dots = body.dots or {}
    HideDots(body)

    local set = ctx.set
    local key = ctx.groupKey
    local entries = (set and set.entries) or {}
    local count, groupName, displayMapID = 0, nil, nil

    -- Find the first matching entry's mapID so we can render its art.
    for _, entry in ipairs(entries) do
        local match = (not key) or VFN.Selectors.GetEntryGroupKey(entry) == key
        if match then
            displayMapID = displayMapID or entry.coordMapID
            if not groupName then
                groupName = VFN.Selectors.GetEntryGroupName(entry)
            end
        end
    end

    -- Render the actual map tiles. Returns the canvas frame + the artMapID
    -- that was actually drawn (may be a parent zone if the entry's mapID
    -- has no art -- cities, micro-zones). Pins go on the canvas so their
    -- positions stay correct under SetScale.
    local canvas, artMapID
    if displayMapID and VFN.MapRenderer and VFN.MapRenderer.Render then
        canvas, artMapID = VFN.MapRenderer:Render(body, displayMapID)
    end
    if not canvas and VFN.MapRenderer and VFN.MapRenderer.Clear then
        VFN.MapRenderer:Clear(body)
    end
    -- Pin parent: prefer canvas when we have one (so pins move with the map);
    -- fall back to body when no map art is available. ensureDot reparents
    -- pooled dots as needed.
    local pinHost = canvas or body
    local width  = pinHost.GetWidth  and pinHost:GetWidth()  or 0
    local height = pinHost.GetHeight and pinHost:GetHeight() or 0
    -- Canvas is scaled (~0.3 to fit the drawer). Sizes set on pin frames are
    -- in canvas-local coords, so dividing by the canvas scale keeps the dot
    -- at PIN_SIZE_PX actual screen pixels regardless of zoom level.
    local hostScale = (pinHost.GetScale and pinHost:GetScale()) or 1
    if hostScale <= 0 then hostScale = 1 end
    local visibleSize = PIN_SIZE_PX / hostScale
    local hitSize     = PIN_HIT_PX  / hostScale

    -- Selected entry index drives the pin highlight. Read from session UI
    -- (same source as the coord row badge styling).
    local selectedEntryIndex = CH.Mechanics.GetUI().selectedEntryIndex
    -- Pin dot colour is painted by Theme.Skinners.PinDot via the selected
    -- flag stashed on each dot. Label colour is still per-pin (selected
    -- pin's dot is amber/warning so the label switches to a dark surface
    -- colour for contrast; default pins use inverse text).
    local labelOnDefault  = VFN.Theme:GetColor("text.inverse")
    local labelOnSelected = VFN.Theme:GetColor("surface.canvas")
    local SELECTED_SIZE_MULT = 1.5

    for entryIdx, entry in ipairs(entries) do
        local match = (not key) or VFN.Selectors.GetEntryGroupKey(entry) == key
        -- If we walked up to a parent for art, the entry's coords are still
        -- in the original child map's space -- skip them rather than place
        -- them wrongly on the parent map.
        local mapMismatch = (artMapID and entry.coordMapID and entry.coordMapID ~= artMapID)
        if match and entry.x and entry.y and not mapMismatch then
            count = count + 1
            local pin = ensurePin(body, pinHost, count)
            if pin then
                local isSelected = (entryIdx == selectedEntryIndex)
                local sizeMult = isSelected and SELECTED_SIZE_MULT or 1
                local thisHit  = hitSize * sizeMult
                local thisDot  = visibleSize * sizeMult

                pin:ClearAllPoints()
                pin:SetSize(thisHit, thisHit)
                pin:SetPoint("CENTER", pinHost, "TOPLEFT", entry.x * width, -(entry.y * height))
                if pin._dot then
                    pin._dot:SetSize(thisDot, thisDot)
                    VFN.Theme:Register(pin._dot, "PinDot", { selected = isSelected })
                end
                if pin._label then
                    -- Font size in CANVAS units; canvas is scaled by hostScale
                    -- (~0.3). Inflating by 1/hostScale keeps screen-pixel size
                    -- constant. Round to integer -- fractional font sizes
                    -- round inconsistently per character, throwing off
                    -- centring. OUTLINEMONOCHROME gives sharper, more
                    -- predictable glyph metrics than antialiased OUTLINE.
                    local labelPx = math.floor((PIN_LABEL_PX * sizeMult) / hostScale + 0.5)
                    if labelPx < 4 then labelPx = 4 end
                    if pin._label.SetFont then
                        pin._label:SetFont("Fonts\\FRIZQT__.TTF", labelPx, "")
                    end
                    pin._label:SetText(tostring(entryIdx))
                    local lc = isSelected and labelOnSelected or labelOnDefault
                    if lc and pin._label.SetTextColor then
                        pin._label:SetTextColor(lc.r, lc.g, lc.b, 1)
                    end
                end
                pin._pinSize = thisDot
                -- Selected pin renders ABOVE peers so its larger footprint
                -- doesn't get partially obscured by adjacent pins.
                if pin.SetFrameLevel and pinHost.GetFrameLevel then
                    pin:SetFrameLevel(pinHost:GetFrameLevel() + (isSelected and 20 or 10))
                end
                pin._data = {
                    mapName = VFN.Selectors.GetEntryGroupName(entry),
                    rawX    = entry.rawX or (entry.x * 100),
                    rawY    = entry.rawY or (entry.y * 100),
                    label   = entry.label,
                    index   = entryIdx,
                }
                pin:Show()
            end
        end
    end

    -- Drawer title / subtitle / current-card text / setNoteBody / applyLogList
    -- all flow through bindings. The pin painting above is the imperative
    -- side-effect that bindings can't express.
end

VFN.Controllers:Register("drawer", DrawerController)

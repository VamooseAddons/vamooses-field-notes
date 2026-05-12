-- VFN.TooltipEngine
--
-- Drives Blizzard's GameTooltip from declarative `tooltip` fields on
-- WidgetTypes. NOT a custom rendering surface -- we use Blizzard's API
-- exactly as intended. The engine is a thin shorthand that wires
-- OnEnter/OnLeave scripts and translates the tooltip table into
-- GameTooltip method calls.
--
-- Architecture spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 17.3.
--
-- The `tooltip` field on a WidgetType is either:
--   - A table { title, body, anchor, textFn, itemID, hyperlink, extraLines }
--   - A function(self) returning that table
--
-- WidgetTypes registry validates the table shape (see Core/WidgetTypes.lua
-- section "tooltip field shape"). This engine just consumes it.
--
-- Reference: spec section 1.3 (contract-vs-engines principle). The tooltip
-- TEXT is declarative (it's contract); the RENDERING is an engine call.

VFN = VFN or {}
VFN.TooltipEngine = VFN.TooltipEngine or {}

local TE = VFN.TooltipEngine

-- ===== Internal helpers ===================================================

-- Resolve a tooltip definition. Table -> the table. Function -> call it
-- with the widget. Anything else -> nil (no tooltip shown).
local function resolveDef(widget, def)
    if type(def) == "function" then
        local ok, result = pcall(def, widget)
        if not ok or type(result) ~= "table" then return nil end
        return result
    end
    if type(def) == "table" then return def end
    return nil
end

-- Render a resolved tooltip table to GameTooltip.
local function renderTooltip(widget, t)
    local tooltip = _G.GameTooltip
    if not tooltip then return end

    tooltip:SetOwner(widget, t.anchor or "ANCHOR_RIGHT")

    -- Item / hyperlink: Blizzard fills the body. Custom title/body/extras
    -- are appended below.
    if t.itemID then
        if tooltip.SetItemByID then tooltip:SetItemByID(t.itemID) end
    elseif t.hyperlink then
        if tooltip.SetHyperlink then tooltip:SetHyperlink(t.hyperlink) end
    end

    if t.title then
        tooltip:AddLine(t.title)
    end
    if t.body then
        tooltip:AddLine(t.body, 1, 1, 1, true)   -- wrap=true
    end

    if t.extraLines then
        for _, line in ipairs(t.extraLines) do
            if type(line) == "string" then
                tooltip:AddLine(line, 1, 1, 1, true)
            elseif type(line) == "table" then
                tooltip:AddLine(line.text or "",
                    line.r or 1, line.g or 1, line.b or 1,
                    line.wrap ~= false)
            end
        end
    end

    -- textFn: dynamic content function. Called now (at hover time) so the
    -- tooltip can show current state without re-mounting. Returns string
    -- or list of strings/lines.
    if t.textFn then
        local ok, dyn = pcall(t.textFn, widget)
        if ok and dyn then
            if type(dyn) == "string" then
                tooltip:AddLine(dyn, 1, 1, 1, true)
            elseif type(dyn) == "table" then
                for _, line in ipairs(dyn) do
                    if type(line) == "string" then
                        tooltip:AddLine(line, 1, 1, 1, true)
                    end
                end
            end
        end
    end

    tooltip:Show()
end

-- ===== Public API =========================================================

-- Attach tooltip handlers to a widget. Called from the WidgetTypes builder
-- when a WidgetType declares the `tooltip` field. HookScript (not SetScript)
-- so existing OnEnter/OnLeave wiring -- e.g., visual hover state -- isn't
-- clobbered.
function TE:Attach(widget, def)
    if not widget then return end
    if def == nil then return end
    if not widget.HookScript then return end

    widget:HookScript("OnEnter", function(self)
        local resolved = resolveDef(self, def)
        if resolved then renderTooltip(self, resolved) end
    end)
    widget:HookScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
end

-- Manually render a tooltip for a widget. Use for explicit "show tooltip
-- now" cases (e.g., focus on a widget without hover). Caller is responsible
-- for hiding via GameTooltip:Hide().
function TE:Show(widget, def)
    local resolved = resolveDef(widget, def)
    if resolved then renderTooltip(widget, resolved) end
end

-- Hide the current tooltip. Convenience over reaching for the global.
function TE:Hide()
    if _G.GameTooltip then _G.GameTooltip:Hide() end
end

-- VFN.Panels
--
-- Registers the "panel" widget kind. A panel is a chrome container --
-- a Frame whose internal regions (header / body / footer) are declared
-- via slots in LayoutConfig.panels[panelId].slots.
--
-- The panel factory only creates the outer Frame (with theme backdrop). All
-- header content -- title, subtitle, icons, chips, action buttons -- lives
-- in LayoutConfig.widgets with `slot = "header"` and is built/positioned by
-- the layout engine like any other widget.

VFN = VFN or {}
VFN.Panels = VFN.Panels or {}

local function PanelFactory(parent, spec)
    if not CreateFrame then return nil end
    return CreateFrame("Frame", spec.frameName, parent, "BackdropTemplate")
    -- Theme:Register is owned by Layout's buildKind helper (spec section 5);
    -- the kind's `skin = "Frame"` declaration drives paint role assignment.
end

VFN.WidgetTypes:Register("panel", { build = PanelFactory, skin = "Frame" })

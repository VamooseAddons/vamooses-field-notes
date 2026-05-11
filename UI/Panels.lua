-- VFN.Panels
--
-- Registers the "panel" kind with VFN.LayoutRegistry. A panel is a chrome
-- container -- a Frame whose internal regions (header / body / footer) are
-- declared via slots in LayoutConfig.panels[panelId].slots.
--
-- The panel factory only creates the outer Frame (with theme backdrop). All
-- header content -- title, subtitle, icons, chips, action buttons -- lives in
-- LayoutConfig.widgets with `slot = "header"` and is built/positioned by the
-- layout engine like any other widget.
--
-- Future hooks (declared in panel spec, currently no-ops):
--   detachable      bool -- can the panel be detached into a floating window
--   resizable       { width=bool, height=bool } -- can the user drag-resize
--   defaultEnabled  bool -- if false, BuildAll skips this panel

VFN = VFN or {}
VFN.Panels = VFN.Panels or {}
VFN.Panels.HEADER_HEIGHT = 34   -- legacy default; slot spec overrides

local function PanelFactory(parent, spec)
    if not CreateFrame then return nil end

    local panel = CreateFrame("Frame", spec.frameName, parent, "BackdropTemplate")
    VFN.Theme:Register(panel, "Frame")

    -- Stash spec metadata for future hooks (detach, resize). No-op today.
    panel.detachable = spec.detachable == true
    panel.resizable = spec.resizable or { width = false, height = false }

    return panel
end

if VFN.LayoutRegistry and VFN.LayoutRegistry.Register then
    VFN.LayoutRegistry:Register("panel", PanelFactory)
end

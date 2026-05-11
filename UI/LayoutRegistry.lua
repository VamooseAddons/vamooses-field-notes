-- VFN.LayoutRegistry
--
-- Pure dispatch mechanism: a kind -> factory map. The Layout engine calls
-- VFN.LayoutRegistry:Build(kind, parent, spec) when walking the spec tree.
-- This file holds NO widget construction code -- standard kinds are defined
-- in Components.lua, surface-specific kinds (rows etc.) in their owning
-- surface module.
--
-- Factory contract:
--   factory(parent, spec) -> widget
--   `widget` may have a custom :ApplyLayout(rect) method; if present, the
--   engine calls it instead of the default SetPoint/SetSize. Useful for
--   composite widgets (e.g. ScrollBox host that needs to position children).

VFN = VFN or {}
VFN.LayoutRegistry = VFN.LayoutRegistry or { factories = {} }

local Registry = VFN.LayoutRegistry

function Registry:Register(kind, factory)
    if type(kind) ~= "string" or kind == "" then return false end
    if type(factory) ~= "function" then return false end
    self.factories[kind] = factory
    return true
end

function Registry:Get(kind)
    if type(kind) ~= "string" or kind == "" then return nil end
    return self.factories[kind]
end

function Registry:Build(kind, parent, spec)
    local factory = self:Get(kind)
    if not factory then return nil end
    return factory(parent, spec or {})
end

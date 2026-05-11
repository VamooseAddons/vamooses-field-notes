-- VFN.Controllers
--
-- Registry of UI controller modules. A controller binds widgets <-> state for
-- a single panel: it attaches event handlers (OnClick, OnTextChanged, ...)
-- and updates widget content from Store state. Controllers do NOT create or
-- position widgets -- the layout engine does that from spec data.
--
-- Each controller self-registers at file load:
--   VFN.Controllers:Register("stream", VFN.StreamController)
--
-- MainFrame loops controllers calling :Wire(rootFrame) at build time and
-- :Refresh(rootFrame, ctx) on every state change. Standard contract:
--
--   controller:Wire(rootFrame)         -- attach event handlers
--   controller:Refresh(rootFrame, ctx) -- update content from state
--
-- ctx is the same shared table passed to every controller; conventional fields:
--   ctx.state          current Store state
--   ctx.mode           layout mode ("collapsed" | "expanded")
--   ctx.hasSelection   bool
--   ctx.set            currently selected set (or nil)
--   ctx.visible        bool (for the drawer in particular)
--   ctx.groupKey       currently selected group key (or nil)
--
-- Adding a new controller never touches MainFrame -- just self-register.

VFN = VFN or {}
VFN.Controllers = VFN.Controllers or { byName = {}, ordered = {} }

local Controllers = VFN.Controllers

function Controllers:Register(name, controller)
    if type(name) ~= "string" or name == "" then return false end
    if type(controller) ~= "table" then return false end
    if not self.byName[name] then
        self.ordered[#self.ordered + 1] = name
    end
    self.byName[name] = controller
    return true
end

function Controllers:Get(name)
    return self.byName[name]
end

function Controllers:Each(fn)
    -- Iterate in registration order so behaviour wiring is deterministic.
    for _, name in ipairs(self.ordered) do
        local controller = self.byName[name]
        if controller then fn(name, controller) end
    end
end

function Controllers:WireAll(rootFrame)
    self:Each(function(_, controller)
        if controller.Wire then controller:Wire(rootFrame) end
    end)
end

function Controllers:RefreshAll(rootFrame, ctx)
    self:Each(function(_, controller)
        if controller.Refresh then controller:Refresh(rootFrame, ctx) end
    end)
end

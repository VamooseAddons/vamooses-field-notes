-- VFN.BindingEngine
--
-- Declarative state-to-widget data flow. Widget specs in LayoutConfig can
-- declare a `binding` field that names one or more selectors; the engine
-- walks every bound widget on each refresh, calls the selector, and pushes
-- the value through a kind-specific dispatcher.
--
-- Binding shape (per widget spec):
--   binding = "selector.name"                       -- single scalar -> default field
--   binding = "static:Literal text"                 -- string literal, no selector call
--   binding = { value = "x", label = "static:Y" }   -- multi-field, kind-specific names
--
-- Kind-specific field names (the dispatcher routes to widget methods):
--   label / fieldLabel                  -> { text }   (variant via spec.variant)
--   button                              -> { text, enabled, active }
--   editbox                             -> { text }
--   chip                                -> { text, status }
--   statCard                            -> { value, label }
--   scrollbox                           -> { items }
--
-- Rules:
--   - A widget MUST be either fully bound (declarative) OR fully imperative
--     (controller's Refresh pushes its values). Never both -- the engine
--     stamps `_vfnBound = true` on bound widgets; controllers should never
--     SetText/SetItems on those.
--   - Selectors are pure: `function(state, ctx) -> value`. No side effects.
--   - "static:..." prefix resolves to the literal substring without a
--     selector lookup. Useful for fixed labels (COORDS, MAP, STATUS, etc).

VFN = VFN or {}
VFN.BindingEngine = VFN.BindingEngine or {}

local Engine = VFN.BindingEngine

-- Kind-specific dispatchers + default scalar-binding fields now live on
-- the WidgetType records themselves (VFN.WidgetTypes -> kind.dispatch).
-- See UI/Components.lua for the registrations; see Core/WidgetTypes.lua
-- for the contract (spec section 3 -- dispatch = { fields, push }).

-- ===== Resolution ==========================================================

-- Resolve one binding value: literal "static:..." OR a registered selector.
local function resolve(spec, state, ctx)
    if type(spec) ~= "string" then return nil end
    if spec:sub(1, 7) == "static:" then return spec:sub(8) end
    return VFN.Selectors:Call(spec, state, ctx)
end

-- Normalise a binding into { fieldName = selectorSpec, ... }. Scalar form
-- ("foo.bar") maps to the kind's default field (dispatch.fields[1]); table
-- form is passed through.
local function normaliseBinding(binding, kind, kindDef)
    if type(binding) == "string" then
        local dispatch = kindDef and kindDef.dispatch or nil
        local field = dispatch and dispatch.fields and dispatch.fields[1] or nil
        if not field then
            error(string.format(
                "binding: kind %q does not accept scalar binding %q -- use the table form",
                tostring(kind), tostring(binding)), 2)
        end
        return { [field] = binding }
    end
    if type(binding) == "table" then return binding end
    return nil
end

-- ===== Public API =========================================================

-- Mark every widget that has a `binding` in the spec. Call once at build time.
-- Sets widget._vfnBound = true and stashes the normalised binding +
-- dispatcher on the widget for fast access during Apply.
function Engine:Build(rootFrame, config)
    if not (rootFrame and rootFrame.widgets and config and config.widgets) then return end
    for id, spec in pairs(config.widgets) do
        local widget = rootFrame.widgets[id]
        if widget and spec.binding then
            local kind = spec.kind
            local kindDef = VFN.WidgetTypes:TryGet(kind)
            local dispatcher = kindDef and kindDef.dispatch and kindDef.dispatch.push or nil
            if not dispatcher then
                error(string.format("binding: kind %q has no dispatch (widget %q)",
                    tostring(kind), tostring(id)), 2)
            end
            widget._vfnBinding    = normaliseBinding(spec.binding, kind, kindDef)
            widget._vfnDispatcher = dispatcher
            widget._vfnBound      = true
        end
    end
end

-- Push current state values to every bound widget. Call from MainFrame's
-- RefreshMainWindow BEFORE controllers' Refresh runs.
function Engine:Apply(rootFrame, state, ctx)
    if not (rootFrame and rootFrame.widgets and state) then return end
    for _, widget in pairs(rootFrame.widgets) do
        if widget._vfnBound and widget._vfnBinding and widget._vfnDispatcher then
            local resolved = {}
            for field, selectorSpec in pairs(widget._vfnBinding) do
                resolved[field] = resolve(selectorSpec, state, ctx)
            end
            widget._vfnDispatcher(widget, resolved)
        end
    end
end

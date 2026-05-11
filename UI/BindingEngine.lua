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
--   label / labelDim / labelStatus     -> { text }
--   button                              -> { text, enabled }
--   editbox                             -> { text }
--   chip                                -> { text, variant }
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

-- Default field per kind. A scalar binding ("library.title") maps to this
-- field; a table binding ({ value = ..., label = ... }) specifies fields
-- explicitly. Widgets whose kind isn't in this table CANNOT use a scalar
-- binding -- they must use the table form.
local KIND_DEFAULT_FIELD = {
    label       = "text",
    labelDim    = "text",
    labelStatus = "text",
    editbox     = "text",
    scrollbox   = "items",
}

-- Kind-specific dispatchers. Each receives (widget, values) where `values`
-- is a table keyed by binding field names. The dispatcher pushes the values
-- to the widget via its concrete API. Missing fields are no-ops (selector
-- returned nil OR field not declared in the binding).
Engine.Dispatchers = {}

function Engine.Dispatchers.label(widget, values)
    if values.text ~= nil and widget.SetText then widget:SetText(tostring(values.text)) end
end
Engine.Dispatchers.labelDim    = Engine.Dispatchers.label
Engine.Dispatchers.labelStatus = Engine.Dispatchers.label
Engine.Dispatchers.fieldLabel  = Engine.Dispatchers.label

function Engine.Dispatchers.button(widget, values)
    if values.text ~= nil then
        if widget.RefreshIntrinsicWidth then
            widget:SetText(tostring(values.text))
            widget:RefreshIntrinsicWidth()
        elseif widget.SetText then
            widget:SetText(tostring(values.text))
        end
    end
    if values.enabled ~= nil and widget.SetEnabled then
        widget:SetEnabled(values.enabled and true or false)
    end
    if values.active ~= nil and widget.SetActive then
        widget:SetActive(values.active and true or false)
    end
end

-- (Legacy kind aliases removed in #10.6. All button shapes -- text, atlas,
--  toggle, close -- ship under one `kind = "button"` with options.atlas /
--  options.activeAtlas / options.close picking the internal shape.)

function Engine.Dispatchers.editbox(widget, values)
    if values.text == nil or not widget.SetText then return end
    -- Skip the SetText if the current widget text already matches the desired
    -- value -- prevents cursor resets and OnTextChanged loops when the user
    -- is mid-typing and a state notify fires.
    local current = widget.GetText and widget:GetText() or nil
    if current ~= tostring(values.text) then
        widget:SetText(tostring(values.text))
        if widget._vfnPlaceholderRefresh then widget._vfnPlaceholderRefresh() end
    end
end

function Engine.Dispatchers.chip(widget, values)
    if values.text ~= nil and widget.SetChipText then widget:SetChipText(tostring(values.text)) end
    -- Chip's data-driven category is `status` (ready / blocked / has_note /
    -- source / default). Different concept from button's design-time variant.
    if values.status ~= nil and widget.SetStatus then widget:SetStatus(values.status) end
end

function Engine.Dispatchers.statCard(widget, values)
    if values.value ~= nil and widget.SetValue then widget:SetValue(tostring(values.value)) end
    if values.label ~= nil and widget.SetLabel then widget:SetLabel(tostring(values.label)) end
end

function Engine.Dispatchers.scrollbox(widget, values)
    if values.items ~= nil and widget.SetItems then
        widget:SetItems(values.items, true)
    end
end

-- ===== Resolution ==========================================================

-- Resolve one binding value: literal "static:..." OR a registered selector.
local function resolve(spec, state, ctx)
    if type(spec) ~= "string" then return nil end
    if spec:sub(1, 7) == "static:" then return spec:sub(8) end
    return VFN.Selectors:Call(spec, state, ctx)
end

-- Normalise a binding into { fieldName = selectorSpec, ... }. Scalar form
-- ("foo.bar") maps to the kind's default field; table form is passed through.
local function normaliseBinding(binding, kind)
    if type(binding) == "string" then
        local field = KIND_DEFAULT_FIELD[kind]
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
            local dispatcher = self.Dispatchers[kind]
            if not dispatcher then
                error(string.format("binding: kind %q has no dispatcher (widget %q)",
                    tostring(kind), tostring(id)), 2)
            end
            widget._vfnBinding    = normaliseBinding(spec.binding, kind)
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

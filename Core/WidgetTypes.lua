-- VFN.WidgetTypes
--
-- Central widget type registry. Architecture spec:
-- Project Documentation/UI_WIDGET_TAXONOMY.md section 3 (contract) + section 5
-- (engines as views) + section 12 (validation).
--
-- Registration is DEFERRED (lazy.nvim / which-key pattern): WidgetTypes:Register
-- enqueues at file-load time; Flush() processes the queue at OnInitialize and
-- runs the validator. This eliminates load-order sensitivity between files
-- that register widget types -- a kind can be registered anywhere in the TOC
-- and the registry is sealed after all modules have loaded.
--
-- The registry is keyed by `kind` (string). Each entry is a WidgetType
-- record: a flat table of optional capability fields per the action
-- taxonomy in section 2. Engines (Layout, Theme, BindingEngine, etc.)
-- read this registry directly -- no query layer.
--
-- See Project Documentation/UI_WIDGET_TAXONOMY.md section 3.7 for the
-- Widget Kind Catalog (Tier A atomic / B composite / C v0.6 new / D
-- specialized / E addon-local).
--
-- Reference patterns:
--   - lazy.nvim deferred queue + spec normalization
--     (LUA_SAMPLES.md section 4)
--   - nvim-cmp duck-typed provider contract
--     (LUA_SAMPLES.md section 5)

VFN = VFN or {}
VFN.WidgetTypes = VFN.WidgetTypes or {
    _queue    = {},                 -- [i] = { kind, def } pre-flush
    _registry = {},                 -- [kind] = normalized def post-flush
    _flushed  = false,
}

local WT = VFN.WidgetTypes

-- ===== Known field set (closed contract, validator-checked) ===============
-- Every key a WidgetType may set. Unknown keys error during validation.
-- Mirrors the contract in spec section 3.

local KNOWN_FIELDS = {
    -- Identity
    extends = true,
    tags    = true,
    key     = true,

    -- Data
    opts    = true,

    -- Construction (required)
    build   = true,

    -- Capability fields (all optional, all nilable)
    skin       = true,
    dispatch   = true,
    measure    = true,
    input      = true,
    slots      = true,
    list       = true,
    lifecycle  = true,
    animations = true,
    rendering  = true,
    persistAt  = true,
    validity   = true,

    -- v0.6 additions
    tooltip    = true,
    resize     = true,
    hover      = true,
    keyboard   = true,

    -- Pool config + destroy path
    pool    = true,
    destroy = true,

    -- initialState(spec) -> table: optional initial Theme.Skinners state.
    -- Called by Layout's buildKind after build; result is passed through
    -- VFN.Theme:Register(widget, kindDef.skin, state). State-bearing kinds
    -- (chip's status) use this to carry per-instance paint state.
    initialState = true,

    -- requiresFont(spec) -> bool: optional predicate. When the WidgetType is
    -- text-bearing in general (button/label/editbox/chip) but specific spec
    -- shapes (icon-only buttons via options.close/atlas) don't render text,
    -- this predicate suppresses the validator's "missing font" requirement.
    -- Layout's validator consults this instead of inspecting spec.options
    -- itself (spec section 5 -- engines query the registry, not internals).
    requiresFont = true,
}

-- ===== Registration (deferred queue) ======================================

-- Register a widget type. Enqueues for processing at Flush time. The kind
-- name is the canonical lookup key.
function WT:Register(kind, def)
    if self._flushed then
        error(("VFN.WidgetTypes:Register(%q) called after Flush()"):format(tostring(kind)), 2)
    end
    if type(kind) ~= "string" or kind == "" then
        error("VFN.WidgetTypes:Register: kind must be a non-empty string", 2)
    end
    if type(def) ~= "table" then
        error(("VFN.WidgetTypes:Register(%q): def must be a table"):format(kind), 2)
    end
    self._queue[#self._queue + 1] = { kind = kind, def = def }
end

-- ===== Validator ==========================================================

-- Per-WidgetType validation. Errors are accumulated and reported together
-- so one bad registration doesn't mask others. Returns an error list
-- (empty on success).
local function validateOne(kind, def, registry, errors)
    local function err(msg)
        errors[#errors + 1] = ("[%s] %s"):format(kind, msg)
    end

    -- 1. build is required and must be a function
    if type(def.build) ~= "function" then
        err("missing required field `build` (must be a function)")
    end

    -- 2. Unknown fields -- closed-contract enforcement
    for k in pairs(def) do
        if not KNOWN_FIELDS[k] then
            err(("unknown field %q (not in the contract; see section 3)"):format(k))
        end
    end

    -- 3. tags must be a list of strings if present
    if def.tags ~= nil then
        if type(def.tags) ~= "table" then
            err("`tags` must be a list of strings")
        else
            for i, t in ipairs(def.tags) do
                if type(t) ~= "string" then
                    err(("`tags[%d]` must be a string, got %s"):format(i, type(t)))
                end
            end
        end
    end

    -- 4. key must be a function if present
    if def.key ~= nil and type(def.key) ~= "function" then
        err("`key` must be a function (spec, ctx) -> string")
    end

    -- 5. dispatch is both-or-neither
    if def.dispatch ~= nil then
        if type(def.dispatch) ~= "table" then
            err("`dispatch` must be a table { fields, push }")
        else
            if type(def.dispatch.fields) ~= "table" then
                err("`dispatch.fields` must be a list of field names")
            end
            if type(def.dispatch.push) ~= "function" then
                err("`dispatch.push` must be a function")
            end
        end
    end

    -- 6. lifecycle: both configure and reset must be functions
    if def.lifecycle ~= nil then
        if type(def.lifecycle) ~= "table" then
            err("`lifecycle` must be a table { configure, reset }")
        else
            if type(def.lifecycle.configure) ~= "function" then
                err("`lifecycle.configure` must be a function")
            end
            if type(def.lifecycle.reset) ~= "function" then
                err("`lifecycle.reset` must be a function")
            end
        end
    end

    -- 7. input.secure.attributes must be a non-empty list of strings
    if def.input and def.input.secure then
        local sec = def.input.secure
        if type(sec) ~= "table" then
            err("`input.secure` must be a table { template, attributes }")
        else
            if type(sec.attributes) ~= "table" or #sec.attributes == 0 then
                err("`input.secure.attributes` must be a non-empty list of strings")
            else
                for i, a in ipairs(sec.attributes) do
                    if type(a) ~= "string" then
                        err(("`input.secure.attributes[%d]` must be a string"):format(i))
                    end
                end
            end
        end
    end

    -- 7b. skin is a string referencing a registered Theme.Skinners entry.
    -- Per spec section 3 + research finding (Roact tag strings, CSS classes,
    -- nui.nvim highlight groups, Compose Modifier vals all share this shape):
    -- the WidgetType declares the paint ROLE by name; the paint function lives
    -- in the Theme.Skinners registry and may be reused by multiple kinds.
    if def.skin ~= nil then
        if type(def.skin) ~= "string" then
            err("`skin` must be a string (paint role name in VFN.Theme.Skinners)")
        elseif VFN.Theme and VFN.Theme.Skinners and not VFN.Theme.Skinners[def.skin] then
            err(("`skin` references unknown paint role %q (not in VFN.Theme.Skinners)"):format(def.skin))
        end
    end

    -- 7c. initialState must be a function if present, and only meaningful
    -- when `skin` is declared (state without a skinner has no consumer).
    if def.initialState ~= nil then
        if type(def.initialState) ~= "function" then
            err("`initialState` must be a function (spec, ctx) -> state table")
        elseif def.skin == nil then
            err("`initialState` is declared but `skin` is not -- state has no consumer")
        end
    end

    -- 7d. requiresFont must be a function if present.
    if def.requiresFont ~= nil and type(def.requiresFont) ~= "function" then
        err("`requiresFont` must be a function(spec) -> bool")
    end

    -- 8. extends references a registered WidgetType AND parent doesn't extend (depth 1)
    if def.extends ~= nil then
        if type(def.extends) ~= "string" then
            err("`extends` must be a string (kind name)")
        elseif not registry[def.extends] then
            err(("`extends` references unregistered kind %q"):format(def.extends))
        elseif registry[def.extends].extends ~= nil then
            err(("`extends` depth must not exceed 1 (parent %q itself extends %q)")
                :format(def.extends, registry[def.extends].extends))
        end
    end

    -- 9. validity must be a function returning boolean
    if def.validity ~= nil and type(def.validity) ~= "function" then
        err("`validity` must be a function(state) -> bool")
    end

    -- 10. destroy required if widget owns event handlers / animations / pool
    if (def.input and def.input.events) or def.animations or def.pool then
        if type(def.destroy) ~= "function" then
            err("`destroy` is required when widget declares input.events, animations, or pool "
                .. "(prevents GC-cycle leaks through C++ frame refs)")
        end
    end

    -- 11. v0.6 tooltip field shape (closed sub-variants)
    if def.tooltip ~= nil then
        local t = def.tooltip
        if type(t) ~= "function" and type(t) ~= "table" then
            err("`tooltip` must be a table OR a function(self) -> table")
        elseif type(t) == "table" then
            -- Validate known sub-keys; unknown keys error.
            local TOOLTIP_FIELDS = {
                title = true, body = true, anchor = true, textFn = true,
                itemID = true, hyperlink = true, extraLines = true,
            }
            for k in pairs(t) do
                if not TOOLTIP_FIELDS[k] then
                    err(("`tooltip.%s` is not a known sub-field (use title/body/anchor/"
                        .. "textFn/itemID/hyperlink/extraLines)"):format(k))
                end
            end
        end
    end

    -- 12. v0.6 resize field shape
    if def.resize ~= nil then
        if type(def.resize) ~= "table" then
            err("`resize` must be a table { grip, minSize, maxSize, persistAt, axes }")
        else
            local r = def.resize
            if r.axes ~= nil and r.axes ~= "horizontal" and r.axes ~= "vertical" and r.axes ~= "both" then
                err("`resize.axes` must be 'horizontal', 'vertical', or 'both'")
            end
            -- Spec section 12 v0.6: grip must reference a sibling/child widget id.
            -- Cross-reference happens at build time in Layout (the registry has
            -- no spec tree at flush time), so the validator only checks string
            -- shape here.
            if r.grip ~= nil and type(r.grip) ~= "string" then
                err("`resize.grip` must be a string widget id")
            end
            -- minSize <= maxSize. Both are either numbers (uniform across axes)
            -- or tables { w = n, h = n } when axes = "both".
            local function checkBound(name, v)
                if v == nil then return nil end
                if type(v) == "number" then return { w = v, h = v }
                elseif type(v) == "table" then
                    if v.w ~= nil and type(v.w) ~= "number" then
                        err(("`resize.%s.w` must be a number"):format(name))
                    end
                    if v.h ~= nil and type(v.h) ~= "number" then
                        err(("`resize.%s.h` must be a number"):format(name))
                    end
                    return { w = v.w, h = v.h }
                else
                    err(("`resize.%s` must be a number or { w, h } table"):format(name))
                end
                return nil
            end
            local minB = checkBound("minSize", r.minSize)
            local maxB = checkBound("maxSize", r.maxSize)
            if minB and maxB then
                if minB.w and maxB.w and minB.w > maxB.w then
                    err("`resize.minSize.w` exceeds `resize.maxSize.w`")
                end
                if minB.h and maxB.h and minB.h > maxB.h then
                    err("`resize.minSize.h` exceeds `resize.maxSize.h`")
                end
            end
        end
    end

    -- 13. v0.6 keyboard.nav shape. Keys must be Blizzard key constants per
    -- spec section 12 v0.6: ESCAPE/UP/DOWN/LEFT/RIGHT/ENTER/TAB/SPACE/HOME/
    -- END/PAGEUP/PAGEDOWN/DELETE/BACKSPACE. The set is the documented
    -- ButtonHandler key namespace used by WoW's keyboard input layer.
    if def.keyboard ~= nil then
        if type(def.keyboard) ~= "table" or type(def.keyboard.nav) ~= "table" then
            err("`keyboard` must be a table { nav = { KEY = fn, ... } }")
        else
            local NAV_KEYS = {
                ESCAPE = true, UP = true, DOWN = true, LEFT = true, RIGHT = true,
                ENTER = true, TAB = true, SPACE = true, HOME = true, END = true,
                PAGEUP = true, PAGEDOWN = true, DELETE = true, BACKSPACE = true,
            }
            for key, handler in pairs(def.keyboard.nav) do
                if type(handler) ~= "function" then
                    err(("`keyboard.nav[%q]` must be a function"):format(tostring(key)))
                elseif not NAV_KEYS[key] then
                    err(("`keyboard.nav` key %q is not a valid Blizzard key constant"
                        .. " (allowed: ESCAPE/UP/DOWN/LEFT/RIGHT/ENTER/TAB/SPACE/"
                        .. "HOME/END/PAGEUP/PAGEDOWN/DELETE/BACKSPACE)"):format(tostring(key)))
                end
            end
        end
    end

    -- 14. hover.children must be a list of strings; hover.floatingCTA must be a table
    if def.hover ~= nil then
        if type(def.hover) ~= "table" then
            err("`hover` must be a table { children?, floatingCTA? }")
        else
            if def.hover.children ~= nil then
                if type(def.hover.children) ~= "table" then
                    err("`hover.children` must be a list of widget ids")
                else
                    -- Each entry must be a string widget id (matches the `tags`
                    -- check at the top of the validator for symmetry).
                    for i, child in ipairs(def.hover.children) do
                        if type(child) ~= "string" then
                            err(("`hover.children[%d]` must be a string widget id"):format(i))
                        end
                    end
                end
            end
            if def.hover.floatingCTA ~= nil then
                local cta = def.hover.floatingCTA
                if type(cta) ~= "table" or type(cta.widget) ~= "string" then
                    err("`hover.floatingCTA` must be a table with `widget` field (kind name)")
                else
                    -- Cross-reference: floatingCTA.widget must be a registered kind
                    if not registry[cta.widget] then
                        err(("`hover.floatingCTA.widget` references unregistered kind %q"):format(cta.widget))
                    end
                end
                if cta and cta.combatSafe ~= nil and type(cta.combatSafe) ~= "boolean" then
                    err("`hover.floatingCTA.combatSafe` must be a boolean")
                end
            end
        end
    end

    -- 15. Pool config
    if def.pool ~= nil then
        if type(def.pool) ~= "table" then
            err("`pool` must be a table { preallocate?, versionKey? }")
        end
    end

    -- NOTE on spec section 12 "v0.6 scroll API checks":
    -- The spec requires the validator to forbid the legacy scroll template
    -- (the one named in CLAUDE.md rule #29) inside `build` functions. Lua
    -- closures are opaque at validation time -- we cannot introspect the
    -- template name passed to CreateFrame inside a build closure body.
    -- Enforcement is therefore tooling-based, not validator-based:
    --   1. A repo-level PreToolUse hook blocks the legacy template literal
    --      from being written into ANY .lua file (catches the introduction
    --      at source -- stronger than a runtime validator check).
    --   2. CLAUDE.md rule #29 + spec section 3.7 forbid the pattern for lists
    --      and free-scrolling content.
    -- Together these provide the same guarantee the spec describes, with
    -- write-time enforcement that beats load-time validation.
end

-- ===== Normalization (apply extends inheritance) ==========================

-- Apply `extends` field-merge. Parent's `opts.defaults` deep-merges into
-- child's. Function fields (build, skin, dispatch.push, etc.) wholly replace
-- when the child declares them; otherwise inherit from parent.
local function normalizeWithExtends(def, parent)
    if not parent then return def end

    local result = {}
    -- Copy parent fields first
    for k, v in pairs(parent) do result[k] = v end
    -- Child wins on field-by-field
    for k, v in pairs(def) do
        if k == "opts" and type(v) == "table" and type(parent.opts) == "table" then
            result.opts = VFN.TableUtils.DeepMerge("force", parent.opts, v)
        else
            result[k] = v
        end
    end
    -- Clear `extends` on the normalized child so engines don't see it
    result.extends = nil
    return result
end

-- ===== Flush ==============================================================

-- Process the queue. Called once at OnInitialize. Two-pass:
-- pass 1 stores raw defs (so `extends` references resolve), pass 2 runs
-- the validator and applies `extends` merging.
function WT:Flush()
    if self._flushed then return end
    self._flushed = true

    -- Pass 1: insert raw defs, catch duplicate kinds
    for _, entry in ipairs(self._queue) do
        if self._registry[entry.kind] then
            error(("VFN.WidgetTypes: duplicate registration for kind %q"):format(entry.kind), 2)
        end
        self._registry[entry.kind] = entry.def
    end

    -- Pass 2: validate every def
    local errors = {}
    for kind, def in pairs(self._registry) do
        validateOne(kind, def, self._registry, errors)
    end
    if #errors > 0 then
        error("VFN.WidgetTypes:Flush validation failures:\n  " ..
            table.concat(errors, "\n  "), 2)
    end

    -- Pass 3: apply extends inheritance (after validation so parent existence
    -- is guaranteed). Result is the engine-facing normalized def.
    local normalized = {}
    for kind, def in pairs(self._registry) do
        local parent = def.extends and self._registry[def.extends] or nil
        normalized[kind] = normalizeWithExtends(def, parent)
    end
    self._registry = normalized

    self._queue = nil
end

-- ===== Read API (engines consume this) ====================================

-- Look up a WidgetType by kind. Errors loudly on unknown kind so engine
-- bugs surface immediately rather than silently no-op.
function WT:Get(kind)
    if not self._flushed then
        error(("VFN.WidgetTypes:Get(%q): registry not flushed yet"):format(tostring(kind)), 2)
    end
    local def = self._registry[kind]
    if not def then
        error(("VFN.WidgetTypes:Get(%q): unknown widget kind"):format(tostring(kind)), 2)
    end
    return def
end

-- Soft lookup (no error on unknown). Used by validators / debug tools that
-- need to introspect without throwing.
function WT:TryGet(kind)
    return self._flushed and self._registry[kind] or nil
end

-- Iterate every registered kind. Order is iteration-order of `pairs`, which
-- is implementation-defined; callers that need stable order should sort
-- the returned list.
function WT:GetAll()
    return self._registry
end

-- ===== Test helpers =======================================================

function WT:_Reset()
    self._queue = {}
    self._registry = {}
    self._flushed = false
end

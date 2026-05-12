-- VFN.Rows
--
-- Unified row registry for scrollbox-style lists. ONE place to define a row;
-- one shape that covers both "simple text row" and "custom multi-line row."
--
-- Each row definition:
--   font   = "body" | "subheading" | ...      (Theme font role; REQUIRED)
--   height = number                            (row pixel height; REQUIRED)
--   spacing = number                           (override scrollbox row spacing;
--                                               optional, defaults to spec.spacing)
--   key    = function(spec, ctx) -> string    (stable per-row identity;
--                                               REQUIRED per spec section 10;
--                                               `spec` is the row's elementData,
--                                               `ctx` is the parent scrollbox
--                                               context table -- nil for now)
--
-- Plus EXACTLY ONE of:
--   factory(template) -> { Configure(row, ed), Reset(row) }
--                                              (full-custom row -- icons,
--                                               multi-FontString, badge, etc)
--
-- OR a simple-text shape:
--   deriveText(ed) -> string                   (simple single-FontString text)
--   onClick(ed)    -> handler|nil              (optional click handler)
--
-- Selection state is conveyed via CH.UI.PaintRowChrome (accent border + fill);
-- factories don't decorate the row text with prefixes.
--
-- Identity rule (spec section 10): every loop-rendered row MUST declare a
-- key function. WowScrollBoxList tracks elementData by reference today, but
-- the explicit key is the contract surface for future migrations (diffing,
-- animation, focus preservation across re-layouts).

VFN = VFN or {}
VFN.Rows = VFN.Rows or { byName = {} }

local R = VFN.Rows

function R:Register(name, def)
    if type(name) ~= "string" or name == "" then
        error("VFN.Rows: name must be a non-empty string", 2)
    end
    if type(def) ~= "table" then
        error(("VFN.Rows: %q definition must be a table"):format(name), 2)
    end
    if type(def.font) ~= "string" or def.font == "" then
        error(("VFN.Rows: %q.font is required (Theme font role)"):format(name), 2)
    end
    if type(def.height) ~= "number" then
        error(("VFN.Rows: %q.height is required (pixel number)"):format(name), 2)
    end

    local hasFactory = type(def.factory) == "function"
    local hasDerive  = type(def.deriveText) == "function"
    if hasFactory == hasDerive then
        -- Both or neither -- ambiguous.
        error(("VFN.Rows: %q must declare EXACTLY one of `factory` or `deriveText`"):format(name), 2)
    end
    if def.onClick ~= nil and type(def.onClick) ~= "function" then
        error(("VFN.Rows: %q.onClick must be a function or nil"):format(name), 2)
    end
    -- Spec section 10: every loop-rendered row declares a stable key
    -- function. Validator errors loudly so the omission isn't silent.
    if type(def.key) ~= "function" then
        error(("VFN.Rows: %q.key is required (function(elementData) -> string;"
            .. " spec section 10 -- stable per-row identity)"):format(name), 2)
    end

    self.byName[name] = def
    return true
end

function R:Get(name)
    if type(name) ~= "string" or name == "" then return nil end
    return self.byName[name]
end

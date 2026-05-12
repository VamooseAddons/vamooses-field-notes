-- VFN.TableUtils
--
-- Small table utilities vendored from Penlight + Neovim core.lua. Replaces
-- the need to depend on either library; we own ~80 lines that handle deep
-- merge, deep copy, deep equal, shallow merge, and a handful of helpers.
--
-- Decision matrix: Project Documentation/sample-lua-references/LUA_SAMPLES_UTILITIES.md
-- "Decision Matrix" section. Source patterns:
--   - DeepCopy: Penlight cycle_aware_copy (handles cycles, preserves metatables)
--   - DeepMerge: Neovim vim.tbl_deep_extend (three-mode merge: force/keep/error,
--     arrays-as-leaves behavior, can_merge predicate)
--   - DeepEqual: Penlight cycle_aware_compare (with cycle detection)
--
-- Lua 5.1 compatible (LuaJIT). No metatable magic, no module()/setfenv,
-- no goto/continue. Plain table-walking recursion.

VFN = VFN or {}
VFN.TableUtils = VFN.TableUtils or {}

local TU = VFN.TableUtils

-- ===== DeepCopy (Penlight cycle_aware_copy shape) =========================

-- Recursively copy a table, preserving metatables and handling cycles.
-- Non-table values returned as-is. Cycle detection via the cache table
-- (pre-registered before recursion to avoid infinite loops).
function TU.DeepCopy(t, cache)
    if type(t) ~= "table" then return t end
    cache = cache or {}
    if cache[t] then return cache[t] end

    local result = {}
    cache[t] = result   -- pre-register BEFORE recursion to break cycles
    for k, v in pairs(t) do
        result[TU.DeepCopy(k, cache)] = TU.DeepCopy(v, cache)
    end
    return setmetatable(result, getmetatable(t))
end

-- ===== DeepEqual (Penlight cycle_aware_compare shape) =====================

-- Deep structural equality. Handles cycles via the seen table. Returns
-- true if all keys/values match recursively. Metatables ignored unless
-- one side has __eq -- in which case relational ==  is used.
function TU.DeepEqual(a, b, seen)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end

    -- Honor __eq metamethods when present on either side
    local mtA, mtB = getmetatable(a), getmetatable(b)
    if (mtA and mtA.__eq) or (mtB and mtB.__eq) then return a == b end

    seen = seen or {}
    if seen[a] and seen[a][b] then return true end       -- already in flight
    seen[a] = seen[a] or {}
    seen[a][b] = true

    -- Check every key in a is in b with matching value
    for k, v in pairs(a) do
        if not TU.DeepEqual(v, b[k], seen) then return false end
    end
    -- Check b doesn't have extra keys
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- ===== DeepMerge (Neovim tbl_deep_extend shape) ===========================
--
-- can_merge: a value is mergeable iff it's a non-array table. Arrays
-- (consecutive integer keys starting at 1) are treated as LEAVES and
-- replaced wholesale by the override -- not concatenated. This matches
-- Neovim's behavior and avoids the "I overrode the list, why did my
-- override get appended?" footgun.
local function isArray(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then return false end
        n = n + 1
    end
    return n > 0 and #t == n
end

local function canMerge(v)
    return type(v) == "table" and not isArray(v)
end

-- Mode: "force" (override wins), "keep" (base wins), "error" (conflict throws).
-- Returns a NEW table; inputs not mutated.
local function deepExtendOne(mode, base, override)
    if not canMerge(base) or not canMerge(override) then
        if mode == "force" then return TU.DeepCopy(override) end
        if mode == "keep"  then return TU.DeepCopy(base) end
        if mode == "error" then
            error("DeepMerge: conflicting non-mergeable values (use 'force' or 'keep' instead of 'error')", 3)
        end
        error("DeepMerge: unknown mode " .. tostring(mode), 3)
    end

    local result = {}
    for k, v in pairs(base) do
        if override[k] == nil then
            result[k] = TU.DeepCopy(v)
        elseif canMerge(v) and canMerge(override[k]) then
            result[k] = deepExtendOne(mode, v, override[k])
        else
            if mode == "force" then result[k] = TU.DeepCopy(override[k])
            elseif mode == "keep" then result[k] = TU.DeepCopy(v)
            elseif mode == "error" then
                error(("DeepMerge: conflict at key %q (mode='error')"):format(tostring(k)), 3)
            end
        end
    end
    -- Keys only in override
    for k, v in pairs(override) do
        if base[k] == nil then result[k] = TU.DeepCopy(v) end
    end
    return result
end

-- Public API: DeepMerge(mode, base, ...overrides). Each override merges
-- left-to-right onto the accumulating result.
function TU.DeepMerge(mode, base, ...)
    if mode ~= "force" and mode ~= "keep" and mode ~= "error" then
        error("VFN.TableUtils.DeepMerge: mode must be 'force', 'keep', or 'error'", 2)
    end
    local result = TU.DeepCopy(base)
    for i = 1, select("#", ...) do
        local override = select(i, ...)
        result = deepExtendOne(mode, result, override)
    end
    return result
end

-- ===== Shallow merge ======================================================

-- Single-level merge. base ⊕ override (override wins) returning a NEW table.
-- Faster than DeepMerge when single-level is all you need.
function TU.Merge(base, override)
    local result = {}
    if base then for k, v in pairs(base) do result[k] = v end end
    if override then for k, v in pairs(override) do result[k] = v end end
    return result
end

-- ===== Predicates / lookups ===============================================

function TU.IsArray(t) return isArray(t) end
function TU.CanMerge(v) return canMerge(v) end

function TU.IsEmpty(t)
    if type(t) ~= "table" then return true end
    return next(t) == nil
end

-- Count entries (works for sparse tables; # operator is unreliable there).
function TU.Count(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Keys / values as arrays
function TU.Keys(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k in pairs(t) do out[#out + 1] = k end
    return out
end

function TU.Values(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for _, v in pairs(t) do out[#out + 1] = v end
    return out
end

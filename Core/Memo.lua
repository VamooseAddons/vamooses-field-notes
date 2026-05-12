-- VFN.Memo
--
-- Selector memoization. Architecture spec:
-- Project Documentation/UI_WIDGET_TAXONOMY.md section 11.
-- Reference: LUA_SAMPLES_UTILITIES.md section 3c (custom createSelector).
--
-- Two API entry points:
--
-- 1. Memo({ inputs = {fn1, fn2, ...}, compute = fn })
--    Reselect-style memoize. inputs are functions of (state, ...) that
--    return stable values (do NOT construct {} inside inputs!). compute
--    runs only when ALL inputs have changed since the last call. Result
--    is cached at single entry.
--
-- 2. MakeFactory({ inputs = ..., compute = ... })
--    Selector factory. Returns a function(key) -> selector. Each unique
--    key gets its own 1-entry cache. Use when N callers each need a
--    selector keyed by their own ID (set ID, character name, etc.).
--    Without this, a single shared selector thrashes its cache across N
--    differently-keyed callers.
--
-- Three reselect rules baked in (spec section 11):
--   1. Input selectors must return stable references. Never construct
--      {} or [] inside an input -- destroys cascading memoization.
--      (We can't enforce this at runtime cheaply; documented as contract.)
--   2. Only memoize selectors that do non-trivial compute. Memoizing a
--      direct field read adds overhead with no benefit.
--   3. Selector-factory pattern for per-instance selectors. See MakeFactory.

VFN = VFN or {}
VFN.Memo = VFN.Memo or {}

local M = VFN.Memo

-- ===== Single-entry Memo (reselect style) =================================

-- Returns a memoized selector. Inputs are called with whatever args the
-- selector itself was called with; results compared with rawequal for the
-- cache hit/miss decision. compute runs only on cache miss.
--
-- Lua 5.1 note: == on tables checks reference identity unless __eq is
-- defined. That's the property we want for input selectors: a stable
-- reference returned by an input means "unchanged" with cheap O(1) compare.
function M.Memo(spec)
    if type(spec) ~= "table" then
        error("VFN.Memo.Memo: expected a spec table", 2)
    end
    if type(spec.compute) ~= "function" then
        error("VFN.Memo.Memo: spec.compute must be a function", 2)
    end
    local inputs = spec.inputs or {}
    if type(inputs) ~= "table" then
        error("VFN.Memo.Memo: spec.inputs must be a list of functions", 2)
    end
    for i, inputFn in ipairs(inputs) do
        if type(inputFn) ~= "function" then
            error(("VFN.Memo.Memo: spec.inputs[%d] must be a function"):format(i), 2)
        end
    end

    -- Cache state (closure-captured)
    local cachedInputs = nil        -- last inputs (list); nil = no cache yet
    local cachedResult = nil
    local n = #inputs

    return function(...)
        -- Special case: zero inputs means "always recompute" -- semantically
        -- equivalent to "no memoization." We allow it for API consistency
        -- but it doesn't cache.
        if n == 0 then
            return spec.compute(...)
        end

        local currentInputs = {}
        for i = 1, n do
            currentInputs[i] = inputs[i](...)
        end

        -- Compare current vs cached. Reference equality is intentional
        -- and required -- the contract is that input selectors return
        -- stable references.
        local hit = cachedInputs ~= nil
        if hit then
            for i = 1, n do
                if cachedInputs[i] ~= currentInputs[i] then
                    hit = false
                    break
                end
            end
        end

        if hit then
            return cachedResult
        end

        cachedInputs = currentInputs
        cachedResult = spec.compute(unpack(currentInputs, 1, n))
        return cachedResult
    end
end

-- ===== Factory (per-instance memoization) =================================

-- Returns a factory function(key) -> selector. Each unique key produces a
-- selector with its own 1-entry cache. Used when N row components each need
-- a selector parameterized by row ID (or character name, set ID, etc.).
--
-- Without this pattern, a shared selector with one cache slot thrashes
-- across N differently-keyed callers (cache miss every call). With it,
-- each key gets its own 1-entry cache; reselect's memoization works.
--
-- spec.inputs is a list of (state, key, ...) -> value functions. The factory
-- partial-applies key, so the returned selector behaves like a normal Memo:
-- inputs are called with (state, ...) and key is captured in the closure.
function M.MakeFactory(spec)
    if type(spec) ~= "table" then
        error("VFN.Memo.MakeFactory: expected a spec table", 2)
    end
    if type(spec.compute) ~= "function" then
        error("VFN.Memo.MakeFactory: spec.compute must be a function", 2)
    end
    local inputs = spec.inputs or {}

    -- Strong cache: the factory keeps selectors alive for the addon's
    -- lifetime. Weak-value caches looked tempting (auto-GC selectors when
    -- consumer drops them), but produce a subtle correctness bug: if a
    -- consumer holds the selector only via a local var, the next GC cycle
    -- can evict it, and the next factory(key) call rebuilds a fresh
    -- selector with empty cache -- silently defeating memoization.
    --
    -- The bound is selectors-per-key. Per-key counts are typically small
    -- (N rows in a list = N selectors); selectors are tiny closures.
    -- If selective eviction is ever needed, expose factory:Evict(key)
    -- explicitly rather than relying on GC behavior.
    local cache = {}

    local function makeSelector(key)
        if cache[key] then return cache[key] end

        -- Build a Memo selector that captures `key` in its input/compute
        -- closures.
        local boundInputs = {}
        for i, inputFn in ipairs(inputs) do
            boundInputs[i] = function(...) return inputFn(key, ...) end
        end

        local selector = M.Memo({
            inputs = boundInputs,
            compute = function(...) return spec.compute(key, ...) end,
        })

        cache[key] = selector
        return selector
    end

    -- Callable table: factory(key) -> selector, plus :Evict and :EvictAll
    -- methods for explicit cache management. Lua doesn't let us attach
    -- fields to plain functions, so we wrap in a table with __call.
    local factory = setmetatable({
        Evict = function(_self, key) cache[key] = nil end,
        EvictAll = function() cache = {} end,
    }, {
        __call = function(_self, key) return makeSelector(key) end,
    })
    return factory
end

-- ===== Helpers ============================================================

-- Identity selector: returns its first arg unchanged. Useful as an input
-- selector when you want compute to receive the state directly:
--   Memo({ inputs = { Memo.Identity }, compute = fn })
function M.Identity(...)
    return (...)
end

-- Direct field reader. Convenience for the common "input selector that
-- reads state.foo.bar" pattern. Path is a dotted string.
--   Memo.Path("account.sets")
-- returns a function(state) -> state.account.sets.
function M.Path(path)
    if type(path) ~= "string" or path == "" then
        error("VFN.Memo.Path: expected non-empty dotted string", 2)
    end
    local segments = {}
    for seg in path:gmatch("[^%.]+") do segments[#segments + 1] = seg end
    return function(state)
        local cur = state
        for _, seg in ipairs(segments) do
            if type(cur) ~= "table" then return nil end
            cur = cur[seg]
        end
        return cur
    end
end

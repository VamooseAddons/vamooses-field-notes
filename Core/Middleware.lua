-- VFN.Middleware
--
-- Action-stream middleware chain. The Store-level mechanism for cross-cutting
-- concerns: combat protection, logging, persistence, error boundaries, etc.
-- Architecture spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 4.
--
-- Each middleware has Rodux's two-curry shape:
--   middleware = function(nextDispatch, store)
--       return function(action)
--           -- pre-processing
--           local result = nextDispatch(action)
--           -- post-processing
--           return result
--       end
--   end
--
-- Registration order = execution order. Logger first sees the raw action;
-- persistence last sees the final committed state.
--
-- Chain construction (right-fold over the middleware list) builds a closure
-- chain: mw1 -> mw2 -> ... -> baseDispatch. The result REPLACES the store's
-- dispatch method so future calls automatically traverse the chain.
--
-- Reference: Project Documentation/sample-lua-references/LUA_SAMPLES.md
--   section 1a (Rodux Store middleware chain construction).

VFN = VFN or {}
VFN.Middleware = VFN.Middleware or {}

local M = VFN.Middleware

-- ===== Chain construction =================================================

-- Apply an ordered list of middlewares to a store. Right-folds the list so
-- that middlewares[1] becomes the outermost wrapper. Replaces store.Dispatch
-- in place; future store:Dispatch(action) calls traverse the chain.
function M.Apply(store, middlewares)
    if type(middlewares) ~= "table" or #middlewares == 0 then return end

    -- Capture the un-wrapped baseDispatch BEFORE we replace store.Dispatch.
    local baseDispatch = function(action)
        return store:_RawDispatch(action)
    end

    -- Right-fold: iterate backwards so middlewares[1] wraps everything inside.
    local dispatch = baseDispatch
    for i = #middlewares, 1, -1 do
        local mw = middlewares[i]
        if type(mw) ~= "function" then
            error(("VFN.Middleware.Apply: middleware at index %d is not a function"):format(i), 2)
        end
        dispatch = mw(dispatch, store)
        if type(dispatch) ~= "function" then
            error(("VFN.Middleware.Apply: middleware at index %d did not return a dispatch function"):format(i), 2)
        end
    end

    -- Replace the store's Dispatch method. Callers writing store:Dispatch()
    -- now flow through the chain. The raw method is preserved as _RawDispatch
    -- so the base of the chain can still reach the reducer.
    store.Dispatch = function(self, action)
        return dispatch(action)
    end
end

-- ===== Standard middlewares ===============================================

-- LoggerMiddleware: dev-mode action log. Prints action type + payload at
-- dispatch time. Gated by state.account.config.debug to avoid log spam in
-- production. Always sits first in the chain so it sees the raw action
-- before any transformation.
--
-- Output format (readable -- spec audit follow-up):
--   [VFN] >  SET_OPEN              setID=set_12345
--   [VFN] >  UI_SET_TRANSIENT      view=library key=selectedSetID
--   [VFN] >  MAIN_WINDOW_TOGGLE
-- VFN_ prefix is stripped (it's redundant -- we know it's VFN). Action
-- name is amber (semantic.accent), payload is dim. Three columns padded
-- so the eye finds the action name at a fixed glance position.
local LOGGER_NAME_WIDTH = 22  -- pad action names to this width (most are <= 20)
local LOGGER_MAX_KEYS   = 6   -- payload keys shown before truncating
local LOGGER_MAX_STR    = 80  -- string-value chars shown before "..."
local function formatPayload(payload)
    if type(payload) ~= "table" then return "" end
    -- Compact key=value list. Truncates beyond LOGGER_MAX_KEYS / LOGGER_MAX_STR
    -- so a giant payload (SET_UPDATE with sourceLines + entries + fields)
    -- doesn't blow chat scrollback. Bumped from 3/24 to 6/80 in the readable-
    -- output pass -- typical actions fit fully now.
    local parts, count = {}, 0
    for k, v in pairs(payload) do
        count = count + 1
        if count > LOGGER_MAX_KEYS then
            parts[#parts + 1] = "..."
            break
        end
        local repr
        local t = type(v)
        if t == "string" then
            repr = v
            if #repr > LOGGER_MAX_STR then repr = repr:sub(1, LOGGER_MAX_STR - 3) .. "..." end
        elseif t == "boolean" or t == "number" then
            repr = tostring(v)
        elseif t == "table" then
            repr = "{...}"
        else
            repr = "<" .. t .. ">"
        end
        parts[#parts + 1] = tostring(k) .. "=" .. repr
    end
    return table.concat(parts, " ")
end

function M.LoggerMiddleware(nextDispatch, store)
    return function(action)
        local state = store:GetState()
        if state and state.account and state.account.config and state.account.config.debug then
            local actionType = action and action.type or "?"
            local short = tostring(actionType):gsub("^VFN_", "")
            -- Pad action name so the payload column lands at the same X each line.
            local padded = short
            if #padded < LOGGER_NAME_WIDTH then
                padded = padded .. string.rep(" ", LOGGER_NAME_WIDTH - #padded)
            end
            local payload = action and action.payload
            local payloadStr = formatPayload(payload)
            if payloadStr ~= "" then
                -- Bracket prefix dim, action name amber, payload dim italic-ish.
                print(("|cff666666[VFN]|r |cffffb060%s|r |cff999999%s|r"):format(
                    padded, payloadStr))
            else
                print(("|cff666666[VFN]|r |cffffb060%s|r"):format(padded))
            end
        end
        return nextDispatch(action)
    end
end

-- CombatMiddleware: queues combat-unsafe actions during PLAYER_REGEN_DISABLED.
-- Drains the queue on PLAYER_REGEN_ENABLED. Action metadata declares which
-- actions are combat-unsafe via ACTION_META[type].combatUnsafe.
--
-- This middleware OWNS the combat regen Blizzard events (modules cannot
-- subscribe to PLAYER_REGEN_DISABLED/ENABLED -- BlizzardEvents validator
-- rejects them). The middleware wires its own listeners directly via the
-- frame held by VFN.BlizzardEvents -- a sibling-engine collaboration.
function M.MakeCombatMiddleware(actionMeta)
    actionMeta = actionMeta or {}
    return function(nextDispatch, store)
        -- Wire combat state listeners once per store (idempotent guard).
        -- The regen events themselves are sibling-engine territory
        -- (_internalSubscribe is permitted per spec section 15.7), but the
        -- resulting state mutation goes through the public Dispatch chain
        -- so the reducer remains the single source of truth for
        -- session.combat.inLockdown.
        if not store._combatListenersWired and VFN.BlizzardEvents then
            store._combatListenersWired = true
            local A = VFN.Constants and VFN.Constants.ACTIONS or {}
            VFN.BlizzardEvents:_internalSubscribe("PLAYER_REGEN_DISABLED", function()
                store:Dispatch({ type = A.COMBAT_ENTER })
            end)
            VFN.BlizzardEvents:_internalSubscribe("PLAYER_REGEN_ENABLED", function()
                -- Drain order: dispatch COMBAT_EXIT first (so the reducer
                -- flips inLockdown=false BEFORE the queued-action loop --
                -- otherwise queued actions would land back in the queue);
                -- then replay queued combat-unsafe actions through the
                -- public chain (ErrorBoundary -> ... -> reducer) so they
                -- traverse every middleware exactly once.
                store:Dispatch({ type = A.COMBAT_EXIT })
                local s = store:GetState()
                if not (s and s.session and s.session.combat) then return end
                local queued = s.session.combat.queued or {}
                s.session.combat.queued = {}
                for _, queuedAction in ipairs(queued) do
                    store:Dispatch(queuedAction)
                end
            end)
        end

        return function(action)
            local meta = actionMeta[action and action.type or nil]
            local inLockdown = false
            local s = store:GetState()
            if s and s.session and s.session.combat then
                inLockdown = s.session.combat.inLockdown == true
            end

            if meta and meta.combatUnsafe and inLockdown then
                -- Queue for drain on PLAYER_REGEN_ENABLED. The queued buffer
                -- lives on state (transient session.combat.queued); the next
                -- COMBAT_EXIT dispatch above drains it.
                s.session.combat.queued = s.session.combat.queued or {}
                table.insert(s.session.combat.queued, action)
                return  -- deferred; no result for caller
            end
            return nextDispatch(action)
        end
    end
end

-- EnvMiddleware: injects an addon-level environment table as the second
-- argument to function-typed actions (thunks). Pattern: Rodux's
-- makeThunkMiddleware. Lets thunks dispatch conditionally with full
-- Store/env access without prop-drilling the environment through every
-- caller. See spec section 9.
function M.MakeEnvMiddleware(env)
    return function(nextDispatch, store)
        return function(action)
            if type(action) == "function" then
                return action(store, env)
            end
            return nextDispatch(action)
        end
    end
end

-- PersistenceMiddleware: marks SavedVariables dirty when an action mutates
-- a persisted field. Uses action metadata (ACTION_META[type].persists) so
-- the middleware itself doesn't know about state shape -- it just queues a
-- save when told to.
function M.MakePersistenceMiddleware(actionMeta)
    actionMeta = actionMeta or {}
    return function(nextDispatch, store)
        return function(action)
            local result = nextDispatch(action)
            local meta = actionMeta[action and action.type or nil]
            if meta and meta.persists and store.QueueSave then
                store:QueueSave()
            end
            return result
        end
    end
end

-- ErrorBoundaryMiddleware: pcall the chain so a single faulty reducer or
-- inner middleware doesn't crash the whole dispatch. Should be the OUTERMOST
-- middleware (i.e., registered FIRST in the list) so it wraps everything
-- else. Errors are logged but don't propagate.
function M.ErrorBoundaryMiddleware(nextDispatch, store)
    return function(action)
        local ok, result = pcall(nextDispatch, action)
        if not ok then
            local actionType = action and action.type or "?"
            print(("|cffff5555[VFN] dispatch error (action=%s): %s|r"):format(
                tostring(actionType), tostring(result)))
            return nil
        end
        return result
    end
end

-- ===== Standard chain assembly =============================================

-- Convenience: assemble the standard middleware chain in the recommended
-- order. Callers pass actionMeta + env tables; this returns the ordered
-- middleware list ready for M.Apply().
--
-- Order (registered first = outermost, sees raw action first):
--   1. ErrorBoundaryMiddleware -- catches all downstream errors
--   2. LoggerMiddleware        -- logs raw action
--   3. CombatMiddleware        -- defers unsafe actions in combat
--   4. EnvMiddleware           -- injects env into thunk-style actions
--   5. PersistenceMiddleware   -- queues SavedVars save after reducer
function M.StandardChain(opts)
    opts = opts or {}
    return {
        M.ErrorBoundaryMiddleware,
        M.LoggerMiddleware,
        M.MakeCombatMiddleware(opts.actionMeta),
        M.MakeEnvMiddleware(opts.env),
        M.MakePersistenceMiddleware(opts.actionMeta),
    }
end

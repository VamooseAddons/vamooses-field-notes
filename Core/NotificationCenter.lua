-- VFN.NotificationCenter
--
-- Toast queue with priority + auto-dismiss + interruption. Architecture
-- spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 17.5.
--
-- Per the contract-vs-engines principle: toast VISUALS are widget kinds
-- (addon-local -- VC's mascotToast, future bannerToast, etc.). The QUEUE,
-- TIMING, and PRIORITY logic lives here. Modules call:
--   VFN.NotificationCenter:Show({ title, body, duration, priority, ... })
-- and the engine handles ordering, the current-toast lifecycle, and
-- handing off to a registered renderer.
--
-- A renderer is a function that mounts / animates / dismisses one toast.
-- Addons register a renderer for their style at OnInitialize:
--   VFN.NotificationCenter:RegisterRenderer("mascotToast", function(notification, onDone) ... end)
-- The default renderer (DEFAULT_RENDERER below) prints to chat -- useful
-- before any visual addon registers and as a test fallback.
--
-- Priority levels (lower number = higher priority):
--   "urgent" = 0    interrupts current toast immediately
--   "high"   = 1    moves to front of queue (but waits for current)
--   "normal" = 2    appended to queue
--   "low"    = 3    appended after all normal toasts
--
-- Queue processing:
--   - One toast active at a time
--   - When active completes (timer expires OR onClick OR explicit Dismiss),
--     the next-priority toast is rendered
--   - "urgent" notifications skip the queue; the current toast is cancelled

VFN = VFN or {}
VFN.NotificationCenter = VFN.NotificationCenter or {
    _renderers = {},                  -- [styleName] = renderer fn
    _defaultStyle = "default",
    _queue = {},                      -- ordered by priority + arrival
    _active = nil,                    -- the currently-rendered notification
    _currentDismiss = nil,            -- closure to cancel current toast
}

local NC = VFN.NotificationCenter

-- Priority enum -> numeric rank for queue ordering.
local PRIORITY_RANK = {
    urgent = 0,
    high   = 1,
    normal = 2,
    low    = 3,
}

-- Default renderer: writes to chat. Used when no addon has registered a
-- visual renderer. Returns immediately; "duration" emulated via a deferred
-- callback so the queue still rotates.
local function defaultRenderer(notification, onDone)
    print(("|cff7fbfff[notify] %s|r%s"):format(
        notification.title or "",
        notification.body and (": " .. notification.body) or ""))

    -- Simulate the toast's lifetime so the queue progresses. If duration
    -- is nil/0, fire immediately so urgent broadcasts don't stall the queue.
    local duration = tonumber(notification.duration) or 0
    if duration <= 0 then
        onDone()
        return function() end   -- no-op cancel
    end
    if _G.C_Timer then
        local cancelled = false
        _G.C_Timer.After(duration, function()
            if not cancelled then onDone() end
        end)
        return function() cancelled = true; onDone() end
    end
    onDone()
    return function() end
end

-- ===== Renderer registration ==============================================

function NC:RegisterRenderer(styleName, renderer)
    if type(styleName) ~= "string" or styleName == "" then
        error("VFN.NotificationCenter:RegisterRenderer: styleName required", 2)
    end
    if type(renderer) ~= "function" then
        error("VFN.NotificationCenter:RegisterRenderer: renderer must be a function", 2)
    end
    self._renderers[styleName] = renderer
end

function NC:SetDefaultStyle(styleName)
    if type(styleName) ~= "string" or styleName == "" then
        error("VFN.NotificationCenter:SetDefaultStyle: styleName required", 2)
    end
    self._defaultStyle = styleName
end

-- ===== Show / queue =======================================================

local function rankOf(notification)
    return PRIORITY_RANK[notification.priority or "normal"] or PRIORITY_RANK.normal
end

-- Pick the next notification to render. Priority rank first; ties broken
-- by arrival order (which our table.insert preserves implicitly when we
-- append; we use FIFO for same-priority items).
local function popNext(queue)
    if #queue == 0 then return nil end
    -- Find the lowest-rank entry; ties go to earliest insertion.
    local bestI, bestRank = 1, rankOf(queue[1])
    for i = 2, #queue do
        if rankOf(queue[i]) < bestRank then
            bestI, bestRank = i, rankOf(queue[i])
        end
    end
    return table.remove(queue, bestI)
end

-- Render the next queued notification. No-op if one is already active or
-- queue is empty.
local function pump(self)
    if self._active then return end
    local next = popNext(self._queue)
    if not next then return end
    self._active = next

    local style = next.style or self._defaultStyle
    local renderer = self._renderers[style] or defaultRenderer

    local function onDone()
        self._active = nil
        self._currentDismiss = nil
        pump(self)
    end

    self._currentDismiss = renderer(next, onDone)
    if type(self._currentDismiss) ~= "function" then
        -- Renderer didn't return a dismiss closure; treat as fire-and-forget.
        self._currentDismiss = function() end
    end
end

-- Public Show: queues a notification (or interrupts current if urgent).
function NC:Show(notification)
    if type(notification) ~= "table" then
        error("VFN.NotificationCenter:Show: notification must be a table", 2)
    end

    if notification.priority == "urgent" and self._active then
        -- Interrupt: cancel the current toast, render this one immediately.
        local dismiss = self._currentDismiss
        self._active = nil
        self._currentDismiss = nil
        if dismiss then pcall(dismiss) end
    end

    table.insert(self._queue, notification)
    pump(self)
end

-- Dismiss the currently-active toast. The renderer's dismiss closure is
-- called; the queue advances.
function NC:DismissCurrent()
    if not self._active then return end
    local dismiss = self._currentDismiss
    self._active = nil
    self._currentDismiss = nil
    if dismiss then pcall(dismiss) end
    -- pump() may already have been called by the renderer's onDone; if not,
    -- pump now to keep the queue progressing.
    pump(self)
end

-- Drop all queued notifications without dismissing the active one.
function NC:ClearQueue()
    self._queue = {}
end

-- ===== Introspection / test helpers =======================================

function NC:GetActive()
    return self._active
end

function NC:GetQueueDepth()
    return #self._queue
end

function NC:_Reset()
    self._renderers = {}
    self._defaultStyle = "default"
    self._queue = {}
    self._active = nil
    self._currentDismiss = nil
end

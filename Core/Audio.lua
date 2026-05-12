-- VFN.Audio
--
-- Thin wrapper over Blizzard's PlaySound / PlaySoundFile. Architecture
-- spec: Project Documentation/UI_WIDGET_TAXONOMY.md section 17.6.
--
-- Per the contract-vs-engines principle (spec section 1.3): sounds are
-- imperative effects, not declarative widget fields. Handlers call
-- Audio:Play() from their onClick / onShow / wherever. The contract
-- (WidgetType) stays focused on declarative structure.
--
-- API:
--   Audio:Play(soundKitOrPath, channel?)
--     soundKitOrPath: number (SOUNDKIT constant) OR string (file path)
--     channel: "Master" | "Music" | "SFX" | "Ambience" | "Dialog"
--              defaults to "SFX"
--   Audio:SetChannelMuted(channel, muted)
--     Per-channel mute that this engine respects. Distinct from Blizzard's
--     CVar volumes; lets us mute sounds from a specific addon without
--     affecting the player's global volumes.
--   Audio:IsChannelMuted(channel) -> bool
--
-- Returns: (willPlay, soundHandleOrNil)
--   willPlay: true if the underlying API was called (not muted, valid kit)
--   soundHandle: Blizzard's PlaySound return (canBePlayed, soundHandle)
--
-- For now this is a passthrough wrapper -- the real value is the channel
-- mute + the contract-vs-engines discipline. Future additions: per-addon
-- volume mixing, sound queue rate-limiting, etc.

VFN = VFN or {}
VFN.Audio = VFN.Audio or {
    _muted = {},   -- [channelName] = true if muted
}

local A = VFN.Audio

local VALID_CHANNELS = {
    Master   = true,
    Music    = true,
    SFX      = true,
    Ambience = true,
    Dialog   = true,
}

-- ===== Public API ==========================================================

-- Play a sound. Returns (willPlay, soundHandle) -- willPlay false means
-- we short-circuited (muted, bad input). soundHandle is Blizzard's return
-- value; callers usually ignore it (the SOUNDKIT API also returns canBePlayed
-- as a first return; we pass it through transparently).
function A:Play(soundKitOrPath, channel)
    channel = channel or "SFX"
    if not VALID_CHANNELS[channel] then
        error(("VFN.Audio:Play: invalid channel %q (use Master/Music/SFX/Ambience/Dialog)")
            :format(tostring(channel)), 2)
    end
    if self._muted[channel] then return false, nil end

    if type(soundKitOrPath) == "number" then
        if _G.PlaySound then return _G.PlaySound(soundKitOrPath, channel) end
        return false, nil
    elseif type(soundKitOrPath) == "string" then
        if _G.PlaySoundFile then return _G.PlaySoundFile(soundKitOrPath, channel) end
        return false, nil
    end
    error(("VFN.Audio:Play: expected number (SOUNDKIT) or string (path), got %s")
        :format(type(soundKitOrPath)), 2)
end

-- ===== Mute control ========================================================

function A:SetChannelMuted(channel, muted)
    if not VALID_CHANNELS[channel] then
        error(("VFN.Audio:SetChannelMuted: invalid channel %q"):format(tostring(channel)), 2)
    end
    self._muted[channel] = muted and true or nil
end

function A:IsChannelMuted(channel)
    return self._muted[channel] == true
end

-- ===== Test helpers =======================================================

function A:_Reset()
    self._muted = {}
end

-- An invalidated playback device must not be retried forever.
--
-- Windows takes the output away from under a running game (headset unplugged,
-- sleep/resume, default device change).  OpenAL Soft's WASAPI mixer then fails
-- GetCurrentPadding with AUDCLNT_E_DEVICE_INVALIDATED, prints
--   AL lib: (EE) ALCwasapiPlayback_mixerProc: Failed to get padding: 0x88890004
-- and disconnects the ALC device: every Source reads as stopped forever.  LOVE
-- 11.5 has no playback-device API, so nothing can re-open it in-process --
-- which makes the honest behavior "say so, stop retrying, let Music move on"
-- rather than an endless per-frame Source:play against a dead device.
-- ROM-free: ChipAsm blobs, no data/generated/.
--   luajit tests/engine/audio_device_lost_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check = T.check

love = require("tests.love_stub")

-- ------- audio stub: sources that can be told the output device died

local sources = {}
local deviceDead = false

local Source = {}
Source.__index = Source
function Source:play()
  self.playCalls = self.playCalls + 1
  if not deviceDead then self.playing = true end
end
function Source:stop() self.playing = false end
function Source:pause() self.playing = false end
-- A disconnected ALC device reports "not playing" no matter what play() did.
function Source:isPlaying() return self.playing and not deviceDead end
function Source:setLooping(v) self.looping = v end
function Source:setVolume(v) self.volume = v end
function Source:setPitch(v) self.pitch = v end
function Source:setFilter() end
function Source:getDuration() return 1 end
function Source:getFreeBufferCount() return self.free end
function Source:queue() self.free = math.max(0, self.free - 1) end

local ChipSynth = require("src.core.ChipSynth")
local BUFFERS = ChipSynth.MUSIC_BUFFER_COUNT

local function track(src)
  src.playCalls = 0
  sources[#sources + 1] = src
  return src
end

love.audio = {
  newSource = function(what, mode)
    if what ~= "assets/beep.wav" then error("could not open " .. tostring(what), 0) end
    return track(setmetatable({ file = what, mode = mode, free = 0 }, Source))
  end,
  newQueueableSource = function()
    return track(setmetatable({ queueable = true, free = BUFFERS }, Source))
  end,
}

-- ------- worker stub for the threaded path

local channels = {}
local lastGen = 0

local Channel = {}
Channel.__index = Channel
function Channel:push(msg)
  if type(msg) == "table" and msg.cmd == "play" then lastGen = msg.gen end
  self.queue[#self.queue + 1] = msg
end
function Channel:pop() return table.remove(self.queue, 1) end
function Channel:clear() self.queue = {} end

local function channel(name)
  channels[name] = channels[name] or setmetatable({ queue = {} }, Channel)
  return channels[name]
end

local threadStub = {
  newThread = function()
    return {
      start = function() end,
      getError = function() return nil end,
      wait = function() end,
    }
  end,
  getChannel = channel,
}

local function deliverBuffer()
  channel("chipaudio_out"):push({ gen = lastGen, sd = true })
end

-- ------- fixture dataset (an endless loop, so "finished" is never the reason)

local ChipAsm = require("src.audio.ChipAsm")

local function chipSong(octave)
  return ChipAsm.song{
    channels = { { hw = 1, program = {
      { notetype = { speed = 12, volume = 12, fade = 0 } },
      { octave = octave },
      { note = "C", len = 8 },
      { loop = { count = 0, to = 1 } },
    } } },
  }
end

local function fixtureData()
  return {
    audio = {
      songs = { Music_PalletTown = chipSong(4), Music_Routes1 = chipSong(5) },
      sfx = { Level_Up = "assets/beep.wav" },
      cries = {},
      mapSongs = { PALLET_TOWN = "Music_PalletTown" },
    },
  }
end

local Logger = require("src.core.Logger")

local function deviceLostWarnings()
  local count = 0
  for _, line in ipairs(Logger.history) do
    if line:find("playback device was lost", 1, true) then count = count + 1 end
  end
  return count
end

-- ChipAudio decides sync vs threaded once per process (workerReady), so each
-- path gets its own copy of the module; Music resolves it through require on
-- every call and picks the new one up.
local function freshChipAudio(threaded)
  love.thread = threaded and threadStub or nil
  package.loaded["src.core.ChipAudio"] = nil
  return require("src.core.ChipAudio")
end

local function lastSource() return sources[#sources] end

local function scenario(label, threaded)
  local ChipAudio = freshChipAudio(threaded)
  local data = fixtureData()
  for i = #sources, 1, -1 do sources[i] = nil end
  deviceDead = false
  local budget = ChipAudio.DEVICE_LOST_AFTER_ATTEMPTS
  check(type(budget) == "number" and budget > 1,
    label .. ": the lost-device budget is published, not hard-coded")

  local header = data.audio.songs.Music_PalletTown
  local music = ChipAudio.playMusic(data, header)
  check(music ~= nil, label .. ": the map theme starts while the device is live")
  if threaded then deliverBuffer() ChipAudio.update() end
  check(music.playing, label .. ": the map theme is sounding before the loss")
  local warnedBefore = deviceLostWarnings()

  -- A render stall is not a lost device: the first few restarts must keep
  -- trying, and one that succeeds clears the streak entirely.
  deviceDead = true
  for _ = 1, budget - 1 do
    if threaded then ChipAudio.update() end
    ChipAudio.ensureMusicPlaying()
  end
  check(not ChipAudio.deviceLost(),
    label .. ": a stall shorter than the budget is not declared a lost device")
  deviceDead = false
  ChipAudio.ensureMusicPlaying()
  check(music.playing, label .. ": playback resumes when the output returns")
  check(deviceLostWarnings() == warnedBefore,
    label .. ": recovering inside the budget logs nothing")

  -- Now let it stay dead through the whole budget.
  deviceDead = true
  local attemptsAtLatch = lastSource().playCalls
  for _ = 1, budget + 5 do
    if threaded then ChipAudio.update() end
    ChipAudio.ensureMusicPlaying()
  end
  check(ChipAudio.deviceLost(),
    label .. ": a device that never comes back is declared lost")
  check(deviceLostWarnings() == warnedBefore + 1,
    label .. ": the loss is reported once, in the game log")
  check(lastSource().playCalls > attemptsAtLatch,
    label .. ": restart attempts were actually made before giving up")

  -- The retry storm must stop: with the latch set, further frames touch the
  -- Source no more.
  local attemptsAfterLatch = lastSource().playCalls
  for _ = 1, budget * 3 do
    if threaded then ChipAudio.update() end
    ChipAudio.ensureMusicPlaying()
  end
  check(lastSource().playCalls == attemptsAfterLatch,
    label .. ": a lost device is not retried every frame forever")
  check(deviceLostWarnings() == warnedBefore + 1,
    label .. ": the loss is not re-logged on every frame")

  -- Music.restoreMap re-plays the map theme the instant a stream stops, so a
  -- song change must NOT clear the latch: that would rebuild the storm.
  local next_ = ChipAudio.playMusic(data, data.audio.songs.Music_Routes1)
  check(next_ ~= nil and next_ ~= lastSource() or next_ ~= nil,
    label .. ": a song change still builds a source")
  if threaded then deliverBuffer() ChipAudio.update() end
  ChipAudio.ensureMusicPlaying()
  check(ChipAudio.deviceLost(),
    label .. ": a song change keeps the lost-device latch")
  check(not next_.playing,
    label .. ": a new song does not pretend to sound on a dead device")
  check(deviceLostWarnings() == warnedBefore + 1,
    label .. ": a new song does not re-log the loss")

  -- The one way back is an explicit recovery, and a still-dead device just
  -- re-latches after the same budget rather than looping tightly.
  check(ChipAudio.recoverDevice(),
    label .. ": an explicit recovery clears the latch")
  check(not ChipAudio.deviceLost(),
    label .. ": playback is tried again after a recovery request")
  ChipAudio.ensureMusicPlaying()
  check(lastSource().playCalls > 0, label .. ": recovery attempts playback again")
  for _ = 1, budget + 5 do
    if threaded then ChipAudio.update() end
    ChipAudio.ensureMusicPlaying()
  end
  check(ChipAudio.deviceLost(),
    label .. ": a still-dead device re-latches after the same budget")
  check(deviceLostWarnings() == warnedBefore + 1,
    label .. ": re-latching does not log a second warning")

  -- Output returns for real: recovery sticks and the song sounds again.
  deviceDead = false
  local reCue = ChipAudio.playMusic(data, header)
  ChipAudio.recoverDevice()
  if threaded then deliverBuffer() ChipAudio.update() end
  ChipAudio.ensureMusicPlaying()
  check(not ChipAudio.deviceLost(),
    label .. ": recovery sticks once the output device is back")
  check(reCue.playing, label .. ": music sounds again after the device returns")
end

scenario("sync", false)
scenario("threaded", true)

T.finish("audio device lost")

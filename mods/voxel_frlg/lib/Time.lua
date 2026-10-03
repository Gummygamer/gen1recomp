-- Time of day: the clock, and the light and sky it implies.
--
-- FireRed and LeafGreen have no day/night, so this is purely the mod's own: a
-- clock (the real one, an accelerated cycle, or a pinned hour) feeding a table
-- of light keyframes.  Nothing here touches the game's state.
--
-- A keyframe is the whole look of one hour: the ambient light, the colour of
-- the sun (or, after dark, the moon), the sky's zenith and horizon, and how
-- far the lamps are lit.  Between keyframes everything blends linearly, and
-- the day wraps, so midnight's frame is also 24h's.

local V = ...

local Time = {}

-- name -> hour; REAL and CYCLE are the two running modes
Time.PINNED = { day = 12.0, dusk = 18.8, night = 23.5, dawn = 6.3 }
-- one full day of the CYCLE mode, in real seconds
Time.CYCLE_SECONDS = 20 * 60
local SUNRISE, SUNSET = 6.0, 19.0

--   hour, ambient, sun/moon, zenith, horizon, lamps
local KEYS = {
  { 0.0,  { .20, .25, .42 }, { .22, .28, .50 }, { .02, .03, .10 }, { .07, .09, .22 }, 1.00 },
  { 5.0,  { .20, .25, .42 }, { .22, .28, .50 }, { .02, .03, .10 }, { .07, .09, .22 }, 1.00 },
  { 6.2,  { .48, .42, .54 }, { 1.30, .78, .52 }, { .28, .34, .62 }, { .98, .66, .48 }, 0.35 },
  { 7.5,  { .50, .52, .58 }, { .78, .70, .58 }, { .33, .56, .92 }, { .78, .87, .96 }, 0.00 },
  { 11.0, { .52, .55, .60 }, { .58, .54, .45 }, { .30, .55, .95 }, { .72, .86, .97 }, 0.00 },
  { 15.5, { .52, .55, .60 }, { .58, .54, .45 }, { .30, .55, .95 }, { .72, .86, .97 }, 0.00 },
  { 17.5, { .50, .47, .52 }, { 1.05, .78, .50 }, { .32, .50, .85 }, { .95, .82, .66 }, 0.00 },
  { 18.8, { .46, .36, .46 }, { 1.40, .72, .40 }, { .26, .30, .58 }, { 1.0, .55, .35 }, 0.15 },
  { 19.8, { .30, .28, .42 }, { .62, .40, .46 }, { .10, .12, .30 }, { .55, .30, .40 }, 0.65 },
  { 21.0, { .20, .25, .42 }, { .22, .28, .50 }, { .02, .03, .10 }, { .07, .09, .22 }, 1.00 },
  { 24.0, { .20, .25, .42 }, { .22, .28, .50 }, { .02, .03, .10 }, { .07, .09, .22 }, 1.00 },
}

-- Weather that takes the light out of the day: precipitation and ash fully,
-- fog partly (src/core/game3/weather.lua ids).
local OVERCAST = {
  [3] = 1, [4] = 1, [5] = 1, [13] = 1, [7] = 1, [8] = 0.8, [6] = 0.55, [9] = 0.55,
}
local GREY = { .52, .56, .62 }

local clock = 12.0    -- the running cycle's hour

local function lerp(a, b, t) return a + (b - a) * t end
local function lerp3(a, b, t)
  return { lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t) }
end
local function smooth(t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end

-- Local hours 0..24, minutes as the fraction.  A named seam so a test can
-- hand it a fixed hour.
function Time.realHours()
  local ok, d = pcall(os.date, "*t")
  if not ok or type(d) ~= "table" then return 12.0 end
  return d.hour + d.min / 60 + d.sec / 3600
end

-- Advance the cycle.  Ticks whatever the level so time keeps passing through
-- menus and battles.
function Time.update(dt, mode)
  if mode == "cycle" then
    clock = (clock + dt * 24 / Time.CYCLE_SECONDS) % 24
  end
end

-- The hour a mode shows right now; nil for "off".
function Time.hours(mode)
  if mode == "off" then return nil end
  if mode == "cycle" then return clock end
  if mode == "real" then return Time.realHours() end
  return Time.PINNED[mode] or Time.PINNED.day
end

-- The sun's direction (unit, toward the light) at `h`; after dark it is the
-- moon's, a fixed high one in the south-west so the shaded sides stay shaded.
-- The second return is how much of the day's sunlight is in play (0 at night).
local function bodyDir(h)
  local sun = 0
  local x, y, z = -0.30, 0.70, 0.65
  if h >= SUNRISE and h <= SUNSET then
    local s = (h - SUNRISE) / (SUNSET - SUNRISE)
    local th = math.pi * s                      -- east -> south -> west
    local el = math.rad(22 + 40 * math.sin(math.pi * s))
    x, y, z = math.cos(th) * math.cos(el), math.sin(el), math.sin(th) * math.cos(el)
    sun = 1
  end
  local l = math.sqrt(x * x + y * y + z * z)
  return { x / l, y / l, z / l }, sun
end

-- The look at hour `h`.  `outdoor` and `weather` come from the ctx: indoors the
-- light is neutral and the sky black, and weather greys the day out.
function Time.env(h, outdoor, weather)
  if not outdoor then
    local l = math.sqrt(0.35 ^ 2 + 0.8 ^ 2 + 0.5 ^ 2)
    return {
      ambient = { .62, .62, .62 }, sun = { .45, .45, .45 },
      dir = { .35 / l, .8 / l, .5 / l },
      zenith = { 0, 0, 0 }, horizon = { 0, 0, 0 },
      lamps = 0, stars = 0, body = nil, overcast = 0, shadow = 0.7,
      lit = false,
    }
  end
  -- the mode is OFF: fixed noon, whatever the weather
  if not h then h, weather = 12, 0 end
  h = h % 24
  local a, b = KEYS[1], KEYS[#KEYS]
  for i = 1, #KEYS - 1 do
    if h >= KEYS[i][1] and h <= KEYS[i + 1][1] then a, b = KEYS[i], KEYS[i + 1] break end
  end
  local t = (b[1] == a[1]) and 0 or (h - a[1]) / (b[1] - a[1])
  local env = {
    ambient = lerp3(a[2], b[2], t), sun = lerp3(a[3], b[3], t),
    zenith = lerp3(a[4], b[4], t), horizon = lerp3(a[5], b[5], t),
    lamps = lerp(a[6], b[6], t), lit = true,
  }
  local dir, daySun = bodyDir(h)
  env.dir = dir
  -- the moon is dimmer than the sun was; its keyframe colour already says so.
  -- How much of the scene's light a shadow can take out follows the body.
  env.shadow = 0.4 + 0.6 * daySun

  local o = OVERCAST[weather or 0] or 0
  env.overcast = o
  env.shadow = env.shadow * (1 - 0.6 * o)
  if o > 0 then
    local lum = 0.3 * env.horizon[1] + 0.59 * env.horizon[2] + 0.11 * env.horizon[3]
    local grey = { GREY[1] * (0.4 + lum), GREY[2] * (0.4 + lum), GREY[3] * (0.4 + lum) }
    for i = 1, 3 do
      env.sun[i] = env.sun[i] * (1 - 0.65 * o)
      env.ambient[i] = lerp(env.ambient[i], math.min(env.ambient[i] + 0.06, 0.62), o)
    end
    env.zenith = lerp3(env.zenith, { grey[1] * 0.8, grey[2] * 0.8, grey[3] * 0.8 }, 0.7 * o)
    env.horizon = lerp3(env.horizon, grey, 0.7 * o)
    -- rain and ash put the lamps on early
    env.lamps = math.max(env.lamps, 0.25 * o)
  end

  -- stars come out with the dark and are hidden by cloud
  env.stars = smooth((env.lamps - 0.5) / 0.5) * (1 - o)

  -- the body on its arc across the sky: x 0..1 and how high it stands, 0..1
  if h >= SUNRISE and h <= SUNSET then
    local s = (h - SUNRISE) / (SUNSET - SUNRISE)
    env.body = { kind = "sun", x = s, y = math.sin(math.pi * s) }
  else
    local n = (h >= SUNSET) and (h - SUNSET) / (24 - SUNSET + SUNRISE)
      or (h + 24 - SUNSET) / (24 - SUNSET + SUNRISE)
    env.body = { kind = "moon", x = n, y = math.sin(math.pi * n) }
  end
  if o >= 0.8 then env.body = nil end
  return env
end

return Time

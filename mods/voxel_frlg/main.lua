-- Voxel Overworld (FireRed / LeafGreen): the Gen 3 field as a 3D diorama,
-- shipped as a rendering-pipeline mod.
--
-- The engine's render_pipelines registry lets a mod own the world pass.  On
-- Gen 3 the hook is Display.drawFieldPlane, which builds a ctx
-- (src/core/game3/field_pipeline.lua) -- the metatile cells, their atlases,
-- the camera and the sorted actors -- and composites whatever Canvas this
-- returns.  Returning nil falls back to the flat game for that frame.
--
-- Terrain is extruded from the metatile grid (lib/Terrain.lua); characters are
-- drawn by the engine into a small atlas and stood up as cards
-- (lib/Actors.lua); the scene is a depth-buffered perspective camera that
-- orbits the player (lib/Gfx.lua).
--
-- Presentational only: it changes what the world LOOKS like, never where
-- anybody stands.

local mod = ...

local V = { mod = mod, path = mod.path }

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local source = mod:read("lib/" .. name .. ".lua")
  if not source then
    error(("VOXEL_FRLG: lib/%s.lua is missing -- reinstall the mod"):format(name), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/lib/" .. name .. ".lua")
  if not chunk then
    error(("VOXEL_FRLG: lib/%s.lua did not compile: %s"):format(name, tostring(err)), 0)
  end
  local value = chunk(V)
  modules[name] = value
  return value
end

local Gfx = V.require("Gfx")
local Terrain = V.require("Terrain")
local Actors = V.require("Actors")
local Fx = V.require("Fx")

-- ------- the ladder
--
-- Degrees the camera is tipped off straight down: 15 is nearly the flat game's
-- own view with depth, 65 leans toward the horizon.
local LABELS = { "OFF", "15", "35", "50", "65" }
local ANGLE = { [1] = 15, [2] = 35, [3] = 50, [4] = 65 }
local FOV = math.rad(35)
local SKY = { 0.55, 0.74, 0.95 }

local state = { tilt = 35 }

-- The scene canvas's size in FRAMEBUFFER pixels.  ctx.width / ctx.height are
-- the window in LOVE units, but the engine composites a pipeline's canvas at
-- 1/dpi scale, so a canvas sized in units would land small in the corner on a
-- high-DPI display.
local function sceneSize(ctx)
  if love.graphics.getPixelDimensions then
    local pw, ph = love.graphics.getPixelDimensions()
    if pw and ph and pw > 0 and ph > 0 then return pw, ph end
  end
  return ctx.width, ctx.height
end

local function groundAt(ctx)
  return function(x, z)
    local c = ctx.cell(math.floor(x / 16), math.floor(z / 16))
    if not c then return 0 end
    if c.class == "water" then return Terrain.HEIGHT.water end
    return 0
  end
end

local function drawWorld(ctx)
  if not Gfx.available() then return nil end
  local sw, sh = sceneSize(ctx)

  -- characters first: they are drawn into their own atlas, which cannot be
  -- done with the scene canvas bound
  local list = Actors.render(ctx)
  Fx.render(ctx)

  local tilt = state.tilt
  local focus = { ctx.camX + ctx.viewW / 2, 0, ctx.camY + ctx.viewH / 2 }
  local dist = (ctx.viewH / 2) / math.tan(FOV / 2)
  local vp, eye = Gfx.camera(focus, tilt, dist, FOV, sw / sh)

  -- how much ground the view takes in, in cells: the width and height of the
  -- flat view, stretched toward the horizon as the camera tips
  local lean = 1 / math.cos(math.rad(math.min(tilt, 70))) + 0.5
  local rx = math.ceil(ctx.viewW / 32 * 1.45) + 3
  local ry = math.ceil(ctx.viewH / 32 * lean * 1.3) + 3
  local chunks = Terrain.visible(ctx, focus[1] / 16, focus[3] / 16 - ry * 0.25, rx, ry)

  if not Gfx.begin(sw, sh, vp, eye, SKY, dist * 1.6, dist * 5.5) then return nil end
  Terrain.draw(chunks)
  Fx.draw(ctx)
  Actors.draw(list, groundAt(ctx), math.rad((90 - tilt) * 0.8))
  local scene = Gfx.finish()
  Fx.screen(ctx, scene, sw, sh)
  return scene
end

mod.content.render_pipelines:register("voxel_frlg", {
  label = "VOXEL",
  levels = LABELS,
  -- 3 is the engine's TILT key and 4 its zoom; 6 is free
  hotkey = "6",
  priority = 20,

  -- a headless run, or a driver with no depth canvas / shader support, answers
  -- false and keeps the flat game
  available = function() return Gfx.available() end,

  update = function(dt, level)
    local target = ANGLE[level]
    if target then
      state.tilt = state.tilt + (target - state.tilt) * math.min(1, dt * 8)
      if math.abs(target - state.tilt) < 0.05 then state.tilt = target end
    end
  end,

  drawWorld = drawWorld,

  invalidate = function()
    Gfx.invalidate()
    Terrain.invalidate()
    Actors.invalidate()
    Fx.invalidate()
  end,
})

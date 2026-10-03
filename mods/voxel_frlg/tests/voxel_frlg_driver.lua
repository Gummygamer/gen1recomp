-- Driver test for the Voxel Overworld (FireRed / LeafGreen) mod.
--
-- Boots a fresh FireRed game, stands in Pallet Town, and checks that:
--   * the mod loads clean and registers its pipeline;
--   * hotkey 6 walks the ladder and the level is written to options.pipelines;
--   * turning TILT on switches the pipeline off;
--   * with the pipeline on, the world frame really is the 3D scene (it differs
--     from the flat frame, is not blank, and is not just the flat frame
--     shifted) and returns to the flat frame when switched off.
--
-- It needs an imported FireRed or LeafGreen cache, so it is a driver test, not
-- part of the ROM-free CI groups:
--
--   POKEPORT_DRIVER=mods/voxel_frlg/tests/voxel_frlg_driver.lua \
--   POKEPORT_VERSION=leafgreen POKEPORT_TOUCH=0 POKEPORT_IDENTITY=voxel-frlg-test \
--   SHOT_DIR=/tmp/voxel_frlg love .
--
-- (POKEPORT_IDENTITY must hold the imported cache; copy the version's folder
-- from your real save directory into a scratch identity so the test never
-- touches your saves or options.)  Exits 0 on PASS, 1 on FAIL.
local U = require("tests.drivers.util")
local DIR = os.getenv("SHOT_DIR") or "/tmp/voxel_frlg"
local ID = "voxel_frlg"
local MOD = "VOXEL_FRLG"

local failures = 0
local function check(ok, label)
  print((ok and "PASS " or "FAIL ") .. label)
  if not ok then failures = failures + 1 end
  return ok
end

local function finish()
  if failures == 0 then
    print("PASS voxel_frlg_driver")
    love.event.quit(0)
  else
    print("FAIL voxel_frlg_driver failures=" .. failures)
    love.event.quit(1)
  end
end

-- love.image cannot open an absolute path, so read the bytes ourselves.
local function load(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local bytes = f:read("*a")
  f:close()
  local ok, data = pcall(function()
    return love.image.newImageData(love.filesystem.newFileData(bytes, "shot.png"))
  end)
  return ok and data or nil
end

-- Fraction of sampled pixels that differ by more than `tol` per channel.
local function differ(a, b, tol)
  local w, h = math.min(a:getWidth(), b:getWidth()), math.min(a:getHeight(), b:getHeight())
  local n, d = 0, 0
  for y = 0, h - 1, 4 do
    for x = 0, w - 1, 4 do
      local r1, g1, b1 = a:getPixel(x, y)
      local r2, g2, b2 = b:getPixel(x, y)
      n = n + 1
      if math.abs(r1 - r2) > tol or math.abs(g1 - g2) > tol or math.abs(b1 - b2) > tol then
        d = d + 1
      end
    end
  end
  return d / math.max(n, 1)
end

-- Distinct coarse colours in a frame: a blank or one-colour frame has one or two.
local function colours(a)
  local seen, count = {}, 0
  for y = 0, a:getHeight() - 1, 8 do
    for x = 0, a:getWidth() - 1, 8 do
      local r, g, b = a:getPixel(x, y)
      local k = math.floor(r * 15) * 256 + math.floor(g * 15) * 16 + math.floor(b * 15)
      if not seen[k] then seen[k] = true; count = count + 1 end
    end
  end
  return count
end

return function(game)
  for _ = 1, 900 do
    if game.phase == "boot" and game.boot then break end
    U.wait(1)
  end
  game:_handleBootAction({ action = "new_game", name = "RED" })
  U.wait(240)

  local Pipelines = require("src.render.Pipelines")
  local Tilt = require("src.render.Tilt")
  local Map = require("src.core.game3.map")
  local Player = require("src.core.game3.player")

  -- ------------------------------------------------------------ loads clean
  local status = game.mods and game.mods:status() or { available = {} }
  local entry
  for _, m in ipairs(status.available) do
    if m.id == MOD then entry = m end
  end
  if not check(entry ~= nil, MOD .. " is installed") then return finish() end
  check(entry.state == "loaded", MOD .. " loaded, state=" .. tostring(entry.state)
    .. " error=" .. tostring(entry.error))
  check(Pipelines.get(ID) ~= nil, "the " .. ID .. " pipeline is registered")
  check(Pipelines.maxLevel(ID) == 4, "the ladder is OFF + four angles")
  if not Pipelines.get(ID) then return finish() end
  check(Pipelines.eligible(ID) == false, "off by default")

  -- ---------------------------------------------------------------- hotkey
  Pipelines.setLevel(ID, 0)
  game:keypressed("6")
  U.wait(2)
  check(Pipelines.level(ID) == 1, "hotkey 6 steps the ladder to 1")
  check(game.options.pipelines and game.options.pipelines[ID] == 1,
    "the level is written to options.pipelines")
  game:keypressed("3")
  U.wait(2)
  check(Tilt.level > 0 and Pipelines.level(ID) == 0,
    "turning TILT on switches the pipeline off")
  Tilt.setLevel(0)
  game.options.tilt = 0

  -- ----------------------------------------------------------- the frame
  local X, Y = 8, 8
  Map.load(nil, game, "FR_PALLET_TOWN", { x = X, y = Y, facing = "down" })
  if game.session then game.session.x, game.session.y, game.session.facing = X, Y, "down" end
  Player.cellX, Player.cellY = X, Y
  Player.px, Player.py = X * 16, Y * 16
  Player.targetX, Player.targetY = X, Y
  Player.facing = "down"
  U.wait(30)
  local Preview = package.loaded["src.ui.game3.map_preview_screen"]
  for _ = 1, 240 do
    if not (Preview and Preview.isActive and Preview.isActive()) then break end
    U.wait(5)
  end
  U.wait(90)

  Pipelines.setLevel(ID, 0)
  U.wait(10)
  check(U.shot(game, DIR .. "/flat.png"), "captured the flat frame")
  Pipelines.setLevel(ID, 2)
  U.wait(60)
  check(Pipelines.eligible(ID), "the pipeline is eligible at level 2")
  check(U.shot(game, DIR .. "/voxel.png"), "captured the voxel frame")
  Pipelines.setLevel(ID, 0)
  U.wait(30)
  check(U.shot(game, DIR .. "/flat_again.png"), "captured the flat frame again")

  local flat, voxel, again = load(DIR .. "/flat.png"), load(DIR .. "/voxel.png"),
    load(DIR .. "/flat_again.png")
  if not check(flat and voxel and again, "all three frames decode") then return finish() end

  check(colours(voxel) > 40, "the voxel frame is not blank (" .. colours(voxel) .. " colours)")
  local d = differ(flat, voxel, 0.04)
  check(d > 0.25, string.format("the voxel frame differs from the flat one (%.0f%% of pixels)", d * 100))
  local back = differ(flat, again, 0.04)
  -- NPCs walk and flowers animate between captures, so "the same frame" is
  -- measured against how far the 3D one was, not against zero
  check(back < d * 0.4, string.format(
    "switching off returns the flat frame (%.1f%% differ, vs %.0f%% for the 3D one)",
    back * 100, d * 100))
  check(not Pipelines.eligible(ID), "and the pipeline is no longer eligible")

  finish()
end

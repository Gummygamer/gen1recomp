-- Characters as cards.
--
-- The flat game draws each actor (the player, NPCs, a follower, field effects)
-- through its own sprite pipeline: OW sprite sheets, palettes, walk phases,
-- bobbing.  Rather than reimplement any of that, each actor is drawn BY THE
-- ENGINE (ctx.drawActor) into its own slot of a small atlas canvas, and the
-- slot is then stood up in the scene as a card that leans back toward the
-- camera.  Occlusion is the depth buffer: walk behind a building and the
-- building is simply in front.

local V = ...
local Gfx = V.require("Gfx")

local Actors = {}

-- A slot is SLOT x SLOT px.  The actor's 16x16 cell sits at (CELL_X, CELL_Y)
-- inside it: room for 24 px either side (a 64px sprite is centred on its
-- cell) and 32 px above the cell for tall sprites.
local CELL = 16
local SLOT = 64
local CELL_X, CELL_Y = 24, 32
local COLS, ROWS = 8, 8
local MAX = COLS * ROWS

local atlas
local mesh, meshCap = nil, 0

local function ensureAtlas()
  if atlas then return atlas end
  local ok, c = pcall(love.graphics.newCanvas, COLS * SLOT, ROWS * SLOT, { dpiscale = 1 })
  if not ok or not c then return nil end
  c:setFilter("nearest", "nearest")
  atlas = c
  return atlas
end

-- ------- shadows
--
-- A soft ellipse on the ground under every character and NPC.  The flat game
-- has none, but a card standing on a lit diorama reads as floating without
-- one.  Two alpha bands, so it stays pixel art.

local SHADOW_W, SHADOW_H = 16, 8
local shadowImage
local shadowMesh

local function shadowTexture()
  if shadowImage then return shadowImage end
  local ok, img = pcall(function()
    local data = love.image.newImageData(SHADOW_W, SHADOW_H)
    for y = 0, SHADOW_H - 1 do
      for x = 0, SHADOW_W - 1 do
        local dx, dy = (x + 0.5 - SHADOW_W / 2) / (SHADOW_W / 2), (y + 0.5 - SHADOW_H / 2) / (SHADOW_H / 2)
        local d = dx * dx + dy * dy
        local a = d < 0.5 and 0.34 or d < 1 and 0.18 or 0
        data:setPixel(x, y, 0, 0, 0, a)
      end
    end
    local image = love.graphics.newImage(data)
    image:setFilter("nearest", "nearest")
    return image
  end)
  shadowImage = ok and img or nil
  return shadowImage
end

-- `groundAt(x, z)` answers the column top under a point.  Water gets none.
function Actors.shadows(list, groundAt)
  local img = shadowTexture()
  if not img then return end
  local verts, map, n = {}, {}, 0
  for _, d in ipairs(list) do
    if d.slot and (d.kind == "player" or d.kind == "npc") then
      local gx, gz = d.x, d.y - 4
      local gy = groundAt(gx, gz)
      if gy >= 0 then
        gy = gy + 0.12
        local hw, hh = SHADOW_W / 2 - 1, SHADOW_H / 2
        verts[#verts + 1] = { gx - hw, gy, gz - hh, 0, 0, 1, 1, 1, 1 }
        verts[#verts + 1] = { gx + hw, gy, gz - hh, 1, 0, 1, 1, 1, 1 }
        verts[#verts + 1] = { gx + hw, gy, gz + hh, 1, 1, 1, 1, 1, 1 }
        verts[#verts + 1] = { gx - hw, gy, gz + hh, 0, 1, 1, 1, 1, 1 }
        Gfx.pushQuad(map, n)
        n = n + 1
      end
    end
  end
  if n == 0 then return end
  if shadowMesh then shadowMesh:release() end
  shadowMesh = Gfx.mesh(verts, map, "stream")
  if not shadowMesh then return end
  shadowMesh:setTexture(img)
  Gfx.depthBias(4e-4)
  Gfx.soft(true)
  love.graphics.draw(shadowMesh)
  Gfx.soft(false)
  Gfx.depthBias(0)
end

function Actors.invalidate()
  if shadowMesh and shadowMesh.release then pcall(shadowMesh.release, shadowMesh) end
  shadowMesh = nil
  if atlas and atlas.release then pcall(atlas.release, atlas) end
  if mesh and mesh.release then pcall(mesh.release, mesh) end
  atlas, mesh, meshCap = nil, nil, 0
end

-- Draw every actor into its slot.  Must run BEFORE the scene canvas is bound.
-- Returns the list it drew, each entry { desc, slot }.
function Actors.render(ctx)
  local list = ctx.actors()
  if #list == 0 then return list end
  local a = ensureAtlas()
  if not a then return {} end
  love.graphics.push("all")
  love.graphics.setCanvas(a)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.origin()
  love.graphics.setBlendMode("alpha")
  for i, d in ipairs(list) do
    if i > MAX then break end
    local sx = ((i - 1) % COLS) * SLOT
    local sy = math.floor((i - 1) / COLS) * SLOT
    d.slot = i
    love.graphics.setScissor(sx, sy, SLOT, SLOT)
    love.graphics.setColor(1, 1, 1, 1)
    local ok = pcall(ctx.drawActor, d, sx + CELL_X, sy + CELL_Y)
    if not ok then d.slot = nil end
  end
  love.graphics.setScissor()
  love.graphics.pop()
  return list
end

-- Build and draw the cards.  `groundAt(x, z)` answers the column top under a
-- point; `lean` is the card's tilt toward the camera, in radians.
function Actors.draw(list, groundAt, lean)
  if not atlas or #list == 0 then return end
  local verts, map, n = {}, {}, 0
  local aw, ah = COLS * SLOT, ROWS * SLOT
  local cosL, sinL = math.cos(lean), math.sin(lean)
  for _, d in ipairs(list) do
    if d.slot then
      local i = d.slot - 1
      local sx = (i % COLS) * SLOT
      local sy = math.floor(i / COLS) * SLOT
      local u0, v0 = (sx + 0.02) / aw, (sy + 0.02) / ah
      local u1, v1 = (sx + SLOT - 0.02) / aw, (sy + SLOT - 0.02) / ah
      -- the foot: the bottom edge of the actor's cell, standing a little
      -- inside it so a card never z-fights the wall in front of it
      local fx, fz = d.x, d.y - 2
      local fy = groundAt(fx, fz) + 0.5
      -- the slot's row CELL_Y + 16 is the foot; up is the card's own up,
      -- leaned back toward the camera
      local ux, uy, uz = 0, cosL, -sinL
      local function pt(px, py, u, v)
        -- px in [0, SLOT] across, py in [0, SLOT] down the slot
        local across = px - SLOT / 2
        local up = (CELL_Y + CELL - py)    -- pixels above the foot
        return { fx + across, fy + uy * up, fz + uz * up, u, v, 1, 1, 1, 1 }
      end
      verts[#verts + 1] = pt(0, 0, u0, v0)
      verts[#verts + 1] = pt(SLOT, 0, u1, v0)
      verts[#verts + 1] = pt(SLOT, SLOT, u1, v1)
      verts[#verts + 1] = pt(0, SLOT, u0, v1)
      Gfx.pushQuad(map, n)
      n = n + 1
    end
  end
  if n == 0 then return end
  if mesh and meshCap >= #verts then
    mesh:setVertices(verts)
  else
    if mesh and mesh.release then pcall(mesh.release, mesh) end
    mesh = Gfx.mesh(verts, map, "stream")
    meshCap = #verts
  end
  if not mesh then return end
  mesh:setVertexMap(map)
  mesh:setDrawRange(1, n * 6)
  mesh:setTexture(atlas)
  love.graphics.draw(mesh)
end

return Actors

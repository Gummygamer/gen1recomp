-- The flat game's 2D field effects, placed in the scene.
--
-- Door-opening animations, the tall grass under the avatar's body and weather
-- that sits below the actors are drawn by the engine as ordinary 2D sprites in
-- VIEW coordinates.  Rather than reimplement them, they are drawn (by the
-- engine, through ctx.drawFx) into a transparent canvas the size of the flat
-- view, and that canvas is laid on the ground as one quad -- so a door
-- animation lands in its doorway, and a wall in front of it hides it, because
-- the quad is depth-tested like everything else.
--
-- Rain, snow, fog and sandstorm are screen-space in the original, so they go
-- over the finished scene unprojected -- and so does the dark-cave (Flash)
-- mask, a hole around the view's centre, which the camera keeps on the player.

local V = ...
local Gfx = V.require("Gfx")

local Fx = {}

-- clip-space depth the ground layer is pulled forward by: enough to win
-- against the ground it lies on, not enough to show through a wall
local GROUND_BIAS = 4e-4
local LIFT = 0.05

local canvas, cw, ch
local mesh

local function ensure(w, h)
  if canvas and cw == w and ch == h then return canvas end
  if canvas and canvas.release then pcall(canvas.release, canvas) end
  local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
  if not ok or not c then canvas = nil return nil end
  c:setFilter("nearest", "nearest")
  canvas, cw, ch = c, w, h
  return canvas
end

function Fx.invalidate()
  if canvas and canvas.release then pcall(canvas.release, canvas) end
  if mesh and mesh.release then pcall(mesh.release, mesh) end
  canvas, mesh = nil, nil
end

-- Draw the ground effects into their canvas.  Must run BEFORE the scene
-- canvas is bound.
function Fx.render(ctx)
  local c = ensure(ctx.viewW, ctx.viewH)
  if not c then return end
  love.graphics.push("all")
  love.graphics.setCanvas(c)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.origin()
  love.graphics.setBlendMode("alpha")
  pcall(ctx.drawFx, "ground")
  love.graphics.pop()
end

-- Lay the effects on the ground under the view.  Inside the scene pass.
function Fx.draw(ctx)
  if not canvas then return end
  local x0, z0 = ctx.camX, ctx.camY
  local x1, z1 = x0 + ctx.viewW, z0 + ctx.viewH
  local verts = {
    { x0, LIFT, z0, 0, 0, 1, 1, 1, 1 },
    { x1, LIFT, z0, 1, 0, 1, 1, 1, 1 },
    { x1, LIFT, z1, 1, 1, 1, 1, 1, 1 },
    { x0, LIFT, z1, 0, 1, 1, 1, 1, 1 },
  }
  if mesh then
    mesh:setVertices(verts)
  else
    mesh = Gfx.mesh(verts, { 1, 2, 3, 1, 3, 4 }, "stream")
  end
  if not mesh then return end
  mesh:setTexture(canvas)
  Gfx.depthBias(GROUND_BIAS)
  love.graphics.draw(mesh)
  Gfx.depthBias(0)
end

-- Screen-space layers over the finished scene, which is `target` (a w x h
-- canvas): weather, then the Flash mask.
function Fx.screen(ctx, target, w, h)
  if not target then return end
  love.graphics.push("all")
  love.graphics.setCanvas(target)
  love.graphics.origin()
  love.graphics.scale(w / ctx.viewW, h / ctx.viewH)
  love.graphics.setBlendMode("alpha")
  pcall(ctx.drawFx, "weather")
  pcall(ctx.drawFx, "flash")
  love.graphics.pop()
end

return Fx

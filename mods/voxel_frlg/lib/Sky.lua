-- The sky behind the diorama: a gradient from the zenith to the horizon, stars
-- after dark, and the sun or moon on its arc.  Only the part above the ground
-- plane's vanishing line is ever visible, and only when the camera is tipped
-- far enough to see past the map's edge (the steeper rungs); everywhere else
-- the scene canvas is simply cleared to the horizon colour, which is also the
-- haze the distant ground fades into.

local V = ...

local Sky = {}

-- Where the ground plane's vanishing line lands, in canvas pixels down from
-- the top, or nil when this camera has no horizon in view.  A direction ALONG
-- the ground is a point at infinity; putting one through the same matrix the
-- geometry is drawn with gives the line every ground plane converges on, so
-- the gradient's pale end meets the horizon at any tilt, fov or window shape.
-- (`vp` is row-major with the clip-space Y flip already baked in.)
function Sky.horizon(vp, eye, focus, h)
  local dx, dz = focus[1] - eye[1], focus[3] - eye[3]
  local len = math.sqrt(dx * dx + dz * dz)
  if len < 1e-6 then return nil end
  dx, dz = dx / len, dz / len
  local y = vp[5] * dx + vp[7] * dz
  local w = vp[13] * dx + vp[15] * dz
  if w <= 1e-6 then return nil end
  return (y / w * 0.5 + 0.5) * h
end

-- A deterministic star field in unit square coordinates.
local stars
local function field()
  if stars then return stars end
  stars = {}
  local seed = 12345
  local function rnd()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
  end
  for i = 1, 140 do
    stars[i] = { rnd(), rnd(), 0.5 + rnd() * 0.5, rnd() * 6.28 }
  end
  return stars
end

local mesh
local function gradient(w, hy, top, bottom)
  local verts = {
    { 0, 0, 0, 0, top[1], top[2], top[3], 1 },
    { w, 0, 1, 0, top[1], top[2], top[3], 1 },
    { w, hy, 1, 1, bottom[1], bottom[2], bottom[3], 1 },
    { 0, hy, 0, 1, bottom[1], bottom[2], bottom[3], 1 },
  }
  if not mesh then
    mesh = love.graphics.newMesh(4, "fan", "stream")
  end
  mesh:setVertices(verts)
  love.graphics.draw(mesh)
end

-- Paint the sky into the canvas that is currently bound (w x h), before any
-- depth or scene shader is set.  `hy` is Sky.horizon's answer.
function Sky.paint(w, h, hy, env, scale, time)
  if not env.lit or not hy then return end
  hy = math.min(hy, h)
  if hy <= 0 then return end
  love.graphics.setColor(1, 1, 1, 1)
  gradient(w, hy, env.zenith, env.horizon)

  if env.stars > 0.01 then
    local s = math.max(1, math.floor(scale))
    for _, st in ipairs(field()) do
      local twinkle = 0.65 + 0.35 * math.sin(time * 1.7 + st[4])
      love.graphics.setColor(1, 1, 0.92, env.stars * st[3] * twinkle)
      love.graphics.rectangle("fill", math.floor(st[1] * w), math.floor(st[2] * hy * 0.95), s, s)
    end
  end

  local b = env.body
  if b then
    local bx = w * (0.12 + 0.76 * b.x)
    local by = hy - (hy * 0.12 + hy * 0.72 * b.y)
    local r = math.max(6, 7 * scale)
    if b.kind == "sun" then
      -- a pale halo, then the disc
      love.graphics.setColor(1, 0.92, 0.7, 0.18)
      love.graphics.circle("fill", bx, by, r * 2.6)
      love.graphics.setColor(1, 0.96, 0.78, 1)
      love.graphics.circle("fill", bx, by, r)
    else
      love.graphics.setColor(0.85, 0.9, 1, 0.12)
      love.graphics.circle("fill", bx, by, r * 2.2)
      love.graphics.setColor(0.92, 0.95, 1, 1)
      love.graphics.circle("fill", bx, by, r * 0.85)
      -- a bite out of it, in the sky's own colour, for a crescent
      love.graphics.setColor(env.zenith[1] * 0.5 + env.horizon[1] * 0.5,
        env.zenith[2] * 0.5 + env.horizon[2] * 0.5,
        env.zenith[3] * 0.5 + env.horizon[3] * 0.5, 1)
      love.graphics.circle("fill", bx + r * 0.35, by - r * 0.1, r * 0.75)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Sky.invalidate()
  if mesh and mesh.release then pcall(mesh.release, mesh) end
  mesh = nil
end

return Sky

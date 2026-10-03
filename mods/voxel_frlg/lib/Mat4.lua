-- 4x4 matrix math for the 3D pass.  Row-major, sent to the shader with
-- shader:send(name, "row", m) so the tables read the way they are written.
-- Adapted from the Dramatic Shape Voxel Mod's lib/Mat4.lua (MIT).

local Mat4 = {}

function Mat4.mul(a, b)
  local o = {}
  for r = 0, 3 do
    local a0, a1, a2, a3 = a[r * 4 + 1], a[r * 4 + 2], a[r * 4 + 3], a[r * 4 + 4]
    for c = 1, 4 do
      o[r * 4 + c] = a0 * b[c] + a1 * b[4 + c] + a2 * b[8 + c] + a3 * b[12 + c]
    end
  end
  return o
end

function Mat4.scale(x, y, z)
  return { x, 0, 0, 0,  0, y, 0, 0,  0, 0, z, 0,  0, 0, 0, 1 }
end

-- Right-handed perspective onto GL clip space (z in [-1, 1]).
function Mat4.perspective(fovY, aspect, near, far)
  local f = 1 / math.tan(fovY / 2)
  local d = near - far
  return { f / aspect, 0, 0, 0,
           0, f, 0, 0,
           0, 0, (far + near) / d, (2 * far * near) / d,
           0, 0, -1, 0 }
end

-- Right-handed look-at; eye / target / up are { x, y, z }.
function Mat4.lookAt(eye, target, up)
  local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
  local function norm(v)
    local l = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    if l == 0 then return { 0, 0, 0 } end
    return { v[1] / l, v[2] / l, v[3] / l }
  end
  local function cross(a, b)
    return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3],
             a[1] * b[2] - a[2] * b[1] }
  end
  local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
  local f = norm(sub(target, eye))
  local s = norm(cross(f, up))
  local u = cross(s, f)
  return { s[1], s[2], s[3], -dot(s, eye),
           u[1], u[2], u[3], -dot(u, eye),
          -f[1], -f[2], -f[3], dot(f, eye),
           0, 0, 0, 1 }
end

return Mat4

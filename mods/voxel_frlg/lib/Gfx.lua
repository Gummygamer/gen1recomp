-- The 3D pass's GPU plumbing: the shader, the colour + depth canvas, and the
-- camera matrix.  Everything is pcall-guarded and `available()` reports the
-- result, so a headless run or a driver without depth canvases keeps the flat
-- game rather than erroring.
--
-- World space is GAME PIXELS, so every coordinate the field already works in
-- drops straight in: +X east, +Z south (the map's y), +Y up, ground at 0.

local V = ...
local Mat4 = V.require("Mat4")
local Sky = V.require("Sky")

local Gfx = {}

-- position, the atlas coordinate it samples (normalised), and a colour that
-- carries the face's shade
Gfx.FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexColor", "byte", 4 },
}

local SHADER = [[
  varying float vDist;
#ifdef VERTEX
  uniform mat4 vp;
  uniform vec3 eye;
  uniform float depthBias;     // pulls a coplanar decal toward the camera
  vec4 position(mat4 transform_projection, vec4 vertex_position) {
    vDist = distance(vertex_position.xyz, eye);
    vec4 p = vp * vertex_position;
    p.z -= depthBias * p.w;
    return p;
  }
#endif
#ifdef PIXEL
  uniform vec3 fogColor;
  uniform vec2 fogRange;       // x = where haze starts, y = where it is total
  uniform float cutoff;        // alpha below this is discarded, not blended
  uniform float soft;          // 1 = blend by alpha instead (shadows)
  uniform vec3 ambient;        // the light every face gets
  uniform vec3 sunColor;       // the sun's (after dark, the moon's) colour
  uniform vec3 sunDir;         // unit, toward the light
  uniform float lamps;         // 0 = day .. 1 = windows fully lit
  uniform vec3 lampColor;

  // Vertex alpha carries WHICH FACE a surface is, not transparency: 0 top,
  // 1 south, 2 east, 3 west, 4 north, 5 a character card -- plus 8 when the
  // surface is a building wall whose windows may light up.  16 steps across
  // the byte, so it survives the round trip exactly.
  vec3 faceNormal(float code) {
    if (code < 0.5) return vec3(0.0, 1.0, 0.0);
    if (code < 1.5) return vec3(0.0, 0.0, 1.0);
    if (code < 2.5) return vec3(1.0, 0.0, 0.0);
    if (code < 3.5) return vec3(-1.0, 0.0, 0.0);
    return vec3(0.0, 0.0, -1.0);
  }

  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 p = Texel(tex, tc);
    float f = clamp((vDist - fogRange.x) / max(fogRange.y - fogRange.x, 1.0), 0.0, 1.0);
    if (soft > 0.5) {
      // a shadow fades out into the haze with everything else
      return vec4(p.rgb * color.rgb, p.a * color.a * (1.0 - f * f));
    }
    // alpha-tested rather than blended: a sprite or an eave never writes its
    // transparent texels into the depth buffer, so it cannot cut a hole in
    // what stands behind it
    if (p.a < cutoff) discard;

    float code = floor(color.a * 16.0 + 0.5);
    bool windowWall = code >= 8.0;
    if (windowWall) code -= 8.0;
    vec3 light;
    if (code > 4.5) {
      // a card faces the camera, so it takes a fair share of the sun
      light = ambient + sunColor * 0.7;
    } else {
      light = ambient + sunColor * max(dot(faceNormal(code), sunDir), 0.0);
    }
    vec3 rgb = p.rgb * light;

    // Lit windows.  Nothing in a metatile says which pixels are glass, but
    // FireRed's panes are the one saturated light blue on a building, so a
    // blue-dominant texel on a wall lights up with the lamps.
    if (windowWall && lamps > 0.01) {
      float glass = step(0.34, p.b - p.r) * step(0.5, p.b) * step(0.05, p.b - p.g);
      float lum = dot(p.rgb, vec3(0.299, 0.587, 0.114));
      rgb = mix(rgb, lampColor * (0.7 + 0.55 * lum), lamps * 0.92 * glass);
    }
    return vec4(mix(rgb, fogColor, f * f), 1.0);
  }
#endif
]]

local shader, shaderFailed

function Gfx.shader()
  if shader ~= nil then return shader or nil end
  if shaderFailed then return nil end
  local ok, sh = pcall(love.graphics.newShader, SHADER)
  if ok and sh then
    shader = sh
  else
    shaderFailed = true
    shader = false
  end
  return shader or nil
end

function Gfx.available()
  return love.graphics ~= nil and love.graphics.newCanvas ~= nil
    and love.graphics.setDepthMode ~= nil and Gfx.shader() ~= nil
end

-- ------- the scene target

local held   -- { canvas, w, h }

local function release()
  if held and held.canvas and held.canvas.release then
    pcall(held.canvas.release, held.canvas)
  end
  held = nil
end

function Gfx.invalidate()
  release()
end

-- The camera: an orbit around `focus` (world pixels) at `tilt` degrees off
-- straight down, `dist` pixels away, looking along the ground at `fov`.
-- Returns the view-projection matrix and the eye.
function Gfx.camera(focus, tilt, dist, fov, aspect)
  local a = math.rad(tilt)
  local eye = { focus[1], focus[2] + dist * math.cos(a), focus[3] + dist * math.sin(a) }
  -- perpendicular to the view direction in the YZ plane: north is screen-up
  -- when looking straight down, +Y when looking level.  Never parallel to it.
  local up = { 0, math.sin(a), -math.cos(a) }
  local proj = Mat4.perspective(fov, aspect, math.max(1, dist * 0.08), dist * 8 + 1024)
  -- We bypass LOVE's transform_projection, whose canvas Y runs DOWN, so the
  -- clip-space Y is flipped here or the scene lands mirrored top to bottom.
  -- The winding flips with it, which is free: the pass draws with culling off.
  proj = Mat4.mul(Mat4.scale(1, -1, 1), proj)
  return Mat4.mul(proj, Mat4.lookAt(eye, focus, up)), eye
end

-- Open the pass: bind a w x h colour canvas with a depth buffer, paint the sky
-- (`env`, from Time.env), and set the scene shader and its light.  Returns
-- false (and leaves the canvas unbound) when any of it will not build.
function Gfx.begin(w, h, vp, eye, focus, env, fogNear, fogFar, scale, time)
  local sh = Gfx.shader()
  if not sh then return false end
  if not (held and held.w == w and held.h == h) then
    release()
    local ok, c = pcall(love.graphics.newCanvas, w, h, { dpiscale = 1 })
    if not ok or not c then return false end
    c:setFilter("nearest", "nearest")
    held = { canvas = c, w = w, h = h }
  end
  local ok = pcall(love.graphics.setCanvas, { held.canvas, depth = true })
  if not ok then
    pcall(love.graphics.setCanvas)
    return false
  end
  local hz = env.horizon
  love.graphics.clear(hz[1], hz[2], hz[3], 1, true, true)
  -- the sky goes down while a rectangle is still just a rectangle: before the
  -- depth mode and the scene shader are set
  pcall(Sky.paint, w, h, Sky.horizon(vp, eye, focus, h), env, scale or 1, time or 0)
  love.graphics.setDepthMode("lequal", true)
  love.graphics.setMeshCullMode("none")
  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  pcall(sh.send, sh, "vp", "row", vp)
  pcall(sh.send, sh, "eye", eye)
  pcall(sh.send, sh, "fogColor", { hz[1], hz[2], hz[3] })
  pcall(sh.send, sh, "fogRange", { fogNear, fogFar })
  pcall(sh.send, sh, "cutoff", 0.5)
  pcall(sh.send, sh, "depthBias", 0)
  pcall(sh.send, sh, "soft", 0)
  pcall(sh.send, sh, "ambient", env.ambient)
  pcall(sh.send, sh, "sunColor", env.sun)
  pcall(sh.send, sh, "sunDir", env.dir)
  pcall(sh.send, sh, "lamps", env.lamps)
  pcall(sh.send, sh, "lampColor", { 1.0, 0.82, 0.48 })
  return true
end

-- Pull everything drawn next toward the camera by `bias` (clip-space depth
-- units, ~1e-4).  A decal laid exactly on a surface then wins the depth test
-- without floating above it, which would show a gap at its edge.
function Gfx.depthBias(bias)
  local sh = Gfx.shader()
  if sh then pcall(sh.send, sh, "depthBias", bias or 0) end
end

-- Blend by alpha, testing depth but not writing it, for what is drawn next (a
-- shadow); pass false to go back to the alpha-tested opaque draws.
function Gfx.soft(on)
  local sh = Gfx.shader()
  if sh then pcall(sh.send, sh, "soft", on and 1 or 0) end
  love.graphics.setDepthMode("lequal", not on)
end

-- Close the pass and hand back its colour canvas.
function Gfx.finish()
  love.graphics.setShader()
  love.graphics.setDepthMode()
  love.graphics.setMeshCullMode("none")
  love.graphics.setCanvas()
  return held and held.canvas or nil
end

-- A mesh in the shared format from a flat vertex list and a triangle index
-- list; nil when there is nothing to draw or the driver refuses.
function Gfx.mesh(verts, map, usage)
  if #verts == 0 then return nil end
  local ok, mesh = pcall(love.graphics.newMesh, Gfx.FORMAT, verts, "triangles",
                         usage or "static")
  if not ok then return nil end
  if map and #map > 0 then pcall(mesh.setVertexMap, mesh, map) end
  return mesh
end

-- Append the six indices of quad `n` (0-based) to a triangle index list.
function Gfx.pushQuad(map, n)
  local b = n * 4
  map[#map + 1] = b + 1
  map[#map + 1] = b + 2
  map[#map + 1] = b + 3
  map[#map + 1] = b + 1
  map[#map + 1] = b + 3
  map[#map + 1] = b + 4
end

return Gfx

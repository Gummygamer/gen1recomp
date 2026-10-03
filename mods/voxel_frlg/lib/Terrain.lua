-- The map as geometry.
--
-- The field is a grid of 16px metatiles, each with an under layer and an over
-- layer (the eaves, canopies and counter tops the flat game draws above the
-- actors).  This turns every cell into a column: solid things stand up, water
-- sinks, ground stays level.  Each column's top is the cell's own metatile art
-- seen from above, and each exposed side is the same art stood on end, so a
-- house reads as a house from the front and as its roof from above.
--
-- Cells are meshed in CHUNKS of CHUNK x CHUNK, one mesh per atlas and layer,
-- because a chunk can straddle two connected maps with different tilesets.
-- Meshes are static: they are rebuilt only when ctx.epoch changes (a metatile
-- write, a tileset reload, a map change), and the atlas TEXTURE is rebound at
-- draw time because the engine swaps animated atlases (water, flowers) under
-- the same pair every few frames.

local V = ...
local Gfx = V.require("Gfx")

local Terrain = {}

local CELL = 16
local CHUNK = 8
-- clip-space depth a decal is pulled forward by; a few depth-buffer steps
local DECAL_BIAS = 2e-4

-- Column tops, in game pixels.  Water sinks, ground is level, and a solid cell
-- stands as tall as the structure it belongs to: a fence or a sign is one cell
-- deep from north to south, a tree two, a house three or more, so the height
-- comes from the length of the run of solid cells down its column (see
-- runHeight) rather than from anything the metatile says about itself.
Terrain.HEIGHT = {
  ground = 0,
  ledge = 0,
  water = -3,
}
Terrain.RUN_HEIGHT = { 8, 14, 18, 22 }     -- by run length, 1 / 2 / 3 / 4 or more
-- an over layer on walkable ground with nothing solid south of it is an
-- overhead sheet held above it (a gate, a bridge)
Terrain.OVERHEAD = 18

-- Which face a quad is, carried in the vertex alpha (see the shader): the
-- lighting works out how much sun each one catches.  + 8 marks a building wall
-- whose windows may light up at night.
local FACE = { top = 0, south = 1, east = 2, west = 3, north = 4 }
local WINDOW = 8

local chunks = {}        -- key -> { x, y, meshes = { {mesh, ts, layer} }, complete }
local cellCache = {}     -- key -> the fields a build reads from one cell
local lastEpoch
-- Once the first frame is drawn, chunks build nearest-first under a time
-- budget, so walking into new ground costs a slice of a frame, never a hitch.
local BUILD_MS = 2.5
-- cells past the view the build runs ahead by, so a chunk is ready before
-- the camera reaches it
local PREFETCH = 12
local EVICT_EVERY = 300      -- frames between sweeps for far-off chunks
local evictClock = 0

local function key(cx, cy)
  return (cy + 4096) * 8192 + (cx + 4096)
end

function Terrain.invalidate()
  for _, c in pairs(chunks) do
    for _, m in ipairs(c.meshes) do
      if m.mesh and m.mesh.release then pcall(m.mesh.release, m.mesh) end
    end
  end
  chunks = {}
  cellCache = {}
  lastEpoch = nil
end

-- A cell stands up if it is solid, or if it is the overhang of something solid:
-- a tree's canopy and a roof's top edge are walkable cells whose over layer
-- belongs to the structure just south of them.  Left as a sheet at a fixed
-- height they float, with a hairline of ground showing under the edge, so they
-- join the structure instead.
local function isSolid(c)
  return c.class == "wall" or c.class == "void" or c.attached == true
end

-- Build one chunk.  Reads a skirt around it: one cell either side so the
-- sides facing a neighbouring chunk know how tall that neighbour is, and
-- RUN_REACH rows above and below so a solid structure is measured whole
-- however the chunk boundary cuts it.
local RUN_REACH = 3
local function build(ctx, cx0, cy0)
  local x0, y0 = cx0 * CHUNK, cy0 * CHUNK
  local W = CHUNK + 2
  local top = y0 - RUN_REACH - 1
  local rows = CHUNK + 2 * (RUN_REACH + 1)
  local function idx(x, y) return (y - top) * W + (x - (x0 - 1)) + 1 end
  local info = {}
  local complete = true
  for y = top, top + rows - 1 do
    for x = x0 - 1, x0 + CHUNK do
      -- every cell is read by the chunks around it (the skirt), so what the
      -- engine answered is kept for the life of the epoch; a cell whose atlas
      -- has not streamed in yet is not kept, and marks the chunk incomplete
      local k = key(x, y)
      local rec = cellCache[k]
      if not rec then
        local c = ctx.cell(x, y)
        if c then
          rec = { pair = c.pair, slot = c.slot, ts = c.ts, class = c.class,
                  hasUnder = c.hasUnder, hasOver = c.hasOver }
          cellCache[k] = rec
        end
      end
      if rec then
        -- h is per build: copy so a chunk's heights never leak into another's
        info[idx(x, y)] = { pair = rec.pair, slot = rec.slot, ts = rec.ts,
          class = rec.class, hasUnder = rec.hasUnder, hasOver = rec.hasOver }
      else
        complete = false
        info[idx(x, y)] = false
      end
    end
  end
  -- overhangs, swept south to north so a two-row overhang chains
  for y = top + rows - 2, top, -1 do
    for x = x0 - 1, x0 + CHUNK do
      local c, south = info[idx(x, y)], info[idx(x, y + 1)]
      if c and south and c.class == "ground" and c.hasOver and isSolid(south) then
        c.attached = true
      end
    end
  end
  -- column heights, for the cells whose tops get drawn and their neighbours
  local function runHeight(x, y)
    local run = 1
    for d = 1, RUN_REACH do
      local c = info[idx(x, y - d)]
      if not (c and isSolid(c)) then break end
      run = run + 1
    end
    for d = 1, RUN_REACH do
      local c = info[idx(x, y + d)]
      if not (c and isSolid(c)) then break end
      run = run + 1
    end
    return Terrain.RUN_HEIGHT[math.min(run, #Terrain.RUN_HEIGHT)]
  end
  for y = y0 - 1, y0 + CHUNK do
    for x = x0 - 1, x0 + CHUNK do
      local c = info[idx(x, y)]
      if c then
        c.h = isSolid(c) and runHeight(x, y) or (Terrain.HEIGHT[c.class] or 0)
      end
    end
  end

  local buckets = {}       -- pair .. layer -> { verts, map, quads, ts, layer }
  local function bucket(ts, pair, layer)
    local k = pair .. layer
    local b = buckets[k]
    if not b then
      b = { verts = {}, map = {}, quads = 0, ts = ts, layer = layer, pair = pair }
      buckets[k] = b
    end
    return b
  end

  -- one quad: four corners { x, y, z, u, v }, which face it is
  local function quad(b, c1, c2, c3, c4, face)
    local v = b.verts
    local code = face / 16
    for _, c in ipairs({ c1, c2, c3, c4 }) do
      v[#v + 1] = { c[1], c[2], c[3], c[4], c[5], 1, 1, 1, code }
    end
    Gfx.pushQuad(b.map, b.quads)
    b.quads = b.quads + 1
  end

  -- The atlas rectangle of a slot, normalised and inset a hair so nearest
  -- sampling at a quad edge never bleeds the neighbouring metatile in.
  local function uvRect(ts, slot)
    local img = ts.image or ts.overImage
    local aw, ah = img:getDimensions()
    local sx = (slot % ts.cols) * CELL
    local sy = math.floor(slot / ts.cols) * CELL
    local e = 0.02
    return (sx + e) / aw, (sy + e) / ah, (sx + CELL - e) / aw, (sy + CELL - e) / ah
  end

  for ly = 0, CHUNK - 1 do
    for lx = 0, CHUNK - 1 do
      local c = info[idx(x0 + lx, y0 + ly)]
      if c then
        local wx, wz = (x0 + lx) * CELL, (y0 + ly) * CELL
        local h = c.h
        local u0, v0, u1, v1 = uvRect(c.ts, c.slot)
        local under = bucket(c.ts, c.pair, "u")
        -- only the SIDE of a building's own wall has windows: a roof is not
        -- glass (a Poke Mart's is blue), a tree or a rock has no panes, and the
        -- pond's blue is not glass
        local win = (c.class == "wall" and not c.attached) and WINDOW or 0

        -- top face: the metatile's own art, seen from above
        quad(under,
          { wx, h, wz, u0, v0 }, { wx + CELL, h, wz, u1, v0 },
          { wx + CELL, h, wz + CELL, u1, v1 }, { wx, h, wz + CELL, u0, v1 },
          FACE.top)

        -- the over layer: an overhead sheet above walkable ground, a decal
        -- laid on the top of a solid
        if c.hasOver and c.ts.overImage then
          -- on a solid it lies ON the top face ("d": drawn with a depth bias so
          -- it wins without floating); over open ground it is a sheet held
          -- above ("o")
          local solid = h > 0
          local ob = bucket(c.ts, c.pair, solid and "d" or "o")
          local oh = solid and h or Terrain.OVERHEAD
          quad(ob,
            { wx, oh, wz, u0, v0 }, { wx + CELL, oh, wz, u1, v0 },
            { wx + CELL, oh, wz + CELL, u1, v1 }, { wx, oh, wz + CELL, u0, v1 },
            FACE.top)
        end

        -- sides: wherever the next cell is lower, stand the art on end
        local function side(nx, ny, face, a, b2, c3, d)
          local n = info[idx(x0 + lx + nx, y0 + ly + ny)]
          local nh = n and n.h or h
          if nh < h then
            -- corners are given as {x, z} pairs, top then bottom
            local function pt(p, y, u, v) return { p[1], y, p[2], u, v } end
            quad(under,
              pt(a, h, u0, v0), pt(b2, h, u1, v0),
              pt(c3, nh, u1, v1), pt(d, nh, u0, v1), face + win)
          end
        end
        -- south face: left to right as the camera sees it
        side(0, 1, FACE.south,
          { wx, wz + CELL }, { wx + CELL, wz + CELL },
          { wx + CELL, wz + CELL }, { wx, wz + CELL })
        -- east face: south edge to north edge is left to right from outside
        side(1, 0, FACE.east,
          { wx + CELL, wz + CELL }, { wx + CELL, wz },
          { wx + CELL, wz }, { wx + CELL, wz + CELL })
        side(-1, 0, FACE.west,
          { wx, wz }, { wx, wz + CELL },
          { wx, wz + CELL }, { wx, wz })
        side(0, -1, FACE.north,
          { wx + CELL, wz }, { wx, wz },
          { wx, wz }, { wx + CELL, wz })
      end
    end
  end

  local out = { x = cx0, y = cy0, meshes = {}, complete = complete, tries = 0 }
  for _, b in pairs(buckets) do
    local mesh = Gfx.mesh(b.verts, b.map)
    if mesh then
      out.meshes[#out.meshes + 1] = { mesh = mesh, ts = b.ts, layer = b.layer }
    end
  end
  return out
end

-- Rebuild what changed and answer which chunks cover the view.
-- `rx`, `ry` are the half-extent in cells around (fx, fy), a cell position.
-- Chunks out to PREFETCH cells beyond that are built too, but not returned.
function Terrain.visible(ctx, fx, fy, rx, ry)
  if ctx.epoch ~= lastEpoch then
    Terrain.invalidate()
    lastEpoch = ctx.epoch
  end
  local first = next(chunks) == nil
  local want = {}
  local cxa = math.floor((fx - rx - PREFETCH) / CHUNK)
  local cxb = math.floor((fx + rx + PREFETCH) / CHUNK)
  local cya = math.floor((fy - ry - PREFETCH) / CHUNK)
  local cyb = math.floor((fy + ry + PREFETCH) / CHUNK)
  for cy = cya, cyb do
    for cx = cxa, cxb do
      -- chunk centre against the focus, in cells
      local dx, dy = (cx + 0.5) * CHUNK - fx, (cy + 0.5) * CHUNK - fy
      local inView = math.abs(dx) <= rx + CHUNK / 2 and math.abs(dy) <= ry + CHUNK / 2
      want[#want + 1] = { cx = cx, cy = cy, d = dx * dx + dy * dy, inView = inView }
    end
  end
  table.sort(want, function(a, b) return a.d < b.d end)

  -- Forget what the camera has left far behind: every few seconds, drop the
  -- chunks (and the cell answers they were built from) beyond twice the
  -- prefetch ring.  Cells are re-asked of the engine as needed.
  evictClock = evictClock + 1
  if evictClock >= EVICT_EVERY then
    evictClock = 0
    local keep = {}
    for _, w in ipairs(want) do keep[key(w.cx, w.cy)] = true end
    local ex = (rx + PREFETCH * 2) / CHUNK + 1
    local ey = (ry + PREFETCH * 2) / CHUNK + 1
    for k, c in pairs(chunks) do
      if not keep[k]
          and (math.abs((c.x + 0.5) * CHUNK - fx) > ex * CHUNK
            or math.abs((c.y + 0.5) * CHUNK - fy) > ey * CHUNK) then
        for _, m in ipairs(c.meshes) do
          if m.mesh and m.mesh.release then pcall(m.mesh.release, m.mesh) end
        end
        chunks[k] = nil
      end
    end
    cellCache = {}
  end

  local out = {}
  local started = love.timer.getTime()
  for _, w in ipairs(want) do
    local k = key(w.cx, w.cy)
    local c = chunks[k]
    -- a chunk whose atlas was still streaming in is retried, a few times a
    -- second, until it completes
    if c and not c.complete then
      c.tries = c.tries + 1
      if c.tries % 20 == 0 then c = nil end
    end
    if not c then
      -- the first frame builds the whole view so nothing pops in; after that
      -- the budget spends on the nearest missing chunk first, which the
      -- prefetch ring keeps well ahead of the camera
      local spent = (love.timer.getTime() - started) * 1000
      if (first and w.inView) or spent < BUILD_MS then
        c = build(ctx, w.cx, w.cy)
        chunks[k] = c
      end
    end
    if c and w.inView then out[#out + 1] = c end
  end
  return out
end

-- Draw the meshes of `list` with the atlas textures as they are RIGHT NOW.
function Terrain.draw(list)
  for _, layer in ipairs({ "u", "d", "o" }) do
    Gfx.depthBias(layer == "d" and DECAL_BIAS or 0)
    for _, c in ipairs(list) do
      for _, m in ipairs(c.meshes) do
        if m.layer == layer then
          local img = (layer == "u") and m.ts.image or m.ts.overImage
          if img then
            m.mesh:setTexture(img)
            love.graphics.draw(m.mesh)
          end
        end
      end
    end
  end
  Gfx.depthBias(0)
end

return Terrain

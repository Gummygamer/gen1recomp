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

-- What the engine answered for one cell, kept for the life of the epoch: every
-- cell is read by the chunks around it and by the height lookup.  nil while the
-- cell's atlas is still streaming in (and then it is not kept).
local function cellRec(ctx, cx, cy)
  local k = key(cx, cy)
  local rec = cellCache[k]
  if not rec then
    local c = ctx.cell(cx, cy)
    if c then
      rec = { pair = c.pair, slot = c.slot, ts = c.ts, class = c.class,
              hasUnder = c.hasUnder, hasOver = c.hasOver, overPixels = c.overPixels }
      cellCache[k] = rec
    end
  end
  return rec
end

function Terrain.invalidate()
  for _, c in pairs(chunks) do
    if Terrain._releaseProps then Terrain._releaseProps(c) end
    for _, m in ipairs(c.meshes) do
      if m.mesh and m.mesh.release then pcall(m.mesh.release, m.mesh) end
    end
  end
  chunks = {}
  cellCache = {}
  lastEpoch = nil
end

-- ------- what stands up, and what stands as a card
--
-- A cell is SOLID if it is a wall or the border, and a walkable cell joins the
-- solid south of it when its over layer is that structure's overhang (a tree's
-- canopy, a roof's top edge): left as a sheet at a fixed height such a cell
-- floats, with a hairline of ground showing under its edge.
--
-- How tall a solid structure is comes from its run: the cells stacked down its
-- column.  A fence or a sign is one deep, a tree three counting the canopy, a
-- house four or more.  Outdoors the short ones -- trees, boulders, signs,
-- bushes -- are PROPS: boxing them up repeats one tile across every face and
-- they read as cubes, so they stand as sprite cards instead, like the
-- characters, with their ground colour keyed away.  The tall ones stay boxes.
-- `get(x, y)` answers a cell record or nil, so the same rules serve the mesher
-- (its local skirt) and the height lookup (the cache).
local RUN_REACH = 3
local MAX_STACK = 8          -- the tallest prop that is still stacked as one object
Terrain.PROP_MAX_RUN = 3
-- the border (past every connected map) is trees on most outdoor maps
Terrain.PROP_VOID = true

local keyed          -- defined below with the keying; the prop test needs it

local function solidRec(r)
  return r ~= nil and (r.class == "wall" or r.class == "void")
end

local function attachedAt(get, x, y, depth)
  local r = get(x, y)
  if not (r and r.class == "ground" and r.hasOver) then return false end
  local south = get(x, y + 1)
  if not south then return false end
  return solidRec(south) or (depth < RUN_REACH and attachedAt(get, x, y + 1, depth + 1))
end

local function solidish(get, x, y)
  local r = get(x, y)
  return r ~= nil and (solidRec(r) or attachedAt(get, x, y, 0))
end

-- cells of the structure stacked through (x, y), capped.  The border (void) is
-- not part of any structure: it is a field of trees of its own, and counting it
-- would make every tree at the edge of a map a house.
local function structureCell(get, x, y)
  local r = get(x, y)
  if r == nil or r.class == "void" then return false end
  return solidish(get, x, y)
end

local function runAt(get, x, y)
  local run = 1
  for d = 1, RUN_REACH do
    if not structureCell(get, x, y - d) then break end
    run = run + 1
  end
  for d = 1, RUN_REACH do
    if not structureCell(get, x, y + d) then break end
    run = run + 1
  end
  return run
end

-- Is this one cell, by its art, part of a grove?  A tile whose pixels are mostly
-- green, or one that is mostly ground with next to nothing over it (the gap
-- between trunks).
local function foliageCell(get, x, y)
  local r = get(x, y)
  if not (r and r.class == "wall" and r.ts) then return false end
  local k = keyed(r.ts)
  if k == nil then return false end
  return k.foliage[r.slot] == true
    or ((not r.hasOver or (r.overPixels or 0) <= 24) and k.groundish[r.slot] == true)
end

-- A single cell of a tree can look like anything (the middle of a trunk is
-- mostly ground), so a column of solid cells is foliage if ANY cell of it is.
local function groveAt(get, x, y)
  if foliageCell(get, x, y) then return true end
  for _, dir in ipairs({ -1, 1 }) do
    for d = 1, RUN_REACH do
      if not structureCell(get, x, y + dir * d) then break end
      if foliageCell(get, x, y + dir * d) then return true end
    end
  end
  return false
end

-- How many cells wide the structure through (x, y) is, capped.  A fence line, a
-- hedge or a pole is one or two across however far it runs; a building is wider.
local function widthAt(get, x, y)
  local width = 1
  for d = 1, 3 do
    if not structureCell(get, x - d, y) then break end
    width = width + 1
  end
  for d = 1, 3 do
    if not structureCell(get, x + d, y) then break end
    width = width + 1
  end
  return width
end
Terrain.PROP_MAX_WIDTH = 2

-- Does the cell at (x, y) stand as a card?  The border always does; a wall does
-- when its structure is short or is a grove; an overhang is part of what it
-- hangs on.
local function isProp(get, x, y, outdoor, depth)
  if not outdoor then return false end
  local r = get(x, y)
  if not r then return false end
  if r.class == "void" then return Terrain.PROP_VOID end
  if r.class == "wall" then
    return runAt(get, x, y) <= Terrain.PROP_MAX_RUN
      or widthAt(get, x, y) <= Terrain.PROP_MAX_WIDTH or groveAt(get, x, y)
  end
  if (depth or 0) < RUN_REACH and attachedAt(get, x, y, 0) then
    return isProp(get, x, y + 1, outdoor, (depth or 0) + 1)
  end
  return false
end

local function runHeight(run)
  return Terrain.RUN_HEIGHT[math.min(run, #Terrain.RUN_HEIGHT)]
end

-- ------- the colour of a tile's sides
--
-- A box's east, west and north faces are seen edge-on and at an angle, where one
-- tile stretched across them just repeats the same picture on every face and
-- reads as a cube.  The art stays on the top and on the front (south) face,
-- where it reads as a roof and a facade; the other sides take the tile's average
-- colour, which the lighting then shades.
local averages = setmetatable({}, { __mode = "k" })

local function averageColour(ts, slot)
  local byTs = averages[ts]
  if not byTs then
    byTs = {}
    averages[ts] = byTs
  end
  local hit = byTs[slot]
  if hit then return hit[1], hit[2], hit[3] end
  local data = ts.imageData
  local r, g, b, n = 0, 0, 0, 0
  if data then
    local sx, sy = (slot % ts.cols) * CELL, math.floor(slot / ts.cols) * CELL
    for y = sy, sy + CELL - 1 do
      for x = sx, sx + CELL - 1 do
        local pr, pg, pb, pa = data:getPixel(x, y)
        if pa > 0.5 then r, g, b, n = r + pr, g + pg, b + pb, n + 1 end
      end
    end
  end
  if n == 0 then r, g, b, n = 0.5, 0.5, 0.5, 1 end
  byTs[slot] = { r / n, g / n, b / n }
  return r / n, g / n, b / n
end

local whiteImage
local function white()
  if whiteImage then return whiteImage end
  local ok, image = pcall(function()
    local data = love.image.newImageData(1, 1)
    data:setPixel(0, 0, 1, 1, 1, 1)
    local img = love.graphics.newImage(data)
    img:setFilter("nearest", "nearest")
    return img
  end)
  whiteImage = ok and image or nil
  return whiteImage
end

-- ------- keying a tileset's ground colour away
--
-- The art of a tree sits on the tile's own ground colour in the under layer, so
-- a prop's card is that tile with the ground colour made transparent.  The
-- colour is the one most of the atlas is painted in (the grass, the floor); a
-- tuft of darker grass on a tile is not it and stays, as part of the sprite.
-- Also found here: the atlas slot that is nearly all ground, which a prop's
-- own cell is laid with so no painted tree lies flat under the standing one.
local keyedCache = setmetatable({}, { __mode = "k" })
local KEY_TOLERANCE = 14        -- summed channel distance, 0..765

keyed = function(ts)
  local hit = keyedCache[ts]
  if hit ~= nil then return hit or nil end
  local data = ts.imageData
  if not data then
    keyedCache[ts] = false
    return nil
  end
  -- The ground colour is the one that is the BACKGROUND OF THE MOST TILES, not
  -- the one with the most pixels: in a forest tileset the tall grass outweighs
  -- the path it grows beside, but only the ground sits behind every tree, sign
  -- and ledge.  A tile votes for its commonest colour if that covers a quarter
  -- of it.
  local cols, rows = ts.cols, ts.rows
  local votes, bestKey, bestN = {}, nil, 0
  for slot = 0, cols * rows - 1 do
    local sx, sy = (slot % cols) * CELL, math.floor(slot / cols) * CELL
    local hist, top, topN = {}, nil, 0
    for y = sy, sy + CELL - 1 do
      for x = sx, sx + CELL - 1 do
        local r, g, b, a = data:getPixel(x, y)
        if a > 0.5 then
          local k = math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256
            + math.floor(b * 255 + 0.5)
          local n = (hist[k] or 0) + 1
          hist[k] = n
          if n > topN then top, topN = k, n end
        end
      end
    end
    if top and topN >= 64 then
      local n = (votes[top] or 0) + 1
      votes[top] = n
      if n > bestN then bestKey, bestN = top, n end
    end
  end
  if not bestKey then
    keyedCache[ts] = false
    return nil
  end
  local br, bg, bb = math.floor(bestKey / 65536), math.floor(bestKey / 256) % 256, bestKey % 256
  local function ground(r, g, b)
    return math.abs(r * 255 - br) + math.abs(g * 255 - bg) + math.abs(b * 255 - bb) <= KEY_TOLERANCE
  end
  -- the slot that is nearly all ground, and which slots are foliage: tiles
  -- whose non-ground pixels are mostly green.  A deep mass of trees is as big as
  -- a building by shape, so colour is what tells them apart.
  local plain, plainN = nil, 0
  local foliage, groundish = {}, {}
  for slot = 0, cols * rows - 1 do
    local sx, sy = (slot % cols) * CELL, math.floor(slot / cols) * CELL
    local n, other, green = 0, 0, 0
    for y = sy, sy + CELL - 1 do
      for x = sx, sx + CELL - 1 do
        local r, g, b, a = data:getPixel(x, y)
        if a > 0.5 then
          if ground(r, g, b) then
            n = n + 1
          else
            other = other + 1
            -- greenish, dark outlines and shadows included: brown rock, grey stone, blue and
            -- orange roofs are not
            if g >= r and g - b >= 0.04 then green = green + 1 end
          end
        end
      end
    end
    if n > plainN then plain, plainN = slot, n end
    foliage[slot] = other >= 30 and green / other >= 0.5
    -- a tree's centre tile is all over layer: the ground colour (or nothing)
    -- below, the canopy above
    local od = ts.overImageData
    if od and not foliage[slot] then
      local on, og = 0, 0
      for y = sy, sy + CELL - 1 do
        for x = sx, sx + CELL - 1 do
          local r, g, b, a = od:getPixel(x, y)
          if a > 0.5 and not ground(r, g, b) then
            on = on + 1
            if g >= r and g - b >= 0.04 then og = og + 1 end
          end
        end
      end
      foliage[slot] = on >= 30 and og / on >= 0.5
    end
    -- a tile that is mostly ground is the gap between trunks; kept apart, because
    -- it only counts for a cell with next to nothing in its over layer (a roof's
    -- corner tile is mostly ground too, but it has an eave on it)
    groundish[slot] = n >= 110
  end
  local copy = data:clone()
  copy:mapPixel(function(_, _, r, g, b, a)
    if a > 0.5 and ground(r, g, b) then return r, g, b, 0 end
    return r, g, b, a
  end)
  local ok, image = pcall(love.graphics.newImage, copy)
  if not ok then
    keyedCache[ts] = false
    return nil
  end
  image:setFilter("nearest", "nearest")
  -- the over layer of a tree's centre column is a full tile with the ground
  -- colour around the canopy, so it is keyed the same way
  local over
  if ts.overImageData then
    local overCopy = ts.overImageData:clone()
    overCopy:mapPixel(function(_, _, r, g, b, a)
      if a > 0.5 and ground(r, g, b) then return r, g, b, 0 end
      return r, g, b, a
    end)
    local okO, img = pcall(love.graphics.newImage, overCopy)
    if okO then
      img:setFilter("nearest", "nearest")
      over = img
    end
  end
  local entry = { image = image, over = over, plain = plainN >= 230 and plain or nil,
    foliage = foliage, groundish = groundish }
  keyedCache[ts] = entry
  return entry
end

-- Build one chunk.  Reads a skirt around it: one cell either side so the
-- sides facing a neighbouring chunk know how tall that neighbour is, and
-- RUN_REACH rows above and below so a solid structure is measured whole
-- however the chunk boundary cuts it.
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
      local rec = cellRec(ctx, x, y)
      if rec then
        -- h is per build: copy so a chunk's heights never leak into another's
        info[idx(x, y)] = { pair = rec.pair, slot = rec.slot, ts = rec.ts,
          class = rec.class, hasUnder = rec.hasUnder, hasOver = rec.hasOver,
          overPixels = rec.overPixels }
      else
        complete = false
        info[idx(x, y)] = false
      end
    end
  end
  local outdoor = ctx.outdoor and ctx.mapType ~= 5
  local function cached(x, y) return cellRec(ctx, x, y) end
  local function get(x, y)
    local r = info[idx(x, y)]
    if r ~= nil then return r or nil end
    -- outside this build's skirt (the width of a long structure): the cache
    if x >= x0 - 1 and x <= x0 + CHUNK and y >= top and y < top + rows then return nil end
    return cellRec(ctx, x, y)
  end
  -- classify every cell the build reads: its column height, and whether it
  -- stands as a card instead of a box
  for y = y0 - 1, y0 + CHUNK do
    for x = x0 - 1, x0 + CHUNK do
      local c = info[idx(x, y)]
      if c then
        c.attached = attachedAt(get, x, y, 0)
        if isProp(get, x, y, outdoor) then
          c.prop = true
          c.h = 0
        elseif c.class == "void" then
          -- indoors the border is a tall dark wall all round the room
          c.h = runHeight(#Terrain.RUN_HEIGHT)
        elseif c.attached or solidRec(c) then
          c.h = runHeight(runAt(get, x, y))
        else
          c.h = Terrain.HEIGHT[c.class] or 0
        end
      end
    end
  end

  local props = {}
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

  local function flat(ts, pair) return bucket(ts, pair, "f") end

  -- one quad: four corners { x, y, z, u, v }, which face it is
  local function quad(b, c1, c2, c3, c4, face, colour)
    local v = b.verts
    local code = face / 16
    local r, g, bl = 1, 1, 1
    if colour then r, g, bl = colour[1], colour[2], colour[3] end
    for _, c in ipairs({ c1, c2, c3, c4 }) do
      v[#v + 1] = { c[1], c[2], c[3], c[4], c[5], r, g, bl, code }
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
        local groundSlot = c.slot
        local key_ = c.prop and keyed(c.ts) or nil
        if key_ and key_.plain then groundSlot = key_.plain end
        local u0, v0, u1, v1 = uvRect(c.ts, groundSlot)
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

        -- a prop's art stands as a card (see drawProps); its own cell is just
        -- ground, with the sprite's stack position remembered
        if c.prop and key_ then
          -- how many prop cells stand below this one in its column: it is
          -- stacked on them.  Counted through the cache, not this build's skirt,
          -- so a tall tree measures the same from either side of a chunk edge.
          local below = 0
          for d = 1, MAX_STACK do
            if isProp(cached, x0 + lx, y0 + ly + d, outdoor) then below = below + 1 else break end
          end
          -- past MAX_STACK it is not one object but a mass (the border, a deep
          -- grove): each cell then stands on its own row, layered like shingles
          if below >= MAX_STACK then below = 0 end
          props[#props + 1] = { x = wx, zfoot = (y0 + ly + below + 1) * CELL, k = below,
            ts = c.ts, slot = c.slot, over = c.hasOver and c.ts.overImage ~= nil, key = key_ }
        end

        -- the over layer: an overhead sheet above walkable ground, a decal
        -- laid on the top of a solid
        if c.hasOver and c.ts.overImage and not (c.prop and key_) then
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
            if face == FACE.south then
              quad(under,
                pt(a, h, u0, v0), pt(b2, h, u1, v0),
                pt(c3, nh, u1, v1), pt(d, nh, u0, v1), face + win)
            else
              -- the other sides: the tile's average colour, flat
              local mid = ((u0 + u1) / 2)
              local midv = ((v0 + v1) / 2)
              quad(flat(c.ts, c.pair),
                pt(a, h, mid, midv), pt(b2, h, mid, midv),
                pt(c3, nh, mid, midv), pt(d, nh, mid, midv), face,
                { averageColour(c.ts, c.slot) })
            end
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

  local out = { x = cx0, y = cy0, meshes = {}, complete = complete, tries = 0, props = props }
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
        if Terrain._releaseProps then Terrain._releaseProps(c) end
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
  for _, layer in ipairs({ "u", "f", "d", "o" }) do
    Gfx.depthBias(layer == "d" and DECAL_BIAS or 0)
    for _, c in ipairs(list) do
      for _, m in ipairs(c.meshes) do
        if m.layer == layer then
          local img
          if layer == "u" then img = m.ts.image
          elseif layer == "f" then img = white()
          else img = m.ts.overImage end
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

-- ------- props: trees, boulders, signs and bushes as standing cards
--
-- Each prop cell is one 16x16 quad of its keyed art, stacked on the cells below
-- it in the same structure and leaned back toward the camera by `lean` (radians),
-- exactly as a character card is, so it reads as the flat game's own picture of
-- a tree.  The lean follows the tilt, so these are rebuilt every frame from the
-- small per-chunk lists rather than baked into the chunk meshes.
local CARD = 5 / 16          -- the face code a card carries (see Gfx's shader)
local PROP_BIAS = 3e-4
local PROP_LIFT = 0.2

local function releasePropMeshes(c)
  for _, m in ipairs(c.propMeshes or {}) do
    if m.mesh.release then pcall(m.mesh.release, m.mesh) end
  end
  c.propMeshes, c.propLean = nil, nil
end
Terrain._releaseProps = releasePropMeshes

-- One chunk's props as meshes for this lean.  Cached on the chunk: only a chunk
-- entering the view, or the camera tipping (which changes every chunk's lean),
-- pays for a build.
local function buildChunkProps(c, lean)
  releasePropMeshes(c)
  c.propMeshes, c.propLean = {}, lean
  local cosL, sinL = math.cos(lean), math.sin(lean)
  local groups = {}
  local function add(g, kind, image, p)
    local b = g[kind]
    if not b then
      b = { verts = {}, map = {}, n = 0, image = image }
      g[kind] = b
    end
    local aw, ah = image:getDimensions()
    local sx = (p.slot % p.ts.cols) * CELL
    local sy = math.floor(p.slot / p.ts.cols) * CELL
    local e = 0.02
    local u0, v0 = (sx + e) / aw, (sy + e) / ah
    local u1, v1 = (sx + CELL - e) / aw, (sy + CELL - e) / ah
    local lo, hi = CELL * p.k, CELL * (p.k + 1)
    local zf = p.zfoot - 1.5
    local x0, x1 = p.x, p.x + CELL
    local function pt(x, up, u, v)
      return { x, PROP_LIFT + cosL * up, zf - sinL * up, u, v, 1, 1, 1, CARD }
    end
    local v = b.verts
    v[#v + 1] = pt(x0, hi, u0, v0)
    v[#v + 1] = pt(x1, hi, u1, v0)
    v[#v + 1] = pt(x1, lo, u1, v1)
    v[#v + 1] = pt(x0, lo, u0, v1)
    Gfx.pushQuad(b.map, b.n)
    b.n = b.n + 1
  end
  for _, p in ipairs(c.props) do
    local g = groups[p.ts]
    if not g then
      g = {}
      groups[p.ts] = g
    end
    add(g, "u", p.key.image, p)
    if p.over and p.key.over then add(g, "o", p.key.over, p) end
  end
  for ts, g in pairs(groups) do
    for kind, b in pairs(g) do
      local mesh = Gfx.mesh(b.verts, b.map, "static")
      if mesh then
        c.propMeshes[#c.propMeshes + 1] = { mesh = mesh, ts = ts, kind = kind, image = b.image }
      end
    end
  end
end

function Terrain.drawProps(list, lean)
  Gfx.depthBias(PROP_BIAS)
  for _, c in ipairs(list) do
    if c.props and #c.props > 0 then
      if c.propLean ~= lean then buildChunkProps(c, lean) end
      for _, m in ipairs(c.propMeshes) do
        m.mesh:setTexture(m.image)
        love.graphics.draw(m.mesh)
      end
    end
  end
  Gfx.depthBias(0)
end

-- The top of the column standing at a world point: what a character on it
-- stands on.  A box is as tall as its run, a prop or an overhang is ground
-- (the character walks past or under it), water sinks.
function Terrain.heightAt(ctx, wx, wz)
  local x, y = math.floor(wx / CELL), math.floor(wz / CELL)
  local function get(cx, cy) return cellRec(ctx, cx, cy) end
  local r = get(x, y)
  if not r then return 0 end
  if r.class == "water" then return Terrain.HEIGHT.water end
  if not solidRec(r) then return 0 end
  if isProp(get, x, y, ctx.outdoor and ctx.mapType ~= 5) then return 0 end
  if r.class == "void" then return runHeight(#Terrain.RUN_HEIGHT) end
  return runHeight(runAt(get, x, y))
end

return Terrain

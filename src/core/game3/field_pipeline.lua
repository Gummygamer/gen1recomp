-- Render-pipeline seam for the Gen 3 (FireRed / LeafGreen) overworld.
--
-- Gen 1 and Gen 2 hand a mod's render pipeline a ctx and take back a finished
-- world image (src/world/OverworldController.lua, src/world/gen2/World.lua);
-- Gen 3 draws its field through FieldView on a 240x160 tile blitter, so this
-- is the same contract in the same shape for it: Display.drawFieldPlane asks
-- Pipelines.worldPipeline(), builds a ctx here, and the pipeline answers with
-- one window-resolution Canvas (or nil to decline, which falls back to the flat
-- draw).
--
-- What a pipeline gets is DATA about the field rather than drawing hooks:
-- metatile cells (with the atlas each one samples), the camera, and the sorted
-- actors, each of which can be drawn into any spot of any canvas.  That is what
-- a 3D mode needs -- it cannot reuse FieldView's own flat blit -- and it keeps
-- engine internals out of the mod.  The mod never requires an engine module.
--
-- Cells follow the native FRLG layout: one 16px metatile per cell, a `mid` that
-- indexes the pair's atlas, an under layer (BG3) and an over layer (BG1, the
-- eaves, canopies and counter tops drawn above the actors).
--
-- Presentational only, like tilt and survey zoom: nothing here reaches
-- collision, movement, scripts or the save.

local FieldView = require("src.core.game3.field_view")
local Pipelines = require("src.render.Pipelines")
local Zoom = require("src.render.Zoom")

local FieldPipeline = {}

local CELL = 16
FieldPipeline.CELL = CELL

local Map, NativeTileset, CollPermissions, MB, Interaction
local function lazy()
  if Map then return end
  Map = package.loaded["src.core.game3.map"] or require("src.core.game3.map")
  NativeTileset = require("src.core.game3.tileset_native")
  CollPermissions = require("src.core.CollPermissions")
  MB = require("src.core.game3.mb")
  Interaction = require("src.core.game3.scripting.interaction_scripts")
end

-- Cell classes a pipeline can build on without knowing Gen 3's collision codes:
--   "void"   past every connected map; the border tiling answers (FRLG: trees)
--   "water"  surfable water
--   "wall"   something solid: a building, a tree, a fence, a cliff, a sign
--   "ledge"  a one-way hop
--   "ground" anything you can stand on
local function classify(coll, behaviorName, isVoid)
  if isVoid then return "void" end
  if CollPermissions.isWater(coll) then return "water" end
  if behaviorName and behaviorName:find("WATER", 1, true)
      and not behaviorName:find("WATERFALL", 1, true) then
    return "water"
  end
  if CollPermissions.isLedge(coll) then return "ledge" end
  if CollPermissions.isWalkable(coll) then return "ground" end
  return "wall"
end

-- The slot a mid occupies in its atlas, and whether either layer has anything
-- in it.  An empty over layer is the common case, and "is there roof here" is
-- what decides whether a cell stands up, so it is answered once per (atlas,
-- slot) by scanning the layer's pixels rather than per frame.
local presence = setmetatable({}, { __mode = "k" })
local function layerPresence(ts, slot)
  local byTs = presence[ts]
  if not byTs then
    byTs = {}
    presence[ts] = byTs
  end
  local hit = byTs[slot]
  if hit then return hit[1], hit[2] end
  local function occupied(data)
    if not data then return false end
    local cols = ts.cols
    local sx, sy = (slot % cols) * CELL, math.floor(slot / cols) * CELL
    for y = sy, sy + CELL - 1 do
      for x = sx, sx + CELL - 1 do
        local _, _, _, a = data:getPixel(x, y)
        if a and a > 0 then return true end
      end
    end
    return false
  end
  local under = occupied(ts.imageData)
  local over = occupied(ts.overImageData)
  byTs[slot] = { under, over }
  return under, over
end

local cellOut = {}

-- Everything the pipeline may ask of one field frame.  Returns nil when the
-- field has nothing to draw this frame (no native layout, headless), which the
-- caller treats as "decline".
function FieldPipeline.context(game, Renderer, pipelineId)
  lazy()
  local _, _, pw, ph = Renderer:playfieldRect()
  local scale = Zoom.scale(Renderer:fitScale())
  local vw, vh = Renderer:worldViewSize()
  local frame = FieldView.pipelineFrame(game, vw, vh)
  if not frame then return nil end
  local mapDef = frame.mapDef

  local ctx = {
    gen = 3,
    width = pw, height = ph, scale = scale,
    level = Pipelines.level(pipelineId),
    mapId = frame.mapId,
    mapDef = mapDef,
    -- FieldView's own camera: the top-left of the view in world pixels, and
    -- the player's pixel position (world pixels, cell top-left)
    camX = frame.camX, camY = frame.camY,
    viewW = frame.viewW, viewH = frame.viewH,
    px = frame.px, py = frame.py, facing = frame.facing,
    cellSize = CELL,
  }

  -- Changes whenever geometry built from cells must be rebuilt: a metatile
  -- write, a tileset reload, or the set of connected maps changing.  Cheap
  -- enough to read per frame.
  local sig = {}
  for _, n in ipairs(Map.neighborList or {}) do
    sig[#sig + 1] = tostring(n.map or n.mapId) .. (n.dir or "")
  end
  ctx.epoch = tostring(FieldView._epoch) .. "|" .. tostring(frame.mapId)
    .. "|" .. tostring(mapDef) .. "|" .. table.concat(sig, ",")

  -- The atlas a pair draws from, or nil while it is still streaming in.
  function ctx.tileset(pair)
    if not (pair and NativeTileset.ready(pair)) then return nil end
    return NativeTileset.get(pair)
  end

  -- One cell in current-map coordinates (negative / past the edge reads the
  -- connected maps, then the border).  The returned table is reused: copy what
  -- you keep.  nil while the cell's atlas has not streamed in yet.
  function ctx.cell(wx, wy)
    local mid, pair, isVoid, L, lx, ly = Map.worldCellAt(wx, wy, mapDef)
    if mid == nil or pair == nil then return nil end
    local ts = ctx.tileset(pair)
    if not ts then return nil end
    local slot = NativeTileset.slotFor(ts, mid)
    local coll = (not isVoid and L and L.collAt) and L:collAt(lx, ly) or 0xff
    local elev = (not isVoid and L and L.elevAt) and L:elevAt(lx, ly) or 0
    local behaviors = Interaction.behaviors[pair]
    local behavior = behaviors and behaviors[mid]
    local behaviorName = behavior and MB.nameOf(behavior) or nil
    local underOn, overOn = layerPresence(ts, slot)
    local c = cellOut
    c.mid, c.pair, c.slot, c.ts = mid, pair, slot, ts
    c.void = isVoid
    c.coll, c.elev = coll, elev
    c.behavior, c.behaviorName = behavior, behaviorName
    c.class = classify(coll, behaviorName, isVoid)
    c.hasUnder, c.hasOver = underOn, overOn
    return c
  end

  -- Actors in draw order, as { x, y, kind, ref } where (x, y) is the foot
  -- point in world pixels.  `over` marks the ones the flat game draws above the
  -- overhead layer (bridges, jumps, escalators).
  local list = {}
  function ctx.actors()
    for i = #list, 1, -1 do list[i] = nil end
    local function add(src, over)
      for _, a in ipairs(src or {}) do
        list[#list + 1] = {
          x = (a.x or 0) + CELL / 2, y = (a.y or 0) + CELL,
          kind = a.kind, over = over, ref = a,
        }
      end
    end
    add(frame.under, false)
    add(frame.over, true)
    return list
  end

  -- Draw one actor with its cell's top-left at (ox, oy) of the current canvas.
  function ctx.drawActor(desc, ox, oy)
    FieldView.drawPipelineActor(frame, desc.ref, ox, oy)
  end

  -- The flat game's 2D field effects, drawn into the current canvas in view
  -- coordinates (origin at the view's top-left, one unit per game pixel):
  -- "ground" for what lies on the map under the actors, "weather" for the
  -- screen-space layer over everything.  See FieldView.drawPipelineFx.
  function ctx.drawFx(which)
    FieldView.drawPipelineFx(frame, which)
  end

  return ctx
end

return FieldPipeline

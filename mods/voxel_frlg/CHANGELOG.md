# Changelog

## 0.3.2

- **Fewer cubes.** Narrow tall structures (a fence line, a hedge, a pole: one or
  two cells across however far they run) now stand as sprite cards, not boxes. A
  box's east, west and north faces take the tile's average colour instead of
  repeating the tile's picture on every face; the picture stays on the top (roof)
  and the front (facade), where it reads correctly.
- **Characters no longer vanish.** A character hidden behind a building, a tree
  or a roof, or inside a column, is drawn again as a translucent ghost wherever
  something stands in front of it. In the flat game nobody disappears behind a
  house.

## 0.3.1

- **Trees are trees.** Trees, bushes, boulders, signs and the whole border of
  an outdoor map were extruded into boxes with one tile repeated on every face,
  so they read as cubes. They now stand as sprite cards, leaning toward the
  camera like the characters, with the tileset's ground colour keyed away.
  Buildings and rock walls stay solid boxes.
- **Sprites no longer vanish.** An actor standing on a cell classed as solid (the
  Poke Balls on Oak's lab table, a scientist behind a counter, an NPC at a
  museum display) was swallowed by the column; it now stands on top of it.
- Needs the engine ctx's `overPixels` on a cell (commit after `29edec3a`; see
  the README's Requirements).

## 0.3.0

- **Day and night.** A TIME row (OPTIONS > EXTRAS, hotkey 7): REAL clock
  (default), CYCLE (a day in twenty minutes), pinned DAY / DUSK / NIGHT / DAWN,
  or OFF for the old fixed daylight.
- **Lighting.** Surfaces are lit by a sun that crosses the sky east to west and
  by the moon after dark, per face, with ambient light, so tops, fronts and
  sides read as solid. Sun colour, ambient, sky and haze follow keyframes for
  dawn, morning, noon, golden hour, dusk and night.
- A sky gradient, stars, and the sun or moon on its arc (visible on the steeper
  rungs, where the camera sees past the map's edge).
- After dark, windows on buildings light up. Rain, snow, ash and fog dim the day
  and put the lamps on early.
- Interiors and caves are lit neutrally with a black sky whatever the hour.
- Needs the engine ctx's `outdoor`, `mapType` and `weather` (same seam commit
  range as 0.2.0; see the README's Requirements).

## 0.2.0

- A soft shadow under every character and NPC, so cards no longer read as
  floating.
- Tree canopies and roof edges (walkable cells whose over layer belongs to the
  solid cell south of them) now join the structure instead of floating above it
  as a sheet; this removes a hairline of ground that showed under their edge,
  and trees stand taller (a tree is now as tall as a three-cell structure).
- The Flash cave mask is drawn over the scene.
- Tall grass over the feet and shoreline reflections were checked and already
  work: both are drawn by the engine as actors and ground effects.

## 0.1.0

First release.

- The FireRed / LeafGreen overworld as a 3D diorama behind a VOXEL options row
  and hotkey 6 (OFF / 15 / 35 / 50 / 65 degrees off straight down).
- Every metatile is extruded into a column: solid structures stand up (a fence,
  a tree and a house are different heights, measured from how far the solid
  cells run), water sinks, ground stays level. The top of each column is the
  metatile's own art, the sides are the same art stood on end.
- The over layer (eaves, canopies, counter tops) is laid on the structure it
  belongs to, or held above open ground as an overhead sheet.
- Characters, followers and field effects are drawn by the engine into an atlas
  and stood up as cards that lean toward the camera; occlusion is the depth
  buffer.
- Door animations, tall grass and weather keep working: ground effects are laid
  on the map under the view, weather goes over the finished scene.
- Chunked, cached meshes with a per-frame build budget, a prefetch ring and
  eviction, so walking costs a slice of a frame, never a hitch.

# Changelog

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

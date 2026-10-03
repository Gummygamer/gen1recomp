# Voxel Overworld (FireRed / LeafGreen)

The Gen 3 overworld as a 3D diorama. FireRed and LeafGreen only (`"games":
["frlg"]`); Red, Blue and Yellow have the Dramatic Shape Voxel Mod.

It is presentational: the map, the scripts, the collision and the save are
untouched. Walk, talk, battle and warp exactly as before; only the world pass
is drawn differently.

## Requirements

This mod needs the Gen 3 render-pipeline seam in the engine: `Display.drawFieldPlane`
calling `Pipelines.drawWorld`, `Game3` installing `Pipelines`, and
`render_pipelines` kept off `Schemas.GEN3`'s drop list. Without it the mod loads
but its pipeline is dropped on a FireRed / LeafGreen boot and nothing changes.
Day/night also reads `ctx.outdoor`, `ctx.mapType` and `ctx.weather`, added in
commit `29edec3a`; on a build without them everything is lit like an interior.

The seam is in commit `bb7973d1` of
[Gummygamer/gen1recomp](https://github.com/Gummygamer/gen1recomp) (branch `dev`);
`docs/modding.md` there documents the Gen 3 ctx under "Pipelines on FireRed and
LeafGreen". A stock upstream build does not have it yet.

## Installing

Download the `.zip` from a release and use **MODS > Import mod .zip** in the game,
or copy this folder to `mods/voxel_frlg/` (manifest.json at its top level).

## Using it

- **OPTIONS > EXTRAS > VOXEL** cycles OFF / 15 / 35 / 50 / 65 -- the angle in
  degrees the camera is tipped off straight down. 15 is almost the flat game
  with depth; 65 leans toward the horizon.
- **6** cycles the same ladder in free roam.
- **OPTIONS > EXTRAS > TIME** (hotkey **7**) sets the time of day: **REAL**
  follows your computer's clock (the default), **CYCLE** runs a full day in
  twenty minutes, **DAY**, **DUSK**, **NIGHT** and **DAWN** pin an hour, and
  **OFF** keeps the fixed daylight of earlier versions.
- Turning TILT on switches this off, and the other way round: they are two
  answers to the same question.
- A battle's transition wipe, a shop and the menus draw flat, the way tilt does.

## How it works

The engine's `render_pipelines` registry lets a mod own the world pass. On Gen 3
the hook is `Display.drawFieldPlane`, which builds a ctx
(`src/core/game3/field_pipeline.lua`) and composites whatever canvas a pipeline
returns, falling back to the flat draw when it returns nil.

| piece | what it does |
| --- | --- |
| `lib/Terrain.lua` | meshes the metatile grid into chunks of columns, one mesh per atlas and layer |
| `lib/Actors.lua` | has the engine draw each actor into an atlas slot, stands the slot up as a card, and drops a soft shadow under it |
| `lib/Fx.lua` | lays the engine's 2D ground effects on the map; draws weather and the Flash mask over the scene |
| `lib/Gfx.lua` | the shader (lighting, haze, lit windows), the colour + depth canvas, the camera |
| `lib/Time.lua` | the clock modes and the keyframed light and sky colours for each hour |
| `lib/Sky.lua` | the sky gradient, stars, and the sun or moon on its arc |

The mod requires no engine module: everything it needs comes through the ctx.

### Column heights

Nothing in a metatile says how tall it is, so a solid cell stands as tall as the
structure it belongs to, measured by the run of solid cells down its column: one
cell deep (a fence, a sign) is low, two medium, three or more (a tree, a house)
tall. A walkable cell whose over layer belongs to the solid cell south of it (a
tree's canopy, a roof's top edge) counts as part of that structure. Tune
`Terrain.RUN_HEIGHT`.

## Day, night and lighting

Every surface is lit by the sun (after dark, the moon) from a direction that
moves east to west across the day, so the faces toward it are bright and the
others fall into the ambient light. The sun's colour, the ambient light, the
sky and the haze the distant ground fades into all blend between keyframes for
dawn, morning, noon, golden hour, dusk and night. After dark the stars come
out and building windows light up; rain, snow, ash and fog dim the day and
put the lamps on early.

Interiors and caves are lit neutrally with a black sky, whatever the hour: only
open-sky maps (towns, cities, routes) follow the clock.

## What carries over from the flat game

- Tall grass draws over the avatar's legs, and the shoreline reflection of a
  character on a pond's edge appears, because the engine draws both as actors
  and ground effects that this mod places in the scene.
- Door animations, weather and the Flash cave mask too.

## Known limits

- There are no cast shadows, only a soft blob under each character; the lighting
  is per face, not per pixel.
- Window glow is a colour heuristic (blue-dominant texels on a building's side
  walls), since nothing in a metatile says which pixels are glass.
- The camera does not rotate: movement is map-relative (up is always north), so
  a rotated view would make the controls disagree with the picture.
- Emerald is not claimed: it shares FieldView but this has only been run on
  FireRed and LeafGreen.

## Credits

Approach inspired by `ZallaxDev/pokeemerald-3Ds-dualscreen`'s voxel overworld and
by the Dramatic Shape Voxel Mod. `lib/Mat4.lua` is adapted from the latter (MIT),
and the clip-space Y flip and depth-canvas setup in `lib/Gfx.lua` follow its
technique; the rest is written for the Gen 3 field.

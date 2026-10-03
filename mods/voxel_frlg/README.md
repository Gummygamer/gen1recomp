# Voxel Overworld (FireRed / LeafGreen)

The Gen 3 overworld as a 3D diorama. FireRed and LeafGreen only (`"games":
["frlg"]`); Red, Blue and Yellow have the Dramatic Shape Voxel Mod.

It is presentational: the map, the scripts, the collision and the save are
untouched. Walk, talk, battle and warp exactly as before; only the world pass
is drawn differently.

## Using it

- **OPTIONS > EXTRAS > VOXEL** cycles OFF / 15 / 35 / 50 / 65 -- the angle in
  degrees the camera is tipped off straight down. 15 is almost the flat game
  with depth; 65 leans toward the horizon.
- **6** cycles the same ladder in free roam.
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
| `lib/Actors.lua` | has the engine draw each actor into an atlas slot, stands the slot up as a card |
| `lib/Fx.lua` | lays the engine's 2D ground effects on the map; draws weather and the Flash mask over the scene |
| `lib/Gfx.lua` | the shader, the colour + depth canvas, the camera |

The mod requires no engine module: everything it needs comes through the ctx.

### Column heights

Nothing in a metatile says how tall it is, so a solid cell stands as tall as the
structure it belongs to, measured by the run of solid cells down its column: one
cell deep (a fence, a sign) is low, two (a tree) medium, three or more (a house)
tall. Tune `Terrain.RUN_HEIGHT`.

## Known limits

- Tall grass lies at the avatar's feet instead of over them: a card cannot be
  overdrawn by a ground effect.
- No reflections, shadows or day/night; the water is the engine's own animated
  tiles on a sunken column.
- Emerald is not claimed: it shares FieldView but this has only been run on
  FireRed and LeafGreen.

## Credits

Approach inspired by `ZallaxDev/pokeemerald-3Ds-dualscreen`'s voxel overworld and
by the Dramatic Shape Voxel Mod. `lib/Mat4.lua` is adapted from the latter (MIT),
and the clip-space Y flip and depth-canvas setup in `lib/Gfx.lua` follow its
technique; the rest is written for the Gen 3 field.

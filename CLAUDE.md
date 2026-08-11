# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Godot 4.7 (Forward+ renderer, Jolt Physics) proof-of-concept that renders real-world map data
into a 3D scene: a hand-rolled Mapbox Vector Tile (MVT/.pbf) parser drives procedural mesh
generation for terrain features (water, landuse, roads, buildings), and a Terrain-RGB elevation
loader builds a heightmap mesh from a webp/png DEM tile. There is no gameplay — `scenes/main.tscn`
just loads one tile of each kind so the output can be eyeballed in the editor viewport.

## Running / testing

There is no CLI, build step, or test suite — this is a GDScript-only Godot project with no
compiled code. Iteration happens by opening the project in the Godot 4.7 editor and running the
main scene (`scenes/main.tscn`, F6) or the whole project (F5). There's no `godot` binary on PATH
in this environment, so verification is visual, done through the editor.

When editing `scripts/mvt_parser.gd`, `scripts/mvt_tile_renderer.gd`, or
`scenes/terrain_rgb_loader.gd`, the practical check is: run the main scene and confirm the mesh
still looks right (no missing layers, no inverted normals, no NaNs) — there's nothing to lint or
compile against.

## Architecture

Three independent pieces, wired together only through `main.tscn`:

1. **`scripts/mvt_parser.gd`** (`MVTParser`, static, `RefCounted`) — a minimal protobuf/MVT
   decoder with zero external dependencies. `parse_tile(bytes)` returns
   `{ layer_name: { extent: int, features: [{type, rings, props}] } }`. Geometry stays in
   tile-local integer space (`0..extent`); nothing here knows about world units or Godot's scene
   tree. This is the layer to touch if a `.pbf` fails to parse or a new tag/value type shows up.

2. **`scripts/mvt_tile_renderer.gd`** (`MVTTileRenderer`, `Node3D`) — consumes `MVTParser` output
   and builds `SurfaceTool` meshes: a flat ground pass (landcover/landuse/water, colored by
   `LAYER_COLORS`/`LANDUSE_CLASS_COLORS`), a line pass (roads/waterways, styled by
   `ROAD_STYLE` per road class), and an extruded-building pass (roof + walls, height from the
   `render_height` property or `default_building_height`). Each pass is one `MeshInstance3D` child
   added at `_ready()`. Layers are drawn ground-up at slightly different Y offsets specifically to
   avoid z-fighting — preserve that ordering when adding new layers.

3. **`scenes/terrain_rgb_loader.gd`** (`TerrainRGBLoader`, `Node3D`) — decodes a Terrain-RGB
   elevation image (`height = -10000 + (R*65536 + G*256 + B) * 0.1`, the MapTiler/Mapbox
   convention) into a heightmap mesh via `sample_stride`-based downsampling. **Not yet verified
   against a real tile** (see the header comment in the file) — `mvt_parser.gd` was checked
   against real bytes from `tiles/3090.pbf`, this wasn't. If you touch elevation decoding, sanity
   check the output against a known elevation point before trusting it.

### Coordinate/scale conventions that matter across files

- Tile-local coordinates are always `[0, extent]` (extent is usually 4096, but read it from the
  layer rather than assuming). `MVTTileRenderer._to_world()` maps that into centered world meters
  using `tile_size_meters`.
- `tile_size_meters` must be set correctly for the tile's actual zoom level:
  `40075016.6855784 / pow(2, zoom)`. Both `MVTTileRenderer` and `TerrainRGBLoader` have this
  export independently — if a vector tile and a terrain tile are meant to align in the same scene,
  their `tile_size_meters` must represent the *same real-world footprint*, even though the terrain
  tile may come from a lower zoom level (terrain maxzoom is typically lower than vector maxzoom).
  `TerrainRGBLoader.crop_rect` exists to crop a lower-zoom terrain tile down to the footprint of a
  single higher-zoom vector tile — see the worked example in that file's doc comment.
- MVT tile Y grows downward (south); the renderer flips tile Y directly into world Z (Godot -Z is
  "north" by convention), so no explicit sign flip is applied — see the comment in `_to_world()`.
- Ring winding: `_ensure_ccw()` normalizes polygon winding before triangulation via
  `Geometry2D.triangulate_polygon`. Materials use `cull_mode = CULL_DISABLED` as a POC-grade
  workaround for winding-order edge cases rather than guaranteeing correct winding everywhere.

### Adding a new rendered layer

Follow the existing pattern in `_render_layers()`: check `layers.has(name)`, read that layer's own
`extent` (don't reuse another layer's extent), pick a Y offset that won't z-fight with existing
passes, and add a new `SurfaceTool` + `_finalize_mesh()` call (or fold into an existing pass if the
geometry type matches).

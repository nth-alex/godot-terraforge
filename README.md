# Godot TerraForge

GPU world generator for baking RPG heightmaps. Godot 4.7, compute shaders. It is a tool, not a game.

Tweak sliders, watch the map update, then export a bake your game can load.

![preview](export/preview.png)

## Run

```
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

Windowed only — compute shaders need a RenderingDevice, so `--headless` will not work.

Self-check (generates, asserts, writes screenshots, quits):

```
/Applications/Godot.app/Contents/MacOS/Godot --path . -- --test
```

## What it generates

Pipeline runs continent → harbour → regions → ridges → basin → erosion → water → roads → composite.
Each stage writes its own texture; the last one is the bake.

- Continent shape with warped coastline and a sheltered harbour site
- Mountain ridges with passes, inland basin, coastal shelf
- Droplet erosion, depression fill, flow accumulation, rivers and lakes
- Least-cost roads between region capitals
- Voronoi regions with relaxation and warped borders

Views: biome composite, raw height, regions, water. 3D flythrough preview included.

## Export

"Export bake" writes to `export/`:

| File | Contents |
| --- | --- |
| `heightmap.exr` | Height in real metres (32-bit float). Falls back to 16-bit `heightmap.png` if EXR is unavailable. |
| `regions.png` | Region id per pixel, `255` = ocean |
| `water.png` | R = river strength, G = lake depth in metres |
| `roads.png` | Road strength |
| `preview.png` | Rendered composite |
| `world.json` | Scale, sea level, seed, region list, road graph, layer legend |

Heights are metres above zero, not normalised — `world.json` carries `sea_level_m` and `height_scale_m` so importers do not have to guess.

## Settings

Every slider has a tooltip explaining what it does and which way to push it. Same seed plus same settings always gives the same world.

Region names and palettes live in `regions.json`.

## Notes

Run `Godot --path . --import` after editing any `.glsl`, or the old SPIR-V is used silently.

## Licence

MIT

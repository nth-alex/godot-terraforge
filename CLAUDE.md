# Godot TerraForge

GPU world generator for baking RPG heightmaps. Godot 4.7 + compute shaders. Not a game.

## Run and verify

- `/Applications/Godot.app/Contents/MacOS/Godot --path . -- --test` - generate, run asserts, write screenshots, quit. Prints `PASS`/`FAIL`.
- Screenshots land in `~/Library/Application Support/Godot/app_userdata/Godot TerraForge/`: `selfcheck.png` (UI + composite), `selfcheck_relief.png` (hillshade). Read them - visual bugs do not show up in asserts.
- Headless has no RenderingDevice. `--headless` cannot run compute; always run windowed.
- `Godot --path . --import` after editing any `.glsl`, or the old SPIR-V is used silently.

## Layout

- `addons/terraforge/world_gen.gd` - whole pipeline. GPU passes (`_run_*`), CPU steps (seed placement, Lloyd relax, road A*), `export_world()`. Owns its own local `RenderingDevice`, so it never touches the editor renderer.
- `addons/terraforge/main.gd` - UI. `TIPS` maps param key to slider tooltip; every slider needs an entry or the self-check fails.
- `addons/terraforge/shaders/*.glsl` - one file per pass, named after the `_run_*` that dispatches it.
- Region names and palettes: `addons/terraforge/regions.json`. Bake output: `res://export/`.
- A param in `main.gd:DISPLAY_ONLY` only re-runs `render()`. Anything else re-runs the full pipeline - put a new param in that list if it only affects the composite pass.
- Tooltip text states which way to push a slider, so it must match the shader maths. Read the shader before writing or trusting one.

## Compute shader gotchas

- Unused trailing push-constant members are stripped from SPIR-V reflection. Send the exact float count the shader uses; declared padding does not reach the pipeline.
- `image2D` cannot be a function parameter. Use a macro. A violation produces errored bytecode and a zeroed output texture, not a visible error.
- Iterated passes (fill, flow) batch into one `compute_list_begin` with `compute_list_add_barrier` between steps, one submit. Per-step submit+sync is a stutter.
- Droplet/particle seeding needs an integer hash. `sin`-based hashing on consecutive ids lands starts on a lattice and prints evenly spaced parallel grooves.

## Pipeline order

continent -> harbor -> regions -> ridges -> basin -> erosion -> water -> roads -> composite.
Each stage writes its own texture; `graded` is the final bake. `heights()` returns it.

- Depression fill propagates one cell per iteration, so it runs at `water_res` 512, not full res. At 2048 it will not converge and the interior reads as one giant lake.
- Region texture packs nearest id in the low 16 bits, second-nearest in the high 16. `region_ids()` masks it.
- Composite renders the final graded height, so road notches appear in hillshade. A "terrain artifact" that is straight and staircased is a road.

## GDScript

- `var x := <expr from an untyped Dictionary/Array>` fails to infer. Annotate: `var x: float = params["k"]`.
- Self-check asserts live in `addons/terraforge/main.gd:_run_self_check`. Add one per non-trivial pass.

## Git

- Commit straight to `main`. Do not create feature branches or PRs for changes here.

# FlyCam

A free-flying camera for Godot 4. WASD flies in the direction you are looking,
the mouse turns, Shift is faster, Esc releases the mouse. No gravity, no ground,
no collision — it is a camera, not a body.

One script, no dependencies. `class_name FlyCam` registers the node, so there is
no plugin to enable and no project setting to change.

## Install

Into any Godot 4 project, from its root:

```sh
mkdir -p addons/flycam && curl -sL \
  https://raw.githubusercontent.com/nth-alex/godot-addons/main/addons/flycam/flycam.gd \
  -o addons/flycam/flycam.gd
```

Re-run the same command to update. Then add a **FlyCam** node to the scene and
set `current = true`.

**Open the project in the editor once after installing**, or run
`godot --headless --path . --import`. `class_name FlyCam` is registered during
import; before that a script naming the type fails with
`Parse Error: Could not find type "FlyCam" in the current scope`.

Prefer a pinned version? Use a submodule of the whole addon repo instead:

```sh
git submodule add https://github.com/nth-alex/godot-addons vendor/godot-addons
ln -s ../vendor/godot-addons/addons/flycam addons/flycam
```

## Tuning

| Property | Default | Notes |
| --- | --- | --- |
| `speed` | 14.0 | Metres per second. Scale it to the world: 14 suits a village, a room wants 3. |
| `sprint` | 3.0 | Multiplier while the sprint key is held. |
| `sensitivity` | 0.0025 | Radians of turn per pixel. |
| `pitch_limit` | 82.0 | Degrees up and down. Short of 90 on purpose — at 90 the heading is ambiguous. |
| `capture_on_ready` | true | Turn off if the project owns mouse focus; call `grab_mouse()` when the camera should take over. |
| `key_*` | WASD + Shift | Rebindable in the inspector. |

`grab_mouse()` and `release_mouse()` are public, for handing focus to and from a
UI. They set the `active` flag, which is what gates input — not
`Input.mouse_mode`, since capture is unavailable on some platforms (headless
among them, where a test driving the camera would otherwise never move it).
While inactive the camera ignores movement keys and mouse look.

## Notes

Movement uses `global_position` and `global_basis`, so the camera still flies
straight when parented under a rotated or moving node.

Keys are read directly rather than through InputMap actions, so nothing has to
be added to Project Settings before it works. Rebind through the exported
`key_*` properties.

`plugin.cfg` and `plugin.gd` exist only so the Godot Plugins tab and the Asset
Library recognise the folder. Enabling the plugin is not required.

## License

MIT — see [LICENSE](LICENSE).

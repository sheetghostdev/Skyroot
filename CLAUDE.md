# Skyroot - notes for Claude

Co-op (1-4) survival/crafting game in **Godot 4.7, GDScript**. A block (voxel)
world heavily inspired by **Vintage Story**: knapping on a 16x16 grid, fire pits
built stick by stick (each stick crosses the last; tinder tucked underneath),
clay formed layer by layer, pottery fired in a pit kiln you dig and cover.
Read `README.md` (player-facing) and `docs/ARCHITECTURE.md` (how it fits together)
before changing anything.

## Working with the owner

- Work directly in this folder. Commit as you go; **push to GitHub only when the
  owner asks.**  Branch: `claude/affectionate-galileo-setlcm`.
- The owner playtests and gives design direction. They want VS-like mechanics:
  precise, grid-based, physical, readable - not menu crafting, not fiddly free-3D
  interaction. Prefer clear on-screen prompts over hidden rules.
- The earlier smooth-terrain version is in history at commit `5133eb4`.

## Commands

```
godot --headless --path . --import                       # refresh class cache / imports after adding class_name files or textures
godot --headless --path . res://tests/test_main.tscn -- --suite=all     # 180+ checks (suites: core blocks water craft fire kiln survival farm save longrun)
godot --path . -- --autostart=solo --world=Dev --new     # straight into a new island
godot --path . -- --autostart=solo --world=Dev --new --pos=30.5,45.1,34.5 --yaw=180 --pitch=-40 --setup=firepit_lit --hour=21 --shot=out.png
godot --path . -- --autostart=solo --world=Dev --new --pos=30.5,45.1,34.5 --yaw=180 --play=knap   # scripted real input (knap|fire|build)
tools/mp_test.sh, tools/mp_crowd.sh, tools/mp_crash.sh   # multi-instance network tests (bash)
python3 tools/art/gen_blocks.py preview.png ; python3 tools/art/gen_items.py preview.png   # regenerate textures/icons (needs Pillow + numpy)
```

`--setup=` scenes are in `src/util/debug_shot.gd` (firepit, firepit_lit, firepit_cook,
firepit_x, knap, clay, kiln, kiln_lit, ground, items, fell (+ `--after=secs`), water,
torches, inventory, handbook, chooser).  `--sit` sits the player down, `--tp` third person.

## Where things are

- Data: `data/blocks.json` (block ids are saved: never renumber), `items.json`,
  `recipes.json`, `knapping.json`, `clayforming.json`, `guide.json` (handbook
  pages + goal sequence), `hints.json`.
- Host rules: `src/sim/actions.gd` (dispatch, reach, inventory clicks, pickup) +
  `block_acts.gd`, `fire_acts.gd`, `craft_acts.gd`, `farm_acts.gd`; survival,
  climate, weather, sim_driver.  `water_sim.gd`: finite water (8 units per block,
  meta = units short of full, so meta 0 is a full block); it reacts to
  `Events.block_changed`, so anything that changes blocks next to water wakes it.
- Effects: `src/world/fx.gd` (one-shots), `tree_fall.gd` (the toppling tree; the
  host delays the drops with `drop_item(..., wait_ms)`), `src/entities/torch_model.gd`
  (placed torches are "fixtures": the mesher skips them and `VoxelView` adds a model
  + light per torch; wall torches use meta 1-4, see `Blocks.WALL_DIRS`).
- Blocks: `src/voxel/` (registry, storage, threaded mesher with skylight, view).
- Client: `src/player/interactor.gd` + `use_rules.gd` (what the buttons do and the
  prompt text), `src/ui/hud.gd` and panels, `src/entities/*_view.gd`.
- Everything that changes the world goes through `World.request(...)` and is
  validated on the host; add new actions to `Actions.handle` (+ `ARG_TYPES`).

## GDScript gotchas met so far

- New `class_name` files need `godot --headless --path . --import` before a run
  sees them.
- Don't name methods `get_meta`, `set_meta`, `_get`, `_set` (Object clashes).
- `:=` on an untyped expression (ternary of Variants, dictionary reads) is a
  parse error here; give the type explicitly.
- `queue_free()` doesn't remove a child at once: never loop on
  `get_child_count()` while queue-freeing (that froze the HUD once).
- Packed arrays are values: `for a in [arr1, arr2]: a.resize()` resizes copies.
- Vertex colours are linear: `srgb_to_linear()` a tint, or it looks washed out.
- Worker threads (chunk meshing) must not read dictionaries that change; use the
  flat tables in `Blocks`.

## Known gaps / ideas not built yet

Ladders, doors, planks (need a saw), metals, animals, the islet has nothing
special yet, more recipes for cooking pots, sounds for some new actions, pouring a
bowl of water back out, water putting out fires it flows into.

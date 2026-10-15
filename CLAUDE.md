# Skyroot - notes for Claude

Co-op (1-4) survival/crafting game in **Godot 4.7, GDScript**. A block (voxel)
world heavily inspired by **Vintage Story**: knapping on a 16x16 grid, fire pits
built stick by stick (each stick crosses the last; tinder tucked underneath),
clay formed layer by layer, pottery fired in a pit kiln you dig and cover.
Two world kinds: the **archipelago** (default since the owner's "Stranded Deep"
pivot: many small islands, rafts like the game Raft, animals you can take across the
sea) and the original **sky island**.
Read `README.md` (player-facing) and `docs/ARCHITECTURE.md` (how it fits together)
before changing anything.  `docs/ROADMAP.md` has the resource audit and the
long-game ideas being discussed with the owner.

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
godot --headless --path . res://tools/check_scripts.tscn   # load every script (catches parse errors the import misses)
godot --headless --path . res://tests/test_main.tscn -- --suite=all     # 320+ checks (suites: core blocks water craft fire kiln survival farm save longrun sea raft animals)
godot --path . -- --autostart=solo --world=Dev --new     # straight into a new sky island
godot --path . -- --autostart=solo --world=Dev --new --kind=sea --seed=12345 --view=6   # a new archipelago (spawn ~236.5,37,265.5)
godot --path . -- --autostart=solo --world=Dev --new --pos=30.5,45.1,34.5 --yaw=180 --pitch=-40 --setup=firepit_lit --hour=21 --shot=out.png
godot --path . -- --autostart=solo --world=Dev --new --pos=30.5,45.1,34.5 --yaw=180 --play=knap   # scripted real input (knap|fire|build|swim)
godot --path . -- --autostart=solo --world=Dev --new --kind=sea --seed=12345 --view=4 --play=raft   # build, board, sail, paddle a raft
tools/mp_test.sh, tools/mp_crowd.sh, tools/mp_crash.sh, tools/mp_sea.sh   # multi-instance network tests (bash)
python3 tools/art/gen_blocks.py preview.png ; python3 tools/art/gen_items.py preview.png   # regenerate textures/icons (needs Pillow + numpy)
python3 tools/audio/gen_animal_sfx.py                     # the synthesized animal sounds
```

`--setup=` scenes are in `src/util/debug_shot.gd` (firepit, firepit_lit, firepit_cook,
firepit_x, firepit_pot, knap, clay, kiln, kiln_lit, ground, ground2, items, fell
(+ `--after=secs`), water, torches, bed, inventory, handbook, chooser; at sea: raft
(+ `--aboard`), animals).  `--sit` sits the player down, `--tp` third person.  Under
xvfb with software rendering a sea screenshot takes about three minutes; `--yaw`
only applies together with `--pos`.

## Where things are

- Data: `data/blocks.json` (block ids are saved: never renumber), `items.json`,
  `recipes.json`, `knapping.json`, `clayforming.json`, `animals.json`, `guide.json`
  (handbook pages + goal sequence; goals, pages and categories can carry
  `"modes": ["sea"]` / `["sky"]`), `hints.json` (a `<id>_sea` hint replaces `<id>` in
  an archipelago).
- Worlds: `World.kind` is "sea" (`src/world/archipelago_gen.gd`, 512 x 64 x 512,
  islands in `World.geo`) or "sky" (`island_gen.gd`).  `src/world/ocean.gd` draws the
  sea and far islands outside the meshed chunks (`VoxelView.radius`).
- Host rules: `src/sim/actions.gd` (dispatch, reach, inventory clicks, pickup) +
  `block_acts.gd`, `fire_acts.gd`, `craft_acts.gd`, `farm_acts.gd`, `raft_sim.gd`,
  `animal_sim.gd`; survival, climate, weather, sim_driver.  `water_sim.gd`: finite water (8 units per block,
  meta = units short of full, so meta 0 is a full block); it reacts to
  `Events.block_changed`, so anything that changes blocks next to water wakes it.
- Effects: `src/world/fx.gd` (one-shots), `tree_fall.gd` (the toppling tree; the
  host delays the drops with `drop_item(..., wait_ms)`), `src/entities/torch_model.gd`
  (placed torches are "fixtures": the mesher skips them and `VoxelView` adds a model
  + light per torch; wall torches use meta 1-4, see `Blocks.WALL_DIRS`).
- Blocks: `src/voxel/` (registry, storage, threaded mesher with skylight, view).
  Blocks with `"facing": true` turn their boxes by `meta & 3` (beds: foot id 36,
  head id 38, see `BlockActs.bed_partner`).
- Item models: `src/entities/item_models.gd` (box-built items at real size, piles
  for stacks; anything without a model falls back to `Icons.mesh`).
- Rafts: entity "raft" with `d.cells` (local `Vector3i` -> `Vector2i(id, meta)`,
  layer 0 = floor, deck at local y 1); geometry in `src/sim/raft.gd`, host physics in
  `raft_sim.gd`, `src/entities/raft_view.gd`.  Riding: `LocalPlayer.riding` +
  `src/player/solid_frame.gd` (collision in the raft's frame), poses carry
  `rv`/`rp`/`rf`.  Raft-only blocks (sail, steering oar, anchor) have
  `"raft_only": true`; outlines of tall raft pieces use `Blocks.select_whole`.
- Animals: entity "animal" (`d.s` species, `lead`, `raft` + `rp`/`ry`, `home`,
  `isl`, `born`, `fed`, `bred`); `src/sim/animal_sim.gd` (host, 10 Hz, only near
  players), `src/entities/animal_view.gd` (box models, lead rope).
- Client: `src/player/interactor.gd` + `use_rules.gd` (what the buttons do and the
  prompt text; targets are "block", "be", "raft", "animal", "satchel"),
  `src/ui/hud.gd` and panels, `src/entities/*_view.gd`.
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
- The import pass only compiles `class_name` scripts: run `tools/check_scripts.tscn`
  too, or a parse error in e.g. `debug_shot.gd` only shows when that script loads.
- `pkill -f <pattern>` in a shell command also matches (and kills) that shell.
- `range` is a builtin: don't use it as a variable name.
- Tests run with `weather.showers = false` (a random shower used to put out a test
  kiln); tests that want rain set `World.env["rain"]` themselves.

## Known gaps / ideas not built yet

Ladders, doors, planks (need a saw), metals, more recipes for cooking pots, sounds
for some new actions, pouring a bowl of water back out, water putting out fires it
flows into.  At sea: fishing, storage on rafts (jars are block entities, not raft
cells), fire on a raft, rafts bumping each other, sea currents, birds and fish,
fences/pens (untied animals wander about their home), milk, feathers and leather.

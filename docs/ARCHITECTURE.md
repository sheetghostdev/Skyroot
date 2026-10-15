# Skyroot architecture

Skyroot is one Godot project in which single-player and multiplayer run the same
code: single-player is simply a host with no clients (an `OfflineMultiplayerPeer`).

## The authoritative world

`World` (autoload, `src/autoload/world.gd`) holds the whole island:

* **kind** — `"sea"` (an archipelago, `ArchipelagoGen`) or `"sky"` (the floating
  island, `IslandGen`), with `geo`: the sea level, the islands (centre, radius, kind)
  and where you wake.
* **blocks** — `VoxelData` (`src/voxel/voxel_data.gd`): a grid of block ids (512 × 64
  × 512 for an archipelago, 64 × 80 × 64 for the sky island) plus one byte of state per
  block (log axis and "grew naturally", crop stage, farmland wetness, ripe berries,
  water level, facing), stored column by column.  Past the x/z edges every column is
  the same `outside` column (open sea, or sky).  It also keeps the highest and lowest
  sky-blocking block of every column (skylight, rain, shelter), saved with the world.
* **entities** — `id -> {id, t, xf, d}`: dropped items, the bags people leave when
  they die, rafts, animals, and **block entities** — things that occupy one cell and have their own
  state: fire pits, pit kilns, knapping stones, clay being shaped, ground storage,
  storage jars.  `World.be_at` maps a cell to its block entity.
* **env** — game time, rain, clouds, wind, mist.
* per-player **inventories** (hotbar, backpack, crafting grid and the stack on the
  mouse cursor all live on the host), **stats** and **guide progress**, and
  `player_saves` (records of players who are away).

Only the host mutates this state, through `set_block` and `spawn / update / set_xf /
despawn`.  Each mutation is applied locally and queued as a replication op; ops are
flushed to every client once per physics frame in a single reliable RPC, so clients
see changes in exactly the order the host made them.  Late joiners receive a snapshot
(the block grid is zstd-compressed: about 30 kB for the sky island, 220 kB for an
archipelago).  Clients never change the world
themselves: they call `World.request(action, args)`.

## Requests and validation

`Actions` (`src/sim/actions.gd`) is the host's request handler.  It checks argument
types, that the player is alive and within reach (from the poses players send), what
they really hold, and rate limits, then hands the request to a domain module:

| module | file | does |
|---|---|---|
| blocks | `block_acts.gd` | break times and tools, drops, felling whole trees, plants that go with their ground, falling sand/gravel, placing |
| fire | `fire_acts.gd` | fire pits (sticks, tinder, firewood; lighting; burning phases; rain; roasting; stew; torches) and pit kilns |
| craft | `craft_acts.gd` | setting things down, knapping, clay forming, ground storage, storage jars |
| farm | `farm_acts.gd` | berries, tilling, sowing, filling vessels and waterskins, planting coconuts, beds; random ticks that grow crops, saplings, berries, grass and mushrooms |
| rafts | `raft_sim.gd` | floating, extending, building on and taking apart rafts; paddle strokes, sails, the helm, anchors; moving them every physics frame and grounding them |
| animals | `animal_sim.gd` | stocking the islands, wandering, running away, being led (onto and off rafts), hunting, feeding and young, eggs, refilling hunted-out islands |
| water | `water_sim.gd` | finite fresh water (8 units a block) that falls, spreads and levels whole bodies; the sea floods in at sea level and never runs out |

Inventory clicks (`inv_click`) follow Minecraft's rules with the cursor stack kept on
the host; the crafting grid matches `data/recipes.json`.  Because requests are handled
one after the other against the current state, two players grabbing the same thing
can't both get it.

Player movement is the exception: each machine moves its own player (box physics
against the block grid, `src/player/voxel_body.gd`) and relays a pose (~20 Hz,
unreliable) through the host.

## Rafts

A raft is an entity whose `d.cells` is a little grid of its own (`Vector3i` →
`Vector2i(block id, meta)`): layer 0 is the floor of lashed logs, things built on the
deck stand in layer 1 and up.  Its transform places that grid in the world, turned
about Y only, with the deck a hand above the sea (`Raft`, `src/sim/raft.gd`, has the
shared geometry: collision boxes, ray casts, connectivity).  The host's `RaftSim`
moves it every physics frame (paddle impulses and torque, the wind in raised sails,
the helm and its keel, drag, the anchor) and stops it where its logs would touch
the bottom; others get its transform four times a second and `RaftView` carries it on
at its speed in between.

Standing on a raft, a player moves in the raft's frame: `SolidFrame` hands
`VoxelBody` the raft's boxes in raft-local space (exact) and the world's blocks
turned into it (close enough at a shore).  Each frame the raft's motion since the last
is applied to the rider (position and heading), so it carries you.  Poses then carry
`rv` / `rp` (the raft and where on it), so other machines draw you on the raft as they
draw it, not lagging behind.

## Animals

Animals are entities too (`d`: species, health, home, island, who leads them, the
raft they stand on and where).  `AnimalSim` steps the ones near anyone ten times a
second (the rest stand still) and replicates their transforms; `AnimalView` eases
between updates and animates legs and heads from how fast they move.  On a raft an
animal keeps a deck position (`rp`) and every machine places it from its own view of
the raft.  Species are data (`data/animals.json`): size, speed, shyness, what they
eat, drops, which island kinds have how many.

## Simulation

`SimDriver` (host) advances time (one in-game day = 20 real minutes, much faster when
everyone sleeps) and ticks every system twice a second: weather, fire pits and kilns,
random ticks, and survival (hunger, thirst, warmth from `Climate`: time of day, rain,
wind, roof and walls read from the blocks, nearby fires).

## Rendering

`VoxelView` meshes the grid in 16³ chunks on worker threads (`ChunkMesher`; the
padded region is copied on the main thread, the mesh built on a worker).  In an
archipelago only the chunks within the view distance of the camera are meshed and far
ones are dropped; beyond them the `Ocean` draws a sea plane to the horizon and every
island as a coarse heightfield, both stepping aside inside the square of real blocks.
The mesher does face culling, per-vertex corner occlusion and skylight.  Skylight is worked out per chunk
from a padded copy of the surrounding blocks: open sky above and open air under the
island are lit, and light spreads into overhangs, caves and canopies.  The shaders
apply it to ambient light only; the sun casts real shadows.  Textures come from one
atlas split into a `Texture2DArray`, so tiles never bleed.  Block entities have their
own views in `src/entities/`, built from the same textured boxes.  Items are their
pixel-art icon extruded into 3D (`Icons.mesh`).

## Client side

* `Interactor` ray-casts the blocks (down to the cell of a knapping grid or clay
  layer), outlines the target, and turns mouse buttons into requests; `UseRules`
  decides what each button will do and words the prompt under the crosshair.
* `HUD` owns the hotbar, bars, goal tracker, toasts, hints, death screen, chat and the
  panels: inventory (`InventoryUI`), handbook (`HandbookUI`), shape chooser
  (`ChooserUI`), pause menu.
* `Guide` (autoload) holds handbook pages (`data/guide.json`, plus one generated page
  per item), one-time hints (`data/hints.json`) and the goal sequence.

## Data

* `data/blocks.json` — every block: shape, textures, hardness, tool, drops, light.
* `data/items.json` — stack sizes, the block an item places, tool kinds and uses,
  food values, fuel kinds.
* `data/recipes.json`, `data/knapping.json`, `data/clayforming.json` — what can be
  made and how.
* `data/guide.json`, `data/hints.json` — the handbook, goals and hints.

## Persistence

The host saves the world (`World.save_world`) to `user://saves/<name>.skyroot` as a
versioned dictionary: blocks, entities, env, discoveries and every player's record.
Saving writes a temporary file and renames it, so a crash can't leave half a save.
A returning player is matched by name and gets exactly the record they left with.

## Testing

* `tests/test_runner.gd` — headless suites driving the real game through requests.
* `src/util/mp_test.gd` with `tools/mp_test.sh`, `mp_crowd.sh`, `mp_crash.sh` — real
  multi-instance network tests.
* `src/util/debug_shot.gd` — staged scenes and screenshots for visual review, and
  scripted real-input plays (`--play=knap|fire|build|swim|raft`).
* `tools/check_scripts.tscn` — loads every script (with the autoloads), so parse
  errors in scripts the import pass doesn't compile show up.

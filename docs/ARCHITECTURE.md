# Skyroot architecture

Skyroot is one Godot project in which single-player and multiplayer run the same
code: single-player is simply a host with no clients (an `OfflineMultiplayerPeer`).

## The authoritative world

`World` (autoload, `src/autoload/world.gd`) holds the whole simulated island:

* **entities** — `id -> {id, t, xf, d}`: a type (`item`, `tree`, `plant`, `site`,
  `structure`, `compost`, `work`, `satchel`...), a transform, and a plain data
  dictionary.  Everything that exists on the island is an entity or terrain.
* **terrain** (`TerrainData`) — a height-field of layers (rock, clay, soil) plus
  per-cell moisture, nutrients, grass and tilled flags.
* **env** — replicated environment: game time, weather, wind, pond volume.
* **pools** — host-only reservoirs of the closed economy (air water and carbon, soil
  organic matter, losses to the abyss...), see [ECONOMY.md](ECONOMY.md).
* per-player **inventories**, **stats** and **guide progress**, and `player_saves`
  (records of players who are away).

Only the host mutates this state, through `spawn / update / set_xf / despawn /
terrain_edited`.  Each mutation is applied locally and queued as a replication op;
ops are flushed to every client once per physics frame in a single reliable RPC, so
clients see changes in exactly the order the host made them.  Late joiners receive a
snapshot.  Clients never change the world themselves: they call
`World.request(action, args)`.

## Requests and validation

`Actions` (`src/sim/actions.gd`) is the host's request handler.  Each action is a
small function that re-validates everything against the current state — does the
item still exist, is it in the slot the client claims, is the target within reach,
does the player have the tool — before changing anything.  Because two requests for
the same thing are processed one after the other, the second simply fails: nothing
can be duplicated.  Domain handlers register themselves: `ActionsCraft`,
`ActionsFire`, `ActionsBuild`, `ActionsCompost`, `FarmActions`, `TreeActions`,
`TerrainActions`, `WaterActions`.

Player movement is the exception: each machine owns its own player's movement and
relays a pose (~20 Hz, unreliable) through the host.  The host checks reach from the
poses it has.

## Simulation

`SimDriver` (host) advances time (one in-game day = 20 real minutes) and ticks every
system twice a second:

| system | file | what it does |
|---|---|---|
| weather | `sim/weather.gd` | clouds, rain driven by air humidity, wind |
| water | `sim/water_sim.gd` | pond and soil evaporation, rain, seepage, runoff, diffusion |
| plants | `sim/plant_sim.gd`, `tree_sim.gd` | crops, the tree, grass, bush, mushrooms grow from air carbon, soil water and nutrients |
| drying | `sim/drying_sim.gd` | pottery, wood and grass dry or get rained on |
| fire | `sim/fire_sim.gd` + `fire_model.gd` | every fire site: membership, enclosure (65 shell cells, ray-cast), per-piece pyrolysis/char/heat, cooking, pot firing, charcoal |
| structures | `sim/structure_sim.gd` | support spans, creaking, collapse |
| compost | `sim/compost_sim.gd` | rot rate from mix, moisture, air, self-heating |
| survival | `sim/survival.gd` | hunger, thirst, warmth, stamina, health, death |

Processes are evaluated from the physical setup, not from recipes: a fire site does
not know whether it is a "campfire" or a "charcoal mound"; it sees fuel pieces, their
moisture and size, the earth shell and vents around them, and the air that can reach
them, and the outcome follows.

## Crafting sessions

Hands-on crafts (knapping, cordage, hafting, clay preparation, pottery, the fire
drill) open a **work entity** at the spot where the material was set down.  The
player's `CraftSession` (`src/crafting/`) turns mouse gestures into small operations
(`strike`, `flip`, `twist`, `knead`, `water`, `hollow`, `shape`, `smooth`, `seat`,
`wrap`, `spin`) sent as `work_op` requests.  The host applies them to the workpiece's data (the knapped polygon, the
pot's lathe profile, the twist of the cord) and replicates it — which is why other
players see a pot rise or a stone lose its flakes as it happens.  Finishing evaluates
the result geometrically (`Knap.evaluate`, `Pottery.stats`) and gives the item.

## Client side

* `EntityManager` keeps one view node (`src/entities/*_view.gd`) per entity and
  updates it from replication signals.  Views only render and expose colliders that
  resolve back to `(entity id, part)`.
* `Interactor` ray-casts what the player looks at; `InteractionRules` (plus
  `SiteRules`, `BuildRules`, `CompostRules`) decide what E, LMB and RMB do with the
  held item, and the HUD shows those prompts.  Animations play locally at once and
  the request is sent at the animation's moment of impact.
* `BuildPlacer` shows a ghost frame with snapping and asks `ActionsBuild.check_place`
  (the same function the host uses) whether it fits.
* UI panels (`src/ui/`): inventory, Survival Guide, build menu, pause; `HUD` owns them
  and the hint card, toasts, tracker and vitals.

## Data

Everything that describes *what things are* is data:

* `data/items.json` — mass, volume, material, fuel properties, food values, tool
  kinds, processing yields, guide links.
* `data/blueprints.json` — building pieces: parts in installation order, the work
  each part needs, bounding box, model.
* `data/plants.json` — crops: growth time, water and nutrient needs, yields.
* `data/guide/*.json` — guide categories and entries, contextual hints, discoveries.

## Persistence

The host saves the world (`World.save_world`) to `user://saves/<name>.skyroot` as a
versioned dictionary: entities, terrain layers, env, pools, discoveries and every
player's record (inventory, stats, position, guide progress).  Saving writes a
temporary file and renames it, so a crash can't leave half a save.  `_migrate`
upgrades older versions.  A returning player is matched by name and gets exactly the
record they left with (tests check that nothing duplicates across save/load and
leave/rejoin).

## Testing

* `tests/test_runner.gd` — headless suites driving the real game through requests,
  with ledger checks after every scenario (see the README).
* `src/util/mp_test.gd` with `tools/mp_test.sh` / `tools/mp_crowd.sh` — real
  multi-instance network tests.
* `src/util/debug_shot.gd` — deterministic screenshots of set-up scenes for visual
  review.

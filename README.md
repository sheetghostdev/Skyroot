# Skyroot

A first-person co-op survival and crafting game for 1–4 players, set on one small
floating island above an endless sky.  Everything you will ever have is already on
the island: stone in the outcrop, clay by the pond, one great tree, soil, grass and a
few wild plants.  Nothing is spawned from nothing — you shape what is there.

Crafting is physical, not menu-driven: you knap stone by choosing where to strike it,
twist fiber into cordage, bind heads to handles, knead clay with water and raise a pot
on the ground with your hands, then fire it in a pit you build and cover.  Fires,
charcoal mounds, drying pottery, compost heaps and crops are simulated processes that
respond to how you set them up.

Built with **Godot 4.7** (GDScript, Forward+ renderer, Jolt physics).

## Running it

1. Open the project folder in Godot 4.7 (`project.godot`) and press **Play**, or run
   `godot --path .` from this folder.
2. **Play** starts or continues an island; leave *Open to friends* ticked to host co-op
   over LAN or direct IP (port 7777 by default) — or open a solo island later from
   the pause menu (**Open to friends now**).  Friends use **Join a friend** with the
   host's address, which the pause menu shows.

Saves are kept per island in Godot's user folder (`user://saves/*.skyroot`); the host
owns the save and autosaves every three minutes and on exit.

## Controls

| | |
|---|---|
| W A S D / mouse | move / look |
| Shift, Ctrl (or C), Space | sprint, crouch, jump |
| E | interact (pick up, use, talk to the thing in front of you) |
| Left / right mouse | primary / secondary action with what you hold (place, plant, strike...) |
| Mouse wheel, 1–9 | choose what to hold |
| Tab (or I) | what you carry |
| H | the Survival Guide (also opens the tip on screen) |
| B | build: pick a blueprint, set its frame down, then fit each part by hand |
| V | first / third person (no extra reach in third person) |
| Q | drop the held item (Ctrl+Q drops the stack) |
| R | rotate something before placing it |
| T | chat |
| F5, F12, F1 | quick save (host), screenshot, hide the HUD |
| Esc | close a panel / pause |

The prompts beside the crosshair always show what E and the mouse buttons will do with
what you hold right now.

## What's in it

* **The island** — smooth terrain with dig-able pockets of soil and clay, a pond with a
  real water level, an outcrop of loose stones, the great tree, grass that grows back,
  wild tubers, fiber grass, wild grain, a berry bush and mushrooms on a mossy log.
  Changes persist.
* **Survival** — hunger, thirst, stamina, health and warmth.  Night is cold; fire,
  walls, a roof and staying dry help.  You can carry about 45 kg, and a heavy load
  slows you down.  Falling off the edge is final for what you carry; dying on the
  island leaves a satchel you can recover.
* **Physical crafting** — knapping (blade, axe head, digging head, judged by the actual
  shape you made), cordage, hafting, clay preparation, pottery (a lathe profile you
  pull and thin; bowl, cup or jar; it can collapse or crack), drying, pit firing,
  log splitting into boards or firewood, the fire drill.
* **Fire** — a physical fire model: tinder, kindling and fuel heat each other; air,
  moisture and enclosure decide whether a lay catches, roars, smoulders or chars.  The
  same evaluator runs campfires, cooking, pit kilns and charcoal mounds (seal it with
  earth, leave vents, watch the smoke, seal it when it thins — open it hot and it burns
  to ash).
* **Farming and compost** — till, plant, water; crops grow from the soil's water and
  nutrients and the air's carbon.  Compost heaps rot according to their mix of greens
  and browns, moisture, air and the heat they make; turn them, water them, take the
  finished compost back to the soil.
* **Construction** — platforms, posts and braces, railings, ladders, wattle walls,
  doorways, thatch roofs, shelves and sleeping mats.  Frames are placed, then every part
  is installed by hand.  Spans out over the abyss creak, and a piece that loses its
  support groans and falls.  Taking things apart returns every part.
* **Closed economy** — water, carbon (biomass), nutrients, clay, soil and stone are
  conserved and audited by a ledger; see [docs/ECONOMY.md](docs/ECONOMY.md).
* **Survival Guide** — 43 searchable entries with animated diagrams, contextual tips,
  checklists you can pin to the screen, and an island journal of shared discoveries.
* **Co-op** — 2–4 players, host-authoritative: everyone sees the same island, the
  same fires and pots taking shape; nothing can be duplicated; a player who leaves gets
  their belongings back when they return.

## Tests

`tools/run_tests.sh` runs everything below and prints a summary.

Headless suites (each prints `ok` / `FAIL` lines and a summary; exit code 0 = pass):

```
godot --headless --path . res://tests/test_main.tscn -- --suite=all
```

Suites: `craft`, `survival`, `farm` (compost and crops), `fire`, `build`, `save`,
`longrun` (ten in-game days with a forager: survival on island food alone, stability
and exact conservation).  Every suite checks the material ledger.

Multiplayer, as separate game instances on one machine:

```
tools/mp_test.sh     # host + client: shared world, no duplication, leave and rejoin
OPEN_LATER=1 tools/mp_test.sh   # the same, with a solo island opened to friends mid-session
tools/mp_crowd.sh    # four players at once; a fifth is told the island is full
tools/mp_crash.sh    # a client is killed and restarts: back as themselves, with their things
```

Visual checks use `--shot=<png>` with xvfb (see `src/util/debug_shot.gd` for scene
setups such as `--fire=mound`, `--compost=20`, `--build=hut`, `--panel=guide`).

## Project layout

```
data/            items, blueprints, plants, guide entries/hints/discoveries (JSON)
src/autoload/    Game (session), World (entities, replication, saves), Net, ItemDB,
                 Guide, Settings, Sfx, Events
src/sim/         host simulation and request handlers (fire, water, plants, compost,
                 structures, survival, crafting, ledger)
src/rules/       what the player can do to each kind of thing (prompts)
src/entities/    views of world entities
src/crafting/    crafting sessions (knapping, pottery...) and their geometry
src/player/      local player, interaction, build placement, hands
src/ui/          HUD, guide, inventory, build menu, menus
src/world/       terrain, island view, sky, effects
tools/           Blender model scripts, audio tools, multiplayer test scripts
docs/            architecture, economy, art pipeline
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit together.

## Credits

Models are generated by the Blender scripts in `tools/blender` (see
[docs/ARTPIPELINE.md](docs/ARTPIPELINE.md)).  Audio is CC0: curated from Kenney's packs
or synthesized (see `assets/audio/CREDITS.md`).  Fonts are under the SIL Open Font
License (`assets/fonts/LICENSE-OFL.txt`).

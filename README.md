# Skyroot

A co-op survival and crafting game for 1–4 players.  It's a block world, heavily
inspired by Vintage Story: you knap stone tools cell by cell on a grid, build fire
pits stick by stick, shape clay pottery layer by layer, and fire it in a pit kiln you
dig and cover yourself.

There are two kinds of world:

* **Archipelago** (the default) — you wake on a small island in a wide sea, with a
  dozen and a half others around it, none of them big and each a different kind:
  palm-fringed atolls, wooded isles with fresh ponds and clay, rocky knolls with
  flint, marshes, meadows.  No island has everything.  Build a raft, paddle and sail
  from one to the next, and bring back what you need — animals included.  Your base
  can be on land or on the raft itself.
* **Sky island** — the original: one small floating island above the clouds with
  everything you need on it (and a long fall off the edge).

Trees, berries, grass and mushrooms grow back; stone does not.

Built with **Godot 4.7** (GDScript, Forward+ renderer).

## Running it

1. Open the project folder in Godot 4.7 (`project.godot`) and press **Play**, or run
   `godot --path .` from this folder.
2. **Play** starts or continues a world (choose *Archipelago* or *Sky island* for a new
   one); leave *Open to friends* ticked to host
   co-op over LAN or direct IP (port 7777 by default) — or open a solo island later
   from the pause menu (**Open to friends now**).  Friends use **Join a friend** with
   the host's address, which the pause menu shows.

The host owns the save (`user://saves/*.skyroot`), autosaves every three minutes and on
exit.  Islands saved by the earlier smooth-terrain version can't be opened (the menu
says so); that version is still in the git history at commit `5133eb4`.

## Controls

| | |
|---|---|
| W A S D, mouse | move, look |
| Space, Ctrl, Shift | jump, sprint, sneak (sneaking, you can't walk off an edge); in water Space swims up and Shift dives |
| A / D at the helm | steer a raft (W, S or Space lets go of the steering oar) |
| Left mouse (hold) | break what you look at; chip a knapping stone; remove clay |
| Right mouse | use or place what you hold; hold it to eat, drink or work a bow drill (keep holding to eat one after another, or lay stick after stick) |
| Shift + right mouse | set things down on the ground: a stone to knap, clay to shape, a stick or dry grass to start a fire pit, anything else to leave there |
| E (or Tab) | inventory and the 3 × 3 crafting grid |
| H | the handbook: how-tos, your goals, a page for every item (over an item in the inventory: its page) |
| 1–9, mouse wheel | hotbar (over an inventory slot: swap that slot onto the hotbar) |
| C | sit down for a close look at knapping or clay work (a step or Space to get up) |
| F | clay brush (1 × 1, 2 × 2, 3 × 3, copy the layer below) / knapping flakes |
| Q / Ctrl+Q | drop one / the stack |
| V | first / third person (no extra reach in third person) |
| T | chat |
| F1, F6, F12 | hide the HUD, quick save (host), screenshot |
| Esc | close a panel / the island menu (the world doesn't pause — it's co-op) |

Under the crosshair it always says what you're looking at and what each mouse button
will do with what you hold.  The goal in the top right walks you through the first
steps.

## How things work

* **Knapping** — sneak-right-click a stone or flint onto flat ground and pick a shape
  (knife blade, axe head, shovel head, hoe head).  The shape stays bright, the waste dark;
  chip the waste touching the shape, and whatever is no longer joined to it falls away
  by itself.  Left-click chips one cell; hold and sweep to chip a row (F: flakes).
  Chip into the shape three times and the stone splits.  Flint tools last longer.
  C sits you down for a closer look.
* **Tools** — put a head above a stick in the crafting grid.  Knives cut grass (dry
  grass) and cattails/flax/ferns (fiber); axes fell whole trees; shovels dig fast;
  hoes till.
* **Fire pits** — sneak-right-click a stick onto the ground.  Each stick you add lies
  across the last: two make an X, then a cross over it, up to eight.  Dry grass goes
  in the middle underneath as tinder.  Hold right-click with a bow drill (twine + two
  sticks) to light it.  Tinder lights the sticks, sticks light firewood laid on top;
  firewood (a log split with an axe in the grid) burns for ninety minutes each.  Rain
  drowns an open fire unless firewood is burning well.  Roast food on it; set a pot of
  water on it with food in it for stew.
* **Clay** — dig blue clay from the pond's banks.  Sneak-right-click it onto the
  ground and choose a bowl, cooking pot, storage jar or bricks; build it up one layer
  at a time (right-click adds, left-click removes, F changes the brush).
* **Trees** — an axe fells the whole tree; it topples away from you and the logs land
  along the trunk (never off the edge of the island).
* **Water** — finite, eight parts to a block.  It falls, spreads and evens out; dig
  beside the pond and the pond goes down, open it to the edge and it pours away.
  Bowls and pots take from it; rain tops it up and fills hollows; puddles dry.
* **Torches** — glowing heads and live flames; stand them on the ground or hang them
  on a wall.  They don't burn out.
* **Pit kiln** — dig a hole one block deep, set raw pottery in it, cover it with four
  dry grass and six sticks, light it.  Three hours later it's fired.  In a pit nothing
  cracks; on open ground some pieces do.
* **Survival** — food, water, warmth and health.  Nights are cold: a fire, a roof and
  walls keep you warm.  Dying leaves your things in a bag where you fell (fall into
  the abyss and the bag waits at the edge you went over).  A straw bed (three
  thatch) lets you sleep through the night (when everyone sleeps) and is where you
  wake.
* **Farming** — till soil with a hoe, sow turnip or flax seeds from the wild plants.
  Farmland near water grows faster.
* **The archipelago** — each island kind has its own things: the home island has
  palms, coconuts and a few stones and sticks; wooded isles have oak and birch, berries,
  mushrooms and a fresh pond with clay; rocky isles have stone and flint; marshes clay,
  cattails and flax; meadows turnips and flax.  Far islands show on the horizon.
* **Rafts** — two logs and twine lash into a raft section.  Right-click the sea to float
  it, the water beside it to lash on more (up to 25 × 25).  Stand on it and it carries
  you; build on its deck like on the ground.  Hold right click with a paddle to paddle
  the way you look; raise a sail and the wind takes you; take the helm at a steering
  oar and A / D steer (you can hold a course across the wind, never into it); drop an
  anchor to stay put.  Rafts ground in the shallows.
* **Swimming** — you float with your head up; Space swims up, Shift dives; under water
  you hold your breath (the air bar).  Swim against a bank or a raft holding Space to
  climb out.  Things dropped in the sea float.
* **Water at sea** — the sea is salt and makes you thirstier.  Drink coconuts, find a
  fresh pond, or boil sea water in a pot over a fire until it's fresh; drink from the
  pot, ladle it into bowls or fill a waterskin (a goat hide and twine) for the voyage.
  A coconut pressed into the sand grows a palm.
* **Animals** — crabs on the beaches, junglefowl on the wooded isles and meadows (they
  lay eggs), wild goats on the rocks.  They run if you come too close.  Hunt them (a
  spear — a knapped spear point on two sticks — hits hardest and reaches furthest) for
  meat, crab and hides.  Tie twine on a junglefowl or goat to lead it: it follows you
  onto your raft, across the sea and off again; let it go and that's its new home.
  Feed two by hand and they have a young one.  Hunted-out islands slowly fill again.
* **Co-op** — up to four players; the host's game holds the island and checks every
  action, so nothing can be duplicated.  When someone leaves, their things go with them
  and come back when they return.

## Project layout

```
data/        blocks, items, crafting recipes, knapping and clay patterns, handbook, hints
src/voxel/   block registry, block storage, chunk mesher (with skylight), renderer
src/world/   island and archipelago generators, game scene, sky, ocean, effects
src/sim/     host rules: blocks, fire and kilns, crafting, farming, rafts, animals, survival, weather
src/player/  movement (box physics on the block grid), cameras, interaction, models
src/entities views of entities (fire pits, kilns, knapping, clay, items, rafts, animals...)
src/ui/      HUD, inventory, handbook, menus
tools/art/   texture and icon generators (Python + Pillow);  tools/audio/  animal sounds
tests/       headless test suites;  tools/*.sh  multiplayer tests
```

Textures and icons are drawn by code: `python3 tools/art/gen_blocks.py` and
`python3 tools/art/gen_items.py` regenerate `assets/textures/`.

## Tests

```
godot --headless --path . res://tests/test_main.tscn -- --suite=all
tools/mp_test.sh      # host + client, leave and rejoin
tools/mp_crowd.sh     # four players grabbing the same things; a fifth is turned away
tools/mp_crash.sh     # a client crashes and comes straight back
tools/mp_sea.sh       # at sea: a friend rides your raft, paddles it, leads a goat
tools/run_tests.sh    # all of the above
```

The suites drive the real game through the same requests a client sends: breaking and
placing blocks, felling trees, knapping, the crafting grid, clay forming, building and
lighting fires, cooking, stew, pit kilns (in a pit and in the open, in the rain),
hunger and cold, death and the bag you leave, farming and regrowth, saving and loading,
and ten days on the island; at sea, the islands and what's on them, salt water and
boiling it fresh, floating, building, sailing, steering, anchoring, grounding and
riding rafts, and the animals (wandering, running, hunting, leading across the sea,
breeding, eggs, coming back to hunted-out islands).

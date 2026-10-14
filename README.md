# Skyroot

A co-op survival and crafting game for 1–4 players, set on a small floating island
above the clouds.  It's a block world, heavily inspired by Vintage Story: you knap
stone tools cell by cell on a grid, build fire pits stick by stick, shape clay pottery
layer by layer, and fire it in a pit kiln you dig and cover yourself.

Everything you need is already on the island: loose stones and flint, fallen sticks
under the trees, tall grass, cattails at the pond, blue clay in its banks, wild
turnips and flax, berry bushes and mushrooms.  Trees, berries, grass and mushrooms
grow back; stone does not.

Built with **Godot 4.7** (GDScript, Forward+ renderer).

## Running it

1. Open the project folder in Godot 4.7 (`project.godot`) and press **Play**, or run
   `godot --path .` from this folder.
2. **Play** starts or continues an island; leave *Open to friends* ticked to host
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
| Space, Ctrl, Shift | jump, sprint, sneak (sneaking, you can't walk off an edge) |
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
  (knife blade, axe head, shovel head, hoe head).  The shape stays bright; the cells
  touching it are red - chip those, and waste no longer joined to the shape falls away
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
* **Co-op** — up to four players; the host's game holds the island and checks every
  action, so nothing can be duplicated.  When someone leaves, their things go with them
  and come back when they return.

## Project layout

```
data/        blocks, items, crafting recipes, knapping and clay patterns, handbook, hints
src/voxel/   block registry, block storage, chunk mesher (with skylight), renderer
src/world/   island generator, game scene, sky, effects
src/sim/     host rules: blocks, fire and kilns, crafting, farming, survival, weather
src/player/  movement (box physics on the block grid), cameras, interaction, models
src/entities views of block entities (fire pits, kilns, knapping, clay, items...)
src/ui/      HUD, inventory, handbook, menus
tools/art/   texture and icon generators (Python + Pillow)
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
tools/run_tests.sh    # all of the above
```

The suites drive the real game through the same requests a client sends: breaking and
placing blocks, felling trees, knapping, the crafting grid, clay forming, building and
lighting fires, cooking, stew, pit kilns (in a pit and in the open, in the rain),
hunger and cold, death and the bag you leave, farming and regrowth, saving and loading,
and ten days on the island.

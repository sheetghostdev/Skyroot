# The closed island economy

Nothing on Skyroot is created from nothing, and nothing vanishes except over the
edge.  Six quantities are conserved and audited by `Ledger.compute()`
(`src/sim/ledger.gd`), which walks every store on the island and sums them:

| quantity | unit | where it lives |
|---|---|---|
| water | litres | soil moisture (per terrain cell), the pond, the air (`atmo_water_l`), juice in plants and berries (`plant_water_l`), water in porridge, in pots and wet clay, in compost heaps, in players' bodies, and what was spilled into the abyss (`lost_water_l`) |
| carbon | kg of biomass-equivalent | the air's CO2 (`atmo_carbon_kg`), the tree, crops, grass, the bush, mushrooms and their log, every organic item, charcoal and ash, soil organic matter (`soil_organic_kg`, `soil_mineral_kg`), compost heaps, fire sites' ash, food scraps waiting in a body, and losses |
| nutrients | abstract units | soil cells, the tree (`tree_nutr`), grass (`grass_nutr`), crops, organic items, ash, compost, fire-site ash, bodies, losses |
| clay | litres | the clay layer, clay items, pots and potsherds, clay in walls, spilled crumbs, losses |
| soil | litres | the soil layer, earth items, earth on mounds and walls, losses |
| stone | kg | loose stones in the outcrop, stones and knapped heads, knapping debris, losses |

The grand totals never change.  The test suites assert this after every scenario —
crafting, fires, construction, compost, crops, saving and loading, multiplayer
sessions, and ten in-game days of island life — to within rounding.

## The cycles

**Water.**  The pond and the soil evaporate into the air (faster when warm, sunny and
windy, slower when the air is already humid).  When the air holds enough, it rains:
on the pond, into open vessels, onto compost heaps and items, and into the soil;
what the soil can't take runs off into the pond.  Plants draw soil water and transpire
it.  People drink from the pond or vessels and lose water to the air as they breathe
and sweat.  Water poured over the edge is gone.

**Carbon.**  Plants and the tree grow by fixing carbon from the air; growth is paid
for, kilogram for kilogram.  Burning returns carbon to the air (charcoal and ash keep
some of it); eating returns food carbon to the air except what leaves the body as
food scraps; rotting (in compost heaps, cut stubble, curing grass) returns part to the
air and part to the soil.  The tree regrows cut branches from its stored reserve.

**Nutrients.**  Plants take nutrients from the soil under them; harvests can contain
no more than the plant absorbed.  Eating puts the nutrients into food scraps; scraps,
leaves and other greens go into compost, compost and ash are worked back into the
soil.  Burning leaves the minerals in the ash.

**Clay and soil.**  Digging moves soil or clay from the terrain into items; filling,
covering mounds and daubing walls moves it back out.  Fired pots are clay; a cracked
pot breaks into potsherds plus a few crumbs.

**Stone.**  The outcrop holds a fixed number of loose stones.  Knapping turns part of
a stone into a tool and the rest into debris; a worn-out tool head comes back as a
dull shaped stone that can be knapped again.

## What the player experiences

* There are as many stones as the outcrop holds — use them well.
* The tree, grass, crops, the bush and mushrooms regrow, but only from what the island
  can supply: dry weather and spent soil slow everything down.
* Feeding the soil (compost, ash) keeps crops productive; farming without returning
  anything slowly spends the soil.
* Anything dropped or knocked over the edge — or carried when you fall — is lost for
  good.  The ledger records it as lost, so the books still balance.

## Notes on abstraction

* Water bound inside living tissue (the moisture of fresh leaves, grass and wood) is
  part of the item's material, not of the water ledger; drying an item changes its
  state, not the water totals.  Free water — in the pond, soil, air, vessels, clay,
  porridge and bodies — is always counted.
* "Carbon" is biomass-equivalent mass rather than elemental carbon, so a kilogram of
  wood burned returns a kilogram of fixable biomass-equivalent to the air.
* Hunger and stamina are not matter: a respawned player wakes with a little food
  energy without any matter changing hands.

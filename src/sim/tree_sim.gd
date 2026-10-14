class_name TreeSim
extends RefCounted
## The island tree as a living, renewable - but finite-rate - resource.
##
## Biomass lives in explicit pools: roots (rb), trunk & crown wood (tb), the
## individually harvestable branches and a sugar/wood reserve (store).  New
## biomass is made only by photosynthesis: carbon from the island's atmosphere
## pool, water drawn from the soil around the roots (transpired back to the
## air) and nutrients from the root zone.  Felling the trunk leaves the roots
## alive; they push up a sapling from their reserves.  A planted seed grows
## the same way from almost nothing.

const SMALL := 8
const LARGE := 5
const SMALL_KG := 1.4
const LARGE_KG := 9.5
const TRUNK_FULL := 163.0       # trunk & crown wood of a full-grown tree
const MATURE_TB := 60.0         # trunk mass at which branches start to grow
const ROOT_FULL := 90.0
const STORE_MAX := 16.0
const ROOT_RADIUS := 2.8
const GROW_RATE := 0.5          # kg per game hour per unit leaf area at full light
const WATER_PER_KG := 1.5       # litres transpired per kg grown
const NUTR_PER_KG := 0.0018
const LOG_KG := 70.0


static func new_state() -> Dictionary:
	var sb := []
	var lb := []
	var shp := []
	var lhp := []
	for i in SMALL:
		sb.append(1.0)
		shp.append(1.0)
	for i in LARGE:
		lb.append(1.0)
		lhp.append(1.0)
	return {"sb": sb, "lb": lb, "shp": shp, "lhp": lhp, "trunk": 1.0, "felled": false,
		"tb": TRUNK_FULL, "rb": ROOT_FULL, "store": 6.0, "shed": 3.0, "seedt": 20.0, "leaft": 10.0}


static func seedling_state() -> Dictionary:
	var d := new_state()
	for i in SMALL:
		d["sb"][i] = 0.0
	for i in LARGE:
		d["lb"][i] = 0.0
	d["felled"] = true
	d["tb"] = 0.0
	d["rb"] = 0.0
	d["store"] = ItemDB.unit_mass("seed_tree")
	d["from_seed"] = true
	return d


static func is_mature(d: Dictionary) -> bool:
	return not bool(d.get("felled", false))


static func growth(d: Dictionary) -> float:
	## 0..1 visual size of the trunk/crown.
	return clampf(float(d.get("tb", 0.0)) / TRUNK_FULL, 0.0, 1.0)


static func stage(d: Dictionary) -> String:
	if is_mature(d):
		return "mature"
	var tb := float(d.get("tb", 0.0))
	if tb < 0.05 and float(d.get("rb", 0.0)) <= 0.0 and float(d.get("store", 0.0)) <= 0.0:
		return "dead"
	if tb < 18.0:
		return "sapling"
	return "young"


static func leaf_area(d: Dictionary) -> float:
	if bool(d.get("felled", false)):
		return 0.4 + 5.0 * clampf(float(d.get("tb", 0.0)) / MATURE_TB, 0.0, 1.0)
	var a := 2.0
	for g in d["sb"]:
		a += float(g) * 0.12
	for g in d["lb"]:
		a += float(g) * 0.55
	return a


static func biomass(d: Dictionary) -> float:
	var b := float(d.get("rb", 0.0)) + float(d.get("tb", 0.0)) + float(d.get("store", 0.0))
	if not bool(d.get("felled", false)):
		for g in d["sb"]:
			b += float(g) * SMALL_KG
		for g in d["lb"]:
			b += float(g) * LARGE_KG
	return b


static func on_felled(d: Dictionary) -> Array:
	## Returns the items the falling tree becomes; their mass equals what left the tree.
	var drops: Array = []
	var tb := float(d["tb"])
	var logs := int(floor(tb / LOG_KG))
	var rest := tb - logs * LOG_KG
	if logs > 0:
		drops.append(["log", logs])
	var limbs := int(floor(rest / ItemDB.unit_mass("limb")))
	rest -= limbs * ItemDB.unit_mass("limb")
	if limbs > 0:
		drops.append(["limb", limbs])
	var fw := int(floor(rest / ItemDB.unit_mass("firewood")))
	rest -= fw * ItemDB.unit_mass("firewood")
	if fw > 0:
		drops.append(["firewood", fw])
	var lv := int(floor(rest / ItemDB.unit_mass("leaves")))
	rest -= lv * ItemDB.unit_mass("leaves")
	if lv > 0:
		drops.append(["leaves", lv])
	for i in SMALL:
		if float(d["sb"][i]) >= 0.98:
			drops.append(["branch", 1])
		else:
			rest += float(d["sb"][i]) * SMALL_KG
		d["sb"][i] = 0.0
		d["shp"][i] = 1.0
	for i in LARGE:
		if float(d["lb"][i]) >= 0.98:
			drops.append(["limb", 1])
		else:
			rest += float(d["lb"][i]) * LARGE_KG
		d["lb"][i] = 0.0
		d["lhp"][i] = 1.0
	# unharvestable remainder (bark crumbs, small twigs) stays in the tree's reserve
	d["felled"] = true
	d["tb"] = 0.0
	d["trunk"] = 1.0
	# the root system mobilises reserves into new shoots
	var reserve := minf(20.0, float(d["rb"]) * 0.22)
	d["rb"] = float(d["rb"]) - reserve
	d["store"] = float(d["store"]) + reserve + rest
	return drops


static func tick(d: Dictionary, hours: float, light: float, pos: Vector3, terrain: TerrainData, pools: Dictionary) -> Dictionary:
	## Advance growth by `hours`.  Mutates d, the soil and the pools.
	var out := {"drops": [], "changed": false}
	if stage(d) == "dead":
		return out
	var cells := terrain.cells_in_radius(Vector2(pos.x, pos.z), ROOT_RADIUS * (0.4 if float(d.get("rb", 0.0)) < 20.0 else 1.0))
	if cells.is_empty():
		return out
	var moist := 0.0
	var nutr := 0.0
	for k in cells:
		moist += terrain.moist[k]
		nutr += terrain.nutr[k]
	moist /= cells.size()
	var water_f := clampf((moist - 0.12) / 0.4, 0.0, 1.0)
	var nutr_f := clampf(nutr / (cells.size() * 0.004), 0.0, 1.0)
	var carbon_f := clampf(float(pools.get("atmo_carbon_kg", 0.0)) / 50.0, 0.0, 1.0)
	var grow := GROW_RATE * leaf_area(d) * light * water_f * (0.35 + 0.65 * nutr_f) * carbon_f * hours
	grow = minf(grow, float(pools.get("atmo_carbon_kg", 0.0)))
	var cap_l := TerrainData.FIELD_CAPACITY * TerrainData.CELL_AREA * 1000.0
	var water_avail := 0.0
	for k in cells:
		water_avail += maxf(0.0, terrain.moist[k] - 0.08) * cap_l
	var water_need := grow * WATER_PER_KG
	if water_need > water_avail * 0.5 and water_need > 0.0:
		grow *= water_avail * 0.5 / water_need
	var nutr_need := grow * NUTR_PER_KG
	if nutr_need > nutr * 0.25 and nutr_need > 0.0:
		grow *= nutr * 0.25 / nutr_need
	water_need = grow * WATER_PER_KG
	nutr_need = grow * NUTR_PER_KG
	if grow > 0.0:
		draw_from_cells(terrain, cells, water_need, nutr_need)
		pools["atmo_carbon_kg"] = float(pools["atmo_carbon_kg"]) - grow
		pools["atmo_water_l"] = float(pools.get("atmo_water_l", 0.0)) + water_need
		pools["tree_nutr"] = float(pools.get("tree_nutr", 0.0)) + nutr_need
		d["store"] = float(d.get("store", 0.0)) + grow
	var store := float(d.get("store", 0.0))
	if bool(d.get("felled", false)):
		# young tree: part to roots (until full), the rest to the trunk
		var spend := minf(store, hours * 2.2)
		var to_roots := spend * (0.3 if float(d.get("rb", 0.0)) < ROOT_FULL * 0.8 else 0.0)
		d["rb"] = float(d.get("rb", 0.0)) + to_roots
		d["tb"] = float(d.get("tb", 0.0)) + spend - to_roots
		d["store"] = store - spend
		if spend > 0.001:
			out["changed"] = true
		if float(d["tb"]) >= MATURE_TB:
			d["felled"] = false
	else:
		var sb: Array = d["sb"]
		var lb: Array = d["lb"]
		for i in SMALL:
			if float(sb[i]) < 1.0 and store > 0.05:
				var dg := minf(1.0 - float(sb[i]), minf(hours / 10.0, store / SMALL_KG))
				sb[i] = float(sb[i]) + dg
				store -= dg * SMALL_KG
				out["changed"] = true
		for i in LARGE:
			if float(lb[i]) < 1.0 and store > 0.3:
				var dg := minf(1.0 - float(lb[i]), minf(hours / 26.0, store / LARGE_KG))
				lb[i] = float(lb[i]) + dg
				store -= dg * LARGE_KG
				out["changed"] = true
		# thicken the trunk with what's left
		if store > 4.0 and float(d["tb"]) < TRUNK_FULL:
			var dt := minf(store - 4.0, minf(hours * 1.5, TRUNK_FULL - float(d["tb"])))
			d["tb"] = float(d["tb"]) + dt
			store -= dt
		if store > STORE_MAX:
			pools["atmo_carbon_kg"] = float(pools["atmo_carbon_kg"]) + (store - STORE_MAX)  # respired
			store = STORE_MAX
		d["store"] = store
		d["shed"] = float(d.get("shed", 0.0)) - hours
		if float(d["shed"]) <= 0.0 and float(d["store"]) > 0.5:
			d["shed"] = randf_range(5.0, 9.0)
			_shed(d, pools, out, "twig")
		d["leaft"] = float(d.get("leaft", 0.0)) - hours
		if float(d["leaft"]) <= 0.0 and float(d["store"]) > 1.0:
			d["leaft"] = randf_range(18.0, 30.0)
			_shed(d, pools, out, "leaves")
		d["seedt"] = float(d.get("seedt", 0.0)) - hours
		if float(d["seedt"]) <= 0.0 and float(d["store"]) > 1.0:
			d["seedt"] = randf_range(26.0, 40.0)
			_shed(d, pools, out, "seed_tree")
	return out


static func _shed(d: Dictionary, pools: Dictionary, out: Dictionary, id: String) -> void:
	## The tree lets something fall: its wood comes from the reserve, its
	## nutrients from what the tree has taken up (no nutrients, no drop).
	var nu := ItemDB.nutrients(id)
	if float(pools.get("tree_nutr", 0.0)) < nu:
		return
	pools["tree_nutr"] = float(pools["tree_nutr"]) - nu
	d["store"] = float(d["store"]) - ItemDB.unit_mass(id)
	out["drops"].append([id, 1])


static func draw_from_cells(terrain: TerrainData, cells: PackedInt32Array, water_l: float, nutr: float) -> void:
	var cap_l := TerrainData.FIELD_CAPACITY * TerrainData.CELL_AREA * 1000.0
	var per_cell_w := water_l / cells.size()
	var carry := 0.0
	for k in cells:
		var avail := maxf(0.0, terrain.moist[k] - 0.05) * cap_l
		var want := per_cell_w + carry
		var take := minf(avail, want)
		carry = want - take
		terrain.moist[k] -= take / cap_l
	var per_cell_n := nutr / cells.size()
	var carry_n := 0.0
	for k in cells:
		var want := per_cell_n + carry_n
		var take := minf(terrain.nutr[k], want)
		carry_n = want - take
		terrain.nutr[k] -= take

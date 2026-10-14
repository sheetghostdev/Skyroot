extends Node
## Data-driven definitions loaded from res://data/*.json: items, blocks (through
## Blocks), crafting recipes, knapping and clay-forming patterns.  Everything that
## describes "what a thing is" lives there; systems query it through here.

const KNAP := 16
const CLAY_PER_LUMP := 32

var items: Dictionary = {}
var recipes: Array = []
var knapping: Dictionary = {}     # recipe id -> {"label", "mask": PackedByteArray(256)}
var clayforming: Dictionary = {}  # recipe id -> {"label", "out", "n", "layers": Array[PackedByteArray]}
var stone_mask := PackedByteArray()


func _ready() -> void:
	load_all()


func load_all() -> void:
	Blocks.load_all()
	items = _load_json("res://data/items.json")
	items.erase("_doc")
	recipes = _load_json("res://data/recipes.json").get("recipes", [])
	var kn := _load_json("res://data/knapping.json")
	for k in kn:
		if String(k).begins_with("_"):
			continue
		var mask := PackedByteArray()
		mask.resize(KNAP * KNAP)
		var rows: Array = kn[k]["pattern"]
		for z in KNAP:
			var row := String(rows[z])
			for x in KNAP:
				mask[x + z * KNAP] = 1 if row[x] == "#" else 0
		knapping[k] = {"label": String(kn[k].get("label", k)), "mask": mask}
	var cf := _load_json("res://data/clayforming.json")
	for k in cf:
		if String(k).begins_with("_"):
			continue
		var layers: Array[PackedByteArray] = []
		for l in cf[k]["layers"]:
			layers.append(_clay_layer(l))
		clayforming[k] = {"label": String(cf[k].get("label", k)), "out": String(cf[k]["out"]), "n": int(cf[k].get("n", 1)), "layers": layers}
	# the stone you start knapping from: a rounded slab filling most of the block
	stone_mask.resize(KNAP * KNAP)
	for z in KNAP:
		for x in KNAP:
			var dx := absf(x - 7.5)
			var dz := absf(z - 7.5)
			stone_mask[x + z * KNAP] = 1 if dx + dz <= 11.2 and dx * dx + dz * dz <= 72.0 else 0


func _clay_layer(l: Dictionary) -> PackedByteArray:
	var m := PackedByteArray()
	m.resize(KNAP * KNAP)
	for z in KNAP:
		for x in KNAP:
			var d := Vector2(x - 7.5, z - 7.5).length()
			var on := false
			if l.has("disc"):
				on = d <= float(l["disc"])
			elif l.has("ring"):
				on = d <= float(l["ring"][0]) and d > float(l["ring"][1])
			elif l.has("rects"):
				for r in l["rects"]:
					if x >= int(r[0]) and x <= int(r[2]) and z >= int(r[1]) and z <= int(r[3]):
						on = true
			m[x + z * KNAP] = 1 if on else 0
	return m


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("ItemDB: cannot open " + path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_error("ItemDB: bad json " + path)
	return {}


# ---------------------------------------------------------------------------
# Items
# ---------------------------------------------------------------------------

func exists(id: String) -> bool:
	return items.has(id)


func def(id: String) -> Dictionary:
	return items.get(id, {})


func stack_max(id: String) -> int:
	return int(def(id).get("stack", 1))


func can_stack(id: String, d: Dictionary) -> bool:
	return stack_max(id) > 1 and d.is_empty()


func label(id: String, d: Dictionary = {}) -> String:
	var base := String(def(id).get("label", id.capitalize()))
	var mat := String(d.get("mat", ""))
	if mat == "flint":
		base = "Flint " + base.to_lower()
	elif mat == "stone":
		base = "Stone " + base.to_lower()
	var c := String(d.get("c", ""))
	if c == "water":
		base += " of water"
	elif c == "stew":
		base += " of stew"
	return base


func desc(id: String) -> String:
	return String(def(id).get("desc", ""))


func food(id: String) -> Dictionary:
	return def(id).get("food", {})


func fuel(id: String) -> String:
	return String(def(id).get("fuel", ""))


func tool_info(id: String) -> Dictionary:
	return def(id).get("tool", {})


func tool_kind(id: String) -> String:
	return String(tool_info(id).get("kind", ""))


func max_durability(id: String, d: Dictionary = {}) -> int:
	var base := int(tool_info(id).get("dur", 0))
	if String(d.get("mat", "")) == "flint":
		base = int(base * 1.7)
	return int(base * float(d.get("q", 1.0)))


func block_of(id: String) -> int:
	var b := String(def(id).get("block", ""))
	return Blocks.id_of(b) if b != "" else -1


func item_of_block(block_id: int) -> String:
	var d := Blocks.def(block_id)
	return String(d.get("item", ""))


func icon_key(id: String, d: Dictionary = {}) -> String:
	var mat := String(d.get("mat", ""))
	var c := String(d.get("c", ""))
	if mat != "" and Icons.has("%s@%s" % [id, mat]):
		return "%s@%s" % [id, mat]
	if c != "" and Icons.has("%s@%s" % [id, c]):
		return "%s@%s" % [id, c]
	return id


func is_raw_pottery(id: String) -> bool:
	return def(id).has("raw_pottery")


func fired_of(id: String) -> String:
	var k := String(def(id).get("raw_pottery", ""))
	return k


# ---------------------------------------------------------------------------
# Crafting grid
# ---------------------------------------------------------------------------

func _ing_ok(spec: String, s: Dictionary) -> bool:
	if s.is_empty():
		return false
	var id := String(s["i"])
	if spec.begins_with("tool:"):
		return tool_kind(id) == spec.substr(5)
	for alt in spec.split("|"):
		if alt == id:
			return true
	return false


func match_recipe(grid: Array) -> Dictionary:
	## grid: 9 stacks (row-major 3x3).  Returns {"recipe", "slots": {key/index -> grid slot}} or {}.
	for r in recipes:
		var m := _match_one(r, grid)
		if not m.is_empty():
			return m
	return {}


func _match_one(r: Dictionary, grid: Array) -> Dictionary:
	var filled: Array = []
	for i in 9:
		if not (grid[i] as Dictionary).is_empty():
			filled.append(i)
	if r.has("shapeless"):
		var need: Array = r["shapeless"]
		if need.size() != filled.size():
			return {}
		var used := {}
		var map := {}
		for ni in need.size():
			var found := -1
			for gi in filled:
				if not used.has(gi) and _ing_ok(String(need[ni]), grid[gi]):
					found = gi
					break
			if found < 0:
				return {}
			used[found] = true
			map[ni] = found
		return {"recipe": r, "slots": map}
	var shape: Array = r["shape"]
	var h := shape.size()
	var w := 0
	for row in shape:
		w = maxi(w, String(row).length())
	for mirror in [false, true]:
		for oy in range(0, 4 - h):
			for ox in range(0, 4 - w):
				var ok := true
				var map := {}
				var covered := {}
				for ry in h:
					var row := String(shape[ry])
					for rx in w:
						var ch := row[rx] if rx < row.length() else " "
						var gx := ox + (w - 1 - rx if mirror else rx)
						var gi := gx + (oy + ry) * 3
						if ch == " " or ch == ".":
							continue
						covered[gi] = true
						if not _ing_ok(String(r["keys"][ch]), grid[gi]):
							ok = false
						else:
							map[ch] = gi
				if not ok:
					continue
				# nothing else in the grid
				for gi in filled:
					if not covered.has(gi):
						ok = false
				if ok:
					return {"recipe": r, "slots": map}
	return {}


func recipe_output(m: Dictionary, grid: Array) -> Dictionary:
	## The stack a matched recipe makes.
	var r: Dictionary = m["recipe"]
	var out := String(r["out"])
	var d := {}
	if r.has("mat"):
		var src: Dictionary = grid[int(m["slots"][r["mat"]])]
		var sd: Dictionary = src.get("d", {})
		d["mat"] = sd.get("mat", "stone")
		if sd.has("q"):
			d["q"] = sd["q"]
	if not tool_info(out).is_empty():
		d["dur"] = max_durability(out, d)
	return {"i": out, "n": int(r.get("n", 1)), "d": d}


func recipes_using(id: String) -> Array:
	var out: Array = []
	for r in recipes:
		var ings: Array = r.get("shapeless", [])
		if r.has("keys"):
			ings = (r["keys"] as Dictionary).values()
		for spec in ings:
			if String(spec) == id or String(spec).split("|").has(id):
				out.append(r)
				break
	return out


func recipes_making(id: String) -> Array:
	return recipes.filter(func(r): return String(r["out"]) == id)

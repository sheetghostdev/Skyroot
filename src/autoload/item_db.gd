extends Node
## Data-driven definitions: items, plants and building blueprints, loaded from
## res://data/*.json.  Everything that describes "what a thing is" lives there;
## systems query it through this singleton.

var items: Dictionary = {}
var plants: Dictionary = {}
var blueprints: Dictionary = {}

const QUALITY_WORDS := ["Crude", "Rough", "Decent", "Good", "Fine", "Excellent"]


func _ready() -> void:
	load_all()


func load_all() -> void:
	items = _load_json("res://data/items.json")
	plants = _load_json("res://data/plants.json")
	blueprints = _load_json("res://data/blueprints.json")


func _load_json(path: String) -> Dictionary:
	var res = load(path)
	if res is JSON and res.data is Dictionary:
		return res.data
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("ItemDB: cannot open " + path)
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_error("ItemDB: bad json " + path)
	return {}


func exists(id: String) -> bool:
	return items.has(id)


func def(id: String) -> Dictionary:
	return items.get(id, {})


func stack_max(id: String) -> int:
	return int(def(id).get("stack", 1))


func unit_mass(id: String) -> float:
	return float(def(id).get("mass", 0.1))


func unit_volume(id: String) -> float:
	return float(def(id).get("vol", 0.1))


func material(id: String) -> String:
	return String(def(id).get("mat", ""))


func has_tag(id: String, tag: String) -> bool:
	return def(id).get("tags", []).has(tag)


func fuel(id: String) -> Dictionary:
	return def(id).get("fuel", {})


func food(id: String) -> Dictionary:
	return def(id).get("food", {})


func tool_info(id: String) -> Dictionary:
	return def(id).get("tool", {})


func tool_kind(id: String) -> String:
	return String(tool_info(id).get("kind", ""))


func nutrients(id: String) -> float:
	## Nutrient units carried by one unit of this item (organic matter or fertilizer).
	var d := def(id)
	if d.has("nutr"):
		return float(d["nutr"])
	return float(d.get("organic", {}).get("nutr", 0.0))


func is_organic(id: String) -> bool:
	return has_tag(id, "organic")


func guide_entry(id: String) -> String:
	return String(def(id).get("guide", ""))


func quality_word(q: float) -> String:
	return QUALITY_WORDS[clampi(int(q * QUALITY_WORDS.size()), 0, QUALITY_WORDS.size() - 1)]


func display_name(id: String, d: Dictionary = {}) -> String:
	var base := String(def(id).get("name", id))
	match id:
		"blade", "axe", "digger":
			if d.has("q"):
				return "%s %s" % [quality_word(float(d["q"])), base.to_lower()]
		"stone_head":
			var shape := String(d.get("shape", ""))
			if shape != "":
				return {"blade": "Knapped blade", "axe": "Stone axe head", "digger": "Stone digging blade"}.get(shape, base)
		"pot":
			return Pottery.display_name(d)
		"wood_piece":
			return String(d.get("label", base))
		"torch":
			return base
	return base


func describe(id: String, d: Dictionary = {}) -> String:
	var lines: PackedStringArray = []
	lines.append(String(def(id).get("desc", "")))
	match id:
		"blade", "axe", "digger":
			if d.has("q"):
				lines.append("Quality %d%%   Wear %d%%" % [int(float(d["q"]) * 100.0), int(100.0 - 100.0 * float(d.get("dur", 1.0)))])
				if d.has("note"):
					lines.append(String(d["note"]))
		"stone_head":
			if d.has("q"):
				lines.append("Shape quality %d%%. Bind it to a stick with cordage." % int(float(d["q"]) * 100.0))
		"pot":
			lines.append(Pottery.describe(d))
	if d.has("moist") and def(id).has("moist"):
		var m := float(d["moist"])
		if def(id).get("mat", "") == "wood":
			lines.append("Seasoned (dry)" if m < 0.2 else ("Drying" if m < 0.3 else "Green (wet) wood"))
	return "\n".join(lines)


func can_stack(id: String, d: Dictionary) -> bool:
	## Stackable items may only differ by moisture, which merges as an average.
	return stack_max(id) > 1 and (d.is_empty() or (d.size() == 1 and d.has("moist")))


func default_moist(id: String) -> float:
	return float(def(id).get("moist", 0.0))


func icon_key(id: String, d: Dictionary = {}) -> String:
	if d.is_empty():
		return id
	return id + ":" + str(hash(d))


# ---------------------------------------------------------------------------
# Blueprints
# ---------------------------------------------------------------------------

func blueprint(id: String) -> Dictionary:
	return blueprints.get(id, {})


func part_accepts(part_spec: String, item_id: String) -> bool:
	for alt in part_spec.split("|"):
		if alt == item_id:
			return true
	return false


func part_label(part_spec: String) -> String:
	var names: PackedStringArray = []
	for alt in part_spec.split("|"):
		names.append(String(def(alt).get("name", alt)))
	return " or ".join(names)


func blueprint_totals(bp_id: String) -> Dictionary:
	var totals := {}
	for p in blueprint(bp_id).get("parts", []):
		totals[p] = totals.get(p, 0) + 1
	return totals


func plant(id: String) -> Dictionary:
	return plants.get(id, {})

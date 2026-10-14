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


# Things counted in loads, lumps and bundles rather than one by one.
const UNITS := {
	"earth": ["load of earth", "loads of earth"], "clay": ["lump of raw clay", "lumps of raw clay"],
	"clay_prepared": ["lump of prepared clay", "lumps of prepared clay"], "cordage": ["length of cordage", "lengths of cordage"],
	"straw": ["bundle of straw", "bundles of straw"], "fiber": ["bundle of fiber", "bundles of fiber"],
	"grass": ["handful of grass", "handfuls of grass"], "leaves": ["bunch of leaves", "bunches of leaves"],
	"firewood": ["piece of firewood", "pieces of firewood"], "charcoal": ["piece of charcoal", "pieces of charcoal"],
	"ash": ["handful of ash", "handfuls of ash"], "compost": ["basket of compost", "baskets of compost"],
	"food_scraps": ["handful of food scraps", "handfuls of food scraps"], "berries": ["handful of berries", "handfuls of berries"],
	"seed_grain": ["handful of grain seeds", "handfuls of grain seeds"], "seed_fiber": ["pinch of fiber seeds", "pinches of fiber seeds"],
	"potsherds": ["handful of potsherds", "handfuls of potsherds"],
}


static func with_article(noun: String) -> String:
	## "a stone", "an axe head" (by spelling; good enough for the island's words).
	if noun == "":
		return noun
	return ("an " if "aeiou".contains(noun.substr(0, 1).to_lower()) else "a ") + noun


static func plural(noun: String) -> String:
	if noun.ends_with("s"):
		return noun
	if noun.ends_with("y") and noun.length() > 1 and not "aeiou".contains(noun.substr(noun.length() - 2, 1)):
		return noun.substr(0, noun.length() - 1) + "ies"
	if noun.ends_with("sh") or noun.ends_with("ch") or noun.ends_with("x"):
		return noun + "es"
	return noun + "s"


func a_name(id: String, d: Dictionary = {}) -> String:
	## "a rough board", "a load of earth".
	if UNITS.has(id):
		return with_article(String(UNITS[id][0]))
	return with_article(display_name(id, d).to_lower())


func count_name(id: String, n: int, d: Dictionary = {}, number: bool = true) -> String:
	## "3 rough boards", "6 loads of earth" (or without the number: "rough boards").
	var word: String
	if UNITS.has(id):
		word = String(UNITS[id][0 if n == 1 else 1])
	else:
		var nm := display_name(id, d).to_lower()
		word = nm if n == 1 else plural(nm)
	return ("%d %s" % [n, word]) if number else word


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
				if String(d.get("shape", "")) in ["axe", "digger"]:
					lines.append("Shape quality %d%%. Bind it to a stick with cordage." % int(float(d["q"]) * 100.0))
				elif String(d.get("shape", "")) == "":
					lines.append("Not finished yet: set it on the anvil stone again and keep knapping.")
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

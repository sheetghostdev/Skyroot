extends Node
## The Handbook (H) and the goal tracker, client side.
##
## * Handbook pages come from data/guide.json (how-to pages) plus one generated
##   page per item: what it is, how to get it, what it is used for.
## * Hints (data/hints.json) are shown once each, when the game asks for them.
## * Goals: the first steps on the island, one after another, each ticked off
##   when its condition is met (they stay done).  The tracker shows the current
##   one; the Handbook lists them all.
##
## Progress is per player and per island: it is kept locally and sent to the
## host, which saves it with the player's record.

const LOCAL_PATH := "user://guide_progress.cfg"

var pages: Dictionary = {}          # id -> {title, cat, body, items}
var categories: Array = []          # [{id, title, pages: [ids]}]
var hints: Dictionary = {}          # hint id -> {text, keys}
var goals: Array = []               # [{id, title, text, page, check}]
var discovery_defs: Dictionary = {}

var read: Dictionary = {}           # page id -> true
var seen: Dictionary = {}           # hint id -> true
var done: Dictionary = {}           # goal id -> true
var flags: Dictionary = {}          # things this player has done ("lit_fire"...)
var hints_disabled := false
var last_page := ""

var _world_key := ""
var _sync_timer := -1.0
var _check_t := 0.0


func _ready() -> void:
	_load_data()
	Events.hint.connect(_on_hint_requested)
	Events.discovery.connect(_on_discovery)


func _load_data() -> void:
	var g := _load_json("res://data/guide.json")
	for c in g.get("categories", []):
		var ids: Array = []
		for p in c.get("pages", []):
			p["cat"] = c["id"]
			pages[p["id"]] = p
			ids.append(p["id"])
		categories.append({"id": c["id"], "title": c["title"], "pages": ids})
	goals = g.get("goals", [])
	discovery_defs = g.get("discoveries", {})
	hints = _load_json("res://data/hints.json")
	hints.erase("_doc")


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func page(id: String) -> Dictionary:
	if pages.has(id):
		return pages[id]
	if id.begins_with("item:"):
		return item_page(id.substr(5))
	return {}


func item_page(item: String) -> Dictionary:
	## A generated page: what an item is, where it comes from, what it makes.
	if not ItemDB.exists(item):
		return {}
	var get_lines: Array = []
	for nm in Blocks.defs:
		var bd: Dictionary = Blocks.defs[nm]
		for dr in bd.get("drops", []):
			if String(dr["item"]) == item:
				var how := "Break %s" % String(bd.get("label", nm)).to_lower()
				if dr.has("tool"):
					how += " with a %s" % String(dr["tool"])
				if float(dr.get("p", 1.0)) < 1.0:
					how += " (sometimes)"
				get_lines.append(how + ".")
		if String(bd.get("item", "")) == item and not bd.has("drops"):
			get_lines.append("Break %s." % String(bd.get("label", nm)).to_lower())
	for r in ItemDB.recipes_making(item):
		get_lines.append("Crafting grid: " + _recipe_text(r) + ".")
	for k in ItemDB.knapping:
		if k == item:
			get_lines.append("Knap it from stone or flint.")
	for k in ItemDB.clayforming:
		if ItemDB.clayforming[k]["out"] == item:
			get_lines.append("Shape it from clay (%s)." % ItemDB.clayforming[k]["label"])
	var fired := ItemDB.fired_of(item)
	var use_lines: Array = []
	for r in ItemDB.recipes_using(item):
		use_lines.append("Makes %s: %s." % [ItemDB.label(String(r["out"])).to_lower(), _recipe_text(r)])
	if fired != "":
		use_lines.append("Fire it in a pit kiln to get a %s." % ItemDB.label(fired).to_lower())
	var body := ItemDB.desc(item)
	if not get_lines.is_empty():
		body += "\n\n[b]Getting it[/b]\n" + "\n".join(get_lines)
	if not use_lines.is_empty():
		body += "\n\n[b]Uses[/b]\n" + "\n".join(use_lines)
	return {"id": "item:" + item, "title": ItemDB.label(item), "cat": "items", "body": body, "items": [item]}


func _recipe_text(r: Dictionary) -> String:
	var parts: Array = []
	var ings: Array = r.get("shapeless", [])
	if r.has("keys"):
		var shape: Array = r["shape"]
		var counts := {}
		for row in shape:
			for ch in String(row):
				if r["keys"].has(ch):
					counts[ch] = int(counts.get(ch, 0)) + 1
		for ch in counts:
			parts.append(_ing_name(String(r["keys"][ch]), int(counts[ch])))
		return " + ".join(parts) + (" (%s)" % ("stacked" if shape.size() > 1 and String(shape[0]).length() == 1 else "in a row" if shape.size() == 1 else "in a square"))
	var counts2 := {}
	for s in ings:
		counts2[s] = int(counts2.get(s, 0)) + 1
	for s in counts2:
		parts.append(_ing_name(String(s), int(counts2[s])))
	return " + ".join(parts)


func _ing_name(spec: String, n: int) -> String:
	var nm := ""
	if spec.begins_with("tool:"):
		nm = "any " + spec.substr(5)
	else:
		var alts: Array = []
		for a in spec.split("|"):
			alts.append(ItemDB.label(a).to_lower())
		nm = " or ".join(alts)
	return ("%d %s" % [n, nm]) if n > 1 else nm


func search(query: String) -> Array:
	var q := query.strip_edges().to_lower()
	var out: Array = []
	for id in pages:
		var p: Dictionary = pages[id]
		if q == "" or String(p["title"]).to_lower().contains(q) or String(p.get("body", "")).to_lower().contains(q):
			out.append(id)
	for item in ItemDB.items:
		if q != "" and (ItemDB.label(item).to_lower().contains(q) or item.contains(q)):
			out.append("item:" + item)
	return out


func mark_read(id: String) -> void:
	if not read.has(id):
		read[id] = true
		_changed()
	last_page = id


# ---------------------------------------------------------------------------
# Hints
# ---------------------------------------------------------------------------

func should_show(hint_id: String) -> bool:
	return not hints_disabled and Settings.show_hints and hints.has(hint_id) and not seen.has(hint_id)


func mark_seen(hint_id: String) -> void:
	if not seen.has(hint_id):
		seen[hint_id] = true
		_changed()


func _on_hint_requested(_hint_id: String) -> void:
	pass  # the HUD shows it; it calls mark_seen


func _on_discovery(discovery_id: String, who: String) -> void:
	flags["disc:" + discovery_id] = true


# ---------------------------------------------------------------------------
# Goals
# ---------------------------------------------------------------------------

func flag(name: String) -> void:
	## Something this player did that a goal may wait for ("lit_fire").
	if not flags.has(name):
		flags[name] = true
		_changed()
		check_goals()


func has_flag(name: String) -> bool:
	return flags.has(name)


func current_goal() -> Dictionary:
	for g in goals:
		if not done.has(g["id"]):
			return g
	return {}


func goal_met(g: Dictionary) -> bool:
	var c: Dictionary = g.get("check", {})
	var inv := World.my_inventory
	for k in c:
		match String(k):
			"have":
				for item in c["have"]:
					var need := int(c["have"][item])
					var n := 0
					for alt in String(item).split("|"):
						n += _count_any(inv, alt)
					if n < need:
						return false
			"flag":
				for f in c["flag"]:
					if not flags.has(String(f)):
						return false
			"day":
				if World.day() < int(c["day"]):
					return false
	return true


func _count_any(inv: Inventory, id: String) -> int:
	var n := 0
	for i in Inventory.MAIN:
		var s := inv.get_slot(i)
		if not s.is_empty() and String(s["i"]) == id:
			n += int(s["n"])
	var cur := inv.get_slot(Inventory.CURSOR)
	if not cur.is_empty() and String(cur["i"]) == id:
		n += int(cur["n"])
	return n


func check_goals() -> void:
	var changed := false
	for g in goals:
		if done.has(g["id"]):
			continue
		if goal_met(g):
			done[g["id"]] = true
			changed = true
			Events.toast.emit("Goal done: " + String(g["title"]), "goal")
		else:
			break    # one at a time, in order
	if changed:
		_changed()
	Events.goal_progress.emit()


func _process(delta: float) -> void:
	if _sync_timer > 0.0:
		_sync_timer -= delta
		if _sync_timer <= 0.0:
			_sync_timer = -1.0
			save_local()
			if World.running:
				World.request("guide_state", {"state": export_state()})
	_check_t -= delta
	if _check_t <= 0.0 and World.running:
		_check_t = 1.0
		check_goals()


func _changed() -> void:
	_sync_timer = 1.5


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func export_state() -> Dictionary:
	return {"read": read.duplicate(), "seen": seen.duplicate(), "done": done.duplicate(), "flags": flags.duplicate()}


func import_state(st: Dictionary) -> void:
	for k in ["read", "seen", "done", "flags"]:
		var src = st.get(k, {})
		if src is Dictionary:
			var dst: Dictionary = get(k)
			for key in src:
				dst[String(key)] = true
	Events.goal_progress.emit()


func load_local(world_key: String) -> void:
	_world_key = world_key
	read.clear()
	seen.clear()
	done.clear()
	flags.clear()
	var cfg := ConfigFile.new()
	if cfg.load(LOCAL_PATH) == OK and cfg.has_section(world_key):
		import_state(cfg.get_value(world_key, "state", {}))


func save_local() -> void:
	if _world_key == "":
		return
	var cfg := ConfigFile.new()
	cfg.load(LOCAL_PATH)
	cfg.set_value(_world_key, "state", export_state())
	cfg.save(LOCAL_PATH)

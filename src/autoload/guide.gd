extends Node
## The Survival Guide's data and each player's personal progress with it.
##
## Entries are data (res://data/guide/*.json) describing how the world works,
## linked to items and processes.  Every entry is readable from the start;
## encountering a material or process marks related entries as "new" so the
## player notices them.  Progress (read / pinned / dismissed hints) is personal:
## kept locally and mirrored to the host's save so it survives reconnects.

signal progress_changed
signal pinned_changed

const LOCAL_PATH := "user://guide_progress.cfg"
const MAX_PINS := 3

var categories: Array = []          # [{id, title, order, entries: [ids]}]
var entries: Dictionary = {}        # id -> entry dict (with "category")
var hints: Dictionary = {}          # hint id -> {text, entry, keys}
var discovery_defs: Dictionary = {} # discovery id -> {title, text ("{who}..."), entry}
var last_entry := ""                # where the guide reopens

var read: Dictionary = {}           # entry id -> true
var fresh: Dictionary = {}          # entry id -> true (highlighted as new)
var pinned: Array = []              # entry ids
var dismissed: Dictionary = {}      # hint id -> true
var hints_disabled := false

var _sync_timer := -1.0


func _ready() -> void:
	_load_data()
	Events.hint.connect(_on_hint_requested)
	Events.discovery.connect(_on_discovery)


func _load_data() -> void:
	categories.clear()
	entries.clear()
	var files: PackedStringArray
	if ResourceLoader.has_method("list_directory"):
		files = ResourceLoader.list_directory("res://data/guide")
	else:
		var d := DirAccess.open("res://data/guide")
		files = d.get_files() if d else PackedStringArray()
	for f in files:
		f = f.trim_suffix(".import").trim_suffix(".remap")
		if not f.ends_with(".json"):
			continue
		var data := _load_json("res://data/guide/" + f)
		if data.is_empty():
			continue
		if f == "hints.json":
			hints = data
			continue
		if f == "discoveries.json":
			discovery_defs = data
			continue
		var cat := {"id": f.get_basename(), "title": data.get("title", f), "order": int(data.get("order", 99)),
			"icon": data.get("icon", ""), "entries": []}
		for e in data.get("entries", []):
			e["category"] = cat["id"]
			entries[e["id"]] = e
			cat["entries"].append(e["id"])
		categories.append(cat)
	categories.sort_custom(func(a, b): return a["order"] < b["order"])


func _load_json(path: String) -> Dictionary:
	var res = load(path)
	if res is JSON and res.data is Dictionary:
		return res.data
	var f := FileAccess.open(path, FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			return parsed
	push_warning("Guide: could not load " + path)
	return {}


func entry(id: String) -> Dictionary:
	return entries.get(id, {})


func has_entry(id: String) -> bool:
	return entries.has(id)


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

func search(query: String) -> Array:
	query = query.strip_edges().to_lower()
	if query == "":
		return []
	var words := query.split(" ", false)
	var scored: Array = []
	for id in entries:
		var e: Dictionary = entries[id]
		var score := 0.0
		var title := String(e.get("title", "")).to_lower()
		var kw := " ".join(PackedStringArray(e.get("keywords", []))).to_lower()
		var body := _entry_text(e).to_lower()
		for w in words:
			if title.contains(w):
				score += 10.0 + (5.0 if title.begins_with(w) else 0.0)
			if kw.contains(w):
				score += 6.0
			if String(e.get("summary", "")).to_lower().contains(w):
				score += 3.0
			var c := body.count(w)
			score += minf(c, 6) * 0.8
		if score > 0.0:
			scored.append([score, id])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var out: Array = []
	for s in scored:
		out.append(s[1])
	return out


func _entry_text(e: Dictionary) -> String:
	var parts: PackedStringArray = [String(e.get("summary", ""))]
	for sec in e.get("sections", []):
		parts.append(String(sec.get("h", "")))
		parts.append(String(sec.get("text", "")))
		for s in sec.get("steps", []):
			parts.append(String(s))
		for s in sec.get("list", []):
			parts.append(String(s))
	return " ".join(parts)


# ---------------------------------------------------------------------------
# Progress
# ---------------------------------------------------------------------------

func mark_read(id: String) -> void:
	if not read.has(id) or fresh.has(id):
		read[id] = true
		fresh.erase(id)
		_changed()


func mark_fresh(ids: Array) -> void:
	var any := false
	for id in ids:
		if entries.has(id) and not read.has(id) and not fresh.has(id):
			fresh[id] = true
			any = true
	if any:
		_changed()


func unread_count() -> int:
	return fresh.size()


func toggle_pin(id: String) -> void:
	if pinned.has(id):
		pinned.erase(id)
	else:
		pinned.append(id)
		while pinned.size() > MAX_PINS:
			pinned.pop_front()
	pinned_changed.emit()
	_changed()


func is_pinned(id: String) -> bool:
	return pinned.has(id)


func dismiss_hint(hint_id: String) -> void:
	dismissed[hint_id] = true
	_changed()


func _on_hint_requested(hint_id: String) -> void:
	pass  # the HUD listens to Events.hint and asks should_show()


func _on_discovery(discovery_id: String, who: String) -> void:
	## Someone on the island worked something out: tell everyone, and point at the entry.
	var def: Dictionary = discovery_defs.get(discovery_id, {})
	if def.is_empty():
		return
	var me := who == Settings.player_name
	var text := String(def.get("text", "")).replace("{who}", "You" if me else who)
	Events.toast.emit("%s - %s" % [String(def.get("title", "Discovery")), text], "discovery")
	Sfx.ui("discovery", -4.0)
	var ent := String(def.get("entry", ""))
	if ent != "" and not me:
		mark_fresh([ent])


func should_show(hint_id: String) -> bool:
	return Settings.show_hints and not hints_disabled and not dismissed.has(hint_id) and hints.has(hint_id)


func encountered_item(item_id: String) -> void:
	## Called when the local player first handles an item: highlight related entries.
	var gid := ItemDB.guide_entry(item_id)
	var ids: Array = []
	if gid != "":
		ids.append(gid)
		ids.append_array(entry(gid).get("related", []))
	mark_fresh(ids)


func _changed() -> void:
	progress_changed.emit()
	_sync_timer = 2.0


func _process(delta: float) -> void:
	if _sync_timer > 0.0:
		_sync_timer -= delta
		if _sync_timer <= 0.0:
			save_local()
			if World.running:
				World.request("guide_state", {"state": export_state()})


func export_state() -> Dictionary:
	return {"read": read.keys(), "fresh": fresh.keys(), "pinned": pinned.duplicate(), "dismissed": dismissed.keys()}


func import_state(st: Dictionary) -> void:
	for id in st.get("read", []):
		read[id] = true
	for id in st.get("fresh", []):
		if not read.has(id):
			fresh[id] = true
	for id in st.get("dismissed", []):
		dismissed[id] = true
	if st.get("pinned", []).size() > 0:
		pinned = st["pinned"].duplicate()
	progress_changed.emit()
	pinned_changed.emit()


func load_local(world_key: String) -> void:
	read.clear()
	fresh.clear()
	pinned.clear()
	dismissed.clear()
	var cfg := ConfigFile.new()
	if cfg.load(LOCAL_PATH) == OK and cfg.has_section(world_key):
		import_state(cfg.get_value(world_key, "state", {}))
	set_meta("world_key", world_key)


func save_local() -> void:
	if not has_meta("world_key"):
		return
	var cfg := ConfigFile.new()
	cfg.load(LOCAL_PATH)
	cfg.set_value(get_meta("world_key"), "state", export_state())
	cfg.save(LOCAL_PATH)

class_name GuideTracker
extends VBoxContainer
## Pinned guide entries, shown at the side of the screen while you play: each
## one's checklist, ticking itself off as you carry the right things, make
## discoveries or finish building.

const W := 330.0

var _t := 0.0
var _sig := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 10)
	Guide.pinned_changed.connect(_rebuild)
	_rebuild()


static func step_done(st: Dictionary) -> bool:
	if st.has("have"):
		return World.my_inventory != null and World.my_inventory.count(String(st["have"])) >= int(st.get("n", 1))
	if st.has("found"):
		return World.discoveries.has(String(st["found"]))
	if st.has("built"):
		for e in World.entities_of("structure"):
			if String(e["d"].get("bp", "")) == String(st["built"]) and StructureSim.is_complete(e["d"]):
				return true
	return false


func _process(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = 0.5
	# only rebuild when something actually changed
	var sig := ""
	for id in Guide.pinned:
		sig += String(id) + ":"
		for st in Guide.entry(id).get("track", []):
			sig += "1" if step_done(st) else "0"
	if sig != _sig:
		_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_sig = ""
	for id in Guide.pinned:
		var e := Guide.entry(id)
		if e.is_empty():
			continue
		_sig += String(id) + ":"
		var pc := PanelContainer.new()
		pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pc.add_theme_stylebox_override("panel", UITheme.panel(Color(0.08, 0.075, 0.065, 0.72), 10, Color(UITheme.ACCENT, 0.25), 12))
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 4)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pc.add_child(v)
		var title := UITheme.label(String(e.get("title", id)), 15, UITheme.ACCENT, true)
		title.custom_minimum_size.x = W
		title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(title)
		var track: Array = e.get("track", [])
		if track.is_empty():
			var s := UITheme.label(String(e.get("summary", "")), 13, UITheme.TEXT_DIM)
			s.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			s.custom_minimum_size.x = W
			v.add_child(s)
		var next_marked := false
		var all_done := not track.is_empty()
		for st in track:
			var done := step_done(st)
			_sig += "1" if done else "0"
			all_done = all_done and done
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			row.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var tr := TextureRect.new()
			tr.texture = UITheme._check_tex(done)
			tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
			tr.custom_minimum_size = Vector2(20, 20)
			tr.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			row.add_child(tr)
			var is_next := not done and not next_marked
			if is_next:
				next_marked = true
			var col := Color(UITheme.TEXT_DIM, 0.75) if done else (UITheme.PAPER if is_next else UITheme.TEXT_DIM)
			var l := UITheme.label(GuideUI.plain(String(st.get("text", ""))), 14 if is_next else 13, col, is_next)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = W - 30
			l.add_theme_constant_override("outline_size", 3)
			l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.4))
			row.add_child(l)
			v.add_child(row)
		if all_done:
			v.add_child(UITheme.label("All done. Unpin it in the guide (H).", 12, UITheme.ACCENT_2))
		add_child(pc)

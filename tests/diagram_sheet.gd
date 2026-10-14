extends Control
## Contact sheet for the Survival Guide diagrams (GuideDiagram): lays every
## diagram out in a grid, lets the animations run, saves a PNG and quits.
##   godot --path . --resolution 1960x2400 res://tests/diagram_sheet.tscn -- --sheet=/tmp/sheet.png
## Optional user args:
##   --only=<id>      render just that diagram, large (960x540)
##   --size=<w>x<h>   with --only: render it at this size instead (letterboxing check)
##   --time=<sec>     freeze every diagram at this animation time for the shot
##   --wait=<sec>     real time to let the animations run first (default 1.5)
##   --bench          print per diagram the average _draw() cost, GPU draw calls and the
##                    one-off cost of the first draw (static layers recorded), then quit

const DiagramScript := preload("res://src/ui/guide_diagram.gd")
const COLS := 4
const CELL := Vector2(480, 270)
const BIG := Vector2(960, 540)
const GAP := 8.0
const LABEL_H := 24.0

var _diagrams: Array[Control] = []


class TimedDiagram extends "res://src/ui/guide_diagram.gd":
	## Times _draw() and its main helpers (bench mode only).
	var acc := {}

	func _add(k: String, t0: int) -> void:
		acc[k] = int(acc.get(k, 0)) + Time.get_ticks_usec() - t0

	func _draw() -> void:
		var t0 := Time.get_ticks_usec()
		super()
		_add("draw", t0)
		acc["frames"] = int(acc.get("frames", 0)) + 1

	func _wob(pts: PackedVector2Array, closed: bool = false, amp: float = 0.8, step: float = 8.0) -> PackedVector2Array:
		var t0 := Time.get_ticks_usec()
		var r := super(pts, closed, amp, step)
		_add("wobble", t0)
		return r

	func _fill(pts: PackedVector2Array, col: Color) -> void:
		var t0 := Time.get_ticks_usec()
		super(pts, col)
		_add("fill", t0)

	func _text(pos: Vector2, txt: String, fs: int = 12, col: Color = INK, align: int = CENTER, halo: bool = true) -> void:
		var t0 := Time.get_ticks_usec()
		super(pos, txt, fs, col, align, halo)
		_add("text", t0)


func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	var sheet_path := String(args.get("sheet", "user://diagram_sheet.png"))
	var only := String(args.get("only", ""))

	var ids: PackedStringArray = DiagramScript.ids()
	if args.has("bench"):
		await _bench(ids)
		return
	var cell := CELL
	var cols := COLS
	if only != "":
		ids = PackedStringArray([only])
		cell = BIG
		cols = 1
		if args.has("size"):
			var wh := String(args["size"]).split("x")
			if wh.size() == 2:
				cell = Vector2(maxf(float(wh[0]), 8.0), maxf(float(wh[1]), 8.0))
	var rows := int(ceil(float(ids.size()) / float(cols)))
	var total := Vector2(GAP + cols * (cell.x + GAP), GAP + rows * (cell.y + LABEL_H + GAP))

	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	win.size = Vector2i(int(total.x), int(total.y))
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.11, 0.10, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	for i in ids.size():
		var col := i % cols
		var row := i / cols
		var origin := Vector2(GAP + col * (cell.x + GAP), GAP + row * (cell.y + LABEL_H + GAP))
		var d: Control = DiagramScript.new()
		d.kind = ids[i]
		d.position = origin
		d.size = cell
		add_child(d)
		_diagrams.append(d)
		var l := Label.new()
		l.text = ids[i] + ("" if DiagramScript.has(ids[i]) else "  (unknown id)")
		l.position = origin + Vector2(4, cell.y + 1)
		l.add_theme_color_override("font_color", Color(0.94, 0.9, 0.82))
		l.add_theme_font_size_override("font_size", 15)
		add_child(l)

	if args.has("time"):
		var t := float(args["time"])
		for d in _diagrams:
			d.playing = false
			d.set_time(t)
		for i in 4:
			await get_tree().process_frame
	else:
		await get_tree().create_timer(float(args.get("wait", "1.5"))).timeout
	if DisplayServer.get_name() == "headless":
		# dummy renderer: the diagrams were drawn (so script errors show), nothing to capture
		await get_tree().process_frame
		print("diagram sheet: %d diagrams drawn (headless: nothing to capture)" % ids.size())
		get_tree().quit(0)
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		print("diagram sheet: %d diagrams drawn, but the viewport gave no image" % ids.size())
		get_tree().quit(1)
		return
	if sheet_path.get_base_dir() != "":
		DirAccess.make_dir_recursive_absolute(sheet_path.get_base_dir())
	var err := img.save_png(sheet_path)
	print("diagram sheet: %d diagrams, %dx%d -> %s (%s)" % [ids.size(), img.get_width(), img.get_height(), sheet_path, error_string(err)])
	get_tree().quit(0 if err == OK else 1)


func _bench(ids: PackedStringArray) -> void:
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().size = Vector2i(int(CELL.x), int(CELL.y))
	var d := TimedDiagram.new()
	d.size = CELL
	add_child(d)
	var worst := 0.0
	for id in ids:
		d.acc = {}
		d.kind = id
		d.set_time(1.0)
		for i in 3:
			await get_tree().process_frame
		var first := float(d.acc.get("draw", 0)) / 1000.0
		d.acc = {}
		for i in 20:
			await get_tree().process_frame
		var calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		var n := float(maxi(int(d.acc.get("frames", 1)), 1)) * 1000.0
		var ms := float(d.acc.get("draw", 0)) / n
		worst = maxf(worst, ms)
		print("%-16s %6.2f ms per _draw  (wobble %.2f  fill %.2f  text %.2f)  %4d GPU draw calls   first draw %.1f ms" % [id, ms,
			float(d.acc.get("wobble", 0)) / n, float(d.acc.get("fill", 0)) / n, float(d.acc.get("text", 0)) / n, calls, first])
	print("worst: %.2f ms" % worst)
	get_tree().quit(0)

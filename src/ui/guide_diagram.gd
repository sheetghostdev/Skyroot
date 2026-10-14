class_name GuideDiagram
extends Control
## Animated "field notebook" diagrams for the Survival Guide: hand-drawn ink and
## muted washes on parchment, drawn procedurally.
##
## Every diagram is designed in a fixed 480x270 space and scaled uniformly to
## fit the control (centered).  Set `kind` to one of ids(); an unknown or empty
## kind draws a neutral placeholder card.  Animations loop every few seconds and
## only redraw while the control is visible (at most `max_fps` times a second).
##
## Drawing is retained: a diagram draws into a few child canvas items
## ("layers", see _layer()).  Static layers are recorded once and kept until the
## kind, size or scale changes; they can still move, fade or tint every frame
## through _layer_fx().  Dynamic layers are rebuilt each frame, so keep them
## small, and keep anything time-dependent out of static layers.

const W := 480.0
const H := 270.0

const IDS := [
	"island", "vitals", "economy", "water_cycle", "temperature", "abyss",
	"knap", "knap_shapes", "cordage", "haft", "clay_prep", "pottery", "drying",
	"pit_firing", "fire_triangle", "fire_lay", "fire_drill", "cooking",
	"charcoal_mound", "charcoal_vs_ash", "compost", "farming", "crop_stages",
	"tree_regrow", "log_split", "build_frame", "support", "shelter",
]

# --- palette -----------------------------------------------------------------
const PAPER := Color(0.93, 0.89, 0.80)
const PAPER_EDGE := Color(0.80, 0.72, 0.57)
const INK := Color(0.20, 0.17, 0.13)
const INK2 := Color(0.20, 0.17, 0.13, 0.55)
const EMBER := Color(0.86, 0.45, 0.18)
const FLAME := Color(0.96, 0.76, 0.32)
const WATER := Color(0.36, 0.56, 0.72)
const LEAF := Color(0.45, 0.58, 0.30)
const STRAW := Color(0.80, 0.68, 0.40)
const CLAY := Color(0.68, 0.42, 0.30)
const FIRED := Color(0.74, 0.47, 0.32)
const EARTH := Color(0.45, 0.33, 0.22)
const SOIL := Color(0.30, 0.22, 0.15)
const STONE := Color(0.56, 0.55, 0.51)
const WOOD := Color(0.62, 0.46, 0.30)
const CHARCOAL := Color(0.16, 0.15, 0.15)
const ASH := Color(0.70, 0.69, 0.66)
const SKY := Color(0.62, 0.74, 0.82)
const SMOKE_W := Color(0.95, 0.95, 0.93, 0.8)
const SMOKE_B := Color(0.62, 0.68, 0.80, 0.6)
const RED := Color(0.75, 0.26, 0.2)
const GREEN := Color(0.35, 0.55, 0.28)
const AMBER := Color(0.86, 0.60, 0.16)
const TUBER := Color(0.52, 0.30, 0.45)
const BERRY := Color(0.72, 0.17, 0.24)
const GRASS := Color(0.66, 0.72, 0.48)

const FILL_A := 0.85                      # default wash opacity
const FOFF := Vector2(1.1, 0.9)           # wash misregistration (hand-painted look)
const CENTER := HORIZONTAL_ALIGNMENT_CENTER
const LEFT := HORIZONTAL_ALIGNMENT_LEFT
const RIGHT := HORIZONTAL_ALIGNMENT_RIGHT

## Which diagram to draw (see ids()).  Changing it restarts the animation.
var kind: String = "":
	set(v):
		if v == kind:
			return
		kind = v
		_t = 0.0
		_cache.clear()
		_static_ok = false
		queue_redraw()

## When false the animation clock stands still (useful for screenshots).
var playing: bool = true
## Redraws per second while animating (hand-drawn motion reads fine at 30);
## 0 = every frame.
var max_fps: float = 30.0

var _t: float = 0.0
var _since_draw: float = 0.0
var _seed: int = 0
var _xf := Transform2D.IDENTITY           # 480x270 design space -> control
var _lxf := Transform2D.IDENTITY          # optional local transform inside the design space
var _scale: float = 1.0
var _cache: Dictionary = {}
# Frame-to-frame memo: entries used this frame are kept for the next one and
# everything else is dropped, so static shapes cost a lookup instead of being
# rebuilt (wobbled, triangulated) every frame, and memory stays bounded.
var _memo_now: Dictionary = {}
var _memo_prev: Dictionary = {}
# Retained drawing: everything is drawn into child canvas items ("layers",
# drawn in index order).  Static layers are recorded once and kept until the
# diagram, size or scale changes; dynamic layers are rebuilt every frame.
var _layers: Array[RID] = []
var _dyn: Dictionary = {}                 # indices of dynamic layers
var _static_ok := false
var _ci: RID                              # canvas item currently drawn into
var _fxd: Dictionary = {}                 # layers given a motion/tint this frame

static var _ntab: PackedFloat32Array = _make_noise_table()
static var _fibres: PackedVector2Array = _make_fibres()
static var _sb_card: StyleBoxFlat
static var _sb_edge: StyleBoxFlat
static var _label_font: Font
static var _cloud_cache: Dictionary = {}
# A unit "soft disc" as a plain triangle list: solid core, feathered rim.
static var _disc_tpl: PackedVector2Array = _make_disc(10, 0.62, 1.15)
static var _disc_alpha: PackedFloat32Array = _make_disc_alpha(10)
## A small clay pot (local coordinates, rim up), shared by several diagrams.
static var _POT := PackedVector2Array([Vector2(-6, -11), Vector2(6, -11), Vector2(5, -8), Vector2(10, -3), Vector2(11, 3),
	Vector2(7, 10), Vector2(-7, 10), Vector2(-11, 3), Vector2(-10, -3), Vector2(-5, -8)])


static func ids() -> PackedStringArray:
	return PackedStringArray(IDS)


static func has(id: String) -> bool:
	return IDS.has(id)


func _init() -> void:
	custom_minimum_size = Vector2(W, H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


## Jump the animation clock (seconds).
func set_time(seconds: float) -> void:
	_t = maxf(seconds, 0.0)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_RESIZED:
		queue_redraw()
	elif what == NOTIFICATION_PREDELETE:
		for rid in _layers:
			RenderingServer.free_rid(rid)
		_layers.clear()


func _process(delta: float) -> void:
	if not is_visible_in_tree() or not playing:
		return
	_t += delta
	_since_draw += delta
	if max_fps <= 0.0 or _since_draw >= 1.0 / max_fps - 0.002:
		_since_draw = 0.0
		queue_redraw()


func _draw() -> void:
	if size.x < 4.0 or size.y < 4.0:
		_clear_layers(true)
		_static_ok = false
		return
	var s := minf(size.x / W, size.y / H)
	var off := ((size - Vector2(W, H) * s) * 0.5).round()
	var xf := Transform2D(0.0, Vector2(s, s), 0.0, off)
	if xf != _xf or s != _scale:
		_static_ok = false
	_scale = s
	_xf = xf
	for i in _fxd:
		RenderingServer.canvas_item_set_transform(_layers[i], Transform2D.IDENTITY)
		RenderingServer.canvas_item_set_modulate(_layers[i], Color.WHITE)
	_fxd.clear()
	_memo_prev = _memo_now
	_memo_now = {}
	_clear_layers(not _static_ok)
	if _layer(0, false):
		_card()
	_layer(1, true)
	if has(kind):
		call("_d_" + kind)
	else:
		_d_placeholder()
	_static_ok = true


func _layer(i: int, dynamic: bool) -> bool:
	## Route drawing to layer i (higher layers draw on top).  Returns false for a
	## static layer that is already recorded: the caller skips its drawing code.
	if not dynamic and _static_ok:
		return false
	_ci = _layer_rid(i)
	if dynamic:
		_dyn[i] = true
	_seed = i * 10007
	_lxf = Transform2D.IDENTITY
	RenderingServer.canvas_item_add_set_transform(_ci, _xf)
	return true


func _layer_rid(i: int) -> RID:
	while _layers.size() <= i:
		var rid := RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(rid, get_canvas_item())
		RenderingServer.canvas_item_set_draw_index(rid, _layers.size())
		_layers.append(rid)
	return _layers[i]


func _layer_fx(i: int, m: Transform2D = Transform2D.IDENTITY, tint: Color = Color.WHITE) -> void:
	## Move (rigidly, in design space) and tint/fade a whole layer for this frame,
	## so a recorded static layer can animate without being redrawn.
	var rid := _layer_rid(i)
	RenderingServer.canvas_item_set_transform(rid, _xf * m * _xf.affine_inverse())
	RenderingServer.canvas_item_set_modulate(rid, tint)
	_fxd[i] = true


func _clear_layers(all: bool) -> void:
	for i in _layers.size():
		if all or _dyn.has(i):
			RenderingServer.canvas_item_clear(_layers[i])
	if all:
		_dyn.clear()


# =============================================================================
# Card
# =============================================================================

func _card() -> void:
	if _sb_card == null:
		_sb_card = StyleBoxFlat.new()
		_sb_card.bg_color = PAPER
		_sb_card.border_color = PAPER_EDGE
		_sb_card.set_border_width_all(18)
		_sb_card.border_blend = true
		_sb_card.set_corner_radius_all(8)
		_sb_card.corner_detail = 6
		_sb_card.anti_aliasing = true
		_sb_edge = StyleBoxFlat.new()
		_sb_edge.draw_center = false
		_sb_edge.border_color = Color(INK, 0.45)
		_sb_edge.set_border_width_all(1)
		_sb_edge.set_corner_radius_all(8)
		_sb_edge.corner_detail = 6
		_sb_edge.anti_aliasing = true
	_sb_card.draw(_ci, Rect2(0, 0, W, H))
	_ml(_fibres, Color(INK, 0.055), 1.0, true)
	_sb_edge.draw(_ci, Rect2(0, 0, W, H))


func _d_placeholder() -> void:
	var r := Rect2(190, 92, 100, 66)
	_dashed(_rrect(r, 8.0), INK2, 1.5, 6.0, 5.0, 0.0, true)
	_stroke(PackedVector2Array([Vector2(204, 146), Vector2(226, 118), Vector2(240, 134), Vector2(252, 122), Vector2(276, 146)]), INK2, 1.8)
	_cir(Vector2(262, 108), 6.0, Color(INK, 0.3), true, -1.0, true)
	_text(Vector2(240, 176), "diagram", 13, INK2)


# =============================================================================
# Time & easing
# =============================================================================

static func _seg(x: float, a: float, b: float) -> float:
	return clampf((x - a) / (b - a), 0.0, 1.0)


static func _ss(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


static func _eo(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, 3.0)


static func _ei(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return x * x * x


static func _back(x: float) -> float:
	## Ease out with a small overshoot (a gentle bounce into place).
	x = clampf(x, 0.0, 1.0)
	var c := 2.0
	return 1.0 + (c + 1.0) * pow(x - 1.0, 3.0) + c * pow(x - 1.0, 2.0)


static func _win(x: float, a: float, b: float, fade: float) -> float:
	## 0 -> 1 over [a, a+fade], 1 until b-fade, -> 0 at b.
	return _seg(x, a, a + fade) * (1.0 - _seg(x, b - fade, b))


# =============================================================================
# Noise & randomness (deterministic: fixed table, never random per frame)
# =============================================================================

static func _make_noise_table() -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 271828
	var a := PackedFloat32Array()
	a.resize(256)
	for i in 256:
		a[i] = rng.randf_range(-1.0, 1.0)
	return a


static func _make_disc(n: int, core: float, rim: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a0 := Vector2(cos(TAU * i / n), sin(TAU * i / n))
		var a1 := Vector2(cos(TAU * (i + 1) / n), sin(TAU * (i + 1) / n))
		out.append_array([Vector2.ZERO, a0 * core, a1 * core])
		out.append_array([a0 * core, a0 * rim, a1 * rim])
		out.append_array([a0 * core, a1 * rim, a1 * core])
	return out


static func _make_disc_alpha(n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in n:
		out.append_array([1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0])
	return out


static func _make_fibres() -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var out := PackedVector2Array()
	for i in 80:
		var p := Vector2(rng.randf_range(12.0, W - 12.0), rng.randf_range(12.0, H - 12.0))
		var a := rng.randf_range(0.0, TAU)
		out.append(p)
		out.append(p + Vector2(cos(a), sin(a)) * rng.randf_range(2.0, 7.0))
	return out


static func _nz(x: float) -> float:
	## Smooth 1-D value noise in [-1, 1].
	var fl := floorf(x)
	var i := int(fl)
	var f := x - fl
	f = f * f * (3.0 - 2.0 * f)
	var a: float = _ntab[i & 255]
	var b: float = _ntab[(i + 1) & 255]
	return a + (b - a) * f


static func _rnd(i: int) -> float:
	## Deterministic pseudo-random value in [0, 1] for an integer.
	return _ntab[(i * 73 + 19) & 255] * 0.5 + 0.5


# =============================================================================
# Geometry helpers
# =============================================================================

static func _qb(a: Vector2, c: Vector2, b: Vector2, n: int = 12) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n + 1:
		var u := float(i) / float(n)
		out.append(a.lerp(c, u).lerp(c.lerp(b, u), u))
	return out


static func _cb(a: Vector2, c1: Vector2, c2: Vector2, b: Vector2, n: int = 16) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n + 1:
		out.append(a.bezier_interpolate(c1, c2, b, float(i) / float(n)))
	return out


static func _arcp(c: Vector2, rx: float, ry: float, a0: float, a1: float, n: int = 16) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n + 1:
		var a := lerpf(a0, a1, float(i) / float(n))
		out.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return out


static func _oval(c: Vector2, rx: float, ry: float, n: int = 24, rot: float = 0.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(c + Vector2(cos(a) * rx, sin(a) * ry).rotated(rot))
	return out


func _lumpy(c: Vector2, rx: float, ry: float, lump: float, n: int, sd: float, rot: float = 0.0, detail: float = 0.0) -> PackedVector2Array:
	## Closed organic outline; periodic so it closes without a seam.
	var probe := [&"l", c, rx, ry, lump, n, sd, rot, detail]
	var hit = _memo_get(probe)
	if hit != null:
		return (hit as PackedVector2Array).duplicate()
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		var k := 1.0 + lump * (0.55 * sin(2.0 * a + sd * 1.3) + 0.35 * sin(3.0 * a + sd * 2.7) + 0.25 * sin(5.0 * a + sd * 0.6))
		k += detail * (0.5 * sin(9.0 * a + sd * 3.1) + 0.3 * sin(14.0 * a + sd * 1.9))
		out.append(c + Vector2(cos(a) * rx * k, sin(a) * ry * k).rotated(rot))
	_memo_put(probe, out)
	return out


static func _rectp(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


static func _rrect(r: Rect2, rad: float, n: int = 4) -> PackedVector2Array:
	rad = minf(rad, minf(r.size.x, r.size.y) * 0.5)
	var out := PackedVector2Array()
	var cs := [Vector2(r.end.x - rad, r.position.y + rad), Vector2(r.end.x - rad, r.end.y - rad),
		Vector2(r.position.x + rad, r.end.y - rad), Vector2(r.position.x + rad, r.position.y + rad)]
	for k in 4:
		var c: Vector2 = cs[k]
		var a0 := -PI * 0.5 + PI * 0.5 * k
		for i in n + 1:
			var a := a0 + PI * 0.5 * float(i) / float(n)
			out.append(c + Vector2(cos(a), sin(a)) * rad)
	return out


static func _xpts(pts: PackedVector2Array, pos: Vector2, rot: float = 0.0, scl: float = 1.0) -> PackedVector2Array:
	return Transform2D(rot, Vector2(scl, scl), 0.0, pos) * pts


static func _plen(p: PackedVector2Array) -> float:
	var l := 0.0
	for i in range(1, p.size()):
		l += p[i].distance_to(p[i - 1])
	return l


static func _pat(p: PackedVector2Array, d: float) -> Vector2:
	## Point at arc length d along a polyline.
	if p.size() == 0:
		return Vector2.ZERO
	if d <= 0.0:
		return p[0]
	for i in range(1, p.size()):
		var sl := p[i].distance_to(p[i - 1])
		if d <= sl and sl > 0.0:
			return p[i - 1].lerp(p[i], d / sl)
		d -= sl
	return p[p.size() - 1]


static func _pdir(p: PackedVector2Array, d: float) -> Vector2:
	if p.size() < 2:
		return Vector2.RIGHT
	for i in range(1, p.size()):
		var sl := p[i].distance_to(p[i - 1])
		if d <= sl and sl > 0.0:
			return (p[i] - p[i - 1]) / sl
		d -= sl
	return (p[p.size() - 1] - p[p.size() - 2]).normalized()


static func _psub(p: PackedVector2Array, d0: float, d1: float) -> PackedVector2Array:
	## The part of a polyline between arc lengths d0 and d1.
	var out := PackedVector2Array()
	if p.size() < 2 or d1 <= d0:
		return out
	var acc := 0.0
	out.append(_pat(p, d0))
	for i in range(1, p.size()):
		acc += p[i].distance_to(p[i - 1])
		if acc > d0 and acc < d1:
			out.append(p[i])
	out.append(_pat(p, d1))
	return out


# =============================================================================
# Drawing primitives
# =============================================================================

func _push(t: Transform2D) -> void:
	_lxf = t
	_xform(_xf * _lxf)


func _pop() -> void:
	_lxf = Transform2D.IDENTITY
	_xform(_xf)


static func _rot_about(pivot: Vector2, ang: float, move: Vector2 = Vector2.ZERO) -> Transform2D:
	return Transform2D(ang, pivot + move) * Transform2D(0.0, -pivot)


# --- low-level wrappers: every draw goes to the current layer (_ci) ---------

func _xform(t: Transform2D) -> void:
	RenderingServer.canvas_item_add_set_transform(_ci, t)


func _pl(points: PackedVector2Array, col: Color, w: float = -1.0, _aa: bool = true) -> void:
	if points.size() >= 2 and col.a > 0.004:
		RenderingServer.canvas_item_add_polyline(_ci, points, PackedColorArray([col]), w, true)


func _plc(points: PackedVector2Array, colors: PackedColorArray, w: float = -1.0, _aa: bool = true) -> void:
	if points.size() >= 2 and colors.size() == points.size():
		RenderingServer.canvas_item_add_polyline(_ci, points, colors, w, true)


func _ml(points: PackedVector2Array, col: Color, w: float = -1.0, _aa: bool = true) -> void:
	if points.size() >= 2 and points.size() % 2 == 0 and col.a > 0.004:
		RenderingServer.canvas_item_add_multiline(_ci, points, PackedColorArray([col]), w, true)


func _ln(a: Vector2, b: Vector2, col: Color, w: float = -1.0, _aa: bool = true) -> void:
	if col.a > 0.004:
		RenderingServer.canvas_item_add_line(_ci, a, b, col, w, true)


func _cir(c: Vector2, r: float, col: Color, filled: bool = true, w: float = -1.0, _aa: bool = true) -> void:
	if r <= 0.05 or col.a <= 0.004:
		return
	if filled:
		RenderingServer.canvas_item_add_circle(_ci, c, r, col, true)
	else:
		_pl(_arcp(c, r, r, 0.0, TAU, clampi(int(r * 1.5), 12, 48)), col, w)


func _poly(points: PackedVector2Array, colors: PackedColorArray) -> void:
	if points.size() >= 3:
		RenderingServer.canvas_item_add_polygon(_ci, points, colors)


func _memo_get(probe: Array) -> Variant:
	## Cached result for these inputs, or null.  Entries are keyed by hash and
	## keep their own deep copy of the inputs, so callers mutating their arrays
	## later cannot corrupt the cache; cached arrays are never handed out as-is.
	var h := hash(probe)
	var e = _memo_now.get(h)
	if e == null:
		e = _memo_prev.get(h)
		if e == null:
			return null
		_memo_now[h] = e
	return e[1] if e[0] == probe else null


func _memo_put(probe: Array, value: Variant) -> void:
	var v = value
	if value is PackedVector2Array:
		v = (value as PackedVector2Array).duplicate()
	_memo_now[hash(probe)] = [probe.duplicate(true), v]


func _wob(pts: PackedVector2Array, closed: bool = false, amp: float = 0.8, step: float = 8.0) -> PackedVector2Array:
	## Hand-drawn wobble: subdivide and push points along the normal by smooth
	## noise.  Seeds come from a per-frame counter, so the wobble of a shape is
	## stable from frame to frame even while it moves.
	_seed += 1
	var n := pts.size()
	if n < 2 or amp <= 0.0:
		return pts.duplicate()
	var probe := [&"w", _seed, closed, amp, step, pts]
	var hit = _memo_get(probe)
	if hit != null:
		return (hit as PackedVector2Array).duplicate()
	var sd := float(_seed) * 17.31
	var out := PackedVector2Array()
	var segs := n if closed else n - 1
	var acc := 0.0
	for i in segs:
		var a := pts[i]
		var d := pts[(i + 1) % n] - a
		var l := d.length()
		if l < 0.01:
			continue
		var nr := Vector2(-d.y, d.x) / l
		var k := maxi(1, int(l / step))
		for j in k:
			var f := float(j) / float(k)
			var s := acc + l * f
			out.append(a + d * f + nr * ((_nz(sd + s * 0.11) * 0.55 + _nz(sd * 1.7 + s * 0.03)) * amp))
		acc += l
	if not closed:
		var d2 := (pts[n - 1] - pts[n - 2]).normalized()
		out.append(pts[n - 1] + Vector2(-d2.y, d2.x) * ((_nz(sd + acc * 0.11) * 0.55 + _nz(sd * 1.7 + acc * 0.03)) * amp))
	_memo_put(probe, out)
	return out


func _fill(pts: PackedVector2Array, col: Color) -> void:
	## Filled polygon that never errors: falls back to the convex hull, or skips.
	if col.a <= 0.004 or pts.size() < 3:
		return
	var probe := [&"t", pts]
	var tri = _memo_get(probe)
	if tri == null:
		var idx := Geometry2D.triangulate_polygon(pts)
		var used := pts.duplicate()
		if idx.is_empty():
			var hull := Geometry2D.convex_hull(pts)
			if hull.size() >= 4:
				hull.remove_at(hull.size() - 1)
				idx = Geometry2D.triangulate_polygon(hull)
				used = hull
		tri = [idx, used]
		_memo_put(probe, tri)
	var ix: PackedInt32Array = tri[0]
	if ix.is_empty():
		return
	RenderingServer.canvas_item_add_triangle_array(_ci, ix, tri[1], PackedColorArray([col]))


func _fill_convex_many(polys: Array, col: Color) -> void:
	## Many small convex (or star-shaped) polygons of one colour in one draw call.
	if col.a <= 0.004:
		return
	var pts := PackedVector2Array()
	var idx := PackedInt32Array()
	for poly in polys:
		var p: PackedVector2Array = poly
		var n := p.size()
		if n < 3:
			continue
		var c := Vector2.ZERO
		for q in p:
			c += q
		var base := pts.size()
		pts.append(c / float(n))
		pts.append_array(p)
		for i in n:
			idx.append(base)
			idx.append(base + 1 + i)
			idx.append(base + 1 + (i + 1) % n)
	if idx.size() >= 3:
		RenderingServer.canvas_item_add_triangle_array(_ci, idx, pts, PackedColorArray([col]))


func _outline_many(polys: Array, col: Color, w: float = 1.0) -> void:
	## Outlines of many closed polygons in a single draw call.
	var segs := PackedVector2Array()
	for poly in polys:
		var p: PackedVector2Array = poly
		for i in p.size():
			segs.append(p[i])
			segs.append(p[(i + 1) % p.size()])
	if segs.size() >= 2 and col.a > 0.004:
		_ml(segs, col, w, true)


func _stroke(pts: PackedVector2Array, col: Color = INK, w: float = 2.0, closed: bool = false, amp: float = 0.8) -> void:
	if pts.size() < 2:
		return
	var p := _wob(pts, closed, amp)
	if col.a <= 0.004 or p.size() < 2:
		return
	# (never append to p: it may be a cached array shared with later frames)
	_pl(p + PackedVector2Array([p[0]]) if closed else p, col, w, true)


func _shape(pts: PackedVector2Array, fill: Color, ink: Color = INK, w: float = 2.0, amp: float = 0.8) -> void:
	## Wash (slightly misregistered) under a wobbly ink outline.
	if pts.size() < 3:
		return
	var p := _wob(pts, true, amp)
	if p.size() < 3:
		return
	_fill(Transform2D(0.0, FOFF) * p, fill)
	if ink.a > 0.004 and w > 0.0:
		_pl(p + PackedVector2Array([p[0]]), ink, w, true)


func _line(a: Vector2, b: Vector2, col: Color = INK, w: float = 2.0, amp: float = 0.7) -> void:
	_stroke(PackedVector2Array([a, b]), col, w, false, amp)


func _circ(c: Vector2, r: float, fill: Color, ink: Color = INK, w: float = 1.8) -> void:
	if r <= 0.3:
		return
	var n := clampi(int(r * 1.2), 10, 40)
	_shape(_oval(c, r, r, n), fill, ink, w, minf(0.7, r * 0.06))


func _dot(c: Vector2, r: float, col: Color) -> void:
	if r > 0.05 and col.a > 0.004:
		_cir(c, r, col, true, -1.0, true)


func _discs(centers: PackedVector2Array, radii: PackedFloat32Array, col: Color) -> void:
	## Many soft round dots of one colour in a single draw call.
	if centers.is_empty() or col.a <= 0.004:
		return
	var tpl_cols := PackedColorArray()
	for a in _disc_alpha:
		tpl_cols.append(Color(col, col.a * a))
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	for i in centers.size():
		var r: float = radii[i]
		pts.append_array(Transform2D(0.0, Vector2(r, r), 0.0, centers[i]) * _disc_tpl)
		cols.append_array(tpl_cols)
	RenderingServer.canvas_item_add_triangle_array(_ci, PackedInt32Array(), pts, cols)


func _ring(c: Vector2, r: float, col: Color, w: float = 1.5) -> void:
	if r > 0.3 and col.a > 0.004:
		_pl(_arcp(c, r, r, 0.0, TAU, clampi(int(r * 1.5), 12, 48)), col, w)


func _dashed(pts: PackedVector2Array, col: Color, w: float = 1.5, dash: float = 6.0, gap: float = 4.0, phase: float = 0.0, closed: bool = false) -> void:
	if pts.size() < 2 or col.a <= 0.004:
		return
	var p := pts
	if closed:
		p = pts.duplicate()
		p.append(pts[0])
	var total := _plen(p)
	var period := dash + gap
	var segs := PackedVector2Array()
	var d := -fposmod(phase, period)
	while d < total:
		var a := maxf(d, 0.0)
		var b := minf(d + dash, total)
		if b > a + 0.3:
			var sub := _psub(p, a, b)
			for i in range(1, sub.size()):
				segs.append(sub[i - 1])
				segs.append(sub[i])
		d += period
	if segs.size() >= 2:
		_ml(segs, col, w, true)


func _glow(c: Vector2, r: float, col: Color, sy: float = 1.0) -> void:
	## Soft radial glow: one fan with per-vertex alpha.
	if r <= 0.5 or col.a <= 0.004:
		return
	var n := 24
	var pts := PackedVector2Array([c])
	var cols := PackedColorArray([col])
	var idx := PackedInt32Array()
	var clear := Color(col, 0.0)
	for i in n:
		var a := TAU * float(i) / float(n)
		pts.append(c + Vector2(cos(a) * r, sin(a) * r * sy))
		cols.append(clear)
		idx.append_array([0, 1 + i, 1 + (i + 1) % n])
	RenderingServer.canvas_item_add_triangle_array(_ci, idx, pts, cols)


func _grad(r: Rect2, top: Color, bottom: Color) -> void:
	_poly(_rectp(r), PackedColorArray([top, top, bottom, bottom]))


func _head(tip: Vector2, dir: Vector2, col: Color = INK, hs: float = 7.0) -> void:
	## Filled arrowhead pointing along dir.
	var d := dir.normalized()
	var s := Vector2(-d.y, d.x)
	_fill(PackedVector2Array([tip + d * 1.5, tip - d * hs + s * hs * 0.5, tip - d * hs * 0.72, tip - d * hs - s * hs * 0.5]), col)


func _arrow_path(pts: PackedVector2Array, col: Color = INK, w: float = 2.0, hs: float = 7.0, amp: float = 0.6) -> void:
	var n := pts.size()
	if n < 2:
		return
	var d := pts[n - 1] - pts[n - 2]
	if d.length() < 0.01:
		return
	# stop the shaft a little short so the tip stays sharp
	var shaft := _psub(pts, 0.0, maxf(_plen(pts) - hs * 0.6, 0.5))
	_stroke(shaft, col, w, false, amp)
	_head(pts[n - 1], d, col, hs)


func _arrow(a: Vector2, b: Vector2, col: Color = INK, w: float = 2.0, hs: float = 7.0, bend: float = 0.0) -> void:
	if a.distance_to(b) < 1.0:
		return
	if absf(bend) > 0.01:
		var m := (a + b) * 0.5 + (b - a).orthogonal().normalized() * bend
		_arrow_path(_qb(a, m, b, 14), col, w, hs)
	else:
		_arrow_path(PackedVector2Array([a, b]), col, w, hs)


func _flow_dots(pts: PackedVector2Array, spacing: float, phase: float, col: Color, r: float = 2.4) -> void:
	## Dots travelling along a path (they grow in and shrink out at its ends).
	var total := _plen(pts)
	if total < 1.0 or col.a <= 0.004:
		return
	var cs := PackedVector2Array()
	var rs := PackedFloat32Array()
	var d := fposmod(phase, spacing)
	var acc := 0.0
	for i in range(1, pts.size()):
		var sl := pts[i].distance_to(pts[i - 1])
		while d <= acc + sl and sl > 0.0:
			var k := _seg(d, 0.0, 10.0) * (1.0 - _seg(d, total - 10.0, total))
			if k > 0.05:
				cs.append(pts[i - 1].lerp(pts[i], (d - acc) / sl))
				rs.append(r * 1.15 * k)
			d += spacing
		acc += sl
	_discs(cs, rs, col)


func _font() -> Font:
	if _label_font == null:
		var path := "res://assets/fonts/journal_italic.woff2"
		if ResourceLoader.exists(path):
			_label_font = load(path) as Font
		if _label_font == null:
			_label_font = UITheme.font()
	return _label_font


func _text(pos: Vector2, txt: String, fs: int = 12, col: Color = INK, align: int = CENTER, halo: bool = true) -> void:
	## Crisp label: drawn unscaled at the final screen position and size.
	## `pos` is the anchor (centre / left / right edge) at the text's middle.
	if txt == "" or col.a <= 0.004:
		return
	var f := _font()
	var sz := maxi(6, int(round(float(fs) * _scale)))
	var p := _xf * (_lxf * pos)
	var tw := f.get_string_size(txt, LEFT, -1, sz).x
	var x := p.x
	if align == CENTER:
		x -= tw * 0.5
	elif align == RIGHT:
		x -= tw
	var base := Vector2(round(x), round(p.y + (f.get_ascent(sz) - f.get_descent(sz)) * 0.5))
	_xform(Transform2D.IDENTITY)
	if halo:
		f.draw_string_outline(_ci, base, txt, LEFT, -1, sz, maxi(2, int(round(4.0 * _scale))), Color(PAPER, 0.8 * col.a))
	f.draw_string(_ci, base, txt, LEFT, -1, sz, col)
	_xform(_xf * _lxf)


func _callout(txt: String, at: Vector2, target: Vector2, fs: int = 12, align: int = CENTER, col: Color = INK) -> void:
	## Label with a thin leader line to what it names.
	var f := _font()
	var half := f.get_string_size(txt, LEFT, -1, fs).x * 0.5
	var c := at
	if align == LEFT:
		c.x += half
	elif align == RIGHT:
		c.x -= half
	var d := target - c
	var box := Vector2(half + 4.0, float(fs) * 0.6 + 2.0)
	var k := 1.0
	if absf(d.x) > 0.01:
		k = minf(k, box.x / absf(d.x))
	if absf(d.y) > 0.01:
		k = minf(k, box.y / absf(d.y))
	var start := c + d * k
	if start.distance_to(target) > 6.0:
		_line(start, target - d.normalized() * 2.0, Color(col, 0.5 * col.a), 1.1, 0.5)
		_dot(target, 1.8, Color(col, 0.6 * col.a))
	_text(at, txt, fs, col, align)


func _vgrad(pts: PackedVector2Array, y0: float, y1: float, top: Color, bottom: Color) -> void:
	## Polygon filled with a vertical gradient (one call).
	if pts.size() < 3:
		return
	var cols := PackedColorArray()
	for p in pts:
		cols.append(top.lerp(bottom, clampf((p.y - y0) / maxf(y1 - y0, 0.01), 0.0, 1.0)))
	_poly(pts, cols)


func _panel(r: Rect2, top: Color, bottom: Color, frame: bool = true) -> PackedVector2Array:
	## A painted panel inside the card (rounded, vertical wash).  Returns its outline for clipping.
	var p := _rrect(r, 6.0, 3)
	_vgrad(p, r.position.y, r.end.y, top, bottom)
	if frame:
		_stroke(p, Color(INK, 0.35), 1.2, true, 0.3)
	return p


func _clip_shape(pts: PackedVector2Array, clip: PackedVector2Array, fill: Color, ink: Color = INK, w: float = 1.5, amp: float = 0.5) -> void:
	## Like _shape, but cut to the clip polygon (for things drifting out of a panel).
	var p := _wob(pts, true, amp)
	if p.size() < 3:
		return
	if fill.a > 0.004:
		for part in Geometry2D.intersect_polygons(Transform2D(0.0, FOFF) * p, clip):
			_fill(part, fill)
	if ink.a > 0.004 and w > 0.0:
		for piece in Geometry2D.intersect_polyline_with_polygon(p + PackedVector2Array([p[0]]), clip):
			if piece.size() >= 2:
				_pl(piece, ink, w, true)


# =============================================================================
# Reusable pictures
# =============================================================================

func _flame_pts(base: Vector2, w: float, h: float, sway: float, t: float, sd: float) -> PackedVector2Array:
	var r := w * 0.5
	var cy := base.y - r
	var hh := maxf(h - r, 1.0)
	var out := PackedVector2Array()
	var n := 9
	for i in n:
		var u := float(i) / float(n)
		var hw := r * pow(1.0 - u, 0.8) * (1.0 + 0.14 * sin(u * 9.0 - t * 11.0 + sd))
		out.append(Vector2(base.x + sway * u * u + hw, cy - hh * u))
	out.append(Vector2(base.x + sway, cy - hh))
	for i in range(n - 1, -1, -1):
		var u := float(i) / float(n)
		var hw := r * pow(1.0 - u, 0.8) * (1.0 + 0.14 * sin(u * 9.0 - t * 12.0 + sd + 2.1))
		out.append(Vector2(base.x + sway * u * u - hw, cy - hh * u))
	for i in range(1, 7):
		var a := PI - PI * float(i) / 7.0
		out.append(Vector2(base.x + cos(a) * r, cy + sin(a) * r))
	return out


func _flame(base: Vector2, w: float, h: float, sd: float = 0.0, a: float = 1.0, outline: bool = true) -> void:
	## A flickering flame standing on `base` (bottom centre): outer, inner and
	## core tongues as fans in a single draw call, plus a thin ink edge.
	if h < 2.0 or w < 1.0 or a <= 0.01:
		return
	var t := _t
	var hh := h * (1.0 + 0.11 * _nz(t * 4.3 + sd))
	var sway := w * 0.38 * _nz(t * 2.4 + sd * 1.7)
	var outer := _flame_pts(base, w, hh, sway, t, sd)
	var parts := [[outer, w, hh, sway, Color(EMBER, 0.88 * a)],
		[_flame_pts(base + Vector2(0, -0.5), w * 0.56, hh * 0.62, sway * 0.75, t + 0.4, sd + 5.0), w * 0.56, hh * 0.62, sway * 0.75, Color(FLAME, 0.95 * a)]]
	if w > 10.0:
		parts.append([_flame_pts(base + Vector2(0, -0.5), w * 0.26, hh * 0.32, sway * 0.5, t + 0.8, sd + 9.0), w * 0.26, hh * 0.32, sway * 0.5, Color(1.0, 0.95, 0.78, 0.9 * a)])
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	for part in parts:
		var ring: PackedVector2Array = part[0]
		var pw: float = part[1]
		var ph: float = part[2]
		var col: Color = part[4]
		var b0 := pts.size()
		pts.append(base + Vector2(float(part[3]) * 0.09, -pw * 0.5 - (ph - pw * 0.5) * 0.3))
		cols.append(col)
		var n := ring.size()
		for i in n:
			pts.append(ring[i])
			cols.append(col)
			idx.append(b0)
			idx.append(b0 + 1 + i)
			idx.append(b0 + 1 + (i + 1) % n)
	RenderingServer.canvas_item_add_triangle_array(_ci, idx, pts, cols)
	if outline and w >= 14.0:
		var o := outer.duplicate()
		o.append(outer[0])
		_pl(o, Color(INK, 0.55 * a), clampf(w * 0.06, 1.0, 1.6))


func _smoke(base: Vector2, height: float, col: Color, n: int = 6, sd: float = 0.0, spread: float = 12.0, r0: float = 3.0, r1: float = 11.0, speed: float = 0.22, drift: float = 6.0) -> void:
	## Puffs rising from base, growing and thinning out (one draw call).
	if col.a <= 0.004:
		return
	var cs := PackedVector2Array()
	var rs := PackedFloat32Array()
	for i in n:
		var ph := fposmod(_t * speed + float(i) / float(n) + sd * 0.137, 1.0)
		var k := sin(PI * pow(ph, 0.7))
		if k > 0.05:
			var x := base.x + _nz(sd + ph * 2.5 + float(i) * 7.3) * spread * (0.3 + ph) + drift * ph
			cs.append(Vector2(x, base.y - ph * height))
			rs.append(lerpf(r0, r1, ph) * (0.55 + 0.45 * k))
	_discs(cs, rs, Color(col, col.a * 0.8))


func _wisp(base: Vector2, height: float, col: Color, sd: float = 0.0, w: float = 1.6, speed: float = 1.0) -> void:
	## A curling line of steam/heat rising (fades at both ends).
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var n := 12
	for i in n + 1:
		var u := float(i) / float(n)
		var y := base.y - u * height
		var x := base.x + sin(u * 5.0 - _t * 3.0 * speed + sd) * (2.0 + u * 3.0)
		pts.append(Vector2(x, y))
		cols.append(Color(col, col.a * sin(PI * u)))
	_plc(pts, cols, w, true)


func _wisps(bases: PackedVector2Array, height: float, col: Color, sd0: float = 0.0, sd_step: float = 1.9, w: float = 1.6, speed: float = 1.0) -> void:
	## Several curling lines of steam/heat (fading at both ends) in one draw call.
	if bases.is_empty() or col.a <= 0.004:
		return
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var n := 10
	for k in bases.size():
		var b := bases[k]
		var sd := sd0 + float(k) * sd_step
		var prev := b
		for i in range(1, n + 1):
			var u := float(i) / float(n)
			var p := Vector2(b.x + sin(u * 5.0 - _t * 3.0 * speed + sd) * (2.0 + u * 3.0), b.y - u * height)
			if i == 1:
				prev = Vector2(b.x + sin(-_t * 3.0 * speed + sd) * 2.0, b.y)
			pts.append(prev)
			pts.append(p)
			cols.append(Color(col, col.a * sin(PI * (u - 0.5 / float(n)))))
			prev = p
	RenderingServer.canvas_item_add_multiline(_ci, pts, cols, w, true)


func _drop(c: Vector2, r: float, col: Color = WATER, ink: Color = INK, w: float = 1.2) -> void:
	## Water drop (round bottom at c, point up).
	if r <= 0.4:
		return
	var pts := PackedVector2Array()
	for i in 13:
		var a := lerpf(-PI * 0.18, PI * 1.18, float(i) / 12.0)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	pts.append(c + Vector2(0, -r * 2.3))
	_fill(pts, Color(col, 0.9 * col.a))
	if ink.a > 0.0:
		var o := pts.duplicate()
		o.append(pts[0])
		_pl(o, ink, w, true)
		_dot(c + Vector2(-r * 0.35, -r * 0.2), r * 0.22, Color(1, 1, 1, 0.6 * col.a))


func _cloud_pts(c: Vector2, w: float, h: float) -> PackedVector2Array:
	## Flat-bottomed cumulus outline made of bumps (shape cached per size).
	var key := Vector2(w, h)
	var shape: PackedVector2Array
	if _cloud_cache.has(key):
		shape = _cloud_cache[key]
	else:
		shape = PackedVector2Array()
		var bumps := [[-0.36, 0.42], [-0.08, 0.62], [0.2, 0.52], [0.40, 0.34]]
		var yb := h * 0.3
		shape.append(Vector2(w * 0.5, yb))
		shape.append(Vector2(-w * 0.5, yb))
		var prev := Vector2(-w * 0.5, yb)
		for bi in bumps.size():
			var b: Array = bumps[bi]
			var br: float = float(b[1]) * h
			var bc := Vector2(float(b[0]) * w, yb - br * 0.55)
			var a_start := atan2(prev.y - bc.y, prev.x - bc.x)
			if a_start > 0.0:
				a_start -= TAU
			var a_end := -0.15 if bi == bumps.size() - 1 else -PI * 0.25
			for i in range(1, 7):
				var a := lerpf(a_start, a_end, float(i) / 6.0)
				shape.append(bc + Vector2(cos(a), sin(a)) * br)
			prev = shape[shape.size() - 1]
		_cloud_cache[key] = shape
	return Transform2D(0.0, c) * shape


func _cloud(c: Vector2, w: float, h: float, fill: Color = Color(1, 1, 1, 0.85), ink: Color = INK2, lw: float = 1.5, shade: Color = Color(0, 0, 0, 0)) -> void:
	var p := _cloud_pts(c, w, h)
	_fill(Transform2D(0.0, FOFF) * p, fill)
	if shade.a > 0.004:
		_fill(_cloud_pts(c + Vector2(w * 0.04, h * 0.1), w * 0.8, h * 0.6), shade)
	if ink.a > 0.004:
		_pl(p + PackedVector2Array([p[0]]), ink, lw, true)


func _stone(c: Vector2, rx: float, ry: float, sd: float, fill: Color = Color(STONE, FILL_A), rot: float = 0.0, facets: int = 1) -> void:
	var n := 9
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n) + _rnd(int(sd * 13.0) + i) * 0.35
		var k := 0.82 + 0.3 * _rnd(int(sd * 7.0) + i * 3)
		pts.append(c + Vector2(cos(a) * rx * k, sin(a) * ry * k).rotated(rot))
	_shape(pts, fill, INK, 1.6, 0.5)
	for f in facets:
		var i0 := (int(sd) + f * 3) % n
		var p0 := pts[i0].lerp(c, 0.18)
		_line(p0, c.lerp(pts[(i0 + 4) % n], 0.35) , Color(INK, 0.4), 1.1, 0.3)


func _leaf(c: Vector2, length: float, width: float, rot: float, col: Color = LEAF, ink: Color = INK, w: float = 1.3) -> void:
	var pts := PackedVector2Array()
	var n := 7
	for i in n + 1:
		var u := float(i) / float(n)
		pts.append(Vector2(lerpf(-0.5, 0.5, u) * length, -sin(PI * u) * width * 0.5))
	for i in range(n - 1, 0, -1):
		var u := float(i) / float(n)
		pts.append(Vector2(lerpf(-0.5, 0.5, u) * length, sin(PI * u) * width * 0.5))
	pts = _xpts(pts, c, rot)
	_shape(pts, Color(col, 0.9 * col.a), ink, w, 0.25)
	_ln(c - Vector2(length * 0.45, 0).rotated(rot), c + Vector2(length * 0.4, 0).rotated(rot), Color(ink, 0.5), 1.0, true)


func _tuber(c: Vector2, s: float = 1.0, rot: float = -0.35) -> void:
	_shape(_lumpy(c, 12.0 * s, 7.5 * s, 0.10, 18, 2.0, rot), Color(TUBER, 0.9), INK, 1.5, 0.4)
	for k in 3:
		_dot(c + Vector2(-5.0 + 5.0 * k, -1.0 + 2.0 * (k % 2)).rotated(rot) * s, 0.9 * s, Color(INK, 0.6))
	var tip := c + Vector2(-12.0 * s, 0).rotated(rot)
	_line(tip, tip + Vector2(-4.0, 3.0) * s, INK2, 1.0, 0.2)
	var top := c + Vector2(11.0 * s, -1.0 * s).rotated(rot)
	_leaf(top + Vector2(3.0, -5.0) * s, 10.0 * s, 4.5 * s, -1.1, LEAF, INK, 1.0)
	_leaf(top + Vector2(6.0, -1.0) * s, 9.0 * s, 4.0 * s, -0.2, LEAF, INK, 1.0)


func _heart_pts(c: Vector2, s: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 28:
		var t := TAU * float(i) / 28.0
		var x := 16.0 * pow(sin(t), 3.0)
		var y := -(13.0 * cos(t) - 5.0 * cos(2.0 * t) - 2.0 * cos(3.0 * t) - cos(4.0 * t))
		pts.append(c + Vector2(x, y) * s)
	return pts


func _check(c: Vector2, s: float = 1.0, col: Color = GREEN, w: float = 3.0) -> void:
	_stroke(PackedVector2Array([c + Vector2(-7, 0) * s, c + Vector2(-2, 6) * s, c + Vector2(8, -7) * s]), col, w, false, 0.3)


func _cross(c: Vector2, s: float = 1.0, col: Color = RED, w: float = 3.0) -> void:
	_line(c + Vector2(-7, -7) * s, c + Vector2(7, 7) * s, col, w, 0.3)
	_line(c + Vector2(7, -7) * s, c + Vector2(-7, 7) * s, col, w, 0.3)


static func _clip_seg(a: Vector2, b: Vector2, r: Rect2) -> PackedVector2Array:
	var t0 := 0.0
	var t1 := 1.0
	var d := b - a
	var p := [-d.x, d.x, -d.y, d.y]
	var q := [a.x - r.position.x, r.end.x - a.x, a.y - r.position.y, r.end.y - a.y]
	for i in 4:
		var pi_: float = p[i]
		var qi: float = q[i]
		if absf(pi_) < 0.00001:
			if qi < 0.0:
				return PackedVector2Array()
		else:
			var tt := qi / pi_
			if pi_ < 0.0:
				t0 = maxf(t0, tt)
			else:
				t1 = minf(t1, tt)
	if t0 >= t1:
		return PackedVector2Array()
	return PackedVector2Array([a + d * t0, a + d * t1])


func _hatch_poly(poly: PackedVector2Array, spacing: float, col: Color, w: float = 1.0, slope: float = 1.0, key: String = "") -> void:
	## Hatching clipped to a polygon; cached by key when the polygon is static.
	var segs: PackedVector2Array
	if key != "" and _cache.has(key):
		segs = _cache[key]
	else:
		segs = PackedVector2Array()
		var bb := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			bb = bb.expand(p)
		var hgt := bb.size.y + 2.0
		var x := bb.position.x - hgt * absf(slope)
		while x < bb.end.x:
			var line := PackedVector2Array([Vector2(x, bb.end.y + 1.0), Vector2(x + hgt * slope, bb.position.y - 1.0)])
			for piece in Geometry2D.intersect_polyline_with_polygon(line, poly):
				if piece.size() >= 2:
					segs.append(piece[0])
					segs.append(piece[piece.size() - 1])
			x += spacing
		if key != "":
			_cache[key] = segs
	if segs.size() >= 2:
		_ml(segs, col, w, true)


func _stipple(r: Rect2, n: int, col: Color, sd: int = 0, size_px: float = 1.6) -> void:
	## Speckles in a rectangle (one draw call; short strokes read as dots).
	var segs := PackedVector2Array()
	for i in n:
		var p := r.position + Vector2(_rnd(sd + i * 2) * r.size.x, _rnd(sd + i * 2 + 101) * r.size.y)
		segs.append(p)
		segs.append(p + Vector2(size_px, size_px * 0.3))
	_ml(segs, col, size_px, true)


func _tufts(pts: PackedVector2Array, col: Color, s: float = 1.0, w: float = 1.2) -> void:
	## Little grass tufts (three blades each) at the given points; one call.
	var segs := PackedVector2Array()
	for i in pts.size():
		var p := pts[i]
		var k := 0.8 + 0.4 * _rnd(i * 5)
		for b in 3:
			var dx := (float(b) - 1.0) * 3.0 * s
			segs.append(p + Vector2(dx * 0.3, 0))
			segs.append(p + Vector2(dx, -6.0 * s * k * (1.0 - absf(float(b) - 1.0) * 0.3)))
	if segs.size() >= 2:
		_ml(segs, col, w, true)


func _sun(c: Vector2, r: float, a: float = 1.0, animated: bool = true) -> void:
	## Sun with rays (the rays turn slowly unless drawn into a static layer).
	_glow(c, r * 2.6, Color(FLAME, 0.35 * a))
	var segs := PackedVector2Array()
	var tt := _t if animated else 0.0
	for i in 10:
		var ang := TAU * float(i) / 10.0 + tt * 0.15
		var r1 := r + 9.0 + 2.0 * sin(tt * 2.0 + i)
		segs.append(c + Vector2(cos(ang), sin(ang)) * (r + 4.0))
		segs.append(c + Vector2(cos(ang), sin(ang)) * r1)
	_ml(segs, Color(EMBER, 0.8 * a), 1.8, true)
	_circ(c, r, Color(FLAME, 0.95 * a), Color(INK, 0.7 * a), 1.6)


func _thermo_tube(bulb: Vector2, hgt: float) -> void:
	_fill(_rrect(Rect2(bulb.x - 4.5, bulb.y - hgt, 9.0, hgt), 4.5), Color(1, 1, 1, 0.55))


func _thermo_level(bulb: Vector2, hgt: float, frac: float, col: Color) -> void:
	var lvl := lerpf(bulb.y - 6.0, bulb.y - hgt + 4.0, clampf(frac, 0.0, 1.0))
	_fill(_rectp(Rect2(bulb.x - 2.2, lvl, 4.4, bulb.y - lvl)), col)
	_circ(bulb + Vector2(0, 5), 8.0, Color(col, 1.0), INK, 1.6)


func _thermo_frame(bulb: Vector2, hgt: float, ticks: int = 4) -> void:
	var top := bulb.y - hgt
	_stroke(_rrect(Rect2(bulb.x - 4.5, top, 9.0, hgt), 4.5), INK, 1.6, true, 0.3)
	var segs := PackedVector2Array()
	for i in ticks + 1:
		var y := lerpf(bulb.y - 6.0, top + 4.0, float(i) / float(ticks))
		segs.append(Vector2(bulb.x + 5.5, y))
		segs.append(Vector2(bulb.x + 9.5, y))
	_ml(segs, INK2, 1.2, true)


# =============================================================================
# Diagrams
# =============================================================================

# --- 1. island ---------------------------------------------------------------

func _d_island() -> void:
	var t := _t
	var fr := Rect2(14, 14, 452, 242)
	var pc := Vector2(318, 168)
	if _layer(2, false):
		_fill(_rectp(fr), Color(SKY, 0.30))
	# clouds drifting far below the island (they pass beneath it)
	_layer(3, true)
	for i in 5:
		var cw: float = [70.0, 56.0, 80.0, 60.0, 50.0][i]
		var cy: float = [34.0, 244.0, 52.0, 228.0, 136.0][i]
		var cx := fr.position.x + fposmod(30.0 + i * 97.0 + t * (5.0 + i), fr.size.x + 120.0) - 60.0
		var hw := cw * 0.5 + 2.0
		var a := _seg(cx, fr.position.x + hw, fr.position.x + hw + 30.0) * (1.0 - _seg(cx, fr.end.x - hw - 30.0, fr.end.x - hw))
		if a > 0.01:
			_cloud(Vector2(cx, cy), cw, cw * 0.42, Color(1, 1, 1, 0.8 * a), Color(INK, 0.35 * a), 1.3)
	if _layer(4, false):
		var ctr := Vector2(240, 134)
		var rx := 160.0
		var ry := 94.0
		var isl := _lumpy(ctr, rx, ry, 0.06, 80, 1.7, 0.0, 0.012)
		# underside shadow (it floats)
		_fill(_xpts(isl, Vector2(5, 10)), Color(0.28, 0.33, 0.42, 0.28))
		_shape(isl, GRASS, INK, 2.4, 0.6)
		# cliff hachures around the rim, grass tufts
		var segs := PackedVector2Array()
		var tuft_pts := PackedVector2Array()
		for i in isl.size():
			var p := isl[i]
			var g := Vector2((p.x - ctr.x) / (rx * rx), (p.y - ctr.y) / (ry * ry)).normalized()
			var l := 4.0 + 4.0 * _rnd(i * 3)
			segs.append(p + g * 1.5)
			segs.append(p + g * (1.5 + l))
		for k in 46:
			var a := TAU * _rnd(k * 7 + 3)
			var rr := 0.25 + 0.68 * sqrt(_rnd(k * 11 + 5))
			tuft_pts.append(ctr + Vector2(cos(a) * (rx - 10.0) * rr, sin(a) * (ry - 10.0) * rr))
		_ml(segs, Color(INK, 0.55), 1.2, true)
		_tufts(tuft_pts, Color(0.33, 0.45, 0.22, 0.7), 0.8, 1.1)
		# pond with its clay bank
		_shape(_lumpy(pc + Vector2(7, 7), 44.0, 27.0, 0.08, 30, 3.3), Color(CLAY, 0.8), Color(INK, 0.5), 1.3, 0.5)
		_stipple(Rect2(pc.x + 4, pc.y + 18, 40, 12), 14, Color(INK, 0.35), 3)
		_shape(_lumpy(pc, 37.0, 21.0, 0.1, 30, 4.1), Color(WATER, 0.82), INK, 2.0, 0.5)
	# ripples
	_layer(5, true)
	for k in 2:
		var rc := pc + Vector2(-14.0 + 26.0 * k, -4.0 + 9.0 * k)
		for j in 2:
			var ph := fposmod(t / 3.2 + k * 0.37 + j * 0.5, 1.0)
			var rr := 2.0 + 11.0 * ph
			_pl(_arcp(rc, rr, rr * 0.5, 0.0, TAU, 20), Color(1, 1, 1, 0.75 * (1.0 - ph)), 1.2)
	if not _layer(6, false):
		return
	# rocky outcrop
	var rocks := [[Vector2(344, 80), 15.0, 11.0], [Vector2(366, 72), 11.0, 8.0], [Vector2(370, 91), 12.0, 9.0],
		[Vector2(350, 99), 9.0, 7.0], [Vector2(326, 92), 8.0, 6.0]]
	for i in rocks.size():
		var r: Array = rocks[i]
		_stone(r[0], r[1], r[2], 3.0 + i * 2.0, Color(STONE, 0.92))
	# flat work stone + a few flakes
	var ws := _rrect(Rect2(-21, -12, 42, 24), 7.0, 3)
	_shape(_rot_ptsc(ws, Vector2(152, 172), -0.12), Color(STONE.lerp(PAPER, 0.3), 0.95), INK, 1.8, 0.5)
	for k in 3:
		var fp := Vector2(180 + k * 6, 182 - k * 5)
		_fill(PackedVector2Array([fp, fp + Vector2(4, -2), fp + Vector2(2, 3)]), Color(INK, 0.5))
	# berry bushes
	for b in [[Vector2(118, 104), 16.0, 1.0], [Vector2(98, 134), 13.0, 2.0], [Vector2(132, 132), 11.0, 3.0]]:
		var bc: Vector2 = b[0]
		var br: float = b[1]
		_shape(_lumpy(bc, br, br * 0.9, 0.08, 20, float(b[2]), 0.0, 0.04), Color(0.38, 0.52, 0.27, 0.95), INK, 1.6, 0.4)
		for k in 4:
			_dot(bc + Vector2(cos(k * 1.9 + b[2]), sin(k * 1.9 + b[2])) * br * 0.5, 2.3, BERRY)
	# great tree (canopy from above)
	var tc := Vector2(228, 110)
	var canopy := _lumpy(tc, 40.0, 35.0, 0.07, 44, 5.0, 0.0, 0.07)
	_fill(_xpts(canopy, Vector2(6, 7)), Color(0.2, 0.25, 0.15, 0.22))
	_shape(canopy, Color(0.36, 0.50, 0.25, 0.95), INK, 2.0, 0.5)
	for k in 6:
		var a := TAU * k / 6.0 + 0.4
		var p := tc + Vector2(cos(a) * 21.0, sin(a) * 18.0)
		_stroke(_arcp(p, 7.0, 6.0, PI * 1.1, PI * 1.9, 6), Color(INK, 0.35), 1.1, false, 0.2)
	for k in 5:
		var a := TAU * k / 5.0 + 0.9
		_line(tc, tc + Vector2(cos(a), sin(a)) * 14.0, Color(WOOD.darkened(0.3), 0.7), 1.6, 0.3)
	_circ(tc, 5.0, Color(WOOD, 1.0), INK, 1.5)
	# mossy log with mushrooms
	var lc := Vector2(240, 194)
	var lr := -0.14
	_shape(_rot_ptsc(_rrect(Rect2(-32, -7, 64, 14), 6.0, 3), lc, lr), Color(WOOD, 0.95), INK, 1.8, 0.4)
	_circ(lc + Vector2(31, 0).rotated(lr), 6.0, Color(STRAW, 1.0), INK, 1.3)
	_ring(lc + Vector2(31, 0).rotated(lr), 2.6, Color(INK, 0.5), 1.0)
	for k in 3:
		_fill(_lumpy(lc + Vector2(-20.0 + 15.0 * k, -4.0).rotated(lr), 7.0, 3.0, 0.2, 10, float(k)), Color(LEAF, 0.95))
	for k in 3:
		var mp := lc + Vector2(-16.0 + 13.0 * k, 10.0).rotated(lr)
		_circ(mp, 3.0, Color(0.93, 0.80, 0.62, 1.0), INK, 1.1)
		_dot(mp, 1.0, Color(FIRED, 0.9))
	# labels
	_text(Vector2(228, 158), "great tree", 13)
	_text(pc + Vector2(-2, -1), "pond", 12, PAPER, CENTER, false)
	_callout("clay", Vector2(404, 190), pc + Vector2(34, 22), 12)
	_text(Vector2(350, 120), "rocks", 12)
	_text(Vector2(152, 196), "work stone", 12)
	_text(Vector2(112, 80), "berries", 12)
	_text(Vector2(240, 216), "mossy log", 12)
	_callout("cliff edge", Vector2(50, 222), Vector2(122, 200), 12)
	_text(Vector2(430, 244), "abyss", 12, INK2)
	# north arrow
	_arrow(Vector2(446, 60), Vector2(446, 36), INK, 1.6, 6.0)
	_text(Vector2(446, 26), "N", 11)


func _rot_ptsc(pts: PackedVector2Array, c: Vector2, rot: float) -> PackedVector2Array:
	## Rotate points (defined around the origin) by rot and move them to c.
	return Transform2D(rot, c) * pts


# --- 2. vitals ---------------------------------------------------------------

func _d_vitals() -> void:
	var names := ["Hunger", "Thirst", "Stamina", "Health", "Warmth"]
	var caps := ["eat", "drink", "rest", "bandage", "fire"]
	var cols := [Color(0.82, 0.58, 0.26), WATER, Color(0.52, 0.64, 0.32), Color(0.78, 0.30, 0.24), EMBER]
	var top := 48.0
	var bot := 184.0
	var bw := 26.0
	if _layer(2, false):
		for i in 5:
			var x := 56.0 + 92.0 * i
			var r := Rect2(x - bw * 0.5, top, bw, bot - top)
			_text(Vector2(x, 26), names[i], 14)
			_text(Vector2(x, 248), caps[i], 12, INK2)
			_fill(_rrect(r, 8.0), Color(1, 1, 1, 0.35))
			var ticks := PackedVector2Array()
			for k in range(1, 4):
				var ty := lerpf(r.end.y, r.position.y, k * 0.25)
				ticks.append(Vector2(r.position.x - 6.0, ty))
				ticks.append(Vector2(r.position.x - 1.5, ty))
			_ml(ticks, INK2, 1.2, true)
	# the levels drain, then refill when the thing below is used
	_layer(3, true)
	var bounce := PackedFloat32Array()
	for i in 5:
		var x := 56.0 + 92.0 * i
		var lt := fposmod(_t + 0.6 + i * 1.17, 6.0)
		var lvl: float
		if lt < 4.2:
			lvl = lerpf(0.9, 0.24, lt / 4.2)
		elif lt < 5.1:
			lvl = lerpf(0.24, 0.9, _eo((lt - 4.2) / 0.9))
		else:
			lvl = 0.9
		var col: Color = cols[i]
		var inner := Rect2(x - bw * 0.5, top, bw, bot - top).grow(-3.5)
		var ly := lerpf(inner.end.y, inner.position.y, lvl)
		var fill := PackedVector2Array([Vector2(inner.position.x, ly)])
		fill.append_array(_arcp(Vector2(inner.position.x + 5.0, inner.end.y - 5.0), 5.0, 5.0, PI, PI * 0.5, 4))
		fill.append_array(_arcp(Vector2(inner.end.x - 5.0, inner.end.y - 5.0), 5.0, 5.0, PI * 0.5, 0.0, 4))
		fill.append(Vector2(inner.end.x, ly))
		_fill(fill, Color(col, 0.9))
		_ln(Vector2(inner.position.x + 1.0, ly), Vector2(inner.end.x - 1.0, ly), Color(col.darkened(0.35), 0.9), 1.4)
		if lvl < 0.36:
			_pl(_rrect(Rect2(x - bw * 0.5 - 1.5, top - 1.5, bw + 3.0, bot - top + 3.0), 9.0), Color(RED, 0.4 + 0.4 * sin(_t * 9.0)), 2.0)
		bounce.append(1.0 + 0.28 * sin(PI * _seg(lt, 4.2, 4.65)))
		var fl := _seg(lt, 4.2, 5.2)
		if fl > 0.0 and fl < 1.0:
			_text(Vector2(x + 22.0, lerpf(196.0, ly + 12.0, _eo(fl))), "+", 16, Color(GREEN, sin(PI * fl)))
	_flame(Vector2(56.0 + 92.0 * 4, 227), 15.0 * bounce[4], 26.0 * bounce[4], 3.0)
	if _layer(4, false):
		for i in 5:
			_stroke(_rrect(Rect2(56.0 + 92.0 * i - bw * 0.5, top, bw, bot - top), 8.0), INK, 2.0, true, 0.6)
	# what refills each bar (bounces when used)
	for i in 4:
		var ic := Vector2(56.0 + 92.0 * i, 216)
		_layer_fx(5 + i, Transform2D(0.0, Vector2(bounce[i], bounce[i]), 0.0, ic) * Transform2D(0.0, -ic))
		if _layer(5 + i, false):
			match i:
				0:
					_tuber(ic, 0.95)
				1:
					_drop(ic + Vector2(0, 5), 8.0)
				2:
					_moon(ic + Vector2(-3, 1), 10.0)
					_text(ic + Vector2(10, -9), "z", 12, INK)
					_text(ic + Vector2(16, -15), "z", 9, INK2)
				3:
					_shape(_heart_pts(ic + Vector2(0, -1), 0.62), Color(RED, 0.9), INK, 1.5, 0.3)
					_leaf(ic + Vector2(1, 1), 22.0, 7.0, -0.7, Color(0.55, 0.68, 0.36), INK, 1.1)


func _moon(c: Vector2, r: float) -> void:
	var pts := PackedVector2Array()
	for i in 13:
		var a := lerpf(PI * 0.5 - 1.2, -PI * 1.5 + 1.2, float(i) / 12.0)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	var ic := c + Vector2(r * 0.55, -r * 0.2)
	var ir := r * 0.82
	var p_end := pts[pts.size() - 1]
	var p_start := pts[0]
	var a0 := atan2(p_end.y - ic.y, p_end.x - ic.x)
	var a1 := atan2(p_start.y - ic.y, p_start.x - ic.x)
	if a1 < a0:
		a1 += TAU
	for i in range(1, 10):
		pts.append(ic + Vector2(cos(lerpf(a0, a1, i / 10.0)), sin(lerpf(a0, a1, i / 10.0))) * ir)
	_shape(pts, Color(0.97, 0.88, 0.55, 0.95), INK, 1.4, 0.2)


# --- 7. knap -----------------------------------------------------------------

func _d_knap() -> void:
	var P := 4.8
	var lt := fposmod(_t, P)
	var ground := 232.0
	var t_hit := 1.32
	var strike := Vector2(283, 146)
	var piv := Vector2(410, 145)
	var arm := 125.0
	var a_up := deg_to_rad(236.0)
	var a_hit := deg_to_rad(190.0)
	if _layer(2, false):
		_line(Vector2(22, ground), Vector2(458, ground), INK2, 1.6)
		_stipple(Rect2(24, ground + 3, 432, 18), 40, Color(INK, 0.22), 7)
		var anvil := PackedVector2Array([Vector2(116, ground), Vector2(122, 212), Vector2(140, 200), Vector2(200, 196),
			Vector2(300, 197), Vector2(344, 202), Vector2(362, 216), Vector2(366, ground)])
		_shape(anvil, Color(STONE.darkened(0.05), 0.9))
		_line(Vector2(150, 214), Vector2(190, 210), Color(INK, 0.35), 1.1)
		_line(Vector2(300, 216), Vector2(338, 222), Color(INK, 0.35), 1.1)
	# core: left part + right face (outer before the strike, scar after)
	_layer(3, true)
	var left := PackedVector2Array([Vector2(232, 199), Vector2(178, 198), Vector2(165, 187), Vector2(163, 171), Vector2(172, 158),
		Vector2(194, 149), Vector2(236, 145), Vector2(272, 145)])
	var outer := PackedVector2Array([Vector2(283, 146), Vector2(291, 152), Vector2(297, 165), Vector2(299, 180), Vector2(294, 192)])
	var scar := PackedVector2Array([Vector2(280, 149), Vector2(285, 160), Vector2(288, 173), Vector2(289, 185), Vector2(294, 192)])
	var hit := lt >= t_hit
	var heal := _seg(lt, P - 0.35, P)
	var core := left.duplicate()
	core.append_array(scar if hit else outer)
	core.append(Vector2(288, 198))
	_shape(core, Color(0.50, 0.52, 0.55, 0.92))
	_line(Vector2(200, 160), Vector2(222, 182), Color(INK, 0.3), 1.1)
	_line(Vector2(240, 155), Vector2(252, 176), Color(INK, 0.3), 1.1)
	if hit:
		_stroke(PackedVector2Array([Vector2(282, 154), Vector2(286, 170), Vector2(287, 184)]), Color(INK, 0.35), 1.0, false, 0.3)
	# strike guide: dashed line along the blow, near the edge; the swing's arc
	if _layer(4, false):
		var blow := Vector2(-0.174, 0.985)
		_dashed(PackedVector2Array([strike - blow * 92.0, strike + blow * 14.0]), Color(RED, 0.7), 1.5, 6.0, 4.0)
		_stroke(_arcp(strike, 16.0, 16.0, PI + 0.0, PI + 1.39, 8), Color(RED, 0.6), 1.2, false, 0.2)
		_dashed(_arcp(piv, arm, arm, a_hit + 0.05, a_up + 0.1, 20), Color(INK, 0.2), 1.2, 4.0, 5.0)
		_text(Vector2(436, 112), "hammerstone", 13)
		_text(Vector2(140, 170), "core", 13)
		_text(Vector2(160, 250), "anvil stone", 12)
		_text(Vector2(228, 98), "strike near the edge", 12, RED.darkened(0.2))
	# flake + chips
	_layer(5, true)
	var flake := outer.duplicate()
	for i in range(scar.size() - 2, -1, -1):
		flake.append(scar[i])
	var fc := Vector2(290, 168)
	if hit:
		var ft := lt - t_hit
		var land := 0.6
		var tt := minf(ft, land)
		var pos := fc + Vector2(150.0, -60.0) * tt + Vector2(0, 500.0) * 0.5 * tt * tt
		var rot := (PI * 0.5) * (tt / land)
		if ft > land:
			pos.x += 10.0 * _eo((ft - land) / 0.3)
		pos.y = minf(pos.y, ground - 4.0)
		var fa := 1.0 - _seg(lt, P - 0.8, P - 0.35)
		_push(Transform2D(rot, pos) * Transform2D(0.0, -fc))
		_shape(flake, Color(0.58, 0.60, 0.62, fa), Color(INK, fa), 1.5, 0.3)
		_pop()
		var chips: Array = []
		for k in 5:
			var v := Vector2(60.0 + 40.0 * _rnd(k * 3), -140.0 + 90.0 * _rnd(k * 5 + 1))
			var ct := minf(ft, 0.9)
			var cp := strike + Vector2(4, 2) + v * ct + Vector2(0, 600.0) * 0.5 * ct * ct
			cp.y = minf(cp.y, ground - 1.5)
			var s := 2.0 + 1.5 * _rnd(k * 7)
			chips.append(_xpts(PackedVector2Array([Vector2(-s, -s * 0.5), Vector2(s, -s * 0.2), Vector2(0, s * 0.8)]), cp, ct * (6.0 + k)))
		_fill_convex_many(chips, Color(INK, 0.75 * fa))
		# impact flash
		var fl := _seg(lt, t_hit, t_hit + 0.3)
		if fl < 1.0:
			var segs := PackedVector2Array()
			for k in 7:
				var a := -PI * 0.1 - PI * 0.8 * k / 6.0 + 0.2
				var d := Vector2(cos(a), sin(a))
				segs.append(strike + d * (6.0 + 8.0 * fl))
				segs.append(strike + d * (12.0 + 14.0 * fl))
			_ml(segs, Color(EMBER, 1.0 - fl), 2.0, true)
		_text(Vector2(424, 206), "flake", 13, Color(INK, _seg(lt, t_hit + 0.5, t_hit + 0.8) * fa))
	if heal > 0.0:
		_shape(flake, Color(0.50, 0.52, 0.55, 0.92 * heal), Color(INK, heal), 2.0)
	# hammerstone in a fist, swinging on an arc around the (unseen) elbow
	var ang: float
	if lt < 0.45:
		ang = a_up
	elif lt < 1.05:
		ang = lerpf(a_up, a_up + 0.14, _ss(_seg(lt, 0.45, 1.05)))
	elif lt < t_hit:
		ang = lerpf(a_up + 0.14, a_hit, _ei(_seg(lt, 1.05, t_hit)))
	elif lt < 1.62:
		ang = lerpf(a_hit, a_hit + 0.16, _eo(_seg(lt, t_hit, 1.62)))
	elif lt < 2.9:
		ang = a_hit + 0.16
	else:
		ang = lerpf(a_hit + 0.16, a_up, _ss(_seg(lt, 2.9, 3.9)))
	var hc := piv + Vector2(cos(ang), sin(ang)) * arm
	if lt > 1.05 and lt < t_hit + 0.08:
		for k in 3:
			var back := ang + 0.07 * (k + 1)
			_pl(_arcp(piv, arm - 8.0 + k * 8.0, arm - 8.0 + k * 8.0, back, back + 0.18, 6), Color(INK, 0.45), 1.3)
	# local frame: x along the stone (towards the hand), y towards the elbow
	_push(Transform2D(ang + PI * 0.5, hc))
	_shape(_lumpy(Vector2.ZERO, 23.0, 15.0, 0.08, 18, 7.0), Color(0.66, 0.60, 0.50, 0.95), INK, 2.0, 0.4)
	_line(Vector2(-4, 6), Vector2(3, -5), Color(INK, 0.3), 1.1)
	_shape(PackedVector2Array([Vector2(2, 12), Vector2(18, 12), Vector2(20, 74), Vector2(2, 74)]), Color(WATER.lerp(PAPER, 0.4), 0.97), INK, 1.6, 0.3)
	_shape(PackedVector2Array([Vector2(-1, -15), Vector2(6, -18), Vector2(15, -17), Vector2(20, -10), Vector2(20, 12), Vector2(12, 15),
		Vector2(1, 13), Vector2(-3, 0)]), Color(0.92, 0.78, 0.62, 1.0), INK, 1.6, 0.3)
	_ml(PackedVector2Array([Vector2(3, -16), Vector2(3, -6), Vector2(8.5, -16), Vector2(8.5, -6), Vector2(14, -16), Vector2(14, -6)]), Color(INK, 0.5), 1.0, true)
	_pop()


# --- 15. fire_triangle -------------------------------------------------------

func _d_fire_triangle() -> void:
	var P := 4.0
	var which := int(fposmod(_t, P * 3.0) / P)
	var lt := fposmod(_t, P)
	var gone := _ss(_seg(lt, 1.2, 1.9)) * (1.0 - _ss(_seg(lt, 3.0, 3.6)))
	var corners := [Vector2(240, 46), Vector2(128, 206), Vector2(352, 206)]
	var names := ["Air", "Fuel", "Heat"]
	# sides: the two touching the removed corner fade
	for s in 3:
		var touches := s == which or (s + 1) % 3 == which
		_layer_fx(2 + s, Transform2D.IDENTITY, Color(1, 1, 1, 1.0 - 0.8 * gone if touches else 1.0))
		if _layer(2 + s, false):
			var a: Vector2 = corners[s]
			var b: Vector2 = corners[(s + 1) % 3]
			_line(a + (b - a).normalized() * 26.0, b - (b - a).normalized() * 26.0, INK, 3.0, 0.9)
	# flame in the middle
	_layer(5, true)
	var fire := 1.0 - gone
	var base := Vector2(240, 176)
	_glow(base + Vector2(0, -20), 60.0, Color(FLAME, 0.35 * fire))
	_flame(base, 34.0 * (0.25 + 0.75 * fire), 66.0 * (0.12 + 0.88 * fire), 1.0, clampf(fire * 1.4, 0.0, 1.0))
	_smoke(base + Vector2(0, -16), 70.0, Color(SMOKE_B, 0.6 * gone), 5, 2.0, 8.0, 3.0, 10.0, 0.3)
	if _layer(6, false):
		_line(base + Vector2(-26, 6), base + Vector2(22, -2), WOOD.darkened(0.2), 5.0, 0.5)
		_line(base + Vector2(-22, -2), base + Vector2(26, 6), WOOD.darkened(0.1), 5.0, 0.5)
	# corners: the removed one slides away and greys out
	for c in 3:
		var p: Vector2 = corners[c]
		var off := gone if c == which else 0.0
		var dirv := (p - Vector2(240, 150)).normalized()
		_layer_fx(7 + c, Transform2D(0.0, dirv * 16.0 * off), Color(1, 1, 1, 1.0 - 0.6 * off))
		if _layer(7 + c, false):
			var tint: Color = [SKY, WOOD, EMBER][c]
			_circ(p, 23.0, Color(tint.lerp(PAPER, 0.45), 1.0), INK, 2.0)
			match c:
				0:
					for k in 3:
						var y := p.y - 7.0 + 7.0 * k
						var x0 := p.x - 13.0 + 3.0 * k
						var sw := PackedVector2Array()
						for j in 9:
							var u := float(j) / 8.0
							sw.append(Vector2(x0 + 22.0 * u, y + sin(u * 6.0 + k) * 1.8))
						_stroke(sw, INK, 1.6, false, 0.2)
				1:
					_line(p + Vector2(-13, 6), p + Vector2(13, -3), WOOD.darkened(0.35), 5.0, 0.3)
					_line(p + Vector2(-13, -3), p + Vector2(13, 6), WOOD.darkened(0.15), 5.0, 0.3)
					_ring(p + Vector2(13, -3), 2.5, Color(INK, 0.6), 1.0)
				2:
					for k in 3:
						var sw := PackedVector2Array()
						for j in 9:
							var u := float(j) / 8.0
							sw.append(Vector2(p.x - 8.0 + 8.0 * k + sin(u * 6.0 + k) * 2.0, p.y + 11.0 - 22.0 * u))
						_stroke(sw, RED.darkened(0.1), 1.8, false, 0.2)
			var lp: Vector2 = [p + Vector2(42, 0), p + Vector2(0, 36), p + Vector2(0, 36)][c]
			_text(lp, names[c], 15)
	_layer(10, true)
	if gone > 0.05:
		var p: Vector2 = corners[which]
		_cross(p + (p - Vector2(240, 150)).normalized() * 16.0 * gone, 1.4, Color(RED, gone), 3.0)
	var msg: String = ["no air", "no fuel", "no heat"][which]
	_text(Vector2(240, 250), msg + " - the fire dies", 13, Color(RED.darkened(0.15), _seg(gone, 0.5, 1.0)))
	_text(Vector2(240, 250), "all three together", 13, Color(INK, 0.65 * (1.0 - _seg(gone, 0.0, 0.4))))


# --- 3. economy --------------------------------------------------------------

func _d_economy() -> void:
	var c1 := Vector2(140, 142)
	var c2 := Vector2(336, 142)
	var rx := 98.0
	var ry := 84.0
	var ang1 := [0.0, -60.0, -120.0, -180.0, -240.0, -300.0]   # soil plants food you scraps compost
	var ang2 := [180.0, 252.0, 324.0, 396.0, 468.0]             # soil tree wood fire ash
	if not _cache.has("eco"):
		var arcs: Array = []
		for i in 6:
			var a0: float = ang1[i]
			var g0 := 21.0 if i == 0 else 14.0
			var g1 := 21.0 if i == 5 else 14.0
			arcs.append(_arcp(c1, rx, ry, deg_to_rad(a0 - g0), deg_to_rad(a0 - 60.0 + g1), 12))
		for i in 5:
			var a0: float = ang2[i]
			var g0 := 21.0 if i == 0 else 14.0
			var g1 := 21.0 if i == 4 else 14.0
			arcs.append(_arcp(c2, rx, ry, deg_to_rad(a0 + g0), deg_to_rad(a0 + 72.0 - g1), 12))
		_cache["eco"] = arcs
	var arcs: Array = _cache["eco"]
	var fire_p := c2 + Vector2(cos(deg_to_rad(396.0)) * rx, sin(deg_to_rad(396.0)) * ry)
	var comp_p := c1 + Vector2(cos(deg_to_rad(-300.0)) * rx, sin(deg_to_rad(-300.0)) * ry)
	var ash_p := c2 + Vector2(cos(deg_to_rad(468.0)) * rx, sin(deg_to_rad(468.0)) * ry)
	if _layer(2, false):
		for pts in arcs:
			_arrow_path(pts, Color(INK, 0.6), 1.6, 7.0)
	# things flowing round the loops
	_layer(3, true)
	var flow := _t * 15.0
	for i in arcs.size():
		_flow_dots(arcs[i], 19.0, flow + i * 6.0, Color(GREEN, 0.95) if i < 6 else Color(EMBER, 0.95), 2.2)
	if _layer(4, false):
		var names1 := ["soil", "plants", "food", "you", "scraps", "compost"]
		var names2 := ["soil", "tree", "wood", "fire", "ash"]
		for i in range(1, 6):
			var a := deg_to_rad(float(ang1[i]))
			var p := c1 + Vector2(cos(a) * rx, sin(a) * ry)
			match i:
				1: _ico_sprout(p)
				2: _ico_food(p)
				3: _ico_person(p)
				4: _ico_scraps(p)
				5: _ico_compost(p)
			_text(p + (c1 - p).normalized() * 30.0, names1[i], 12)
		for i in range(1, 5):
			var a := deg_to_rad(float(ang2[i]))
			var p := c2 + Vector2(cos(a) * rx, sin(a) * ry)
			match i:
				1: _ico_tree(p)
				2: _ico_log(p)
				3: _ico_fire(p)
				4: _ico_ash(p)
			_text(p + (c2 - p).normalized() * 30.0, names2[i], 12)
		# the shared soil node
		var sp := Vector2(238, 142)
		_shape(_arcp(sp + Vector2(0, 10), 27.0, 22.0, PI, TAU, 14), Color(EARTH, 0.95), INK, 1.8, 0.4)
		_stipple(Rect2(sp + Vector2(-18, 2), Vector2(36, 6)), 8, Color(PAPER, 0.45), 13)
		_text(sp + Vector2(0, -1), "soil", 13, PAPER, CENTER, false)
		_text(Vector2(240, 24), "nothing from nothing", 13, INK2)
	# the living bits: flame, steam, a last wisp off the ash
	_layer(5, true)
	_flame(fire_p + Vector2(0, 10), 15.0, 27.0, 7.0)
	_wisp(comp_p + Vector2(5, -9), 14.0, Color(INK, 0.45), 1.0, 1.3)
	_wisp(ash_p + Vector2(-3, -4), 13.0, Color(INK, 0.3), 2.0, 0.8)


func _ico_sprout(c: Vector2) -> void:
	_line(c + Vector2(-13, 12), c + Vector2(13, 12), EARTH, 2.4, 0.3)
	_stroke(_qb(c + Vector2(0, 12), c + Vector2(-2, 2), c + Vector2(1, -9), 6), LEAF.darkened(0.3), 2.0, false, 0.2)
	_leaf(c + Vector2(-6, -5), 13.0, 6.0, 0.5, LEAF, INK, 1.1)
	_leaf(c + Vector2(7, -9), 13.0, 6.0, -0.5, LEAF, INK, 1.1)


func _ico_food(c: Vector2) -> void:
	_tuber(c + Vector2(-3, 3), 0.85)
	_circ(c + Vector2(11, 9), 3.6, Color(BERRY, 1.0), INK, 1.1)
	_circ(c + Vector2(16, 4), 3.4, Color(BERRY, 1.0), INK, 1.1)


func _ico_person(c: Vector2) -> void:
	var sh := PackedVector2Array([c + Vector2(-13, 15), c + Vector2(-11, 5), c + Vector2(-5, 1), c + Vector2(5, 1),
		c + Vector2(11, 5), c + Vector2(13, 15)])
	_shape(sh, Color(WATER.lerp(PAPER, 0.35), 0.95), INK, 1.6, 0.4)
	_circ(c + Vector2(0, -8), 7.5, Color(0.92, 0.80, 0.66, 1.0), INK, 1.6)


func _ico_scraps(c: Vector2) -> void:
	var peel := PackedVector2Array()
	for i in 12:
		var a := float(i) * 0.6
		var r := 3.0 + float(i) * 0.75
		peel.append(c + Vector2(-4, 2) + Vector2(cos(a) * r, sin(a) * r * 0.65))
	_stroke(peel, Color(TUBER, 0.95), 3.2, false, 0.2)
	_leaf(c + Vector2(9, -4), 12.0, 5.0, -0.9, Color(LEAF, 0.9), INK, 1.0)
	_dot(c + Vector2(10, 8), 1.8, INK)
	_dot(c + Vector2(14, 6), 1.6, INK)


func _ico_compost(c: Vector2) -> void:
	var b := c + Vector2(0, 11)
	_shape(_arcp(b, 19.0, 19.0, PI, TAU, 12), Color(EARTH, 0.95), INK, 1.6, 0.4)
	_stroke(_arcp(b, 13.0, 13.0, PI + 0.25, TAU - 0.25, 8), Color(LEAF, 1.0), 2.4, false, 0.3)
	_stroke(_arcp(b, 7.0, 7.0, PI + 0.3, TAU - 0.3, 6), Color(STRAW, 1.0), 2.4, false, 0.3)


func _ico_tree(c: Vector2) -> void:
	_shape(_rectp(Rect2(c + Vector2(-3, 1), Vector2(6, 15))), Color(WOOD, 1.0), INK, 1.4, 0.3)
	_shape(_lumpy(c + Vector2(0, -6), 16.0, 13.0, 0.1, 22, 3.0, 0.0, 0.07), Color(LEAF, 0.95), INK, 1.6, 0.4)


func _ico_log(c: Vector2) -> void:
	var r := -0.3
	_shape(_rot_ptsc(_rrect(Rect2(-16, -6, 32, 12), 5.0, 3), c, r), Color(WOOD, 0.95), INK, 1.6, 0.4)
	var e := c + Vector2(16, 0).rotated(r)
	_circ(e, 5.5, Color(STRAW, 1.0), INK, 1.3)
	_ring(e, 2.4, Color(INK, 0.5), 1.0)


func _ico_fire(c: Vector2) -> void:
	_line(c + Vector2(-13, 13), c + Vector2(11, 7), WOOD.darkened(0.25), 4.0, 0.3)
	_line(c + Vector2(-11, 7), c + Vector2(13, 13), WOOD.darkened(0.1), 4.0, 0.3)


func _ico_ash(c: Vector2) -> void:
	_shape(_arcp(c + Vector2(0, 11), 18.0, 13.0, PI, TAU, 12), Color(ASH, 0.95), INK, 1.6, 0.4)
	_stipple(Rect2(c + Vector2(-12, 3), Vector2(24, 6)), 8, Color(INK, 0.4), 17, 1.4)


# --- 4. water_cycle ----------------------------------------------------------

func _d_water_cycle() -> void:
	var t := _t
	var basin := _cb(Vector2(40, 199), Vector2(62, 240), Vector2(176, 242), Vector2(204, 199), 14)
	if _layer(2, false):
		_grad(Rect2(10, 10, 460, 180), Color(SKY, 0.5), Color(SKY, 0.05))
		var soil := _water_ground(basin)
		soil.append(Vector2(468, 260))
		soil.append(Vector2(12, 260))
		_fill(soil, Color(EARTH, 0.55))
		_stipple(Rect2(16, 206, 448, 50), 60, Color(INK, 0.25), 31)
	# wet patch under the rain
	_layer(3, true)
	var wet := 0.65 + 0.15 * sin(t * 1.3)
	_fill(_lumpy(Vector2(372, 212), 62.0, 22.0, 0.12, 22, 2.0), Color(SOIL, 0.35 * wet))
	if _layer(4, false):
		var water := basin.duplicate()
		water[0] = Vector2(41, 201)
		water[water.size() - 1] = Vector2(203, 201)
		_fill(water, Color(WATER, 0.85))
		_stroke(_water_ground(basin), INK, 2.0, false, 0.5)
		_line(Vector2(42, 201), Vector2(202, 201), Color(INK, 0.6), 1.4, 0.3)
		_tufts(PackedVector2Array([Vector2(24, 195), Vector2(226, 195), Vector2(300, 189), Vector2(452, 177)]), Color(LEAF.darkened(0.2), 0.9), 1.0, 1.2)
		_sun(Vector2(62, 52), 15.0, 1.0, false)
	_layer(5, true)
	for k in 3:
		var ph := fposmod(t * 0.4 + k / 3.0, 1.0)
		var rr := 6.0 + 20.0 * ph
		_pl(_arcp(Vector2(90.0 + k * 40.0, 207), rr, rr * 0.25, 0.0, TAU, 16), Color(1, 1, 1, 0.55 * (1.0 - ph)), 1.1)
	# evaporation
	for k in 4:
		var x := 72.0 + k * 34.0
		var ph := fposmod(t * 0.35 + k * 0.27, 1.0)
		var base := Vector2(x + ph * 10.0, 196.0 - ph * 70.0)
		_wisp(base, 34.0, Color(WATER.lightened(0.15), 0.9 * sin(PI * ph)), k * 1.7, 1.6, 0.8)
	var evap := _qb(Vector2(150, 140), Vector2(200, 54), Vector2(292, 64), 16)
	_dashed(evap, Color(WATER.darkened(0.25), 0.9), 1.8, 7.0, 5.0, -t * 14.0)
	_head(evap[evap.size() - 1], evap[evap.size() - 1] - evap[evap.size() - 2], Color(WATER.darkened(0.25), 0.9), 8.0)
	# rain (falls from behind the cloud)
	var rain := PackedVector2Array()
	var splash := PackedVector2Array()
	for i in 22:
		var x := 316.0 + 108.0 * _rnd(i * 3 + 1)
		var gy := 186.0 - (x - 330.0) * 0.085
		var ph := fposmod(t * 0.9 + _rnd(i * 5 + 2), 1.0)
		var y := lerpf(96.0, gy, ph)
		rain.append(Vector2(x, y - 7.0))
		rain.append(Vector2(x - 1.0, y))
		if ph > 0.9:
			var sp := (ph - 0.9) * 10.0
			splash.append(Vector2(x - 1.0, gy - 1.0))
			splash.append(Vector2(x - 4.0 - 2.0 * sp, gy - 3.0 - 2.0 * sp))
			splash.append(Vector2(x - 1.0, gy - 1.0))
			splash.append(Vector2(x + 2.0 + 2.0 * sp, gy - 3.0 - 2.0 * sp))
	_ml(rain, Color(WATER.darkened(0.2), 0.9), 1.6, true)
	_ml(splash, Color(WATER.darkened(0.2), 0.8), 1.1, true)
	var run := PackedVector2Array([Vector2(330, 178), Vector2(280, 183), Vector2(232, 189), Vector2(212, 193)])
	if _layer(6, false):
		_cloud(Vector2(372, 66), 150.0, 62.0, Color(0.97, 0.97, 0.97, 0.95), INK, 1.7, Color(SMOKE_B, 0.4))
		_arrow_path(run, Color(WATER.darkened(0.3), 0.9), 1.8, 7.0)
		_text(Vector2(178, 78), "evaporation", 12)
		_text(Vector2(445, 136), "rain", 13)
		_text(Vector2(420, 244), "soaks in", 12)
		_text(Vector2(276, 170), "runoff", 12)
		_text(Vector2(122, 222), "pond", 12, PAPER, CENTER, false)
	# soaking in, and running back to the pond over and through the soil
	_layer(7, true)
	for k in 3:
		var x := 344.0 + k * 30.0
		var gy := 190.0 - (x - 330.0) * 0.085
		_dashed(PackedVector2Array([Vector2(x, gy + 4.0), Vector2(x, gy + 34.0)]), Color(WATER.darkened(0.35), 0.95), 1.8, 4.0, 3.0, -t * 10.0)
		_head(Vector2(x, gy + 40.0), Vector2.DOWN, Color(WATER.darkened(0.35), 0.95), 6.0)
	_flow_dots(run, 16.0, t * 22.0, Color(WATER.darkened(0.1), 1.0), 2.0)
	var seep := _qb(Vector2(352, 236), Vector2(280, 250), Vector2(206, 226), 12)
	_dashed(seep, Color(WATER.darkened(0.3), 0.6), 1.5, 5.0, 4.0, -t * 10.0)
	_head(seep[seep.size() - 1], seep[seep.size() - 1] - seep[seep.size() - 2], Color(WATER.darkened(0.3), 0.6), 6.0)


func _water_ground(basin: PackedVector2Array) -> PackedVector2Array:
	## Ground line of the water-cycle scene: land sloping down to a pond basin.
	var ground := PackedVector2Array([Vector2(12, 195), Vector2(28, 197)])
	ground.append_array(basin)
	ground.append_array(PackedVector2Array([Vector2(214, 196), Vector2(260, 192), Vector2(330, 186), Vector2(400, 180), Vector2(468, 176)]))
	return ground


# --- 5. temperature ----------------------------------------------------------

func _d_temperature() -> void:
	var t := _t
	var P := 7.0
	var lt := fposmod(t, P)
	# 0..1: how much the warm side is "in focus" (the thermometer follows)
	var warm := _ss(_seg(lt, 2.8, 3.8)) * (1.0 - _ss(_seg(lt, 6.2, 7.0)))
	var lp := Rect2(14, 14, 206, 242)
	var rp := Rect2(260, 14, 206, 242)
	var gy := 230.0
	var fire := Vector2(398, gy - 2.0)
	var feet := Vector2(118, gy)
	var tb := Vector2(240, 210)
	if _layer(2, false):
		_panel(lp, Color(0.26, 0.34, 0.52, 0.42), Color(0.36, 0.46, 0.62, 0.22), false)
		_panel(rp, Color(FLAME, 0.20), Color(EMBER, 0.22), false)
		_line(Vector2(lp.position.x, gy), Vector2(lp.end.x, gy), INK2, 1.6)
		_line(Vector2(rp.position.x, gy), Vector2(rp.end.x, gy), INK2, 1.6)
		_moon(Vector2(42, 40), 9.0)
		_text(Vector2(66, 246), "wind + rain", 12, Color(INK, 0.9))
	# --- cold side: night, wind and rain
	_layer(3, true)
	var stars := PackedVector2Array()
	var sr := PackedFloat32Array()
	for k in 5:
		stars.append(Vector2(70.0 + k * 31.0, 30.0 + 9.0 * _rnd(k * 9)))
		sr.append(1.0 + 0.6 * (0.5 + 0.5 * sin(t * 2.0 + k)))
	_discs(stars, sr, Color(1, 1, 1, 0.9))
	var rain := PackedVector2Array()
	for i in 26:
		var x0 := lp.position.x + 230.0 * _rnd(i * 7 + 3) - 20.0
		var ph := fposmod(t * 1.1 + _rnd(i * 11), 1.0)
		var y := lerpf(50.0, gy - 2.0, ph)
		var x := x0 + ph * 26.0
		if x > lp.position.x + 2.0 and x < lp.end.x - 4.0:
			rain.append(Vector2(x - 2.5, y - 8.0))
			rain.append(Vector2(x, y))
	_ml(rain, Color(0.30, 0.42, 0.60, 0.75), 1.4, true)
	for k in 3:
		var y := 92.0 + k * 46.0
		var ph := fposmod(t * 0.45 + k * 0.33, 1.0)
		var x0 := lerpf(lp.position.x - 30.0, lp.end.x - 70.0, ph)
		var keep := PackedVector2Array()
		for j in 10:
			var u := float(j) / 9.0
			var p := Vector2(x0 + u * 64.0, y + sin(u * 7.0 + t * 4.0 + k) * 3.0)
			if p.x > lp.position.x + 3.0 and p.x < lp.end.x - 3.0:
				keep.append(p)
		if keep.size() >= 2:
			var wc := Color(0.22, 0.36, 0.60, 0.9 * sin(PI * ph))
			_pl(keep, wc, 2.0)
			_head(keep[keep.size() - 1], keep[keep.size() - 1] - keep[keep.size() - 2], wc, 7.0)
	# a shivering figure (the whole body trembles)
	_layer_fx(4, Transform2D(0.0, Vector2(sin(t * 47.0) * 0.9, 0.0)))
	if _layer(4, false):
		_figure_cold_body(feet)
	_layer(5, true)
	var neck := feet + Vector2(2, -73)
	var sh := 0.55 + 0.45 * sin(t * 9.0)
	var marks := PackedVector2Array()
	for s in [-1.0, 1.0]:
		for k in 2:
			var arc := _arcp(neck + Vector2(s * (17.0 + k * 5.0), 12.0), 3.0, 6.0, -PI * 0.4 if s > 0 else PI * 0.6, PI * 0.4 if s > 0 else PI * 1.4, 5)
			for i in range(1, arc.size()):
				marks.append_array([arc[i - 1], arc[i]])
	_ml(marks, Color(INK, 0.6 * sh), 1.3, true)
	var bp := fposmod(t * 0.5, 1.0)
	_discs(PackedVector2Array([neck + Vector2(16, -8) + Vector2(bp * 16.0, -bp * 6.0)]), PackedFloat32Array([2.0 + bp * 5.0]), Color(1, 1, 1, 0.7 * (1.0 - bp)))
	_glow(fire + Vector2(0, -24), 92.0, Color(FLAME, 0.38 + 0.06 * sin(t * 5.0)))
	# --- warm side: wall + roof + fire
	if _layer(6, false):
		var roof := PackedVector2Array([Vector2(262, 112), Vector2(364, 50), Vector2(464, 108), Vector2(456, 114), Vector2(364, 62), Vector2(270, 120)])
		_shape(roof, Color(STRAW, 0.95), INK, 2.0, 0.5)
		var thatch := PackedVector2Array()
		for k in 14:
			var u := (float(k) + 0.5) / 14.0
			var a: Vector2
			if u < 0.5:
				a = Vector2(266, 114).lerp(Vector2(364, 56), u * 2.0)
			else:
				a = Vector2(364, 56).lerp(Vector2(460, 111), u * 2.0 - 1.0)
			thatch.append(a + Vector2(0, -3))
			thatch.append(a + Vector2(-2.0 if u < 0.5 else 2.0, 5))
		_ml(thatch, Color(INK, 0.4), 1.0, true)
		_wattle(Rect2(262, 116, 18, gy - 116.0))
		_line(fire + Vector2(-20, 2), fire + Vector2(18, -4), WOOD.darkened(0.25), 5.0, 0.4)
		_line(fire + Vector2(-18, -4), fire + Vector2(20, 2), WOOD.darkened(0.1), 5.0, 0.4)
		_figure_warm(Vector2(330, gy))
		_text(Vector2(362, 36), "shelter", 12)
		_text(Vector2(430, 246), "fire", 12)
		_thermo_tube(tb, 160.0)
	_layer(7, true)
	_flame(fire, 26.0, 46.0, 4.0)
	_wisps(PackedVector2Array([fire + Vector2(-14, -56), fire + Vector2(0, -56), fire + Vector2(14, -56)]), 34.0, Color(EMBER, 0.65), 0.0, 2.0, 1.6, 1.2)
	# veil on the side that is not in focus
	_fill(_rrect(lp, 6.0, 3), Color(PAPER, 0.25 * warm))
	_fill(_rrect(rp, 6.0, 3), Color(PAPER, 0.25 * (1.0 - warm)))
	# thermometer between: the body's temperature
	var frac := lerpf(0.16, 0.86, warm)
	_thermo_level(tb, 160.0, frac, Color(0.30, 0.45, 0.70).lerp(RED, warm))
	_text(Vector2(240, 38), "warm", 12, Color(INK, 0.5 + 0.5 * warm))
	_text(Vector2(240, 238), "cold", 12, Color(INK, 1.0 - 0.5 * warm))
	var ay := lerpf(210.0 - 6.0, 50.0 + 4.0, frac)
	if warm > 0.5:
		_arrow(Vector2(249, ay), Vector2(258, ay), Color(RED, (warm - 0.5) * 2.0), 2.0, 6.0)
	else:
		_arrow(Vector2(231, ay), Vector2(222, ay), Color(0.25, 0.4, 0.65, (0.5 - warm) * 2.0), 2.0, 6.0)
	if _layer(8, false):
		_thermo_frame(tb, 160.0, 4)


func _figure_cold_body(feet: Vector2) -> void:
	## Standing, hunched, arms wrapped round: cold.
	var hip := feet + Vector2(0, -40)
	var neck := hip + Vector2(2, -33)
	_stroke(PackedVector2Array([feet + Vector2(-7, 0), hip + Vector2(-3, 2)]), INK, 2.6, false, 0.4)
	_stroke(PackedVector2Array([feet + Vector2(6, 0), hip + Vector2(3, 2)]), INK, 2.6, false, 0.4)
	var body := PackedVector2Array([neck + Vector2(-9, 1), neck + Vector2(9, 1), hip + Vector2(11, 5), hip + Vector2(-11, 5)])
	_shape(body, Color(STRAW.lerp(SKY, 0.45), 0.95), INK, 1.8, 0.4)
	_circ(neck + Vector2(3, -9), 9.0, Color(0.82, 0.84, 0.88, 1.0), INK, 1.8)
	_stroke(PackedVector2Array([neck + Vector2(-8, 3), neck + Vector2(-6, 16), neck + Vector2(8, 13)]), INK, 2.4, false, 0.3)
	_stroke(PackedVector2Array([neck + Vector2(8, 3), neck + Vector2(5, 17), neck + Vector2(-7, 15)]), INK, 2.4, false, 0.3)


func _figure_warm(feet: Vector2) -> void:
	## Sitting on a log, hands held out to the fire: warm.
	var seat := feet + Vector2(-12, -14)
	_shape(_rrect(Rect2(seat.x - 20.0, seat.y, 36.0, 13.0), 5.0, 3), Color(WOOD, 0.95), INK, 1.6, 0.4)
	_circ(Vector2(seat.x + 16.0, seat.y + 6.5), 5.0, Color(STRAW, 1.0), INK, 1.2)
	var hip := seat + Vector2(0, -2)
	var knee := hip + Vector2(22, -6)
	_stroke(PackedVector2Array([hip, knee, knee + Vector2(3, 22)]), INK, 2.6, false, 0.3)
	var neck := hip + Vector2(-2, -31)
	var body := PackedVector2Array([neck + Vector2(-8, 1), neck + Vector2(8, 1), hip + Vector2(9, 2), hip + Vector2(-10, 2)])
	_shape(body, Color(EMBER.lerp(PAPER, 0.45), 0.95), INK, 1.8, 0.4)
	_circ(neck + Vector2(2, -10), 9.0, Color(0.93, 0.79, 0.64, 1.0), INK, 1.8)
	var hand := neck + Vector2(31, 9)
	_stroke(PackedVector2Array([neck + Vector2(4, 4), neck + Vector2(17, 9), hand]), INK, 2.4, false, 0.3)
	_dot(hand + Vector2(2, 0), 2.6, Color(0.93, 0.79, 0.64))
	_ring(hand + Vector2(2, 0), 2.6, INK, 1.2)


func _wattle(r: Rect2) -> void:
	## Woven wall seen from the side: stakes with withies passing in front and behind.
	_fill(_rectp(r), Color(WOOD.darkened(0.25), 0.5))
	var stakes := 3
	var xs := PackedFloat32Array()
	for k in stakes:
		xs.append(lerpf(r.position.x + 3.0, r.end.x - 3.0, float(k) / float(stakes - 1)))
	var stake_col := Color(WOOD.darkened(0.35), 1.0)
	for k in stakes:
		_line(Vector2(xs[k], r.position.y - 4.0), Vector2(xs[k], r.end.y), stake_col, 3.0, 0.3)
	var rows := int(r.size.y / 7.0)
	var front := PackedVector2Array()
	for j in rows:
		var y := r.position.y + 4.0 + float(j) * (r.size.y - 6.0) / float(rows)
		var pts := PackedVector2Array()
		for i in 7:
			var u := float(i) / 6.0
			pts.append(Vector2(lerpf(r.position.x - 1.0, r.end.x + 1.0, u), y + sin(u * PI * 2.0 + float(j) * PI) * 1.6))
		_stroke(pts, Color(STRAW.darkened(0.15), 1.0), 3.6, false, 0.2)
		_stroke(pts, Color(INK, 0.35), 0.8, false, 0.2)
		for k in stakes:
			if (j + k) % 2 == 0:
				front.append(Vector2(xs[k], y - 3.0))
				front.append(Vector2(xs[k], y + 3.0))
	if front.size() >= 2:
		_ml(front, stake_col, 3.0, true)
	_stroke(_rectp(r), Color(INK, 0.8), 1.4, true, 0.4)


# --- 6. abyss ----------------------------------------------------------------

func _d_abyss() -> void:
	var t := _t
	var P := 5.6
	var lt := fposmod(t, P)
	var panel := Rect2(12, 12, 456, 246)
	var clip := _rrect(panel, 6.0, 3)
	var edge := Vector2(214, 101)
	if _layer(2, false):
		_panel(panel, Color(SKY, 0.45), Color(0.38, 0.46, 0.60, 0.55))
	# far cloud bank (behind the falling item)
	_layer(3, true)
	for i in 5:
		var x := fposmod(30.0 + i * 110.0 - t * 4.0, 560.0) - 40.0
		_clip_shape(_cloud_pts(Vector2(x, 214.0 + 6.0 * (i % 2)), 100.0, 40.0), clip, Color(0.93, 0.94, 0.96, 0.8), Color(INK, 0.25), 1.2, 0.0)
	# island in profile, the cliff edge at x ~ 214
	if _layer(4, false):
		var top := PackedVector2Array([Vector2(12, 104), Vector2(40, 101), Vector2(80, 103), Vector2(120, 100), Vector2(160, 102), Vector2(196, 100), Vector2(214, 101)])
		var face := PackedVector2Array([Vector2(218, 110), Vector2(212, 132), Vector2(200, 156), Vector2(182, 178), Vector2(156, 198),
			Vector2(124, 214), Vector2(90, 226), Vector2(52, 234), Vector2(12, 238)])
		var isl := top.duplicate()
		isl.append_array(face)
		_shape(isl, Color(EARTH, 0.92), INK, 2.2, 0.6)
		var grass := top.duplicate()
		for i in range(top.size() - 1, -1, -1):
			grass.append(top[i] + Vector2(-2.0 if i == top.size() - 1 else 0.0, 9.0))
		_fill(grass, Color(GRASS, 0.95))
		_stroke(top, INK, 2.2, false, 0.5)
		_tufts(PackedVector2Array([Vector2(30, 101), Vector2(70, 102), Vector2(104, 100), Vector2(140, 101), Vector2(182, 100)]), Color(LEAF.darkened(0.3), 0.9), 1.0, 1.2)
		for k in 4:
			var y := 128.0 + k * 22.0
			var x1 := 200.0 - k * 26.0
			_stroke(PackedVector2Array([Vector2(16, y + 4.0), Vector2(x1 * 0.5, y - 2.0), Vector2(x1, y + 2.0)]), Color(INK, 0.28), 1.1, false, 0.8)
		_stone(Vector2(60, 150), 9.0, 6.0, 2.0, Color(STONE, 0.9))
		_stone(Vector2(150, 136), 7.0, 5.0, 5.0, Color(STONE, 0.9))
		_stone(Vector2(110, 190), 8.0, 5.5, 8.0, Color(STONE, 0.9))
		# hanging roots
		for k in 4:
			var rp: Vector2 = [Vector2(190, 172), Vector2(150, 202), Vector2(112, 219), Vector2(70, 231)][k]
			var l := 16.0 + 8.0 * _rnd(k)
			_stroke(_qb(rp, rp + Vector2(2.0, l * 0.5), rp + Vector2(-2.0 + 2.0 * _rnd(k + 5), l), 6), Color(WOOD.darkened(0.35), 0.9), 1.4, false, 0.3)
		# the path things take over the edge
		var traj := PackedVector2Array()
		for k in 14:
			var tau := float(k) * 0.2
			var tp := edge + Vector2(6.0 + 34.0 * tau, -5.0 + 35.0 * tau * tau)
			if tp.y > 250.0:
				break
			traj.append(tp)
		_dashed(traj, Color(INK, 0.3), 1.2, 4.0, 5.0)
	# the item: slides to the edge, tips over and tumbles away into the clouds
	_layer(5, true)
	var pos := Vector2.ZERO
	var rot := 0.0
	var scl := 1.0
	var alpha := 1.0
	if lt < 0.5:
		pos = Vector2(150, 90)
		alpha = _seg(lt, 0.0, 0.5)
	elif lt < 1.5:
		var u := _ei(_seg(lt, 0.5, 1.5)) * 0.85 + _seg(lt, 0.5, 1.5) * 0.15
		pos = Vector2(lerpf(150.0, 208.0, u), 90.0)
		rot = sin(u * 12.0) * 0.05
	elif lt < 1.9:
		var u := _seg(lt, 1.5, 1.9)
		rot = u * 0.9
		pos = edge + Vector2(-6.0 + 12.0 * u, -11.0 + 6.0 * u * u)
	else:
		var tau := lt - 1.9
		pos = edge + Vector2(6.0 + 34.0 * tau, -5.0 + 0.5 * 70.0 * tau * tau)
		rot = 0.9 + tau * 2.4
		scl = lerpf(1.0, 0.55, _seg(tau, 0.0, 2.6))
		alpha = 1.0 - _seg(pos.y, 180.0, 232.0)
	if alpha > 0.01:
		if lt > 1.9:
			for k in 2:
				var sx := (-5.0 + 10.0 * k) * scl
				_line(pos + Vector2(sx, -15.0 * scl), pos + Vector2(sx, -15.0 * scl - 9.0), Color(INK, 0.35 * alpha), 1.1, 0.2)
		_push(Transform2D(rot, Vector2(scl, scl), 0.0, pos))
		_shape(_POT, Color(FIRED, 0.95 * alpha), Color(INK, alpha), 1.8, 0.3)
		_stroke(PackedVector2Array([Vector2(-8, -2), Vector2(8, -2)]), Color(INK, 0.5 * alpha), 1.1, false, 0.2)
		_pop()
	# near cloud bank (in front)
	for i in 4:
		var x := fposmod(80.0 + i * 150.0 - t * 7.0, 600.0) - 60.0
		_clip_shape(_cloud_pts(Vector2(x, 250.0 - 6.0 * (i % 2)), 160.0, 52.0), clip, Color(0.98, 0.98, 0.98, 0.95), Color(INK, 0.35), 1.4, 0.0)
	if _layer(6, false):
		_callout("cliff edge", Vector2(276, 84), edge + Vector2(2, 2), 12)
		_text(Vector2(364, 182), "lost forever", 14, RED.darkened(0.15))


# --- 8. knap_shapes ----------------------------------------------------------

func _d_knap_shapes() -> void:
	if not _cache.has("ks"):
		_cache["ks"] = [_knap_geo(_blade_outline(), 0, 13.0), _knap_geo(_axe_outline(), 1, 15.0), _knap_geo(_dig_outline(), 2, 15.0)]
	var geos: Array = _cache["ks"]
	var centers := [Vector2(84, 116), Vector2(240, 112), Vector2(396, 112)]
	if _layer(2, false):
		var names := ["blade", "axe head", "digging head"]
		var notes := ["long, thin, sharp", "broad wedge, thick back", "broad, flat, round edge"]
		var tints := [Color(0.55, 0.55, 0.57), Color(0.52, 0.51, 0.47), Color(0.58, 0.55, 0.50)]
		for k in 3:
			var c: Vector2 = centers[k]
			_draw_knapped(geos[k], Transform2D(0.0, c), tints[k], 1.0, k * 31)
			_text(Vector2(c.x, 226), names[k], 14)
			_text(Vector2(c.x, 245), notes[k], 11, INK2)
		# side profiles (thickness): thin lens, thick-backed wedge, flat slab
		_side_profile(Vector2(138, 116), PackedVector2Array([Vector2(0, -62), Vector2(3, -30), Vector2(3.5, 20), Vector2(2, 52), Vector2(0, 58),
			Vector2(-2, 52), Vector2(-3.5, 20), Vector2(-3, -30)]))
		_side_profile(Vector2(306, 116), PackedVector2Array([Vector2(-7, -56), Vector2(7, -56), Vector2(9, -40), Vector2(6, 10), Vector2(0.5, 58),
			Vector2(-0.5, 58), Vector2(-6, 10), Vector2(-9, -40)]))
		_side_profile(Vector2(456, 116), PackedVector2Array([Vector2(-3, -58), Vector2(3, -58), Vector2(3.5, 30), Vector2(1, 58), Vector2(-1, 58),
			Vector2(-3.5, 30)]))
		for x in [138.0, 306.0, 456.0]:
			_text(Vector2(x, 180), "side", 10, INK2)
	# a glint sweeping along each cutting edge
	_layer(3, true)
	for k in 3:
		var g: Dictionary = geos[k]
		var edge: PackedVector2Array = Transform2D(0.0, centers[k]) * PackedVector2Array(g["edge"])
		var el := _plen(edge)
		var ph := fposmod(_t / 3.0 - k * 0.22, 1.0)
		var head := lerpf(-30.0, el + 30.0, _ss(_seg(ph, 0.0, 0.75)))
		var seg := _psub(edge, maxf(head - 36.0, 0.0), clampf(head, 0.0, el))
		if seg.size() >= 2 and _plen(seg) > 1.0:
			var cols := PackedColorArray()
			for i in seg.size():
				cols.append(Color(1.0, 0.97, 0.80, 0.95 * float(i) / float(seg.size() - 1)))
			_plc(seg, cols, 3.2, true)
			if head > 0.0 and head < el:
				var hp := _pat(edge, head)
				var sp := 0.6 + 0.4 * sin(_t * 20.0)
				_ml(PackedVector2Array([hp + Vector2(-5, 0) * sp, hp + Vector2(5, 0) * sp, hp + Vector2(0, -5) * sp, hp + Vector2(0, 5) * sp]), Color(1, 1, 0.9, 0.9), 1.4, true)


func _side_profile(c: Vector2, pts: PackedVector2Array) -> void:
	var p := _xpts(pts, c, 0.0, 0.85)
	_shape(p, Color(STONE, 0.7), Color(INK, 0.7), 1.3, 0.2)


func _blade_outline() -> PackedVector2Array:
	var right := PackedVector2Array()
	var left := PackedVector2Array()
	var n := 16
	for i in n + 1:
		var u := float(i) / float(n)
		var hw := 20.0 * pow(sin(PI * clampf(0.13 + u * 0.87, 0.0, 1.0)), 0.75) * (1.0 - 0.25 * u)
		var y := 86.0 - 176.0 * u
		right.append(Vector2(hw, y))
		left.append(Vector2(-hw, y))
	var out := PackedVector2Array()
	for i in range(1, 4):
		var u := float(i) / 4.0
		out.append(Vector2(lerpf(left[0].x, right[0].x, u), 86.0 + 4.0 * sin(PI * u)))
	var pts := PackedVector2Array()
	pts.append_array(right)
	for i in range(n - 1, -1, -1):
		pts.append(left[i])
	pts.append_array(out)
	return Transform2D(-0.08, Vector2.ZERO) * pts


func _axe_outline() -> PackedVector2Array:
	var pts := PackedVector2Array()
	for p in _arcp(Vector2(0, -60), 17.0, 13.0, PI * 1.05, PI * 1.95, 6):
		pts.append(p)
	pts.append_array(PackedVector2Array([Vector2(21, -50), Vector2(30, -20), Vector2(40, 12), Vector2(47, 38)]))
	for p in _arcp(Vector2(0, 38), 48.0, 26.0, 0.05, PI - 0.05, 12):
		pts.append(p)
	pts.append_array(PackedVector2Array([Vector2(-40, 12), Vector2(-30, -20), Vector2(-21, -50)]))
	return pts


func _dig_outline() -> PackedVector2Array:
	var pts := PackedVector2Array([Vector2(-40, -54), Vector2(-14, -57), Vector2(-11, -70), Vector2(11, -70), Vector2(14, -57),
		Vector2(40, -54), Vector2(45, -20), Vector2(47, 14)])
	for p in _arcp(Vector2(0, 14), 47.0, 50.0, 0.0, PI, 14):
		pts.append(p)
	pts.remove_at(pts.size() - 1)
	pts.append(Vector2(-47, 14))
	pts.append(Vector2(-45, -20))
	return pts


func _knap_geo(outline: PackedVector2Array, which: int, step: float) -> Dictionary:
	## Scalloped (flake-scarred) outline, facet patches and scar lines, built once.
	var closed := outline.duplicate()
	closed.append(outline[0])
	var total := _plen(closed)
	var n := maxi(8, int(total / step))
	var nodes := PackedVector2Array()
	for i in n:
		nodes.append(_pat(closed, total * float(i) / float(n)))
	var ymin := 1e9
	var ymax := -1e9
	for p in outline:
		ymin = minf(ymin, p.y)
		ymax = maxf(ymax, p.y)
	var axis0 := ymin + (ymax - ymin) * 0.22
	var axis1 := ymax - (ymax - ymin) * 0.28
	var inner := PackedVector2Array()
	for p in nodes:
		var target := Vector2(0, clampf(p.y, axis0, axis1))
		var k := 0.42 + 0.12 * _rnd(int(p.x * 3.0 + p.y * 7.0) & 255)
		inner.append(p.lerp(target, k))
	var scal := PackedVector2Array()
	var facets: Array = []
	var lines := PackedVector2Array()
	var edge := PackedVector2Array()
	for i in n:
		var a := nodes[i]
		var b := nodes[(i + 1) % n]
		var mid := (a + b) * 0.5
		var inward := (inner[i] + inner[(i + 1) % n]) * 0.5 - mid
		var ctrl := mid + inward.normalized() * 2.4
		var arc := _qb(a, ctrl, b, 4)
		arc.remove_at(arc.size() - 1)
		scal.append_array(arc)
		var f := arc.duplicate()
		f.append(b)
		f.append(inner[(i + 1) % n])
		f.append(inner[i])
		facets.append(f)
		lines.append(a)
		lines.append(inner[i])
		lines.append(inner[i])
		lines.append(inner[(i + 1) % n])
		var on_edge := false
		match which:
			0: on_edge = a.y < 78.0 and b.y < 78.0
			1: on_edge = a.y > 30.0 and b.y > 30.0
			2: on_edge = a.y > 8.0 and b.y > 8.0
		if on_edge:
			edge.append_array(arc)
			edge.append(b)
	# keep the edge path continuous (start it after any break)
	var cleaned := PackedVector2Array()
	var best := PackedVector2Array()
	for p in edge:
		if cleaned.size() > 0 and cleaned[cleaned.size() - 1].distance_to(p) > step * 1.5:
			if cleaned.size() > best.size():
				best = cleaned
			cleaned = PackedVector2Array()
		cleaned.append(p)
	if cleaned.size() > best.size():
		best = cleaned
	return {"outline": scal, "facets": facets, "lines": lines, "edge": best}


# --- 9. cordage --------------------------------------------------------------

func _d_cordage() -> void:
	var t := _t
	var P := 7.0
	var lt := fposmod(t, P)
	var tight := _ss(_seg(lt, 0.3, 3.0))
	var grow := _ss(_seg(lt, 2.8, 5.6))
	var fade := 1.0 - _seg(lt, P - 0.5, P)
	var spin := lt * 26.0 if lt < 3.2 else 3.2 * 26.0 + (lt - 3.2) * 6.0
	# two strands, each twisted (stripes travel = the bundle turns)
	var j := Vector2(236, 128)
	var starts := [Vector2(44, 80), Vector2(44, 176)]
	for s in 2:
		var a: Vector2 = starts[s]
		var d := j + Vector2(-4, -6.0 if s == 0 else 6.0) - a
		var L := d.length()
		var r := lerpf(9.5, 7.8, tight)
		_push(Transform2D(d.angle(), a))
		_twisted_band(L, r, lerpf(15.0, 9.0, tight), spin, Color(STRAW, 0.95 * fade), Color(INK, fade), 1)
		# loose fibres at the free end
		var fib := PackedVector2Array()
		for k in 7:
			var y := lerpf(-r * 0.8, r * 0.8, float(k) / 6.0)
			fib.append(Vector2(2.0, y))
			fib.append(Vector2(-10.0 - 6.0 * _rnd(k + s * 9), y * 1.6 + (_rnd(k * 3 + s) - 0.5) * 4.0))
		_ml(fib, Color(STRAW.darkened(0.3), fade), 1.2, true)
		# twist arrow wrapped around the strand
		var arw := 0.5 + 0.5 * sin(lt * 6.0)
		var ap := _arcp(Vector2(L * 0.42, 0), 7.0, r + 6.0, -PI * 0.5 - 1.2, PI * 0.5 - 0.1, 10)
		_arrow_path(ap, Color(RED.darkened(0.1), (0.55 + 0.45 * arw) * (1.0 - grow * 0.6) * fade), 2.0, 6.0, 0.2)
		_pop()
	# the two-ply cord: lobes of both strands spiral the opposite way
	var x0 := 238.0
	var x1 := lerpf(x0 + 4.0, 452.0, grow)
	if x1 > x0 + 6.0:
		var r := 11.0
		var pitch := 17.0
		var slant := 9.0
		var ph := fposmod(-(lt - 2.8) * 14.0, pitch * 2.0) if lt > 2.8 else 0.0
		var clip := _rectp(Rect2(x0, 128.0 - r - 4.0, x1 - x0, r * 2.0 + 8.0))
		var light: Array = []
		var dark: Array = []
		var k := -2
		while true:
			var xa := x0 + ph + k * pitch - pitch * 2.0
			if xa > x1 + slant:
				break
			var lobe := _qb(Vector2(xa - slant, 128.0 - r + 1.0), Vector2(xa - slant * 0.2, 128.0 - r - 3.0), Vector2(xa + pitch - slant, 128.0 - r + 1.0), 4)
			lobe.remove_at(lobe.size() - 1)
			var side_r := _qb(Vector2(xa + pitch - slant, 128.0 - r + 1.0), Vector2(xa + pitch + slant * 0.2, 128.0), Vector2(xa + pitch + slant, 128.0 + r - 1.0), 5)
			side_r.remove_at(side_r.size() - 1)
			lobe.append_array(side_r)
			var bottom := _qb(Vector2(xa + pitch + slant, 128.0 + r - 1.0), Vector2(xa + pitch * 0.5 + slant * 1.2, 128.0 + r + 3.0), Vector2(xa + slant, 128.0 + r - 1.0), 4)
			bottom.remove_at(bottom.size() - 1)
			lobe.append_array(bottom)
			var side_l := _qb(Vector2(xa + slant, 128.0 + r - 1.0), Vector2(xa - slant * 0.2, 128.0), Vector2(xa - slant, 128.0 - r + 1.0), 5)
			side_l.remove_at(side_l.size() - 1)
			lobe.append_array(side_l)
			for part in Geometry2D.intersect_polygons(lobe, clip):
				(light if (k & 1) == 0 else dark).append(part)
			k += 1
		_fill_convex_many(light, Color(STRAW, 0.95 * fade))
		_fill_convex_many(dark, Color(STRAW.darkened(0.22), 0.95 * fade))
		_outline_many(light + dark, Color(INK, 0.85 * fade), 1.4)
		var ap := _arcp(Vector2(minf(x1 - 30.0, 330.0), 128), 8.0, r + 8.0, PI * 0.5 + 0.1, PI * 1.5 + 1.2, 10)
		_arrow_path(ap, Color(GREEN.darkened(0.1), grow * fade), 2.0, 6.0, 0.2)
	_text(Vector2(120, 40), "twist each strand", 13, Color(INK, fade))
	_text(Vector2(346, 84), "ply them together, the other way", 12, Color(INK, grow * fade))
	_text(Vector2(420, 172), "two-ply cord", 13, Color(INK, _seg(lt, 5.0, 5.6) * fade))


func _twisted_band(L: float, r: float, pitch: float, phase: float, fill: Color, ink: Color, dir: int) -> void:
	## A fibre bundle along +x (local) with slanted stripes that travel as it turns.
	var rect := Rect2(0, -r, L, r * 2.0)
	_fill(_rectp(rect), fill)
	_fill(_rectp(Rect2(0, r * 0.25, L, r * 0.75)), Color(fill.darkened(0.25), fill.a * 0.45))
	var segs := PackedVector2Array()
	var sl := r * 1.2 * float(dir)
	var x := -fposmod(phase, pitch) - absf(sl) * 2.0
	while x < L + absf(sl):
		var c := _clip_seg(Vector2(x - sl, r), Vector2(x + sl, -r), rect)
		if c.size() == 2:
			segs.append_array(c)
		x += pitch
	if segs.size() >= 2:
		_ml(segs, Color(INK, 0.55 * ink.a), 1.3, true)
	_line(Vector2(0, -r * 0.5), Vector2(L, -r * 0.5), Color(1, 1, 1, 0.35 * fill.a), 1.4, 0.3)
	_stroke(PackedVector2Array([Vector2(0, -r), Vector2(L, -r)]), ink, 1.6, false, 0.4)
	_stroke(PackedVector2Array([Vector2(0, r), Vector2(L, r)]), ink, 1.6, false, 0.4)


# --- 10. haft ----------------------------------------------------------------

func _d_haft() -> void:
	var t := _t
	var P := 8.0
	var lt := fposmod(t, P)
	var fade := 1.0 - _seg(lt, P - 0.45, P)
	var test := _seg(lt, 5.4, 7.0)
	var tilt := -0.24 * sin(test * PI * 2.5) * pow(1.0 - test, 1.2)
	var grip := Vector2(76, 160)
	var swing := _rot_about(grip, tilt)
	if not _cache.has("axe_geo"):
		_cache["axe_geo"] = _knap_geo(_axe_outline(), 1, 15.0)
	# stone head drops into the split (drawn first: the split halves cover its middle)
	var drop := _back(_seg(lt, 0.2, 1.4))
	_layer_fx(2, swing * Transform2D(0.0, Vector2(0, -92.0 * (1.0 - drop))), Color(1, 1, 1, fade * _seg(lt, 0.0, 0.25)))
	if _layer(2, false):
		_draw_knapped(_cache["axe_geo"], Transform2D(-0.04, Vector2(0.58, 0.58), 0.0, Vector2(350, 174)), Color(0.52, 0.51, 0.47), 1.0, 3)
	# handle
	_layer_fx(3, swing, Color(1, 1, 1, fade))
	if _layer(3, false):
		_shape(_rrect(Rect2(64, 153, 322, 14), 5.0, 3), Color(WOOD, 0.95), INK, 2.0, 0.5)
		for k in 3:
			var y := 157.0 + k * 3.0
			_stroke(PackedVector2Array([Vector2(84.0 + k * 20.0, y), Vector2(200, y + 0.5), Vector2(300.0 - k * 14.0, y)]), Color(INK, 0.25), 1.0, false, 0.6)
	# the split (opens a little while the head goes in), then cord wraps one by one
	_layer(4, true)
	_push(swing)
	var gap := 1.2 + 2.2 * sin(PI * _seg(lt, 0.4, 1.5))
	_stroke(PackedVector2Array([Vector2(312, 160), Vector2(330, 160)]), Color(INK, 0.85 * fade), gap, false, 0.2)
	_stroke(PackedVector2Array([Vector2(368, 160), Vector2(386, 160)]), Color(INK, 0.85 * fade), gap, false, 0.2)
	var wraps := [[Vector2(296, 150), Vector2(305, 170)], [Vector2(304, 150), Vector2(313, 170)], [Vector2(312, 150), Vector2(321, 170)],
		[Vector2(325, 140), Vector2(375, 181)], [Vector2(325, 181), Vector2(375, 140)], [Vector2(376, 150), Vector2(385, 170)]]
	var done := 0
	for i in wraps.size():
		var w0 := 1.8 + i * 0.55
		var g := _ss(_seg(lt, w0, w0 + 0.3))
		if g <= 0.0:
			continue
		if g >= 1.0:
			done += 1
		var a: Vector2 = wraps[i][0]
		var b: Vector2 = wraps[i][1]
		_cord(PackedVector2Array([a, a.lerp(b, g)]), 3.4, STRAW, fade)
	# test swing: motion lines
	if test > 0.05 and test < 0.7:
		var ma := sin(PI * test / 0.7) * 0.6
		for k in 3:
			_pl(_arcp(grip, 300.0 + k * 10.0, 300.0 + k * 10.0, -0.2 - 0.03 * k, -0.02, 8), Color(INK, ma), 1.2)
	_pop()
	# labels (faded out while the tool is tested)
	var la := fade * (1.0 - _win(lt, 5.3, 7.3, 0.3))
	_layer_fx(5, Transform2D.IDENTITY, Color(1, 1, 1, la))
	if _layer(5, false):
		_callout("stone head", Vector2(436, 100), Vector2(368, 128), 12)
		_callout("split", Vector2(300, 122), Vector2(322, 158), 12)
		_text(Vector2(160, 186), "handle", 12)
	_layer_fx(6, Transform2D.IDENTITY, Color(1, 1, 1, la * _seg(float(done), 0.5, 1.5)))
	if _layer(6, false):
		_callout("cord wraps", Vector2(268, 222), Vector2(308, 168), 12)
	_layer_fx(7, Transform2D.IDENTITY, Color(1, 1, 1, fade * _seg(lt, 6.9, 7.2)))
	if _layer(7, false):
		_check(Vector2(436, 214), 1.3, GREEN)
		_text(Vector2(436, 240), "test it", 12)


func _cord(pts: PackedVector2Array, w: float = 3.4, col: Color = STRAW, a: float = 1.0) -> void:
	## A length of two-ply cord (ink edge, wash, twist ticks).
	if pts.size() < 2 or a <= 0.004:
		return
	var p := _wob(pts, false, 0.3)
	if _plen(p) < 0.5:
		return
	_pl(p, Color(INK, 0.9 * a), w + 2.0, true)
	_pl(p, Color(col, a), w, true)
	var total := _plen(p)
	var segs := PackedVector2Array()
	var d := 2.0
	while d < total - 1.0:
		var c := _pat(p, d)
		var dir := _pdir(p, d)
		var n := Vector2(-dir.y, dir.x)
		segs.append(c + n * w * 0.45 - dir * w * 0.35)
		segs.append(c - n * w * 0.45 + dir * w * 0.35)
		d += w * 1.1
	if segs.size() >= 2:
		_ml(segs, Color(INK, 0.45 * a), 1.0, true)


func _draw_knapped(g: Dictionary, xf: Transform2D, base: Color, a: float = 1.0, sd: int = 0) -> void:
	## A knapped stone from _knap_geo: wash, facet patches, scar lines, outline.
	if a <= 0.004:
		return
	_fill(xf * PackedVector2Array(g["outline"]), Color(base, 0.95 * a))
	var facets: Array = g["facets"]
	for i in facets.size():
		var fc := base.lightened(0.18) if _rnd(i * 7 + sd) > 0.5 else base.darkened(0.12)
		_fill(xf * PackedVector2Array(facets[i]), Color(fc, 0.55 * a))
	_ml(xf * PackedVector2Array(g["lines"]), Color(INK, 0.42 * a), 1.0, true)
	var ol: PackedVector2Array = xf * PackedVector2Array(g["outline"])
	ol.append(ol[0])
	_pl(ol, Color(INK, a), 1.9, true)


# --- 11. clay_prep -----------------------------------------------------------

func _d_clay_prep() -> void:
	var t := _t
	var P := 8.0
	var lt := fposmod(t, P)
	var fade := 1.0 - _seg(lt, P - 0.4, P)
	var g0 := 90.0
	var zw := 100.0
	if _layer(2, false):
		# work slab and the moisture gauge
		_shape(_rrect(Rect2(104, 186, 264, 18), 6.0, 3), Color(STONE.lerp(PAPER, 0.25), 0.95), INK, 1.8, 0.5)
		_line(Vector2(130, 197), Vector2(170, 196), Color(INK, 0.25), 1.0)
		var zc := [STRAW, GREEN, WATER]
		for z in 3:
			_fill(_rectp(Rect2(g0 + zw * z, 220, zw, 11)), Color(zc[z], 0.45))
		_stroke(_rrect(Rect2(g0, 220, zw * 3.0, 11), 4.0), INK, 1.6, true, 0.3)
		_line(Vector2(g0 + zw, 220), Vector2(g0 + zw, 231), INK2, 1.2, 0.2)
		_line(Vector2(g0 + zw * 2.0, 220), Vector2(g0 + zw * 2.0, 231), INK2, 1.2, 0.2)
	_layer(3, true)
	var drops := [0.7, 1.25, 1.8, 2.35]
	var fall := 0.42
	var wet := 0.0
	for td in drops:
		wet += 0.25 * _ss(_seg(lt, float(td) + fall, float(td) + fall + 0.35))
	var knead := _seg(lt, 2.9, 6.1)
	var cyc := fposmod(knead * 3.0, 1.0) if knead > 0.0 and knead < 1.0 else 0.0
	var squash := pow(sin(PI * cyc), 2.0)
	var smooth := _ss(knead)
	# the lump
	var rx := 46.0 * (1.0 + 0.3 * squash)
	var ry := 28.0 * (1.0 - 0.34 * squash)
	var lc := Vector2(196, 186.0 - ry * 0.92)
	var pts := _lumpy(lc, rx, ry, 0.15 * (1.0 - smooth) + 0.04, 28, 2.4, 0.0, 0.07 * (1.0 - smooth)).duplicate()
	for i in pts.size():
		pts[i].y = minf(pts[i].y, 187.0)
	var col := CLAY.lerp(Color(0.86, 0.74, 0.60), 0.55 * (1.0 - wet))
	_shape(pts, Color(col, 0.97 * fade), Color(INK, fade), 2.0, 0.4)
	if smooth > 0.6:
		_stroke(_arcp(lc + Vector2(-6, -ry * 0.2), rx * 0.62, ry * 0.55, PI * 1.15, PI * 1.6, 8), Color(1, 1, 1, 0.45 * _seg(smooth, 0.6, 1.0) * fade), 2.0, false, 0.2)
	# dry cracks
	var ca := (1.0 - wet) * (1.0 - smooth) * fade
	if ca > 0.02:
		for k in 3:
			var c0 := lc + Vector2(-26.0 + 24.0 * k, -ry * 0.35 + 5.0 * (k % 2))
			_stroke(PackedVector2Array([c0, c0 + Vector2(4, 4), c0 + Vector2(2, 9), c0 + Vector2(6, 13)]), Color(INK, 0.7 * ca), 1.2, false, 0.2)
	# grit specks: picked out during kneading, collected on the slab
	var grit := [Vector2(-0.55, -0.15), Vector2(-0.2, -0.55), Vector2(0.25, -0.3), Vector2(0.55, -0.1), Vector2(-0.05, 0.1), Vector2(0.35, 0.3)]
	var gc := PackedVector2Array()
	var gr := PackedFloat32Array()
	var go: Array = []
	for i in grit.size():
		var gv: Vector2 = grit[i]
		var on := lc + Vector2(gv.x * rx, gv.y * ry)
		var pile := Vector2(326.0 + (i % 3) * 6.0 - 6.0, 181.0 - float(i / 3) * 4.5)
		var tp := 3.1 + i * 0.45
		var u := _ss(_seg(lt, tp, tp + 0.45))
		var p := on.lerp(pile, u) + Vector2(0, -38.0 * sin(PI * u))
		gc.append(p)
		gr.append(2.2)
		go.append(_oval(p, 2.6, 2.6, 7))
	_discs(gc, gr, Color(STONE.darkened(0.3), fade))
	_outline_many(go, Color(INK, 0.8 * fade), 1.0)
	if lt > 3.4:
		_text(Vector2(326, 160), "grit out", 12, Color(INK, fade * _seg(lt, 3.4, 3.8)))
	# water from a little pot
	var pa := _win(lt, 0.3, 3.0, 0.3) * fade
	if pa > 0.01:
		var vp := Vector2(232, 42)
		var tilt := -2.0
		_shape(_xpts(_POT, vp, tilt, 1.9), Color(FIRED, 0.95 * pa), Color(INK, pa), 1.8, 0.3)
		_fill(_xpts(_oval(Vector2(0, -11), 6.0, 2.2, 10), vp, tilt, 1.9), Color(WATER.darkened(0.2), pa))
		_text(Vector2(276, 30), "water", 12, Color(INK, pa))
	for td in drops:
		var u := _seg(lt, float(td), float(td) + fall)
		if u > 0.0 and u < 1.0:
			_drop(Vector2(208, lerpf(52.0, lc.y - ry + 4.0, u * u)), 4.0)
		var sp := _seg(lt, float(td) + fall, float(td) + fall + 0.3)
		if sp > 0.0 and sp < 1.0:
			var top := Vector2(204, lc.y - ry + 2.0)
			_pl(_arcp(top, 6.0 + 12.0 * sp, 3.0 + 4.0 * sp, PI * 1.1, PI * 1.9, 8), Color(WATER, 1.0 - sp), 1.4)
	# kneading arrows: press, then fold over
	if knead > 0.0 and knead < 1.0:
		var top := lc + Vector2(0, -ry)
		if cyc < 0.5:
			var a := sin(PI * cyc * 2.0)
			for s in [-1.0, 1.0]:
				_arrow(top + Vector2(18.0 * s, -30.0), top + Vector2(18.0 * s, -9.0), Color(INK, 0.85 * a), 2.0, 7.0)
		else:
			var a := sin(PI * (cyc - 0.5) * 2.0)
			_arrow(lc + Vector2(rx * 0.75, -ry * 0.6), lc + Vector2(-rx * 0.55, -ry * 0.9), Color(INK, 0.85 * a), 2.0, 7.0, -30.0)
		_text(Vector2(196, 86), "knead & fold", 13, Color(INK, _win(lt, 2.9, 6.3, 0.3)))
	# where the moisture is now
	var zn := ["crumbly", "good", "sticky"]
	var good := _seg(lt, 6.1, 6.5) * fade
	for z in 3:
		var c := INK.lerp(GREEN.darkened(0.2), good) if z == 1 else INK
		_text(Vector2(g0 + zw * (z + 0.5), 246), zn[z], 13 if z == 1 else 12, c)
	var mx := 110.0 + 88.0 * wet + 44.0 * smooth
	_fill(PackedVector2Array([Vector2(mx - 6, 208), Vector2(mx + 6, 208), Vector2(mx, 217)]), INK)
	_line(Vector2(mx, 217), Vector2(mx, 233), INK, 2.0, 0.2)


# --- 12. pottery -------------------------------------------------------------

func _d_pottery() -> void:
	var t := _t
	var P := 8.4
	var lt := fposmod(t * (P / 8.0), P)   # the 8.4 s story plays in an 8 s loop
	var fade := 1.0 - _seg(lt, P - 0.4, P)
	var axis := 240.0
	var base_y := 168.0
	if _layer(2, false):
		_dashed(PackedVector2Array([Vector2(axis, 36), Vector2(axis, base_y + 8.0)]), Color(INK, 0.35), 1.2, 9.0, 4.0)
		_line(Vector2(axis - 110.0, base_y + 1.0), Vector2(axis + 110.0, base_y + 1.0), INK2, 1.4)
		_text(Vector2(372, 54), "pinch & pull up", 12)
		_text(Vector2(372, 70), "thinner, taller walls", 11, INK2)
	_layer(3, true)
	var s1 := _ss(_seg(lt, 0.8, 2.6))
	var s2 := _ss(_seg(lt, 3.3, 4.9))
	var s3 := _ss(_seg(lt, 5.6, 7.2))
	var h := 14.0 + 30.0 * s1 + 26.0 * s2 + 24.0 * s3
	var th := 20.0 - 9.0 * s1 - 2.0 * s2 - 2.0 * s3
	var base_top := base_y - 10.0
	var r0 := 60.0
	var n := 12
	var rr := PackedFloat32Array()
	var ww := PackedFloat32Array()
	var yy := PackedFloat32Array()
	for i in n + 1:
		var u := float(i) / float(n)
		var r := r0 + 28.0 * pow(u, 1.6) * s1 * (1.0 - s2) + 3.0 * u * s2
		r += s3 * (12.0 * sin(PI * u * 0.95) - 34.0 * _ss((u - 0.55) / 0.45))
		rr.append(r)
		ww.append(th * (1.0 - 0.35 * u))
		yy.append(base_top - h * u)
	var poly := PackedVector2Array()
	for i in range(n, -1, -1):
		poly.append(Vector2(axis - rr[i] - ww[i] * 0.5, yy[i]))
	poly.append(Vector2(axis - rr[0] - ww[0] * 0.5, base_y - 2.0))
	poly.append(Vector2(axis - rr[0] - ww[0] * 0.5 + 3.0, base_y))
	poly.append(Vector2(axis + rr[0] + ww[0] * 0.5 - 3.0, base_y))
	poly.append(Vector2(axis + rr[0] + ww[0] * 0.5, base_y - 2.0))
	for i in n + 1:
		poly.append(Vector2(axis + rr[i] + ww[i] * 0.5, yy[i]))
	poly.append(Vector2(axis + rr[n], yy[n] - ww[n] * 0.35))
	for i in range(n, -1, -1):
		poly.append(Vector2(axis + rr[i] - ww[i] * 0.5, yy[i]))
	for i in n + 1:
		poly.append(Vector2(axis - rr[i] + ww[i] * 0.5, yy[i]))
	poly.append(Vector2(axis - rr[n], yy[n] - ww[n] * 0.35))
	_fill(Transform2D(0.0, FOFF) * poly, Color(CLAY, 0.92 * fade))
	_hatch_poly(poly, 6.0, Color(INK, 0.32 * fade), 1.0, 1.0)
	var ol := poly.duplicate()
	ol.append(poly[0])
	_pl(ol, Color(INK, fade), 2.0, true)
	# fingers pinching and pulling up the right wall
	var pulls := [[0.8, 2.6], [3.3, 4.9], [5.6, 7.2]]
	for pr in pulls:
		var a0: float = pr[0]
		var a1: float = pr[1]
		if lt > a0 and lt < a1:
			var u := fposmod(_seg(lt, a0, a1) * 2.0, 1.0)
			var k := clampi(int(u * n), 0, n)
			var y := yy[k]
			var xo := axis + rr[k] + ww[k] * 0.5
			var xi := axis + rr[k] - ww[k] * 0.5
			var al := sin(PI * u) * fade
			_arrow(Vector2(xo + 18.0, y), Vector2(xo + 3.0, y), Color(INK, al), 1.8, 6.0)
			_arrow(Vector2(xi - 18.0, y), Vector2(xi - 3.0, y), Color(INK, al), 1.8, 6.0)
			_arrow(Vector2(xo + 28.0, y + 18.0), Vector2(xo + 28.0, y - 12.0), Color(RED.darkened(0.1), al), 2.0, 7.0)
	# what the walls become: the matching shape lights up
	var stage := 0
	if s3 >= 0.5:
		stage = 3
	elif s2 >= 0.5:
		stage = 2
	elif s1 >= 0.5:
		stage = 1
	if stage > 0:
		var uc := Vector2(150.0 + 90.0 * (stage - 1), 214)
		_line(uc + Vector2(-16, 43), uc + Vector2(16, 43), Color(RED.darkened(0.1), fade), 1.8, 0.4)
	var shapes := [
		PackedVector2Array([Vector2(-30, -12), Vector2(30, -12), Vector2(25, -2), Vector2(14, 9), Vector2(-14, 9), Vector2(-25, -2)]),
		PackedVector2Array([Vector2(-17, -18), Vector2(17, -18), Vector2(15, 12), Vector2(12, 15), Vector2(-12, 15), Vector2(-15, 12)]),
		PackedVector2Array([Vector2(-10, -26), Vector2(10, -26), Vector2(9, -21), Vector2(16, -12), Vector2(20, 2), Vector2(15, 15),
			Vector2(9, 19), Vector2(-9, 19), Vector2(-15, 15), Vector2(-20, 2), Vector2(-16, -12), Vector2(-9, -21)]),
	]
	var names := ["bowl", "cup", "jar"]
	for k in 3:
		_layer_fx(4 + k, Transform2D.IDENTITY, Color(1, 1, 1, (1.0 if stage == k + 1 else 0.45) * fade))
		if _layer(4 + k, false):
			var c := Vector2(150.0 + 90.0 * k, 214)
			_shape(_xpts(shapes[k], c), Color(FIRED, 0.9), INK, 1.7, 0.3)
			_text(c + Vector2(0, 34), names[k], 13)


# --- 13. drying --------------------------------------------------------------

func _dry_roof(u: float) -> float:
	return 1.0 - 0.92 * (1.0 - pow(1.0 - clampf(u, 0.0, 1.0), 1.7))


func _dry_open(u: float, r0: float, r1: float) -> float:
	if u <= r0:
		return _dry_roof(u)
	if u <= r1:
		return lerpf(_dry_roof(r0), 0.8, _ss((u - r0) / (r1 - r0)))
	return _dry_roof(u) + (0.8 - _dry_roof(r1)) * exp(-(u - r1) * 3.0)


func _d_drying() -> void:
	var t := _t
	var P := 8.5
	var lt := fposmod(t * (P / 8.0), P)   # the 8.5 s story plays in an 8 s loop
	var fade := 1.0 - _seg(lt, P - 0.4, P)
	var u := _seg(lt, 0.4, 6.6)
	var x0 := 172.0
	var x1 := 452.0
	var yw := 66.0
	var yd := 192.0
	var r0 := 0.58
	var r1 := 0.72
	var rain_a := _win(u, r0 - 0.01, r1 + 0.01, 0.03)
	var xr0 := lerpf(x0, x1, r0)
	var xr1 := lerpf(x0, x1, r1)
	var c_open := CLAY.darkened(0.15)
	var c_roof := GREEN
	if _layer(2, false):
		# chart: moisture over one day, with a shower in the afternoon
		_line(Vector2(x0, yw - 14.0), Vector2(x0, yd), INK, 1.6, 0.4)
		_line(Vector2(x0, yd), Vector2(x1 + 6.0, yd), INK, 1.6, 0.4)
		_text(Vector2(x0 - 8.0, yw), "wet", 12, INK, RIGHT)
		_text(Vector2(x0 - 8.0, yd), "dry", 12, INK, RIGHT)
		_fill(_rectp(Rect2(xr0, yw - 14.0, xr1 - xr0, yd - yw + 14.0)), Color(SKY, 0.35))
		_cloud(Vector2((xr0 + xr1) * 0.5, 40), 64.0, 26.0, Color(0.95, 0.95, 0.96, 0.95), INK, 1.3, Color(SMOKE_B, 0.4))
		_text(Vector2((xr0 + xr1) * 0.5 + 44.0, 30), "rain", 12)
		for k in 3:
			var tx := lerpf(x0, x1, float(k) * 0.5)
			_line(Vector2(tx, yd), Vector2(tx, yd + 5.0), INK, 1.4, 0.2)
		_text(Vector2(x0 + 6.0, yd + 16.0), "morning", 11, INK2)
		_text(Vector2((x0 + x1) * 0.5, yd + 16.0), "noon", 11, INK2)
		_text(Vector2(x1 - 6.0, yd + 16.0), "evening", 11, INK2)
		# the two pots' legend and the little roof
		_text(Vector2(70, 136), "open", 12)
		_text(Vector2(70, 246), "under a roof", 12)
		_line(Vector2(94, 104), Vector2(108, 104), c_open, 2.6, 0.2)
		_line(Vector2(94, 214), Vector2(108, 214), c_roof, 2.6, 0.2)
		_line(Vector2(40, 172), Vector2(40, 234), WOOD.darkened(0.3), 2.4, 0.3)
		_line(Vector2(102, 180), Vector2(102, 234), WOOD.darkened(0.3), 2.4, 0.3)
		_shape(PackedVector2Array([Vector2(28, 166), Vector2(114, 176), Vector2(114, 183), Vector2(28, 173)]), Color(STRAW, 0.95), INK, 1.6, 0.3)
	var sun_u := clampf(u, 0.0, 1.0)
	var sun_ref := Vector2(x0 + 20.0, 34.0)
	var sp := Vector2(lerpf(x0 + 20.0, x1 - 20.0, sun_u), 34.0 - 10.0 * sin(PI * sun_u))
	_layer_fx(3, Transform2D(0.0, sp - sun_ref), Color(1, 1, 1, (1.0 - 0.85 * rain_a) * fade))
	if _layer(3, false):
		_sun(sun_ref, 9.0, 1.0, false)
	_layer(4, true)
	var streaks := PackedVector2Array()
	for i in 8:
		var x := lerpf(xr0 + 4.0, xr1 - 4.0, _rnd(i * 3))
		var ph := fposmod(t * 1.2 + _rnd(i * 5 + 1), 1.0)
		var y := lerpf(yw - 10.0, yd - 4.0, ph)
		streaks.append(Vector2(x, y))
		streaks.append(Vector2(x - 1.0, y + 7.0))
	_ml(streaks, Color(WATER.darkened(0.2), 0.55), 1.2, true)
	# sun and breeze speed it up
	for k in 2:
		var bx := 216.0 + k * 52.0
		var by := 52.0 + k * 8.0
		var bw := PackedVector2Array()
		for j in 8:
			var v := float(j) / 7.0
			bw.append(Vector2(bx + v * 30.0, by + sin(v * 6.0 + t * 4.0 + k) * 2.0))
		_pl(bw, Color(INK, 0.5 * (1.0 - rain_a)), 1.4)
	_text(Vector2(260, 82), "sun + breeze", 11, Color(INK2, INK2.a * (1.0 - rain_a)))
	# the two moisture lines, drawn up to "now"
	var lo := PackedVector2Array()
	var lr := PackedVector2Array()
	var steps := maxi(2, int(40.0 * u) + 1)
	for i in steps:
		var v := u * float(i) / float(steps - 1)
		var x := lerpf(x0, x1, v)
		lo.append(Vector2(x, lerpf(yd, yw, _dry_open(v, r0, r1))))
		lr.append(Vector2(x, lerpf(yd, yw, _dry_roof(v)) + 2.5))
	if u > 0.0:
		_pl(lr, Color(c_roof, fade), 2.4)
		_pl(lo, Color(c_open, fade), 2.4)
		_dot(lr[lr.size() - 1], 3.2, Color(c_roof, fade))
		_dot(lo[lo.size() - 1], 3.2, Color(c_open, fade))
		_dashed(PackedVector2Array([Vector2(lerpf(x0, x1, u), yw - 14.0), Vector2(lerpf(x0, x1, u), yd)]), Color(INK, 0.3 * fade), 1.0, 3.0, 3.0)
	var end_a := _seg(lt, 6.4, 6.8) * fade
	_text(Vector2(x1 + 4.0, lerpf(yd, yw, _dry_open(1.0, r0, r1)) - 12.0), "open", 12, Color(c_open.darkened(0.2), end_a), RIGHT)
	_text(Vector2(x1 + 4.0, lerpf(yd, yw, _dry_roof(1.0)) - 12.0), "roofed", 12, Color(c_roof.darkened(0.2), end_a), RIGHT)
	# the pots themselves (dark = wet, pale = dry)
	_dry_pot(Vector2(70, 104), _dry_open(u, r0, r1))
	_dry_pot(Vector2(70, 214), _dry_roof(u))
	# rain on the open pot; the roofed one stays dry
	if rain_a > 0.01:
		_cloud(Vector2(70, 40), 70.0, 28.0, Color(0.95, 0.95, 0.96, 0.95 * rain_a), Color(INK, rain_a), 1.3, Color(SMOKE_B, 0.4 * rain_a))
		var rs := PackedVector2Array()
		for i in 7:
			var x := 46.0 + 48.0 * _rnd(i * 7 + 2)
			var ph := fposmod(t * 1.3 + _rnd(i * 3 + 9), 1.0)
			var y := lerpf(52.0, 100.0, ph)
			rs.append(Vector2(x, y))
			rs.append(Vector2(x - 1.0, y + 7.0))
		for i in 6:
			var x := 40.0 + 60.0 * _rnd(i * 5 + 4)
			var ph := fposmod(t * 1.3 + _rnd(i * 9 + 1), 1.0)
			var y := lerpf(150.0, 168.0 - (x - 40.0) * 0.12, ph)
			rs.append(Vector2(x, y))
			rs.append(Vector2(x - 1.0, y + 6.0))
		_ml(rs, Color(WATER.darkened(0.2), 0.8 * rain_a), 1.4, true)


func _dry_pot(c: Vector2, m: float) -> void:
	## A pot whose colour shows how wet it is (dark = wet, pale = dry).
	var pot := PackedVector2Array([Vector2(-9, -17), Vector2(9, -17), Vector2(8, -13), Vector2(16, -5), Vector2(18, 5),
		Vector2(12, 16), Vector2(-12, 16), Vector2(-18, 5), Vector2(-16, -5), Vector2(-8, -13)])
	var col := Color(0.86, 0.74, 0.60).lerp(CLAY.darkened(0.1), clampf(m, 0.0, 1.0))
	_shape(_xpts(pot, c), Color(col, 0.97), INK, 1.8, 0.3)
	_line(c + Vector2(-13, -4), c + Vector2(13, -4), Color(INK, 0.35), 1.0, 0.2)
	if m > 0.55:
		_discs(PackedVector2Array([c + Vector2(-8, 3), c + Vector2(0, 7), c + Vector2(8, 3)]), PackedFloat32Array([1.9, 1.9, 1.9]), Color(WATER, (m - 0.55) * 2.0))


# --- 14. pit_firing ----------------------------------------------------------

func _d_pit_firing() -> void:
	var t := _t
	var P := 8.0
	var lt := fposmod(t, P)
	var heat := _ss(_seg(lt, 0.3, 5.0)) * (1.0 - _ss(_seg(lt, 6.6, 7.9)))
	var gy := 116.0
	var tx := 436.0
	var pit := _cb(Vector2(76, gy), Vector2(90, 236), Vector2(320, 236), Vector2(334, gy), 18)
	if _layer(2, false):
		var soil := PackedVector2Array([Vector2(12, gy)])
		soil.append_array(pit)
		soil.append_array(PackedVector2Array([Vector2(468, gy), Vector2(468, 260), Vector2(12, 260)]))
		_fill(soil, Color(EARTH, 0.6))
		_stipple(Rect2(16, gy + 6.0, 448, 136), 70, Color(INK, 0.22), 41)
		_fill(pit, Color(SOIL, 0.55))
	_layer(3, true)
	_glow(Vector2(205, 182), 150.0, Color(EMBER, 0.6 * heat), 0.55)
	if _layer(4, false):
		_stroke(PackedVector2Array([Vector2(12, gy), Vector2(76, gy)]), INK, 2.0, false, 0.4)
		_stroke(PackedVector2Array([Vector2(334, gy), Vector2(468, gy)]), INK, 2.0, false, 0.4)
		_stroke(pit, INK, 2.0, false, 0.4)
	# fuel under and around the pots (chars as it burns)
	_layer_fx(5, Transform2D.IDENTITY, Color.WHITE.lerp(Color(0.45, 0.43, 0.42), heat * 0.7))
	if _layer(5, false):
		var sticks := [[Vector2(96, 200), Vector2(170, 212)], [Vector2(150, 214), Vector2(250, 206)], [Vector2(230, 212), Vector2(312, 198)],
			[Vector2(104, 176), Vector2(124, 210)], [Vector2(290, 172), Vector2(300, 212)], [Vector2(176, 150), Vector2(186, 206)],
			[Vector2(232, 150), Vector2(238, 204)]]
		for s in sticks:
			_line(s[0], s[1], WOOD.darkened(0.2), 4.0, 0.4)
	# dry pots nestled in, glowing as they heat (two recorded looks, cross-faded)
	for hot in 2:
		_layer_fx(6 + hot, Transform2D.IDENTITY, Color(1, 1, 1, 1.0 if hot == 0 else heat * 0.8))
		if _layer(6 + hot, false):
			var pc := Color(0.86, 0.74, 0.60) if hot == 0 else Color(0.95, 0.55, 0.30)
			_shape(_xpts(_POT, Vector2(148, 178), 0.0, 2.0), Color(pc, 0.97), INK, 1.8, 0.3)
			_shape(_xpts(_POT, Vector2(209, 186), 1.45, 1.9), Color(pc, 0.97), INK, 1.8, 0.3)
			_shape(_xpts(_POT, Vector2(268, 176), -0.08, 2.0), Color(pc, 0.97), INK, 1.8, 0.3)
	_layer(8, true)
	for k in 4:
		var fx: float = [118.0, 178.0, 238.0, 296.0][k]
		_flame(Vector2(fx, 206.0), 10.0 + 6.0 * heat, 8.0 + 34.0 * heat, k * 3.0, clampf(heat * 1.5, 0.0, 1.0))
	if _layer(9, false):
		# (drawn above the pots and flames:) cover of potsherds, then an earth mound
		var mpoly := _cb(Vector2(70, gy + 1.0), Vector2(90, 58), Vector2(320, 58), Vector2(340, gy + 1.0), 18)
		mpoly.append(Vector2(334, gy + 6.0))
		mpoly.append(Vector2(76, gy + 6.0))
		_shape(mpoly, Color(EARTH.lightened(0.08), 0.95), INK, 2.0, 0.5)
		_stipple(Rect2(110, 90, 190, 22), 26, Color(INK, 0.25), 77)
		for k in 9:
			var x := 92.0 + k * 26.0
			var y := gy - 2.0 - 10.0 * sin(PI * (x - 76.0) / 258.0)
			_shape(_xpts(PackedVector2Array([Vector2(-15, 2), Vector2(-9, -3), Vector2(9, -3), Vector2(15, 2), Vector2(9, 0), Vector2(-9, 0)]), Vector2(x, y), -0.25 + 0.5 * _rnd(k), 1.0),
				Color(FIRED, 0.95), INK, 1.3, 0.2)
		for vx in [86.0, 324.0]:
			_dot(Vector2(vx, gy - 6.0), 4.5, Color(CHARCOAL, 0.9))
		for k in 5:
			var y := lerpf(206.0 - 6.0, 206.0 - 150.0 + 4.0, float(k) / 4.0)
			_text(Vector2(tx - 12.0, y), str(k * 200), 10, INK2, RIGHT)
		_thermo_tube(Vector2(tx, 206), 150.0)
		# inset: a wet pot cracks
		_dashed(_rrect(Rect2(18, 16, 84, 90), 6.0), INK2, 1.2, 5.0, 4.0, 0.0, true)
		var ip := Vector2(56, 52)
		_shape(_xpts(_POT, ip, 0.0, 1.9), Color(CLAY, 0.95), INK, 1.8, 0.3)
		_stroke(PackedVector2Array([ip + Vector2(-3, -14), ip + Vector2(3, -7), ip + Vector2(-2, 0), ip + Vector2(4, 6), ip + Vector2(0, 14)]), RED, 2.2, false, 0.2)
		_text(Vector2(60, 94), "wet = cracks", 12, RED.darkened(0.15))
		_text(Vector2(205, 46), "earth + potsherds", 12)
		_callout("dry pots in fuel", Vector2(205, 250), Vector2(209, 200), 12)
	_layer(10, true)
	for vx in [86.0, 324.0]:
		var vp := Vector2(vx, gy - 6.0)
		_dot(vp, 3.0, Color(FLAME, (0.3 + 0.7 * heat) * (0.75 + 0.25 * sin(t * 7.0 + vx))))
		_smoke(vp + Vector2(0, -6), 60.0, Color(SMOKE_W, 0.5 * (0.3 + heat)), 4, vx, 8.0, 2.5, 8.0, 0.3, 4.0 if vx > 200.0 else -4.0)
	_smoke(Vector2(64, 34), 22.0, Color(SMOKE_W, 0.9), 3, 1.0, 5.0, 2.0, 5.0, 0.45, 3.0)
	# thermometer: up to ~800 C
	_thermo_level(Vector2(tx, 206), 150.0, 0.06 + 0.9 * heat, RED)
	if _layer(11, false):
		_thermo_frame(Vector2(tx, 206), 150.0, 4)
	_layer_fx(12, Transform2D.IDENTITY, Color(1, 1, 1, 0.4 + 0.6 * heat))
	if _layer(12, false):
		_text(Vector2(tx, 38), "800 °C", 12)


# --- 16. fire_lay ------------------------------------------------------------

func _d_fire_lay() -> void:
	var t := _t
	var P := 8.0
	var lt := fposmod(t, P)
	var fade := 1.0 - _seg(lt, P - 0.5, P)
	var burn := _ss(_seg(lt, 0.8, 6.0)) * fade
	var gy := 224.0
	var cx := 240.0
	if not _cache.has("lay"):
		var twigs: Array = []
		for k in 7:
			var bx := cx - 26.0 + k * 8.7
			twigs.append([Vector2(bx, gy - 2.0), Vector2(cx - 4.0 + 8.0 * _rnd(k * 3), 140.0)])
		var sticks: Array = []
		for k in 6:
			var bx := cx - 52.0 + k * 20.8
			sticks.append([Vector2(bx, gy - 1.0), Vector2(cx - 5.0 + 10.0 * _rnd(k * 5 + 2), 112.0)])
		var paths: Array = []
		for s in [-1.0, 1.0]:
			paths.append(_qb(Vector2(cx + s * 196.0, gy - 10.0), Vector2(cx + s * 110.0, gy - 2.0), Vector2(cx + s * 40.0, gy - 8.0), 12))
		_cache["lay"] = [twigs, sticks, paths]
	var geo: Array = _cache["lay"]
	var twigs: Array = geo[0]
	var sticks: Array = geo[1]
	var char_tint := Color.WHITE.lerp(Color(0.63, 0.66, 0.75), burn)
	if _layer(2, false):
		_line(Vector2(20, gy), Vector2(460, gy), INK2, 1.6)
		_stipple(Rect2(24, gy + 3.0, 432, 20), 40, Color(INK, 0.2), 51)
	_layer(3, true)
	_glow(Vector2(cx, gy - 40.0), 70.0 + 70.0 * burn, Color(FLAME, 0.45 * burn))
	if _layer(4, false):
		# air drawn in at the base, rising through the lay
		for path in geo[2]:
			_arrow_path(path, Color(SKY.darkened(0.35), 0.9), 2.0, 8.0)
		_text(Vector2(118, gy - 20.0), "air", 13, SKY.darkened(0.45))
		_text(Vector2(338, gy - 20.0), "air", 13, SKY.darkened(0.45))
		# tinder nest
		var nest := _lumpy(Vector2(cx, gy - 9.0), 24.0, 10.0, 0.12, 20, 1.5).duplicate()
		for i in nest.size():
			nest[i].y = minf(nest[i].y, gy)
		_shape(nest, Color(STRAW, 0.95), INK, 1.5, 0.4)
		var curls := PackedVector2Array()
		for k in 9:
			var c := Vector2(cx - 18.0 + k * 4.5, gy - 8.0 - 4.0 * _rnd(k))
			for j in 4:
				var a0 := float(j) * 1.4 + k
				curls.append(c + Vector2(cos(a0), sin(a0)) * 4.0)
				curls.append(c + Vector2(cos(a0 + 1.2), sin(a0 + 1.2)) * 4.0)
		_ml(curls, Color(INK, 0.4), 1.0, true)
	# twigs (teepee) and sticks around them; they char as the fire grows
	_layer_fx(5, Transform2D.IDENTITY, char_tint)
	if _layer(5, false):
		for s in sticks:
			_line(s[0], s[1], WOOD.darkened(0.1), 4.6, 0.6)
		for s in twigs:
			_line(s[0], s[1], WOOD.lightened(0.15), 2.2, 0.5)
	_layer(6, true)
	for path in geo[2]:
		_flow_dots(path, 18.0, t * 26.0, Color(SKY.darkened(0.2), 1.0), 2.2)
	_dashed(PackedVector2Array([Vector2(cx, gy - 30.0), Vector2(cx, 70.0)]), Color(SKY.darkened(0.35), 0.5), 1.6, 6.0, 6.0, t * 20.0)
	# firewood: waits on the ground, then is leaned on once the sticks burn well
	var lay := _ss(_seg(lt, 4.3, 5.2))
	var log_a := Vector2(384, gy - 8.0).lerp(Vector2(300, gy - 6.0), lay)
	var log_b := Vector2(456, gy - 8.0).lerp(Vector2(256, 132.0), lay)
	log_a.y -= 26.0 * sin(PI * lay)
	log_b.y -= 26.0 * sin(PI * lay)
	_wood_log(log_a, log_b, 7.5, fade)
	# flames grow from the tinder up through the lay
	var fh := 16.0 + 116.0 * burn
	var fw := 14.0 + 56.0 * burn
	if lt > 0.8 and fade > 0.01:
		_flame(Vector2(cx, gy - 4.0), fw, fh, 2.0, clampf((lt - 0.8) * 2.0, 0.0, 1.0) * fade)
		if burn > 0.4:
			_flame(Vector2(cx - 24.0, gy - 4.0), fw * 0.45, fh * 0.55, 5.0, (burn - 0.4) * 1.6)
			_flame(Vector2(cx + 26.0, gy - 4.0), fw * 0.4, fh * 0.5, 8.0, (burn - 0.4) * 1.6)
	# front sticks stay visible through the flames
	_layer_fx(7, Transform2D.IDENTITY, char_tint)
	if _layer(7, false):
		for k in [1, 4]:
			var s: Array = sticks[k]
			_line(s[0], s[1], Color(WOOD.darkened(0.2), 0.85), 4.0, 0.6)
		for k in [2, 5]:
			var s: Array = twigs[k]
			_line(s[0], s[1], Color(WOOD, 0.85), 2.0, 0.5)
	_layer(8, true)
	_smoke(Vector2(cx, 120.0 - 30.0 * burn), 90.0, Color(SMOKE_W, 0.6 * burn), 5, 3.0, 10.0, 4.0, 14.0, 0.25, 8.0)
	_callout("firewood", Vector2(410, 160), (log_a + log_b) * 0.5, 12, CENTER, Color(INK, fade))
	if _layer(9, false):
		_callout("tinder", Vector2(150, 252), Vector2(cx - 12.0, gy - 6.0), 12)
		_callout("twigs", Vector2(126, 168), Vector2(cx - 16.0, 180.0), 12)
		_callout("sticks", Vector2(110, 120), Vector2(cx - 34.0, 168.0), 12)


func _wood_log(a: Vector2, b: Vector2, r: float, alpha: float = 1.0) -> void:
	## A round log from a to b (bark wash, end grain at b).
	var d := (b - a).normalized()
	var n := Vector2(-d.y, d.x)
	var body := PackedVector2Array([a + n * r, b + n * r, b - n * r, a - n * r])
	for p in _arcp(Vector2.ZERO, r, r, d.angle() + PI * 0.5, d.angle() + PI * 1.5, 6):
		body.append(a + p)
	_shape(body, Color(WOOD.darkened(0.1), 0.95 * alpha), Color(INK, alpha), 1.8, 0.4)
	_shape(_oval(b, r * 0.45, r, 14, d.angle()), Color(STRAW, alpha), Color(INK, alpha), 1.4, 0.2)
	_ring(b, r * 0.4, Color(INK, 0.4 * alpha), 1.0)


# --- 17. fire_drill ----------------------------------------------------------

func _d_fire_drill() -> void:
	var t := _t
	var P := 8.5
	var lt := fposmod(t * (P / 8.0), P)   # the 8.5 s story plays in an 8 s loop
	var fade := 1.0 - _seg(lt, P - 0.45, P)
	var gy := 226.0
	var sx := 206.0
	var nest_c := Vector2(380, 214)
	var href := Vector2(sx, 100)
	if _layer(2, false):
		_line(Vector2(20, gy), Vector2(460, gy), INK2, 1.6)
		_stipple(Rect2(24, gy + 3.0, 432, 20), 36, Color(INK, 0.2), 61)
		# bark under the notch to catch the ember
		_leaf(Vector2(sx + 4.0, gy + 2.0), 44.0, 9.0, 0.0, Color(WOOD.darkened(0.15), 0.95), INK, 1.2)
		# hearth board (seen a little from above)
		var front := PackedVector2Array([Vector2(92, 210), Vector2(sx - 9.0, 210), Vector2(sx, 223), Vector2(sx + 9.0, 210), Vector2(330, 210),
			Vector2(330, 224), Vector2(92, 224)])
		var top := PackedVector2Array([Vector2(92, 210), Vector2(108, 201), Vector2(346, 201), Vector2(330, 210)])
		var endf := PackedVector2Array([Vector2(330, 210), Vector2(346, 201), Vector2(346, 215), Vector2(330, 224)])
		_shape(top, Color(WOOD.lightened(0.12), 0.95), INK, 1.6, 0.4)
		_shape(endf, Color(WOOD.darkened(0.12), 0.95), INK, 1.6, 0.4)
		_shape(front, Color(WOOD, 0.95), INK, 1.8, 0.4)
		_fill(PackedVector2Array([Vector2(sx - 9.0, 210), Vector2(sx + 9.0, 210), Vector2(sx + 4.0, 205), Vector2(sx - 4.0, 205)]), Color(SOIL, 0.9))
		_fill(_oval(Vector2(sx, 205), 8.0, 3.0, 14), Color(CHARCOAL, 0.85))
		_stroke(PackedVector2Array([Vector2(120, 216), Vector2(180, 217)]), Color(INK, 0.3), 1.0, false, 0.4)
		_stroke(PackedVector2Array([Vector2(240, 217), Vector2(310, 216)]), Color(INK, 0.3), 1.0, false, 0.4)
		_callout("hearth board", Vector2(110, 250), Vector2(140, 222), 12)
		_text(Vector2(nest_c.x, 248), "tinder", 12)
	# spinning: palms rub back and forth on either side of the spindle, sliding down
	var lift := _ss(_seg(lt, 4.5, 5.1))
	var sa := 1.0 - lift
	var osc := sin(t * TAU * 1.4)
	var hy := lerpf(70.0, 146.0, fposmod(lt / 2.3, 1.0)) - 30.0 * lift
	var off := osc * 10.0
	_layer_fx(3, Transform2D(0.0, Vector2(-off, hy + 3.0) - Vector2(0, href.y)), Color(1, 1, 1, sa))
	if _layer(3, false):
		_hand_flat(href, -1.0, 1.0, true)
	_layer(4, true)
	if sa > 0.01:
		_push(Transform2D(-PI * 0.5, Vector2(sx, 204.0 - 30.0 * lift)))
		_twisted_band(158.0, 4.6, 11.0, osc * 22.0, Color(WOOD.lightened(0.2), sa), Color(INK, sa), 1)
		_pop()
	_layer_fx(5, Transform2D(0.0, Vector2(off, hy) - Vector2(0, href.y)), Color(1, 1, 1, sa))
	if _layer(5, false):
		_hand_flat(href, 1.0, 1.0, false)
	_layer(6, true)
	if sa > 0.01:
		var dir := 1.0 if cos(t * TAU * 1.4) > 0.0 else -1.0
		var ap := _arcp(Vector2(sx, hy + 44.0), 15.0, 5.0, 0.3 if dir > 0.0 else PI - 0.3, PI - 0.3 if dir > 0.0 else 0.3, 10)
		_arrow_path(ap, Color(RED.darkened(0.1), 0.8 * sa), 1.8, 6.0, 0.2)
	# smoke from the notch while drilling
	var smoke := _seg(lt, 0.8, 3.2) * (1.0 - _seg(lt, 4.6, 5.6))
	_smoke(Vector2(sx + 6.0, 206.0), 80.0, Color(SMOKE_W, 0.85 * smoke), 6, 1.0, 9.0, 2.5, 10.0, 0.35, 10.0)
	_smoke(Vector2(sx - 6.0, 206.0), 60.0, Color(0.85, 0.85, 0.85, 0.6 * smoke), 4, 4.0, 7.0, 2.0, 8.0, 0.4, -6.0)
	# the ember forms in the notch, then is tipped into the tinder
	var form := _ss(_seg(lt, 2.8, 4.4))
	var move := _ss(_seg(lt, 5.1, 6.0))
	var ep := Vector2(sx, 219).lerp(nest_c + Vector2(0, -6), move) + Vector2(0, -46.0 * sin(PI * move))
	var catch_ := _ss(_seg(lt, 6.0, 7.2)) * fade
	if form > 0.01 and lt < P - 0.45:
		var pulse := 0.8 + 0.2 * sin(t * 9.0)
		_glow(ep, 16.0 * form, Color(FLAME, 0.7 * pulse * (1.0 - catch_)))
		_dot(ep, 3.6 * form, Color(EMBER.lerp(FLAME, 0.3 * pulse), 1.0 - catch_ * 0.8))
	_glow(nest_c + Vector2(0, -16), 70.0 * catch_, Color(FLAME, 0.5 * catch_))
	# tinder nest
	if _layer(7, false):
		var nest := _lumpy(nest_c, 30.0, 13.0, 0.15, 20, 4.4).duplicate()
		for i in nest.size():
			nest[i].y = minf(nest[i].y, gy)
		_shape(nest, Color(STRAW, 0.95), INK, 1.5, 0.4)
		var curls := PackedVector2Array()
		for k in 10:
			var c := nest_c + Vector2(-22.0 + k * 5.0, -2.0 - 5.0 * _rnd(k + 3))
			for j in 3:
				var a0 := float(j) * 1.7 + k
				curls.append(c + Vector2(cos(a0), sin(a0)) * 4.0)
				curls.append(c + Vector2(cos(a0 + 1.3), sin(a0 + 1.3)) * 4.0)
		_ml(curls, Color(INK, 0.4), 1.0, true)
	# ...which smokes, then bursts into flame
	_layer(8, true)
	_smoke(nest_c + Vector2(0, -8), 70.0, Color(SMOKE_W, 0.7 * _win(lt, 5.8, 6.8, 0.3)), 5, 7.0, 10.0, 3.0, 10.0, 0.4, 6.0)
	if catch_ > 0.01:
		_flame(nest_c + Vector2(0, -2), 18.0 + 28.0 * catch_, 14.0 + 58.0 * catch_, 6.0, catch_)
	_text(Vector2(250, 60), "spindle", 12, Color(INK, sa))
	_callout("notch", Vector2(150, 186), Vector2(sx - 6.0, 212), 12, CENTER, Color(INK, 1.0 - _seg(lt, 5.0, 5.4)))
	_callout("ember", Vector2(262, 186), Vector2(sx + 4.0, 218), 12, CENTER, Color(INK, _seg(lt, 3.2, 3.6) * (1.0 - _seg(lt, 5.0, 5.3))))
	_layer_fx(9, Transform2D.IDENTITY, Color(1, 1, 1, sa))
	if _layer(9, false):
		_text(Vector2(118, 92), "rub back and forth,", 11, INK2)
		_text(Vector2(118, 106), "pressing down", 11, INK2)


func _hand_flat(c: Vector2, side: float, a: float, behind: bool) -> void:
	## An upright flat hand (fingers up) pressing the spindle, forearm going down
	## and out to `side`.  The hand behind the spindle is drawn a little darker.
	if a <= 0.01:
		return
	var dk := 0.12 if behind else 0.0
	var skin := Color(0.92, 0.78, 0.62).darkened(dk)
	var sleeve := WATER.lerp(PAPER, 0.4).darkened(dk)
	var arm := PackedVector2Array([c + Vector2(-8, 10), c + Vector2(8, 10), c + Vector2(-24.0 + 6.0 * side, 40), c + Vector2(-40.0 + 6.0 * side, 34)])
	_shape(arm, Color(sleeve, a), Color(INK, a), 1.6, 0.3)
	var hand := PackedVector2Array([Vector2(-10, 13), Vector2(-11, -5), Vector2(-9, -15), Vector2(-4, -19), Vector2(4, -19),
		Vector2(9, -15), Vector2(11, -5), Vector2(10, 13)])
	_shape(_xpts(hand, c), Color(skin, a), Color(INK, a), 1.6, 0.3)
	var thumb := PackedVector2Array([c + Vector2(side * 9.0, 0.0), c + Vector2(side * 16.0, -8.0), c + Vector2(side * 14.0, -12.0), c + Vector2(side * 9.0, -8.0)])
	_shape(thumb, Color(skin, a), Color(INK, a), 1.3, 0.2)
	var f := PackedVector2Array()
	for k in 3:
		var x := c.x - 4.5 + 4.5 * k
		f.append(Vector2(x, c.y - 18.0))
		f.append(Vector2(x, c.y - 9.0))
	_ml(f, Color(INK, 0.45 * a), 1.0, true)


# --- 18. cooking -------------------------------------------------------------

func _d_cooking() -> void:
	var t := _t
	var gy := 214.0
	var fc := Vector2(232, gy - 6.0)
	var st := Vector2(120, gy - 9.0)
	var pc := Vector2(358, gy - 34.0)
	var bt := fc + Vector2(-46, -16)
	if _layer(2, false):
		_line(Vector2(20, gy), Vector2(460, gy), INK2, 1.6)
		_stipple(Rect2(24, gy + 3.0, 432, 26), 40, Color(INK, 0.2), 71)
	_layer(3, true)
	_glow(fc + Vector2(0, -20), 120.0, Color(FLAME, 0.38 + 0.05 * sin(t * 5.0)))
	if _layer(4, false):
		# too-close zone around the flames
		var zone := _arcp(Vector2(fc.x, gy), 66.0, 92.0, PI, TAU, 24)
		_fill(zone, Color(RED, 0.08))
		_dashed(zone, Color(RED, 0.85), 1.8, 7.0, 5.0)
		_text(Vector2(fc.x, 98), "too close = burnt", 13, RED.darkened(0.15))
		_line(Vector2(fc.x, 106), Vector2(fc.x, 118), Color(RED, 0.6), 1.2, 0.2)
		# campfire logs
		_line(fc + Vector2(-34, 4), fc + Vector2(30, -6), WOOD.darkened(0.25), 7.0, 0.5)
		_line(fc + Vector2(-30, -6), fc + Vector2(34, 4), WOOD.darkened(0.1), 7.0, 0.5)
	_layer(5, true)
	_flame(fc + Vector2(0, 2), 44.0, 84.0, 1.0)
	_flame(fc + Vector2(-20, 4), 18.0, 34.0, 4.0)
	_flame(fc + Vector2(22, 4), 16.0, 30.0, 7.0)
	if _layer(6, false):
		# a ring of stones, a burnt example inside the zone
		for k in 5:
			_stone(Vector2(fc.x - 52.0 + k * 26.0, gy - 5.0), 10.0, 7.0, 3.0 + k, Color(STONE, 0.95), 0.0, 1)
		_shape(_lumpy(bt, 10.0, 6.0, 0.1, 14, 2.0, -0.3), Color(CHARCOAL, 0.95), INK, 1.3, 0.3)
		_cross(bt + Vector2(0, -24), 0.55, RED, 2.2)
		# the hot stone at the edge, outside the zone
		_shape(_rrect(Rect2(st.x - 28.0, st.y - 7.0, 56.0, 16.0), 6.0, 3), Color(STONE.lerp(EMBER, 0.15), 0.95), INK, 1.7, 0.4)
		_text(Vector2(116, 238), "hot stone", 12)
		# porridge pot on coals
		for k in 6:
			_dot(Vector2(328.0 + k * 12.0, gy - 5.0 - 3.0 * (k % 2)), 6.0, Color(CHARCOAL, 0.95))
		var pot := PackedVector2Array([Vector2(-26, -26), Vector2(26, -26), Vector2(24, -21), Vector2(32, -8), Vector2(33, 6), Vector2(24, 20),
			Vector2(-24, 20), Vector2(-33, 6), Vector2(-32, -8), Vector2(-24, -21)])
		_shape(_xpts(pot, pc), Color(FIRED, 0.97), INK, 2.0, 0.4)
		_fill(_oval(pc + Vector2(0, -26), 24.0, 5.0, 18), Color(0.93, 0.84, 0.62, 1.0))
		_stroke(_oval(pc + Vector2(0, -26), 25.0, 5.5, 18), INK, 1.5, true, 0.2)
		_text(Vector2(360, 238), "pot on coals", 12)
	# the tuber is turned now and then
	var tc := st + Vector2(0, -14)
	_layer_fx(7, _rot_about(tc, sin(t * 1.4) * 0.12))
	if _layer(7, false):
		_tuber(tc, 1.25, -0.15)
	_layer(8, true)
	_wisp(bt + Vector2(2, -8), 22.0, Color(INK, 0.5), 3.0, 1.2)
	_wisps(PackedVector2Array([st + Vector2(-12, -30), st + Vector2(0, -30), st + Vector2(12, -30)]), 40.0, Color(INK, 0.35), 0.0, 1.9, 1.3, 0.8)
	_wisps(PackedVector2Array([pc + Vector2(-12, -34), pc + Vector2(0, -34), pc + Vector2(12, -34)]), 44.0, Color(INK, 0.35), 1.0, 2.3, 1.3, 0.9)
	var coals := PackedVector2Array()
	var cr := PackedFloat32Array()
	for k in 6:
		coals.append(Vector2(329.0 + k * 12.0, gy - 6.0 - 3.0 * (k % 2)))
		cr.append(2.0 + 0.8 * sin(t * 4.0 + k))
	_discs(coals, cr, Color(EMBER.lerp(FLAME, 0.5), 0.9))
	var bubbles: Array = []
	for k in 4:
		var ph := fposmod(t * 0.9 + k * 0.29, 1.0)
		if ph < 0.9:
			bubbles.append(_oval(pc + Vector2(-14.0 + k * 9.0, -26.0 - ph * 3.0), 1.0 + 3.0 * ph, 1.0 + 3.0 * ph, 8))
	_outline_many(bubbles, Color(INK, 0.45), 1.0)


# --- 19. charcoal_mound ------------------------------------------------------

func _d_charcoal_mound() -> void:
	var t := _t
	var P := 9.0
	var lt := fposmod(t * 1.125, P)   # the 9 s story plays in an 8 s loop
	var fade := 1.0 - _seg(lt, P - 0.4, P)
	var gy := 216.0
	var cx := 236.0
	var burn := _seg(lt, 0.0, 5.6)
	var seal := _ss(_seg(lt, 5.6, 6.4))
	var cool := _ss(_seg(lt, 6.4, 8.4))
	var hot := (1.0 - cool) * fade
	var hole := Vector2(cx, gy - 112.0)
	var kx := 340.0
	if not _cache.has("cm"):
		var outer := _arcp(Vector2(cx, gy), 132.0, 112.0, PI, TAU, 28)
		var inner := _arcp(Vector2(cx, gy), 116.0, 96.0, PI, TAU, 28)
		var shell := outer.duplicate()
		for i in range(inner.size() - 1, -1, -1):
			shell.append(inner[i])
		var logs: Array = []
		for k in 15:
			var x := cx - 105.0 + k * 15.0
			if absf(x - cx) < 7.0:
				continue
			var dx := (x - cx) / 116.0
			var top := gy - 96.0 * sqrt(maxf(0.0, 1.0 - dx * dx)) + 5.0
			if top > gy - 10.0:
				continue
			logs.append(Vector3(x, top, sin(k * 1.3)))
		_cache["cm"] = [outer, inner, shell, logs]
	var geo: Array = _cache["cm"]
	var logs: Array = geo[3]
	var bot := gy - 2.0
	if _layer(2, false):
		_line(Vector2(20, gy), Vector2(460, gy), INK2, 1.6)
		_stipple(Rect2(24, gy + 3.0, 432, 26), 40, Color(INK, 0.2), 81)
	# glow inside, and the charring creeping down from the top
	_layer(3, true)
	_glow(Vector2(cx, gy - 40.0), 110.0, Color(EMBER, 0.45 * hot * (0.85 + 0.15 * sin(t * 3.0))), 0.8)
	if _layer(4, false):
		for l in logs:
			var lg: Vector3 = l
			_fill(_rrect(Rect2(lg.x - 6.0, lg.y, 12.0, bot - lg.y), 3.0, 2), Color(WOOD, 0.95))
	_layer(5, true)
	var front := lerpf(gy - 100.0, gy + 4.0, _ss(burn))
	var charred: Array = []
	var embers := PackedVector2Array()
	for l in logs:
		var lg: Vector3 = l
		var mid := clampf(front + 6.0 * lg.z, lg.y, bot)
		if mid > lg.y + 1.0:
			charred.append(_rrect(Rect2(lg.x - 6.0, lg.y, 12.0, mid - lg.y), 3.0, 2))
			if hot > 0.05 and mid > lg.y + 4.0:
				embers.append(Vector2(lg.x - 3.0, mid - 2.0))
				embers.append(Vector2(lg.x + 3.0, mid - 2.0))
	_fill_convex_many(charred, Color(CHARCOAL, 0.95))
	_ml(embers, Color(EMBER.lerp(FLAME, 0.4), 0.8 * hot), 2.0, true)
	if _layer(6, false):
		for l in logs:
			var lg: Vector3 = l
			_stroke(_rrect(Rect2(lg.x - 6.0, lg.y, 12.0, bot - lg.y), 3.0, 2), Color(INK, 0.55), 1.1, true, 0.3)
		# earth shell, vents at the base, the smoke hole
		_shape(geo[2], Color(EARTH, 0.95), INK, 2.0, 0.5)
		_hatch_poly(geo[2], 7.0, Color(INK, 0.25), 1.0, 1.0)
		_stroke(geo[1], Color(INK, 0.7), 1.4, false, 0.4)
		for s in [-1.0, 1.0]:
			_fill(_oval(Vector2(cx + s * 124.0, gy - 7.0), 7.0, 6.0, 12), Color(CHARCOAL, 0.95))
		_fill(_oval(hole + Vector2(0, 4), 7.0, 3.0, 10), Color(CHARCOAL, 0.9))
		# smoke colour key
		_text(Vector2(kx - 14.0, 30), "smoke", 11, INK2, RIGHT)
		var kc := [Color(0.97, 0.97, 0.95), Color(0.92, 0.84, 0.55), Color(0.60, 0.68, 0.86), Color(1, 1, 1, 0)]
		var kn := ["white", "yellow", "blue", "clear"]
		for k in 4:
			var p := Vector2(kx + k * 34.0, 30)
			var kcol: Color = kc[k]
			_dot(p, 7.0, Color(kcol, kcol.a * 0.95))
			_ring(p, 7.0, Color(INK, 0.7), 1.2)
			_text(p + Vector2(0, 15), kn[k], 10, INK2)
		_callout("vents", Vector2(64, 236), Vector2(cx - 126.0, gy - 8.0), 12)
		_callout("earth", Vector2(76, 128), Vector2(cx - 112.0, gy - 52.0), 12)
	_layer(7, true)
	# vents glow until they are plugged
	for s in [-1.0, 1.0]:
		var vp := Vector2(cx + s * 124.0, gy - 7.0)
		_dot(vp, 4.0, Color(FLAME.lerp(EMBER, 0.4), hot * (1.0 - seal) * (0.7 + 0.3 * sin(t * 6.0 + s))))
		if lt > 5.5:
			var plug := vp + Vector2(s * 40.0 * (1.0 - seal), -10.0 * sin(PI * seal))
			_shape(_lumpy(plug, 8.0, 7.0, 0.15, 12, 3.0 + s), Color(EARTH.lightened(0.1), fade), Color(INK, fade), 1.4, 0.3)
	# smoke: thick white -> yellowish -> thin blue -> clear
	var stage_t := _seg(lt, 0.0, 5.2) * 3.0
	var cw := Color(0.97, 0.97, 0.95)
	var cy_ := Color(0.92, 0.84, 0.55)
	var cb := Color(0.60, 0.68, 0.86)
	var scol: Color
	var dens: float
	if stage_t < 1.0:
		scol = cw
		dens = 1.0
	elif stage_t < 2.0:
		scol = cw.lerp(cy_, _ss(stage_t - 1.0))
		dens = lerpf(1.0, 0.75, stage_t - 1.0)
	else:
		scol = cy_.lerp(cb, _ss((stage_t - 2.0) * 2.0))
		dens = lerpf(0.75, 0.2, stage_t - 2.0)
	dens *= 1.0 - _seg(lt, 5.0, 5.6)
	_smoke(hole, 100.0, Color(scol, 0.85 * dens), 7, 2.0, 12.0 * dens + 4.0, 3.0 + 4.0 * dens, 9.0 + 12.0 * dens, 0.3, 10.0)
	if lt > 5.5:
		_shape(_lumpy(hole + Vector2(0, 3.0 - 30.0 * (1.0 - seal)), 10.0, 6.0, 0.15, 12, 9.0), Color(EARTH.lightened(0.1), fade), Color(INK, fade), 1.4, 0.3)
	var cur := clampi(int(stage_t), 0, 2)
	if lt > 5.2:
		cur = 3
	var mk := Vector2(kx + cur * 34.0, 30)
	_ring(mk, 11.0, Color(RED, 0.9), 1.8)
	_text(mk + Vector2(0, 15), ["white", "yellow", "blue", "clear"][cur], 10, INK)
	var sa := _win(lt, 3.6, 6.6, 0.3)
	_callout("seal when smoke thins", Vector2(118, 66), hole + Vector2(-10, -4), 12, CENTER, Color(RED.darkened(0.15), sa))
	_text(Vector2(cx, gy + 24.0), "charcoal", 13, Color(INK, _seg(lt, 7.0, 7.4) * fade))


# --- 20. charcoal_vs_ash -----------------------------------------------------

func _d_charcoal_vs_ash() -> void:
	var t := _t
	var P := 8.5
	var lt := fposmod(t * (P / 8.0), P)   # the 8.5 s story plays in an 8 s loop
	var fade := 1.0 - _seg(lt, P - 0.4, P)
	var burn := _ss(_seg(lt, 0.3, 5.2))
	var gy := 208.0
	var lc := Vector2(122, gy)
	var rc := Vector2(358, gy)
	if _layer(2, false):
		_dashed(PackedVector2Array([Vector2(240, 30), Vector2(240, 246)]), INK2, 1.2, 6.0, 5.0)
		_text(Vector2(122, 26), "open fire", 13)
		_text(Vector2(358, 26), "covered, little air", 13)
		_line(Vector2(22, gy), Vector2(226, gy), INK2, 1.6)
		_line(Vector2(254, gy), Vector2(458, gy), INK2, 1.6)
	# --- left: burns away to ash
	_layer(3, true)
	_glow(lc + Vector2(0, -30), 80.0, Color(FLAME, 0.4 * (1.0 - burn) * fade))
	var stick_h := lerpf(78.0, 8.0, burn)
	var sticks_a := 1.0 - _seg(burn, 0.8, 1.0)
	var sticks := PackedVector2Array()
	for k in 5:
		var bx := lc.x - 36.0 + k * 18.0
		var tip := Vector2(lc.x - 4.0 + 8.0 * _rnd(k), gy - stick_h)
		sticks.append(Vector2(bx, gy - 2.0))
		sticks.append(Vector2(bx, gy - 2.0).lerp(tip, 0.95))
	_ml(sticks, Color(WOOD.lerp(CHARCOAL, burn * 0.7), sticks_a * fade), 4.0, true)
	var ash := burn * fade
	if ash > 0.02:
		_shape(_arcp(Vector2(lc.x, gy), 34.0 * ash + 4.0, 16.0 * ash + 2.0, PI, TAU, 14), Color(ASH, 0.97), Color(INK, fade), 1.6, 0.4)
		_stipple(Rect2(lc.x - 22.0 * ash, gy - 10.0 * ash, 44.0 * ash, 8.0 * ash), 10, Color(INK, 0.35 * ash), 91, 1.3)
	var fl := (1.0 - burn) * fade
	_flame(Vector2(lc.x, gy - 2.0), 22.0 + 40.0 * fl, 14.0 + 90.0 * fl, 2.0, clampf(fl * 1.5, 0.0, 1.0))
	_smoke(Vector2(lc.x, gy - 80.0 * fl - 20.0), 60.0, Color(SMOKE_B, 0.5 * fade), 4, 5.0, 8.0, 3.0, 10.0, 0.3, 4.0)
	_text(Vector2(lc.x, 230), "ash", 14, Color(INK, _seg(lt, 5.0, 5.5) * fade))
	var shell_a := (1.0 - _ss(_seg(lt, 5.2, 6.2))) * fade
	_glow(rc + Vector2(0, -28), 60.0, Color(EMBER, 0.45 * (1.0 - burn * 0.5) * shell_a * (0.8 + 0.2 * sin(t * 4.0))))
	# plenty of air reaches the open fire
	_layer_fx(4, Transform2D.IDENTITY, Color(1, 1, 1, (0.9 - 0.5 * burn) * fade))
	if _layer(4, false):
		for s in [-1.0, 1.0]:
			for k in 2:
				var y := gy - 8.0 - k * 22.0
				_arrow(Vector2(lc.x + s * 98.0, y), Vector2(lc.x + s * 46.0, y + 2.0), SKY.darkened(0.35), 2.0, 7.0, s * 4.0)
	# --- right: smoulders to charcoal under earth (the wood keeps its shape)
	_layer_fx(5, Transform2D.IDENTITY, Color(Color.WHITE.lerp(Color(0.26, 0.33, 0.5), burn), fade))
	if _layer(5, false):
		var stack := [[Vector2(-46, -8), Vector2(46, -8)], [Vector2(-42, -20), Vector2(40, -20)], [Vector2(-34, -32), Vector2(36, -32)],
			[Vector2(-26, -44), Vector2(24, -44)], [Vector2(-14, -55), Vector2(16, -55)]]
		for s in stack:
			var a: Vector2 = rc + s[0]
			var b: Vector2 = rc + s[1]
			_line(a, b, INK, 9.0, 0.4)
			_line(a, b, WOOD, 6.6, 0.4)
			_dot(b, 3.6, WOOD.lightened(0.15))
			_ring(b, 3.6, Color(INK, 0.7), 1.0)
	# the earth cover (lifted off at the end)
	_layer_fx(6, Transform2D(0.0, Vector2(0, -22.0 * _ss(_seg(lt, 5.2, 6.2)))), Color(1, 1, 1, shell_a))
	if _layer(6, false):
		var outer := _arcp(rc, 70.0, 76.0, PI, TAU, 22)
		var inner := _arcp(rc, 58.0, 64.0, PI, TAU, 22)
		var shell := outer.duplicate()
		for i in range(inner.size() - 1, -1, -1):
			shell.append(inner[i])
		_shape(shell, Color(EARTH, 0.95), INK, 1.8, 0.4)
		_stipple(Rect2(rc.x - 50.0, rc.y - 70.0, 100.0, 14.0), 14, Color(INK, 0.3), 97)
		var vp := rc + Vector2(64, -6.0)
		_dot(vp, 3.5, CHARCOAL)
		_arrow(vp + Vector2(30, 2), vp + Vector2(9, 0), Color(SKY.darkened(0.35), 0.8), 1.6, 6.0)
	_layer(7, true)
	if shell_a > 0.01:
		_smoke(rc + Vector2(0, -76.0 - 22.0 * _ss(_seg(lt, 5.2, 6.2))), 40.0, Color(SMOKE_W, 0.6 * shell_a * (1.0 - burn * 0.6)), 4, 9.0, 5.0, 2.0, 6.0, 0.35, 4.0)
	_text(Vector2(rc.x, 230), "charcoal", 14, Color(INK, _seg(lt, 5.8, 6.3) * fade))


# --- 21. compost -------------------------------------------------------------

func _d_compost() -> void:
	var t := _t
	var P := 9.0
	var lt := fposmod(t * 1.125, P)   # the 9 s story plays in an 8 s loop
	var gy := 222.0
	var hc := Vector2(222, gy)
	# air in the heap runs down while it works; turning it brings air back
	var air := 1.0
	if lt < 4.2:
		air = lerpf(1.0, 0.2, _seg(lt, 0.3, 4.2))
	elif lt < 6.0:
		air = lerpf(0.2, 1.0, _ss(_seg(lt, 5.0, 6.0)))
	var turning := _win(lt, 4.2, 6.2, 0.2)
	if not _cache.has("heap"):
		var outline := _cb(Vector2(hc.x - 118.0, gy), Vector2(hc.x - 92.0, gy - 140.0), Vector2(hc.x + 92.0, gy - 140.0), Vector2(hc.x + 118.0, gy), 22)
		var greens: Array = []
		var browns: Array = []
		for k in 6:
			var y0 := gy - k * 18.0
			var strip := _rectp(Rect2(hc.x - 130.0, y0 - 18.0, 260.0, 18.0))
			for part in Geometry2D.intersect_polygons(outline, strip):
				(greens if k % 2 == 0 else browns).append(part)
		_cache["heap"] = [outline, greens, browns]
	var heap: Array = _cache["heap"]
	var outline_p: PackedVector2Array = heap[0]
	if _layer(2, false):
		_line(Vector2(20, gy), Vector2(460, gy), INK2, 1.6)
		_stipple(Rect2(24, gy + 3.0, 432, 22), 36, Color(INK, 0.2), 101)
		# greens & browns
		_leaf(Vector2(46, 92), 28.0, 12.0, -0.5, LEAF)
		_ico_scraps(Vector2(70, 104))
		_text(Vector2(56, 128), "greens", 12)
		_leaf(Vector2(46, 166), 28.0, 11.0, 0.4, Color(0.70, 0.55, 0.32))
		var straw := PackedVector2Array()
		for k in 5:
			straw.append(Vector2(58.0 + k * 3.0, 176))
			straw.append(Vector2(70.0 + k * 3.0, 154))
		_ml(straw, Color(STRAW.darkened(0.2), 1.0), 1.6, true)
		_text(Vector2(56, 196), "browns", 12)
		_text(Vector2(56, 214), "layer them", 10, INK2)
	# the layers shuffle a little while the heap is turned
	var mix := sin(PI * _seg(lt, 4.5, 5.8)) * 3.0
	_layer_fx(3, Transform2D(0.0, Vector2(mix, 0)))
	if _layer(3, false):
		for poly in heap[1]:
			_fill(poly, Color(LEAF, 0.9))
	_layer_fx(4, Transform2D(0.0, Vector2(-mix, 0)))
	if _layer(4, false):
		for poly in heap[2]:
			_fill(poly, Color(0.62, 0.48, 0.30, 0.9))
	if _layer(5, false):
		var texture := PackedVector2Array()
		for k in 40:
			var p := Vector2(hc.x - 90.0 + 180.0 * _rnd(k * 3), gy - 6.0 - 100.0 * _rnd(k * 5 + 7))
			if Geometry2D.is_point_in_polygon(p, outline_p) and Geometry2D.is_point_in_polygon(p + Vector2(6, 0), outline_p):
				texture.append(p)
				texture.append(p + Vector2(5.0, -1.5 + 3.0 * _rnd(k)))
		_ml(texture, Color(INK, 0.35), 1.1, true)
		_stroke(outline_p, INK, 2.2, false, 0.5)
	# air comes in at the sides while there is some
	_layer_fx(6, Transform2D.IDENTITY, Color(1, 1, 1, 0.95 * air))
	if _layer(6, false):
		for s in [-1.0, 1.0]:
			for k in 2:
				var y := gy - 30.0 - k * 34.0
				var b := Vector2(hc.x + s * (100.0 - k * 22.0), y)
				_arrow(b + Vector2(s * 34.0, -6.0), b, SKY.darkened(0.4), 2.0, 7.0, s * 5.0)
	# heat and steam while it works (needs air)
	_layer(7, true)
	var work := air * (0.8 + 0.2 * sin(t * 2.0))
	_glow(hc + Vector2(0, -52), 70.0, Color(EMBER, 0.22 * work), 0.7)
	for k in 4:
		_wisp(hc + Vector2(-36.0 + k * 24.0, -116.0), 46.0 * (0.4 + 0.6 * air), Color(INK, 0.45 * air), k * 1.7, 1.4, 0.7)
	_text(Vector2(hc.x - 70.0, 70), "warm, steaming", 12, Color(INK, 0.4 + 0.6 * air))
	_text(Vector2(hc.x + 150.0, gy - 92.0), "air", 12, Color(SKY.darkened(0.5), 0.4 + 0.6 * air))
	# water drops now and then
	for k in 2:
		var ph := fposmod(t * 0.5 + k * 0.5, 1.0)
		if ph < 0.6:
			_drop(Vector2(hc.x - 20.0 + k * 40.0, lerpf(40.0, gy - 112.0, ph / 0.6)), 3.6)
	# the fork turns it over
	var fin := _ss(_seg(lt, 4.2, 4.7))
	var fout := _ss(_seg(lt, 5.7, 6.2))
	var flift := sin(PI * _seg(lt, 4.7, 5.7))
	var fork_tip := Vector2(hc.x + 70.0, gy - 40.0) + Vector2(110.0, -60.0) * (1.0 - fin + fout) + Vector2(0, -24.0 * flift)
	var fa := clampf(fin * 2.0, 0.0, 1.0) * (1.0 - fout)
	if fa > 0.01:
		var fdir := Vector2(1.0, -0.62).normalized().rotated(-0.35 * flift)
		var n := Vector2(-fdir.y, fdir.x)
		_line(fork_tip + fdir * 22.0, fork_tip + fdir * 150.0, Color(WOOD.darkened(0.1), fa), 4.0, 0.4)
		var prongs := PackedVector2Array([fork_tip + fdir * 22.0 + n * 10.0, fork_tip + fdir * 22.0 - n * 10.0])
		for k in 4:
			var o := n * lerpf(-9.0, 9.0, float(k) / 3.0)
			prongs.append(fork_tip + fdir * 22.0 + o)
			prongs.append(fork_tip + o)
		_ml(prongs, Color(INK, fa), 2.0, true)
	if turning > 0.01:
		_arrow_path(_arcp(hc + Vector2(0, -70), 52.0, 30.0, -0.2, -PI + 0.3, 14), Color(RED.darkened(0.1), turning), 2.2, 8.0)
		_arrow_path(_arcp(hc + Vector2(0, -60), 40.0, 22.0, PI - 0.3, 0.3, 14), Color(RED.darkened(0.1), turning * 0.8), 2.0, 7.0)
		_text(Vector2(hc.x + 150.0, 60), "turn it: air back in", 12, Color(RED.darkened(0.15), turning))


# --- 22. farming -------------------------------------------------------------

func _d_farming() -> void:
	var t := _t
	var P := 10.0
	var lt := fposmod(t * 1.25, P)   # the 10 s story plays in an 8 s loop
	var fade := 1.0 - _seg(lt, P - 0.45, P)
	var gy := 168.0
	var cx := 240.0
	var stages := ["till", "sow", "water", "grow", "harvest"]
	if _layer(2, false):
		for k in 5:
			var x := 96.0 + k * 72.0
			_text(Vector2(x, 24), stages[k], 12, INK2)
			if k < 4:
				_arrow(Vector2(x + 22.0, 24), Vector2(x + 48.0, 24), INK2, 1.2, 5.0)
	_layer(3, true)
	var bounds := [0.0, 1.9, 3.1, 4.5, 7.7, 9.5]
	var cur := 0
	for k in 5:
		if lt >= float(bounds[k]):
			cur = k
	var cxs := 96.0 + cur * 72.0
	_text(Vector2(cxs, 24), stages[cur], 12, INK)
	_line(Vector2(cxs - 16.0, 34), Vector2(cxs + 16.0, 34), Color(RED.darkened(0.1), 0.9), 1.8, 0.3)
	# soil (the furrow is dug, then filled back over the seed)
	var till := _ss(_seg(lt, 0.3, 1.7))
	var fill_in := _ss(_seg(lt, 2.4, 3.0))
	var depth := 10.0 * till * (1.0 - fill_in * 0.75)
	var surf := PackedVector2Array([Vector2(12, gy)])
	for i in 13:
		var u := float(i) / 12.0
		var x := lerpf(cx - 46.0, cx + 46.0, u)
		var bump := 3.0 * till * sin(PI * clampf((absf(x - cx) - 22.0) / 24.0, 0.0, 1.0))
		var dip := depth * pow(cos(clampf((x - cx) / 24.0, -1.0, 1.0) * PI * 0.5), 2.0)
		surf.append(Vector2(x, gy + dip - bump))
	surf.append(Vector2(468, gy))
	var soil := surf.duplicate()
	soil.append(Vector2(468, 258))
	soil.append(Vector2(12, 258))
	_fill(soil, Color(EARTH, 0.7))
	var topsoil := surf.duplicate()
	for i in range(surf.size() - 1, -1, -1):
		topsoil.append(surf[i] + Vector2(0, 16))
	_fill(topsoil, Color(SOIL, 0.3))
	if _layer(4, false):
		_stipple(Rect2(16, gy + 6.0, 448, 84), 70, Color(INK, 0.25), 111)
		for k in 5:
			_stone(Vector2(60.0 + k * 92.0 + 20.0 * _rnd(k), gy + 40.0 + 30.0 * _rnd(k + 9)), 6.0, 4.0, float(k) * 3.0, Color(STONE, 0.9), 0.0, 0)
		_tufts(PackedVector2Array([Vector2(40, gy), Vector2(100, gy), Vector2(150, gy), Vector2(330, gy), Vector2(390, gy), Vector2(440, gy)]), Color(LEAF.darkened(0.2), 0.8), 0.9, 1.1)
	_layer(5, true)
	var wet := _ss(_seg(lt, 3.3, 4.4)) * fade
	_fill(_lumpy(Vector2(cx, gy + 22.0), 24.0 + 40.0 * wet, 8.0 + 20.0 * wet, 0.1, 22, 3.0), Color(SOIL, 0.28 * wet))
	_stroke(surf, INK, 2.0, false, 0.5)
	# 1. till with a digging stick
	if lt < 2.0:
		var sw := fposmod(lt / 0.7, 1.0)
		var ang := lerpf(-0.9, 0.15, _ei(_seg(sw, 0.2, 0.55))) if sw < 0.55 else lerpf(0.15, -0.9, _ss(_seg(sw, 0.6, 1.0)))
		var ta := _win(lt, 0.0, 1.95, 0.25)
		var pivot := Vector2(cx + 96.0, 70.0)
		var tip := pivot + Vector2(-96.0, 96.0).rotated(-ang * 0.6)
		var hd := (tip - pivot).normalized()
		_line(pivot + (pivot - tip).normalized() * 30.0, tip - hd * 12.0, Color(WOOD.darkened(0.1), ta), 4.0, 0.4)
		var head := PackedVector2Array([Vector2(-10, -6), Vector2(10, -6), Vector2(12, 4), Vector2(0, 12), Vector2(-12, 4)])
		_shape(_xpts(head, tip - hd * 4.0, hd.angle() - PI * 0.5), Color(STONE, ta), Color(INK, ta), 1.6, 0.3)
		if sw > 0.5 and sw < 0.7:
			for k in 3:
				_dot(Vector2(cx - 18.0 + k * 18.0, gy - 6.0 - 10.0 * sin(PI * (sw - 0.5) * 5.0)), 2.6, Color(EARTH.darkened(0.2), ta))
	# 2. a seed drops in
	var seed_y := lerpf(56.0, gy + 4.0, _ei(_seg(lt, 1.9, 2.4)))
	if lt > 1.85 and lt < 8.2:
		var sa := (1.0 - _seg(lt, 4.6, 5.2)) * fade
		_shape(_oval(Vector2(cx, seed_y), 4.5, 3.0, 10, 0.4), Color(STRAW.darkened(0.2), sa), Color(INK, sa), 1.2, 0.2)
	# 3. water from a vessel
	var pour := _win(lt, 3.1, 4.5, 0.3)
	if pour > 0.01:
		var vp := Vector2(cx + 52.0, 82.0)
		var tilt := -0.9 * _ss(_seg(lt, 3.1, 3.5)) * (1.0 - _ss(_seg(lt, 4.2, 4.5)))
		_shape(_xpts(_POT, vp, tilt, 2.0), Color(FIRED, 0.95 * pour), Color(INK, pour), 1.8, 0.3)
		var lip := vp + Vector2(-8, -22).rotated(tilt)
		if tilt < -0.6:
			var stream := _qb(lip, lip + Vector2(-14, 10), Vector2(cx + 6.0, gy - 4.0), 10)
			_stroke(stream, Color(WATER, 0.9 * pour), 3.0, false, 0.4)
			for k in 3:
				var ph := fposmod(t * 2.0 + k * 0.33, 1.0)
				_drop(_pat(stream, _plen(stream) * ph), 2.6, Color(WATER, pour), Color(INK, 0.0))
	# 4. grow: roots down, shoot up, leaves, a tuber swells; 5. pull it up
	var g := _seg(lt, 4.5, 7.7)
	var pull := _ss(_seg(lt, 7.9, 8.8))
	var up := Vector2(0, -42.0 * pull)
	if g > 0.0 and fade > 0.01:
		var pa := fade
		var root := _ss(_seg(g, 0.0, 0.5))
		var roots := PackedVector2Array()
		for k in 3:
			var rd := Vector2(-14.0 + k * 14.0, 30.0) * root
			var rp := _qb(Vector2(cx, gy + 6.0) + up, Vector2(cx + rd.x * 0.3, gy + 6.0 + rd.y * 0.6) + up, Vector2(cx, gy + 6.0) + rd + up, 6)
			for i in range(1, rp.size()):
				roots.append_array([rp[i - 1], rp[i]])
		_ml(roots, Color(INK, 0.6 * pa), 1.2, true)
		var tub := _ss(_seg(g, 0.45, 1.0))
		if tub > 0.01:
			_shape(_lumpy(Vector2(cx + 3.0, gy + 20.0) + up, 13.0 * tub + 1.0, 9.0 * tub + 1.0, 0.1, 16, 1.0, 0.3), Color(TUBER, 0.95 * pa), Color(INK, pa), 1.5, 0.3)
		var sh := _ss(_seg(g, 0.1, 0.9))
		var top := Vector2(cx, gy - 70.0 * sh) + up
		_pl(_qb(Vector2(cx, gy + 4.0) + up, Vector2(cx - 4.0, gy - 35.0 * sh) + up, top, 8), Color(LEAF.darkened(0.3), pa), 2.4)
		var nl := int(1.0 + sh * 5.0)
		var leaves: Array = []
		var ribs := PackedVector2Array()
		for k in nl:
			var u := (float(k) + 1.0) / 6.0
			var lp := Vector2(cx - 2.0, gy - 70.0 * sh * u) + up
			var side := 1.0 if k % 2 == 0 else -1.0
			var ls := clampf(sh * 6.0 - k, 0.0, 1.0)
			var lc := lp + Vector2(side * 11.0 * ls, -3.0)
			var ll := 22.0 * ls + 1.0
			leaves.append(_leaf_poly(lc, ll, 9.0 * ls + 0.5, side * -0.5))
			ribs.append_array([lc - Vector2(ll * 0.45, 0).rotated(side * -0.5), lc + Vector2(ll * 0.4, 0).rotated(side * -0.5)])
		_fill_convex_many(leaves, Color(LEAF, 0.9 * pa))
		_outline_many(leaves, Color(INK, pa), 1.1)
		_ml(ribs, Color(INK, 0.5 * pa), 1.0, true)
	if pull > 0.0:
		_text(Vector2(cx + 66.0, gy - 10.0), "+ tuber", 13, Color(GREEN.darkened(0.2), pull * fade))


# --- 23. crop_stages ---------------------------------------------------------

func _d_crop_stages() -> void:
	var rows := [["tuber", 74.0], ["grain", 160.0], ["fiber grass", 246.0]]
	var xs := [154.0, 236.0, 318.0, 400.0]
	# a soft light walks through the stages: left to right, again and again
	_layer(2, true)
	var pos := fposmod(_t / 1.2, 4.0)
	var i0 := int(pos)
	var f := _ss(_seg(pos - float(i0), 0.7, 1.0))
	var x0: float = xs[i0]
	var x1: float = xs[(i0 + 1) % 4]
	var gx := lerpf(x0, x1, f) if i0 < 3 else x0
	var ga := 1.0 - f if i0 == 3 else 1.0
	for r in 3:
		var gy: float = rows[r][1]
		_glow(Vector2(gx, gy - 26.0), 40.0, Color(FLAME, 0.42 * ga), 1.1)
		if i0 == 3:
			_glow(Vector2(float(xs[0]), gy - 26.0), 40.0, Color(FLAME, 0.42 * f), 1.1)
	if not _layer(3, false):
		return
	var acc := {"stem": [], "root": [], "leaf": [], "rib": [], "grain_g": [], "grain_r": [], "plume": [],
		"blade0": [], "blade1": [], "blade2": [], "blade3": [], "gstalk": [], "gstalk_r": [], "arrow": [], "head": []}
	for r in 3:
		var gy: float = rows[r][1]
		if r == 0:
			_fill(_rrect(Rect2(104, gy, 352, 22), 4.0, 2), Color(EARTH, 0.55))
			_stipple(Rect2(108, gy + 3.0, 344, 16), 24, Color(INK, 0.25), 121)
		_line(Vector2(104, gy), Vector2(456, gy), INK, 1.6, 0.4)
		_text(Vector2(56, gy - 18.0), rows[r][0], 14)
		for k in 3:
			var ax: float = (float(xs[k]) + float(xs[k + 1])) * 0.5
			var ay := gy + 10.0 if r > 0 else gy - 34.0
			acc["arrow"].append_array([Vector2(ax - 8.0, ay), Vector2(ax + 3.0, ay)])
			acc["head"].append(PackedVector2Array([Vector2(ax + 8.0, ay), Vector2(ax + 2.0, ay - 3.0), Vector2(ax + 2.0, ay + 3.0)]))
		for s in 4:
			var b := Vector2(float(xs[s]), gy)
			match r:
				0: _crop_tuber(b, s, acc)
				1: _crop_grain(b, s, acc)
				2: _crop_fiber(b, s, acc)
		_check(Vector2(446, gy - 52.0 if r > 0 else gy - 40.0), 0.8, GREEN, 2.4)
	_text(Vector2(426, 14), "ready", 11, GREEN.darkened(0.2))
	# flush the batched strokes and shapes (a few calls for dozens of leaves)
	_ml(PackedVector2Array(acc["arrow"]), INK2, 1.2)
	_fill_convex_many(acc["head"], INK2)
	_ml(PackedVector2Array(acc["root"]), Color(INK, 0.5), 1.0)
	_ml(PackedVector2Array(acc["stem"]), LEAF.darkened(0.3), 1.8)
	for s in 4:
		_ml(PackedVector2Array(acc["blade%d" % s]), LEAF.darkened(0.15).lerp(STRAW, 0.15 * s), 1.6)
	_ml(PackedVector2Array(acc["gstalk"]), LEAF.darkened(0.2), 1.6)
	_ml(PackedVector2Array(acc["gstalk_r"]), STRAW.darkened(0.25), 1.6)
	_ml(PackedVector2Array(acc["plume"]), STRAW.darkened(0.1), 1.2)
	_fill_convex_many(acc["leaf"], Color(LEAF, 0.92))
	_outline_many(acc["leaf"], INK, 1.0)
	_ml(PackedVector2Array(acc["rib"]), Color(INK, 0.45), 1.0)
	_fill_convex_many(acc["grain_g"], LEAF.lightened(0.15))
	_outline_many(acc["grain_g"], INK, 0.9)
	_fill_convex_many(acc["grain_r"], STRAW)
	_outline_many(acc["grain_r"], INK, 0.9)


static func _curve_segs(out: Array, a: Vector2, c: Vector2, b: Vector2, n: int = 6) -> void:
	## Append a quadratic curve to a multiline accumulator (pairs of points).
	var prev := a
	for i in range(1, n + 1):
		var u := float(i) / float(n)
		var p := a.lerp(c, u).lerp(c.lerp(b, u), u)
		out.append(prev)
		out.append(p)
		prev = p


static func _leaf_poly(c: Vector2, length: float, width: float, rot: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 8:
		var u := float(i) / 7.0
		pts.append(Vector2(lerpf(-0.5, 0.5, u) * length, -sin(PI * u) * width * 0.5))
	for i in range(6, 0, -1):
		var u := float(i) / 7.0
		pts.append(Vector2(lerpf(-0.5, 0.5, u) * length, sin(PI * u) * width * 0.5))
	return Transform2D(rot, c) * pts


func _crop_tuber(b: Vector2, s: int, acc: Dictionary) -> void:
	var size: float = [0.35, 0.6, 0.85, 1.0][s]
	var tub: float = [0.0, 0.35, 0.7, 1.0][s]
	# below ground: roots and the purple tuber
	_curve_segs(acc["root"], b, b + Vector2(-3, 8.0 * size), b + Vector2(1, 16.0 * size), 3)
	if tub > 0.0:
		_shape(_lumpy(b + Vector2(5, 11), 11.0 * tub + 1.5, 7.0 * tub + 1.0, 0.1, 14, float(s), 0.25), Color(TUBER, 0.95), INK, 1.3, 0.3)
		if s == 3:
			_shape(_lumpy(b + Vector2(-12, 9), 5.0, 3.5, 0.1, 10, 2.0, -0.3), Color(TUBER, 0.95), INK, 1.1, 0.2)
	# stem and leaves
	var top := b + Vector2(0, -40.0 * size)
	_curve_segs(acc["stem"], b, b + Vector2(0, -20.0 * size), top)
	var n := 2 + s * 2
	for k in n:
		var u := 0.35 + 0.65 * float(k) / float(maxi(n - 1, 1))
		var side := 1.0 if k % 2 == 0 else -1.0
		var ll := 15.0 * size + 3.0
		var lc := b.lerp(top, u) + Vector2(side * ll * 0.45, -2.0)
		var rot := side * -0.45
		acc["leaf"].append(_leaf_poly(lc, ll, ll * 0.42, rot))
		acc["rib"].append_array([lc - Vector2(ll * 0.45, 0).rotated(rot), lc + Vector2(ll * 0.4, 0).rotated(rot)])
	if s == 3:
		_dot(top + Vector2(0, -3), 2.6, Color(0.85, 0.75, 0.95))
		_ring(top + Vector2(0, -3), 2.6, INK, 1.0)


func _crop_grain(b: Vector2, s: int, acc: Dictionary) -> void:
	var h: float = [14.0, 30.0, 50.0, 62.0][s]
	var stalks: int = [1, 3, 4, 5][s]
	var blades: Array = acc["gstalk_r"] if s == 3 else acc["gstalk"]
	for k in stalks:
		var dx := (float(k) - (stalks - 1) * 0.5) * 5.0
		var top := b + Vector2(dx * 1.6, -h * (0.85 + 0.15 * _rnd(k + s * 7)))
		_curve_segs(blades, b + Vector2(dx * 0.4, 0), b + Vector2(dx, -h * 0.5), top)
		if s >= 2:
			var droop := 0.0 if s == 2 else 0.6
			var hd := Vector2(0.25 + droop, -1.0).normalized()
			for j in 5:
				acc["grain_g" if s == 2 else "grain_r"].append(_oval(top + hd * (j * 3.6), 2.6, 1.6, 8, hd.angle()))
	# a couple of leaves
	for k in mini(s + 1, 2):
		var side := 1.0 if k == 0 else -1.0
		_curve_segs(blades, b, b + Vector2(side * 6.0, -h * 0.3), b + Vector2(side * 14.0, -h * 0.25))


func _crop_fiber(b: Vector2, s: int, acc: Dictionary) -> void:
	var h: float = [16.0, 34.0, 52.0, 66.0][s]
	var blades: int = [3, 5, 8, 11][s]
	for k in blades:
		var u := float(k) / float(maxi(blades - 1, 1)) - 0.5
		var tip := b + Vector2(u * (10.0 + h * 0.5), -h * (1.0 - 0.35 * absf(u)) * (0.85 + 0.15 * _rnd(k + s * 5)))
		_curve_segs(acc["blade%d" % s], b + Vector2(u * 6.0, 0), b + Vector2(u * 4.0, -h * 0.5), tip)
		if s == 3 and k % 2 == 0:
			for j in 4:
				acc["plume"].append_array([tip, tip + Vector2(-2.0 + j * 1.3, -3.0 - j * 2.0)])


# --- 24. tree_regrow ---------------------------------------------------------

func _d_tree_regrow() -> void:
	var t := _t
	var P := 8.0
	var lt := fposmod(t, P)
	var grow := _ss(_seg(lt, 0.8, 5.0)) * (1.0 - _ss(_seg(lt, 7.3, 8.0)))
	var gy := 240.0
	var ig := 206.0
	var st := Vector2(354, ig)
	var s2 := Vector2(428, ig)
	var stubs := [[Vector2(146, 190), Vector2(-1.0, -0.35)], [Vector2(170, 168), Vector2(1.0, -0.45)], [Vector2(146, 152), Vector2(-1.0, -0.6)]]
	if _layer(2, false):
		_line(Vector2(20, gy), Vector2(300, gy), INK2, 1.6)
		_tufts(PackedVector2Array([Vector2(40, gy), Vector2(80, gy), Vector2(226, gy), Vector2(270, gy)]), Color(LEAF.darkened(0.2), 0.8), 1.0, 1.2)
		# canopy behind, limbs, trunk
		var blobs := [[Vector2(96, 72), 36.0], [Vector2(160, 44), 34.0], [Vector2(222, 70), 36.0], [Vector2(62, 112), 22.0], [Vector2(252, 112), 22.0]]
		for i in blobs.size():
			var bb: Array = blobs[i]
			var r: float = bb[1]
			_shape(_lumpy(bb[0], r, r * 0.82, 0.08, 26, float(i) * 2.0, 0.0, 0.08), Color(0.36, 0.50, 0.25, 0.95), INK, 1.8, 0.4)
		var limbs := [[Vector2(152, 140), Vector2(100, 84), 8.0], [Vector2(158, 130), Vector2(160, 56), 8.0], [Vector2(164, 138), Vector2(220, 82), 8.0],
			[Vector2(122, 104), Vector2(70, 114), 5.0], [Vector2(196, 104), Vector2(248, 114), 5.0]]
		for l in limbs:
			_line(l[0], l[1], INK, float(l[2]) + 2.6, 0.5)
			_line(l[0], l[1], WOOD, float(l[2]), 0.5)
		var trunk := PackedVector2Array([Vector2(130, gy), Vector2(140, gy - 12.0), Vector2(145, 140), Vector2(150, 126), Vector2(166, 126),
			Vector2(171, 140), Vector2(176, gy - 12.0), Vector2(188, gy)])
		_shape(trunk, Color(WOOD, 0.97), INK, 2.0, 0.5)
		for k in 3:
			_stroke(PackedVector2Array([Vector2(152.0 + k * 5.0, gy - 6.0), Vector2(153.0 + k * 4.0, 180), Vector2(154.0 + k * 3.0, 140)]), Color(INK, 0.3), 1.0, false, 0.6)
		# cut branch stubs
		for i in stubs.size():
			var sp: Vector2 = stubs[i][0]
			var d: Vector2 = (stubs[i][1] as Vector2).normalized()
			var end := sp + d * 12.0
			_line(sp, end, INK, 9.5, 0.3)
			_line(sp, end, WOOD.darkened(0.05), 7.0, 0.3)
			_shape(_oval(end, 3.0, 4.6, 12, d.angle()), Color(STRAW.lightened(0.2), 1.0), INK, 1.2, 0.0)
		# inset: a felled trunk leaves a stump that sends up a sapling
		var ir := Rect2(316, 34, 146, 202)
		_fill(_rrect(ir, 8.0, 3), Color(PAPER.lightened(0.25), 0.6))
		_dashed(_rrect(ir, 8.0, 3), INK2, 1.3, 6.0, 4.0, 0.0, true)
		_text(Vector2(ir.get_center().x, ir.position.y + 16.0), "felled tree", 12)
		_line(Vector2(ir.position.x + 8.0, ig), Vector2(ir.end.x - 8.0, ig), INK2, 1.4)
		_stump(st)
		_arrow(Vector2(st.x + 26.0, ig - 18.0), Vector2(st.x + 48.0, ig - 18.0), INK, 1.6, 6.0)
		_stump(s2, 0.75)
		_text(Vector2(st.x, ig + 18.0), "stump", 12)
		_text(Vector2(s2.x, ig + 18.0), "sapling", 12)
	# new branches grow from the stubs
	_layer(3, true)
	for i in stubs.size():
		var sp: Vector2 = stubs[i][0]
		var d: Vector2 = (stubs[i][1] as Vector2).normalized()
		var end := sp + d * 12.0
		var g := _ss(clampf(grow * 1.4 - i * 0.2, 0.0, 1.0))
		if g > 0.01:
			var tip := end + d.rotated(-0.5 * signf(d.x)) * 42.0 * g + Vector2(0, -16.0 * g)
			var br := _qb(end, end + d * 16.0 * g, tip, 8)
			_pl(br, INK, 4.6 * g + 1.0)
			_pl(br, Color(WOOD.lightened(0.1), 1.0), 2.8 * g + 0.4)
			var lg := _ss(_seg(g, 0.35, 1.0))
			if lg > 0.01:
				_shape(_lumpy(tip + Vector2(0, -4.0), 15.0 * lg + 1.0, 12.0 * lg + 1.0, 0.1, 18, 3.0 + i, 0.0, 0.08), Color(LEAF.lightened(0.1), 0.95), INK, 1.5, 0.3)
	_callout("cut branch", Vector2(52, 196), Vector2(136, 192), 12, CENTER, Color(INK, 1.0 - _ss(_seg(grow, 0.3, 0.6))))
	_text(Vector2(56, 196), "regrows", 13, Color(GREEN.darkened(0.25), _ss(_seg(grow, 0.5, 0.8))))
	# ...and the stump sends up a sapling
	var sg := _ss(_seg(lt, 1.2, 5.6)) * (1.0 - _ss(_seg(lt, 7.3, 8.0)))
	var stem_top := s2 + Vector2(0, -14.0 - 90.0 * sg)
	_pl(_qb(s2 + Vector2(0, -10), s2 + Vector2(-3, -14.0 - 45.0 * sg), stem_top, 8), Color(WOOD.darkened(0.1), 1.0), 1.5 + 2.0 * sg)
	if sg > 0.05:
		for k in 3:
			var u := 0.45 + 0.27 * k
			var p := (s2 + Vector2(0, -10)).lerp(stem_top, u)
			var side := 1.0 if k % 2 == 0 else -1.0
			_leaf(p + Vector2(side * 8.0 * sg, 0), 16.0 * sg + 2.0, 7.0 * sg + 1.0, side * -0.5, LEAF, INK, 1.0)
		_shape(_lumpy(stem_top + Vector2(0, -6.0 * sg), 14.0 * sg + 1.0, 12.0 * sg + 1.0, 0.1, 16, 8.0, 0.0, 0.06), Color(LEAF.lightened(0.05), 0.95), INK, 1.4, 0.3)


func _stump(b: Vector2, s: float = 1.0) -> void:
	var w := 20.0 * s
	var h := 22.0 * s
	var body := PackedVector2Array([Vector2(b.x - w - 4.0 * s, b.y), Vector2(b.x - w, b.y - h), Vector2(b.x + w, b.y - h), Vector2(b.x + w + 4.0 * s, b.y)])
	_shape(body, Color(WOOD, 0.97), INK, 1.8, 0.4)
	_shape(_oval(Vector2(b.x, b.y - h), w, 6.0 * s, 20), Color(STRAW.lightened(0.15), 1.0), INK, 1.5, 0.2)
	_stroke(_oval(Vector2(b.x, b.y - h), w * 0.6, 3.6 * s, 16), Color(INK, 0.4), 1.0, true, 0.2)
	_stroke(_oval(Vector2(b.x, b.y - h), w * 0.25, 1.6 * s, 10), Color(INK, 0.4), 1.0, true, 0.1)


# --- 25. log_split -----------------------------------------------------------

func _d_log_split() -> void:
	var t := _t
	var P := 7.5
	var lt := fposmod(t, P)
	var fade := 1.0 - _seg(lt, P - 0.4, P)
	var r := 40.0
	if not _cache.has("ls"):
		var circle := _lumpy(Vector2.ZERO, r, r, 0.03, 40, 2.0)
		var cuts := [-50.0, -22.0, -4.0, 14.0, 32.0, 50.0]
		var pieces: Array = []
		for k in 5:
			var strip := _rectp(Rect2(float(cuts[k]), -60.0, float(cuts[k + 1]) - float(cuts[k]), 120.0))
			var parts := Geometry2D.intersect_polygons(circle, strip)
			pieces.append(_grain_piece(parts[0] if parts.size() > 0 else PackedVector2Array(), r))
		var wedges: Array = []
		for k in 5:
			var w := PackedVector2Array([Vector2.ZERO])
			for j in 7:
				var a := TAU * (float(k) + float(j) / 6.0) / 5.0 + 0.3
				w.append(Vector2(cos(a), sin(a)) * r)
			wedges.append(_grain_piece(w, r))
		_cache["ls"] = [_grain_piece(circle, r), pieces, wedges]
	var geo: Array = _cache["ls"]
	var pieces: Array = geo[1]
	var wedges: Array = geo[2]
	var c1 := Vector2(86, 76)
	var c2 := Vector2(86, 200)
	var hit := 0.9
	if _layer(2, false):
		_dashed(PackedVector2Array([Vector2(24, 136), Vector2(456, 136)]), INK2, 1.2, 6.0, 5.0)
		_text(Vector2(86, 22), "careful strikes", 13)
		_text(Vector2(86, 148), "quick strikes", 13)
		_arrow(Vector2(146, 70), Vector2(196, 70), INK, 1.8, 7.0)
		_arrow(Vector2(146, 196), Vector2(196, 196), INK, 1.8, 7.0)
		_text(Vector2(420, 82), "boards", 14)
		_text(Vector2(420, 172), "firewood", 14)
	# --- careful strikes along the grain: boards come off one by one
	var split := lt >= 2.6
	_layer_fx(3, Transform2D.IDENTITY, Color(1, 1, 1, 0.0 if split else 1.0))
	if _layer(3, false):
		_end_grain(Transform2D(0.0, c1), geo[0])
	var peel := {3: 2.6, 2: 3.4, 1: 4.2}
	for k in 5:
		var pc: Dictionary = pieces[k]
		var poly: PackedVector2Array = pc["poly"]
		var pos := c1
		if peel.has(k) and poly.size() >= 3:
			var start: float = peel[k]
			var u := _ss(_seg(lt, start, start + 0.7))
			var cx := 0.0
			var maxy := -100.0
			for p in poly:
				cx += p.x
				maxy = maxf(maxy, p.y)
			cx /= float(poly.size())
			var target := Vector2(286.0 + (3 - k) * 30.0 - cx, 120.0 - maxy)
			pos = c1.lerp(target, u) + Vector2(0, -36.0 * sin(PI * u))
		_layer_fx(4 + k, Transform2D(0.0, pos - c1), Color(1, 1, 1, fade if split else 0.0))
		if _layer(4 + k, false):
			_end_grain(Transform2D(0.0, c1), pc)
	_layer(9, true)
	if not split:
		var cutx := [-22.0, -4.0, 14.0, 32.0]
		for i in 4:
			var t0 := 0.3 + i * 0.55
			var g := _seg(lt, t0, t0 + 0.45)
			if g <= 0.0:
				continue
			var cx: float = cutx[i]
			var hh := sqrt(r * r - cx * cx) - 1.0
			_ln(c1 + Vector2(cx, -hh), c1 + Vector2(cx, -hh + 2.0 * hh * g), Color(INK, 0.9), 1.7)
			if g < 1.0:
				var tap := fposmod(g * 3.0, 1.0)
				var sp := c1 + Vector2(cx, -hh - 3.0)
				_arrow(sp + Vector2(0, -20.0 + 8.0 * tap), sp + Vector2(0, -2.0 + 2.0 * tap), Color(RED.darkened(0.1), 0.9), 2.0, 6.0)
	# --- quick strikes: it bursts into chunky firewood
	var burst_on := lt >= hit + 0.12
	_layer_fx(10, Transform2D.IDENTITY, Color(1, 1, 1, 0.0 if burst_on else 1.0))
	if _layer(10, false):
		_end_grain(Transform2D(0.0, c2), geo[0])
	_layer(11, true)
	if lt > hit and not burst_on:
		var f := _seg(lt, hit, hit + 0.12)
		var cracks := PackedVector2Array()
		for k in 5:
			var a := TAU * float(k) / 5.0 + 0.3
			cracks.append(c2)
			cracks.append(c2 + Vector2(cos(a), sin(a)) * r * f)
		_ml(cracks, INK, 1.8, true)
	if lt > hit - 0.25 and lt < hit + 0.3:
		var a := _seg(lt, hit - 0.25, hit)
		_arrow(c2 + Vector2(0, -r - 34.0 + 22.0 * a), c2 + Vector2(0, -r - 4.0 + 6.0 * a), Color(RED.darkened(0.1), 1.0), 3.0, 9.0)
	if lt > hit and lt < hit + 0.4:
		var f := _seg(lt, hit, hit + 0.4)
		var segs := PackedVector2Array()
		for k in 8:
			var d := Vector2.RIGHT.rotated(TAU * k / 8.0)
			segs.append(c2 + d * (r + 4.0 + 6.0 * f))
			segs.append(c2 + d * (r + 12.0 + 12.0 * f))
		_ml(segs, Color(EMBER, 1.0 - f), 2.0, true)
	var burst := _ss(_seg(lt, hit + 0.12, hit + 0.9))
	for k in wedges.size():
		var w: PackedVector2Array = wedges[k]["poly"]
		var mid := w[3] * 0.5
		var pile := Vector2(300.0 + (k % 3) * 34.0 + (k / 3) * 17.0, 222.0 - (k / 3) * 24.0)
		var pos := c2.lerp(pile, burst) + mid.normalized() * 10.0 * sin(PI * burst) + Vector2(0, -26.0 * sin(PI * burst))
		var m := Transform2D(burst * (1.2 + k * 0.7), pos) * Transform2D(0.0, -mid * burst) * Transform2D(0.0, -c2)
		_layer_fx(12 + k, m, Color(1, 1, 1, fade if burst_on else 0.0))
		if _layer(12 + k, false):
			_end_grain(Transform2D(0.0, c2), wedges[k], 1.0, true)


func _grain_piece(poly: PackedVector2Array, r: float) -> Dictionary:
	## End-grain detail for a piece of log (log centre at the origin): growth
	## rings clipped to the piece and the runs of its outline that carry bark.
	var rings := PackedVector2Array()
	var bark: Array = []
	var n := poly.size()
	if n >= 3:
		for rr in [r * 0.3, r * 0.55, r * 0.78]:
			var circ := _arcp(Vector2.ZERO, rr, rr, 0.0, TAU, 36)
			for piece in Geometry2D.intersect_polyline_with_polygon(circ, poly):
				for i in range(1, piece.size()):
					rings.append(piece[i - 1])
					rings.append(piece[i])
		var i0 := 0
		for i in n:
			if poly[i].length() < r * 0.93:
				i0 = i
				break
		var run := PackedVector2Array()
		for j in range(1, n + 1):
			var p := poly[(i0 + j) % n]
			if p.length() >= r * 0.93:
				run.append(p)
			else:
				if run.size() >= 2:
					bark.append(run)
				run = PackedVector2Array()
		if run.size() >= 2:
			bark.append(run)
	return {"poly": poly, "rings": rings, "bark": bark, "pith": n >= 3 and Geometry2D.is_point_in_polygon(Vector2(0.5, 0.5), poly)}


func _end_grain(xf: Transform2D, g: Dictionary, a: float = 1.0, chunky: bool = false) -> void:
	## A piece of log seen end-on: pale wood, growth rings, bark, ink edge.
	var poly: PackedVector2Array = g["poly"]
	if poly.size() < 3 or a <= 0.01:
		return
	var p: PackedVector2Array = xf * poly
	_fill(Transform2D(0.0, FOFF) * p, Color(STRAW.lightened(0.1), 0.97 * a))
	var rings: PackedVector2Array = g["rings"]
	if rings.size() >= 2:
		_ml(xf * rings, Color(WOOD.darkened(0.15), 0.6 * a), 1.0, true)
	if g["pith"]:
		_dot(xf * Vector2.ZERO, 1.8, Color(WOOD.darkened(0.3), a))
	for b in g["bark"]:
		_pl(xf * PackedVector2Array(b), Color(WOOD.darkened(0.45), a), 4.0, true)
	var o := p.duplicate()
	o.append(p[0])
	_pl(o, Color(INK, a), 2.0 if chunky else 1.7, true)


# --- 26. build_frame ---------------------------------------------------------

func _iso(x: float, y: float, z: float) -> Vector2:
	return Vector2(212, 92) + Vector2(x - y, (x + y) * 0.5) * Vector2(50.0, 50.0) * Vector2(0.94, 1.0) + Vector2(0, -z * 50.0)


func _d_build_frame() -> void:
	var t := _t
	var P := 8.5
	var lt := fposmod(t * (P / 8.0), P)   # the 8.5 s story plays in an 8 s loop
	var fade := 1.0 - _seg(lt, P - 0.45, P)
	var solid := _seg(lt, 6.0, 6.5)
	var ga := (1.0 - solid) * fade
	var tint := Color.WHITE.lerp(Color(0.86, 0.86, 0.86), solid)
	var ghost := Color(INK, 0.35)
	var pole_t := [0.6, 1.1]
	var board_t := [1.8, 2.25, 2.7, 3.15, 3.6, 4.05]
	var lash_t := [4.8, 5.3]
	var counts := [0, 0, 0]
	if _layer(2, false):
		_fill(PackedVector2Array([_iso(-0.1, -0.1, 0), _iso(2.1, -0.1, 0), _iso(2.1, 2.1, 0), _iso(-0.1, 2.1, 0)]), Color(INK, 0.06))
		_text(Vector2(408, 52), "2 x 2 m platform", 12, INK2)
	# each part: a pale ghost until it is installed, then the real thing drops in
	for k in 2:
		var y := 0.3 if k == 0 else 1.7
		var a := _iso(-0.1, y, 0.08)
		var b := _iso(2.15, y, 0.08)
		var t0: float = pole_t[k]
		var started := lt >= t0
		counts[0] += 1 if lt >= t0 + 0.45 else 0
		_layer_fx(3 + 2 * k, Transform2D.IDENTITY, Color(1, 1, 1, 0.0 if started else ga))
		if _layer(3 + 2 * k, false):
			_dashed(PackedVector2Array([a, b]), ghost, 1.4, 5.0, 4.0)
			_dashed(PackedVector2Array([a + Vector2(0, 8), b + Vector2(0, 8)]), ghost, 1.0, 5.0, 4.0)
		_layer_fx(4 + 2 * k, Transform2D(0.0, Vector2(0, -60.0 * (1.0 - _back(_seg(lt, t0, t0 + 0.45))))), Color(tint, fade if started else 0.0))
		if _layer(4 + 2 * k, false):
			_line(a, b, INK, 11.0, 0.4)
			_line(a, b, WOOD.darkened(0.1), 8.5, 0.4)
			_circ(b, 5.0, Color(STRAW, 1.0), INK, 1.3)
	for k in 6:
		var x0 := 0.08 + k * 0.32
		var x1 := x0 + 0.28
		var top := PackedVector2Array([_iso(x0, -0.05, 0.2), _iso(x1, -0.05, 0.2), _iso(x1, 2.05, 0.2), _iso(x0, 2.05, 0.2)])
		var t0: float = board_t[k]
		var started := lt >= t0
		counts[1] += 1 if lt >= t0 + 0.4 else 0
		_layer_fx(7 + 2 * k, Transform2D.IDENTITY, Color(1, 1, 1, 0.0 if started else ga))
		if _layer(7 + 2 * k, false):
			_dashed(top, ghost, 1.3, 5.0, 4.0, 0.0, true)
		_layer_fx(8 + 2 * k, Transform2D(0.0, Vector2(0, -50.0 * (1.0 - _back(_seg(lt, t0, t0 + 0.4))))), Color(tint, fade if started else 0.0))
		if _layer(8 + 2 * k, false):
			var side := PackedVector2Array([top[3], top[2], top[2] + Vector2(0, 5), top[3] + Vector2(0, 5)])
			var side2 := PackedVector2Array([top[1], top[2], top[2] + Vector2(0, 5), top[1] + Vector2(0, 5)])
			_shape(side, Color(WOOD.darkened(0.25), 1.0), INK, 1.2, 0.2)
			_shape(side2, Color(WOOD.darkened(0.15), 1.0), INK, 1.2, 0.2)
			_shape(top, Color(WOOD.lightened(0.12), 0.98), INK, 1.5, 0.3)
			_stroke(PackedVector2Array([top[0].lerp(top[3], 0.2) + Vector2(4, 0), top[0].lerp(top[3], 0.8) + Vector2(4, 0)]), Color(INK, 0.25), 1.0, false, 0.4)
	for k in 2:
		var y := 0.3 if k == 0 else 1.7
		var c := _iso(1.0, y, 0.2)
		var t0: float = lash_t[k]
		var started := lt >= t0
		counts[2] += 1 if lt >= t0 + 0.4 else 0
		_layer_fx(19 + 2 * k, Transform2D.IDENTITY, Color(1, 1, 1, 0.0 if started else ga))
		if _layer(19 + 2 * k, false):
			_dashed(_oval(c, 12.0, 7.0, 14), ghost, 1.2, 4.0, 3.0, 0.0, true)
		var s := lerpf(1.6, 1.0, _back(_seg(lt, t0, t0 + 0.4)))
		_layer_fx(20 + 2 * k, Transform2D(0.0, Vector2(s, s), 0.0, c) * Transform2D(0.0, -c), Color(1, 1, 1, fade if started else 0.0))
		if _layer(20 + 2 * k, false):
			_cord(PackedVector2Array([c + Vector2(-11, -5), c + Vector2(11, 5)]), 3.0, STRAW, 1.0)
			_cord(PackedVector2Array([c + Vector2(-11, 5), c + Vector2(11, -5)]), 3.0, STRAW, 1.0)
	# finished: turns solid; the checklist keeps count
	_layer(23, true)
	if solid > 0.0 and solid < 1.0:
		_fill(PackedVector2Array([_iso(-0.1, -0.1, 0.2), _iso(2.1, -0.1, 0.2), _iso(2.1, 2.1, 0.2), _iso(-0.1, 2.1, 0.2)]), Color(1, 1, 0.9, 0.5 * sin(PI * solid)))
	var names := ["poles", "boards", "lashings"]
	var need := [2, 6, 2]
	for k in 3:
		var y := 92.0 + k * 30.0
		var ok: bool = counts[k] >= need[k]
		_text(Vector2(372, y), names[k], 14, INK, LEFT)
		_text(Vector2(452, y), "%d/%d" % [counts[k], need[k]], 13, GREEN.darkened(0.2) if ok else INK2, RIGHT)
		if ok:
			_check(Vector2(462, y - 2.0), 0.55, GREEN, 2.0)
	_text(Vector2(118, 38), "ghost frame", 12, Color(INK, 0.6 * (1.0 - _seg(lt, 1.2, 2.0))))
	_text(Vector2(212, 238), "solid", 14, Color(GREEN.darkened(0.2), _seg(lt, 6.2, 6.6) * fade))


# --- 27. support -------------------------------------------------------------

func _d_support() -> void:
	var t := _t
	var P := 9.0
	var lt := fposmod(t * 1.125, P)   # the 9 s story plays in an 8 s loop
	var fade := 1.0 - _seg(lt, P - 0.45, P)
	var panel := Rect2(12, 12, 456, 246)
	var clip := _rrect(panel, 6.0, 3)
	var deck_y := 126.0
	var L := 80.0
	var x0 := 132.0
	if _layer(2, false):
		_panel(panel, Color(SKY, 0.4), Color(0.40, 0.48, 0.62, 0.45), false)
	_layer(3, true)
	for i in 3:
		var x := fposmod(60.0 + i * 170.0 - t * 5.0, 560.0) - 40.0
		_clip_shape(_cloud_pts(Vector2(x, 238.0 - 8.0 * (i % 2)), 120.0, 42.0), clip, Color(0.97, 0.97, 0.98, 0.9), Color(INK, 0.3), 1.2, 0.0)
	if _layer(4, false):
		var cliff := PackedVector2Array([Vector2(12, deck_y + 2.0), Vector2(132, deck_y + 2.0), Vector2(136, 150), Vector2(128, 180), Vector2(134, 210),
			Vector2(124, 240), Vector2(128, 258), Vector2(12, 258)])
		_clip_shape(cliff, clip, Color(EARTH, 0.95), INK, 2.0, 0.5)
		_fill(PackedVector2Array([Vector2(12, deck_y - 8.0), Vector2(132, deck_y - 8.0), Vector2(132, deck_y + 2.0), Vector2(12, deck_y + 2.0)]), Color(GRASS, 0.95))
		_stroke(PackedVector2Array([Vector2(12, deck_y - 8.0), Vector2(132, deck_y - 8.0)]), INK, 2.0, false, 0.4)
		_stone(Vector2(60, 170), 10.0, 7.0, 2.0)
		_stone(Vector2(98, 214), 8.0, 6.0, 4.0)
		_stone(Vector2(40, 228), 9.0, 6.0, 6.0)
	# deck steps (each one step = 2 m) drop in; the second sags until braced;
	# the third is too far out: it shakes and falls away
	var s1 := _back(_seg(lt, 0.3, 0.8))
	var s2 := _back(_seg(lt, 1.4, 1.9))
	var s3 := _back(_seg(lt, 2.6, 3.1))
	var sag := deg_to_rad(5.0) * _ss(_seg(lt, 1.9, 2.4)) * (1.0 - _ss(_seg(lt, 5.4, 6.2)))
	var j1 := Vector2(x0 + L, deck_y - 4.0)
	var seg2_end := j1 + Vector2(L, 0).rotated(sag)
	_layer_fx(5, Transform2D(0.0, Vector2(0, -40.0 * (1.0 - s1))), Color(1, 1, 1, fade if lt > 0.3 else 0.0))
	if _layer(5, false):
		_deck(Vector2(x0, deck_y - 4.0), 0.0, L, 1.0)
	_layer_fx(6, _rot_about(j1, sag) * Transform2D(0.0, Vector2(0, -40.0 * (1.0 - s2))), Color(1, 1, 1, fade if lt > 1.4 else 0.0))
	if _layer(6, false):
		_deck(j1, 0.0, L, 1.0)
	var fall := _ei(_seg(lt, 3.7, 4.4))
	var shake := sin(t * 60.0) * 2.0 * _win(lt, 3.1, 3.7, 0.05)
	var p3 := seg2_end + Vector2(shake, -40.0 * (1.0 - s3) + 120.0 * fall)
	var ref3 := j1 + Vector2(L, 0)
	_layer_fx(7, Transform2D(sag + 0.8 * fall, p3) * Transform2D(0.0, -ref3), Color(1, 1, 1, (1.0 - fall) * fade if lt > 2.6 and lt < 4.4 else 0.0))
	if _layer(7, false):
		_deck(ref3, 0.0, L, 1.0, Color(RED, 0.25))
	_layer(8, true)
	# brace from the cliff face to under the second step
	var brace := _ss(_seg(lt, 4.6, 5.6))
	if brace > 0.0:
		var ba := Vector2(130, 210)
		var bb := Vector2(x0 + L * 1.45, deck_y + 4.0)
		_line(ba, ba.lerp(bb, brace), INK, 8.0, 0.4)
		_line(ba, ba.lerp(bb, brace), WOOD, 5.5, 0.4)
		_text(Vector2(186, 196), "brace", 13, Color(INK, _seg(brace, 0.6, 1.0) * fade))
	# markers
	if lt > 0.8:
		_check(Vector2(x0 + L * 0.5, deck_y - 30.0), 1.1, Color(GREEN, fade), 3.0)
		_text(Vector2(x0 + L * 0.5, deck_y - 48.0), "1 step: ok", 12, Color(INK, fade))
	if lt > 1.9:
		var mid := j1 + Vector2(L * 0.5, 0).rotated(sag)
		var warn := _seg(lt, 1.9, 2.2) * (1.0 - _seg(lt, 5.6, 6.0))
		var fixed := _seg(lt, 5.9, 6.3)
		if warn > 0.01:
			_text(mid + Vector2(0, -30.0), "!", 20, Color(AMBER.darkened(0.1), warn * fade))
			var ca := 0.5 + 0.5 * sin(t * 14.0)
			for k in 2:
				_pl(_arcp(j1 + Vector2(0, 16), 6.0 + k * 5.0, 4.0 + k * 3.0, 0.2, PI - 0.2, 8), Color(AMBER.darkened(0.2), ca * warn * fade), 1.4)
			_text(mid + Vector2(0, -48.0), "2: creaks, sags", 12, Color(INK, warn * fade))
		if fixed > 0.01:
			_check(mid + Vector2(0, -30.0), 1.1, Color(GREEN, fixed * fade), 3.0)
			_text(mid + Vector2(0, -48.0), "2: braced", 12, Color(INK, fixed * fade))
	if lt > 3.1 and lt < 5.0:
		var xa := (1.0 - _seg(lt, 4.4, 5.0)) * fade
		var mid3 := seg2_end + Vector2(L * 0.5, 0)
		_cross(mid3 + Vector2(0, -30.0), 1.2, Color(RED, xa), 3.2)
		_text(mid3 + Vector2(0, -48.0), "3: too far", 12, Color(RED.darkened(0.15), xa))


func _deck(a: Vector2, ang: float, L: float, alpha: float, tint: Color = Color(0, 0, 0, 0)) -> void:
	## One deck step (boards on a pole) starting at a, tilted by ang.
	if alpha <= 0.01:
		return
	var pts := PackedVector2Array([Vector2(0, -4), Vector2(L, -4), Vector2(L, 6), Vector2(0, 6)])
	var xf := Transform2D(ang, a)
	var col := WOOD.lightened(0.08)
	if tint.a > 0.0:
		col = col.lerp(Color(tint, 1.0), tint.a)
	_shape(xf * pts, Color(col, 0.97 * alpha), Color(INK, alpha), 1.8, 0.4)
	var seams := PackedVector2Array()
	for k in range(1, 5):
		seams.append(xf * Vector2(L * k / 5.0, -4))
		seams.append(xf * Vector2(L * k / 5.0, 6))
	_ml(seams, Color(INK, 0.35 * alpha), 1.0, true)
	_line(xf * Vector2(2, 9), xf * Vector2(L - 2.0, 9), Color(WOOD.darkened(0.3), alpha), 4.0, 0.3)


# --- 28. shelter -------------------------------------------------------------

func _d_shelter() -> void:
	var t := _t
	var deck := 210.0
	# warm glow inside, rain outside (falls behind the roof)
	_layer(2, true)
	_glow(Vector2(244, 170), 110.0, Color(FLAME, 0.30 + 0.05 * sin(t * 2.2)), 0.7)
	var rain := PackedVector2Array()
	for i in 34:
		var x0 := -20.0 + 500.0 * _rnd(i * 7 + 1)
		var ph := fposmod(t * 1.0 + _rnd(i * 3 + 5), 1.0)
		var x := x0 + ph * 40.0
		var y := lerpf(14.0, 256.0, ph)
		if y > _roof_y(x) - 2.0 and x > 70.0 and x < 410.0:
			continue
		if x < 16.0 or x > 464.0:
			continue
		rain.append(Vector2(x - 3.0, y - 9.0))
		rain.append(Vector2(x, y))
	_ml(rain, Color(WATER.darkened(0.15), 0.6), 1.3, true)
	if _layer(3, false):
		# platform
		_shape(_rectp(Rect2(92, deck, 296, 10)), Color(WOOD, 0.97), INK, 1.8, 0.4)
		var seams := PackedVector2Array()
		for k in range(1, 9):
			seams.append(Vector2(92.0 + k * 33.0, deck))
			seams.append(Vector2(92.0 + k * 33.0, deck + 10.0))
		_ml(seams, Color(INK, 0.35), 1.0, true)
		for px in [110.0, 240.0, 370.0]:
			_line(Vector2(px, deck + 10.0), Vector2(px, 258), WOOD.darkened(0.25), 5.0, 0.4)
		# sleeping mat
		_shape(_rectp(Rect2(170, deck - 6.0, 130, 6)), Color(STRAW, 0.97), INK, 1.4, 0.3)
		var weave := PackedVector2Array()
		for k in 16:
			weave.append(Vector2(173.0 + k * 8.0, deck - 6.0))
			weave.append(Vector2(177.0 + k * 8.0, deck))
		_ml(weave, Color(INK, 0.35), 1.0, true)
	# a sleeper, breathing slowly
	var mat := Vector2(243, deck - 6.0)
	_layer_fx(4, Transform2D(0.0, Vector2(1.0, 1.0 + 0.045 * sin(t * 1.3)), 0.0, mat) * Transform2D(0.0, -mat))
	if _layer(4, false):
		_shape(_cb(Vector2(196, deck - 6.0), Vector2(204, deck - 30.0), Vector2(268, deck - 26.0), Vector2(290, deck - 6.0), 14), Color(WATER.lerp(PAPER, 0.4), 0.95), INK, 1.6, 0.4)
		_circ(Vector2(186, deck - 14.0), 8.0, Color(0.92, 0.79, 0.64, 1.0), INK, 1.5)
	_layer(5, true)
	var zp := fposmod(t * 0.4, 1.0)
	_text(Vector2(196 + zp * 14.0, deck - 34.0 - zp * 24.0), "z", 12, Color(INK, 0.7 * sin(PI * zp)))
	if _layer(6, false):
		# walls: wattle on the windward side, a short one over the doorway
		_wattle(Rect2(100, 118, 18, deck - 118.0))
		_wattle(Rect2(362, 118, 18, 40))
		# thatch roof
		var roof := PackedVector2Array([Vector2(74, 126), Vector2(240, 40), Vector2(406, 126), Vector2(396, 134), Vector2(240, 54), Vector2(84, 134)])
		_shape(roof, Color(STRAW, 0.97), INK, 2.0, 0.5)
		var straw := PackedVector2Array()
		for k in 22:
			var u := (float(k) + 0.5) / 22.0
			var a: Vector2
			if u < 0.5:
				a = Vector2(80, 130).lerp(Vector2(240, 47), u * 2.0)
			else:
				a = Vector2(240, 47).lerp(Vector2(400, 130), u * 2.0 - 1.0)
			var d := 1.0 if u > 0.5 else -1.0
			straw.append(a + Vector2(-d * 1.0, -5))
			straw.append(a + Vector2(d * 3.0, 5))
		_ml(straw, Color(INK, 0.4), 1.0, true)
		_text(Vector2(46, 118), "cold wind", 12, Color(0.2, 0.32, 0.55))
		_text(Vector2(440, 70), "rain", 12)
		_callout("thatch", Vector2(330, 50), Vector2(300, 82), 12)
		_callout("wattle wall", Vector2(56, 232), Vector2(104, 196), 12)
		_text(Vector2(316, 186), "warm, dry", 12, EMBER.darkened(0.35))
		_callout("mat", Vector2(330, 236), Vector2(292, 205), 12)
	# rain splashing on the roof and dripping off the eaves; wind stopped by the wall
	_layer(7, true)
	var spl := PackedVector2Array()
	for k in 9:
		var ph := fposmod(t * 1.7 + _rnd(k * 13), 1.0)
		var x := 92.0 + 296.0 * _rnd(k * 5 + 3)
		var y := _roof_y(x) - 1.0
		if ph < 0.35:
			var s := ph / 0.35
			spl.append_array([Vector2(x, y), Vector2(x - 3.0 - 3.0 * s, y - 4.0 - 4.0 * s), Vector2(x, y), Vector2(x + 3.0 + 3.0 * s, y - 4.0 - 4.0 * s)])
	_ml(spl, Color(WATER.darkened(0.2), 0.85), 1.2, true)
	for e in [Vector2(76, 130), Vector2(404, 130)]:
		var ph := fposmod(t * 0.8 + e.x * 0.01, 1.0)
		_drop(e + Vector2(0, 6.0 + ph * 60.0), 2.6, Color(WATER, 1.0 - ph), Color(INK, 0.6 * (1.0 - ph)), 1.0)
	for k in 3:
		var y := 136.0 + k * 26.0
		var ph := fposmod(t * 0.55 + k * 0.33, 1.0)
		var head_x := lerpf(30.0, 94.0, _ss(ph))
		var keep := PackedVector2Array()
		for j in 9:
			var u := float(j) / 8.0
			var x := head_x - 56.0 + u * 56.0
			if x > 16.0:
				keep.append(Vector2(x, y + sin(u * 6.0 + t * 4.0 + k) * 2.5))
		var a := sin(PI * ph)
		if keep.size() >= 2:
			_arrow_path(keep, Color(0.25, 0.40, 0.65, 0.9 * a), 2.0, 7.0, 0.2)
		if ph > 0.75:
			_pl(_arcp(Vector2(88, y - 8.0), 6.0, 8.0, PI * 0.5, PI * 1.4, 6), Color(0.25, 0.40, 0.65, 0.8 * a), 1.4)


func _roof_y(x: float) -> float:
	return 126.0 - (126.0 - 40.0) * (1.0 - absf(x - 240.0) / 166.0)

class_name UITheme
extends RefCounted
## One cohesive look for every menu and HUD element: warm dark translucent
## panels, parchment text, amber accents.

const BG := Color(0.09, 0.085, 0.075, 0.86)
const BG_SOLID := Color(0.11, 0.10, 0.09, 0.97)
const BG_LIGHT := Color(0.16, 0.15, 0.13, 0.9)
const LINE := Color(0.95, 0.88, 0.72, 0.16)
const TEXT := Color(0.94, 0.9, 0.82)
const TEXT_DIM := Color(0.72, 0.68, 0.6)
const ACCENT := Color(0.88, 0.65, 0.29)
const ACCENT_2 := Color(0.62, 0.72, 0.54)
const DANGER := Color(0.86, 0.38, 0.3)
const WATER := Color(0.45, 0.68, 0.86)
const PAPER := Color(0.93, 0.89, 0.8)
const INK := Color(0.2, 0.17, 0.13)

static var _theme: Theme = null
static var _font: Font = null
static var _font_bold: Font = null
static var _font_title: Font = null


static func font() -> Font:
	if _font == null:
		_font = _load_font("res://assets/fonts/body.woff2", false)
	return _font


static func font_bold() -> Font:
	if _font_bold == null:
		_font_bold = _load_font("res://assets/fonts/body_bold.woff2", true)
	return _font_bold


static func font_title() -> Font:
	if _font_title == null:
		_font_title = _load_font("res://assets/fonts/title.woff2", true)
	return _font_title


static func _load_font(path: String, bold: bool) -> Font:
	if ResourceLoader.exists(path):
		var f = load(path)
		if f is Font:
			return f
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Noto Sans", "DejaVu Sans", "Sans-Serif"])
	sf.font_weight = 700 if bold else 400
	return sf


static func panel(color: Color = BG, radius: int = 10, border: Color = LINE, pad: int = 14) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.border_color = border
	sb.set_border_width_all(1 if border.a > 0.0 else 0)
	sb.content_margin_left = pad
	sb.content_margin_right = pad
	sb.content_margin_top = pad * 0.75
	sb.content_margin_bottom = pad * 0.75
	sb.anti_aliasing = true
	return sb


static func get_theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = 17
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color(1, 0.96, 0.88))
	t.set_color("font_pressed_color", "Button", ACCENT)
	t.set_color("font_disabled_color", "Button", Color(TEXT_DIM, 0.5))
	t.set_color("font_focus_color", "Button", Color(1, 0.96, 0.88))
	var b_normal := panel(Color(0.18, 0.165, 0.145, 0.92), 8, Color(1, 0.9, 0.7, 0.12), 12)
	var b_hover := panel(Color(0.25, 0.22, 0.18, 0.95), 8, Color(ACCENT, 0.55), 12)
	var b_pressed := panel(Color(0.3, 0.24, 0.16, 0.98), 8, ACCENT, 12)
	var b_disabled := panel(Color(0.14, 0.13, 0.12, 0.7), 8, Color(0, 0, 0, 0), 12)
	t.set_stylebox("normal", "Button", b_normal)
	t.set_stylebox("hover", "Button", b_hover)
	t.set_stylebox("pressed", "Button", b_pressed)
	t.set_stylebox("disabled", "Button", b_disabled)
	t.set_stylebox("focus", "Button", panel(Color(0, 0, 0, 0), 8, Color(ACCENT, 0.7), 12))
	t.set_stylebox("panel", "PanelContainer", panel())
	t.set_stylebox("panel", "Panel", panel())
	var le := panel(Color(0.06, 0.055, 0.05, 0.9), 6, Color(1, 0.9, 0.7, 0.18), 10)
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", panel(Color(0.06, 0.055, 0.05, 0.95), 6, Color(ACCENT, 0.8), 10))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(TEXT_DIM, 0.6))
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.35))
	t.set_stylebox("normal", "TextEdit", le)
	var slider_track := StyleBoxFlat.new()
	slider_track.bg_color = Color(1, 1, 1, 0.12)
	slider_track.set_corner_radius_all(3)
	slider_track.content_margin_top = 3
	slider_track.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", slider_track)
	var fill := slider_track.duplicate()
	fill.bg_color = Color(ACCENT, 0.8)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	t.set_icon("grabber", "HSlider", _circle_tex(16, PAPER))
	t.set_icon("grabber_highlight", "HSlider", _circle_tex(16, Color(1, 0.9, 0.7)))
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_hover_color", "CheckBox", Color(1, 0.96, 0.88))
	t.set_color("font_pressed_color", "CheckBox", TEXT)
	t.set_color("font_hover_pressed_color", "CheckBox", Color(1, 0.96, 0.88))
	var empty := StyleBoxEmpty.new()
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		t.set_stylebox(st, "CheckBox", empty)
	t.set_icon("checked", "CheckBox", _check_tex(true))
	t.set_icon("unchecked", "CheckBox", _check_tex(false))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.2)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	t.set_stylebox("grabber", "VScrollBar", sb)
	var sbh := sb.duplicate()
	sbh.bg_color = Color(ACCENT, 0.6)
	t.set_stylebox("grabber_highlight", "VScrollBar", sbh)
	t.set_stylebox("grabber_pressed", "VScrollBar", sbh)
	var scroll_bg := StyleBoxFlat.new()
	scroll_bg.bg_color = Color(0, 0, 0, 0.15)
	scroll_bg.set_corner_radius_all(4)
	scroll_bg.content_margin_left = 4
	scroll_bg.content_margin_right = 4
	t.set_stylebox("scroll", "VScrollBar", scroll_bg)
	t.set_color("default_color", "RichTextLabel", TEXT)
	t.set_font("bold_font", "RichTextLabel", font_bold())
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	t.set_color("font_color", "ItemList", TEXT)
	t.set_stylebox("panel", "ItemList", panel(Color(0.06, 0.055, 0.05, 0.6), 6, LINE, 6))
	t.set_stylebox("selected", "ItemList", panel(Color(ACCENT, 0.25), 4, Color(0, 0, 0, 0), 4))
	t.set_stylebox("selected_focus", "ItemList", panel(Color(ACCENT, 0.32), 4, Color(0, 0, 0, 0), 4))
	t.set_stylebox("hovered", "ItemList", panel(Color(1, 1, 1, 0.06), 4, Color(0, 0, 0, 0), 4))
	var tip := panel(Color(0.08, 0.075, 0.065, 0.96), 6, Color(1, 0.9, 0.7, 0.25), 10)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_color("font_color", "OptionButton", TEXT)
	t.set_stylebox("normal", "OptionButton", b_normal)
	t.set_stylebox("hover", "OptionButton", b_hover)
	t.set_stylebox("pressed", "OptionButton", b_pressed)
	t.set_stylebox("panel", "PopupMenu", panel(BG_SOLID, 6, LINE, 6))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", ACCENT)
	_theme = t
	return t


static func _circle_tex(size: int, col: Color) -> Texture2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := (size - 1) / 2.0
	for y in size:
		for x in size:
			var d := Vector2(x - c, y - c).length()
			var a := clampf(c - d + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(col, col.a * a))
	return ImageTexture.create_from_image(img)


static func _check_tex(on: bool) -> Texture2D:
	var s := 20
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	for y in s:
		for x in s:
			var edge := x < 2 or y < 2 or x > s - 3 or y > s - 3
			var col := Color(0, 0, 0, 0)
			if edge:
				col = Color(PAPER, 0.7)
			elif on and x > 4 and y > 4 and x < s - 5 and y < s - 5:
				col = ACCENT
			else:
				col = Color(0, 0, 0, 0.35)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


static func label(text: String, size: int = 17, color: Color = TEXT, bold: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_font_override("font", font_bold())
	return l


static func title_label(text: String, size: int = 40, color: Color = PAPER) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font_title())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func button(text: String, cb: Callable, min_w: float = 0.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 40)
	b.pressed.connect(func(): Sfx.ui("ui_click"))
	b.pressed.connect(cb)
	b.mouse_entered.connect(func(): Sfx.ui("ui_hover", -14.0))
	b.focus_mode = Control.FOCUS_NONE
	return b


static func hslider(label_text: String, min_v: float, max_v: float, step: float, value: float, cb: Callable, fmt: Variant = "%.2f") -> Control:
	## `fmt` is a format string or a Callable turning the value into its text.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := label(label_text, 16, TEXT_DIM)
	l.custom_minimum_size = Vector2(170, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(180, 24)
	s.focus_mode = Control.FOCUS_NONE
	var show := func(v: float) -> String: return String((fmt as Callable).call(v)) if fmt is Callable else String(fmt) % v
	var val := label(show.call(value), 15, TEXT)
	val.custom_minimum_size = Vector2(64, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.value_changed.connect(func(v): val.text = show.call(v); cb.call(v))
	row.add_child(s)
	row.add_child(val)
	return row


static func checkbox(label_text: String, value: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = label_text
	c.button_pressed = value
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(cb)
	return c

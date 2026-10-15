extends ScrollContainer
## Settings controls, shared by the main menu and the pause menu.


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	custom_minimum_size = Vector2(0, 300)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	add_child(v)
	var pct := func(x: float) -> String: return "%d%%" % roundi(x * 100.0)
	v.add_child(_header("Controls"))
	v.add_child(UITheme.hslider("Mouse sensitivity", 0.0006, 0.006, 0.0001, Settings.mouse_sensitivity,
		func(x): Settings.mouse_sensitivity = x; _save(), func(x: float) -> String: return "%d%%" % roundi(x / 0.0024 * 100.0)))
	v.add_child(UITheme.checkbox("Invert mouse Y", Settings.invert_y, func(on): Settings.invert_y = on; _save()))
	v.add_child(UITheme.hslider("Field of view", 60.0, 100.0, 1.0, Settings.fov, func(x): Settings.fov = x; _save(), "%.0f°"))
	v.add_child(UITheme.checkbox("Head bob", Settings.head_bob, func(on): Settings.head_bob = on; _save()))
	v.add_child(UITheme.checkbox("Contextual hints", Settings.show_hints, func(on): Settings.show_hints = on; _save()))
	v.add_child(_header("Audio"))
	v.add_child(UITheme.hslider("Master volume", 0.0, 1.0, 0.01, Settings.master_volume, func(x): Settings.master_volume = x; _save(true), pct))
	v.add_child(UITheme.hslider("Effects", 0.0, 1.0, 0.01, Settings.sfx_volume, func(x): Settings.sfx_volume = x; _save(true), pct))
	v.add_child(UITheme.hslider("Ambience", 0.0, 1.0, 0.01, Settings.ambience_volume, func(x): Settings.ambience_volume = x; _save(true), pct))
	v.add_child(_header("Graphics"))
	v.add_child(UITheme.hslider("View distance (at sea)", 4, 16, 1, Settings.view_chunks, func(x):
		Settings.view_chunks = int(x)
		_save()
		var gw = Game.game_world
		if gw and World.kind == "sea" and gw.voxels:
			gw.voxels.set_radius(int(x)), func(x: float) -> String: return "%d blocks" % (int(x) * 16)))
	v.add_child(UITheme.hslider("Render scale", 0.5, 1.0, 0.05, Settings.render_scale, func(x): Settings.render_scale = x; _save(true), pct))
	v.add_child(UITheme.hslider("Shadow quality", 0, 3, 1, Settings.shadows_quality, func(x): Settings.shadows_quality = int(x); _save(true),
		func(x: float) -> String: return ["Off", "Low", "Medium", "High"][clampi(int(x), 0, 3)]))
	v.add_child(UITheme.checkbox("Ambient occlusion", Settings.ssao, func(on): Settings.ssao = on; _save(true)))
	v.add_child(UITheme.checkbox("Fullscreen", Settings.fullscreen, func(on): Settings.fullscreen = on; _save(true)))
	v.add_child(UITheme.checkbox("V-Sync", Settings.vsync, func(on): Settings.vsync = on; _save(true)))


func _header(t: String) -> Label:
	var l := UITheme.label(t.to_upper(), 13, UITheme.ACCENT, true)
	return l


func _save(apply_now: bool = false) -> void:
	Settings.save_settings()
	if apply_now:
		Settings.apply()

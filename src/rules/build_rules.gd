class_name BuildRules
extends RefCounted
## What you can do to a built piece or a frame: install its next part, sleep on
## a finished mat, climb a ladder.  (Taking things apart is a build-mode action:
## B, then "Take apart", so nobody dismantles a floor by accident.)

const VERBS := {"hammer": "Hammer in", "bind": "Lash on", "weave": "Weave in", "daub": "Daub on", "thatch": "Thatch with"}
const ANIMS := {"hammer": "hammer", "bind": "bind", "weave": "twist", "daub": "pack", "thatch": "place"}


static func options(out: Dictionary, p: LocalPlayer, t: Dictionary, d: Dictionary, eid: int, held: String, hd: Dictionary, tool: String) -> void:
	var opt := InteractionRules.opt
	var bp := ItemDB.blueprint(String(d.get("bp", "")))
	var parts: Array = bp.get("parts", [])
	var n := int(d.get("installed", 0))
	var complete := n >= parts.size()
	var nm := String(bp.get("name", "Structure"))
	out["info"] = {"title": nm if complete else "%s - frame (%d/%d parts)" % [nm, n, parts.size()], "text": status(d)}
	if not complete:
		var need := String(parts[n]).split("|")
		var work: Array = bp.get("work", [])
		var w := String(work[n]) if n < work.size() else "hammer"
		if held in need and not hd.has("fm"):
			out["primary"] = opt.call("%s the %s" % [VERBS.get(w, "Fit"), ItemDB.display_name(held).to_lower()], "build_install", {"eid": eid}, ANIMS.get(w, "hammer"), true)
		else:
			var names: PackedStringArray = []
			for id in need:
				names.append(ItemDB.a_name(id))
			out["primary"] = InteractionRules.disabled("Needs %s" % " or ".join(names), "Hold %s to fit the next part. Still to come: %s." % [" or ".join(names), remaining_text(d)])
		return
	if bool(bp.get("bed", false)):
		out["interact"] = {"label": "Lie down and sleep", "local": func(): p.start_sleep(eid), "enabled": true}
	elif String(bp.get("kind", "")) == "ladder":
		out["interact"] = {"label": "Climb", "local": func(): p.start_climb(eid), "enabled": true}


static func status(d: Dictionary) -> String:
	var stress := float(d.get("stress", 0.0))
	if stress >= 1.0:
		return "It's groaning and shifting - it has lost its support! Get off it, or prop it up quickly."
	if stress >= 0.5:
		return "It creaks under its own weight. A post or brace beneath would steady it."
	if not StructureSim.is_complete(d):
		return "Still needs: %s." % remaining_text(d)
	return ""


static func remaining_text(d: Dictionary) -> String:
	var parts: Array = ItemDB.blueprint(String(d.get("bp", ""))).get("parts", [])
	var counts := {}
	var order: Array = []
	for i in range(int(d.get("installed", 0)), parts.size()):
		var k := String(parts[i])
		if not counts.has(k):
			order.append(k)
		counts[k] = int(counts.get(k, 0)) + 1
	var bits: PackedStringArray = []
	for k in order:
		var names: PackedStringArray = []
		var ids: PackedStringArray = String(k).split("|")
		for j in ids.size():
			names.append(ItemDB.count_name(ids[j], int(counts[k]), {}, j == 0))
		bits.append(" or ".join(names))
	return ", ".join(bits)

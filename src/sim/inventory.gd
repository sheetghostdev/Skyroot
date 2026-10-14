class_name Inventory
extends RefCounted
## A fixed-size list of item stacks.  Lives on the host (authoritative) and is
## mirrored to the owning client.  A stack is {"i": item_id, "n": count, "d": data}.
## Items carrying data (tools, pottery, knapped heads...) never stack.

const HOTBAR := 9
const SIZE := 27

var slots: Array = []


func _init(size: int = SIZE) -> void:
	slots.resize(size)
	for i in size:
		slots[i] = {}


static func make(id: String, n: int = 1, d: Dictionary = {}) -> Dictionary:
	return {"i": id, "n": n, "d": d}


func size() -> int:
	return slots.size()


func is_empty_slot(i: int) -> bool:
	return i < 0 or i >= slots.size() or slots[i].is_empty()


func get_slot(i: int) -> Dictionary:
	if i < 0 or i >= slots.size():
		return {}
	return slots[i]


func item_at(i: int) -> String:
	return String(get_slot(i).get("i", ""))


func count(id: String) -> int:
	var n := 0
	for s in slots:
		if not s.is_empty() and s["i"] == id:
			n += int(s["n"])
	return n


func find(id: String) -> int:
	for i in slots.size():
		if not slots[i].is_empty() and slots[i]["i"] == id:
			return i
	return -1


func find_where(pred: Callable) -> int:
	for i in slots.size():
		if not slots[i].is_empty() and pred.call(slots[i]):
			return i
	return -1


func space_for(id: String, d: Dictionary = {}) -> int:
	var free := 0
	var mx := ItemDB.stack_max(id)
	var stackable := ItemDB.can_stack(id, d)
	for s in slots:
		if s.is_empty():
			free += mx if stackable else 1
		elif stackable and s["i"] == id and ItemDB.can_stack(id, s["d"]):
			free += maxi(0, mx - int(s["n"]))
	return free


static func _merge_moist(s: Dictionary, id: String, add_n: int, d: Dictionary) -> void:
	## Weighted-average moisture when merging stacks.
	if not d.has("moist") and not s["d"].has("moist"):
		return
	var dm := ItemDB.default_moist(id)
	var m1 := float(s["d"].get("moist", dm))
	var m2 := float(d.get("moist", dm))
	var n1 := int(s["n"])
	var m := (m1 * n1 + m2 * add_n) / maxf(1.0, n1 + add_n)
	s["d"] = {"moist": m}


func add(id: String, n: int = 1, d: Dictionary = {}, prefer_slot: int = -1) -> int:
	## Adds up to n items; returns how many could NOT be added.
	if n <= 0 or not ItemDB.exists(id):
		return n
	var mx := ItemDB.stack_max(id)
	if ItemDB.can_stack(id, d):
		for s in slots:
			if n <= 0:
				break
			if not s.is_empty() and s["i"] == id and ItemDB.can_stack(id, s["d"]) and int(s["n"]) < mx:
				var take := mini(n, mx - int(s["n"]))
				_merge_moist(s, id, take, d)
				s["n"] = int(s["n"]) + take
				n -= take
		var order := _slot_order(prefer_slot)
		for i in order:
			if n <= 0:
				break
			if slots[i].is_empty():
				var take := mini(n, mx)
				slots[i] = make(id, take, d.duplicate())
				n -= take
	else:
		var order := _slot_order(prefer_slot)
		for i in order:
			if n <= 0:
				break
			if slots[i].is_empty():
				slots[i] = make(id, 1, d.duplicate(true))
				n -= 1
	return n


func _slot_order(prefer: int) -> Array:
	var order: Array = []
	if prefer >= 0 and prefer < slots.size():
		order.append(prefer)
	for i in slots.size():
		if i != prefer:
			order.append(i)
	return order


func remove(id: String, n: int = 1) -> bool:
	## Removes n of a (data-less or any) item.  All-or-nothing.
	if count(id) < n:
		return false
	for i in range(slots.size() - 1, -1, -1):
		if n <= 0:
			break
		var s: Dictionary = slots[i]
		if not s.is_empty() and s["i"] == id:
			var take := mini(n, int(s["n"]))
			s["n"] = int(s["n"]) - take
			n -= take
			if int(s["n"]) <= 0:
				slots[i] = {}
	return true


func take_from(i: int, n: int = 1) -> Dictionary:
	## Removes up to n from slot i, returning the removed stack (or {}).
	if is_empty_slot(i):
		return {}
	var s: Dictionary = slots[i]
	var take := mini(n, int(s["n"]))
	var out := make(s["i"], take, s["d"].duplicate(true))
	s["n"] = int(s["n"]) - take
	if int(s["n"]) <= 0:
		slots[i] = {}
	return out


func set_slot(i: int, stack: Dictionary) -> void:
	if i >= 0 and i < slots.size():
		slots[i] = stack


func set_data(i: int, d: Dictionary) -> void:
	if not is_empty_slot(i):
		slots[i]["d"] = d


func move(from: int, to: int) -> void:
	## Move/merge/swap a stack between two slots.
	if from == to or is_empty_slot(from) or to < 0 or to >= slots.size():
		return
	var a: Dictionary = slots[from]
	var b: Dictionary = slots[to]
	if not b.is_empty() and b["i"] == a["i"] and ItemDB.can_stack(a["i"], a["d"]) and ItemDB.can_stack(b["i"], b["d"]):
		var mx := ItemDB.stack_max(a["i"])
		var take := mini(int(a["n"]), mx - int(b["n"]))
		_merge_moist(b, b["i"], take, a["d"])
		b["n"] = int(b["n"]) + take
		a["n"] = int(a["n"]) - take
		if int(a["n"]) <= 0:
			slots[from] = {}
		return
	slots[from] = b
	slots[to] = a


func split(from: int, to: int) -> void:
	if is_empty_slot(from) or not is_empty_slot(to):
		return
	var a: Dictionary = slots[from]
	var half := int(a["n"]) / 2
	if half <= 0:
		return
	a["n"] = int(a["n"]) - half
	slots[to] = make(a["i"], half, a["d"].duplicate(true))


func clear() -> void:
	for i in slots.size():
		slots[i] = {}


func to_array() -> Array:
	return slots.duplicate(true)


func from_array(arr: Array) -> void:
	for i in slots.size():
		slots[i] = arr[i].duplicate(true) if i < arr.size() and arr[i] is Dictionary else {}


func total_mass() -> float:
	var m := 0.0
	for s in slots:
		if not s.is_empty():
			m += ItemDB.unit_mass(s["i"]) * int(s["n"])
	return m

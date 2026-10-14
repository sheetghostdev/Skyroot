class_name Inventory
extends RefCounted
## A player's slots.  Lives on the host (authoritative) and is mirrored to the
## owning client.  A stack is {"i": item_id, "n": count, "d": data}; items
## carrying data (tools, tool heads, filled bowls...) never stack.
##
## Slots 0-8 are the hotbar, 9-35 the backpack, 36-44 the 3x3 crafting grid and
## 45 the stack held on the mouse cursor while the inventory screen is open.

const HOTBAR := 9
const MAIN := 36
const GRID := 36
const CURSOR := 45
const SIZE := 46

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
	for i in MAIN:
		var s: Dictionary = slots[i]
		if not s.is_empty() and s["i"] == id:
			n += int(s["n"])
	return n


func find(id: String) -> int:
	for i in MAIN:
		if not slots[i].is_empty() and slots[i]["i"] == id:
			return i
	return -1


func space_for(id: String, d: Dictionary = {}) -> int:
	var free := 0
	var mx := ItemDB.stack_max(id)
	var stackable := ItemDB.can_stack(id, d)
	for i in MAIN:
		var s: Dictionary = slots[i]
		if s.is_empty():
			free += mx if stackable else 1
		elif stackable and s["i"] == id and ItemDB.can_stack(id, s["d"]):
			free += maxi(0, mx - int(s["n"]))
	return free


func add(id: String, n: int = 1, d: Dictionary = {}, prefer_slot: int = -1) -> int:
	## Adds up to n items to the hotbar and backpack; returns how many did NOT fit.
	if n <= 0 or not ItemDB.exists(id):
		return n
	var mx := ItemDB.stack_max(id)
	if ItemDB.can_stack(id, d):
		for i in MAIN:
			if n <= 0:
				break
			var s: Dictionary = slots[i]
			if not s.is_empty() and s["i"] == id and ItemDB.can_stack(id, s["d"]) and int(s["n"]) < mx:
				var take := mini(n, mx - int(s["n"]))
				s["n"] = int(s["n"]) + take
				n -= take
		for i in _slot_order(prefer_slot):
			if n <= 0:
				break
			if slots[i].is_empty():
				var take := mini(n, mx)
				slots[i] = make(id, take, {})
				n -= take
	else:
		for i in _slot_order(prefer_slot):
			if n <= 0:
				break
			if slots[i].is_empty():
				slots[i] = make(id, 1, d.duplicate(true))
				n -= 1
	return n


func _slot_order(prefer: int) -> Array:
	var order: Array = []
	if prefer >= 0 and prefer < MAIN:
		order.append(prefer)
	for i in MAIN:
		if i != prefer:
			order.append(i)
	return order


func remove(id: String, n: int = 1) -> bool:
	## Removes n of an item from the hotbar and backpack.  All-or-nothing.
	if count(id) < n:
		return false
	for i in range(MAIN - 1, -1, -1):
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
	if is_empty_slot(i) or n <= 0:
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


func grid() -> Array:
	return slots.slice(GRID, GRID + 9)


func clear() -> void:
	for i in slots.size():
		slots[i] = {}


func all_stacks() -> Array:
	var out: Array = []
	for s in slots:
		if not s.is_empty():
			out.append(s.duplicate(true))
	return out


func to_array() -> Array:
	return slots.duplicate(true)


func from_array(arr: Array) -> void:
	for i in slots.size():
		slots[i] = arr[i].duplicate(true) if i < arr.size() and arr[i] is Dictionary else {}

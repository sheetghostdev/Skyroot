extends Node
## Global signal bus.  Systems talk through these signals instead of holding
## references to each other, which keeps the game scene loosely coupled.

# --- World replication (emitted on every peer) ---
signal entity_spawned(id: int)
signal entity_changed(id: int, keys: Array)
signal entity_removed(id: int)
signal block_changed(cell: Vector3i, old_height: int)
signal world_loaded
signal env_changed

# --- Local player / UI ---
signal local_player_spawned(player: Node)
signal inventory_changed
signal hotbar_selected(index: int)
signal stats_changed
signal toast(text: String, kind: String)
signal hint(hint_id: String)
signal ui_mode_changed(mode: String)
signal target_changed(target: Dictionary)
signal player_died(reason: String)
signal guide_open_entry(entry_id: String)
signal open_chooser(kind: String, cell: Vector3i)
signal goal_progress

# --- Session ---
signal player_joined(peer_id: int)
signal player_left(peer_id: int)
signal chat(from_name: String, text: String)
signal discovery(discovery_id: String, by_name: String)

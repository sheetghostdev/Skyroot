extends Node
## Global signal bus.  Systems talk through these signals instead of holding
## references to each other, which keeps the game scene loosely coupled.

# --- World replication (emitted on every peer) ---
signal entity_spawned(id: int)
signal entity_changed(id: int, keys: Array)
signal entity_removed(id: int)
signal terrain_changed(cells: Rect2i)
signal soil_changed
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
signal craft_started(kind: String, entity_id: int)
signal craft_ended
signal interaction_target_changed(target: Dictionary)
signal player_died(reason: String)
signal guide_open_entry(entry_id: String)

# --- Session ---
signal player_joined(peer_id: int)
signal player_left(peer_id: int)
signal chat(from_name: String, text: String)
signal discovery(discovery_id: String, by_name: String)
signal process_feedback(entity_id: int, message: String)

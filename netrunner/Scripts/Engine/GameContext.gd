class_name GameContext
extends RefCounted

# ── GameContext ───────────────────────────────────────────────────────────────
# Owns all mutable game state. The AbilityInterpreter and RunStateMachine
# read and write this object. The game engine syncs it to the UI after
# each state change.

# ── Credits ───────────────────────────────────────────────────────────────────
var corp_credits:   int = 5
var runner_credits: int = 5

# ── Tags and bad publicity ────────────────────────────────────────────────────
var runner_tags:    int = 0
var corp_bad_pub:   int = 0

# ── Click tracking ────────────────────────────────────────────────────────────
var corp_clicks:    int = 0
var runner_clicks:  int = 0

# ── Hands ─────────────────────────────────────────────────────────────────────
# Each entry: {"card_id": String, "card_record": CardRecord}
var corp_hand:   Array = []
var runner_hand: Array = []   # runner's "grip"

# ── Decks ─────────────────────────────────────────────────────────────────────
var corp_deck: Array[CardRecord] = []
var runner_deck: Array[CardRecord] = []
var corp_discard: Array[CardRecord] = []
var runner_discard: Array[CardRecord] = []

# ── Score areas ───────────────────────────────────────────────────────────────
var corp_score_area: Array[CardRecord] = []
var runner_score_area: Array[CardRecord] = []

# ── Servers ───────────────────────────────────────────────────────────────────
var servers: Dictionary = {}

# ── Runner rig ────────────────────────────────────────────────────────────────
var runner_rig: Array = []   # Array[InstalledCard]

# ── Deferred modifiers ───────────────────────────────────────────────────────
# Click penalties applied at the start of the next turn.
# Keys: "corp" | "runner", values: int (clicks to subtract)
var pending_click_penalties: Dictionary = {"corp": 0, "runner": 0}

# ── Run state ─────────────────────────────────────────────────────────────────
var run_active:         bool   = false
var run_ended:          bool   = false
var run_successful:     bool   = false
var run_target_server:  String = ""
var accessed_card_id:   String = ""
# Run modifiers: set by run-initiating events, cleared when the run ends.
# Supported keys:
#   "extra_rez_cost"    : int — Corp pays extra to rez ice (Tread Lightly)
#   "bonus_access"      : int — Runner accesses extra cards on breach (Jailbreak, Conduit)
#   "icebreaker_credits": int — Credits usable only on icebreakers this run (Overclock)
var run_modifiers: Dictionary = {}

# Transient event payload accessible by the AbilityInterpreter during execution
var current_event_data: Dictionary = {}

# ── Game state ────────────────────────────────────────────────────────────────
var turn_number:   int    = 1


# Hand size modifiers — adjusted by scored agendas, installed cards, etc.
var corp_hand_size_bonus:   int = 0   # added to base of 5
var runner_hand_size_bonus: int = 0   # added to base of 5
var active_player: String = "corp"
var game_over:     bool   = false
var winner:        String = ""

# ── Decision makers ───────────────────────────────────────────────────────────
var corp_decision_maker:   Object = null
var runner_decision_maker: Object = null

# ── Event log ─────────────────────────────────────────────────────────────────
var event_log: Array = []

# Holds active structural events. Format: {"event_name": Array[Dictionary]}
var _event_listeners: Dictionary = {}

# Holds constant environmental modifications. Format: {"modifier_type": Array[Dictionary]}
var _state_modifiers: Dictionary = {}


# ── Initialisation ────────────────────────────────────────────────────────────

func _init() -> void:
	for id in ["hq", "rd", "archives"]:
		servers[id] = Server.make(id)


# ── Server management ─────────────────────────────────────────────────────────

func get_server(server_id: String) -> Server:
	return servers.get(server_id, null)

func create_remote_server() -> Server:
	var idx := 0
	while servers.has("remote_%d" % idx):
		idx += 1
	var id     := "remote_%d" % idx
	var server := Server.make(id)
	servers[id] = server
	return server

func get_remote_servers() -> Array:
	var result: Array = []
	for key in servers:
		if (servers[key] as Server).is_remote():
			result.append(servers[key])
	return result

func remove_empty_remote_servers() -> void:
	var to_remove: Array = []
	for key in servers:
		var s: Server = servers[key] as Server
		if s.is_remote() and s.is_empty():
			to_remove.append(key)
	for key in to_remove:
		servers.erase(key)


# ── Installed card queries ────────────────────────────────────────────────────

func all_installed() -> Array:
	var result: Array = []
	for server in servers.values():
		var s: Server = server as Server
		result.append_array(s.ice)
		result.append_array(s.root)
	return result

func get_runner_installed_by_type(card_type: String) -> Array:
	return runner_rig.filter(func(c: InstalledCard): return c.card_record != null and c.card_record.card_type == card_type)

# Query by static database card slug (e.g. "sure-gamble", "tollbooth")
func get_installed_card_by_id(card_id: String) -> InstalledCard:
	for card in all_installed():
		var c: InstalledCard = card as InstalledCard
		if c.card_id == card_id:
			return c
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c.card_id == card_id:
			return c
	return null

# Query by unique engine board instance id (e.g. "ice_1749204")
func get_installed_card_by_instance_id(instance_id: String) -> InstalledCard:
	for card in all_installed():
		var c: InstalledCard = card as InstalledCard
		if c.runtime_instance_id == instance_id:
			return c
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c.runtime_instance_id == instance_id:
			return c
	return null


# ── Registry Mutators ─────────────────────────────────────────────────────────

func register_listener(event_type: String, instance_id: String, ability_def: Dictionary) -> void:
	if not _event_listeners.has(event_type):
		_event_listeners[event_type] = []
	_event_listeners[event_type].append({
		"card_instance_id": instance_id,
		"ability_def": ability_def
	})

func register_modifier(mod_type: String, instance_id: String, value_modifier: int, conditions: Dictionary = {}) -> void:
	if not _state_modifiers.has(mod_type):
		_state_modifiers[mod_type] = []
	_state_modifiers[mod_type].append({
		"card_instance_id": instance_id,
		"value": value_modifier,
		"conditions": conditions
	})

func unregister_all_card_effects(instance_id: String) -> void:
	for event_type in _event_listeners:
		var list: Array = _event_listeners[event_type]
		for i in range(list.size() - 1, -1, -1):
			if list[i]["card_instance_id"] == instance_id:
				list.remove_at(i)
				
	for mod_type in _state_modifiers:
		var list: Array = _state_modifiers[mod_type]
		for i in range(list.size() - 1, -1, -1):
			if list[i]["card_instance_id"] == instance_id:
				list.remove_at(i)


# ── Dynamic Cost and Value Queries ────────────────────────────────────────────

func query_rez_cost(card: InstalledCard) -> int:
	var base_cost: int = card.card_record.cost if card.card_record else 0
	base_cost = max(0, base_cost)
	
	var modifiers: Array = _state_modifiers.get("rez_cost", [])
	var total_mod := 0
	for mod in modifiers:
		if _evaluate_modifier_condition(mod["conditions"] as Dictionary, card):
			total_mod += mod["value"] as int
			
	return max(0, base_cost + total_mod)

func _evaluate_modifier_condition(cond: Dictionary, card: InstalledCard) -> bool:
	if cond.is_empty():
		return true
	if cond.has("card_type") and card.card_record.card_type != cond["card_type"]:
		return false
	if cond.has("zone") and card.zone != cond["zone"]:
		return false
	return true


# ── Event Dispatching Engine ──────────────────────────────────────────────────

func notify_event(event_type: String, event_data: Dictionary, interpreter: AbilityInterpreter) -> void:
	if not _event_listeners.has(event_type):
		return
		
	var active_triggers: Array = _event_listeners[event_type]
	var corp_triggers: Array[Dictionary] = []
	var runner_triggers: Array[Dictionary] = []
	
	for trigger in active_triggers:
		var owner = get_card_owner_by_instance_id(trigger["card_instance_id"] as String)
		if owner == "corp":
			corp_triggers.append(trigger)
		else:
			runner_triggers.append(trigger)
			
	if active_player == "corp":
		await _execute_player_trigger_queue(corp_triggers, "corp", event_data, interpreter)
		await _execute_player_trigger_queue(runner_triggers, "runner", event_data, interpreter)
	else:
		await _execute_player_trigger_queue(runner_triggers, "runner", event_data, interpreter)
		await _execute_player_trigger_queue(corp_triggers, "corp", event_data, interpreter)


func _execute_player_trigger_queue(triggers: Array[Dictionary], player: String, event_data: Dictionary, interpreter: Object) -> void:
	if triggers.is_empty():
		return
		
	var dm = corp_decision_maker if player == "corp" else runner_decision_maker
	
	# While simultaneous triggers exist, let the choice maker pick execution order
	while not triggers.is_empty():
		var chosen_idx := 0
		if triggers.size() > 1 and dm != null and dm.has_method("choose_trigger_order"):
			chosen_idx = await dm.choose_trigger_order(triggers, self)
			
		# pop_at removes the element AND returns it cleanly
		var targeting_trigger: Dictionary = triggers.pop_at(chosen_idx)
		
		# Set transient variable — merge card's own instance_id so self-referencing
		# effects (add_self_counters, etc.) can find the owning card
		var merged_data: Dictionary = event_data.duplicate()
		merged_data["card_instance_id"] = targeting_trigger.get("card_instance_id", "")
		self.current_event_data = merged_data
		await interpreter.execute_trigger(targeting_trigger["ability_def"] as Dictionary, self)


# Explicit board state scan to determine whether the Corp or Runner controls the effect
func get_card_owner_by_instance_id(instance_id: String) -> String:
	# 1. Check Corp servers
	for server in servers.values():
		var s: Server = server as Server
		for c in s.ice:
			if (c as InstalledCard).runtime_instance_id == instance_id:
				return "corp"
		for c in s.root:
			if (c as InstalledCard).runtime_instance_id == instance_id:
				return "corp"
	# 2. Check Runner Rig
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c.runtime_instance_id == instance_id:
			return "runner"
	# 3. Identity fallbacks
	if instance_id.begins_with("runner_identity"):
		return "runner"
	return "corp"


# ── Score queries ─────────────────────────────────────────────────────────────

func corp_agenda_points() -> int:
	var total := 0
	for card in corp_score_area:
		total += (card as CardRecord).agenda_points
	return total

func runner_agenda_points() -> int:
	var total := 0
	for card in runner_score_area:
		total += (card as CardRecord).agenda_points
	return total


# ── Credit helpers ────────────────────────────────────────────────────────────

func query_breaker_strength_bonus() -> int:
	# Sum all active breaker_strength modifiers (e.g. Turbine)
	var total := 0
	var mods: Array = _state_modifiers.get("breaker_strength", [])
	for mod in mods:
		total += mod.get("value", 0) as int
	return total


func corp_max_hand_size() -> int:
	return 5 + corp_hand_size_bonus

func runner_max_hand_size() -> int:
	return 5 + runner_hand_size_bonus


func get_credits(subject: String) -> int:
	match subject:
		"corp":   return corp_credits
		"runner": return runner_credits
	push_error("GameContext: unknown subject '%s'" % subject)
	return 0

func set_credits(subject: String, amount: int) -> void:
	match subject:
		"corp":   corp_credits   = max(0, amount)
		"runner": runner_credits = max(0, amount)
		_: push_error("GameContext: unknown subject '%s'" % subject)

func runner_is_tagged() -> bool:
	return runner_tags > 0


# ── Counter helper ────────────────────────────────────────────────────────────

func get_counters_on_accessed_card(counter_type: String) -> int:
	var card := get_installed_card_by_instance_id(accessed_card_id)
	if card == null:
		# Fall back to slug search if accessed_card_id was a fallback slug
		card = get_installed_card_by_id(accessed_card_id)
	if card == null:
		return 0
	return card.get_counter(counter_type)


# ── Log ───────────────────────────────────────────────────────────────────────

func log(message: String) -> void:
	event_log.append(message)
	print("[GameContext] " + message)

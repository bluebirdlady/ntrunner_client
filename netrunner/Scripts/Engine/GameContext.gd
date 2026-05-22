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

# ── Decision-makers────────────────────────────────────────────────────────────
var corp_decision_maker:  Object = null
var runner_decision_maker:  Object = null

# ── Hands ─────────────────────────────────────────────────────────────────────
# Each entry: {"card_id": String, "card_record": CardRecord}
var corp_hand:   Array = []
var runner_hand: Array = []   # runner's "grip"

# ── Decks ─────────────────────────────────────────────────────────────────────
var corp_deck: Array[CardRecord] = []
var runner_deck: Array[CardRecord] = []
var corp_discard: Array[CardRecord] = []
var runner_discard: Array[CardRecord] = []
# Cards in Archives that were installed unrezzed when trashed — facedown until accessed.
var corp_discard_facedown: Dictionary = {}
# Instance IDs of cards the Corp installed this turn (for Seamless Launch restriction)
var corp_installed_this_turn: Array = []

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
# Tracks whether the runner has made a successful run this turn.
# Used by conditional install costs (e.g. Carmen: costs 3 instead of 5).
# Cleared at the start of each runner turn.
var runner_made_successful_run_this_turn: bool = false
# Tracks which central server IDs the runner has already attempted this turn.
# Used by Red Team to enforce "a central you have not already run this turn".
# Cleared at the start of each runner turn.
var runner_centrals_run_this_turn: Array = []
# Tracks how many times the runner has used click-draw this turn (for Verbal Plasticity)
var runner_click_draws_this_turn: int = 0
# Tracks which cards have already fired their "first HQ breach" bonus this turn (Docklands Pass)
var runner_hq_breached_this_turn: bool = false
# Tracks whether runner has already trashed during a breach this turn (Loup trigger guard)
var runner_trashed_during_breach_this_turn: bool = false
# Tracks whether DZMZ Optimizer discount has been used this turn
var runner_program_install_discounted_this_turn: bool = false
# Tracks whether Carnivore has been used this turn (once per turn)
var runner_carnivore_used_this_turn: bool = false
# Tracks whether Corp has already gained Built-to-Last advance credits this turn
var corp_gained_advance_credits_this_turn: bool = false
# Tracks whether Corp discarded to hand limit last turn (Restoring Humanity)
var corp_discarded_to_hand_limit_last_turn: bool = false
# Agenda points on the last agenda the Corp scored this turn (0 if none yet).
# Used by Neurospike to determine both play legality and damage amount.
# Cleared at the start of each Corp turn.
var corp_last_scored_agenda_points: int = 0
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

# ── Identities ────────────────────────────────────────────────────────────────
var corp_identity:   CardRecord = null
var runner_identity: CardRecord = null

# Convenience helpers — return the short name from the identity title,
# or a generic fallback if no identity is set.
# Identity titles are typically "Faction: Short Name", e.g.
# "Haas-Bioroid: Precision Design" → "Precision Design"
# "The Catalyst: Convention Breaker" → "The Catalyst"
func corp_name() -> String:
	if corp_identity == null:
		return "Corp"
	var title: String = corp_identity.title
	var colon: int = title.find(": ")
	return title.substr(colon + 2) if colon >= 0 else title

func runner_name() -> String:
	if runner_identity == null:
		return "Runner"
	var title: String = runner_identity.title
	var colon: int = title.find(": ")
	return title.substr(colon + 2) if colon >= 0 else title

func player_name(player: String) -> String:
	return corp_name() if player == "corp" else runner_name()

# ── Memory Unit tracking ───────────────────────────────────────────────────────

# Base MU from runner identity (default 4 per rules if identity has none set)
func runner_base_mu() -> int:
	if runner_identity != null and runner_identity.memory_limit > 0:
		return runner_identity.memory_limit
	return 4   # default per rules

# Additional MU granted by installed hardware/resources (e.g. Pennyshaver +1)
func runner_mu_bonus() -> int:
	var bonus := 0
	for mod in _state_modifiers.get("mu_bonus", []):
		bonus += (mod as Dictionary).get("value", 0) as int
	return bonus

# Total MU the runner has available
func runner_total_mu() -> int:
	return runner_base_mu() + runner_mu_bonus()

# MU currently consumed by installed programs (including those hosted on ice)
func runner_mu_used() -> int:
	var used := 0
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c != null and c.card_record != null and c.card_record.memory_cost > 0:
			used += c.card_record.memory_cost
	# Also count programs hosted on ice
	for server in servers.values():
		for ice in (server as Server).ice:
			for hosted in (ice as InstalledCard).hosted_cards:
				var h: InstalledCard = hosted as InstalledCard
				if h != null and h.card_record != null and h.card_record.memory_cost > 0:
					used += h.card_record.memory_cost
	return used

# MU still available for programs
func runner_mu_available() -> int:
	return runner_total_mu() - runner_mu_used()

func runner_link_bonus() -> int:
	var bonus := 0
	for mod in _state_modifiers.get("link_bonus", []):
		bonus += (mod as Dictionary).get("value", 0) as int
	return bonus

func runner_total_link() -> int:
	var base: int = runner_identity.base_link if runner_identity != null and runner_identity.base_link >= 0 else 0
	return base + runner_link_bonus()

# Set by TurnManager at game start based on identities (6 for starters, 7 otherwise)
var agenda_points_to_win: int = 7

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

func remove_meta_if_exists(key: String) -> void:
	if has_meta(key):
		remove_meta(key)

# Returns all programs available during an encounter with a specific ice:
# the normal rig PLUS any programs hosted on that ice (Botulus, Tranquilizer).
func all_programs_for_encounter(ice_card: InstalledCard) -> Array:
	var result: Array = runner_rig.duplicate()
	if ice_card != null:
		for hosted in ice_card.hosted_cards:
			if not result.has(hosted):
				result.append(hosted)
	return result

# Find a piece of ice anywhere in the Corp's servers by instance_id.
func get_ice_by_instance_id(instance_id: String) -> InstalledCard:
	for server in servers.values():
		var s: Server = server as Server
		for ice in s.ice:
			var c: InstalledCard = ice as InstalledCard
			if c.runtime_instance_id == instance_id:
				return c
	return null

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
	# Guard against duplicate registration for the same card instance
	for existing in _event_listeners[event_type]:
		if (existing as Dictionary).get("card_instance_id", "") == instance_id:
			return
	_event_listeners[event_type].append({
		"card_instance_id": instance_id,
		"ability_def": ability_def
	})

func register_modifier(mod_type: String, instance_id: String, value_modifier: int, conditions: Dictionary = {}, extra: Dictionary = {}) -> void:
	if not _state_modifiers.has(mod_type):
		_state_modifiers[mod_type] = []
	# Guard against duplicate registration
	for existing in _state_modifiers[mod_type]:
		if (existing as Dictionary).get("card_instance_id", "") == instance_id:
			return
	var entry := {
		"card_instance_id": instance_id,
		"value": value_modifier,
		"conditions": conditions
	}
	# Merge any extra fields (e.g. card_id, method for dynamic_base_strength)
	for key in extra:
		entry[key] = extra[key]
	_state_modifiers[mod_type].append(entry)

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
	if instance_id == "identity_runner" or instance_id.begins_with("runner_identity"):
		return "runner"
	if instance_id == "identity_corp":
		return "corp"
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


func query_dynamic_breaker_base(breaker: InstalledCard) -> int:
	# Returns a dynamic base strength for a specific breaker, or -1 if none applies.
	if breaker.card_record == null:
		return -1
	var mods: Array = _state_modifiers.get("dynamic_base_strength", [])
	for mod in mods:
		var d := mod as Dictionary
		if d.get("card_id", "") != breaker.card_id:
			continue
		var method: String = d.get("method", "")
		match method:
			"installed_icebreaker_count":
				# Both Unity and Echelon count all installed icebreakers including themselves
				return count_installed_icebreakers()
	return -1


func count_installed_icebreakers() -> int:
	var count := 0
	for card in runner_rig:
		var c: InstalledCard = card as InstalledCard
		if c == null or c.card_record == null:
			continue
		if c.card_record.has_subtype("icebreaker") or \
		   c.card_record.subtypes.any(func(s): return s in ["fracter", "decoder", "killer", "ai"]):
			count += 1
	return count


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

# Total credits available to the runner including any Overclock pool
func runner_available_credits() -> int:
	return runner_credits + run_modifiers.get("overclock_credits", 0)

# Spend runner credits, drawing from Overclock pool first, then own pool.
# Returns false if insufficient total credits.
func runner_spend_credits(amount: int) -> bool:
	var overclock: int = run_modifiers.get("overclock_credits", 0)
	var total: int     = runner_credits + overclock
	if total < amount:
		return false
	var from_overclock: int = min(amount, overclock)
	var from_own: int       = amount - from_overclock
	run_modifiers["overclock_credits"] = overclock - from_overclock
	runner_credits -= from_own
	return true

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

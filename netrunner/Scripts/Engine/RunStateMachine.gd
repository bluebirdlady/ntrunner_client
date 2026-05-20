class_name RunStateMachine
extends RefCounted

# ── RunStateMachine ───────────────────────────────────────────────────────────
# Drives a single run from initiation through to the End phase.
# Owns no game state — reads and writes a GameContext.
# Fires the AbilityInterpreter at the correct timing windows.
# Asks decision_makers for Corp and Runner choices.

enum Phase {
	INITIATION,
	APPROACH_ICE,
	ENCOUNTER_ICE,
	MOVEMENT,
	SUCCESS,
	END,
}

var ctx:              GameContext
var ability_registry: AbilityRegistry
var interpreter:      AbilityInterpreter

# Run position tracking
var _target_server:   Server       = null
var _ice_positions:   Array        = []   # ordered ice, outermost first
var _ice_index:       int          = 0    # current position in _ice_positions
var _current_phase:   Phase        = Phase.INITIATION

# Signals — the UI listens to these to update the display
signal phase_changed(phase: Phase)
signal ice_approached(ice_card: InstalledCard)
signal ice_encountered(ice_card: InstalledCard)
signal ice_rezzed(ice_card: InstalledCard)
signal subroutine_resolving(ice_card: InstalledCard, sub_index: int, sub_def: Dictionary)
signal subroutine_broken(ice_card: InstalledCard, sub_index: int)
signal encounter_started(encounter: EncounterState)
signal encounter_updated(encounter: EncounterState)
signal run_succeeded(server_id: String)
signal run_ended_unsuccessfully(reason: String)
signal card_accessed(card_record: CardRecord, outcome: String)

# Structural window notifications for UI state synchronization
signal timing_window_opened(priority_actor: String)
signal timing_window_closed()


# ── Construction ──────────────────────────────────────────────────────────────

func _init(game_ctx: GameContext, ab_registry: AbilityRegistry) -> void:
	ctx              = game_ctx
	ability_registry = ab_registry
	interpreter      = AbilityInterpreter.new()


# ── Entry point ───────────────────────────────────────────────────────────────

func execute(server_id: String) -> void:
	var server := ctx.get_server(server_id)
	if server == null:
		push_error("RunStateMachine: unknown server '%s'" % server_id)
		return

	_target_server = server
	_ice_positions = server.ice.duplicate()  # snapshot at run start
	_ice_index     = 0

	ctx.run_active        = true
	ctx.run_ended         = false
	ctx.run_successful    = false
	ctx.run_target_server = server_id

	ctx.log("--- Run on %s begins ---" % server.display_name())
	await _phase_initiation()


# ── Phase 1: Initiation ───────────────────────────────────────────────────────

func _phase_initiation() -> void:
	_set_phase(Phase.INITIATION)
	ctx.log("[Initiation] Run declared on %s." % _target_server.display_name())

	# Notify structural event hooks that a run has commenced
	await ctx.notify_event("run_start", {"server_id": _target_server.server_id}, interpreter)

	if _ice_positions.is_empty():
		ctx.log("[Initiation] No ice protecting server — proceeding to root.")
		await _phase_movement()
	else:
		await _phase_approach_ice()


# ── Phase 2: Approach Ice ─────────────────────────────────────────────────────

func _phase_approach_ice() -> void:
	_set_phase(Phase.APPROACH_ICE)
	var ice_card: InstalledCard = _ice_positions[_ice_index]
	ctx.log("[Approach] Runner approaches %s (position %d)." % [
		ice_card.display_name() if ice_card.is_rezzed else "unrezzed ice",
		_ice_index
	])
	emit_signal("ice_approached", ice_card)

	# 1. Notify listeners that ice is approached (e.g., dynamic environmental modifiers)
	await ctx.notify_event("approach_ice", {"ice": ice_card}, interpreter)

	# 2. Open a structural priority-passing window where players can use abilities or rez ice
	await _execute_paid_ability_and_rez_window(true)

	if ctx.run_ended:
		await _phase_end()
		return

	if ice_card.is_rezzed:
		await _phase_encounter_ice(ice_card)
	else:
		ctx.log("[Approach] Corp declines to rez. Runner passes unrezzed ice.")
		await _phase_movement()


# ── Phase 3: Encounter Ice ────────────────────────────────────────────────────

func _phase_encounter_ice(ice_card: InstalledCard) -> void:
	_set_phase(Phase.ENCOUNTER_ICE)
	ctx.log("[Encounter] Runner encounters %s." % ice_card.display_name())
	emit_signal("ice_encountered", ice_card)

	# Notify encounter hooks (e.g. Tithe's on_encounter credit gain)
	await ctx.notify_event("encounter_ice", {"ice": ice_card}, interpreter)

	# Paid ability window before breaking
	await _execute_paid_ability_and_rez_window(false)

	if ctx.run_ended:
		await _phase_end()
		return

	var subroutines: Array = ability_registry.get_subroutines(ice_card.card_id)
	if subroutines.is_empty():
		ctx.log("[Encounter] %s has no implemented subroutines — treating as blank." % ice_card.display_name())
	else:
		# Build encounter state with available icebreakers
		var encounter := EncounterState.make(ice_card, subroutines, ctx.runner_rig, ctx)
		emit_signal("encounter_started", encounter)

		# Iterative break loop — runner acts until they pass
		if ctx.runner_decision_maker != null:
			while not ctx.run_ended:
				var action: Dictionary = await ctx.runner_decision_maker.choose_encounter_action(encounter, ctx)
				if action.get("type", "") == "done":
					break
				await interpreter.process_encounter_action(action, encounter, ctx, ability_registry)
				emit_signal("encounter_updated", encounter)

		# Resolve unbroken subroutines
		for i in range(subroutines.size()):
			if encounter.is_broken(i):
				ctx.log("[Encounter] Subroutine %d broken." % i)
				emit_signal("subroutine_broken", ice_card, i)
				continue

			emit_signal("subroutine_resolving", ice_card, i, subroutines[i] as Dictionary)
			await interpreter.execute_subroutine(subroutines[i] as Dictionary, ctx)

			if ctx.run_ended:
				ctx.log("[Encounter] Run ended by subroutine.")
				await _phase_end()
				return

	await _phase_movement()


# ── Phase 4: Movement ─────────────────────────────────────────────────────────

func _phase_movement() -> void:
	_set_phase(Phase.MOVEMENT)

	# Notify passing milestone effects
	if _ice_index < _ice_positions.size():
		await ctx.notify_event("pass_ice", {"ice": _ice_positions[_ice_index]}, interpreter)

	# Replaces the old legacy non-ice window loop with your robust priority engine
	await _execute_paid_ability_and_rez_window(false)
	if ctx.run_ended:
		await _phase_end()
		return

	# Runner check window for jacking out of standard servers
	var jack_out := await _runner_jack_out_window()
	if jack_out:
		ctx.log("[Movement] Runner jacks out.")
		await _phase_end()
		return

	# Advance engine position pointer across deep ice setups
	_ice_index += 1
	if _ice_index < _ice_positions.size():
		await _phase_approach_ice()
	else:
		ctx.log("[Movement] Runner approaches the server root.")
		await ctx.notify_event("approach_server", {"server_id": _target_server.server_id}, interpreter)
		await _phase_success()


# ── Phase 5: Success ─────────────────────────────────────────────────────────

func _phase_success() -> void:
	_set_phase(Phase.SUCCESS)
	ctx.run_successful = true
	ctx.log("[Success] Run successful on %s!" % _target_server.display_name())
	emit_signal("run_succeeded", _target_server.server_id)

	# Global announcement triggers
	await ctx.notify_event("successful_run", {"server_id": _target_server.server_id}, interpreter)

	# Red Team payout: take hosted credits before breach
	if ctx.has_meta("red_team_pending_payout"):
		var payout: Dictionary = ctx.get_meta("red_team_pending_payout") as Dictionary
		if payout.get("server_id", "") == _target_server.server_id:
			var iid: String          = payout.get("card_instance_id", "")
			var counter: String      = payout.get("counter", "credits")
			var amount: int          = payout.get("amount", 3)
			var self_card: InstalledCard = ctx.get_installed_card_by_instance_id(iid)
			if self_card != null:
				var available: int = self_card.get_counter(counter)
				var taken: int     = min(amount, available)
				if taken > 0:
					self_card.remove_counter(counter, taken)
					ctx.runner_credits += taken
					ctx.log("Red Team: %s takes %d cr (%d remaining on Red Team)." % [
						ctx.runner_name(), taken, self_card.get_counter(counter)
					])

	await _breach_server()
	await _phase_end()


# ── Phase 6: End ─────────────────────────────────────────────────────────────

func _phase_end() -> void:
	_set_phase(Phase.END)
	ctx.run_active = false

	if ctx.run_successful:
		ctx.log("[End] Run ended successfully.")
	else:
		ctx.log("[End] Run ended unsuccessfully.")
		emit_signal("run_ended_unsuccessfully",
			"subroutine" if ctx.run_ended else "jack_out")

	# Final cleanup triggers
	await ctx.notify_event("run_end", {"server_id": _target_server.server_id, "successful": ctx.run_successful}, interpreter)

	# Return unspent Overclock credits to the bank (they don't carry over)
	var overclock_remaining: int = ctx.run_modifiers.get("overclock_credits", 0)
	if overclock_remaining > 0:
		ctx.log("Overclock: %d unspent credit(s) returned to the bank." % overclock_remaining)

	ctx.run_ended      = false
	ctx.run_modifiers  = {}   # clear all run-scoped modifiers


# ── Breach ────────────────────────────────────────────────────────────────────

func _breach_server() -> void:
	ctx.log("[Breach] Runner breaches %s." % _target_server.display_name())

	var access_list: Array = _target_server.get_root_access_cards()
	var _hq_accessed_indices: Array = []   # tracks HQ hand indices already in access_list

	match _target_server.server_id:
		"hq":
			if not ctx.corp_hand.is_empty():
				var idx: int = randi() % ctx.corp_hand.size()
				access_list.append(ctx.corp_hand[idx])
				_hq_accessed_indices.append(idx)
		"rd":
			if not ctx.corp_deck.is_empty():
				access_list.append(ctx.corp_deck[0])
		"archives":
			# Per rules: before accessing, all facedown cards in Archives are turned faceup.
			if not ctx.corp_discard_facedown.is_empty():
				ctx.log("[Breach] Corp turns %d facedown card(s) in Archives faceup." % ctx.corp_discard_facedown.size())
				ctx.corp_discard_facedown.clear()
			access_list.append_array(ctx.corp_discard)

	# Apply bonus access from run modifiers (e.g. Docklands Pass, Jailbreak, Conduit)
	var bonus_access: int = ctx.run_modifiers.get("bonus_access", 0)
	if bonus_access > 0:
		match _target_server.server_id:
			"hq":
				var available: Array = []
				for i in range(ctx.corp_hand.size()):
					if i not in _hq_accessed_indices:
						available.append(i)
				available.shuffle()
				for i in range(min(bonus_access, available.size())):
					var pick_idx: int = available[i]
					access_list.append(ctx.corp_hand[pick_idx])
					_hq_accessed_indices.append(pick_idx)
			"rd":
				for i in range(bonus_access):
					if i + 1 < ctx.corp_deck.size():
						access_list.append(ctx.corp_deck[i + 1])
		ctx.log("[Breach] Bonus access: %d extra card(s)." % bonus_access)

	if access_list.is_empty():
		ctx.log("[Breach] Nothing to access.")
		return

	for card in access_list:
		await _access_card(card)
		if ctx.game_over:
			break


func _access_card(card: Variant) -> void:
	var card_id: String = ""
	var card_record: CardRecord = null
	var instance_id: String = ""

	if card is InstalledCard:
		var ic := card as InstalledCard
		card_id     = ic.card_id
		card_record = ic.card_record
		instance_id = ic.runtime_instance_id
	elif card is Dictionary:
		var d := card as Dictionary
		card_id     = d.get("card_id", "")
		card_record = d.get("card_record", null) as CardRecord
		instance_id = d.get("runtime_instance_id", "")
	elif card is CardRecord:
		# Raw CardRecord — comes from corp_deck (R&D access) or corp_discard
		card_record = card as CardRecord
		card_id     = card_record.id

	ctx.accessed_card_id = instance_id if instance_id != "" else card_id
	ctx.log("[Access] Runner accesses: %s" % (card_record.title if card_record else card_id))

	# Universal framework dispatch trigger
	await ctx.notify_event("access_card", {"card_id": card_id, "runtime_instance_id": instance_id}, interpreter)

	# on_access abilities only fire when the card is accessed while installed (not from Archives/heap)
	# A card accessed from Archives is a CardRecord or a dict without a live server reference.
	var is_installed: bool = (card is InstalledCard)
	if is_installed:
		var on_access_def = ability_registry.get_on_access(card_id)
		if on_access_def != null:
			await interpreter.execute_trigger(on_access_def as Dictionary, ctx)

	# Stop immediately if damage caused a flatline
	if ctx.game_over:
		return

	if card_record == null:
		return

	if card_record.is_agenda():
		await _steal_agenda(card_record)
	elif card_record.is_asset() or card_record.card_type == "upgrade":
		# Don't offer trash for cards already in Archives
		if is_installed:
			await _offer_trash(card, card_record)

	# Stop if game ended during steal or trash resolution
	if ctx.game_over:
		return

	# Determine outcome for display
	var _outcome := "accessed"
	if card_record != null and card_record.is_agenda():
		_outcome = "stolen"
	emit_signal("card_accessed", card_record, _outcome)

	# Wait for the UI to finish displaying this card before accessing the next one.
	if ctx.has_meta("on_card_display_done"):
		var cb: Callable = ctx.get_meta("on_card_display_done") as Callable
		await cb.call(card_record, _outcome)

func _steal_agenda(card_record: CardRecord) -> void:
	ctx.log("[Access] Runner steals %s! (%d agenda points)" % [
		card_record.title, card_record.agenda_points
	])
	ctx.runner_score_area.append(card_record)

	for server in ctx.servers.values():
		var s: Server = server as Server
		for installed in s.root:
			var c: InstalledCard = installed as InstalledCard
			if c.card_id == card_record.id:
				s.remove_from_root(c)
				break

	# Fire on_steal ability (e.g. Send a Message, Superconducting Hub)
	var on_steal_def = ability_registry.get_on_steal(card_record.id)
	if on_steal_def != null:
		await interpreter.execute_trigger(on_steal_def as Dictionary, ctx)

	# Check if runner has won by stealing this agenda
	if ctx.runner_agenda_points() >= ctx.agenda_points_to_win:
		ctx.log("Runner wins by stealing agendas!")
		ctx.game_over = true
		ctx.winner    = "runner"


func _offer_trash(card: Variant, card_record: CardRecord) -> void:
	if card_record.trash_cost < 0:
		return
	ctx.log("[Access] Runner may trash %s for %d credits (Runner has %d)." % [
		card_record.title, card_record.trash_cost, ctx.runner_available_credits()
	])
	if ctx.runner_available_credits() < card_record.trash_cost:
		ctx.log("[Access] Runner cannot afford to trash.")
		return

	var should_trash := false
	if ctx.runner_decision_maker != null:
		should_trash = await ctx.runner_decision_maker.choose_trash(card_record, ctx)

	if should_trash:
		ctx.runner_spend_credits(card_record.trash_cost)
		ctx.log("[Access] Runner trashes %s." % card_record.title)
		if card is InstalledCard:
			var installed: InstalledCard = card as InstalledCard
			var server: Server = ctx.get_server(installed.server_id)
			if server:
				server.remove_from_root(installed)
			# Unrezzed cards go facedown in Archives
			if not installed.is_rezzed:
				ctx.corp_discard_facedown[card_record.title] = true
		ctx.corp_discard.append(card_record)


# ── Decision windows ──────────────────────────────────────────────────────────

func _rez_card(card: InstalledCard) -> void:
	if card.is_rezzed:
		return
	var record: CardRecord = card.card_record
	if record == null:
		return
		
	var rez_cost: int = ctx.query_rez_cost(card)
	# Apply run-scoped extra rez cost (e.g. Tread Lightly)
	rez_cost += ctx.run_modifiers.get("extra_rez_cost", 0)
	if ctx.corp_credits < rez_cost:
		ctx.log("[Rez] Corp cannot afford to rez %s (costs %d, has %d)." % [
			card.card_id, rez_cost, ctx.corp_credits
		])
		return

	ctx.corp_credits -= rez_cost
	card.is_rezzed    = true
	ctx.log("[Rez] Corp rezzes %s for %d credits." % [record.title, rez_cost])
	emit_signal("ice_rezzed", card)

	# Core notification framework hook
	await ctx.notify_event("rez_card", {"card": card}, interpreter)

	var on_rez_def = ability_registry.get_on_rez(card.card_id)
	if on_rez_def != null:
		await interpreter.execute_trigger(on_rez_def as Dictionary, ctx)


# Kept for external callers; new code uses encounter loop directly
func _runner_break_subroutines(_ice_card: InstalledCard, _subroutines: Array) -> Array:
	return []


func _runner_jack_out_window() -> bool:
	if ctx.runner_decision_maker == null:
		return false
	return await ctx.runner_decision_maker.choose_jack_out(ctx)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_phase(phase: Phase) -> void:
	_current_phase = phase
	emit_signal("phase_changed", phase)


# ── Timing Windows Loop ───────────────────────────────────────────────────────

func _execute_paid_ability_and_rez_window(can_rez_ice: bool = false) -> void:
	var current_priority_actor: String = ctx.active_player
	var consecutive_passes := 0
	
	emit_signal("timing_window_opened", current_priority_actor)
	
	while consecutive_passes < 2:
		var dm = ctx.corp_decision_maker if current_priority_actor == "corp" else ctx.runner_decision_maker
		if dm == null or not dm.has_method("choose_window_action"):
			consecutive_passes += 1
			current_priority_actor = "runner" if current_priority_actor == "corp" else "corp"
			continue
			
		var chosen_action: GameAction = await dm.choose_window_action(ctx, current_priority_actor, can_rez_ice)
		
		if chosen_action == null or chosen_action.type == "pass":
			consecutive_passes += 1
			current_priority_actor = "runner" if current_priority_actor == "corp" else "corp"
		else:
			consecutive_passes = 0
			await _process_window_action(chosen_action, current_priority_actor, can_rez_ice)

	emit_signal("timing_window_closed")


func _process_window_action(action: GameAction, actor: String, can_rez_ice: bool) -> void:
	match action.type:
		"rez_card":
			if actor != "corp":
				return
			var card_id = action.params.get("card_id", "")
			var instance_id = action.params.get("card_instance_id", "")
			
			var card: InstalledCard = null
			if instance_id != "":
				card = ctx.get_installed_card_by_instance_id(instance_id)
			else:
				card = ctx.get_installed_card_by_id(card_id)
				
			if card:
				if card.is_ice() and not can_rez_ice:
					ctx.log("[Warning] Cannot rez ICE outside of approach window positions.")
					return
				await _rez_card(card)
				
		"use_paid_ability":
			var ab_def = action.params.get("ability_def", {}) as Dictionary
			if await _verify_and_pay_costs(actor, ab_def):
				# Clear out payload trace before starting clean interaction loops
				ctx.current_event_data = {} 
				await interpreter.execute_trigger(ab_def, ctx)
				
		_:
			ctx.log("Invalid structural window action executed: %s" % action.type)


func _verify_and_pay_costs(player: String, ab_def: Dictionary) -> bool:
	var cost: int = ab_def.get("cost", 0)
	var current_credits = ctx.get_credits(player)
	if current_credits >= cost:
		ctx.set_credits(player, current_credits - cost)
		return true
	return false

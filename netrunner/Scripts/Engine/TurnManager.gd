class_name TurnManager
extends RefCounted

# ── TurnManager ───────────────────────────────────────────────────────────────
# Drives the outer game loop: Corp turn, then Runner turn, repeat.
# Validates and executes GameActions produced by decision makers.
# Fires signals at each meaningful moment for the UI to consume.
# Checks win conditions after each action.
#
# Usage:
#   var tm := TurnManager.new(ctx, ability_registry)
#   tm.action_executed.connect(_on_action)
#   await tm.run_game()

const CORP_CLICKS_PER_TURN:   int = 3
const RUNNER_CLICKS_PER_TURN: int = 4
const MAX_HAND_SIZE:          int = 5

# Starter deck identities play to 6 agenda points; all others play to 7
const STARTER_CORP_ID:   String = "the_syndicate_profit_over_principle"
const STARTER_RUNNER_ID: String = "the_catalyst_convention_breaker"

var agenda_points_to_win: int = 7
# Prevents the game_over signal from firing more than once, even if ctx.game_over
# was set directly by a subsystem (e.g. RunStateMachine._steal_agenda) before
# _check_win_conditions() runs.
var _game_over_signaled: bool = false

var ctx:              GameContext
var ability_registry: AbilityRegistry
var interpreter:      AbilityInterpreter

# ── Signals ───────────────────────────────────────────────────────────────────
signal turn_started(player: String, turn_number: int)
signal action_executed(player: String, action: GameAction)
signal action_rejected(player: String, action: GameAction, reason: String)
signal game_over(winner: String, reason: String)
signal credits_changed(player: String, amount: int)
signal hand_changed(player: String)
signal card_installed(card_record: CardRecord, server_id: String)
signal card_advanced(card_id: String, counter_count: int)


# ── Construction ──────────────────────────────────────────────────────────────

func _init(game_ctx: GameContext, ab_registry: AbilityRegistry) -> void:
	ctx              = game_ctx
	ability_registry = ab_registry
	interpreter      = AbilityInterpreter.new()


# ── Main loop ─────────────────────────────────────────────────────────────────

func run_game() -> void:
	# Set win threshold: starter identities play to 6, all others to 7
	var corp_id:   String = ctx.corp_identity.id   if ctx.corp_identity   != null else ""
	var runner_id: String = ctx.runner_identity.id if ctx.runner_identity != null else ""
	if corp_id == STARTER_CORP_ID and runner_id == STARTER_RUNNER_ID:
		agenda_points_to_win = 6
		ctx.agenda_points_to_win = 6
		ctx.send_log("Starter decks detected — playing to 6 agenda points.")
	else:
		agenda_points_to_win = 7
		ctx.agenda_points_to_win = 7

	# Register identity ability listeners using synthetic instance IDs
	_register_identity_listeners("identity_runner", runner_id)
	_register_identity_listeners("identity_corp",   corp_id)

	# Expose identity re-registration so AbilityInterpreter flip effects can swap faces.
	# The callable unregisters all current listeners for the given instance_id, then
	# registers the new face's listeners from abilities.json.
	ctx.set_meta("reregister_identity", func(instance_id: String, new_card_id: String) -> void:
		ctx.unregister_all_card_effects(instance_id)
		_register_identity_listeners(instance_id, new_card_id)
	)

	while not ctx.game_over:
		await _corp_turn()
		if ctx.game_over:
			break
		await _runner_turn()


# ── Corp turn ─────────────────────────────────────────────────────────────────

func _corp_turn() -> void:
	ctx.active_player = "corp"
	var corp_penalty: int = ctx.pending_click_penalties.get("corp", 0)
	ctx.corp_clicks = max(0, CORP_CLICKS_PER_TURN - corp_penalty)
	ctx.pending_click_penalties["corp"] = 0
	ctx.corp_installed_this_turn = []   # reset for Seamless Launch restriction
	ctx.corp_gained_advance_credits_this_turn = false   # reset for Built to Last
	ctx.corp_played_operation_this_turn = false          # reset for Nebula Making Stars
	ctx.corp_last_scored_agenda_points = 0              # reset for Neurospike
	ctx.corp_agendas_scored_this_turn  = 0              # reset for first-agenda triggers
	# Capture whether the runner ran successfully last turn before this turn's reset.
	# Used by Public Trail ("Play only if the Runner made a successful run during their last turn").
	ctx.runner_made_successful_run_last_turn = ctx.runner_made_successful_run_this_turn
	ctx.corp_used_reality_plus_this_turn = false        # reset once-per-turn identity limit
	ctx.once_per_turn_triggered.clear()                # reset per-turn trigger guards
	if corp_penalty > 0:
		ctx.send_log("%s loses %d click(s) this turn (deferred penalty)." % [ctx.corp_name(), corp_penalty])

	# Draw phase: mandatory draw, then start-of-turn events
	_corp_mandatory_draw()
	emit_signal("turn_started", "corp", ctx.turn_number)
	ctx.send_log("=== %s Turn %d begins. Credits: %d, Clicks: %d ===" % [
		ctx.corp_name(), ctx.turn_number, ctx.corp_credits, ctx.corp_clicks
	])
	# Fire start-of-turn triggers (assets, upgrades, etc.)
	await ctx.notify_event("corp_turn_start", {}, interpreter)

	# Pre-click free actions: Corp may rez assets/upgrades as paid abilities before spending clicks.
	# Handled separately so the click loop only processes click-costing actions.
	if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("get_pre_click_rez_actions"):
		for rez_action in ctx.corp_decision_maker.get_pre_click_rez_actions(ctx):
			await _do_rez_card("corp", rez_action as GameAction)

	# Action phase
	while ctx.corp_clicks > 0 and not ctx.game_over:
		if ctx.corp_decision_maker == null:
			ctx.send_log("No %s decision maker — ending turn." % ctx.corp_name())
			break

		var action: GameAction = await ctx.corp_decision_maker.choose_action(ctx)
		if action == null:
			ctx.send_log("No action from %s — ending turn." % ctx.corp_name())
			break

		var result := await _execute_action("corp", action)
		if not result["ok"]:
			ctx.send_log("%s action rejected: %s" % [ctx.corp_name(), result["reason"]])
			# Give the AI another chance rather than looping forever
			# If it keeps producing invalid actions something is wrong
			break

	# Discard phase
	_corp_discard_to_hand_limit()


func _corp_mandatory_draw() -> void:
	if ctx.corp_deck.is_empty():
		ctx.send_log("%s deck is empty — %s loses!" % [ctx.corp_name(), ctx.corp_name()])
		_end_game("runner", "Corp could not draw (empty R&D)")
		return
		
	# Pop the clean object directly
	var drawn: CardRecord = ctx.corp_deck.pop_front() as CardRecord
	
	# Package it into the dictionary format your hand structure expects
	ctx.corp_hand.append({"card_id": drawn.id, "card_record": drawn})
	
	emit_signal("hand_changed", "corp")
	ctx.send_log("%s draws %s." % [ctx.corp_name(), drawn.title])


func _corp_discard_to_hand_limit() -> void:
	var did_discard := false
	while ctx.corp_hand.size() > ctx.corp_max_hand_size() and not ctx.game_over:
		# Discard the last card (AI discards from the end for simplicity)
		var discarded: Dictionary = ctx.corp_hand.pop_back() as Dictionary
		var record: CardRecord    = discarded.get("card_record", null) as CardRecord
		ctx.corp_discard.append(record)
		if record != null:
			ctx.corp_discard_facedown[record.title] = true   # hand discards always facedown
		ctx.send_log("%s discards %s to hand limit." % [ctx.corp_name(), record.title if record else "?"])
		did_discard = true
	ctx.corp_discarded_to_hand_limit_last_turn = did_discard
	emit_signal("hand_changed", "corp")


func _runner_discard_to_hand_limit() -> void:
	var limit: int = ctx.runner_max_hand_size()
	if limit < 0:
		# Already flatlined from core damage — nothing to do
		return
	while ctx.runner_hand.size() > limit and not ctx.game_over:
		# Human runner picks which card to discard; AI discards from the end for simplicity
		var discarded: Dictionary = ctx.runner_hand.pop_back() as Dictionary
		var record: CardRecord    = discarded.get("card_record", null) as CardRecord
		if record != null:
			ctx.runner_discard.append(record)
		ctx.send_log("%s discards %s to hand limit (%d)." % [
			ctx.runner_name(), record.title if record else "?", limit
		])
	emit_signal("hand_changed", "runner")


# ── Runner turn ───────────────────────────────────────────────────────────────

func _runner_turn() -> void:
	ctx.active_player  = "runner"
	var runner_penalty: int = ctx.pending_click_penalties.get("runner", 0)
	ctx.runner_clicks = max(0, RUNNER_CLICKS_PER_TURN - runner_penalty)
	ctx.pending_click_penalties["runner"] = 0
	ctx.runner_made_successful_run_this_turn = false   # reset each turn
	ctx.runner_centrals_run_this_turn = []             # reset each turn
	ctx.runner_click_draws_this_turn  = 0              # reset each turn
	ctx.runner_hq_breached_this_turn        = false    # reset each turn
	ctx.runner_hq_successful_run_this_turn  = false    # reset each turn (Détente)
	ctx.runner_trashed_during_breach_this_turn = false  # reset each turn (Loup)
	ctx.runner_program_install_discounted_this_turn = false  # reset each turn (DZMZ)
	ctx.runner_carnivore_used_this_turn = false              # reset each turn
	ctx.once_per_turn_triggered.clear()                      # reset per-turn trigger guards
	if runner_penalty > 0:
		ctx.send_log("%s loses %d click(s) this turn (deferred penalty)." % [ctx.runner_name(), runner_penalty])
	ctx.turn_number   += 1

	emit_signal("turn_started", "runner", ctx.turn_number)
	ctx.send_log("=== %s Turn %d begins. Credits: %d, Clicks: %d ===" % [
		ctx.runner_name(), ctx.turn_number, ctx.runner_credits, ctx.runner_clicks
	])
	# Fire start-of-turn triggers (resources, hardware, etc.)
	await ctx.notify_event("runner_turn_start", {}, interpreter)

	while ctx.runner_clicks > 0 and not ctx.game_over:
		if ctx.runner_decision_maker == null:
			ctx.send_log("No %s decision maker — ending turn." % ctx.runner_name())
			break

		var action: GameAction = await ctx.runner_decision_maker.choose_action(ctx)
		if action == null:
			ctx.send_log("No action from %s — ending turn." % ctx.runner_name())
			break

		var result := await _execute_action("runner", action)
		if not result["ok"]:
			ctx.send_log("%s action rejected: %s" % [ctx.runner_name(), result["reason"]])
			break

	# Discard phase: runner discards down to max hand size (relevant after core damage)
	_runner_discard_to_hand_limit()


# ── Action execution ──────────────────────────────────────────────────────────

func _execute_action(player: String, action: GameAction) -> Dictionary:
	# Validate first
	var valid := _validate_action(player, action)
	if not valid["ok"]:
		emit_signal("action_rejected", player, action, valid["reason"])
		return valid

	# Execute
	match action.type:
		"gain_credits":    await _do_gain_credits(player)
		"draw_card":       await _do_draw_card(player)
		"install":         await _do_install(player, action)
		"advance":         await _do_advance(player, action)
		"play_operation":  await _do_play_operation(player, action)
		"run":             await _do_run(action)
		"rez_card":           await _do_rez_card(player, action)
		"use_installed_card": await _do_use_installed_card(player, action)
		"end_turn":           await _do_end_turn(player)
		_:
			return {"ok": false, "reason": "Unknown action type: %s" % action.type}

	emit_signal("action_executed", player, action)
	_check_win_conditions()
	return {"ok": true, "reason": ""}


# ── Validation ────────────────────────────────────────────────────────────────

func _validate_action(player: String, action: GameAction) -> Dictionary:
	var clicks: int = ctx.corp_clicks if player == "corp" else ctx.runner_clicks

	match action.type:
		"end_turn":
			return {"ok": true, "reason": ""}

		"rez_card":
			return {"ok": true, "reason": ""}

		"use_installed_card":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			# Check for additional click costs in the card's click_action def (e.g. Rent Rioters: 3 total)
			var act_card_id: String = action.params.get("card_id", "")
			if act_card_id != "":
				var act_card_def: Dictionary = ability_registry._abilities.get(act_card_id, {}) as Dictionary
				var act_click_def: Dictionary = act_card_def.get("click_action", {}) as Dictionary
				var act_extra: int = act_click_def.get("additional_cost_clicks", 0)
				if act_extra > 0 and clicks < 1 + act_extra:
					return {"ok": false, "reason": "Not enough clicks for %s (need %d total)" % [act_card_id, 1 + act_extra]}
			return {"ok": true, "reason": ""}

		"gain_credits", "draw_card":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			return {"ok": true, "reason": ""}

		"run":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			var target: String = action.params.get("server_id", "")
			var rp_mods: Array = ctx._state_modifiers.get("block_remote_runs_unless_ran_central", [])
			if not rp_mods.is_empty() and target.begins_with("remote_"):
				if ctx.runner_centrals_run_this_turn.is_empty():
					return {"ok": false, "reason": "Replicating Perfection: you must run a central server before running on a remote."}
			return {"ok": true, "reason": ""}

		"install":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			var record: CardRecord = action.params.get("card_record", null) as CardRecord
			if record == null:
				return {"ok": false, "reason": "No card to install"}
			# Ice install costs 1 credit per existing ice on target server
			if record.is_ice():
				var server: Server = ctx.get_server(action.params.get("server_id", ""))
				var ice_cost: int  = server.ice_install_cost() if server else 0
				if ctx.get_credits(player) < ice_cost:
					return {"ok": false, "reason": "Cannot afford ice install cost"}
			return {"ok": true, "reason": ""}

		"advance":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			if ctx.get_credits(player) < 1:
				return {"ok": false, "reason": "Cannot afford advance (costs 1 credit)"}
			var card_id: String = action.params.get("card_id", "")
			var card := _find_advanceable_card(card_id)
			if card == null:
				return {"ok": false, "reason": "Card %s not found or not advanceable" % card_id}
			return {"ok": true, "reason": ""}

		"play_operation":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			var record: CardRecord = action.params.get("card_record", null) as CardRecord
			if record == null:
				return {"ok": false, "reason": "No operation to play"}
			if ctx.get_credits(player) < max(0, record.cost):
				return {"ok": false, "reason": "Cannot afford %s" % record.title}
			# Check additional click costs (e.g. Lie Low, Maintenance Access: spend 1 extra click)
			var op_card_def: Dictionary = ability_registry._abilities.get(record.id, {}) as Dictionary
			var op_extra: int = op_card_def.get("additional_cost_clicks", 0)
			if op_extra > 0 and clicks < 1 + op_extra:
				return {"ok": false, "reason": "Not enough clicks for %s (need %d total)" % [record.title, 1 + op_extra]}
			return {"ok": true, "reason": ""}

		_:
			return {"ok": false, "reason": "Unknown action type: %s" % action.type}


# ── Action implementations ────────────────────────────────────────────────────

func _do_gain_credits(player: String) -> void:
	_spend_click(player)
	ctx.set_credits(player, ctx.get_credits(player) + 1)
	emit_signal("credits_changed", player, ctx.get_credits(player))
	ctx.send_log("%s gains 1 credit. (%d total)" % [ctx.player_name(player), ctx.get_credits(player)])


func _do_draw_card(player: String) -> void:
	_spend_click(player)
	var deck: Array = ctx.corp_deck if player == "corp" else ctx.runner_deck
	
	if deck.is_empty():
		if player == "corp":
			_end_game("runner", "Corp could not draw (empty R&D)")
		else:
			ctx.send_log("%s deck is empty — cannot draw." % ctx.runner_name())
		return
		
	# Pop the object asset cleanly
	var drawn: CardRecord = deck.pop_front() as CardRecord
	var hand_entry := {"card_id": drawn.id, "card_record": drawn}
	
	if player == "corp":
		ctx.corp_hand.append(hand_entry)
	else:
		ctx.runner_hand.append(hand_entry)
		
	emit_signal("hand_changed", player)
	ctx.send_log("%s draws %s." % [ctx.player_name(player), drawn.title])

	# Verbal Plasticity: draw 1 extra card on the FIRST click-draw of the runner's turn only.
	if player == "runner":
		ctx.runner_click_draws_this_turn += 1
		if ctx.runner_click_draws_this_turn == 1:
			var mods: Array = ctx._state_modifiers.get("extra_draw_on_click_draw", [])
			if not mods.is_empty():
				var extra: int = 0
				for mod in mods:
					extra += (mod as Dictionary).get("value", 0) as int
				for _i in range(extra):
					if deck.is_empty():
						ctx.send_log("%s deck empty — Verbal Plasticity cannot draw extra." % ctx.runner_name())
						break
					var extra_card: CardRecord = deck.pop_front() as CardRecord
					ctx.runner_hand.append({"card_id": extra_card.id, "card_record": extra_card})
					ctx.send_log("Verbal Plasticity: %s draws %s." % [ctx.runner_name(), extra_card.title])
				emit_signal("hand_changed", player)


func _do_install(player: String, action: GameAction) -> void:
	_spend_click(player)
	var record: CardRecord = action.params.get("card_record", null) as CardRecord
	var server_id: String  = action.params.get("server_id", "")
	var zone: String       = action.params.get("zone", "root")

	# Runner programs, hardware, and resources go directly to the rig
	if player == "runner" and server_id == "runner_rig":
		var pay_cost: int = max(0, record.cost)

		# Conditional install cost reduction (e.g. Carmen: 5 → 3 after successful run)
		var card_def: Dictionary = ability_registry._abilities.get(record.id, {}) as Dictionary
		var conditional_cost: Variant = card_def.get("install_cost_if_successful_run", null)
		if conditional_cost != null and ctx.runner_made_successful_run_this_turn:
			pay_cost = int(conditional_cost)
			ctx.send_log("Conditional install cost applies: %s costs %d¢ this turn." % [record.title, pay_cost])

		print("Player install: card is: ", record.title, " and charged cost is: ", pay_cost)

		# DZMZ Optimizer: first program install each turn costs 1cr less
		if record.card_type == "program" and not ctx.runner_program_install_discounted_this_turn:
			var has_dzmz := false
			for rig_card in ctx.runner_rig:
				var c: InstalledCard = rig_card as InstalledCard
				if c != null and c.card_id == "dzmz_optimizer":
					has_dzmz = true
					break
			if has_dzmz:
				pay_cost = max(0, pay_cost - 1)
				ctx.runner_program_install_discounted_this_turn = true
				ctx.send_log("DZMZ Optimizer: %s costs 1 less (now %d¢)." % [record.title, pay_cost])

		# Per-icebreaker install cost reduction (e.g. Principia: 1cr less per other installed icebreaker)
		var discount_per_ib: int = card_def.get("install_cost_discount_per_icebreaker", 0)
		if discount_per_ib > 0:
			var num_other_ib := 0
			for rig_card in ctx.runner_rig:
				var c: InstalledCard = rig_card as InstalledCard
				if c == null or c.card_record == null:
					continue
				if c.card_record.has_subtype("icebreaker") or \
				   c.card_record.subtypes.any(func(s): return s in ["fracter", "decoder", "killer", "ai"]):
					num_other_ib += 1
			if num_other_ib > 0:
				var ib_discount: int = discount_per_ib * num_other_ib
				pay_cost = max(0, pay_cost - ib_discount)
				ctx.send_log("%s: %d other icebreaker(s) installed — install costs %d¢ less (now %d¢)." % [
					record.title, num_other_ib, ib_discount, pay_cost
				])

		# MU check for programs (hosted-on-ice programs still use MU)
		if record.card_type == "program" and record.memory_cost > 0:
			var mu_needed: int = record.memory_cost
			if ctx.runner_mu_available() < mu_needed:
				ctx.send_log("%s cannot install %s — not enough MU (%d needed, %d available, %d total)." % [
					ctx.runner_name(), record.title,
					mu_needed, ctx.runner_mu_available(), ctx.runner_total_mu()
				])
				return

		# ── Hosted install credits (e.g. Open Market: credits for connection/job installs) ──
		# Find the first rig card whose install_credits_for_subtypes list contains
		# any subtype of the card being installed. Its hosted credits supplement
		# runner_credits for the affordability check and are drawn down first.
		var om_source: InstalledCard = null
		var om_available: int = 0
		for rig_c in ctx.runner_rig:
			var rc: InstalledCard = rig_c as InstalledCard
			if rc == null:
				continue
			var rc_def: Dictionary = ability_registry._abilities.get(rc.card_id, {}) as Dictionary
			var allowed_sts: Array = rc_def.get("install_credits_for_subtypes", []) as Array
			if allowed_sts.is_empty():
				continue
			for st in allowed_sts:
				if record.has_subtype(st as String):
					om_source    = rc
					om_available = rc.get_counter("credits")
					break
			if om_source != null:
				break

		if ctx.runner_credits + om_available < pay_cost:
			ctx.send_log("%s cannot afford to install %s." % [ctx.runner_name(), record.title])
			return

		# Spend hosted credits first, then top up from runner's pool
		var om_used: int = 0
		if om_source != null and om_available > 0:
			om_used = min(pay_cost, om_available)
			om_source.remove_counter("credits", om_used)
			ctx.send_log("%s: %d hosted cr from %s used for %s (%d remaining)." % [
				ctx.runner_name(), om_used, om_source.display_name(),
				record.title, om_source.get_counter("credits")
			])
		ctx.runner_credits -= (pay_cost - om_used)

		# Check if this card must be hosted on a specific ice card
		var must_host_on_ice: bool = card_def.get("install_on_ice", false)
		var host_ice: InstalledCard = null
		if must_host_on_ice:
			# Ask the runner to choose a target ice
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_host_ice"):
				host_ice = await ctx.runner_decision_maker.choose_host_ice(ctx)
			if host_ice == null:
				# No valid target — find any installed ice
				for server in ctx.servers.values():
					for ice in (server as Server).ice:
						host_ice = ice as InstalledCard
						break
					if host_ice != null:
						break
			if host_ice == null:
				ctx.send_log("%s cannot install %s — no installed ice to host it." % [ctx.runner_name(), record.title])
				ctx.runner_credits += pay_cost   # refund
				return

		var installed := InstalledCard.make_runtime_instance(record, "runner_rig", "root", true)

		if must_host_on_ice and host_ice != null:
			# Host on the chosen ice rather than the general rig
			installed.hosted_on_id = host_ice.runtime_instance_id
			installed.server_id    = host_ice.server_id   # same server as host
			host_ice.hosted_cards.append(installed)
			ctx.send_log("%s hosts %s on %s." % [ctx.runner_name(), record.title, host_ice.display_name()])
		else:
			ctx.runner_rig.append(installed)

		# Boomerang-style: choose a target ice on install (no physical hosting)
		var choose_target_flag: Variant = card_def.get("choose_target_on_install", null)
		if choose_target_flag != null and not must_host_on_ice:
			var target_candidates: Array = []
			for ct_server in ctx.servers.values():
				for ct_ice in (ct_server as Server).ice:
					target_candidates.append(ct_ice as InstalledCard)
			if not target_candidates.is_empty():
				var ct_chosen: InstalledCard = null
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_host_ice"):
					ct_chosen = await ctx.runner_decision_maker.choose_host_ice(ctx)
				if ct_chosen == null:
					ct_chosen = target_candidates[0]  # fallback: first ice
				installed.target_id = ct_chosen.runtime_instance_id
				ctx.send_log("%s targets %s with %s." % [ctx.runner_name(), ct_chosen.display_name(), record.title])

		_remove_from_hand(player, record)
		_register_card_listeners(installed)
		# Fire on_rez directly on this card only — never broadcast via notify_event
		var on_rez_def = ability_registry.get_on_rez(record.id)
		if on_rez_def != null:
			ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
			await interpreter.execute_trigger(on_rez_def as Dictionary, ctx)
			ctx.current_event_data = {}
		emit_signal("card_installed", record, "runner_rig")
		emit_signal("hand_changed", player)
		# Fire runner_installs_virus for Cookbook
		if record.card_type == "program" and record.has_subtype("virus"):
			await ctx.notify_event("runner_installs_virus", {
				"card": installed,
				"card_instance_id": installed.runtime_instance_id
			}, interpreter)
		# Fire runner_installs_card for Bling and similar triggers
		await ctx.notify_event("runner_installs_card", {
			"credits_paid": pay_cost - om_used,
			"card": installed,
			"card_instance_id": installed.runtime_instance_id
		}, interpreter)
		ctx.send_log("%s installs %s. [MU: %d/%d used]" % [
			ctx.runner_name(), record.title, ctx.runner_mu_used(), ctx.runner_total_mu()
		])
		return

	# Get or create server for corp cards and runner ice (future)
	var server: Server = ctx.get_server(server_id)
	if server == null:
		server = ctx.create_remote_server()
		server_id = server.server_id

	# Pay ice install cost
	if record.is_ice():
		var ice_cost: int = server.ice_install_cost()
		ctx.set_credits(player, ctx.get_credits(player) - ice_cost)
		if ice_cost > 0:
			ctx.send_log("%s pays %d credit(s) to install ice." % [ctx.player_name(player), ice_cost])

	# Create InstalledCard
	var installed := InstalledCard.make_runtime_instance(record, server_id, zone, false)

	if zone == "ice":
		server.install_ice(installed)
	else:
		server.install_in_root(installed)

	# Remove from hand
	_remove_from_hand(player, record)

	emit_signal("card_installed", record, server_id)
	emit_signal("hand_changed", player)
	ctx.send_log("%s installs %s in %s." % [ctx.player_name(player), record.title, server.display_name()])
	# Track Corp installs this turn for Seamless Launch restriction
	if player == "corp":
		ctx.corp_installed_this_turn.append(record.id)


func _do_advance(player: String, action: GameAction) -> void:
	_spend_click(player)
	ctx.set_credits(player, ctx.get_credits(player) - 1)
	emit_signal("credits_changed", player, ctx.get_credits(player))

	var card_id: String  = action.params.get("card_id", "")
	var card := _find_advanceable_card(card_id)
	if card == null:
		return

	card.add_counter("advancement", 1)
	emit_signal("card_advanced", card_id, card.get_counter("advancement"))
	ctx.send_log("%s advances %s (%d counters)." % [
		ctx.player_name(player), card.display_name(), card.get_counter("advancement")
	])

	# Fire on_advance for identity abilities (e.g. Weyland: Built to Last)
	await ctx.notify_event("on_advance", {"card_id": card_id}, interpreter)

	# Check if agenda can be scored
	if card.card_record != null and card.card_record.is_agenda():
		if card.meets_advancement_requirement():
			_score_agenda(card)


func _do_play_operation(player: String, action: GameAction) -> void:
	_spend_click(player)
	var record: CardRecord = action.params.get("card_record", null) as CardRecord
	var cost: int          = max(0, record.cost)
	ctx.set_credits(player, ctx.get_credits(player) - cost)
	emit_signal("credits_changed", player, ctx.get_credits(player))

	# Additional click costs (e.g. Lie Low, Maintenance Access: spend 1 extra click)
	var op_card_def: Dictionary = ability_registry._abilities.get(record.id, {}) as Dictionary
	var op_extra_clicks: int = op_card_def.get("additional_cost_clicks", 0)
	for _i in range(op_extra_clicks):
		_spend_click(player)
	if op_extra_clicks > 0:
		ctx.send_log("%s spends %d additional click(s) to play %s." % [ctx.player_name(player), op_extra_clicks, record.title])

	# Remove from hand
	_remove_from_hand(player, record)

	# Execute ability
	var on_play_def = ability_registry.get_on_play(record.id)
	if on_play_def != null:
		await interpreter.execute_trigger(on_play_def as Dictionary, ctx)

	# Operations/events go to the correct discard pile after resolving
	if player == "corp":
		ctx.corp_discard.append(record)
		# Track for Nebula Making Stars flip condition; fire once-per-turn click gain trigger
		ctx.corp_played_operation_this_turn = true
		await ctx.notify_event("corp_plays_operation", {}, interpreter)
	else:
		ctx.runner_discard.append(record)
	ctx.send_log("%s plays %s." % [ctx.player_name(player), record.title])
	emit_signal("hand_changed", player)


func _do_run(action: GameAction) -> void:
	_spend_click("runner")
	var server_id: String = action.params.get("server_id", "hq")

	# Notify Main so it can open RunScene before the run begins
	if ctx.has_meta("on_run_started"):
		var cb: Callable = ctx.get_meta("on_run_started") as Callable
		cb.call(server_id)
		await Engine.get_main_loop().process_frame

	# Reuse the run_state_machine stored on ctx so RunScene stays connected
	var run: RunStateMachine
	if ctx.has_meta("run_state_machine"):
		run = ctx.get_meta("run_state_machine") as RunStateMachine
	else:
		run = RunStateMachine.new(ctx, ability_registry)
	await run.execute(server_id)
	if ctx.run_successful:
		ctx.runner_made_successful_run_this_turn = true
		# Détente: fire once-per-turn event on first successful HQ run
		if server_id == "hq" and not ctx.runner_hq_successful_run_this_turn:
			ctx.runner_hq_successful_run_this_turn = true
			await ctx.notify_event("runner_successful_hq_run", {}, interpreter)
	# Track central servers attempted (for Red Team restriction)
	if server_id in ["hq", "rd", "archives"]:
		if server_id not in ctx.runner_centrals_run_this_turn:
			ctx.runner_centrals_run_this_turn.append(server_id)


func _do_use_installed_card(player: String, action: GameAction) -> void:
	_spend_click(player)
	var instance_id: String = action.params.get("card_instance_id", "")
	var card_id: String     = action.params.get("card_id", "")

	# Find the installed card — also checks scored agendas for Dividends click actions
	var installed: InstalledCard = null
	var search_list: Array = ctx.runner_rig if player == "runner" else []
	for server in ctx.servers.values():
		search_list.append_array((server as Server).root)
	if player == "corp":
		search_list.append_array(ctx.corp_score_area_cards)
	for card in search_list:
		var c: InstalledCard = card as InstalledCard
		if c == null:
			continue
		if (instance_id != "" and c.runtime_instance_id == instance_id) or \
		   (instance_id == "" and c.card_id == card_id):
			installed = c
			break

	if installed == null:
		ctx.send_log("use_installed_card: card not found (%s)" % (instance_id if instance_id != "" else card_id))
		return

	# Look up click_action definition in ability registry
	var card_def: Dictionary = ability_registry._abilities.get(installed.card_id, {}) as Dictionary
	var click_action_def: Dictionary = card_def.get("click_action", {}) as Dictionary
	if click_action_def.is_empty():
		ctx.send_log("use_installed_card: %s has no click_action defined." % installed.display_name())
		return

	# Additional click costs (e.g. Rent Rioters: 3 clicks total, 1 from action + 2 more)
	var extra_clicks: int = click_action_def.get("additional_cost_clicks", 0)
	if extra_clicks > 0:
		var available: int = ctx.runner_clicks if player == "runner" else ctx.corp_clicks
		if available < extra_clicks:
			ctx.send_log("%s: not enough clicks (need %d more) — cancelling." % [installed.display_name(), extra_clicks])
			return
		for _i in range(extra_clicks):
			_spend_click(player)
		ctx.send_log("%s spends %d additional click(s) for %s." % [ctx.player_name(player), extra_clicks, installed.display_name()])

	ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
	await interpreter.execute_trigger(click_action_def, ctx)
	ctx.current_event_data = {}


func _do_rez_card(player: String, action: GameAction) -> void:
	# Rezzing costs no click — it's a paid action outside the normal click economy.
	# Find the card by instance_id or card_id across all servers.
	var instance_id: String = action.params.get("card_instance_id", "")
	var card_id: String     = action.params.get("card_id", "")

	var installed: InstalledCard = null
	for server in ctx.servers.values():
		var s: Server = server as Server
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if (instance_id != "" and c.runtime_instance_id == instance_id) or \
			   (instance_id == "" and c.card_id == card_id):
				installed = c
				break
		if installed != null:
			break

	if installed == null or installed.card_record == null:
		ctx.send_log("Rez failed: card not found (%s)" % (instance_id if instance_id != "" else card_id))
		return

	# Use query_rez_cost so passive modifiers (e.g. Fransofia Ward +1) are applied.
	var rez_cost: int = ctx.query_rez_cost(installed)

	# ── Optional forfeit discount (e.g. Biawak: forfeit 1 agenda to pay 10cr of cost) ──
	if ability_registry._abilities.has(installed.card_id):
		var tm_card_def: Dictionary = ability_registry._abilities[installed.card_id] as Dictionary
		var tm_fd_def: Variant = tm_card_def.get("forfeit_rez_discount", null)
		if tm_fd_def != null and not ctx.corp_score_area_cards.is_empty():
			var tm_fd_amount: int = (tm_fd_def as Dictionary).get("amount", 0)
			var tm_fd_chosen: InstalledCard = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_forfeit_agenda"):
				tm_fd_chosen = await ctx.corp_decision_maker.choose_forfeit_agenda(
					ctx.corp_score_area_cards.duplicate(), ctx
				)
			if tm_fd_chosen != null:
				rez_cost = max(0, rez_cost - tm_fd_amount)
				await interpreter._forfeit_agenda(tm_fd_chosen, ctx)

		# ── Mandatory additional rez cost (e.g. Plutus: forfeit agenda OR reveal+trash 3 HQ) ──
		var tm_arc_def: Variant = tm_card_def.get("additional_rez_cost", null)
		if tm_arc_def != null:
			var tm_arc_type: String = (tm_arc_def as Dictionary).get("type", "")
			if tm_arc_type == "forfeit_or_reveal_trash_hq":
				var tm_reveal_count: int  = (tm_arc_def as Dictionary).get("reveal_trash_count", 3)
				var tm_can_forfeit: bool  = not ctx.corp_score_area_cards.is_empty()
				var tm_can_reveal: bool   = ctx.corp_hand.size() >= tm_reveal_count
				if not tm_can_forfeit and not tm_can_reveal:
					ctx.send_log("Rez failed: %s cannot pay additional rez cost." % installed.display_name())
					return
				var tm_arc_chosen: InstalledCard = null
				if tm_can_forfeit and ctx.corp_decision_maker != null and \
						ctx.corp_decision_maker.has_method("choose_forfeit_agenda"):
					tm_arc_chosen = await ctx.corp_decision_maker.choose_forfeit_agenda(
						ctx.corp_score_area_cards.duplicate(), ctx
					)
				if tm_arc_chosen != null:
					await interpreter._forfeit_agenda(tm_arc_chosen, ctx)
				elif tm_can_reveal:
					ctx.send_log("%s reveals and trashes %d card(s) from HQ for %s." % [
						ctx.corp_name(), tm_reveal_count, installed.display_name()
					])
					for _tm_i in range(min(tm_reveal_count, ctx.corp_hand.size())):
						var tm_entry: Dictionary = ctx.corp_hand.pop_back() as Dictionary
						var tm_record: CardRecord = tm_entry.get("card_record", null) as CardRecord
						if tm_record != null:
							ctx.corp_discard.append(tm_record)
							ctx.corp_discard_facedown[tm_record.title] = true
							ctx.send_log("  %s revealed and trashed from HQ." % tm_record.title)
				else:
					ctx.send_log("Rez failed: %s cannot pay additional rez cost." % installed.display_name())
					return

	if player == "corp":
		# Corp may supplement with Mahkota Langit Grid recurring credits on the same server
		if ctx.corp_rez_credits_available(installed.server_id) < rez_cost:
			ctx.send_log("Cannot afford to rez %s (costs %d, have %d)." % [
				installed.display_name(), rez_cost, ctx.corp_rez_credits_available(installed.server_id)
			])
			return
		ctx.corp_spend_for_rez(rez_cost, installed.server_id)
	else:
		var credits: int = ctx.runner_credits
		if credits < rez_cost:
			ctx.send_log("Cannot afford to rez %s (costs %d, have %d)." % [installed.display_name(), rez_cost, credits])
			return
		ctx.runner_credits -= rez_cost

	installed.is_rezzed = true
	_register_card_listeners(installed)

	var on_rez_def = ability_registry.get_on_rez(installed.card_id)
	if on_rez_def != null:
		ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
		await interpreter.execute_trigger(on_rez_def as Dictionary, ctx)
		ctx.current_event_data = {}

	ctx.send_log("%s rezzes %s for %d cr." % [ctx.player_name(player), installed.display_name(), rez_cost])
	emit_signal("card_installed", installed.card_record, installed.server_id)


func _do_end_turn(player: String) -> void:
	if player == "corp":
		await ctx.notify_event("corp_turn_end", {}, interpreter)
		ctx.corp_clicks = 0
	else:
		await ctx.notify_event("runner_turn_end", {}, interpreter)
		ctx.runner_clicks = 0
	ctx.send_log("%s ends their turn." % ctx.player_name(player))


# ── Win condition checking ────────────────────────────────────────────────────

func _check_win_conditions() -> void:
	if ctx.game_over:
		# A subsystem (e.g. RunStateMachine._steal_agenda) set ctx.game_over directly
		# without going through _end_game(), so the signal was never emitted.
		# Catch that here and emit exactly once.
		if not _game_over_signaled:
			_game_over_signaled = true
			var reason := ""
			if ctx.winner == "runner":
				reason = "%s stole enough agendas to win" % ctx.runner_name()
			elif ctx.winner == "corp":
				reason = "%s wins" % ctx.corp_name()
			ctx.send_log("Game over — %s wins. %s" % [ctx.player_name(ctx.winner), reason])
			emit_signal("game_over", ctx.winner, reason)
		return

	# Agenda point victory
	if ctx.corp_agenda_points() >= agenda_points_to_win:
		_end_game("corp", "%s scored %d agenda points" % [ctx.corp_name(), ctx.corp_agenda_points()])
		return
	if ctx.runner_agenda_points() >= agenda_points_to_win:
		_end_game("runner", "%s scored %d agenda points" % [ctx.runner_name(), ctx.runner_agenda_points()])
		return

	# Flatline — runner has no cards in grip
	if ctx.runner_hand.is_empty() and ctx.active_player == "runner":
		_end_game("corp", "\"%s\" flatlined (empty grip)" % ctx.runner_name())
		return


func _end_game(winner: String, reason: String) -> void:
	ctx.game_over = true
	ctx.winner    = winner
	ctx.send_log("Game over — %s wins. %s" % [ctx.player_name(winner), reason])
	if not _game_over_signaled:
		_game_over_signaled = true
		emit_signal("game_over", winner, reason)


# ── Agenda scoring ────────────────────────────────────────────────────────────

func _score_agenda(card: InstalledCard) -> void:
	var record: CardRecord = card.card_record
	ctx.send_log("%s scores %s! (%d agenda points)" % [ctx.corp_name(), record.title, record.agenda_points])
	ctx.corp_score_area.append(record)
	# Also keep the InstalledCard so Dividends effects can access counters on the scored card
	ctx.corp_score_area_cards.append(card)
	ctx.corp_last_scored_agenda_points  = record.agenda_points
	ctx.corp_agendas_scored_this_turn  += 1

	# Remove from server
	var server: Server = ctx.get_server(card.server_id)
	if server:
		server.remove_from_root(card)
		ctx.remove_empty_remote_servers()

	# Calculate excess advancement counters for the Dividends mechanic.
	# Excess = counters beyond the printed requirement at the moment of scoring.
	var excess: int = max(0, card.get_counter("advancement") - record.advancement_requirement)

	# Fire on_score ability of the scored agenda.
	# Set current_event_data so effects like place_dividend_counters can read the
	# scored card's instance_id and the excess advancement count.
	var on_score_def = ability_registry.get_on_score(record.id)
	if on_score_def != null:
		ctx.current_event_data = {
			"card": card,
			"card_instance_id": card.runtime_instance_id,
			"excess_advancement": excess
		}
		await interpreter.execute_trigger(on_score_def as Dictionary, ctx)
		ctx.current_event_data = {}

	# Broadcast so runner cards (e.g. Pantograph) and corp ICE (e.g. Lamplighter) can respond.
	# server_id is still valid on the InstalledCard even after removal from the server array.
	await ctx.notify_event("corp_scores_agenda", {
		"agenda_id":    record.id,
		"agenda_points": record.agenda_points,
		"server_id":    card.server_id
	}, interpreter)

	# Check win condition immediately — Corp may have won by scoring
	_check_win_conditions()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _spend_click(player: String) -> void:
	if player == "corp":
		ctx.corp_clicks   = max(0, ctx.corp_clicks - 1)
	else:
		ctx.runner_clicks = max(0, ctx.runner_clicks - 1)


func _remove_from_hand(player: String, record: CardRecord) -> void:
	var hand: Array = ctx.corp_hand if player == "corp" else ctx.runner_hand
	for i in range(hand.size()):
		var entry: Dictionary = hand[i] as Dictionary
		if entry.get("card_id", "") == record.id:
			hand.remove_at(i)
			return
	# Not found in hand — check faceup-hosted cards on rig (Bling, Madani, etc.)
	if player == "runner":
		for rig_c in ctx.runner_rig:
			var ic: InstalledCard = rig_c as InstalledCard
			if ic == null:
				continue
			for i in range(ic.faceup_hosted_cards.size()):
				var cr: CardRecord = ic.faceup_hosted_cards[i] as CardRecord
				if cr != null and cr.id == record.id:
					ic.faceup_hosted_cards.remove_at(i)
					return


func _register_identity_listeners(instance_id: String, card_id: String) -> void:
	if card_id == "":
		return
	var card_def: Dictionary = ability_registry._abilities.get(card_id, {}) as Dictionary
	if card_def.is_empty():
		return
	for event_type in ["corp_turn_start", "runner_turn_start", "corp_turn_end", "runner_turn_end",
					"encounter_ice", "pass_ice", "successful_run", "approach_server",
					"run_end", "on_derez", "corp_scores_agenda", "before_breach",
					"runner_trashes_during_breach", "runner_installs_virus",
					"on_advance", "breach_complete", "run_start", "runner_takes_tags",
					"corp_plays_operation"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)

	var id_modifiers: Array = card_def.get("passive_modifiers", []) as Array
	for mod in id_modifiers:
		var mod_dict: Dictionary = mod as Dictionary
		var extra := {}
		for key in ["card_id", "method"]:
			if mod_dict.has(key):
				extra[key] = mod_dict[key]
		ctx.register_modifier(
			mod_dict.get("type", ""),
			instance_id,
			mod_dict.get("value", 0),
			mod_dict.get("conditions", {}) as Dictionary,
			extra
		)


func _register_card_listeners(installed: InstalledCard) -> void:
	# Register all event listeners and passive modifiers for this card.
	# Uses instance_id so effects can be cleaned up when the card leaves play.
	var instance_id: String = installed.runtime_instance_id if installed.runtime_instance_id != "" else installed.card_id
	var card_id: String     = installed.card_id
	var card_def: Dictionary = ability_registry._abilities.get(card_id, {}) as Dictionary

	# Register triggered event listeners
	for event_type in ["corp_turn_start", "runner_turn_start", "corp_turn_end", "runner_turn_end",
						"approach_ice", "encounter_ice", "pass_ice", "successful_run",
						"approach_server", "run_end", "on_derez",
						"corp_scores_agenda", "runner_steals_agenda", "runner_trashes_during_breach",
						"before_breach", "runner_installs_virus", "runner_installs_card",
						"runner_successful_hq_run",
						"on_advance", "breach_complete", "run_start"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)

	# Register passive modifiers (e.g. Turbine's breaker_strength boost, Echelon's dynamic strength)
	var modifiers: Array = card_def.get("passive_modifiers", []) as Array
	for mod in modifiers:
		var mod_dict: Dictionary = mod as Dictionary
		var extra := {}
		# Pass through any extra fields needed by dynamic modifiers
		for key in ["card_id", "method"]:
			if mod_dict.has(key):
				extra[key] = mod_dict[key]
		# Server-scoped modifiers (e.g. Mahkota recurring credits) carry the owning card's server_id
		if mod_dict.get("server_scoped", false):
			extra["server_id"] = installed.server_id
		ctx.register_modifier(
			mod_dict.get("type", ""),
			instance_id,
			mod_dict.get("value", 0),
			mod_dict.get("conditions", {}) as Dictionary,
			extra
		)


func _find_advanceable_card(card_id: String) -> InstalledCard:
	for server in ctx.servers.values():
		var s: Server = server as Server
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_id == card_id and c.can_be_advanced():
				return c
	return null

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
const AGENDA_POINTS_TO_WIN:   int = 7

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
	if corp_penalty > 0:
		ctx.log("Corp loses %d click(s) this turn (deferred penalty)." % corp_penalty)

	# Draw phase: mandatory draw, then start-of-turn events
	_corp_mandatory_draw()
	emit_signal("turn_started", "corp", ctx.turn_number)
	ctx.log("=== Corp Turn %d begins. Credits: %d, Clicks: %d ===" % [
		ctx.turn_number, ctx.corp_credits, ctx.corp_clicks
	])
	# Fire start-of-turn triggers (assets, upgrades, etc.)
	await ctx.notify_event("corp_turn_start", {}, interpreter)

	# Action phase
	while ctx.corp_clicks > 0 and not ctx.game_over:
		if ctx.corp_decision_maker == null:
			ctx.log("No Corp decision maker — ending Corp turn.")
			break

		var action: GameAction = await ctx.corp_decision_maker.choose_action(ctx)
		if action == null:
			ctx.log("Corp decision maker returned null — ending Corp turn.")
			break

		var result := await _execute_action("corp", action)
		if not result["ok"]:
			ctx.log("Corp action rejected: %s" % result["reason"])
			# Give the AI another chance rather than looping forever
			# If it keeps producing invalid actions something is wrong
			break

	# Discard phase
	_corp_discard_to_hand_limit()


func _corp_mandatory_draw() -> void:
	if ctx.corp_deck.is_empty():
		ctx.log("Corp deck is empty — Corp loses!")
		_end_game("runner", "Corp could not draw (empty R&D)")
		return
		
	# Pop the clean object directly
	var drawn: CardRecord = ctx.corp_deck.pop_front() as CardRecord
	
	# Package it into the dictionary format your hand structure expects
	ctx.corp_hand.append({"card_id": drawn.id, "card_record": drawn})
	
	emit_signal("hand_changed", "corp")
	ctx.log("Corp draws %s." % drawn.title)


func _corp_discard_to_hand_limit() -> void:
	while ctx.corp_hand.size() > ctx.corp_max_hand_size() and not ctx.game_over:
		# Discard the last card (AI discards from the end for simplicity)
		var discarded: Dictionary = ctx.corp_hand.pop_back() as Dictionary
		var record: CardRecord    = discarded.get("card_record", null) as CardRecord
		ctx.corp_discard.append(record)
		ctx.log("Corp discards %s to hand limit." % (record.title if record else "?"))
	emit_signal("hand_changed", "corp")


# ── Runner turn ───────────────────────────────────────────────────────────────

func _runner_turn() -> void:
	ctx.active_player  = "runner"
	var runner_penalty: int = ctx.pending_click_penalties.get("runner", 0)
	ctx.runner_clicks = max(0, RUNNER_CLICKS_PER_TURN - runner_penalty)
	ctx.pending_click_penalties["runner"] = 0
	if runner_penalty > 0:
		ctx.log("Runner loses %d click(s) this turn (deferred penalty)." % runner_penalty)
	ctx.turn_number   += 1

	emit_signal("turn_started", "runner", ctx.turn_number)
	ctx.log("=== Runner Turn %d begins. Credits: %d, Clicks: %d ===" % [
		ctx.turn_number, ctx.runner_credits, ctx.runner_clicks
	])
	# Fire start-of-turn triggers (resources, hardware, etc.)
	await ctx.notify_event("runner_turn_start", {}, interpreter)

	while ctx.runner_clicks > 0 and not ctx.game_over:
		if ctx.runner_decision_maker == null:
			ctx.log("No Runner decision maker — ending Runner turn.")
			break

		var action: GameAction = await ctx.runner_decision_maker.choose_action(ctx)
		if action == null:
			ctx.log("Runner decision maker returned null — ending Runner turn.")
			break

		var result := await _execute_action("runner", action)
		if not result["ok"]:
			ctx.log("Runner action rejected: %s" % result["reason"])
			break

	# Runner has no discard phase


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
		"end_turn":        await _do_end_turn(player)
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

		"gain_credits", "draw_card", "run":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
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
			return {"ok": true, "reason": ""}

		_:
			return {"ok": false, "reason": "Unknown action type: %s" % action.type}


# ── Action implementations ────────────────────────────────────────────────────

func _do_gain_credits(player: String) -> void:
	_spend_click(player)
	ctx.set_credits(player, ctx.get_credits(player) + 1)
	emit_signal("credits_changed", player, ctx.get_credits(player))
	ctx.log("%s gains 1 credit. (%d total)" % [player.capitalize(), ctx.get_credits(player)])


func _do_draw_card(player: String) -> void:
	_spend_click(player)
	var deck: Array = ctx.corp_deck if player == "corp" else ctx.runner_deck
	
	if deck.is_empty():
		if player == "corp":
			_end_game("runner", "Corp could not draw (empty R&D)")
		else:
			ctx.log("Runner deck is empty — cannot draw.")
		return
		
	# Pop the object asset cleanly
	var drawn: CardRecord = deck.pop_front() as CardRecord
	var hand_entry := {"card_id": drawn.id, "card_record": drawn}
	
	if player == "corp":
		ctx.corp_hand.append(hand_entry)
	else:
		ctx.runner_hand.append(hand_entry)
		
	emit_signal("hand_changed", player)
	ctx.log("%s draws %s." % [player.capitalize(), drawn.title])


func _do_install(player: String, action: GameAction) -> void:
	_spend_click(player)
	var record: CardRecord = action.params.get("card_record", null) as CardRecord
	var server_id: String  = action.params.get("server_id", "")
	var zone: String       = action.params.get("zone", "root")

	# Runner programs, hardware, and resources go directly to the rig
	if player == "runner" and server_id == "runner_rig":
		var pay_cost: int = max(0, record.cost)
		print("Player install: card is: ", record.title, " and charged cost is: ", pay_cost)
		if ctx.runner_credits < pay_cost:
			ctx.log("Runner cannot afford to install %s." % record.title)
			return
		ctx.runner_credits -= pay_cost
		var installed := InstalledCard.make_runtime_instance(record, "runner_rig", "root", true)
		ctx.runner_rig.append(installed)
		_remove_from_hand(player, record)
		_register_card_listeners(installed)
		await ctx.notify_event("on_rez", {"card": installed, "card_instance_id": installed.runtime_instance_id}, interpreter)
		emit_signal("card_installed", record, "runner_rig")
		emit_signal("hand_changed", player)
		ctx.log("Runner installs %s." % record.title)
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
			ctx.log("%s pays %d credit(s) to install ice." % [player.capitalize(), ice_cost])

	# Create InstalledCard
	var installed := InstalledCard.make_runtime_instance(record, server_id, zone, false)

	if zone == "ice":
		server.install_ice(installed)
	else:
		server.install_in_root(installed)

	# Remove from hand
	_remove_from_hand(player, record)

	# Corp non-ice root cards are auto-rezzed on install
	if player == "corp" and zone == "root" and not record.is_agenda():
		var rez_cost: int = max(0, record.cost)
		if ctx.corp_credits >= rez_cost:
			ctx.corp_credits -= rez_cost
			installed.is_rezzed = true
			_register_card_listeners(installed)
			await ctx.notify_event("on_rez", {"card": installed, "card_instance_id": installed.runtime_instance_id}, interpreter)
			ctx.log("Corp rezzes %s for %d cr." % [record.title, rez_cost])
		else:
			ctx.log("Corp installs %s unrezzed (cannot afford rez cost)." % record.title)

	emit_signal("card_installed", record, server_id)
	emit_signal("hand_changed", player)
	ctx.log("%s installs %s in %s." % [player.capitalize(), record.title, server.display_name()])


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
	ctx.log("%s advances %s (%d counters)." % [
		player.capitalize(), card.display_name(), card.get_counter("advancement")
	])

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

	# Remove from hand
	_remove_from_hand(player, record)

	# Execute ability
	var on_play_def = ability_registry.get_on_play(record.id)
	if on_play_def != null:
		await interpreter.execute_trigger(on_play_def as Dictionary, ctx)

	# Operations go to discard after resolving
	ctx.corp_discard.append(record)
	ctx.log("%s plays %s." % [player.capitalize(), record.title])
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


func _do_end_turn(player: String) -> void:
	if player == "corp":
		ctx.corp_clicks = 0
	else:
		ctx.runner_clicks = 0
	ctx.log("%s ends their turn." % player.capitalize())


# ── Win condition checking ────────────────────────────────────────────────────

func _check_win_conditions() -> void:
	if ctx.game_over:
		return

	# Agenda point victory
	if ctx.corp_agenda_points() >= AGENDA_POINTS_TO_WIN:
		_end_game("corp", "Corp scored %d agenda points" % ctx.corp_agenda_points())
		return
	if ctx.runner_agenda_points() >= AGENDA_POINTS_TO_WIN:
		_end_game("runner", "Runner scored %d agenda points" % ctx.runner_agenda_points())
		return

	# Flatline — runner has no cards in grip
	if ctx.runner_hand.is_empty() and ctx.active_player == "runner":
		_end_game("corp", "Runner flatlined (empty grip)")
		return


func _end_game(winner: String, reason: String) -> void:
	ctx.game_over = true
	ctx.winner    = winner
	ctx.log("Game over — %s wins. %s" % [winner.capitalize(), reason])
	emit_signal("game_over", winner, reason)


# ── Agenda scoring ────────────────────────────────────────────────────────────

func _score_agenda(card: InstalledCard) -> void:
	var record: CardRecord = card.card_record
	ctx.log("Corp scores %s! (%d agenda points)" % [record.title, record.agenda_points])
	ctx.corp_score_area.append(record)

	# Remove from server
	var server: Server = ctx.get_server(card.server_id)
	if server:
		server.remove_from_root(card)
		ctx.remove_empty_remote_servers()

	# Fire on_score ability
	var on_score_def = ability_registry.get_on_score(record.id)
	if on_score_def != null:
		await interpreter.execute_trigger(on_score_def as Dictionary, ctx)


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


func _register_card_listeners(installed: InstalledCard) -> void:
	# Register all event listeners and passive modifiers for this card.
	# Uses instance_id so effects can be cleaned up when the card leaves play.
	var instance_id: String = installed.runtime_instance_id if installed.runtime_instance_id != "" else installed.card_id
	var card_id: String     = installed.card_id
	var card_def: Dictionary = ability_registry._abilities.get(card_id, {}) as Dictionary

	# Register triggered event listeners
	for event_type in ["corp_turn_start", "runner_turn_start", "on_rez",
						"encounter_ice", "pass_ice", "successful_run", "approach_server"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)

	# Register passive modifiers (e.g. Turbine's breaker_strength boost)
	var modifiers: Array = card_def.get("passive_modifiers", []) as Array
	for mod in modifiers:
		var mod_dict: Dictionary = mod as Dictionary
		ctx.register_modifier(
			mod_dict.get("type", ""),
			instance_id,
			mod_dict.get("value", 0),
			mod_dict.get("conditions", {}) as Dictionary
		)


func _find_advanceable_card(card_id: String) -> InstalledCard:
	for server in ctx.servers.values():
		var s: Server = server as Server
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_id == card_id and c.can_be_advanced():
				return c
	return null

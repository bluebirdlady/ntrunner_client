# Main.gd
extends Node

@onready var game_ui: CanvasLayer = $GameUI

var ctx: GameContext
var ability_registry: AbilityRegistry
var interpreter: AbilityInterpreter
var turn_manager: TurnManager
var run_machine: RunStateMachine

# Main.gd (Updated initialization block)
func _ready() -> void:
	ctx = GameContext.new()
	ability_registry = AbilityRegistry.new()
	interpreter = AbilityInterpreter.new()
	
	# Corp is driven by the AI; Runner is driven by the human player
	var corp_brain := CorpTurnAI.new(ability_registry)
	var runner_brain := HumanDecisionMaker.new()
	
	ctx.corp_decision_maker = corp_brain
	ctx.runner_decision_maker = runner_brain
	
	_populate_test_state()
	
	ctx.servers["hq"] = Server.make("hq")
	ctx.servers["rd"] = Server.make("rd")
	ctx.servers["archives"] = Server.make("archives")
	
	turn_manager = TurnManager.new(ctx, ability_registry)
	run_machine = RunStateMachine.new(ctx, ability_registry)
	ctx.set_meta("run_state_machine", run_machine)
	
	game_ui.setup(ctx, turn_manager, run_machine)
	
	# Route UI actions to the Runner brain only — Corp acts autonomously
	game_ui.action_requested.connect(func(action: GameAction):
		if ctx.active_player == "runner":
			runner_brain.action_selected.emit(action)
	)

	# Wire Runner decision proxies to GameUI prompt functions
	runner_brain.jack_out_proxy = func() -> bool:
		return await game_ui.show_jack_out_prompt()

	runner_brain.encounter_action_proxy = func(encounter: EncounterState) -> Dictionary:
		return await game_ui.show_encounter_prompt(encounter)

	runner_brain.trash_proxy = func(card: CardRecord) -> bool:
		return await game_ui.show_trash_prompt(card)

	runner_brain.choose_modes_proxy = func(modes: Array, max_choices: int) -> Array:
		return await game_ui.show_modes_prompt(modes, max_choices)

	# Modal choices: runner picks between card modes via UI prompt
	runner_brain.choose_modes_proxy = func(modes: Array, max_choices: int) -> Array:
		return await game_ui.show_modal_prompt(modes, max_choices)

	# Corp AI chooses which card to return to deck (Sprint)
	# Corp uses its own heuristic; no UI proxy needed for corp_brain

	# Deck search (Mutual Favor): runner picks from matching cards
	runner_brain.choose_from_search_proxy = func(candidates: Array) -> CardRecord:
		return await game_ui.show_search_prompt(candidates)

	# Server choice: runner picks a server for run-initiating events
	runner_brain.choose_server_proxy = func(allowed: Array) -> String:
		return await game_ui.show_server_choice_prompt(allowed)
	
	
	_start_game_loop()
	
func _populate_test_state() -> void:
	ctx.corp_credits   = 5
	ctx.runner_credits = 5
	ctx.corp_clicks    = 3
	ctx.runner_clicks  = 0

	# ── Haas-Bioroid: Precision Design (System Gateway starter) ──────────────
	# Agendas (8)
	var corp_deck_ids: Array = [
		"luminal_transubstantiation",
		"offworld_office", "offworld_office", "offworld_office",
		"send_a_message", "send_a_message", "send_a_message",
		"superconducting_hub",
		# Assets (6)
		"nico_campaign", "nico_campaign", "nico_campaign",
		"urtica_cipher", "urtica_cipher", "urtica_cipher",
		# Operations (13)
		"government_subsidy", "government_subsidy", "government_subsidy",
		"hedge_fund", "hedge_fund", "hedge_fund",
		"predictive_planogram", "predictive_planogram", "predictive_planogram",
		"seamless_launch", "seamless_launch",
		"sprint", "sprint",
		# Upgrades (2)
		"manegarm_skunkworks", "manegarm_skunkworks",
		# Ice (15)
		"bran_1_0", "bran_1_0",
		"palisade", "palisade", "palisade",
		"whitespace", "whitespace", "whitespace",
		"ansel_1_0", "ansel_1_0", "ansel_1_0",
		"tithe", "tithe", "tithe",
	]

	# ── Shaper Runner deck (System Gateway starter) ───────────────────────────
	# Based on the "Find the Truth" Tāo Salonga starter list
	var runner_deck_ids: Array = [
		# Events (17)
		"jailbreak", "jailbreak", "jailbreak",
		"mutual_favor", "mutual_favor",
		"overclock", "overclock", "overclock",
		"sure_gamble", "sure_gamble", "sure_gamble",
		"tread_lightly", "tread_lightly", "tread_lightly",
		"vrcation", "vrcation", "vrcation",
		# Hardware (6)
		"conduit", "conduit", "conduit",
		"k2cp_turbine", "k2cp_turbine", "k2cp_turbine",
		# Programs (12)
		"cleaver", "cleaver", "cleaver",
		"unity", "unity", "unity",
		"carmen", "carmen", "carmen",
		"leech", "leech", "leech",
		# Resources (9)
		"daily_casts", "daily_casts", "daily_casts",
		"earthrise_hotel", "earthrise_hotel", "earthrise_hotel",
		"creative_commission", "creative_commission", "creative_commission",
	]

	_load_deck_from_ids(corp_deck_ids, ctx.corp_deck)
	_load_deck_from_ids(runner_deck_ids, ctx.runner_deck)

	# Shuffle both decks
	ctx.corp_deck.shuffle()
	ctx.runner_deck.shuffle()

	# Draw starting hands (5 for Corp, 5 for Runner)
	for i in range(5):
		if not ctx.corp_deck.is_empty():
			var card: CardRecord = ctx.corp_deck.pop_front()
			ctx.corp_hand.append({"card_id": card.id, "card_record": card})
	for i in range(5):
		if not ctx.runner_deck.is_empty():
			var card: CardRecord = ctx.runner_deck.pop_front()
			ctx.runner_hand.append({"card_id": card.id, "card_record": card})


func _load_deck_from_ids(ids: Array, deck: Array) -> void:
	for card_id in ids:
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record != null:
			deck.append(record)
		else:
			push_warning("_populate_test_state: card not found in registry: %s" % card_id)
func _start_game_loop() -> void:
	# This starts your TurnManager execution coroutine 
	# It will allocate clicks to the starting player and emit 'turn_started'
	await turn_manager.run_game()


func _on_ui_action_requested(action: GameAction) -> void:
	# Direct inbound UI choices straight into your engine's validation pipeline
	# If valid, this mutates ctx and emits 'action_executed', which updates the UI
	var active_player = "corp" if ctx.corp_clicks > 0 else "runner"
	
	# Replace with your actual validation call if named differently inside TurnManager
	if turn_manager.has_method("validate_and_execute"):
		turn_manager.validate_and_execute(active_player, action)
	else:
		# Fallback debug log if TurnManager implementation details differ
		ctx.log("UI requested action: %s" % action.describe())

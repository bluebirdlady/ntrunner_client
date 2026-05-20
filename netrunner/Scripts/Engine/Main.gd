# Main.gd
extends Node

@onready var game_ui: CanvasLayer = $GameUI

var ctx: GameContext
var ability_registry: AbilityRegistry
var turn_manager: TurnManager
var run_machine: RunStateMachine
var runner_brain: HumanDecisionMaker
var _run_scene: RunScene = null

func _ready() -> void:
	ctx = GameContext.new()
	ability_registry = AbilityRegistry.new()
	if not ability_registry.load_from_file("res://Data/abilities.json"):
		push_error("Main: failed to load abilities.json")
	else:
		print("AbilityRegistry loaded %d card definitions" % ability_registry._abilities.size())

	var corp_brain := CorpTurnAI.new(ability_registry)
	runner_brain = HumanDecisionMaker.new()

	ctx.corp_decision_maker   = corp_brain
	ctx.runner_decision_maker = runner_brain

	_populate_test_state()

	ctx.servers["hq"]       = Server.make("hq")
	ctx.servers["rd"]       = Server.make("rd")
	ctx.servers["archives"] = Server.make("archives")

	turn_manager = TurnManager.new(ctx, ability_registry)
	run_machine  = RunStateMachine.new(ctx, ability_registry)
	ctx.set_meta("run_state_machine", run_machine)

	game_ui.setup(ctx, turn_manager, run_machine, ability_registry)

	# Route UI actions to the runner brain
	game_ui.action_requested.connect(func(action: GameAction):
		if ctx.active_player == "runner":
			runner_brain.action_selected.emit(action)
	)

	# Default proxies → GameUI (used outside of runs)
	_wire_proxies_to_game_ui()

	# Intercept run initiation to show RunScene
	_wire_run_via_turn_manager()

	_start_game_loop()


# ── Proxy wiring ──────────────────────────────────────────────────────────────

func _wire_proxies_to_game_ui() -> void:
	runner_brain.jack_out_proxy = func() -> bool:
		return await game_ui.show_jack_out_prompt()
	runner_brain.encounter_action_proxy = func(encounter: EncounterState) -> Dictionary:
		return await game_ui.show_encounter_prompt(encounter)
	runner_brain.trash_proxy = func(card: CardRecord) -> bool:
		return await game_ui.show_trash_prompt(card)
	runner_brain.choose_modes_proxy = func(modes: Array, max_choices: int) -> Array:
		return await game_ui.show_modal_prompt(modes, max_choices)
	runner_brain.choose_from_search_proxy = func(candidates: Array) -> CardRecord:
		return await game_ui.show_search_prompt(candidates)
	runner_brain.choose_payment_option_proxy = func(options: Array) -> Variant:
		return await game_ui.show_payment_option_prompt(options)
	runner_brain.choose_server_proxy = func(allowed: Array) -> String:
		return await game_ui.show_server_choice_prompt(allowed)


func _wire_proxies_to_run_scene(run_scene: RunScene) -> void:
	runner_brain.jack_out_proxy = func() -> bool:
		return await run_scene.show_jack_out_prompt()
	runner_brain.encounter_action_proxy = func(encounter: EncounterState) -> Dictionary:
		return await run_scene.show_encounter_prompt(encounter)
	runner_brain.trash_proxy = func(card: CardRecord) -> bool:
		return await run_scene.show_trash_prompt(card)
	runner_brain.choose_modes_proxy = func(modes: Array, max_choices: int) -> Array:
		return await run_scene.show_modal_prompt(modes, max_choices)
	runner_brain.choose_from_search_proxy = func(candidates: Array) -> CardRecord:
		return await run_scene.show_search_prompt(candidates)
	runner_brain.choose_payment_option_proxy = func(options: Array) -> Variant:
		return await run_scene.show_payment_option_prompt(options)
	runner_brain.choose_server_proxy = func(allowed: Array) -> String:
		return await run_scene.show_server_choice_prompt(allowed)


# ── Run scene lifecycle ───────────────────────────────────────────────────────

func _wire_run_via_turn_manager() -> void:
	# TurnManager calls run_machine.execute internally via _do_run.
	# We override the run proxy on the run_machine so we can intercept it.
	# The approach: hook into run_machine's pre-execution signal if available,
	# otherwise let TurnManager call execute directly and rely on RunScene
	# being created before the first encounter prompt fires.
	#
	# Since run_machine.execute is awaitable, we patch _do_run in TurnManager
	# by setting a run_started callback on ctx metadata.
	ctx.set_meta("on_run_started", Callable(self, "_on_run_will_start"))


func _on_run_will_start(server_id: String) -> void:
	# Called by TurnManager just before run_machine.execute(server_id)
	_open_run_scene(server_id)


func _open_run_scene(server_id: String) -> void:
	if _run_scene != null:
		return

	_run_scene = RunScene.new()
	add_child(_run_scene)
	_run_scene.setup(ctx, ability_registry, run_machine)
	_run_scene.run_complete.connect(_on_run_scene_complete, CONNECT_ONE_SHOT)

	# Redirect all runner decisions to RunScene
	_wire_proxies_to_run_scene(_run_scene)

	# Tell RunScene which server we're running on
	_run_scene.start_run(server_id)


func _on_run_scene_complete() -> void:
	if _run_scene != null:
		_run_scene.queue_free()
		_run_scene = null

	# Restore proxies to GameUI
	_wire_proxies_to_game_ui()
	game_ui._update_all_displays()


# ── Game loop ─────────────────────────────────────────────────────────────────

func _start_game_loop() -> void:
	await turn_manager.run_game()


# ── Test state ────────────────────────────────────────────────────────────────

func _populate_test_state() -> void:
	ctx.corp_credits   = 5
	ctx.runner_credits = 5
	ctx.corp_clicks    = 3
	ctx.runner_clicks  = 0

	# ── Identities ────────────────────────────────────────────────────────────
	ctx.corp_identity   = CardRegistry.get_card("the_syndicate_profit_over_principle")
	ctx.runner_identity = CardRegistry.get_card("the_catalyst_convention_breaker")

	# ── System Gateway Starter Corp deck (34 cards — The Syndicate) ───────────
	var corp_deck_ids: Array = [
		"offworld_office", "offworld_office", "offworld_office",
		"send_a_message", "send_a_message",
		"superconducting_hub", "superconducting_hub",
		"nico_campaign", "nico_campaign",
		"urtica_cipher", "urtica_cipher",
		"regolith_mining_license", "regolith_mining_license",
		"hedge_fund", "hedge_fund", "hedge_fund",
		"government_subsidy", "government_subsidy",
		"seamless_launch", "seamless_launch",
		"manegarm_skunkworks",
		"bran_1_0", "bran_1_0",
		"diviner", "diviner",
		"karuna", "karuna",
		"palisade", "palisade", "palisade",
		"whitespace", "whitespace",
		"tithe", "tithe",
	]

	# ── System Gateway Starter Runner deck (30 cards — The Catalyst) ──────────
	var runner_deck_ids: Array = [
		"tread_lightly", "tread_lightly",
		"creative_commission", "creative_commission",
		"vrcation", "vrcation",
		"overclock", "overclock",
		"jailbreak", "jailbreak", "jailbreak",
		"sure_gamble", "sure_gamble", "sure_gamble",
		"docklands_pass",
		"pennyshaver",
		"red_team",
		"telework_contract", "telework_contract",
		"smartware_distributor", "smartware_distributor",
		"verbal_plasticity",
		"cleaver", "cleaver",
		"carmen", "carmen",
		"unity", "unity",
		"mayfly", "mayfly",
	]

	_load_deck_from_ids(corp_deck_ids, ctx.corp_deck)
	_load_deck_from_ids(runner_deck_ids, ctx.runner_deck)
	ctx.corp_deck.shuffle()
	ctx.runner_deck.shuffle()

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
			push_warning("_populate_test_state: card not found: %s" % card_id)

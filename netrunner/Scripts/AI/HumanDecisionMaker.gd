# HumanDecisionMaker.gd
extends RefCounted
class_name HumanDecisionMaker

# ── HumanDecisionMaker ────────────────────────────────────────────────────────
# Bridges the async decision_maker interface to the UI layer via proxy callables.
# Main.gd sets each proxy to a function that shows a UI prompt and awaits the
# player's button press.
#
# Required proxy callables (set by Main.gd before the game loop starts):
#   action_selected_proxy   — not needed; action_selected signal handles this
#   rez_proxy               — func(InstalledCard) -> bool
#   jack_out_proxy          — func() -> bool
#   break_subroutines_proxy — func(InstalledCard, Array) -> Array
#   trash_proxy             — func(CardRecord) -> bool

signal action_selected(action: GameAction)
signal encounter_action_selected(action: Dictionary)
signal mode_chosen(indices: Array)

var rez_proxy:               Callable
var jack_out_proxy:          Callable
var encounter_action_proxy:  Callable   # func(EncounterState) -> Dictionary
var trash_proxy:             Callable
var choose_modes_proxy:      Callable   # func(modes, max_choices) -> Array[int]
var choose_server_proxy:      Callable   # func(allowed_servers) -> String
var choose_card_from_hand_proxy:  Callable # func(hand) -> Dictionary
var choose_from_search_proxy:     Callable # func(candidates) -> CardRecord


func choose_action(_ctx: GameContext) -> GameAction:
	var action: GameAction = await action_selected
	return action


func choose_rez(card: InstalledCard, _ctx: GameContext) -> bool:
	if rez_proxy.is_valid():
		return await rez_proxy.call(card)
	return false


func choose_jack_out(_ctx: GameContext) -> bool:
	if jack_out_proxy.is_valid():
		return await jack_out_proxy.call()
	return false


func choose_encounter_action(encounter: EncounterState, _ctx: GameContext) -> Dictionary:
	if encounter_action_proxy.is_valid():
		return await encounter_action_proxy.call(encounter)
	# No proxy set — pass immediately (no breaking)
	return {"type": "done"}


func choose_trash(card: CardRecord, _ctx: GameContext) -> bool:
	if trash_proxy.is_valid():
		return await trash_proxy.call(card)
	return false


func choose_modes(modes: Array, max_choices: int, _ctx: GameContext) -> Array:
	if choose_modes_proxy.is_valid():
		return await choose_modes_proxy.call(modes, max_choices)
	# Default: choose first mode
	return [0]


func choose_server(allowed_servers: Array, _ctx: GameContext) -> String:
	if choose_server_proxy.is_valid():
		return await choose_server_proxy.call(allowed_servers)
	return allowed_servers[0] if not allowed_servers.is_empty() else "hq"


func choose_card_from_hand(hand: Array, _ctx: GameContext) -> Variant:
	if choose_card_from_hand_proxy.is_valid():
		return await choose_card_from_hand_proxy.call(hand)
	return hand[0] if not hand.is_empty() else null


func choose_from_search(candidates: Array, _ctx: GameContext) -> CardRecord:
	if choose_from_search_proxy.is_valid():
		return await choose_from_search_proxy.call(candidates)
	return candidates[0] as CardRecord if not candidates.is_empty() else null


func choose_window_action(ctx: GameContext, actor: String, can_rez_ice: bool) -> GameAction:
	# Human Corp player: show rez prompt for the approached ice or upgrades.
	# Human Runner player: pass for now — paid ability selection is a future feature.
	if actor == "corp" and can_rez_ice and rez_proxy.is_valid():
		# Find the first unrezzed ice on the target server to offer rezzing
		var target_server: Server = ctx.get_server(ctx.run_target_server)
		if target_server != null:
			for ice in target_server.ice:
				var c: InstalledCard = ice as InstalledCard
				if not c.is_rezzed:
					var should_rez: bool = await rez_proxy.call(c)
					if should_rez:
						var iid: String = c.get("runtime_instance_id") if c.get("runtime_instance_id") != null else ""
						return GameAction.rez_card(c.card_id, iid)
				break  # only ask about the outermost unrezzed piece

	elif actor == "corp" and not can_rez_ice and rez_proxy.is_valid():
		# Offer to rez upgrades in the target server root
		var target_server: Server = ctx.get_server(ctx.run_target_server)
		if target_server != null:
			for root_card in target_server.root:
				var c: InstalledCard = root_card as InstalledCard
				if not c.is_rezzed and c.card_record != null and c.card_record.card_type == "upgrade":
					var should_rez: bool = await rez_proxy.call(c)
					if should_rez:
						var iid: String = c.get("runtime_instance_id") if c.get("runtime_instance_id") != null else ""
						return GameAction.rez_card(c.card_id, iid)

	return GameAction.pass_window()

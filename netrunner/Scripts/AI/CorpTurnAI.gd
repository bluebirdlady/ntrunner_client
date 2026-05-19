class_name CorpTurnAI
extends RefCounted

# ── CorpTurnAI ────────────────────────────────────────────────────────────────
# Heuristic Corp decision maker for choices that arise during the Corp's turn.
# Implements choose_action(ctx) -> GameAction.
#
# Also owns a CorpRunAI instance and forwards run-time decisions to it,
# making CorpTurnAI the single Corp decision maker the TurnManager interacts with.
#
# Priority order each click:
#   1. Score agenda if one is ready in a protected remote
#   2. Advance agenda that is one counter away from scoring, in a protected remote
#   3. Install agenda in a protected remote (if one exists with ice)
#   4. Install ice on HQ if unprotected
#   5. Install ice on R&D if unprotected
#   6. Install ice on a remote with an agenda
#   7. Gain credits if below economy threshold
#   8. Draw a card if hand is small and deck is not empty
#   9. Gain credits (fallback)

const ECONOMY_THRESHOLD := 6   # try to stay above this credit level
const MIN_HAND_SIZE     := 3   # draw if hand drops below this

var _run_ai: CorpRunAI


func _init(ability_registry: AbilityRegistry) -> void:
	_run_ai = CorpRunAI.new(ability_registry)


# ── Turn-time interface ───────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
	# 1. Score a ready agenda
	var ready := _find_ready_agenda(ctx)
	if ready != null:
		# Scoring is free (no click cost in standard rules — handled in TurnManager
		# via the advance action triggering auto-score). If already at requirement,
		# we just advance once more to trigger scoring. This is a simplification;
		# proper scoring as a free action will be refined later.
		if ready.meets_advancement_requirement():
			return GameAction.advance(ready.card_id)

	# 2. Advance an agenda that is one away from scoring, in a protected remote
	var almost := _find_almost_scored_agenda(ctx)
	if almost != null and ctx.corp_credits >= 1:
		return GameAction.advance(almost.card_id)

	# 3. Install an agenda — prefer a protected remote, but also install into
	#    a new unprotected remote if we have ice in hand to protect it next click
	var agenda_to_install := _find_agenda_in_hand(ctx)
	if agenda_to_install != null:
		var protected_remote := _find_protected_empty_remote(ctx)
		if protected_remote != null:
			return GameAction.install(agenda_to_install, protected_remote.server_id)
		# No protected remote — install into new remote if we have ice to follow up
		elif _find_ice_in_hand(ctx) != null and ctx.corp_credits >= max(0, agenda_to_install.cost) + 1:
			var new_remote := ctx.create_remote_server()
			return GameAction.install(agenda_to_install, new_remote.server_id)

	# 4. Protect HQ if unprotected
	if not _server_has_ice(ctx, "hq"):
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, "hq", "ice")

	# 5. Protect R&D if unprotected
	if not _server_has_ice(ctx, "rd"):
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, "rd", "ice")

	# 6. Install ice on a remote that has an agenda but needs more ice
	var vulnerable_remote := _find_agenda_remote_needing_ice(ctx)
	if vulnerable_remote != null:
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, vulnerable_remote.server_id, "ice")

	# 7. Install ice on a remote that has cards but no ice
	var unprotected_remote := _find_remote_needing_ice(ctx)
	if unprotected_remote != null:
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, unprotected_remote.server_id, "ice")

	# 8. Install an asset in a new remote if we have one and can afford it
	var asset_to_install := _find_asset_in_hand(ctx)
	if asset_to_install != null and ctx.corp_credits >= max(0, asset_to_install.cost):
		var new_remote := ctx.create_remote_server()
		return GameAction.install(asset_to_install, new_remote.server_id)

	# 9. Advance any installed agenda in a protected remote
	if ctx.corp_credits >= 1:
		var any_agenda := _find_any_installed_agenda(ctx)
		if any_agenda != null:
			return GameAction.advance(any_agenda.card_id)

	# 8. Gain credits if below threshold
	if ctx.corp_credits < ECONOMY_THRESHOLD:
		return GameAction.gain_credits()

	# 11. Draw if hand is small
	if ctx.corp_hand.size() < MIN_HAND_SIZE and not ctx.corp_deck.is_empty():
		return GameAction.draw_card()

	# 12. Fallback: gain credits
	return GameAction.gain_credits()


# ── Run-time interface (forwarded to CorpRunAI) ───────────────────────────────

func choose_rez(card: InstalledCard, ctx: GameContext) -> bool:
	return _run_ai.choose_rez(card, ctx)


func choose_from_search(candidates: Array, _ctx: GameContext) -> CardRecord:
	# Heuristic: pick the cheapest card (most immediately playable)
	var best: CardRecord = candidates[0] as CardRecord
	for c in candidates:
		var r: CardRecord = c as CardRecord
		if r != null and r.cost < best.cost:
			best = r
	return best


func choose_card_from_hand(hand: Array, _ctx: GameContext) -> Variant:
	# Heuristic: return the most expensive card (hardest to play again soon),
	# or if all equal, just return the last card drawn (index 0 = oldest).
	var best: Variant = hand[0]
	var best_cost: int = -1
	for entry in hand:
		var r: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if r != null and r.cost > best_cost:
			best_cost = r.cost
			best = entry
	return best



func choose_window_action(ctx: GameContext, actor: String, can_rez_ice: bool) -> GameAction:
	# The Corp AI's behaviour during a paid-ability/rez timing window.
	# During approach (can_rez_ice = true): decide whether to rez the approached ice.
	# During movement or encounter (can_rez_ice = false): consider rezzing upgrades.
	if actor != "corp":
		return GameAction.pass_window()

	var target_server: Server = ctx.get_server(ctx.run_target_server)
	if target_server == null:
		return GameAction.pass_window()

	if can_rez_ice:
		# Find the outermost unrezzed ice — that's what the runner is approaching.
		# The RunStateMachine snapshots ice at run start; we scan the live server
		# for the first unrezzed piece at the current approach position.
		for ice in target_server.ice:
			var c: InstalledCard = ice as InstalledCard
			if not c.is_rezzed:
				if _run_ai.choose_rez(c, ctx):
					var iid: String = c.get("runtime_instance_id") if c.get("runtime_instance_id") != null else ""
					return GameAction.rez_card(c.card_id, iid)
			break  # only consider the outermost unrezzed piece
	else:
		# Non-approach window: consider rezzing upgrades in the target server root
		for root_card in target_server.root:
			var c: InstalledCard = root_card as InstalledCard
			if not c.is_rezzed and c.card_record != null and c.card_record.card_type == "upgrade":
				if _run_ai.choose_rez(c, ctx):
					var iid: String = c.get("runtime_instance_id") if c.get("runtime_instance_id") != null else ""
					return GameAction.rez_card(c.card_id, iid)

	return GameAction.pass_window()


# ── Heuristic helpers ─────────────────────────────────────────────────────────

func _find_ready_agenda(ctx: GameContext) -> InstalledCard:
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null:
				continue
			if c.card_record.is_agenda() and c.meets_advancement_requirement():
				return c
	return null


func _find_almost_scored_agenda(ctx: GameContext) -> InstalledCard:
	# An agenda that needs exactly one more advancement counter to score,
	# sitting in a remote with at least one piece of ice.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote() or not s.has_ice():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null or not c.card_record.is_agenda():
				continue
			var needed: int = c.card_record.advancement_requirement - c.get_counter("advancement")
			if needed == 1:
				return c
	return null


func _find_agenda_in_hand(ctx: GameContext) -> CardRecord:
	for entry in ctx.corp_hand:
		var e: Dictionary  = entry as Dictionary
		var r: CardRecord  = e.get("card_record", null) as CardRecord
		if r != null and r.is_agenda():
			return r
	return null


func _find_ice_in_hand(ctx: GameContext) -> CardRecord:
	for entry in ctx.corp_hand:
		var e: Dictionary = entry as Dictionary
		var r: CardRecord = e.get("card_record", null) as CardRecord
		if r != null and r.is_ice():
			return r
	return null


func _find_protected_empty_remote(ctx: GameContext) -> Server:
	# A remote server that has ice but no agenda/asset in its root.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote():
			continue
		if s.has_ice() and s.get_agenda_or_asset() == null:
			return s
	return null


func _find_agenda_remote_needing_ice(ctx: GameContext) -> Server:
	# A remote with an agenda but fewer than 2 ice protecting it.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote():
			continue
		if s.get_agenda_or_asset() == null:
			continue
		if s.ice_count() < 2:
			return s
	return null


func _find_remote_needing_ice(ctx: GameContext) -> Server:
	# A remote with cards installed but no protecting ice
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote():
			continue
		if not s.is_empty() and not s.has_ice():
			return s
	return null


func _find_asset_in_hand(ctx: GameContext) -> CardRecord:
	for entry in ctx.corp_hand:
		var e: Dictionary = entry as Dictionary
		var r: CardRecord = e.get("card_record", null) as CardRecord
		if r != null and r.is_asset():
			return r
	return null


func _find_any_installed_agenda(ctx: GameContext) -> InstalledCard:
	# Any agenda installed in a remote that has ice and hasn't met its requirement.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote() or not s.has_ice():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null or not c.card_record.is_agenda():
				continue
			if not c.meets_advancement_requirement():
				return c
	return null





func choose_modes(modes: Array, max_choices: int, ctx: GameContext) -> Array:
	# Heuristic: if we need credits more than cards, pick gain_credits; else draw.
	# For now: prefer credits if below economy threshold, else draw.
	var want_credits: bool = ctx.corp_credits < ECONOMY_THRESHOLD
	var result: Array = []
	for i in range(min(max_choices, modes.size())):
		var mode: Dictionary = modes[i] as Dictionary
		var label: String = mode.get("label", "").to_lower()
		# Simple label-based heuristic
		if want_credits and "credit" in label:
			result.append(i)
			break
		elif not want_credits and "draw" in label:
			result.append(i)
			break
	# Fallback: first mode
	if result.is_empty():
		result.append(0)
	return result


func _server_has_ice(ctx: GameContext, server_id: String) -> bool:
	var server: Server = ctx.get_server(server_id)
	return server != null and server.has_ice()

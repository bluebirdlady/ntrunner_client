class_name AbilityInterpreter
extends RefCounted

# ── AbilityInterpreter ────────────────────────────────────────────────────────
# Executes structured ability definitions from AbilityRegistry against a
# GameContext. Contains no game state of its own — it is purely a function
# from (definition, context) -> (mutated context).
#
# Adding support for a new card that uses existing effect types: write JSON.
# Adding a new effect type: add one handler to _execute_effect().
#
# Usage:
#   var interp := AbilityInterpreter.new()
#   await interp.execute_trigger(ability_def, context)


# ── Public entry points ───────────────────────────────────────────────────────

# Execute a trigger definition (on_play, on_access, on_rez, etc.)
# These are the dicts returned by AbilityRegistry.get_on_play() etc.
func execute_trigger(trigger_def: Dictionary, ctx: GameContext) -> void:
	# Route modal abilities to the modal executor
	if trigger_def.has("modes"):
		await execute_modal_trigger(trigger_def, ctx)
		return

	# Check top-level condition
	if trigger_def.has("condition"):
		if not _evaluate_condition(trigger_def["condition"] as Dictionary, ctx):
			ctx.log("Condition not met — ability has no effect.")
			return

	# Resolve targeting if required
	var chosen_target: Variant = null
	if trigger_def.has("target"):
		chosen_target = await _resolve_target(trigger_def["target"] as Dictionary, ctx)
		if chosen_target == null:
			ctx.log("No valid targets — ability has no effect.")
			return

	# Execute effects
	var effects: Array = trigger_def.get("effects", []) as Array
	for effect in effects:
		await _execute_effect(effect as Dictionary, ctx, chosen_target)


# Execute a single subroutine definition.
# Returns true if the subroutine fired, false if its condition blocked it.
func execute_subroutine(sub_def: Dictionary, ctx: GameContext) -> bool:
	if sub_def.has("condition"):
		if not _evaluate_condition(sub_def["condition"] as Dictionary, ctx):
			ctx.log("Subroutine condition not met — no effect.")
			return false

	var effects: Array = sub_def.get("effects", []) as Array
	for effect in effects:
		await _execute_effect(effect as Dictionary, ctx, null)
	return true


# ── Condition evaluation ──────────────────────────────────────────────────────

func _evaluate_condition(condition: Dictionary, ctx: GameContext) -> bool:
	var ctype: String = condition.get("type", "")
	var params: Dictionary = condition.get("params", {}) as Dictionary

	match ctype:
		"runner_is_tagged":
			return ctx.runner_is_tagged()

		"credits_compare":
			var subject: String   = params.get("subject", "runner")
			var operator: String  = params.get("operator", "lte")
			var value: int        = params.get("value", 0)
			var credits: int      = ctx.get_credits(subject)
			match operator:
				"lt":  return credits <  value
				"lte": return credits <= value
				"gt":  return credits >  value
				"gte": return credits >= value
				"eq":  return credits == value
				"neq": return credits != value
			push_error("AbilityInterpreter: unknown operator '%s'" % operator)
			return false

		"and":
			var conditions: Array = condition.get("conditions", []) as Array
			for c in conditions:
				if not _evaluate_condition(c as Dictionary, ctx):
					return false
			return true

		"or":
			var conditions: Array = condition.get("conditions", []) as Array
			for c in conditions:
				if _evaluate_condition(c as Dictionary, ctx):
					return true
			return false

		"not":
			var inner: Dictionary = condition.get("condition", {}) as Dictionary
			return not _evaluate_condition(inner, ctx)

		_:
			push_error("AbilityInterpreter: unknown condition type '%s'" % ctype)
			return false


# ── Target resolution ─────────────────────────────────────────────────────────

func _resolve_target(target_spec: Dictionary, ctx: GameContext) -> Variant:
	var ttype: String   = target_spec.get("type", "")
	var params: Dictionary = target_spec.get("params", {}) as Dictionary

	var candidates: Array = []

	match ttype:
		"installed_card":
			var controller: String = params.get("controller", "")
			var card_types: Array  = params.get("card_types", []) as Array
			var exclude_installed_this_turn: bool = params.get("exclude_installed_this_turn", false)
			var pool: Array = []
			if controller == "runner" or controller == "":
				pool.append_array(ctx.runner_rig)
			if controller == "corp" or controller == "":
				pool.append_array(ctx.all_installed())
			candidates = pool.filter(func(c: InstalledCard):
				var type_match: bool = card_types.is_empty() or card_types.has(c.card_record.card_type)
				var turn_ok: bool = not exclude_installed_this_turn or \
					not ctx.corp_installed_this_turn.has(c.card_id)
				return type_match and turn_ok
			)
		_:
			push_error("AbilityInterpreter: unknown target type '%s'" % ttype)
			return null

	if candidates.is_empty():
		return null

	# Random selection (e.g. HQ access)
	if params.get("random", false):
		return candidates[randi() % candidates.size()]

	# Ask the decision maker to choose
	var decision_maker: Object = ctx.corp_decision_maker if ctx.active_player == "corp" else ctx.runner_decision_maker
	if decision_maker == null:
		push_error("AbilityInterpreter: target required but no decision_maker set")
		return candidates[0]

	var choice_context := {
		"reason": "target",
		"target_spec": target_spec
	}
	return await decision_maker.choose_target(candidates, choice_context)


# ── Effect execution ──────────────────────────────────────────────────────────

func _execute_effect(effect: Dictionary, ctx: GameContext, chosen_target: Variant) -> void:
	var etype: String    = effect.get("type", "")
	var params: Dictionary = effect.get("params", {}) as Dictionary

	match etype:

		"gain_credits":
			var subject: String = params.get("subject", "corp")
			var amount: int     = params.get("amount", 0)
			ctx.set_credits(subject, ctx.get_credits(subject) + amount)
			ctx.log("%s gains %d credits." % [ctx.player_name(subject), amount])

		"lose_credits":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 0)
			var current: int    = ctx.get_credits(subject)
			var lost: int       = min(amount, current)  # can't go below 0
			ctx.set_credits(subject, current - lost)
			ctx.log("%s loses %d credits." % [ctx.player_name(subject), lost])

		"end_run":
			ctx.run_ended = true
			ctx.log("Run ended.")

		"deal_damage":
			var damage_type: String = params.get("damage_type", "net")
			var amount_def          = params.get("amount", 0)
			var amount: int         = _resolve_amount(amount_def, ctx)
			_deal_damage(damage_type, amount, ctx)

		"deal_damage_etr_if_odd_cost":
			# Diviner: do N net damage; if the trashed card has an odd printed cost, end the run.
			var damage_type: String = params.get("damage_type", "net")
			var amount: int         = _resolve_amount(params.get("amount", 1), ctx)
			var trashed_cards: Array = _deal_damage(damage_type, amount, ctx)
			if not ctx.game_over and not trashed_cards.is_empty():
				var first: CardRecord = trashed_cards[0] as CardRecord
				if first != null:
					var printed_cost: int = max(0, first.cost)
					if printed_cost % 2 != 0:
						ctx.log("Diviner: %s has odd cost (%d) — run ends." % [first.title, printed_cost])
						ctx.run_ended = true
					else:
						ctx.log("Diviner: %s has even cost (%d) — run continues." % [first.title, printed_cost])

		"deal_damage_then_may_jack_out":
			# Karunā sub 1: do 2 net damage, then the Runner may jack out.
			# If they jack out, sub 2 (end the run) does not resolve even if unbroken.
			var damage_type: String = params.get("damage_type", "net")
			var amount: int         = _resolve_amount(params.get("amount", 2), ctx)
			_deal_damage(damage_type, amount, ctx)
			if not ctx.game_over:
				# Offer jack-out window to the runner
				var did_jack_out := false
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_jack_out"):
					did_jack_out = await ctx.runner_decision_maker.choose_jack_out(ctx)
				if did_jack_out:
					ctx.log("%s jacks out after Karunā damage." % ctx.runner_name())
					ctx.run_ended = true
					# Mark that the runner chose to jack out so sub 2 is skipped
					ctx.set_meta("karuna_runner_jacked_out", true)

		"draw_cards":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 1)
			_draw_cards(subject, amount, ctx)

		"runner_must_pay_or_end_run":
			# Runner must choose one of the listed payment options or end the run.
			# Used by Manegarm Skunkworks.
			var options: Array = params.get("options", []) as Array
			if options.is_empty():
				return

			# Build available options the runner can actually afford
			var affordable: Array = []
			for opt in options:
				var o: Dictionary = opt as Dictionary
				match o.get("type", ""):
					"clicks":
						if ctx.runner_clicks >= o.get("amount", 0):
							affordable.append(o)
					"credits":
						if ctx.runner_credits >= o.get("amount", 0):
							affordable.append(o)

			if affordable.is_empty():
				ctx.log("%s cannot afford any payment option — run ends." % ctx.runner_name())
				ctx.run_ended = true
				return

			# Ask runner to choose
			var dm: Object = ctx.runner_decision_maker
			var chosen: Variant = null
			if dm != null and dm.has_method("choose_payment_option"):
				chosen = await dm.choose_payment_option(affordable, ctx)
			else:
				chosen = null  # no decision maker — end run

			if chosen == null:
				ctx.log("%s ends the run (Manegarm Skunkworks)." % ctx.runner_name())
				ctx.run_ended = true
				return

			# Apply chosen payment
			var c: Dictionary = chosen as Dictionary
			match c.get("type", ""):
				"clicks":
					var amount: int = c.get("amount", 0)
					ctx.runner_clicks -= amount
					ctx.log("%s spends %d click(s) for Manegarm Skunkworks." % [ctx.runner_name(), amount])
				"credits":
					var amount: int = c.get("amount", 0)
					ctx.runner_credits -= amount
					ctx.log("%s pays %d cr for Manegarm Skunkworks." % [ctx.runner_name(), amount])

		"install_ice_from_hq":
			# Corp chooses an ice from HQ (or Archives if allowed) and installs it
			# on the current run server ignoring all costs.
			var also_archives: bool = params.get("also_archives", false)
			var candidates: Array = []
			for entry in ctx.corp_hand:
				var e: Dictionary = entry as Dictionary
				var r: CardRecord = e.get("card_record", null) as CardRecord
				if r != null and r.is_ice():
					candidates.append(e)
			if also_archives:
				for r in ctx.corp_discard:
					var record: CardRecord = r as CardRecord
					if record != null and record.is_ice():
						candidates.append({"card_id": record.id, "card_record": record, "_from_archives": true})
			if candidates.is_empty():
				ctx.log("%s has no ice in HQ%s to install." % [ctx.corp_name(), " or Archives" if also_archives else ""])
			else:
				var dm: Object = ctx.corp_decision_maker
				var chosen_entry: Variant = null
				if dm != null and dm.has_method("choose_card_from_hand"):
					chosen_entry = await dm.choose_card_from_hand(candidates, ctx)
				else:
					chosen_entry = candidates[0]
				if chosen_entry != null:
					var record: CardRecord = (chosen_entry as Dictionary).get("card_record", null) as CardRecord
					if record != null:
						if (chosen_entry as Dictionary).get("_from_archives", false):
							ctx.corp_discard.erase(record)
						else:
							ctx.corp_hand.erase(chosen_entry)
						var server: Server = ctx.get_server(ctx.run_target_server)
						if server != null:
							var installed := InstalledCard.make_runtime_instance(record, ctx.run_target_server, "ice", false)
							server.install_ice(installed)
							ctx.log("%s installs %s from %s on %s (ignoring costs)." % [ctx.corp_name(), 
								record.title,
								"Archives" if (chosen_entry as Dictionary).get("_from_archives", false) else "HQ",
								server.display_name()
							])

		"trash_runner_installed":
			# Trash one of the runner\'s installed cards matching given types.
			var card_types: Array = params.get("card_types", ["resource"]) as Array
			var subtypes: Array   = params.get("subtypes", []) as Array
			var pool: Array = ctx.runner_rig.filter(func(c: InstalledCard):
				if c.card_record == null:
					return false
				var type_match := card_types.is_empty() or card_types.has(c.card_record.card_type)
				var sub_match  := subtypes.is_empty()
				if not sub_match:
					for st in subtypes:
						if c.card_record.has_subtype(st):
							sub_match = true
							break
				return type_match and sub_match
			)
			if pool.is_empty():
				ctx.log("No valid %s cards to trash." % ctx.runner_name())
			else:
				var dm: Object = ctx.corp_decision_maker
				var target: InstalledCard = null
				if dm != null and dm.has_method("choose_target"):
					target = await dm.choose_target(pool, {"reason": "trash_runner_installed"})
				else:
					target = pool[0] as InstalledCard
				if target != null:
					ctx.runner_rig.erase(target)
					ctx.unregister_all_card_effects(target.runtime_instance_id)
					ctx.log("%s trashes %s's %s." % [ctx.corp_name(), ctx.runner_name(), target.display_name()])

		"search_deck":
			# Search deck for cards matching a condition, let player choose one,
			# add it to hand, then shuffle the deck.
			var subject: String      = params.get("subject", "runner")
			var subtypes: Array      = params.get("subtypes", []) as Array
			var card_types: Array    = params.get("card_types", []) as Array
			var reveal: bool         = params.get("reveal", true)
			var deck: Array          = ctx.corp_deck if subject == "corp" else ctx.runner_deck
			var hand: Array          = ctx.corp_hand if subject == "corp" else ctx.runner_hand

			# Build candidate list from deck
			var candidates: Array = []
			for card_record in deck:
				var r: CardRecord = card_record as CardRecord
				if r == null:
					continue
				var type_match := card_types.is_empty() or card_types.has(r.card_type)
				var subtype_match := subtypes.is_empty()
				if not subtype_match:
					for st in subtypes:
						if r.has_subtype(st):
							subtype_match = true
							break
				if type_match and subtype_match:
					candidates.append(r)

			if candidates.is_empty():
				ctx.log("No matching cards found in deck.")
			else:
				var dm: Object = ctx.corp_decision_maker if subject == "corp" else ctx.runner_decision_maker
				var chosen: CardRecord = null
				if dm != null and dm.has_method("choose_from_search"):
					chosen = await dm.choose_from_search(candidates, ctx)
				else:
					chosen = candidates[0]

				if chosen != null:
					deck.erase(chosen)
					hand.append({"card_id": chosen.id, "card_record": chosen})
					if reveal:
						ctx.log("%s reveals and takes %s from their deck." % [ctx.player_name(subject), chosen.title])
					else:
						ctx.log("%s takes a card from their deck." % ctx.player_name(subject))
					# Shuffle the deck after searching
					deck.shuffle()
					ctx.log("%s's deck is shuffled." % ctx.player_name(subject))

		"choose_and_return_to_deck":
			# Ask the active player to choose a card from their hand to shuffle back.
			var subject: String = params.get("subject", "corp")
			var hand: Array = ctx.corp_hand if subject == "corp" else ctx.runner_hand
			var deck: Array = ctx.corp_deck if subject == "corp" else ctx.runner_deck
			if hand.is_empty():
				ctx.log("No cards in hand to return to deck.")
			else:
				var dm: Object = ctx.corp_decision_maker if subject == "corp" else ctx.runner_decision_maker
				var chosen_entry: Variant = null
				if dm != null and dm.has_method("choose_card_from_hand"):
					chosen_entry = await dm.choose_card_from_hand(hand, ctx)
				else:
					chosen_entry = hand[0]
				if chosen_entry != null:
					hand.erase(chosen_entry)
					var insert_pos: int = randi() % (deck.size() + 1)
					deck.insert(insert_pos, (chosen_entry as Dictionary).get("card_record", null))
					var r: CardRecord = (chosen_entry as Dictionary).get("card_record", null)
					ctx.log("%s shuffles %s back into their deck." % [
						ctx.player_name(subject),
						r.title if r else "a card"
					])

		"set_run_modifier":
			# Set a key in ctx.run_modifiers for the duration of the current run.
			var key: String = params.get("key", "")
			var value: int  = int(params.get("value", 0))
			if key != "":
				ctx.run_modifiers[key] = value
				ctx.log("Run modifier set: %s = %d" % [key, value])

		"initiate_run":
			# Start a run as part of playing an event.
			var server_id: String = params.get("server_id", "")
			if server_id == "" and ctx.has_meta("chosen_run_server"):
				server_id = ctx.get_meta("chosen_run_server")
			if server_id == "" or not ctx.servers.has(server_id):
				push_error("AbilityInterpreter: initiate_run has no valid server")
				return
			if ctx.has_meta("on_run_started"):
				var cb: Callable = ctx.get_meta("on_run_started") as Callable
				cb.call(server_id)
				await Engine.get_main_loop().process_frame
			var rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if rsm == null:
				push_error("AbilityInterpreter: initiate_run — no run_state_machine on ctx")
				return
			await rsm.execute(server_id)

		"choose_and_run":
			# Ask the runner to choose a server from a list, then run it.
			var allowed: Array = params.get("servers", ["hq", "rd", "archives"]) as Array
			var chosen: String = allowed[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				chosen = await ctx.runner_decision_maker.choose_server(allowed, ctx)
			ctx.set_meta("chosen_run_server", chosen)
			if ctx.has_meta("on_run_started"):
				var cb: Callable = ctx.get_meta("on_run_started") as Callable
				cb.call(chosen)
				await Engine.get_main_loop().process_frame
			var rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if rsm == null:
				push_error("AbilityInterpreter: choose_and_run — no run_state_machine on ctx")
				return
			await rsm.execute(chosen)

		"run_central_if_unrun":
			# Red Team: spend a click to run a central not yet run this turn.
			# If successful, take payout_amount credits from this card's hosted pool.
			var payout_counter: String = params.get("payout_counter", "credits")
			var payout_amount: int     = params.get("payout_amount", 3)

			# Build list of eligible centrals (not yet run this turn, has credits)
			var iid: String         = ctx.current_event_data.get("card_instance_id", "")
			var self_card: InstalledCard = ctx.get_installed_card_by_instance_id(iid)
			if self_card == null or self_card.get_counter(payout_counter) <= 0:
				ctx.log("Red Team: no credits remaining — cannot use.")
				return

			var all_centrals: Array = ["hq", "rd", "archives"]
			var eligible: Array = []
			for srv in all_centrals:
				if srv not in ctx.runner_centrals_run_this_turn:
					eligible.append(srv)

			if eligible.is_empty():
				ctx.log("Red Team: all central servers already run this turn.")
				return

			# Ask runner to choose which central to run
			var chosen: String = eligible[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				chosen = await ctx.runner_decision_maker.choose_server(eligible, ctx)

			ctx.log("Red Team: %s runs %s." % [ctx.runner_name(), chosen.to_upper()])

			# Register a one-shot successful_run hook to pay out before breach
			ctx.set_meta("red_team_pending_payout", {
				"card_instance_id": iid,
				"counter": payout_counter,
				"amount": payout_amount,
				"server_id": chosen
			})

			# Initiate the run
			if ctx.has_meta("on_run_started"):
				var cb: Callable = ctx.get_meta("on_run_started") as Callable
				cb.call(chosen)
				await Engine.get_main_loop().process_frame
			var rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if rsm == null:
				push_error("AbilityInterpreter: run_central_if_unrun — no run_state_machine on ctx")
				ctx.remove_meta("red_team_pending_payout")
				return
			await rsm.execute(chosen)

			# Record that this central was run
			if chosen not in ctx.runner_centrals_run_this_turn:
				ctx.runner_centrals_run_this_turn.append(chosen)
			ctx.remove_meta_if_exists("red_team_pending_payout")

		"rez_card_free":
			# Rez an installed card ignoring its rez cost.
			# Prompts the active player to choose which card to rez.
			var target_zone: String = params.get("target_zone", "ice")
			var candidates: Array   = []
			for server in ctx.servers.values():
				var s: Server = server as Server
				var zone_cards: Array = s.ice if target_zone == "ice" else s.root
				for card in zone_cards:
					var c: InstalledCard = card as InstalledCard
					if not c.is_rezzed:
						candidates.append(c)
			if candidates.is_empty():
				ctx.log("No unrezzed %s to rez for free." % target_zone)
			else:
				var dm: Object = ctx.corp_decision_maker if ctx.active_player == "corp" else ctx.runner_decision_maker
				var target: InstalledCard = null
				if dm != null and dm.has_method("choose_target"):
					target = await dm.choose_target(candidates, {"reason": "rez_free"})
				else:
					target = candidates[0]
				if target != null:
					target.is_rezzed = true
					ctx.log("Rezzed %s for free." % target.display_name())

		"increase_hand_size":
			var subject: String = params.get("subject", "corp")
			var amount: int     = params.get("amount", 1)
			if subject == "corp":
				ctx.corp_hand_size_bonus += amount
				ctx.log("%s max hand size increased to %d." % [ctx.corp_name(), ctx.corp_max_hand_size()])
			else:
				ctx.runner_hand_size_bonus += amount
				ctx.log("%s max hand size increased to %d." % [ctx.runner_name(), ctx.runner_max_hand_size()])

		"add_self_counter_if_server":
			# Add a counter to self only if the run is on a specific server.
			var required_server: String = params.get("server", "rd")
			var counter_type: String    = effect.get("counter", params.get("counter", "virus"))
			var amount: int             = int(effect.get("amount", params.get("amount", 1)))
			var actual_server: String   = ctx.current_event_data.get("server_id", "")
			if actual_server == required_server:
				var iid: String = ctx.current_event_data.get("card_instance_id", "")
				var self_card := ctx.get_installed_card_by_instance_id(iid)
				if self_card == null and iid != "":
					self_card = ctx.get_installed_card_by_id(iid)
				if self_card != null:
					self_card.add_counter(counter_type, amount)
					ctx.log("Placed %d %s counter(s) on %s (%d total)." % [
						amount, counter_type, self_card.display_name(),
						self_card.get_counter(counter_type)
					])

		"set_bonus_access_from_counters":
			# Set run_modifiers["bonus_access"] to the card's current counter count.
			# Only fires if the current run is on the required server (if specified).
			var required_server: String = params.get("server", "")
			if required_server != "":
				var actual_server: String = ctx.current_event_data.get("server_id", "")
				if actual_server != required_server:
					return  # wrong server — do nothing
			var counter_type: String = effect.get("counter", params.get("counter", "virus"))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null and iid != "":
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card != null:
				var count: int = self_card.get_counter(counter_type)
				ctx.run_modifiers["bonus_access"] = count
				if count > 0:
					ctx.log("%s: +%d R&D access from virus counters." % [self_card.display_name(), count])

		"transfer_hosted_credits":
			# Move credits from a hosted card counter to the runner's pool.
			# Used by Leech to spend hosted credits during encounters.
			var amount: int         = int(effect.get("amount", params.get("amount", 1)))
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null and iid != "":
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card != null:
				var available: int = self_card.get_counter(counter_type)
				var taken: int     = min(amount, available)
				if taken > 0:
					self_card.remove_counter(counter_type, taken)
					ctx.runner_credits += taken
					ctx.log("%s takes %d cr from %s (%d remaining)." % [ctx.runner_name(), 
						taken, self_card.display_name(), self_card.get_counter(counter_type)
					])

		"add_self_counters":
			# Add counters to the card that owns this ability.
			# The owning card's instance_id is in ctx.current_event_data.
			# Note: JSON stores "counter" and "amount" at effect top level, not under "params"
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int          = int(effect.get("amount", params.get("amount", 0)))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			if iid == "":
				# Fallback: try card_id match (for on_rez fired directly)
				iid = ctx.current_event_data.get("card_id", "")
			var self_card := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null and iid != "":
				# Last resort: find by card_id slug
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card != null:
				self_card.add_counter(counter_type, amount)
				ctx.log("Placed %d %s counter(s) on %s." % [amount, counter_type, self_card.display_name()])
			else:
				push_error("AbilityInterpreter: add_self_counters could not find card '%s'" % iid)

		"take_hosted_credits":
			# Move credits from the card's hosted counter to a player's credit pool.
			var subject: String  = effect.get("subject", params.get("subject", "corp"))
			var amount: int      = int(effect.get("amount", params.get("amount", 0)))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card := ctx.get_installed_card_by_instance_id(iid)
			if self_card != null:
				var available: int = self_card.get_counter("credits")
				var taken: int     = min(amount, available)
				if taken > 0:
					self_card.remove_counter("credits", taken)
					ctx.set_credits(subject, ctx.get_credits(subject) + taken)
					ctx.log("%s takes %d cr from %s (%d remaining)." % [
						ctx.player_name(subject), taken, self_card.display_name(),
						self_card.get_counter("credits")
					])

		"take_hosted_credits_amount":
			# Click action: take a fixed amount of hosted credits (Regolith, Telework).
			# Respects available credits — takes up to amount or what's available.
			var subject: String     = effect.get("subject", params.get("subject", "runner"))
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int         = int(effect.get("amount", params.get("amount", 3)))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null:
				push_error("AbilityInterpreter: take_hosted_credits_amount — card not found")
			else:
				var available: int = self_card.get_counter(counter_type)
				if available <= 0:
					ctx.log("%s is empty." % self_card.display_name())
				else:
					var taken: int = min(amount, available)
					self_card.remove_counter(counter_type, taken)
					ctx.set_credits(subject, ctx.get_credits(subject) + taken)
					ctx.log("%s takes %d cr from %s (%d remaining)." % [
						ctx.player_name(subject), taken, self_card.display_name(),
						self_card.get_counter(counter_type)
					])

		"take_all_hosted_credits":
			# Click action: take ALL hosted credits (Smartware Distributor, Pennyshaver).
			var subject: String     = effect.get("subject", params.get("subject", "runner"))
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null:
				push_error("AbilityInterpreter: take_all_hosted_credits — card not found")
			else:
				var available: int = self_card.get_counter(counter_type)
				if available <= 0:
					ctx.log("%s has no credits to take." % self_card.display_name())
				else:
					self_card.remove_counter(counter_type, available)
					ctx.set_credits(subject, ctx.get_credits(subject) + available)
					ctx.log("%s takes all %d cr from %s." % [
						ctx.player_name(subject), available, self_card.display_name()
					])

		"remove_self_counter":
			# Remove one counter of a type from the owning card.
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int          = int(effect.get("amount", params.get("amount", 1)))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card := ctx.get_installed_card_by_instance_id(iid)
			if self_card != null:
				self_card.remove_counter(counter_type, amount)

		"self_trash_if_empty":
			# Trash the owning card if a given counter reaches zero.
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card := ctx.get_installed_card_by_instance_id(iid)
			if self_card != null and self_card.get_counter(counter_type) <= 0:
				# Remove from server
				var server: Server = ctx.get_server(self_card.server_id)
				if server:
					server.remove_from_root(self_card)
					ctx.remove_empty_remote_servers()
				# Also check runner rig
				ctx.runner_rig.erase(self_card)
				# Unregister all its listeners
				ctx.unregister_all_card_effects(iid)
				ctx.log("%s is trashed (empty)." % self_card.display_name())

		"self_trash_if_empty_and_draw":
			# Trash the owning card if empty, and draw 1 card for the Corp (Nico Campaign).
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card := ctx.get_installed_card_by_instance_id(iid)
			if self_card != null and self_card.get_counter(counter_type) <= 0:
				var server: Server = ctx.get_server(self_card.server_id)
				if server:
					server.remove_from_root(self_card)
					ctx.remove_empty_remote_servers()
				ctx.runner_rig.erase(self_card)
				ctx.unregister_all_card_effects(iid)
				ctx.log("%s is trashed (empty)." % self_card.display_name())
				# Draw 1 card for the Corp
				if not ctx.corp_deck.is_empty():
					var drawn: CardRecord = ctx.corp_deck.pop_front() as CardRecord
					ctx.corp_hand.append({"card_id": drawn.id, "card_record": drawn})
					ctx.log("%s draws %s (Nico Campaign)." % [ctx.corp_name(), drawn.title])
				else:
					ctx.log("%s deck is empty — cannot draw from Nico Campaign." % ctx.corp_name())

		"lose_clicks_next_turn":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 1)
			var current: int    = ctx.pending_click_penalties.get(subject, 0)
			ctx.pending_click_penalties[subject] = current + amount
			ctx.log("%s will lose %d click(s) next turn." % [ctx.player_name(subject), amount])

		"add_counters_to_target":
			var counter_type: String = params.get("counter_type", "advancement")
			var amount: int          = params.get("amount", 1)
			if chosen_target != null and chosen_target is InstalledCard:
				(chosen_target as InstalledCard).add_counter(counter_type, amount)
				ctx.log("Placed %d %s counter(s) on %s." % [
					amount, counter_type,
					(chosen_target as InstalledCard).display_name()
				])
			else:
				push_error("AbilityInterpreter: add_counters_to_target has no valid target")

		"trash_card":
			var target_ref: String = params.get("target", "chosen")
			if target_ref == "chosen" and chosen_target != null:
				_trash_installed_card(chosen_target as InstalledCard, ctx)
			else:
				push_error("AbilityInterpreter: trash_card has no valid target")

		"install_from_grip_optional":
			# Pantograph: runner may install a card from grip paying its install cost.
			if ctx.runner_hand.is_empty():
				ctx.log("Pantograph: no cards in grip to install.")
				return
			var dm: Object = ctx.runner_decision_maker
			if dm == null:
				return
			var chosen: CardRecord = null
			if dm.has_method("choose_card_from_hand"):
				var entry: Variant = await dm.choose_card_from_hand(ctx.runner_hand, ctx)
				if entry != null:
					chosen = (entry as Dictionary).get("card_record", null) as CardRecord
			if chosen == null:
				ctx.log("Pantograph: runner declines to install.")
				return
			var cost: int = max(0, chosen.cost)
			if ctx.runner_credits < cost:
				ctx.log("Pantograph: cannot afford to install %s." % chosen.title)
				return
			ctx.runner_credits -= cost
			var installed := InstalledCard.make_runtime_instance(chosen, "runner_rig", "root", true)
			ctx.runner_rig.append(installed)
			for i in range(ctx.runner_hand.size()):
				var e: Dictionary = ctx.runner_hand[i] as Dictionary
				if e.get("card_record", null) == chosen:
					ctx.runner_hand.remove_at(i)
					break
			if ctx.has_meta("ability_registry"):
				var ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var on_rez_def = ab_reg.get_on_rez(chosen.id)
				if on_rez_def != null:
					ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
					await execute_trigger(on_rez_def as Dictionary, ctx)
					ctx.current_event_data = {}
			ctx.log("Pantograph: %s installs %s for %d cr." % [ctx.runner_name(), chosen.title, cost])

		"install_from_grip_free":
			# Pantograph: install a card from grip ignoring install cost.
			var installable: Array = []
			for entry in ctx.runner_hand:
				var e: Dictionary = entry as Dictionary
				var r: CardRecord = e.get("card_record", null) as CardRecord
				if r == null:
					continue
				if r.card_type in ["program", "hardware", "resource"]:
					installable.append(entry)

			if installable.is_empty():
				ctx.log("Pantograph: no installable cards in grip.")
				return

			var chosen_entry: Variant = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_hand"):
				chosen_entry = await ctx.runner_decision_maker.choose_card_from_hand(installable, ctx)

			if chosen_entry == null:
				ctx.log("Pantograph: no card chosen.")
				return

			var record: CardRecord = (chosen_entry as Dictionary).get("card_record", null) as CardRecord
			if record == null:
				return

			# MU check for programs
			if record.card_type == "program" and record.memory_cost > 0:
				if ctx.runner_mu_available() < record.memory_cost:
					ctx.log("Pantograph: not enough MU to install %s." % record.title)
					return

			# Remove from hand and install
			ctx.runner_hand.erase(chosen_entry)
			var installed := InstalledCard.make_runtime_instance(record, "runner_rig", "root", true)
			ctx.runner_rig.append(installed)

			# Register event listeners via TurnManager callback
			if ctx.has_meta("register_installed_card"):
				var reg: Callable = ctx.get_meta("register_installed_card") as Callable
				reg.call(installed)

			# Fire on_rez if defined
			if ctx.has_meta("ability_registry"):
				var reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var on_rez_def = reg.get_on_rez(record.id)
				if on_rez_def != null:
					ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
					await execute_trigger(on_rez_def as Dictionary, ctx)
					ctx.current_event_data = {}

			ctx.log("Pantograph: %s installs %s for free. [MU: %d/%d]" % [
				ctx.runner_name(), record.title,
				ctx.runner_mu_used(), ctx.runner_total_mu()
			])

		"give_tags":
			# Give the runner N tags.
			var amount: int = _resolve_amount(params.get("amount", 1), ctx)
			ctx.runner_tags += amount
			ctx.log("%s takes %d tag(s). (%d total)" % [ctx.runner_name(), amount, ctx.runner_tags])

		"clearinghouse_activate":
			# Clearinghouse: At turn start, Corp may add 1 advancement counter,
			# then deal 1 meat per counter and trash itself. Activation is optional.
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card   := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null and iid != "":
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card == null:
				return

			# AI decision: activate if runner is close to winning or has many counters
			# (threat grows each turn — AI should activate when it will be lethal or near-lethal)
			var current_counters: int = self_card.get_counter("advancement")
			var damage_if_activate: int = current_counters + 1   # +1 for the counter we're adding
			var runner_grip: int = ctx.runner_hand.size()

			var should_activate := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_activate_clearinghouse"):
				should_activate = await ctx.corp_decision_maker.choose_activate_clearinghouse(self_card, ctx)
			else:
				# Default AI: activate if it would flatline (or near-flatline) the runner
				should_activate = damage_if_activate >= runner_grip

			if not should_activate:
				ctx.log("Clearinghouse: Corp holds. (%d counters, would deal %d meat)" % [
					current_counters, damage_if_activate
				])
				return

			# Activate: add 1 counter first
			self_card.add_counter("advancement", 1)
			var total_damage: int = self_card.get_counter("advancement")
			ctx.log("Clearinghouse fires! Deals %d meat damage." % total_damage)

			# Deal meat damage
			_deal_damage("meat", total_damage, ctx)

			# Trash Clearinghouse (mandatory after activating)
			var server: Server = ctx.get_server(self_card.server_id)
			if server:
				server.remove_from_root(self_card)
				ctx.remove_empty_remote_servers()
			ctx.unregister_all_card_effects(self_card.runtime_instance_id)
			if self_card.card_record != null:
				ctx.corp_discard.append(self_card.card_record)
			ctx.log("Clearinghouse is trashed.")
			# Tranquilizer: derez the ice this program is hosted on.
			# Fires at the start of the Corp's turn while installed.
			if self_card == null:
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card != null and self_card.hosted_on_id != "":
				var host_ice := ctx.get_ice_by_instance_id(self_card.hosted_on_id)
				if host_ice != null and host_ice.is_rezzed:
					host_ice.is_rezzed = false
					ctx.log("Tranquilizer: %s is derezzed." % host_ice.display_name())
					await ctx.notify_event("on_derez", {
						"card": host_ice,
						"card_instance_id": self_card.runtime_instance_id
					}, self)
				elif host_ice != null:
					ctx.log("Tranquilizer: %s is already unrezzed." % host_ice.display_name())

		"gain_credits_per_counter":
			# Fermenter: gain 2cr for each hosted virus counter, then card trashes itself.
			var counter_type: String = effect.get("counter", "virus")
			var credits_per: int     = int(effect.get("credits_per", params.get("credits_per", 2)))
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card   := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null and iid != "":
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card != null:
				var count: int    = self_card.get_counter(counter_type)
				var gained: int   = count * credits_per
				ctx.runner_credits += gained
				ctx.log("Fermenter: %s gains %d cr (%d counters × %d cr)." % [
					ctx.runner_name(), gained, count, credits_per
				])
			else:
				push_error("AbilityInterpreter: gain_credits_per_counter — card not found")

		"add_counters_to_installed_virus":
			# Cookbook: when a virus program is installed, place 1 counter on it.
			# The newly installed card's instance_id is in event_data.
			var counter_type: String = effect.get("counter", "virus")
			var amount: int          = int(effect.get("amount", 1))
			# The newly-installed virus card is the event source
			var new_card_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var new_card := ctx.get_installed_card_by_instance_id(new_card_iid)
			if new_card != null:
				new_card.add_counter(counter_type, amount)
				ctx.log("Cookbook: placed %d %s counter(s) on %s." % [
					amount, counter_type, new_card.display_name()
				])

		"gain_credits_first_trash_this_turn":
			# Loup: the first time each turn you trash during a breach, gain 2cr.
			if ctx.runner_trashed_during_breach_this_turn:
				return   # already fired this turn
			ctx.runner_trashed_during_breach_this_turn = true
			var amount: int = int(params.get("amount", 2))
			ctx.runner_credits += amount
			ctx.log("Loup: %s gains %d cr (first trash this turn)." % [ctx.runner_name(), amount])

		"may_swap_two_ice":
			# Tāo: after a successful run, may swap two ice on any single server.
			if ctx.runner_decision_maker == null:
				return

			# Build list of servers that have ≥2 ice
			var eligible_servers: Array = []
			for server in ctx.servers.values():
				var s: Server = server as Server
				if s.ice_count() >= 2:
					eligible_servers.append(s)

			if eligible_servers.is_empty():
				return   # No servers with 2+ ice — nothing to swap

			# Ask runner to choose a server and two ice positions (or decline)
			var swap_choice: Variant = null
			if ctx.runner_decision_maker.has_method("choose_ice_swap"):
				swap_choice = await ctx.runner_decision_maker.choose_ice_swap(eligible_servers, ctx)

			if swap_choice == null:
				return   # Runner declined

			# swap_choice is a Dictionary: {server: Server, pos_a: int, pos_b: int}
			var s: Server = (swap_choice as Dictionary).get("server", null) as Server
			var pos_a: int = (swap_choice as Dictionary).get("pos_a", 0)
			var pos_b: int = (swap_choice as Dictionary).get("pos_b", 1)

			if s == null or pos_a == pos_b:
				return
			if pos_a < 0 or pos_b < 0 or pos_a >= s.ice.size() or pos_b >= s.ice.size():
				return

			# Perform the swap
			var ice_a: InstalledCard = s.ice[pos_a] as InstalledCard
			var ice_b: InstalledCard = s.ice[pos_b] as InstalledCard
			s.ice[pos_a] = ice_b
			s.ice[pos_b] = ice_a
			ctx.log("Tāo: swaps %s (position %d) and %s (position %d) on %s." % [
				ice_a.display_name(), pos_a,
				ice_b.display_name(), pos_b,
				s.display_name()
			])
			# Anoetic Void: Corp may pay 2cr + trash 2 from HQ to end the breach.
			var breach_server: String = ctx.current_event_data.get("server_id", "")
			var av_iid: String        = ctx.current_event_data.get("card_instance_id", "")
			var av_card := ctx.get_installed_card_by_instance_id(av_iid)
			if av_card == null or av_card.server_id != breach_server or not av_card.is_rezzed:
				return
			var cost_cr: int    = int(params.get("cost_credits", 2))
			var cost_trash: int = int(params.get("cost_trash_hq", 2))
			if ctx.corp_credits < cost_cr or ctx.corp_hand.size() < cost_trash:
				return
			# Ask Corp decision maker
			var use_it := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_use_anoetic_void"):
				use_it = await ctx.corp_decision_maker.choose_use_anoetic_void(ctx)
			else:
				# AI default: use it when ahead on points or runner has few cards
				use_it = ctx.corp_credits >= cost_cr + 2
			if not use_it:
				return
			# Pay costs
			ctx.corp_credits -= cost_cr
			for i in range(cost_trash):
				if ctx.corp_hand.is_empty():
					break
				var discarded: Dictionary = ctx.corp_hand.pop_back() as Dictionary
				var record: CardRecord    = discarded.get("card_record", null) as CardRecord
				if record:
					ctx.corp_discard.append(record)
					ctx.corp_discard_facedown[record.title] = true
					ctx.log("Anoetic Void: Corp trashes %s from HQ." % record.title)
			# Cancel the breach
			ctx.run_modifiers["breach_cancelled"] = true
			ctx.log("Anoetic Void: %s pays %d cr and trashes %d — breach ended." % [ctx.corp_name(), cost_cr, cost_trash])

		# ── Pennyshaver / Red Team: counter effects gated on central server ───

		"add_self_counters_if_central":
			# Add counters to the owning card only if the run was on a central server.
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int          = int(effect.get("amount", params.get("amount", 1)))
			var server_id: String    = ctx.current_event_data.get("server_id", "")
			var server: Server       = ctx.get_server(server_id)
			if server != null and not server.is_remote():
				var iid: String = ctx.current_event_data.get("card_instance_id", "")
				var self_card   := ctx.get_installed_card_by_instance_id(iid)
				if self_card == null and iid != "":
					self_card = ctx.get_installed_card_by_id(iid)
				if self_card != null:
					self_card.add_counter(counter_type, amount)
					ctx.log("Placed %d %s counter(s) on %s (%s run)." % [
						amount, counter_type, self_card.display_name(), server_id
					])

		"take_hosted_credits_if_central":
			# Transfer hosted credits to runner's pool only on a central server run.
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int          = int(effect.get("amount", params.get("amount", 1)))
			var server_id: String    = ctx.current_event_data.get("server_id", "")
			var server: Server       = ctx.get_server(server_id)
			if server != null and not server.is_remote():
				var iid: String = ctx.current_event_data.get("card_instance_id", "")
				var self_card   := ctx.get_installed_card_by_instance_id(iid)
				if self_card == null and iid != "":
					self_card = ctx.get_installed_card_by_id(iid)
				if self_card != null:
					var available: int = self_card.get_counter(counter_type)
					var taken: int     = min(amount, available)
					if taken > 0:
						self_card.remove_counter(counter_type, taken)
						ctx.runner_credits += taken
						ctx.log("%s takes %d cr from %s (%d remaining)." % [ctx.runner_name(), 
							taken, self_card.display_name(), self_card.get_counter(counter_type)
						])
					else:
						ctx.log("%s has no hosted credits to take." % self_card.display_name())

		# ── Docklands Pass: bonus access gated on server ──────────────────────

		"add_bonus_access_if_server":
			# Add to run_modifiers["bonus_access"] if run is on the specified server.
			# Only fires the FIRST TIME per turn that server is breached (Docklands Pass rule).
			var required_server: String = params.get("server", "hq")
			var amount: int             = params.get("amount", 1)
			var actual_server: String   = ctx.current_event_data.get("server_id", "")
			if actual_server == required_server:
				# Use a per-turn flag on ctx so it persists across runs but resets each turn
				var already_fired: bool = false
				if required_server == "hq":
					already_fired = ctx.runner_hq_breached_this_turn
				if not already_fired:
					if required_server == "hq":
						ctx.runner_hq_breached_this_turn = true
					var current: int = ctx.run_modifiers.get("bonus_access", 0)
					ctx.run_modifiers["bonus_access"] = current + amount
					ctx.log("Docklands Pass: +%d access on %s." % [amount, required_server.to_upper()])

		# ── Mayfly: self-trash when run ends if the breaker was used ──────────

		"self_trash_if_used_this_run":
			# Trash the owning card at run end. Mayfly always trashes when the run
			# ends if it was used — unconditional per card text.
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card   := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null and iid != "":
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card != null:
				ctx.runner_rig.erase(self_card)
				ctx.unregister_all_card_effects(iid)
				ctx.log("%s is trashed (end of run)." % self_card.display_name())

		"self_trash":
			# Unconditionally trash the owning card (Tranquilizer after derez, etc.)
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card   := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null and iid != "":
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card != null:
				# Remove from host ice if hosted
				if self_card.hosted_on_id != "":
					var host_ice := ctx.get_ice_by_instance_id(self_card.hosted_on_id)
					if host_ice != null:
						host_ice.hosted_cards.erase(self_card)
				else:
					ctx.runner_rig.erase(self_card)
				ctx.unregister_all_card_effects(iid)
				ctx.log("%s is trashed." % self_card.display_name())

		_:
			push_error("AbilityInterpreter: unknown effect type '%s'" % etype)


# ── Effect helpers ────────────────────────────────────────────────────────────

func _resolve_amount(amount_def: Variant, ctx: GameContext) -> int:
	if amount_def is int:
		return amount_def
	if amount_def is float:
		return int(amount_def)

	# Structured amount: {"base": 2, "plus_counters": "advancement"}
	if amount_def is Dictionary:
		var base: int        = int((amount_def as Dictionary).get("base", 0))
		var plus_counters    = (amount_def as Dictionary).get("plus_counters", "")
		if plus_counters != "":
			base += ctx.get_counters_on_accessed_card(plus_counters as String)
		return base

	push_error("AbilityInterpreter: unrecognised amount definition: %s" % str(amount_def))
	return 0


func _deal_damage(damage_type: String, amount: int, ctx: GameContext) -> Array:
	ctx.log("Runner takes %d %s damage." % [amount, damage_type])
	var trashed: int = 0
	var trashed_cards: Array = []
	for i in range(amount):
		if ctx.runner_hand.is_empty():
			ctx.log("%s is flatlined! (no cards remaining in grip)" % ctx.runner_name())
			ctx.game_over = true
			ctx.winner    = "corp"
			break
		var idx: int = randi() % ctx.runner_hand.size()
		var entry: Dictionary = ctx.runner_hand[idx] as Dictionary
		ctx.runner_hand.remove_at(idx)
		var record: CardRecord = entry.get("card_record", null) as CardRecord
		if record != null:
			trashed_cards.append(record)
			ctx.runner_discard.append(record)
		trashed += 1
		ctx.log("  Trashed from grip: %s" % entry.get("card_id", "unknown"))
	ctx.log("%d card(s) trashed from %s's grip." % [trashed, ctx.runner_name()])
	return trashed_cards


func _trash_installed_card(card: InstalledCard, ctx: GameContext) -> void:
	# If this is ice with hosted programs, trash those first
	if card.zone == "ice" and not card.hosted_cards.is_empty():
		for hosted in card.hosted_cards.duplicate():
			var h: InstalledCard = hosted as InstalledCard
			ctx.runner_rig.erase(h)
			ctx.unregister_all_card_effects(h.runtime_instance_id)
			ctx.log("  %s trashed (host ice removed)." % h.display_name())
		card.hosted_cards.clear()

	# Remove from runner rig or from host ice
	if card.hosted_on_id != "":
		var host_ice := ctx.get_ice_by_instance_id(card.hosted_on_id)
		if host_ice != null:
			host_ice.hosted_cards.erase(card)
	else:
		ctx.runner_rig.erase(card)

	ctx.unregister_all_card_effects(card.runtime_instance_id)
	ctx.log("Trashed installed card: %s" % card.display_name())

func _draw_cards(subject: String, amount: int, ctx: GameContext) -> void:
	var deck: Array
	var hand: Array
	if subject == "corp":
		deck = ctx.corp_deck
		hand = ctx.corp_hand
	else:
		deck = ctx.runner_deck
		hand = ctx.runner_hand
	var drawn := 0
	for i in range(amount):
		if deck.is_empty():
			ctx.log("%s deck empty — cannot draw." % ctx.player_name(subject))
			break
		var card: CardRecord = deck.pop_front() as CardRecord
		hand.append({"card_id": card.id, "card_record": card})
		drawn += 1
	ctx.log("%s draws %d card(s)." % [ctx.player_name(subject), drawn])


# ── Encounter action processing ───────────────────────────────────────────────
# Called by RunStateMachine during Encounter Ice.
# Processes a single encounter action and mutates EncounterState and GameContext.
# Returns true if the action was valid and executed, false if invalid.

func process_encounter_action(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var action_type: String = action.get("type", "")

	match action_type:
		"boost_strength":
			return _do_boost(action, encounter, ctx, ability_registry)
		"break_subroutine":
			return _do_break_sub(action, encounter, ctx, ability_registry)
		"break_all":
			return _do_break_all(action, encounter, ctx, ability_registry)
		"spend_hosted_credits":
			return _do_spend_hosted_credits(action, encounter, ctx)
		"break_with_click":
			return _do_break_with_click(action, encounter, ctx)
		"done":
			return true
		_:
			push_error("AbilityInterpreter: unknown encounter action '%s'" % action_type)
			return false


func _do_boost(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var breaker := _find_breaker(action.get("card_id", ""), encounter)
	if breaker == null:
		return false

	var boost_def: Variant = ability_registry.get_boost(breaker.card_id)
	if boost_def == null:
		push_error("AbilityInterpreter: %s has no boost ability" % breaker.card_id)
		return false

	var boost_dict: Dictionary = boost_def as Dictionary
	var cost: int              = boost_dict.get("cost", 0)
	var times: int             = action.get("times", 1)
	var total_cost: int        = cost * times

	if ctx.runner_available_credits() < total_cost:
		ctx.log("[Encounter] Cannot afford boost (need %d, have %d)." % [total_cost, ctx.runner_available_credits()])
		return false

	# Calculate strength gained per use
	# Unity: 1cr → strength equal to number of installed icebreakers (including itself)
	var str_per_use: int = boost_dict.get("strength_gained", 1)
	if boost_dict.get("strength_gained_modifier", "") == "installed_icebreaker_count":
		str_per_use = ctx.count_installed_icebreakers()

	ctx.runner_spend_credits(total_cost)
	var total_boost: int = str_per_use * times
	encounter.apply_boost(breaker, total_boost)

	if boost_dict.get("strength_gained_modifier", "") == "installed_icebreaker_count":
		ctx.log("[Encounter] %s boosted +%d str (%d icebreakers). Cost: %d cr." % [
			breaker.display_name(), total_boost, str_per_use,
			total_cost
		])
	else:
		ctx.log("[Encounter] %s boosted %s +%d str (now %d). Cost: %d cr." % [
			breaker.display_name(), "×%d" % times if times > 1 else "",
			total_boost, encounter.get_breaker_strength(breaker), total_cost
		])
	return true


func _do_break_sub(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var breaker := _find_breaker(action.get("card_id", ""), encounter)
	if breaker == null:
		return false

	var sub_index: int = action.get("sub_index", -1)
	if sub_index < 0 or sub_index >= encounter.subroutines.size():
		push_error("AbilityInterpreter: invalid sub_index %d" % sub_index)
		return false

	if encounter.is_broken(sub_index):
		ctx.log("[Encounter] Subroutine %d already broken." % sub_index)
		return true  # not an error, just redundant

	var break_def: Variant = ability_registry.get_break(breaker.card_id)
	if break_def == null:
		push_error("AbilityInterpreter: %s has no break ability" % breaker.card_id)
		return false

	var break_dict: Dictionary = break_def as Dictionary

	# host_only: Botulus can only break subs on its host ice
	if break_dict.get("host_only", false):
		if breaker.hosted_on_id == "" or breaker.hosted_on_id != encounter.ice_card.runtime_instance_id:
			ctx.log("[Encounter] %s can only break subroutines on %s." % [
				breaker.display_name(),
				ctx.get_ice_by_instance_id(breaker.hosted_on_id).display_name() if breaker.hosted_on_id != "" else "its host ice"
			])
			return false

	# Strength check (Botulus has no base strength — host_only bypasses this)
	if not break_dict.get("host_only", false) and not encounter.breaker_reaches(breaker):
		ctx.log("[Encounter] %s (str %d) cannot reach %s (str %d)." % [
			breaker.display_name(),
			encounter.get_breaker_strength(breaker),
			encounter.ice_card.display_name(),
			encounter.ice_strength
		])
		return false

	var cost: int = break_dict.get("cost_per_sub", 1)
	var virus_cost: int = break_dict.get("cost_virus_counter", 0)

	if virus_cost > 0:
		# Botulus spends virus counters
		var available_virus: int = breaker.get_counter("virus")
		if available_virus < virus_cost:
			ctx.log("[Encounter] %s has no virus counters to spend." % breaker.display_name())
			return false
		breaker.remove_counter("virus", virus_cost)
	elif ctx.runner_available_credits() < cost:
		ctx.log("[Encounter] Cannot afford to break (need %d, have %d)." % [cost, ctx.runner_available_credits()])
		return false
	else:
		ctx.runner_spend_credits(cost)
	encounter.break_subroutine(sub_index)
	var sub_label: String = (encounter.subroutines[sub_index] as Dictionary).get("label", "subroutine %d" % sub_index)
	if virus_cost > 0:
		ctx.log("[Encounter] %s breaks \'%s\' (1 virus, %d remaining)." % [
			breaker.display_name(), sub_label, breaker.get_counter("virus")])
	else:
		ctx.log("[Encounter] %s breaks \'%s\' for %d cr." % [breaker.display_name(), sub_label, cost])
	return true


func _do_break_all(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var breaker := _find_breaker(action.get("card_id", ""), encounter)
	if breaker == null:
		return false

	var break_def: Variant = ability_registry.get_break(breaker.card_id)
	if break_def == null:
		return false

	if not encounter.breaker_reaches(breaker):
		ctx.log("[Encounter] %s cannot reach %s — boost first." % [
			breaker.display_name(), encounter.ice_card.display_name()
		])
		return false

	var cost_per_sub: int = (break_def as Dictionary).get("cost_per_sub", 1)
	var unbroken       := encounter.unbroken_indices()
	var total_cost     := cost_per_sub * unbroken.size()

	if ctx.runner_available_credits() < total_cost:
		# Break as many as we can afford
		var can_break: int = ctx.runner_available_credits() / cost_per_sub
		for i in range(can_break):
			ctx.runner_spend_credits(cost_per_sub)
			encounter.break_subroutine(unbroken[i])
			var sub_label: String = (encounter.subroutines[unbroken[i]] as Dictionary).get("label", "sub %d" % unbroken[i])
			ctx.log("[Encounter] %s breaks \'%s\'." % [breaker.display_name(), sub_label])
		ctx.log("[Encounter] Out of credits — %d subs remain unbroken." % (unbroken.size() - can_break))
	else:
		for idx in unbroken:
			ctx.runner_spend_credits(cost_per_sub)
			encounter.break_subroutine(idx)
			var sub_label: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
			ctx.log("[Encounter] %s breaks \'%s\'." % [breaker.display_name(), sub_label])
	return true


func _do_break_with_click(action: Dictionary, encounter: EncounterState, ctx: GameContext) -> bool:
	# Runner spends 1 click to break 1 subroutine on a bioroid.
	# No strength check required — this is the ice's own ability, not an icebreaker.
	if ctx.runner_clicks < 1:
		ctx.log("[Encounter] Runner has no clicks to spend.")
		return false
	var sub_index: int = action.get("sub_index", -1)
	if sub_index < 0 or sub_index >= encounter.subroutines.size():
		push_error("AbilityInterpreter: break_with_click — invalid sub_index %d" % sub_index)
		return false
	if encounter.is_broken(sub_index):
		ctx.log("[Encounter] Subroutine %d already broken." % sub_index)
		return true
	ctx.runner_clicks -= 1
	encounter.break_subroutine(sub_index)
	var sub_label: String = (encounter.subroutines[sub_index] as Dictionary).get("label", "sub %d" % sub_index)
	ctx.log("[Encounter] Runner spends 1 click to break '%s'. (%d clicks remaining)" % [
		sub_label, ctx.runner_clicks
	])
	return true


func _do_spend_hosted_credits(action: Dictionary, encounter: EncounterState, ctx: GameContext) -> bool:
	# Transfer hosted credits from a card (e.g. Leech) to the runner's pool.
	var card_id: String  = action.get("card_id", "")
	var amount: int      = action.get("amount", 1)
	# Find the card in the runner rig
	var source: InstalledCard = null
	for c in ctx.runner_rig:
		var ic: InstalledCard = c as InstalledCard
		if ic.card_id == card_id:
			source = ic
			break
	if source == null:
		push_error("AbilityInterpreter: spend_hosted_credits — card '%s' not found" % card_id)
		return false
	var available: int = source.get_counter("credits")
	var taken: int     = min(amount, available)
	if taken <= 0:
		ctx.log("[Encounter] %s has no hosted credits to spend." % source.display_name())
		return false
	source.remove_counter("credits", taken)
	ctx.runner_credits += taken
	ctx.log("[Encounter] %s takes %d cr from %s (%d remaining)." % [
		ctx.runner_name(), taken, source.display_name(), source.get_counter("credits")
	])
	return true


func _find_breaker(card_id: String, encounter: EncounterState) -> InstalledCard:
	for b in encounter.available_breakers:
		var breaker: InstalledCard = b as InstalledCard
		if breaker.card_id == card_id:
			return breaker
	push_error("AbilityInterpreter: breaker '%s' not found in encounter" % card_id)
	return null


# ── Modal ability execution ───────────────────────────────────────────────────
# Handles cards like Predictive Planogram where the player chooses between
# multiple effects. Supports a bonus_condition that auto-executes remaining
# modes when a condition is met (e.g. "if runner is tagged, do both").

func execute_modal_trigger(trigger_def: Dictionary, ctx: GameContext) -> void:
	var modes: Array      = trigger_def.get("modes", []) as Array
	var max_choices: int  = trigger_def.get("max_choices", 1)

	if modes.is_empty():
		return

	# Check bonus condition — may increase max_choices
	var bonus_def: Variant = trigger_def.get("bonus_condition", null)
	var bonus_active := false
	if bonus_def != null:
		bonus_active = _evaluate_condition(bonus_def as Dictionary, ctx)
		if bonus_active:
			ctx.log("Bonus condition met — all modes will execute.")
			max_choices = modes.size()

	# Ask decision maker to choose.
	# "chooser" overrides the active player — used by Wildcat Strike where Corp
	# chooses even though the Runner is the active player.
	var chooser: String = trigger_def.get("chooser", ctx.active_player)
	var chosen_indices: Array = []
	var decision_maker: Object = ctx.corp_decision_maker if chooser == "corp" else ctx.runner_decision_maker
	if chooser == "corp":
		ctx.log("Corp chooses the effect of this card...")
	if decision_maker != null and decision_maker.has_method("choose_modes"):
		chosen_indices = await decision_maker.choose_modes(modes, max_choices, ctx)
	else:
		chosen_indices = [0]

	# If bonus is active, also execute any unchosen modes
	var all_indices: Array = []
	for i in chosen_indices:
		if not all_indices.has(i):
			all_indices.append(i)
	if bonus_active:
		for i in range(modes.size()):
			if not all_indices.has(i):
				all_indices.append(i)

	# Execute chosen modes in order
	for idx in all_indices:
		if idx < 0 or idx >= modes.size():
			continue
		var mode: Dictionary = modes[idx] as Dictionary
		ctx.log("Modal: executing '%s'." % mode.get("label", "mode %d" % idx))
		var effects: Array = mode.get("effects", []) as Array
		for effect in effects:
			await _execute_effect(effect as Dictionary, ctx, null)

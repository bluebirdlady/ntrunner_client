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
			ctx.send_log("Condition not met — ability has no effect.")
			return

	# Resolve targeting if required
	var chosen_target: Variant = null
	if trigger_def.has("target"):
		chosen_target = await _resolve_target(trigger_def["target"] as Dictionary, ctx)
		if chosen_target == null:
			ctx.send_log("No valid targets — ability has no effect.")
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
			ctx.send_log("Subroutine condition not met — no effect.")
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

		"runner_made_successful_run":
			return ctx.runner_made_successful_run_this_turn

		"runner_made_successful_run_last_turn":
			# Public Trail: "Play only if the Runner made a successful run during their last turn."
			return ctx.runner_made_successful_run_last_turn

		"corp_discarded_last_turn":
			return ctx.corp_discarded_to_hand_limit_last_turn

		"corp_scored_agenda_this_turn":
			return ctx.corp_last_scored_agenda_points > 0

		"first_agenda_scored_this_turn":
			# True only while the very first agenda of this Corp turn is being scored.
			return ctx.corp_agendas_scored_this_turn == 1

		"threat_gte":
			# True when the current threat level (runner's agenda points) is at or above
			# the specified threshold.  Used by all "threat X" card abilities.
			# params: { "value": int }  (or top-level "value" for shorthand)
			var tg_threshold: int = condition.get("value", params.get("value", 0))
			return ctx.threat_level() >= tg_threshold

		"tags_compare":
			# Evaluate the runner's tag count against a threshold.
			# params: { "operator": "gte"|"lte"|"gt"|"lt"|"eq", "value": int }
			var operator: String = params.get("operator", "gte")
			var value: int       = params.get("value", 0)
			var tags: int        = ctx.runner_tags
			match operator:
				"lt":  return tags <  value
				"lte": return tags <= value
				"gt":  return tags >  value
				"gte": return tags >= value
				"eq":  return tags == value
				"neq": return tags != value
			push_error("AbilityInterpreter: unknown operator '%s' in tags_compare" % operator)
			return false

		"self_counter_gte":
			# True if the owning card has >= threshold of a given counter type.
			# Used by Syailendra: fire bonus ability when 3+ advancement counters.
			var sc_counter: String = condition.get("counter", "advancement")
			var sc_threshold: int  = condition.get("threshold", 0)
			var sc_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var sc_card := ctx.get_installed_card_by_instance_id(sc_iid)
			if sc_card == null:
				return false
			return sc_card.get_counter(sc_counter) >= sc_threshold

		"agenda_on_my_server":
			# True when the scored/stolen agenda's server matches the listening card's server.
			# Used by Lamplighter: self-trash whenever an agenda leaves its protecting server.
			var ams_iid: String        = ctx.current_event_data.get("card_instance_id", "")
			var ams_event_server: String = ctx.current_event_data.get("server_id", "")
			if ams_iid == "" or ams_event_server == "":
				return false
			var ams_card := ctx.get_installed_card_by_instance_id(ams_iid)
			if ams_card == null:
				return false
			return ams_card.server_id == ams_event_server

		"self_is_rezzed":
			# True when the owning card (card_instance_id) is currently rezzed.
			# Used by Public Access Plaza threat variant: tag only fires if the asset is rezzed.
			var sir_iid: String = ctx.current_event_data.get("card_instance_id", "")
			if sir_iid == "":
				return false
			var sir_card := ctx.get_installed_card_by_instance_id(sir_iid)
			if sir_card == null:
				return false
			return sir_card.is_rezzed

		"ice_on_my_server":
			# True when the approached/encountered ice is protecting the same server as the
			# listening card, AND the listening card is rezzed.
			# Used by Mitra Aman: fire only when ice on its own server is approached.
			var ims_iid: String       = ctx.current_event_data.get("card_instance_id", "")
			var ims_ice: InstalledCard = ctx.current_event_data.get("ice", null) as InstalledCard
			if ims_iid == "" or ims_ice == null:
				return false
			var ims_card := ctx.get_installed_card_by_instance_id(ims_iid)
			if ims_card == null or not ims_card.is_rezzed:
				return false
			return ims_card.server_id == ims_ice.server_id

		"run_active":
			# True when a run is currently in progress.
			# Used by Bumi 1.0: rez trigger only fires when rezzed during a run.
			return ctx.run_active

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
			ctx.send_log("%s gains %d credits." % [ctx.player_name(subject), amount])

		"lose_credits":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 0)
			var current: int    = ctx.get_credits(subject)
			var lost: int       = min(amount, current)  # can't go below 0
			ctx.set_credits(subject, current - lost)
			ctx.send_log("%s loses %d credits." % [ctx.player_name(subject), lost])

		"corp_loses_runner_gains_double":
			# Transfer of Wealth: Corp loses up to N credits; Runner gains 2× the amount lost.
			var tow_amount: int  = params.get("amount", 3)
			var tow_lost: int    = min(tow_amount, ctx.corp_credits)
			ctx.corp_credits    -= tow_lost
			var tow_gained: int  = tow_lost * 2
			ctx.runner_credits  += tow_gained
			ctx.send_log("Transfer of Wealth: %s loses %d cr; %s gains %d cr." % [
				ctx.corp_name(), tow_lost, ctx.runner_name(), tow_gained
			])

		"end_run":
			ctx.run_ended = true
			ctx.send_log("Run ended.")

		"end_run_if_tagged":
			# Subroutine: end the run only if the Runner currently has at least one tag.
			# Used by Lamplighter.
			if ctx.runner_is_tagged():
				ctx.run_ended = true
				ctx.send_log("End the run (Runner is tagged).")
			else:
				ctx.send_log("Runner has no tags — end-the-run sub is blank.")

		"end_run_if_threat_gte":
			# Subroutine: end the run only if the current threat level (runner's agenda
			# points) meets the threshold.  Used by N-Pot subs 2 and 3.
			# params: { "value": int }
			var eritg_threshold: int = params.get("value", 0)
			if ctx.threat_level() >= eritg_threshold:
				ctx.run_ended = true
				ctx.send_log("End the run (threat level %d >= %d)." % [ctx.threat_level(), eritg_threshold])
			else:
				ctx.send_log("Threat level %d < %d — sub is blank." % [ctx.threat_level(), eritg_threshold])

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
						ctx.send_log("Diviner: %s has odd cost (%d) — run ends." % [first.title, printed_cost])
						ctx.run_ended = true
					else:
						ctx.send_log("Diviner: %s has even cost (%d) — run continues." % [first.title, printed_cost])

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
					ctx.send_log("%s jacks out after Karunā damage." % ctx.runner_name())
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
				ctx.send_log("%s cannot afford any payment option — run ends." % ctx.runner_name())
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
				ctx.send_log("%s ends the run (Manegarm Skunkworks)." % ctx.runner_name())
				ctx.run_ended = true
				return

			# Apply chosen payment
			var c: Dictionary = chosen as Dictionary
			match c.get("type", ""):
				"clicks":
					var amount: int = c.get("amount", 0)
					ctx.runner_clicks -= amount
					ctx.send_log("%s spends %d click(s) for Manegarm Skunkworks." % [ctx.runner_name(), amount])
				"credits":
					var amount: int = c.get("amount", 0)
					ctx.runner_credits -= amount
					ctx.send_log("%s pays %d cr for Manegarm Skunkworks." % [ctx.runner_name(), amount])

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
				ctx.send_log("%s has no ice in HQ%s to install." % [ctx.corp_name(), " or Archives" if also_archives else ""])
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
						# Use run server if active; create a new remote as fallback (e.g. KPI played as operation)
						var server: Server = ctx.get_server(ctx.run_target_server)
						if server == null:
							server = ctx.create_remote_server()
						if server != null:
							var installed := InstalledCard.make_runtime_instance(record, server.server_id, "ice", false)
							server.install_ice(installed)
							ctx.send_log("%s installs %s from %s on %s (ignoring costs)." % [ctx.corp_name(),
								record.title,
								"Archives" if (chosen_entry as Dictionary).get("_from_archives", false) else "HQ",
								server.display_name()
							])

		"trash_runner_installed":
			# Trash one of the runner\'s installed cards matching given types.
			# Also scans programs hosted on ice (trojans like Chromatophores, Botulus).
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
			# Also include programs hosted on ice (e.g. Chromatophores as a trojan on ice)
			for tri_server in ctx.servers.values():
				for tri_ice in (tri_server as Server).ice:
					for tri_hosted in (tri_ice as InstalledCard).hosted_cards:
						var tri_h: InstalledCard = tri_hosted as InstalledCard
						if tri_h == null or tri_h.card_record == null:
							continue
						var tri_type_match := card_types.is_empty() or card_types.has(tri_h.card_record.card_type)
						var tri_sub_match  := subtypes.is_empty()
						if not tri_sub_match:
							for st in subtypes:
								if tri_h.card_record.has_subtype(st):
									tri_sub_match = true
									break
						if tri_type_match and tri_sub_match and not pool.has(tri_h):
							pool.append(tri_h)
			if pool.is_empty():
				ctx.send_log("No valid %s cards to trash." % ctx.runner_name())
			else:
				var dm: Object = ctx.corp_decision_maker
				var target: InstalledCard = null
				if dm != null and dm.has_method("choose_target"):
					target = await dm.choose_target(pool, {"reason": "trash_runner_installed"})
				else:
					target = pool[0] as InstalledCard
				if target != null:
					if target.hosted_on_id != "":
						# Hosted trojan — remove from host ice and clean up granted subtypes
						_cleanup_granted_subtypes(target, ctx)
						var tri_host := ctx.get_ice_by_instance_id(target.hosted_on_id)
						if tri_host != null:
							tri_host.hosted_cards.erase(target)
					else:
						ctx.runner_rig.erase(target)
					if target.card_record != null:
						ctx.runner_discard.append(target.card_record)
					ctx.unregister_all_card_effects(target.runtime_instance_id)
					ctx.send_log("%s trashes %s's %s." % [ctx.corp_name(), ctx.runner_name(), target.display_name()])

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
				ctx.send_log("No matching cards found in deck.")
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
						ctx.send_log("%s reveals and takes %s from their deck." % [ctx.player_name(subject), chosen.title])
					else:
						ctx.send_log("%s takes a card from their deck." % ctx.player_name(subject))
					# Shuffle the deck after searching
					deck.shuffle()
					ctx.send_log("%s's deck is shuffled." % ctx.player_name(subject))

		"choose_and_return_to_deck":
			# Ask the active player to choose a card from their hand to shuffle back.
			var subject: String = params.get("subject", "corp")
			var hand: Array = ctx.corp_hand if subject == "corp" else ctx.runner_hand
			var deck: Array = ctx.corp_deck if subject == "corp" else ctx.runner_deck
			if hand.is_empty():
				ctx.send_log("No cards in hand to return to deck.")
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
					ctx.send_log("%s shuffles %s back into their deck." % [
						ctx.player_name(subject),
						r.title if r else "a card"
					])

		"set_run_modifier":
			# Set a key in ctx.run_modifiers for the duration of the current run.
			var key: String = params.get("key", "")
			var value: int  = int(params.get("value", 0))
			if key != "":
				ctx.run_modifiers[key] = value
				ctx.send_log("Run modifier set: %s = %d" % [key, value])

		"initiate_run":
			# Start a run as part of playing an event.
			var server_id: String = params.get("server_id", "")
			if server_id == "" and ctx.has_meta("chosen_run_server"):
				server_id = ctx.get_meta("chosen_run_server")
			if server_id == "" or not ctx.servers.has(server_id):
				push_error("AbilityInterpreter: initiate_run has no valid server")
				return
			# Mark that a run event is active (used by Sang Kancil cost reduction, etc.)
			ctx.run_modifiers["run_event_active"] = 1
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
			# Expand "remote" placeholder to actual live remote server IDs.
			# abilities.json uses "remote" as shorthand; ctx only knows "remote_0" etc.
			var expanded: Array = []
			for srv_entry in allowed:
				if srv_entry == "remote":
					for remote_srv in ctx.get_remote_servers():
						expanded.append((remote_srv as Server).server_id)
				else:
					expanded.append(srv_entry)
			if not expanded.is_empty():
				allowed = expanded
			if allowed.is_empty():
				push_error("AbilityInterpreter: choose_and_run — no valid servers available")
				return
			var chosen: String = allowed[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				chosen = await ctx.runner_decision_maker.choose_server(allowed, ctx)
			ctx.set_meta("chosen_run_server", chosen)
			# Mark that a run event is active (used by Sang Kancil cost reduction, etc.)
			ctx.run_modifiers["run_event_active"] = 1
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
				ctx.send_log("Red Team: no credits remaining — cannot use.")
				return

			var all_centrals: Array = ["hq", "rd", "archives"]
			var eligible: Array = []
			for srv in all_centrals:
				if srv not in ctx.runner_centrals_run_this_turn:
					eligible.append(srv)

			if eligible.is_empty():
				ctx.send_log("Red Team: all central servers already run this turn.")
				return

			# Ask runner to choose which central to run
			var chosen: String = eligible[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				chosen = await ctx.runner_decision_maker.choose_server(eligible, ctx)

			ctx.send_log("Red Team: %s runs %s." % [ctx.runner_name(), chosen.to_upper()])

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
				ctx.send_log("No unrezzed %s to rez for free." % target_zone)
			else:
				var dm: Object = ctx.corp_decision_maker if ctx.active_player == "corp" else ctx.runner_decision_maker
				var target: InstalledCard = null
				if dm != null and dm.has_method("choose_target"):
					target = await dm.choose_target(candidates, {"reason": "rez_free"})
				else:
					target = candidates[0]
				if target != null:
					target.is_rezzed = true
					ctx.send_log("Rezzed %s for free." % target.display_name())

		"increase_hand_size":
			var subject: String = params.get("subject", "corp")
			var amount: int     = params.get("amount", 1)
			if subject == "corp":
				ctx.corp_hand_size_bonus += amount
				ctx.send_log("%s max hand size increased to %d." % [ctx.corp_name(), ctx.corp_max_hand_size()])
			else:
				ctx.runner_hand_size_bonus += amount
				ctx.send_log("%s max hand size increased to %d." % [ctx.runner_name(), ctx.runner_max_hand_size()])

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
					ctx.send_log("Placed %d %s counter(s) on %s (%d total)." % [
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
					ctx.send_log("%s: +%d R&D access from virus counters." % [self_card.display_name(), count])

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
					ctx.send_log("%s takes %d cr from %s (%d remaining)." % [ctx.runner_name(), 
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
				ctx.send_log("Placed %d %s counter(s) on %s." % [amount, counter_type, self_card.display_name()])
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
					ctx.send_log("%s takes %d cr from %s (%d remaining)." % [
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
					ctx.send_log("%s is empty." % self_card.display_name())
				else:
					var taken: int = min(amount, available)
					self_card.remove_counter(counter_type, taken)
					ctx.set_credits(subject, ctx.get_credits(subject) + taken)
					ctx.send_log("%s takes %d cr from %s (%d remaining)." % [
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
					ctx.send_log("%s has no credits to take." % self_card.display_name())
				else:
					self_card.remove_counter(counter_type, available)
					ctx.set_credits(subject, ctx.get_credits(subject) + available)
					ctx.send_log("%s takes all %d cr from %s." % [
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
			# Optional: on_trash_gain_clicks — { subject: "corp"|"runner", amount: int }
			# grants clicks to the specified player when the card self-trashes (e.g. Otto Campaign).
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
				ctx.send_log("%s is trashed (empty)." % self_card.display_name())
				# Grant bonus clicks on self-trash (e.g. Otto Campaign: Corp gains 2 clicks)
				var otgc = effect.get("on_trash_gain_clicks", null)
				if otgc != null:
					var otgc_subject: String = (otgc as Dictionary).get("subject", "corp")
					var otgc_amount: int     = (otgc as Dictionary).get("amount", 0)
					if otgc_subject == "corp":
						ctx.corp_clicks += otgc_amount
						ctx.send_log("%s gains %d click(s) (%s trashed)." % [ctx.corp_name(), otgc_amount, self_card.display_name()])
					else:
						ctx.runner_clicks += otgc_amount
						ctx.send_log("%s gains %d click(s) (%s trashed)." % [ctx.runner_name(), otgc_amount, self_card.display_name()])

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
				ctx.send_log("%s is trashed (empty)." % self_card.display_name())
				# Draw 1 card for the Corp
				if not ctx.corp_deck.is_empty():
					var drawn: CardRecord = ctx.corp_deck.pop_front() as CardRecord
					ctx.corp_hand.append({"card_id": drawn.id, "card_record": drawn})
					ctx.send_log("%s draws %s (Nico Campaign)." % [ctx.corp_name(), drawn.title])
				else:
					ctx.send_log("%s deck is empty — cannot draw from Nico Campaign." % ctx.corp_name())

		"lose_clicks_next_turn":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 1)
			var current: int    = ctx.pending_click_penalties.get(subject, 0)
			ctx.pending_click_penalties[subject] = current + amount
			ctx.send_log("%s will lose %d click(s) next turn." % [ctx.player_name(subject), amount])

		"add_counters_to_target":
			var counter_type: String = params.get("counter_type", "advancement")
			var amount: int          = params.get("amount", 1)
			if chosen_target != null and chosen_target is InstalledCard:
				(chosen_target as InstalledCard).add_counter(counter_type, amount)
				ctx.send_log("Placed %d %s counter(s) on %s." % [
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
				ctx.send_log("Pantograph: no cards in grip to install.")
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
				ctx.send_log("Pantograph: runner declines to install.")
				return
			var cost: int = max(0, chosen.cost)
			if ctx.runner_credits < cost:
				ctx.send_log("Pantograph: cannot afford to install %s." % chosen.title)
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
			ctx.send_log("Pantograph: %s installs %s for %d cr." % [ctx.runner_name(), chosen.title, cost])

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
				ctx.send_log("Pantograph: no installable cards in grip.")
				return

			var chosen_entry: Variant = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_hand"):
				chosen_entry = await ctx.runner_decision_maker.choose_card_from_hand(installable, ctx)

			if chosen_entry == null:
				ctx.send_log("Pantograph: no card chosen.")
				return

			var record: CardRecord = (chosen_entry as Dictionary).get("card_record", null) as CardRecord
			if record == null:
				return

			# MU check for programs
			if record.card_type == "program" and record.memory_cost > 0:
				if ctx.runner_mu_available() < record.memory_cost:
					ctx.send_log("Pantograph: not enough MU to install %s." % record.title)
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

			ctx.send_log("Pantograph: %s installs %s for free. [MU: %d/%d]" % [
				ctx.runner_name(), record.title,
				ctx.runner_mu_used(), ctx.runner_total_mu()
			])

		"give_tags":
			# Give the runner N tags, then fire runner_takes_tags so identity abilities
			# like NBN: Reality Plus can react.
			var amount: int = _resolve_amount(params.get("amount", 1), ctx)
			if amount <= 0:
				return
			ctx.runner_tags += amount
			ctx.send_log("%s takes %d tag(s). (%d total)" % [ctx.runner_name(), amount, ctx.runner_tags])
			await ctx.notify_event("runner_takes_tags", {"amount": amount}, self)

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
				ctx.send_log("Clearinghouse: Corp holds. (%d counters, would deal %d meat)" % [
					current_counters, damage_if_activate
				])
				return

			# Activate: add 1 counter first
			self_card.add_counter("advancement", 1)
			var total_damage: int = self_card.get_counter("advancement")
			ctx.send_log("Clearinghouse fires! Deals %d meat damage." % total_damage)

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
			ctx.send_log("Clearinghouse is trashed.")
			# Tranquilizer: derez the ice this program is hosted on.
			# Fires at the start of the Corp's turn while installed.
			if self_card == null:
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card != null and self_card.hosted_on_id != "":
				var host_ice := ctx.get_ice_by_instance_id(self_card.hosted_on_id)
				if host_ice != null and host_ice.is_rezzed:
					host_ice.is_rezzed = false
					ctx.send_log("Tranquilizer: %s is derezzed." % host_ice.display_name())
					await ctx.notify_event("on_derez", {
						"card": host_ice,
						"card_instance_id": self_card.runtime_instance_id
					}, self)
				elif host_ice != null:
					ctx.send_log("Tranquilizer: %s is already unrezzed." % host_ice.display_name())

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
				ctx.send_log("Fermenter: %s gains %d cr (%d counters × %d cr)." % [
					ctx.runner_name(), gained, count, credits_per
				])
			else:
				push_error("AbilityInterpreter: gain_credits_per_counter — card not found")

		"deal_damage_per_self_counter":
			# Deal N damage where N = this card's own counter of the specified type.
			# Used by Phat Gioan Baotixita: first-agenda trigger deals net damage
			# equal to accumulated power counters.
			var ddpc_counter: String = params.get("counter", "power")
			var ddpc_dtype:   String = params.get("damage_type", "net")
			var ddpc_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var ddpc_card := ctx.get_installed_card_by_instance_id(ddpc_iid)
			if ddpc_card == null:
				push_error("AbilityInterpreter: deal_damage_per_self_counter — card not found")
				return
			var ddpc_count: int = ddpc_card.get_counter(ddpc_counter)
			if ddpc_count <= 0:
				ctx.send_log("%s: no %s counters — no damage dealt." % [
					ddpc_card.display_name(), ddpc_counter
				])
				return
			ctx.send_log("%s: %d %s counter(s) — deals %d %s damage." % [
				ddpc_card.display_name(), ddpc_count, ddpc_counter, ddpc_count, ddpc_dtype
			])
			_deal_damage(ddpc_dtype, ddpc_count, ctx)

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
				ctx.send_log("Cookbook: placed %d %s counter(s) on %s." % [
					amount, counter_type, new_card.display_name()
				])

		"gain_credits_first_trash_this_turn":
			# Loup: the first time each turn you trash during a breach, gain 2cr.
			if ctx.runner_trashed_during_breach_this_turn:
				return   # already fired this turn
			ctx.runner_trashed_during_breach_this_turn = true
			var amount: int = int(params.get("amount", 2))
			ctx.runner_credits += amount
			ctx.send_log("Loup: %s gains %d cr (first trash this turn)." % [ctx.runner_name(), amount])

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
			ctx.send_log("Tāo: swaps %s (position %d) and %s (position %d) on %s." % [
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
					ctx.send_log("Anoetic Void: Corp trashes %s from HQ." % record.title)
			# Cancel the breach
			ctx.run_modifiers["breach_cancelled"] = true
			ctx.send_log("Anoetic Void: %s pays %d cr and trashes %d — breach ended." % [ctx.corp_name(), cost_cr, cost_trash])

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
					ctx.send_log("Placed %d %s counter(s) on %s (%s run)." % [
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
						ctx.send_log("%s takes %d cr from %s (%d remaining)." % [ctx.runner_name(), 
							taken, self_card.display_name(), self_card.get_counter(counter_type)
						])
					else:
						ctx.send_log("%s has no hosted credits to take." % self_card.display_name())

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
					ctx.send_log("Docklands Pass: +%d access on %s." % [amount, required_server.to_upper()])

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
				ctx.send_log("%s is trashed (end of run)." % self_card.display_name())

		"self_trash":
			# Unconditionally trash the owning card (Tranquilizer, Fermenter, Spin Doctor, etc.)
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var self_card   := ctx.get_installed_card_by_instance_id(iid)
			if self_card == null and iid != "":
				self_card = ctx.get_installed_card_by_id(iid)
			if self_card != null:
				if self_card.hosted_on_id != "":
					# Hosted on ice (e.g. Tranquilizer, Chromatophores)
					# Clean up any subtypes this program had granted to the host ice first
					_cleanup_granted_subtypes(self_card, ctx)
					var host_ice := ctx.get_ice_by_instance_id(self_card.hosted_on_id)
					if host_ice != null:
						host_ice.hosted_cards.erase(self_card)
					if self_card.card_record != null:
						ctx.runner_discard.append(self_card.card_record)
				else:
					# Check corp server roots first (e.g. Spin Doctor asset)
					var found_in_server := false
					for server in ctx.servers.values():
						var s: Server = server as Server
						if s.root.has(self_card):
							s.remove_from_root(self_card)
							ctx.remove_empty_remote_servers()
							found_in_server = true
							break
					if found_in_server:
						if self_card.card_record != null:
							ctx.corp_discard.append(self_card.card_record)
					else:
						# Check server ice arrays (e.g. Lamplighter ICE self-trashing)
						var found_as_ice := false
						for ice_server in ctx.servers.values():
							var si: Server = ice_server as Server
							if si.ice.has(self_card):
								si.remove_ice(self_card)
								found_as_ice = true
								break
						if found_as_ice:
							if self_card.card_record != null:
								ctx.corp_discard.append(self_card.card_record)
						else:
							# Runner rig card (e.g. Fermenter)
							ctx.runner_rig.erase(self_card)
							if self_card.card_record != null:
								ctx.runner_discard.append(self_card.card_record)
				ctx.unregister_all_card_effects(iid)
				ctx.send_log("%s is trashed." % self_card.display_name())

		# ── Spin Doctor: shuffle cards from Archives into R&D ─────────────────

		"shuffle_archives_to_rd":
			var max_count: int = params.get("max_count", 2)
			if ctx.corp_discard.is_empty():
				ctx.send_log("Archives is empty — nothing to shuffle into R&D.")
			else:
				var dm: Object = ctx.corp_decision_maker
				var chosen: Array = []
				if dm != null and dm.has_method("choose_cards_from_archives"):
					chosen = await dm.choose_cards_from_archives(ctx.corp_discard, max_count, ctx)
				else:
					var count: int = min(max_count, ctx.corp_discard.size())
					for i in range(count):
						chosen.append(ctx.corp_discard[i])
				for card in chosen:
					ctx.corp_discard.erase(card)
					ctx.corp_deck.append(card)
				ctx.corp_deck.shuffle()
				ctx.send_log("Spin Doctor: shuffled %d card(s) from Archives into R&D." % chosen.size())

		# ── Malapert Data Vault: peek top of R&D; add to HQ if agenda/operation ──

		"malapert_top_rd_to_hq":
			if ctx.corp_deck.is_empty():
				ctx.send_log("Malapert Data Vault: R&D is empty.")
			else:
				var top_card: CardRecord = ctx.corp_deck[0] as CardRecord
				if top_card == null:
					pass
				elif top_card.card_type in ["agenda", "operation"]:
					# Corp always benefits from pulling an agenda or operation into hand.
					# Default AI: always accept. A human chooser method can override.
					var should_add := true
					if ctx.corp_decision_maker != null and \
							ctx.corp_decision_maker.has_method("choose_malapert_add_to_hq"):
						should_add = await ctx.corp_decision_maker.choose_malapert_add_to_hq(top_card, ctx)
					if should_add:
						ctx.corp_deck.pop_front()
						ctx.corp_hand.append({"card_id": top_card.id, "card_record": top_card})
						ctx.send_log("Malapert Data Vault: %s (%s) moved from top of R&D to HQ." % [
							top_card.title, top_card.card_type
						])
					else:
						ctx.send_log("Malapert Data Vault: Corp declines to add %s to HQ." % top_card.title)
				else:
					ctx.send_log("Malapert Data Vault: Top of R&D is %s (%s) — not an agenda or operation." % [
						top_card.title, top_card.card_type
					])

		# ── Precision Design: add 1 card from Archives to HQ ─────────────────

		"fetch_from_archives_to_hq":
			if ctx.corp_discard.is_empty():
				ctx.send_log("Archives is empty — Precision Design has nothing to fetch.")
			else:
				var dm: Object = ctx.corp_decision_maker
				var chosen_arch: CardRecord = null
				if dm != null and dm.has_method("choose_from_archives"):
					chosen_arch = await dm.choose_from_archives(ctx.corp_discard, ctx)
				else:
					chosen_arch = ctx.corp_discard[0] as CardRecord if not ctx.corp_discard.is_empty() else null
				if chosen_arch != null:
					ctx.corp_discard.erase(chosen_arch)
					ctx.corp_hand.append({"card_id": chosen_arch.id, "card_record": chosen_arch})
					ctx.send_log("Precision Design: %s adds %s from Archives to HQ." % [ctx.corp_name(), chosen_arch.title])

		# ── Hansei Review: Corp discards a card from HQ ───────────────────────

		"discard_from_corp_hand":
			var amount: int = params.get("amount", 1)
			var dm: Object = ctx.corp_decision_maker
			for _i in range(min(amount, ctx.corp_hand.size())):
				var chosen_entry: Variant = null
				if dm != null and dm.has_method("choose_card_from_hand"):
					chosen_entry = await dm.choose_card_from_hand(ctx.corp_hand, ctx)
				else:
					chosen_entry = ctx.corp_hand.back() if not ctx.corp_hand.is_empty() else null
				if chosen_entry == null:
					break
				ctx.corp_hand.erase(chosen_entry)
				var hq_record: CardRecord = (chosen_entry as Dictionary).get("card_record", null) as CardRecord
				if hq_record != null:
					ctx.corp_discard.append(hq_record)
					ctx.corp_discard_facedown[hq_record.title] = true
					ctx.send_log("%s discards %s from HQ." % [ctx.corp_name(), hq_record.title])

		# ── Longevity Serum: shuffle discard into deck, gain 1cr per card ─────

		"shuffle_discard_to_deck_gain_credits":
			var subject: String = params.get("subject", "corp")
			var s_discard: Array = ctx.corp_discard if subject == "corp" else ctx.runner_discard
			var s_deck: Array    = ctx.corp_deck    if subject == "corp" else ctx.runner_deck
			if s_discard.is_empty():
				ctx.send_log("Discard pile is empty — nothing to shuffle.")
			else:
				var dm: Object = ctx.corp_decision_maker if subject == "corp" else ctx.runner_decision_maker
				var chosen_cards: Array = []
				if dm != null and dm.has_method("choose_cards_to_shuffle_into_deck"):
					chosen_cards = await dm.choose_cards_to_shuffle_into_deck(s_discard.duplicate(), ctx)
				else:
					chosen_cards = s_discard.duplicate()
				for card in chosen_cards:
					s_discard.erase(card)
					s_deck.append(card)
				s_deck.shuffle()
				var gained: int = chosen_cards.size()
				if gained > 0:
					ctx.set_credits(subject, ctx.get_credits(subject) + gained)
					ctx.send_log("Longevity Serum: shuffled %d card(s) into R&D, gained %d cr." % [gained, gained])

		# ── Neurospike: deal net damage equal to last scored agenda's points ────

		"deal_damage_from_last_scored_agenda":
			var damage_type: String = params.get("damage_type", "net")
			var amount: int = ctx.corp_last_scored_agenda_points
			if amount <= 0:
				ctx.send_log("Neurospike: no agenda scored this turn — no damage.")
			else:
				ctx.send_log("Neurospike: deals %d %s damage." % [amount, damage_type])
				_deal_damage(damage_type, amount, ctx)

		# ── Weyland Built to Last: gain 2cr on first advance each turn ────────

		"gain_credits_first_advance_this_turn":
			if ctx.corp_gained_advance_credits_this_turn:
				return
			ctx.corp_gained_advance_credits_this_turn = true
			var btl_amount: int = params.get("amount", 2)
			ctx.corp_credits += btl_amount
			ctx.send_log("Built to Last: %s gains %d cr (first advance this turn)." % [ctx.corp_name(), btl_amount])

		# ── Zahya: gain 1cr per access beyond the first in HQ/Archives ────────

		"gain_credits_per_access_beyond_first":
			var allowed_servers: Array = params.get("servers", []) as Array
			var breach_server_id: String = ctx.current_event_data.get("server_id", "")
			if not allowed_servers.is_empty() and breach_server_id not in allowed_servers:
				return
			var total_accessed: int = ctx.current_event_data.get("access_count", 0)
			var zahya_bonus: int = max(0, total_accessed - 1)
			if zahya_bonus > 0:
				ctx.runner_credits += zahya_bonus
				ctx.send_log("Zahya: gains %d cr (%d accesses)." % [zahya_bonus, total_accessed])

		# ── Nanomanagement / otto_campaign extras: grant clicks ───────────────

		"gain_clicks":
			# Grant extra clicks to the Corp or Runner.
			# Used by Nanomanagement (Corp gains 2), and future cards.
			var gc_subject: String = params.get("subject", "corp")
			var gc_amount: int     = params.get("amount", 1)
			if gc_subject == "corp":
				ctx.corp_clicks += gc_amount
				ctx.send_log("%s gains %d click(s). (%d total)" % [ctx.corp_name(), gc_amount, ctx.corp_clicks])
			else:
				ctx.runner_clicks += gc_amount
				ctx.send_log("%s gains %d click(s). (%d total)" % [ctx.runner_name(), gc_amount, ctx.runner_clicks])

		# ── Flyswatter: purge all virus counters ──────────────────────────────

		"purge_virus_counters":
			# Remove all virus counters from all installed runner cards.
			var pv_total := 0
			for pv_card in ctx.runner_rig:
				var pv_c: InstalledCard = pv_card as InstalledCard
				if pv_c == null:
					continue
				var pv_vc: int = pv_c.get_counter("virus")
				if pv_vc > 0:
					pv_c.remove_counter("virus", pv_vc)
					pv_total += pv_vc
			# Also purge from programs hosted on ice
			for pv_server in ctx.servers.values():
				for pv_ice in (pv_server as Server).ice:
					for pv_hosted in (pv_ice as InstalledCard).hosted_cards:
						var pv_h: InstalledCard = pv_hosted as InstalledCard
						if pv_h != null:
							var pv_hvc: int = pv_h.get_counter("virus")
							if pv_hvc > 0:
								pv_h.remove_counter("virus", pv_hvc)
								pv_total += pv_hvc
			ctx.send_log("Purge: removed %d virus counter(s) from runner's installed cards." % pv_total)

		# ── Lie Low: remove tags ──────────────────────────────────────────────

		"remove_tags":
			# Remove up to N tags from the runner.
			var rt_amount: int = params.get("amount", 1)
			var rt_removed: int = min(rt_amount, ctx.runner_tags)
			ctx.runner_tags -= rt_removed
			ctx.send_log("%s removes %d tag(s). (%d remaining)" % [ctx.runner_name(), rt_removed, ctx.runner_tags])

		# ── Ritual: draw 1 card per remaining click ───────────────────────────

		"draw_cards_equal_to_remaining_clicks":
			# Draw 1 card for each click the subject currently has remaining.
			# Ritual fires this after spending 1 click to play, so remaining
			# clicks represent the usable draw count.
			var drc_subject: String = params.get("subject", "runner")
			var drc_clicks: int = ctx.runner_clicks if drc_subject == "runner" else ctx.corp_clicks
			if drc_clicks > 0:
				_draw_cards(drc_subject, drc_clicks, ctx)
			else:
				ctx.send_log("%s has no clicks remaining — draws 0 cards." % ctx.player_name(drc_subject))

		# ── Side Hustle: accumulate credits and auto-fire at threshold ────────

		"self_payout_and_trash_at_threshold":
			# When the owning card's hosted counter reaches the given threshold,
			# take all credits, draw 1 card, and self-trash. Used by Side Hustle.
			var sp_counter: String = effect.get("counter", params.get("counter", "credits"))
			var sp_threshold: int  = int(effect.get("threshold", params.get("threshold", 6)))
			var sp_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var sp_card := ctx.get_installed_card_by_instance_id(sp_iid)
			if sp_card == null:
				return
			if sp_card.get_counter(sp_counter) < sp_threshold:
				return   # threshold not yet reached
			# Take all hosted credits
			var sp_taken: int = sp_card.get_counter(sp_counter)
			sp_card.remove_counter(sp_counter, sp_taken)
			ctx.runner_credits += sp_taken
			ctx.send_log("%s takes all %d cr from %s (threshold reached)." % [
				ctx.runner_name(), sp_taken, sp_card.display_name()
			])
			# Draw 1 card for the runner
			_draw_cards("runner", 1, ctx)
			# Self-trash
			ctx.runner_rig.erase(sp_card)
			ctx.unregister_all_card_effects(sp_iid)
			if sp_card.card_record != null:
				ctx.runner_discard.append(sp_card.card_record)
			ctx.send_log("%s is trashed." % sp_card.display_name())

		# ── Top Down Solutions / KPI / Peer Review: install any card from HQ ─

		"install_any_from_hq":
			# Corp installs up to max_installs cards from HQ ignoring all costs.
			# Cards go into a new remote server (or the current run server if active).
			# optional: true means the Corp may decline to install one or more cards.
			var iafh_max: int     = params.get("max_installs", 1)
			var iafh_opt: bool    = params.get("optional", false)
			var iafh_zone: String = params.get("zone", "")  # "" = auto by card type
			for _iafh_i in range(iafh_max):
				if ctx.corp_hand.is_empty():
					ctx.send_log("%s has no cards in HQ to install." % ctx.corp_name())
					break
				var iafh_dm: Object = ctx.corp_decision_maker
				var iafh_entry: Variant = null
				if iafh_dm != null and iafh_dm.has_method("choose_card_from_hand"):
					iafh_entry = await iafh_dm.choose_card_from_hand(ctx.corp_hand, ctx)
				elif not iafh_opt:
					iafh_entry = ctx.corp_hand[0]
				if iafh_entry == null:
					break   # Corp declined
				var iafh_record: CardRecord = (iafh_entry as Dictionary).get("card_record", null) as CardRecord
				if iafh_record == null:
					break
				ctx.corp_hand.erase(iafh_entry)
				# Determine target server
				var iafh_server: Server = null
				if ctx.run_active and ctx.run_target_server != "":
					iafh_server = ctx.get_server(ctx.run_target_server)
				if iafh_server == null:
					iafh_server = ctx.create_remote_server()
				var iafh_z: String = iafh_zone
				if iafh_z == "":
					iafh_z = "ice" if iafh_record.is_ice() else "root"
				var iafh_installed := InstalledCard.make_runtime_instance(
					iafh_record, iafh_server.server_id, iafh_z, false
				)
				if iafh_z == "ice":
					iafh_server.install_ice(iafh_installed)
				else:
					iafh_server.install_in_root(iafh_installed)
				ctx.send_log("%s installs %s from HQ in %s (ignoring costs)." % [
					ctx.corp_name(), iafh_record.title, iafh_server.display_name()
				])

		# ── Empiricist / Syailendra: place advancement counter on installed ───

		"place_advancement_on_installed":
			# Corp places advancement counters on a chosen advanceable installed card.
			# optional: true means the Corp may skip.
			var pai_amount: int  = params.get("amount", 1)
			var pai_opt: bool    = params.get("optional", true)
			# Collect all advanceable cards (server roots + advanceable ice)
			var pai_pool: Array = []
			for pai_server in ctx.servers.values():
				var pai_s: Server = pai_server as Server
				for pai_root in pai_s.root:
					var pai_c: InstalledCard = pai_root as InstalledCard
					if pai_c.can_be_advanced():
						pai_pool.append(pai_c)
				for pai_ice in pai_s.ice:
					var pai_ic: InstalledCard = pai_ice as InstalledCard
					if pai_ic.can_be_advanced():
						pai_pool.append(pai_ic)
			if pai_pool.is_empty():
				ctx.send_log("No advanceable targets available for advancement counter.")
				return
			var pai_dm: Object = ctx.corp_decision_maker
			var pai_target: InstalledCard = null
			if pai_opt:
				# Optional: AI chooses (null = decline)
				if pai_dm != null and pai_dm.has_method("choose_target"):
					pai_target = await pai_dm.choose_target(pai_pool, {"reason": "advance_optional"})
			else:
				if pai_dm != null and pai_dm.has_method("choose_target"):
					pai_target = await pai_dm.choose_target(pai_pool, {"reason": "advance_required"})
				else:
					pai_target = pai_pool[0]
			if pai_target != null:
				pai_target.add_counter("advancement", pai_amount)
				ctx.send_log("%s places %d advancement counter(s) on %s." % [
					ctx.corp_name(), pai_amount, pai_target.display_name()
				])

		# ── Empiricist sub 1: add card from HQ to top of R&D ─────────────────

		"return_card_to_top_from_hand":
			# Corp (or runner) optionally returns a card from hand to top of deck.
			var rct_subject: String = params.get("subject", "corp")
			var rct_opt: bool       = params.get("optional", true)
			var rct_hand: Array = ctx.corp_hand if rct_subject == "corp" else ctx.runner_hand
			var rct_deck: Array = ctx.corp_deck if rct_subject == "corp" else ctx.runner_deck
			if rct_hand.is_empty():
				return
			var rct_dm: Object = ctx.corp_decision_maker if rct_subject == "corp" else ctx.runner_decision_maker
			var rct_entry: Variant = null
			if rct_dm != null and rct_dm.has_method("choose_card_from_hand"):
				rct_entry = await rct_dm.choose_card_from_hand(rct_hand, ctx)
			elif not rct_opt:
				rct_entry = rct_hand[0]
			if rct_entry == null:
				return   # Declined
			rct_hand.erase(rct_entry)
			var rct_record: CardRecord = (rct_entry as Dictionary).get("card_record", null) as CardRecord
			if rct_record != null:
				rct_deck.push_front(rct_record)
				ctx.send_log("%s adds %s to the top of their deck." % [ctx.player_name(rct_subject), rct_record.title])

		# ── Recurring credits: refill to max at start of turn ────────────────

		"refill_recurring_credits":
			# Refill the owning card's recurring credit counter to the specified maximum.
			# Used by Azimat (runner_turn_start, max 2) and Mahkota Langit Grid (corp_turn_start, max 2).
			# Only tops up; does not overfill. No-ops if already at max.
			var rrc_counter: String = effect.get("counter", params.get("counter", "recurring_credits"))
			var rrc_max: int        = int(effect.get("max", params.get("max", 2)))
			var rrc_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var rrc_card := ctx.get_installed_card_by_instance_id(rrc_iid)
			if rrc_card == null and rrc_iid != "":
				rrc_card = ctx.get_installed_card_by_id(rrc_iid)
			if rrc_card != null:
				var rrc_current: int = rrc_card.get_counter(rrc_counter)
				if rrc_current < rrc_max:
					rrc_card.add_counter(rrc_counter, rrc_max - rrc_current)
					ctx.send_log("%s: %s refilled to %d." % [rrc_card.display_name(), rrc_counter, rrc_max])

		# ── Install ice from HQ with fallback outside runs ────────────────────
		# (Extends existing install_ice_from_hq to work outside run context)

		"install_ice_from_hq_any_server":
			# Like install_ice_from_hq but also works outside of runs.
			# Corp chooses ice from HQ and a remote server to install it on.
			var iifha_candidates: Array = []
			for iifha_entry in ctx.corp_hand:
				var iifha_e: Dictionary = iifha_entry as Dictionary
				var iifha_r: CardRecord = iifha_e.get("card_record", null) as CardRecord
				if iifha_r != null and iifha_r.is_ice():
					iifha_candidates.append(iifha_entry)
			if iifha_candidates.is_empty():
				ctx.send_log("%s has no ice in HQ to install." % ctx.corp_name())
			else:
				var iifha_dm: Object = ctx.corp_decision_maker
				var iifha_chosen: Variant = null
				if iifha_dm != null and iifha_dm.has_method("choose_card_from_hand"):
					iifha_chosen = await iifha_dm.choose_card_from_hand(iifha_candidates, ctx)
				else:
					iifha_chosen = iifha_candidates[0]
				if iifha_chosen != null:
					var iifha_record: CardRecord = (iifha_chosen as Dictionary).get("card_record", null) as CardRecord
					if iifha_record != null:
						ctx.corp_hand.erase(iifha_chosen)
						# Use run server if active, otherwise create a remote
						var iifha_server: Server = null
						if ctx.run_active and ctx.run_target_server != "":
							iifha_server = ctx.get_server(ctx.run_target_server)
						if iifha_server == null:
							iifha_server = ctx.create_remote_server()
						var iifha_inst := InstalledCard.make_runtime_instance(
							iifha_record, iifha_server.server_id, "ice", false
						)
						iifha_server.install_ice(iifha_inst)
						ctx.send_log("%s installs %s from HQ on %s (ignoring costs)." % [
							ctx.corp_name(), iifha_record.title, iifha_server.display_name()
						])

		# ── Dividends mechanic ────────────────────────────────────────────────────

		"place_dividend_counters":
			# On-score effect for Dividends agendas.
			# Reads "dividends" (printed N) from the effect definition and
			# "excess_advancement" from current_event_data, then places
			# (dividends + excess) "agenda" counters on the just-scored card.
			var dividends: int  = int(effect.get("dividends", 0))
			var iid: String     = ctx.current_event_data.get("card_instance_id", "")
			var excess: int     = ctx.current_event_data.get("excess_advancement", 0) as int
			var total: int      = dividends + excess
			if total <= 0:
				return
			var scored_card := ctx.get_installed_card_by_instance_id(iid)
			if scored_card == null:
				push_error("AbilityInterpreter: place_dividend_counters — cannot find scored card '%s'" % iid)
				return
			scored_card.add_counter("agenda", total)
			ctx.send_log("%s places %d agenda counter(s) on %s (Dividends %d + %d excess)." % [
				ctx.corp_name(), total, scored_card.display_name(), dividends, excess
			])

		"spend_agenda_counter":
			# Prerequisite effect for Dividends click actions.
			# Removes 1 "agenda" counter from the scored card that owns this ability.
			# Aborts the remaining effects if no counter is available.
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var scored_card := ctx.get_installed_card_by_instance_id(iid)
			if scored_card == null:
				ctx.send_log("spend_agenda_counter: scored agenda not found.")
				return
			var available: int = scored_card.get_counter("agenda")
			if available <= 0:
				ctx.send_log("%s has no agenda counters to spend." % scored_card.display_name())
				return
			scored_card.remove_counter("agenda", 1)
			ctx.send_log("%s spends 1 agenda counter from %s (%d remaining)." % [
				ctx.corp_name(), scored_card.display_name(), scored_card.get_counter("agenda")
			])

		"install_from_archives_free":
			# Dividends payout — Project Ingatan.
			# Corp chooses any card from Archives (corp_discard) and installs it
			# on a new remote server, ignoring all costs.
			if ctx.corp_discard.is_empty():
				ctx.send_log("%s: Archives is empty — nothing to install." % ctx.corp_name())
				return
			var ifa_candidates: Array = []
			for ifa_r in ctx.corp_discard:
				var ifa_record: CardRecord = ifa_r as CardRecord
				if ifa_record == null:
					continue
				# Only cards that can be installed (not operations/events)
				var ct: String = ifa_record.card_type
				if ct in ["ice", "agenda", "asset", "upgrade"]:
					ifa_candidates.append({"card_id": ifa_record.id, "card_record": ifa_record})
			if ifa_candidates.is_empty():
				ctx.send_log("%s: Archives has no installable cards." % ctx.corp_name())
				return
			var ifa_dm: Object = ctx.corp_decision_maker
			var ifa_entry: Variant = null
			if ifa_dm != null and ifa_dm.has_method("choose_card_from_hand"):
				ifa_entry = await ifa_dm.choose_card_from_hand(ifa_candidates, ctx)
			else:
				ifa_entry = ifa_candidates[0]
			if ifa_entry == null:
				return
			var ifa_record: CardRecord = (ifa_entry as Dictionary).get("card_record", null) as CardRecord
			if ifa_record == null:
				return
			ctx.corp_discard.erase(ifa_record)
			var ifa_zone: String = "ice" if ifa_record.is_ice() else "root"
			var ifa_server: Server = ctx.create_remote_server()
			var ifa_installed := InstalledCard.make_runtime_instance(
				ifa_record, ifa_server.server_id, ifa_zone, false
			)
			if ifa_zone == "ice":
				ifa_server.install_ice(ifa_installed)
			else:
				ifa_server.install_in_root(ifa_installed)
			ctx.send_log("%s installs %s from Archives on %s (ignoring costs)." % [
				ctx.corp_name(), ifa_record.title, ifa_server.display_name()
			])

		"search_rd_to_top":
			# Dividends payout — Embedded Reporting.
			# Search R&D for a card matching the given card_type(s), then place it
			# on top of R&D.  R&D is shuffled after the chosen card is removed.
			var srtt_types: Array   = params.get("card_types", []) as Array
			var srtt_subs: Array    = params.get("subtypes",   []) as Array
			var srtt_candidates: Array = []
			for srtt_r in ctx.corp_deck:
				var srtt_record: CardRecord = srtt_r as CardRecord
				if srtt_record == null:
					continue
				var srtt_type_ok := srtt_types.is_empty() or srtt_types.has(srtt_record.card_type)
				var srtt_sub_ok  := srtt_subs.is_empty()
				if not srtt_sub_ok:
					for st in srtt_subs:
						if srtt_record.has_subtype(st):
							srtt_sub_ok = true
							break
				if srtt_type_ok and srtt_sub_ok:
					srtt_candidates.append(srtt_record)
			if srtt_candidates.is_empty():
				ctx.send_log("%s searches R&D but finds no matching card — R&D is shuffled." % ctx.corp_name())
				ctx.corp_deck.shuffle()
				return
			var srtt_dm: Object = ctx.corp_decision_maker
			var srtt_chosen: CardRecord = null
			if srtt_dm != null and srtt_dm.has_method("choose_from_search"):
				srtt_chosen = await srtt_dm.choose_from_search(srtt_candidates, ctx)
			else:
				srtt_chosen = srtt_candidates[0]
			if srtt_chosen == null:
				ctx.corp_deck.shuffle()
				return
			ctx.corp_deck.erase(srtt_chosen)
			ctx.corp_deck.shuffle()         # shuffle the remaining deck first
			ctx.corp_deck.push_front(srtt_chosen)  # then place chosen card on top
			ctx.send_log("%s searches R&D and places %s on top of R&D." % [
				ctx.corp_name(), srtt_chosen.title
			])

		"search_rd_install_free":
			# Dividends payout — Off the Books.
			# Corp searches R&D for any card and may install it ignoring all costs.
			if ctx.corp_deck.is_empty():
				ctx.send_log("%s: R&D is empty." % ctx.corp_name())
				return
			# Build candidate list (installable cards only: not operations)
			var srif_candidates: Array = []
			for srif_r in ctx.corp_deck:
				var srif_record: CardRecord = srif_r as CardRecord
				if srif_record == null:
					continue
				var srif_ct: String = srif_record.card_type
				if srif_ct in ["ice", "agenda", "asset", "upgrade"]:
					srif_candidates.append(srif_record)
			if srif_candidates.is_empty():
				ctx.send_log("%s searches R&D but finds no installable card — R&D is shuffled." % ctx.corp_name())
				ctx.corp_deck.shuffle()
				return
			var srif_dm: Object = ctx.corp_decision_maker
			var srif_chosen: CardRecord = null
			if srif_dm != null and srif_dm.has_method("choose_from_search"):
				srif_chosen = await srif_dm.choose_from_search(srif_candidates, ctx)
			else:
				srif_chosen = srif_candidates[0]
			if srif_chosen == null:
				ctx.corp_deck.shuffle()
				return
			ctx.corp_deck.erase(srif_chosen)
			ctx.corp_deck.shuffle()
			var srif_zone: String = "ice" if srif_chosen.is_ice() else "root"
			var srif_server: Server = ctx.create_remote_server()
			var srif_installed := InstalledCard.make_runtime_instance(
				srif_chosen, srif_server.server_id, srif_zone, false
			)
			if srif_zone == "ice":
				srif_server.install_ice(srif_installed)
			else:
				srif_server.install_in_root(srif_installed)
			ctx.send_log("%s searches R&D and installs %s on %s (ignoring costs)." % [
				ctx.corp_name(), srif_chosen.title, srif_server.display_name()
			])

		# ── NBN: tag-related effects ──────────────────────────────────────────────

		"give_tags_if_agenda_stolen_this_run":
			# AMAZE Amusements: whenever a run on THIS card's server ends, if the Runner
			# stole an agenda during that run, give the Runner N tags.
			if not ctx.runner_stole_agenda_this_run:
				return
			var run_server: String = ctx.current_event_data.get("server_id", "")
			var amaze_iid: String  = ctx.current_event_data.get("card_instance_id", "")
			var amaze_card := ctx.get_installed_card_by_instance_id(amaze_iid)
			if amaze_card == null or amaze_card.server_id != run_server:
				return   # run was on a different server
			if not amaze_card.is_rezzed:
				return   # must be rezzed to trigger
			var amaze_amount: int = params.get("amount", 2)
			ctx.runner_tags += amaze_amount
			ctx.send_log("AMAZE Amusements: %s takes %d tag(s) (agenda stolen this run). (%d total)" % [
				ctx.runner_name(), amaze_amount, ctx.runner_tags
			])
			await ctx.notify_event("runner_takes_tags", {"amount": amaze_amount}, self)

		"runner_must_take_tag_or_end_run":
			# Funhouse encounter_ice: the Runner must take N tags or end the run.
			# If the Runner decision maker has no preference, default to taking the tag.
			var rmt_amount: int = params.get("amount", 1)
			var rmt_end_run := false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_take_tag_or_end_run"):
				rmt_end_run = await ctx.runner_decision_maker.choose_take_tag_or_end_run(rmt_amount, ctx)
			if rmt_end_run:
				ctx.run_ended = true
				ctx.send_log("%s ends the run to avoid %d tag(s) (Funhouse)." % [ctx.runner_name(), rmt_amount])
			else:
				ctx.runner_tags += rmt_amount
				ctx.send_log("%s takes %d tag(s) to continue the run (Funhouse). (%d total)" % [
					ctx.runner_name(), rmt_amount, ctx.runner_tags
				])
				await ctx.notify_event("runner_takes_tags", {"amount": rmt_amount}, self)

		"give_tag_unless_runner_pays":
			# Give the Runner 1 tag unless they pay cost credits.
			# Used by Funhouse subroutine (cost 4) and Public Trail (cost 8).
			var gtup_cost: int = params.get("cost", 4)
			var gtup_pays := false
			if ctx.runner_credits >= gtup_cost and ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_pay_to_avoid_tag"):
				gtup_pays = await ctx.runner_decision_maker.choose_pay_to_avoid_tag(gtup_cost, ctx)
			if gtup_pays:
				ctx.runner_credits -= gtup_cost
				ctx.send_log("%s pays %d cr to avoid 1 tag." % [ctx.runner_name(), gtup_cost])
			else:
				ctx.runner_tags += 1
				ctx.send_log("%s takes 1 tag (did not pay %d cr). (%d total)" % [
					ctx.runner_name(), gtup_cost, ctx.runner_tags
				])
				await ctx.notify_event("runner_takes_tags", {"amount": 1}, self)

		"deal_damage_unless_runner_pays":
			# Corp operation effect (e.g. Measured Response): do N damage unless the
			# Runner pays M credits to prevent it.
			# params: { damage_type, damage, cost }
			var ddup_type:   String = params.get("damage_type", "meat")
			var ddup_damage: int    = params.get("damage", 0)
			var ddup_cost:   int    = params.get("cost", 0)
			var ddup_pays := false
			if ctx.runner_credits >= ddup_cost and ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_pay_to_avoid_damage"):
				ddup_pays = await ctx.runner_decision_maker.choose_pay_to_avoid_damage(
					ddup_cost, ddup_damage, ddup_type, ctx
				)
			if ddup_pays:
				ctx.runner_credits -= ddup_cost
				ctx.send_log("%s pays %d cr to avoid %d %s damage." % [
					ctx.runner_name(), ddup_cost, ddup_damage, ddup_type
				])
			else:
				ctx.send_log("%s takes %d %s damage (did not pay %d cr)." % [
					ctx.runner_name(), ddup_damage, ddup_type, ddup_cost
				])
				_deal_damage(ddup_type, ddup_damage, ctx)

		# ── Byte: Corp may pay N cr to give tag(s) + net damage on access ───────────

		"corp_optional_pay_tag_and_damage":
			# Byte on_access: Corp may pay cost credits to give the Runner tags and net damage.
			# Skips silently if Corp cannot afford the cost.
			var copd_cost:   int    = params.get("cost", 4)
			var copd_tags:   int    = params.get("tags", 1)
			var copd_damage: int    = params.get("damage", 3)
			var copd_dtype:  String = params.get("damage_type", "net")

			if ctx.corp_credits < copd_cost:
				ctx.send_log("Byte: %s cannot afford to activate (%d cr needed, %d available)." % [
					ctx.corp_name(), copd_cost, ctx.corp_credits
				])
				return

			# Corp decides whether to pay
			var copd_pay := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var copd_modes: Array = [
					{"label": "Byte: pay %d cr — %s takes %d tag(s) + %d %s damage" % [
						copd_cost, ctx.runner_name(), copd_tags, copd_damage, copd_dtype]},
					{"label": "Pass"}
				]
				var copd_chosen: Array = await ctx.corp_decision_maker.choose_modes(copd_modes, 1, ctx)
				copd_pay = (not copd_chosen.is_empty() and copd_chosen[0] == 0)
			else:
				# Fallback AI: activate if it would flatline or if runner is untagged
				copd_pay = copd_damage >= ctx.runner_hand.size() or ctx.runner_tags == 0

			if not copd_pay:
				ctx.send_log("Byte: %s passes." % ctx.corp_name())
				return

			ctx.corp_credits -= copd_cost
			ctx.send_log("Byte: %s pays %d cr." % [ctx.corp_name(), copd_cost])
			ctx.runner_tags += copd_tags
			ctx.send_log("Byte: %s takes %d tag(s). (%d total)" % [
				ctx.runner_name(), copd_tags, ctx.runner_tags
			])
			await ctx.notify_event("runner_takes_tags", {"amount": copd_tags}, self)
			_deal_damage(copd_dtype, copd_damage, ctx)

		"reality_plus_trigger":
			# NBN: Reality Plus identity — the first time each turn the Runner takes a
			# tag, the Corp gains 2 credits or draws 2 cards (Corp's choice).
			if ctx.corp_used_reality_plus_this_turn:
				return
			ctx.corp_used_reality_plus_this_turn = true
			ctx.send_log("NBN: Reality Plus — %s may gain 2 cr or draw 2 cards." % ctx.corp_name())
			var rp_modes: Array = [
				{
					"label": "Gain 2 credits",
					"effects": [{"type": "gain_credits", "params": {"subject": "corp", "amount": 2}}]
				},
				{
					"label": "Draw 2 cards",
					"effects": [{"type": "draw_cards", "params": {"subject": "corp", "amount": 2}}]
				}
			]
			var rp_idx := 0
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var rp_chosen: Array = await ctx.corp_decision_maker.choose_modes(rp_modes, 1, ctx)
				if not rp_chosen.is_empty():
					rp_idx = rp_chosen[0]
			var rp_mode: Dictionary = rp_modes[rp_idx] as Dictionary
			ctx.send_log("Reality Plus: %s chooses '%s'." % [ctx.corp_name(), rp_mode.get("label", "")])
			for rp_eff in rp_mode.get("effects", []) as Array:
				await _execute_effect(rp_eff as Dictionary, ctx, null)

		# ── Derez effects ────────────────────────────────────────────────────────

		"may_trash_self_to_derez_corp_card":
			# Runner may trash this card to derez 1 rezzed Corp card.
			# Optional: runner chooses whether to activate.
			# params:
			#   required_server: "hq"|"rd"|etc — skip if run was on a different server
			var mtd_required: String = params.get("required_server", "")
			if mtd_required != "" and ctx.current_event_data.get("server_id", "") != mtd_required:
				return  # wrong server

			# Gather all rezzed Corp cards (ice + root) as candidates
			var mtd_candidates: Array = []
			for mtd_server in ctx.servers.values():
				var mtd_s: Server = mtd_server as Server
				for mtd_ice in mtd_s.ice:
					var mtd_c: InstalledCard = mtd_ice as InstalledCard
					if mtd_c.is_rezzed:
						mtd_candidates.append(mtd_c)
				for mtd_root in mtd_s.root:
					var mtd_c: InstalledCard = mtd_root as InstalledCard
					if mtd_c.is_rezzed:
						mtd_candidates.append(mtd_c)

			if mtd_candidates.is_empty():
				return  # nothing to derez

			# Ask runner: activate (trash self to derez) or pass?
			var mtd_activate := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var mtd_modes: Array = [
					{"label": "Trash this card to derez a Corp card"},
					{"label": "Pass"}
				]
				var mtd_chosen: Array = await ctx.runner_decision_maker.choose_modes(mtd_modes, 1, ctx)
				mtd_activate = (not mtd_chosen.is_empty() and mtd_chosen[0] == 0)
			else:
				mtd_activate = true  # AI default: always use it

			if not mtd_activate:
				return

			# Ask runner to choose which Corp card to derez
			var mtd_target: InstalledCard = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_derez_target"):
				mtd_target = await ctx.runner_decision_maker.choose_derez_target(mtd_candidates, ctx)
			else:
				mtd_target = mtd_candidates[0] as InstalledCard

			if mtd_target == null:
				return

			# Derez the chosen Corp card
			await _derez_card(mtd_target, ctx)

			# Trash self (this card)
			var mtd_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var mtd_self := ctx.get_installed_card_by_instance_id(mtd_iid)
			if mtd_self != null:
				ctx.runner_rig.erase(mtd_self)
				ctx.unregister_all_card_effects(mtd_iid)
				if mtd_self.card_record != null:
					ctx.runner_discard.append(mtd_self.card_record)
				ctx.send_log("%s is trashed." % mtd_self.display_name())

		"may_trash_self_to_bypass":
			# Runner may trash this card to bypass the currently encountered ice
			# (pass through without resolving any subroutines).
			# params:
			#   trigger_if_corp_credits_gte: int — only offer if Corp has at least this many credits
			var mttb_threshold: int = params.get("trigger_if_corp_credits_gte", 0)
			if mttb_threshold > 0 and ctx.corp_credits < mttb_threshold:
				return  # condition not met — ability does not trigger

			# Ask runner: activate (trash self to bypass) or pass?
			var mttb_activate := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var mttb_modes: Array = [
					{"label": "Trash this card to bypass %s" % ctx.current_event_data.get("ice", null).display_name()},
					{"label": "Pass"}
				]
				var mttb_chosen: Array = await ctx.runner_decision_maker.choose_modes(mttb_modes, 1, ctx)
				mttb_activate = (not mttb_chosen.is_empty() and mttb_chosen[0] == 0)
			else:
				mttb_activate = true  # AI default: always bypass when condition is met

			if not mttb_activate:
				return

			# Set bypass flag — RunStateMachine checks this immediately after encounter_ice
			ctx.run_modifiers["bypass_current_ice"] = true

			# Trash self
			var mttb_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var mttb_self := ctx.get_installed_card_by_instance_id(mttb_iid)
			if mttb_self != null:
				ctx.runner_rig.erase(mttb_self)
				ctx.unregister_all_card_effects(mttb_iid)
				if mttb_self.card_record != null:
					ctx.runner_discard.append(mttb_self.card_record)
				ctx.send_log("%s is trashed — %s bypassed." % [
					mttb_self.display_name(),
					ctx.current_event_data.get("ice", null).display_name()
				])

		# ── Boomerang: optional heap recursion after successful run ─────────────

		"boomerang_recur_from_heap":
			# "When this run ends, if it was successful, you may shuffle 1 copy of
			# Boomerang from your heap into your stack."
			# The run_end event data carries {successful: bool}.
			# When Boomerang is trashed mid-run via trash_self_on_use, its run_end
			# listener is kept alive (via unregister_card_effects_except_event) so this
			# fires. After this effect executes for a trashed Boomerang, its run_end
			# listener is cleaned up so it won't ghost-fire on future runs.
			var bm_iid: String = ctx.current_event_data.get("card_instance_id", "")

			# Determine if this card is still in the rig (not trashed during the run)
			var bm_still_installed: bool = false
			for bm_c in ctx.runner_rig:
				if (bm_c as InstalledCard).runtime_instance_id == bm_iid:
					bm_still_installed = true
					break

			if not ctx.current_event_data.get("successful", false):
				# Not a successful run. If the card was trashed, clean up the listener.
				if not bm_still_installed and bm_iid != "":
					ctx.unregister_all_card_effects(bm_iid)
				return

			# Successful run — find a copy of Boomerang in the runner's discard pile
			var bm_discard_idx: int = -1
			for bm_i in range(ctx.runner_discard.size()):
				var bm_r: CardRecord = ctx.runner_discard[bm_i] as CardRecord
				if bm_r != null and bm_r.id == "boomerang":
					bm_discard_idx = bm_i
					break

			# If Boomerang was trashed during this run, clean up the orphaned run_end
			# listener now — it has served its purpose regardless of whether we recur.
			if not bm_still_installed and bm_iid != "":
				ctx.unregister_all_card_effects(bm_iid)

			if bm_discard_idx < 0:
				return  # no Boomerang in heap

			# Ask the runner if they want to shuffle it back
			var bm_choose := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var bm_modes: Array = [
					{"label": "Shuffle Boomerang into stack"},
					{"label": "Leave Boomerang in heap"}
				]
				var bm_chosen: Array = await ctx.runner_decision_maker.choose_modes(bm_modes, 1, ctx)
				bm_choose = (not bm_chosen.is_empty() and bm_chosen[0] == 0)
			else:
				bm_choose = true  # AI default: always recur

			if bm_choose:
				var bm_record: CardRecord = ctx.runner_discard[bm_discard_idx] as CardRecord
				ctx.runner_discard.remove_at(bm_discard_idx)
				var bm_insert: int = randi() % (ctx.runner_deck.size() + 1)
				ctx.runner_deck.insert(bm_insert, bm_record)
				ctx.send_log("%s shuffles %s from their heap into their stack." % [
					ctx.runner_name(), bm_record.title
				])

		# ── Devadatta Drone: spend power counters for bonus R&D access ───────────

		"spend_counters_for_bonus_access":
			# During a breach of the specified server, runner may spend up to N counters
			# from this card for +N additional accesses. Fires via before_breach trigger.
			var scba_server: String  = params.get("server", "rd")
			var scba_counter: String = params.get("counter", "power")
			var scba_breach: String  = ctx.current_event_data.get("server_id", "")
			if scba_breach != scba_server:
				return   # only fires on the target server

			var scba_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var scba_card := ctx.get_installed_card_by_instance_id(scba_iid)
			if scba_card == null:
				return

			var scba_available: int = scba_card.get_counter(scba_counter)
			if scba_available <= 0:
				return   # no counters to spend

			# Ask runner how many counters to spend (0 = decline)
			var scba_spend: int = scba_available   # AI default: spend all
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_spend_counter_amount"):
				scba_spend = await ctx.runner_decision_maker.choose_spend_counter_amount(
					scba_card, scba_counter, scba_available, ctx
				)
			scba_spend = clampi(scba_spend, 0, scba_available)
			if scba_spend <= 0:
				return

			scba_card.remove_counter(scba_counter, scba_spend)
			var scba_current: int = ctx.run_modifiers.get("bonus_access", 0)
			ctx.run_modifiers["bonus_access"] = scba_current + scba_spend
			ctx.send_log("%s spends %d %s counter(s) from %s — +%d %s access." % [
				ctx.runner_name(), scba_spend, scba_counter,
				scba_card.display_name(), scba_spend, scba_server.to_upper()
			])

		# ── Biawak: trash a program or end the run ────────────────────────────────

		"runner_must_trash_program_or_etr":
			# Subroutine: trash an installed program, or if none, end the run.
			var rmt_programs: Array = ctx.runner_rig.filter(
				func(c: InstalledCard): return c.card_record != null and c.card_record.card_type == "program"
			)
			# Also include programs hosted on ice
			for rmt_server in ctx.servers.values():
				for rmt_ice in (rmt_server as Server).ice:
					for rmt_hosted in (rmt_ice as InstalledCard).hosted_cards:
						var rmt_h: InstalledCard = rmt_hosted as InstalledCard
						if rmt_h != null and rmt_h.card_record != null and rmt_h.card_record.card_type == "program":
							if not rmt_programs.has(rmt_h):
								rmt_programs.append(rmt_h)
			if rmt_programs.is_empty():
				ctx.run_ended = true
				ctx.send_log("Biawak: no installed programs — run ended.")
			else:
				# Runner must choose which program to trash
				var rmt_target: InstalledCard = null
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_trash_from_rig"):
					rmt_target = await ctx.runner_decision_maker.choose_trash_from_rig(rmt_programs, ctx)
				if rmt_target == null:
					rmt_target = rmt_programs[0] as InstalledCard
				_trash_installed_card(rmt_target, ctx)
				if rmt_target.card_record != null:
					ctx.runner_discard.append(rmt_target.card_record)
				ctx.send_log("Biawak: %s trashed %s." % [ctx.runner_name(), rmt_target.display_name()])

		# ── Biawak: trash a resource or end the run ───────────────────────────────

		"runner_must_trash_resource_or_etr":
			# Subroutine: trash an installed resource, or if none, end the run.
			var rmr_resources: Array = ctx.runner_rig.filter(
				func(c: InstalledCard): return c.card_record != null and c.card_record.card_type == "resource"
			)
			if rmr_resources.is_empty():
				ctx.run_ended = true
				ctx.send_log("Biawak: no installed resources — run ended.")
			else:
				var rmr_target: InstalledCard = null
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_trash_from_rig"):
					rmr_target = await ctx.runner_decision_maker.choose_trash_from_rig(rmr_resources, ctx)
				if rmr_target == null:
					rmr_target = rmr_resources[0] as InstalledCard
				ctx.runner_rig.erase(rmr_target)
				ctx.unregister_all_card_effects(rmr_target.runtime_instance_id)
				if rmr_target.card_record != null:
					ctx.runner_discard.append(rmr_target.card_record)
				ctx.send_log("Biawak: %s trashed %s." % [ctx.runner_name(), rmr_target.display_name()])

		# ── Plutus: corp turn start — may play a transaction from Archives (RFG) ──

		"may_play_transaction_from_archives_rfg":
			# Plutus corp_turn_start: Corp may play a transaction from Archives,
			# then remove it from the game instead of placing it in Archives again.
			var mptafr_candidates: Array = []
			for mptafr_r in ctx.corp_discard:
				var mptafr_record: CardRecord = mptafr_r as CardRecord
				if mptafr_record == null:
					continue
				if mptafr_record.card_type == "operation" and mptafr_record.has_subtype("transaction"):
					mptafr_candidates.append(mptafr_record)
			if mptafr_candidates.is_empty():
				ctx.send_log("Plutus: no transactions in Archives to play.")
				return

			# Corp chooses one (or declines)
			var mptafr_dm: Object = ctx.corp_decision_maker
			var mptafr_chosen: CardRecord = null
			if mptafr_dm != null and mptafr_dm.has_method("choose_from_archives"):
				mptafr_chosen = await mptafr_dm.choose_from_archives(mptafr_candidates, ctx)
			else:
				mptafr_chosen = mptafr_candidates[0]   # AI default: always use it

			if mptafr_chosen == null:
				ctx.send_log("Plutus: Corp declines to play a transaction from Archives.")
				return

			ctx.send_log("Plutus: %s plays %s from Archives." % [ctx.corp_name(), mptafr_chosen.title])
			ctx.corp_discard.erase(mptafr_chosen)

			# Execute the transaction's on_play effect
			if ctx.has_meta("ability_registry"):
				var mptafr_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var mptafr_on_play = mptafr_ab_reg.get_on_play(mptafr_chosen.id)
				if mptafr_on_play != null:
					await execute_trigger(mptafr_on_play as Dictionary, ctx)
				else:
					ctx.send_log("Plutus: %s has no on_play effect defined." % mptafr_chosen.title)

			# Remove from game (not back to Archives)
			ctx.corp_rfg.append(mptafr_chosen)
			ctx.send_log("Plutus: %s is removed from the game." % mptafr_chosen.title)

		# ── Humanoid Resources: play 1 operation from HQ ─────────────────────────

		"may_play_operation_from_hq":
			# Corp may choose 1 operation from HQ, pay its cost, and execute its on_play.
			# Used by Humanoid Resources (fires after self-trash + gain + draw + install).
			# params: { "optional": bool }
			var mpoh_optional: bool = params.get("optional", true)

			# Gather affordable operations from HQ.
			var mpoh_candidates: Array = []
			for mpoh_entry in ctx.corp_hand:
				var mpoh_e: Dictionary = mpoh_entry as Dictionary
				var mpoh_r: CardRecord = mpoh_e.get("card_record", null) as CardRecord
				if mpoh_r == null or mpoh_r.card_type != "operation":
					continue
				if ctx.corp_credits < max(0, mpoh_r.cost):
					continue   # can't afford — don't show as an option
				mpoh_candidates.append(mpoh_entry)

			if mpoh_candidates.is_empty():
				ctx.send_log("Humanoid Resources: no affordable operations in HQ.")
				return

			# Corp chooses one (null = decline, valid when optional).
			var mpoh_dm: Object = ctx.corp_decision_maker
			var mpoh_chosen_entry: Variant = null
			if mpoh_dm != null and mpoh_dm.has_method("choose_card_from_hand"):
				mpoh_chosen_entry = await mpoh_dm.choose_card_from_hand(mpoh_candidates, ctx)
			elif not mpoh_optional:
				mpoh_chosen_entry = mpoh_candidates[0]

			if mpoh_chosen_entry == null:
				ctx.send_log("Humanoid Resources: Corp declines to play an operation.")
				return

			var mpoh_record: CardRecord = (mpoh_chosen_entry as Dictionary).get("card_record", null) as CardRecord
			if mpoh_record == null:
				return

			# Pay the operation's credit cost.
			var mpoh_cost: int = max(0, mpoh_record.cost)
			ctx.corp_credits -= mpoh_cost
			ctx.corp_hand.erase(mpoh_chosen_entry)
			ctx.send_log("Humanoid Resources: %s plays %s%s." % [
				ctx.corp_name(),
				mpoh_record.title,
				(" for %d cr" % mpoh_cost) if mpoh_cost > 0 else " for free"
			])

			# Execute the operation's on_play effects.
			if ctx.has_meta("ability_registry"):
				var mpoh_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var mpoh_on_play = mpoh_ab_reg.get_on_play(mpoh_record.id)
				if mpoh_on_play != null:
					ctx.corp_played_operation_this_turn = true
					await execute_trigger(mpoh_on_play as Dictionary, ctx)
				else:
					ctx.send_log("Humanoid Resources: %s has no on_play effect." % mpoh_record.title)

			# Discard the played operation to Archives.
			ctx.corp_discard.append(mpoh_record)

		# ── Mycoweb sub 1: install ice from Archives, ignoring all costs ──────────

		"install_ice_from_archives":
			# Corp may install 1 piece of ice from Archives on the run server (or a new
			# remote if called outside a run), ignoring all costs.
			# params: { "optional": bool }
			var iifa_optional: bool = params.get("optional", true)

			# Collect ice from Archives (corp_discard)
			var iifa_candidates: Array = []
			for iifa_r in ctx.corp_discard:
				var iifa_record: CardRecord = iifa_r as CardRecord
				if iifa_record != null and iifa_record.is_ice():
					iifa_candidates.append({"card_id": iifa_record.id, "card_record": iifa_record})

			if iifa_candidates.is_empty():
				ctx.send_log("[Mycoweb] Archives has no ice to install.")
				return

			# Optional: Corp may decline (default true when no method available)
			if iifa_optional:
				var iifa_dm_opt: Object = ctx.corp_decision_maker
				var iifa_will_use := true
				if iifa_dm_opt != null and iifa_dm_opt.has_method("choose_optional_ability"):
					iifa_will_use = await iifa_dm_opt.choose_optional_ability("Install 1 ice from Archives?", ctx)
				if not iifa_will_use:
					ctx.send_log("[Mycoweb] Corp declines to install ice from Archives.")
					return

			# Corp chooses which ice to install
			var iifa_dm: Object = ctx.corp_decision_maker
			var iifa_chosen_entry: Variant = null
			if iifa_dm != null and iifa_dm.has_method("choose_card_from_hand"):
				iifa_chosen_entry = await iifa_dm.choose_card_from_hand(iifa_candidates, ctx)
			else:
				iifa_chosen_entry = iifa_candidates[0]

			if iifa_chosen_entry == null:
				return

			var iifa_record: CardRecord = (iifa_chosen_entry as Dictionary).get("card_record", null) as CardRecord
			if iifa_record == null:
				return

			ctx.corp_discard.erase(iifa_record)
			var iifa_server: Server = ctx.get_server(ctx.run_target_server)
			if iifa_server == null:
				iifa_server = ctx.create_remote_server()
			if iifa_server != null:
				var iifa_installed := InstalledCard.make_runtime_instance(iifa_record, iifa_server.server_id, "ice", false)
				iifa_server.install_ice(iifa_installed)
				ctx.send_log("[Mycoweb] %s installs %s from Archives on %s (ignoring costs)." % [
					ctx.corp_name(), iifa_record.title, iifa_server.display_name()
				])

		# ── Mycoweb sub 2: rez installed ice at a credit discount ─────────────────

		"rez_ice_discounted":
			# Corp may rez 1 unrezzed installed ice, paying N credits less.
			# Uses run_modifiers["extra_rez_cost"] (negative = discount) and calls RSM._rez_card.
			# params: { "discount": int, "optional": bool }
			var rid_discount: int  = params.get("discount", 2)
			var rid_optional: bool = params.get("optional", true)

			# Collect all unrezzed installed ice across all servers
			var rid_candidates: Array = []
			for rid_srv in ctx.servers.values():
				for rid_c in (rid_srv as Server).ice:
					var rid_ic: InstalledCard = rid_c as InstalledCard
					if not rid_ic.is_rezzed:
						rid_candidates.append(rid_ic)

			if rid_candidates.is_empty():
				ctx.send_log("[Mycoweb] No unrezzed ice to rez.")
				return

			# Optional: Corp may decline
			if rid_optional:
				var rid_dm_opt: Object = ctx.corp_decision_maker
				var rid_will_use := true
				if rid_dm_opt != null and rid_dm_opt.has_method("choose_optional_ability"):
					rid_will_use = await rid_dm_opt.choose_optional_ability(
						"Rez 1 ice at %d[credit] discount?" % rid_discount, ctx)
				if not rid_will_use:
					ctx.send_log("[Mycoweb] Corp declines discounted rez.")
					return

			# Corp chooses which ice to rez; default heuristic: most expensive (best discount value)
			var rid_target: InstalledCard = rid_candidates[0] as InstalledCard
			var rid_dm: Object = ctx.corp_decision_maker
			if rid_dm != null and rid_dm.has_method("choose_derez_target"):
				# choose_derez_target picks one InstalledCard from a list — reused here for selection
				rid_target = await rid_dm.choose_derez_target(rid_candidates, ctx)
			else:
				# Inline fallback: pick the most expensive unrezzed ice
				for rid_ic in rid_candidates:
					var rid_c: InstalledCard = rid_ic as InstalledCard
					if rid_c.card_record != null and rid_target.card_record != null:
						if rid_c.card_record.cost > rid_target.card_record.cost:
							rid_target = rid_c

			if rid_target == null:
				return

			# Apply discount via run_modifiers, rez via RSM, then clear the modifier
			ctx.run_modifiers["extra_rez_cost"] = -rid_discount
			if ctx.has_meta("run_state_machine"):
				var rid_rsm: Object = ctx.get_meta("run_state_machine")
				await rid_rsm._rez_card(rid_target)
			ctx.run_modifiers.erase("extra_rez_cost")

		# ── Mycoweb subs 3 & 4: resolve a subroutine on a rezzed ice of a subtype ─

		"resolve_sub_on_rezzed_ice_of_subtype":
			# Corp picks a rezzed ice matching 'subtype', then picks one of its subroutines
			# to resolve (bypassing break windows — this is a direct Corp trigger).
			# params: { "subtype": String, "exclude_card_id": String (optional) }
			var rsris_subtype: String = params.get("subtype", "sentry")
			var rsris_exclude: String = params.get("exclude_card_id", "")

			# Collect rezzed ice of the matching subtype, excluding any by card_id if requested
			var rsris_candidates: Array = []
			for rsris_srv in ctx.servers.values():
				for rsris_c in (rsris_srv as Server).ice:
					var rsris_ic: InstalledCard = rsris_c as InstalledCard
					if not rsris_ic.is_rezzed:
						continue
					if rsris_exclude != "" and rsris_ic.card_id == rsris_exclude:
						continue
					if rsris_ic.has_effective_subtype(rsris_subtype):
						rsris_candidates.append(rsris_ic)

			if rsris_candidates.is_empty():
				ctx.send_log("[Mycoweb] No rezzed %s found to trigger." % rsris_subtype)
				return

			# Corp chooses which ice to target (default: first candidate)
			var rsris_target: InstalledCard = rsris_candidates[0] as InstalledCard
			var rsris_dm: Object = ctx.corp_decision_maker
			if rsris_dm != null and rsris_dm.has_method("choose_derez_target"):
				rsris_target = await rsris_dm.choose_derez_target(rsris_candidates, ctx)

			if rsris_target == null:
				return

			# Fetch the subroutine list for the chosen ice via ability_registry
			var rsris_subs: Array = []
			if ctx.has_meta("ability_registry"):
				var rsris_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				rsris_subs = rsris_ab_reg.get_subroutines_for_card(rsris_target.card_id, rsris_target)

			if rsris_subs.is_empty():
				ctx.send_log("[Mycoweb] %s has no implemented subroutines." % rsris_target.display_name())
				return

			# Corp chooses which subroutine to resolve (default: index 0)
			var rsris_sub_idx: int = 0
			if rsris_subs.size() > 1 and rsris_dm != null and rsris_dm.has_method("choose_modes"):
				var rsris_modes: Array = []
				for rsris_s in rsris_subs:
					rsris_modes.append({"label": (rsris_s as Dictionary).get("label", "Subroutine")})
				var rsris_choice: Array = await rsris_dm.choose_modes(rsris_modes, 1, ctx)
				if not rsris_choice.is_empty():
					rsris_sub_idx = rsris_choice[0]

			var rsris_chosen_sub: Dictionary = rsris_subs[rsris_sub_idx] as Dictionary
			ctx.send_log("[Mycoweb] Corp fires subroutine %d of %s: %s" % [
				rsris_sub_idx, rsris_target.display_name(),
				rsris_chosen_sub.get("label", "?")
			])
			await execute_subroutine(rsris_chosen_sub, ctx)

		# ── Mitra Aman: swap approached ice with ice on HQ or Archives ───────────

		"swap_approached_ice_with_central":
			# Swap the ice currently being approached (from current_event_data["ice"])
			# with a piece of installed ice on HQ or Archives.
			# After the swap, stores the swapped-in ice in ctx meta so that
			# RunStateMachine._phase_approach_ice can update its snapshot pointer.
			var saic_approached: InstalledCard = \
				ctx.current_event_data.get("ice", null) as InstalledCard
			if saic_approached == null:
				push_error("AbilityInterpreter: swap_approached_ice_with_central — no ice in event data")
				return

			# Gather all ice installed on HQ and Archives
			var saic_candidates: Array = []
			for saic_sid in ["hq", "archives"]:
				var saic_srv: Server = ctx.get_server(saic_sid) as Server
				if saic_srv != null:
					for saic_c in saic_srv.ice:
						saic_candidates.append(saic_c)

			if saic_candidates.is_empty():
				ctx.send_log("Mitra Aman: no installed ice on HQ or Archives — swap skipped.")
				return

			# Corp chooses which ice to swap in
			var saic_chosen: InstalledCard = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var saic_modes: Array = []
				for saic_c in saic_candidates:
					var saic_ic: InstalledCard = saic_c as InstalledCard
					var saic_src: Server = ctx.get_server(saic_ic.server_id) as Server
					var saic_src_name: String = saic_src.display_name() if saic_src else saic_ic.server_id
					saic_modes.append({
						"label": "%s (%s)" % [saic_ic.display_name(), saic_src_name]
					})
				var saic_result: Array = \
					await ctx.corp_decision_maker.choose_modes(saic_modes, 1, ctx)
				if not saic_result.is_empty():
					saic_chosen = saic_candidates[saic_result[0]] as InstalledCard
			else:
				saic_chosen = saic_candidates[0] as InstalledCard

			if saic_chosen == null:
				return

			# Locate both ice in their respective server arrays
			var saic_old_srv: Server = ctx.get_server(saic_approached.server_id) as Server
			var saic_new_srv: Server = ctx.get_server(saic_chosen.server_id) as Server
			var saic_old_pos: int    = saic_old_srv.ice.find(saic_approached) if saic_old_srv else -1
			var saic_new_pos: int    = saic_new_srv.ice.find(saic_chosen)     if saic_new_srv else -1

			if saic_old_pos < 0 or saic_new_pos < 0:
				push_error("AbilityInterpreter: swap_approached_ice_with_central — ice not found in server array")
				return

			# Perform physical swap and update server_id on each card
			saic_old_srv.ice[saic_old_pos] = saic_chosen
			saic_chosen.server_id          = saic_old_srv.server_id
			saic_new_srv.ice[saic_new_pos] = saic_approached
			saic_approached.server_id      = saic_new_srv.server_id

			ctx.send_log("Mitra Aman: %s moved to %s; %s moved to %s." % [
				saic_chosen.display_name(),    saic_old_srv.display_name(),
				saic_approached.display_name(), saic_new_srv.display_name()
			])

			# Signal RunStateMachine to update its _ice_positions snapshot at the
			# current index so the runner now approaches the swapped-in ice.
			ctx.set_meta("run_ice_swapped", saic_chosen)

		# ── Sabotage ──────────────────────────────────────────────────────────────

		"sabotage":
			# The Corp trashes N cards of their choice from HQ and/or the top of R&D.
			# params: { "amount": int }
			var sab_amount: int = params.get("amount", 1)
			ctx.send_log("[Sabotage %d] %s must trash %d card(s) from HQ or R&D." % [
				sab_amount, ctx.corp_name(), sab_amount
			])
			for _sab_i in range(sab_amount):
				if ctx.corp_hand.is_empty() and ctx.corp_deck.is_empty():
					ctx.send_log("[Sabotage] %s has no cards remaining." % ctx.corp_name())
					break

				var sab_choice: Dictionary = {}
				if ctx.corp_decision_maker != null and \
						ctx.corp_decision_maker.has_method("choose_sabotage_discard"):
					sab_choice = await ctx.corp_decision_maker.choose_sabotage_discard(ctx)
				else:
					# Default: trash cheapest non-agenda from HQ; fallback to R&D
					sab_choice = _sabotage_default_choice(ctx)

				var sab_source: String = sab_choice.get("source", "rd")
				if sab_source == "hq":
					var sab_cr: CardRecord = sab_choice.get("card_record", null) as CardRecord
					var sab_found := false
					for sab_j in range(ctx.corp_hand.size()):
						if ctx.corp_hand[sab_j].get("card_record") == sab_cr:
							ctx.corp_hand.remove_at(sab_j)
							ctx.corp_discard.append(sab_cr)
							ctx.send_log("[Sabotage] %s trashes %s from HQ." % [
								ctx.corp_name(), sab_cr.title
							])
							sab_found = true
							break
					if not sab_found:
						sab_source = "rd"   # card not in hand — fall through to R&D

				if sab_source == "rd":
					if not ctx.corp_deck.is_empty():
						var sab_top: CardRecord = ctx.corp_deck.pop_front()
						ctx.corp_discard.append(sab_top)
						ctx.send_log("[Sabotage] %s trashes top of R&D: %s." % [
							ctx.corp_name(), sab_top.title
						])
					elif not ctx.corp_hand.is_empty():
						# R&D empty — must trash from HQ as a last resort
						var sab_fb: Dictionary = ctx.corp_hand.pop_front()
						var sab_fb_cr: CardRecord = sab_fb.get("card_record") as CardRecord
						if sab_fb_cr != null:
							ctx.corp_discard.append(sab_fb_cr)
							ctx.send_log("[Sabotage] R&D empty — %s trashes %s from HQ." % [
								ctx.corp_name(), sab_fb_cr.title
							])

		# ── Optional counter spend (e.g. Cacophony end-of-turn) ──────────────────

		"optional_spend_counters":
			# Runner may spend N counters of a given type on this card to fire an effect.
			# params: { "counter": str, "cost": int, "prompt": str, "effects": Array }
			var osc_counter: String = params.get("counter", "power")
			var osc_cost:    int    = params.get("cost", 0)
			var osc_prompt:  String = params.get("prompt", "Spend %d %s counter(s)?" % [osc_cost, osc_counter])
			var osc_effects: Array  = params.get("effects", []) as Array

			var osc_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var osc_card: InstalledCard = ctx.get_installed_card_by_instance_id(osc_iid)
			if osc_card == null:
				return
			if osc_card.get_counter(osc_counter) < osc_cost:
				return   # not enough counters

			# Ask the runner (or use a default) whether to activate
			var osc_activate := false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_optional_ability"):
				osc_activate = await ctx.runner_decision_maker.choose_optional_ability(osc_prompt, ctx)
			else:
				osc_activate = true   # default: activate when counters are available

			if not osc_activate:
				ctx.send_log("%s declines." % osc_card.display_name())
				return

			osc_card.remove_counter(osc_counter, osc_cost)
			ctx.send_log("%s spends %d %s counter(s) (%d remaining)." % [
				osc_card.display_name(), osc_cost, osc_counter,
				osc_card.get_counter(osc_counter)
			])
			for osc_eff in osc_effects:
				await _execute_effect(osc_eff as Dictionary, ctx, null)

		"install_from_heap":
			var ifh_types: Array = params.get("card_types", []) as Array
			var ifh_candidates: Array = []
			for ifh_r in ctx.runner_discard:
				var ifh_record: CardRecord = ifh_r as CardRecord
				if ifh_record == null:
					continue
				if ifh_types.is_empty() or ifh_types.has(ifh_record.card_type):
					ifh_candidates.append(ifh_record)
			if ifh_candidates.is_empty():
				ctx.send_log("Scrounge: no eligible cards in heap.")
				return
			var ifh_chosen: CardRecord = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_heap"):
				ifh_chosen = await ctx.runner_decision_maker.choose_from_heap(ifh_candidates, ctx)
			else:
				ifh_chosen = ifh_candidates[0]
			if ifh_chosen == null:
				ctx.send_log("Scrounge: no program chosen.")
				return
			var ifh_cost: int = max(0, ifh_chosen.cost)
			# DZMZ Optimizer discount for programs
			if ifh_chosen.card_type == "program" and not ctx.runner_program_install_discounted_this_turn:
				for ifh_rig_c in ctx.runner_rig:
					var ifh_c: InstalledCard = ifh_rig_c as InstalledCard
					if ifh_c != null and ifh_c.card_id == "dzmz_optimizer":
						ifh_cost = max(0, ifh_cost - 1)
						ctx.runner_program_install_discounted_this_turn = true
						ctx.send_log("DZMZ Optimizer: heap install costs 1 less (now %d¢)." % ifh_cost)
						break
			# MU check for programs
			if ifh_chosen.card_type == "program" and ifh_chosen.memory_cost > 0:
				if ctx.runner_mu_available() < ifh_chosen.memory_cost:
					ctx.send_log("Scrounge: not enough MU for %s — cannot install." % ifh_chosen.title)
					return
			if ctx.runner_credits < ifh_cost:
				ctx.send_log("Scrounge: cannot afford %s (costs %d¢)." % [ifh_chosen.title, ifh_cost])
				return
			ctx.runner_credits -= ifh_cost
			ctx.runner_discard.erase(ifh_chosen)
			var ifh_installed := InstalledCard.make_runtime_instance(ifh_chosen, "runner_rig", "root", true)
			ctx.runner_rig.append(ifh_installed)
			if ctx.has_meta("register_installed_card"):
				var ifh_reg: Callable = ctx.get_meta("register_installed_card") as Callable
				ifh_reg.call(ifh_installed)
			if ctx.has_meta("ability_registry"):
				var ifh_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var ifh_on_rez = ifh_ab_reg.get_on_rez(ifh_chosen.id)
				if ifh_on_rez != null:
					ctx.current_event_data = {"card": ifh_installed, "card_instance_id": ifh_installed.runtime_instance_id}
					await execute_trigger(ifh_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			if ifh_chosen.card_type == "program" and ifh_chosen.has_subtype("virus"):
				await ctx.notify_event("runner_installs_virus", {
					"card": ifh_installed,
					"card_instance_id": ifh_installed.runtime_instance_id
				}, self)
			ctx.send_log("Scrounge: %s installs %s from heap for %d¢. [MU: %d/%d]" % [
				ctx.runner_name(), ifh_chosen.title, ifh_cost,
				ctx.runner_mu_used(), ctx.runner_total_mu()
			])

		"return_heap_card_to_stack":
			var rhcs_types: Array = params.get("card_types", []) as Array
			var rhcs_opt: bool    = params.get("optional", true)
			var rhcs_candidates: Array = []
			for rhcs_r in ctx.runner_discard:
				var rhcs_record: CardRecord = rhcs_r as CardRecord
				if rhcs_record == null:
					continue
				if rhcs_types.is_empty() or rhcs_types.has(rhcs_record.card_type):
					rhcs_candidates.append(rhcs_record)
			if rhcs_candidates.is_empty():
				ctx.send_log("Scrounge: no more eligible cards in heap to return.")
				return
			var rhcs_chosen: CardRecord = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_heap"):
				rhcs_chosen = await ctx.runner_decision_maker.choose_from_heap(rhcs_candidates, ctx)
			elif not rhcs_opt:
				rhcs_chosen = rhcs_candidates[0]
			if rhcs_chosen == null:
				ctx.send_log("Scrounge: runner declines to return a program to stack.")
				return
			ctx.runner_discard.erase(rhcs_chosen)
			ctx.runner_deck.push_back(rhcs_chosen)
			ctx.send_log("Scrounge: %s returns %s to the bottom of their stack." % [
				ctx.runner_name(), rhcs_chosen.title
			])

		"install_from_grip_discounted":
			var ifgd_require_success: bool = params.get("requires_successful_run", false)
			if ifgd_require_success and not ctx.run_successful:
				ctx.send_log("Illumination: run was not successful — no installation.")
				return
			var ifgd_max: int   = params.get("max_installs", 3)
			var ifgd_disc: int  = params.get("discount_per_card", 1)
			var ifgd_count: int = 0
			for _ifgd_i in range(ifgd_max):
				var ifgd_installable: Array = []
				for ifgd_entry in ctx.runner_hand:
					var ifgd_e: Dictionary = ifgd_entry as Dictionary
					var ifgd_r: CardRecord = ifgd_e.get("card_record", null) as CardRecord
					if ifgd_r == null:
						continue
					if ifgd_r.card_type not in ["program", "hardware", "resource"]:
						continue
					var ifgd_cost: int = max(0, ifgd_r.cost - ifgd_disc)
					if ctx.runner_credits < ifgd_cost:
						continue
					if ifgd_r.card_type == "program" and ifgd_r.memory_cost > 0:
						if ctx.runner_mu_available() < ifgd_r.memory_cost:
							continue
					ifgd_installable.append(ifgd_entry)
				if ifgd_installable.is_empty():
					if ifgd_count == 0:
						ctx.send_log("Illumination: no cards in grip that can be installed.")
					else:
						ctx.send_log("Illumination: no further cards can be installed.")
					break
				var ifgd_chosen_entry: Variant = null
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_hand"):
					ifgd_chosen_entry = await ctx.runner_decision_maker.choose_card_from_hand(ifgd_installable, ctx)
				else:
					ifgd_chosen_entry = ifgd_installable[0]
				if ifgd_chosen_entry == null:
					ctx.send_log("Illumination: runner done installing.")
					break
				var ifgd_record: CardRecord = (ifgd_chosen_entry as Dictionary).get("card_record", null) as CardRecord
				if ifgd_record == null:
					break
				var ifgd_pay: int = max(0, ifgd_record.cost - ifgd_disc)
				ctx.runner_credits -= ifgd_pay
				ctx.runner_hand.erase(ifgd_chosen_entry)
				var ifgd_installed := InstalledCard.make_runtime_instance(ifgd_record, "runner_rig", "root", true)
				ctx.runner_rig.append(ifgd_installed)
				if ctx.has_meta("register_installed_card"):
					var ifgd_reg: Callable = ctx.get_meta("register_installed_card") as Callable
					ifgd_reg.call(ifgd_installed)
				if ctx.has_meta("ability_registry"):
					var ifgd_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
					var ifgd_on_rez = ifgd_ab_reg.get_on_rez(ifgd_record.id)
					if ifgd_on_rez != null:
						ctx.current_event_data = {"card": ifgd_installed, "card_instance_id": ifgd_installed.runtime_instance_id}
						await execute_trigger(ifgd_on_rez as Dictionary, ctx)
						ctx.current_event_data = {}
				if ifgd_record.card_type == "program" and ifgd_record.has_subtype("virus"):
					await ctx.notify_event("runner_installs_virus", {
						"card": ifgd_installed,
						"card_instance_id": ifgd_installed.runtime_instance_id
					}, self)
				ifgd_count += 1
				ctx.send_log("Illumination: %s installs %s for %d¢ (%d/%d). [MU: %d/%d]" % [
					ctx.runner_name(), ifgd_record.title, ifgd_pay,
					ifgd_count, ifgd_max, ctx.runner_mu_used(), ctx.runner_total_mu()
				])
			if ifgd_count > 0:
				ctx.send_log("Illumination: %s installed %d card(s)." % [ctx.runner_name(), ifgd_count])

		"charm_offensive_trash_rezzed_copy":
			var cotrc_accessed: Array = ctx.run_accessed_archives_card_ids
			if cotrc_accessed.is_empty():
				ctx.send_log("Charm Offensive: no cards were accessed in Archives.")
				return
			var cotrc_candidates: Array = []
			for cotrc_server in ctx.servers.values():
				var cotrc_s: Server = cotrc_server as Server
				if cotrc_s == null:
					continue
				for cotrc_root in cotrc_s.root:
					var cotrc_c: InstalledCard = cotrc_root as InstalledCard
					if cotrc_c != null and cotrc_c.is_rezzed and cotrc_c.card_record != null:
						if cotrc_c.card_id in cotrc_accessed:
							cotrc_candidates.append(cotrc_c)
				for cotrc_ice in cotrc_s.ice:
					var cotrc_c: InstalledCard = cotrc_ice as InstalledCard
					if cotrc_c != null and cotrc_c.is_rezzed and cotrc_c.card_record != null:
						if cotrc_c.card_id in cotrc_accessed:
							cotrc_candidates.append(cotrc_c)
			if cotrc_candidates.is_empty():
				ctx.send_log("Charm Offensive: no rezzed copies of accessed cards found.")
				return
			var cotrc_chosen: InstalledCard = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var cotrc_modes: Array = []
				for cotrc_c in cotrc_candidates:
					var cotrc_ic: InstalledCard = cotrc_c as InstalledCard
					cotrc_modes.append({"label": "Trash %s" % cotrc_ic.display_name()})
				cotrc_modes.append({"label": "Pass"})
				var cotrc_result: Array = await ctx.runner_decision_maker.choose_modes(cotrc_modes, 1, ctx)
				if not cotrc_result.is_empty():
					var cotrc_idx: int = cotrc_result[0]
					if cotrc_idx < cotrc_candidates.size():
						cotrc_chosen = cotrc_candidates[cotrc_idx] as InstalledCard
			else:
				cotrc_chosen = cotrc_candidates[0] as InstalledCard   # AI default: always trash
			if cotrc_chosen == null:
				ctx.send_log("Charm Offensive: runner declines to trash.")
				return
			var cotrc_srv: Server = ctx.get_server(cotrc_chosen.server_id)
			if cotrc_srv != null:
				if cotrc_chosen.zone == "ice":
					cotrc_srv.remove_ice(cotrc_chosen)
				else:
					cotrc_srv.remove_from_root(cotrc_chosen)
				ctx.remove_empty_remote_servers()
			ctx.unregister_all_card_effects(cotrc_chosen.runtime_instance_id)
			if cotrc_chosen.card_record != null:
				ctx.corp_discard.append(cotrc_chosen.card_record)
			ctx.send_log("Charm Offensive: %s trashes %s." % [ctx.runner_name(), cotrc_chosen.display_name()])

		# ── Identity flip ────────────────────────────────────────────────────────

		"flip_identity":
			# Flip a dual-faced identity to its other face.
			# params:
			#   face         : "runner" | "corp"
			#   flip_to      : String  — abilities.json key for the new face
			#   flip_title   : String  — display title of the new face (full "Name: Subtitle" form)
			#   condition    : String? — "mu_full" | "mu_has_unused" | "server_is_hq_or_rd" |
			#                            "corp_played_operation" | "" (no condition)
			#   optional     : bool    — if true, ask the runner before flipping
			#   on_flip      : Array   — sub-effects to execute after flip succeeds
			var fi_face:      String = params.get("face",       "runner")
			var fi_flip_to:   String = params.get("flip_to",    "")
			var fi_flip_title:String = params.get("flip_title", "")
			var fi_condition: String = params.get("condition",  "")
			var fi_optional:  bool   = params.get("optional",   false)
			var fi_on_flip:   Array  = params.get("on_flip",    []) as Array

			if fi_flip_to == "":
				push_error("flip_identity: flip_to not specified")
				return

			# ── Condition check ──────────────────────────────────────────────
			match fi_condition:
				"mu_full":
					if ctx.runner_mu_available() != 0:
						return   # condition not met
				"mu_has_unused":
					if ctx.runner_mu_available() < 1:
						return
				"server_is_hq_or_rd":
					var fi_server_id: String = ctx.current_event_data.get("server_id", "")
					if fi_server_id not in ["hq", "rd"]:
						return
				"corp_played_operation":
					if not ctx.corp_played_operation_this_turn:
						return
				_:
					pass  # no condition (or unrecognised — treat as always met)

			# ── Optional check ───────────────────────────────────────────────
			if fi_optional:
				var fi_want_flip: bool = false
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_flip_identity"):
					fi_want_flip = await ctx.runner_decision_maker.choose_flip_identity(fi_flip_title, ctx)
				else:
					fi_want_flip = true   # AI default: always flip
				if not fi_want_flip:
					ctx.send_log("Identity flip declined.")
					return

			# ── Perform flip ─────────────────────────────────────────────────
			if not ctx.has_meta("reregister_identity"):
				push_error("flip_identity: reregister_identity callable missing from ctx")
				return
			var fi_reregister: Callable = ctx.get_meta("reregister_identity") as Callable
			var fi_instance_id: String = "identity_runner" if fi_face == "runner" else "identity_corp"
			if fi_face == "runner":
				ctx.runner_identity_face_title = fi_flip_title
			else:
				ctx.corp_identity_face_title = fi_flip_title
			fi_reregister.call(fi_instance_id, fi_flip_to)
			ctx.send_log("Identity flip: now playing as %s." % fi_flip_title)

			# ── on_flip sub-effects ──────────────────────────────────────────
			for fi_eff in fi_on_flip:
				await _execute_effect(fi_eff as Dictionary, ctx, null)

		# ── Faceup card hosting effects ───────────────────────────────────────────

		"host_top_of_stack_faceup":
			# Bling: trigger on runner_installs_card event; only fires when credits_paid == 0.
			var htsf_only_free: bool = params.get("only_if_free", true)
			if htsf_only_free:
				var htsf_paid: int = ctx.current_event_data.get("credits_paid", -1) as int
				if htsf_paid != 0:
					return
			# Find the Bling InstalledCard via event card_instance_id
			var htsf_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var htsf_host: InstalledCard = ctx.get_installed_card_by_instance_id(htsf_iid)
			if htsf_host == null:
				ctx.send_log("host_top_of_stack_faceup: host card not found.")
				return
			if ctx.runner_deck.is_empty():
				ctx.send_log("%s: stack is empty — nothing to host." % htsf_host.display_name())
				return
			var htsf_card: CardRecord = ctx.runner_deck.pop_front() as CardRecord
			htsf_host.faceup_hosted_cards.append(htsf_card)
			ctx.send_log("%s: %s hosts %s faceup from top of stack." % [
				ctx.runner_name(), htsf_host.display_name(), htsf_card.title
			])

		"trash_faceup_hosted_cards":
			# Bling: at start of runner's turn, trash all hosted cards.
			var tfhc_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var tfhc_host: InstalledCard = ctx.get_installed_card_by_instance_id(tfhc_iid)
			if tfhc_host == null or tfhc_host.faceup_hosted_cards.is_empty():
				return
			for tfhc_cr in tfhc_host.faceup_hosted_cards:
				var tfhc_r: CardRecord = tfhc_cr as CardRecord
				if tfhc_r != null:
					ctx.runner_discard.append(tfhc_r)
					ctx.send_log("%s: trashing hosted %s." % [tfhc_host.display_name(), tfhc_r.title])
			tfhc_host.faceup_hosted_cards.clear()

		"host_programs_from_grip_and_optionally_install":
			# Madani click action: choose programs from grip to stage, then optionally install one.
			var hpfg_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var hpfg_host: InstalledCard = ctx.get_installed_card_by_instance_id(hpfg_iid)
			if hpfg_host == null:
				ctx.send_log("Madani: host card not found.")
				return
			# Gather programs from hand
			var hpfg_programs: Array = []
			for hpfg_entry in ctx.runner_hand:
				var hpfg_e: Dictionary = hpfg_entry as Dictionary
				var hpfg_r: CardRecord = hpfg_e.get("card_record", null) as CardRecord
				if hpfg_r != null and hpfg_r.card_type == "program":
					hpfg_programs.append(hpfg_entry)
			if hpfg_programs.is_empty():
				ctx.send_log("Madani: no programs in grip to host.")
				return
			# Ask runner to choose programs to stage (may choose multiple)
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_programs_to_host"):
				var hpfg_chosen: Array = await ctx.runner_decision_maker.choose_programs_to_host(hpfg_programs, ctx)
				for hpfg_choice in hpfg_chosen:
					var hpfg_entry: Dictionary = hpfg_choice as Dictionary
					var hpfg_cr: CardRecord = hpfg_entry.get("card_record", null) as CardRecord
					if hpfg_cr == null:
						continue
					ctx.runner_hand.erase(hpfg_choice)
					hpfg_host.faceup_hosted_cards.append(hpfg_cr)
					ctx.send_log("Madani: %s stages %s." % [ctx.runner_name(), hpfg_cr.title])
			else:
				# AI default: stage all programs
				for hpfg_entry in hpfg_programs:
					var hpfg_cr: CardRecord = (hpfg_entry as Dictionary).get("card_record", null) as CardRecord
					if hpfg_cr == null:
						continue
					ctx.runner_hand.erase(hpfg_entry)
					hpfg_host.faceup_hosted_cards.append(hpfg_cr)
					ctx.send_log("Madani: %s stages %s." % [ctx.runner_name(), hpfg_cr.title])
			# Optional install: pick one hosted program to install now
			if hpfg_host.faceup_hosted_cards.is_empty():
				return
			var hpfg_installable: Array = []
			for hpfg_cr in hpfg_host.faceup_hosted_cards:
				var hpfg_r: CardRecord = hpfg_cr as CardRecord
				if hpfg_r == null:
					continue
				var hpfg_cost: int = max(0, hpfg_r.cost)
				if hpfg_r.memory_cost > 0 and ctx.runner_mu_available() < hpfg_r.memory_cost:
					continue
				if ctx.runner_credits >= hpfg_cost:
					hpfg_installable.append(hpfg_r)
			if hpfg_installable.is_empty():
				ctx.send_log("Madani: no hosted programs can be afforded or fit in MU.")
				return
			var hpfg_to_install: CardRecord = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_heap"):
				hpfg_to_install = await ctx.runner_decision_maker.choose_from_heap(hpfg_installable, ctx)
			else:
				hpfg_to_install = hpfg_installable[0]
			if hpfg_to_install == null:
				ctx.send_log("Madani: runner declines to install a hosted program.")
				return
			var hpfg_pay: int = max(0, hpfg_to_install.cost)
			# DZMZ discount
			if not ctx.runner_program_install_discounted_this_turn:
				for hpfg_rig_c in ctx.runner_rig:
					var hpfg_c: InstalledCard = hpfg_rig_c as InstalledCard
					if hpfg_c != null and hpfg_c.card_id == "dzmz_optimizer":
						hpfg_pay = max(0, hpfg_pay - 1)
						ctx.runner_program_install_discounted_this_turn = true
						ctx.send_log("DZMZ Optimizer: Madani install costs 1 less (now %d¢)." % hpfg_pay)
						break
			ctx.runner_credits -= hpfg_pay
			hpfg_host.faceup_hosted_cards.erase(hpfg_to_install)
			var hpfg_installed := InstalledCard.make_runtime_instance(hpfg_to_install, "runner_rig", "root", true)
			ctx.runner_rig.append(hpfg_installed)
			if ctx.has_meta("register_installed_card"):
				var hpfg_reg: Callable = ctx.get_meta("register_installed_card") as Callable
				hpfg_reg.call(hpfg_installed)
			if ctx.has_meta("ability_registry"):
				var hpfg_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var hpfg_on_rez = hpfg_ab_reg.get_on_rez(hpfg_to_install.id)
				if hpfg_on_rez != null:
					ctx.current_event_data = {"card": hpfg_installed, "card_instance_id": hpfg_installed.runtime_instance_id}
					await execute_trigger(hpfg_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			if hpfg_to_install.has_subtype("virus"):
				await ctx.notify_event("runner_installs_virus", {
					"card": hpfg_installed,
					"card_instance_id": hpfg_installed.runtime_instance_id
				}, self)
			await ctx.notify_event("runner_installs_card", {
				"credits_paid": hpfg_pay,
				"card": hpfg_installed,
				"card_instance_id": hpfg_installed.runtime_instance_id
			}, self)
			ctx.send_log("Madani: %s installs %s for %d¢. [MU: %d/%d]" % [
				ctx.runner_name(), hpfg_to_install.title, hpfg_pay,
				ctx.runner_mu_used(), ctx.runner_total_mu()
			])

		"host_random_hq_card":
			# Détente: on first successful HQ run, take 1 random HQ card faceup (not installed/rezzed).
			var hrhc_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var hrhc_host: InstalledCard = ctx.get_installed_card_by_instance_id(hrhc_iid)
			if hrhc_host == null:
				ctx.send_log("Détente: host card not found.")
				return
			if ctx.corp_hand.is_empty():
				ctx.send_log("Détente: HQ is empty — nothing to host.")
				return
			var hrhc_idx: int = randi() % ctx.corp_hand.size()
			var hrhc_entry: Dictionary = ctx.corp_hand[hrhc_idx] as Dictionary
			var hrhc_cr: CardRecord = hrhc_entry.get("card_record", null) as CardRecord
			if hrhc_cr == null:
				return
			ctx.corp_hand.remove_at(hrhc_idx)
			hrhc_host.faceup_hosted_cards.append(hrhc_cr)
			ctx.send_log("Détente: %s takes %s from HQ faceup." % [ctx.runner_name(), hrhc_cr.title])

		"detente_trash_hosted_and_access_hq":
			# Détente click ability: return 2 hosted cards to HQ, then runner may access 1 random HQ card.
			var dtha_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var dtha_host: InstalledCard = ctx.get_installed_card_by_instance_id(dtha_iid)
			if dtha_host == null:
				ctx.send_log("Détente: host card not found.")
				return
			if dtha_host.faceup_hosted_cards.size() < 2:
				ctx.send_log("Détente: need at least 2 hosted cards to use this ability (have %d)." % dtha_host.faceup_hosted_cards.size())
				return
			# Return first 2 hosted cards to HQ (top)
			for _dtha_i in range(2):
				var dtha_cr: CardRecord = dtha_host.faceup_hosted_cards.pop_front() as CardRecord
				if dtha_cr == null:
					continue
				ctx.corp_hand.append({"card_id": dtha_cr.id, "card_record": dtha_cr})
				ctx.send_log("Détente: %s returned to HQ." % dtha_cr.title)
			# Access 1 random HQ card
			if not ctx.corp_hand.is_empty():
				var dtha_access_idx: int = randi() % ctx.corp_hand.size()
				var dtha_access_entry: Dictionary = ctx.corp_hand[dtha_access_idx] as Dictionary
				var dtha_access_cr: CardRecord = dtha_access_entry.get("card_record", null) as CardRecord
				if dtha_access_cr != null:
					ctx.send_log("Détente: %s accesses %s from HQ." % [ctx.runner_name(), dtha_access_cr.title])
					ctx.accessed_card_id = dtha_access_cr.id
					await ctx.notify_event("access_card", {"card_id": dtha_access_cr.id, "runtime_instance_id": ""}, self)
					# Steal agendas
					if dtha_access_cr.is_agenda():
						ctx.runner_score_area.append(dtha_access_cr)
						ctx.corp_hand.remove_at(dtha_access_idx)
						ctx.send_log("Détente: %s STEALS %s!" % [ctx.runner_name(), dtha_access_cr.title])
						await ctx.notify_event("runner_steals_agenda", {
							"agenda_id": dtha_access_cr.id,
							"agenda_points": dtha_access_cr.agenda_points
						}, self)
					else:
						ctx.send_log("Détente: %s is not an agenda — cannot be stolen." % dtha_access_cr.title)
			else:
				ctx.send_log("Détente: HQ is empty — no access.")

		"gamedragon_attach_to_icebreaker":
			# GAMEDRAGON Pro: on install and on turn start, may host self on a non-AI icebreaker.
			var gdati_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var gdati_self: InstalledCard = ctx.get_installed_card_by_instance_id(gdati_iid)
			if gdati_self == null:
				ctx.send_log("GAMEDRAGON Pro: card not found.")
				return
			# Gather non-AI icebreakers (not self)
			var gdati_candidates: Array = []
			for gdati_rig_c in ctx.runner_rig:
				var gdati_c: InstalledCard = gdati_rig_c as InstalledCard
				if gdati_c == null or gdati_c.card_record == null:
					continue
				if gdati_c.runtime_instance_id == gdati_iid:
					continue  # don't host on self
				var gdati_subtypes: Array = gdati_c.card_record.subtypes
				if gdati_subtypes.has("icebreaker") or \
				   gdati_subtypes.has("fracter") or gdati_subtypes.has("decoder") or \
				   gdati_subtypes.has("killer"):
					if not gdati_subtypes.has("ai"):
						gdati_candidates.append(gdati_c)
			if gdati_candidates.is_empty():
				ctx.send_log("GAMEDRAGON Pro: no eligible icebreakers to attach to.")
				return
			var gdati_chosen: InstalledCard = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_host_ice"):
				# Reuse choose_host_ice proxy for icebreaker selection
				gdati_chosen = await ctx.runner_decision_maker.choose_host_ice(ctx)
				# Verify the choice is actually an icebreaker candidate (not ice)
				if gdati_chosen != null and not gdati_candidates.has(gdati_chosen):
					gdati_chosen = gdati_candidates[0]
			if gdati_chosen == null:
				gdati_chosen = gdati_candidates[0]
			gdati_self.hosted_on_id = gdati_chosen.runtime_instance_id
			ctx.send_log("GAMEDRAGON Pro: attached to %s (+1 str; pumps persist this run)." % gdati_chosen.display_name())

		# ── Chromatophores: grant subtypes to host ice ───────────────────────────────

		"grant_subtypes_to_host_ice":
			# Fires on Chromatophores' on_rez: adds barrier, code_gate, sentry to the host ice's
			# extra_subtypes.  Reversed automatically when Chromatophores is trashed.
			var gst_subtypes: Array = params.get("subtypes", []) as Array
			var gst_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var gst_self: InstalledCard = ctx.get_installed_card_by_instance_id(gst_iid)
			if gst_self == null or gst_self.hosted_on_id == "":
				push_error("AbilityInterpreter: grant_subtypes_to_host_ice — no host ice found (iid=%s)" % gst_iid)
				return
			var gst_host := ctx.get_ice_by_instance_id(gst_self.hosted_on_id)
			if gst_host == null:
				push_error("AbilityInterpreter: grant_subtypes_to_host_ice — host ice not found (hosted_on_id=%s)" % gst_self.hosted_on_id)
				return
			for gst_st in gst_subtypes:
				var gst_normalized: String = (gst_st as String).to_lower().replace(" ", "_")
				if not gst_host.extra_subtypes.has(gst_normalized):
					gst_host.extra_subtypes.append(gst_normalized)
				if not gst_self.granted_subtypes_to_host.has(gst_normalized):
					gst_self.granted_subtypes_to_host.append(gst_normalized)
			ctx.send_log("%s: %s gains [%s] as additional subtypes." % [
				gst_self.display_name(), gst_host.display_name(), ", ".join(gst_subtypes)
			])

		# ── IP Enforcement: Corp takes agenda from Runner's score area ────────────

		"steal_agenda_from_runner_score":
			# Corp takes 1 agenda from the Runner's score area and adds it to their own.
			# Used by IP Enforcement (play only if Runner is tagged).
			if ctx.runner_score_area.is_empty():
				ctx.send_log("IP Enforcement: %s's score area is empty — no agenda to take." % ctx.runner_name())
				return

			# Corp decision maker picks which agenda to claim
			var safrs_candidates: Array = ctx.runner_score_area.duplicate()
			var safrs_chosen: CardRecord = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_from_runner_score"):
				safrs_chosen = await ctx.corp_decision_maker.choose_from_runner_score(safrs_candidates, ctx)
			else:
				# Default: pick the highest-value agenda (most swing)
				var safrs_best: CardRecord = safrs_candidates[0] as CardRecord
				for safrs_c in safrs_candidates:
					var safrs_cr: CardRecord = safrs_c as CardRecord
					if safrs_cr != null and safrs_cr.agenda_points > safrs_best.agenda_points:
						safrs_best = safrs_cr
				safrs_chosen = safrs_best

			if safrs_chosen == null:
				ctx.send_log("IP Enforcement: no agenda selected.")
				return

			# Transfer: Runner → Corp
			ctx.runner_score_area.erase(safrs_chosen)
			ctx.corp_score_area.append(safrs_chosen)
			# Create a synthetic InstalledCard so corp_score_area_cards stays in sync
			var safrs_ic := InstalledCard.make_runtime_instance(safrs_chosen, "corp_score_area", "root", true)
			ctx.corp_score_area_cards.append(safrs_ic)

			ctx.send_log("IP Enforcement: %s takes %s (%d pt%s) from %s's score area." % [
				ctx.corp_name(),
				safrs_chosen.title,
				safrs_chosen.agenda_points,
				"s" if safrs_chosen.agenda_points != 1 else "",
				ctx.runner_name()
			])

			# Fire corp_scores_agenda so listeners react (Malapert, Phat Gioan, etc.)
			await ctx.notify_event("corp_scores_agenda", {
				"agenda_id": safrs_chosen.id,
				"card_instance_id": safrs_ic.runtime_instance_id
			}, self)

			# Check Corp win
			if ctx.corp_agenda_points() >= ctx.agenda_points_to_win:
				ctx.send_log("%s wins via IP Enforcement!" % ctx.corp_name())
				ctx.game_over = true
				ctx.winner    = "corp"

		# ── Maintenance Access: set a server approach redirect ────────────────────

		"set_server_approach_redirect":
			# Stores a redirect in run_modifiers so that when the runner would approach
			# the 'from' server's root (after clearing all its ice), the RSM instead
			# changes the attacked server to 'to' and approaches it.
			# Maintenance Access: Run Archives; redirect to HQ when reaching Archives root.
			var ssr_from: String = params.get("from", "")
			var ssr_to: String   = params.get("to", "")
			if ssr_from == "" or ssr_to == "":
				push_error("AbilityInterpreter: set_server_approach_redirect missing 'from' or 'to'")
				return
			ctx.run_modifiers["server_approach_redirect"] = {"from": ssr_from, "to": ssr_to}
			ctx.send_log("Server approach redirect set: %s → %s (Maintenance Access)." % [
				ssr_from.to_upper(), ssr_to.to_upper()
			])

		# ── Proprionegation: move runner to outermost position of a server ────────

		"move_runner_to_outermost":
			# Corp paid ability (paw_action): during a run, move the runner to the outermost
			# position of the specified server.  The RSM checks run_modifiers["run_position_reset"]
			# after each PAW/encounter window and applies the reset.
			if not ctx.run_active:
				ctx.send_log("move_runner_to_outermost: no run active — ability has no effect.")
				return
			var mro_server_id: String = params.get("server_id", "archives")
			ctx.run_modifiers["run_position_reset"] = {"server_id": mro_server_id}
			var mro_server: Server = ctx.get_server(mro_server_id)
			var mro_name: String = mro_server.display_name() if mro_server != null else mro_server_id.to_upper()
			ctx.send_log("Proprionegation: Runner will be moved to the outermost position of %s." % mro_name)

		# ── Knickknack O'Brian: trash own installed card for credits + draw ─────────

		"trash_installed_for_credits_and_draw":
			# Runner may trash 1 of their installed cards (optionally excluding self)
			# and gain credits equal to the trashed card's printed install cost, then draw N.
			# params: { "optional": bool, "exclude_self": bool, "draw": int }
			var tifd_optional:  bool = params.get("optional", true)
			var tifd_excl_self: bool = params.get("exclude_self", true)
			var tifd_draw_n:    int  = params.get("draw", 1)

			# Build candidate list from runner rig, excluding self if requested.
			var tifd_self_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var tifd_candidates: Array = []
			for tifd_c in ctx.runner_rig:
				var tifd_ic: InstalledCard = tifd_c as InstalledCard
				if tifd_ic == null:
					continue
				if tifd_excl_self and tifd_ic.runtime_instance_id == tifd_self_iid:
					continue
				tifd_candidates.append(tifd_ic)
			# Also include programs hosted on ice (trojans, Chromatophores, etc.)
			for tifd_srv in ctx.servers.values():
				for tifd_ice in (tifd_srv as Server).ice:
					for tifd_hosted in (tifd_ice as InstalledCard).hosted_cards:
						var tifd_h: InstalledCard = tifd_hosted as InstalledCard
						if tifd_h == null:
							continue
						if tifd_excl_self and tifd_h.runtime_instance_id == tifd_self_iid:
							continue
						if not tifd_candidates.has(tifd_h):
							tifd_candidates.append(tifd_h)

			if tifd_candidates.is_empty():
				ctx.send_log("Knickknack O'Brian: no other installed cards to trash.")
				return

			# Optional gate: ask runner whether to activate at all.
			if tifd_optional:
				var tifd_want := false
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_optional_ability"):
					tifd_want = await ctx.runner_decision_maker.choose_optional_ability(
						"Knickknack O'Brian: trash an installed card to gain its printed cost in credits and draw 1?", ctx
					)
				else:
					tifd_want = true   # AI default: always sell a card
				if not tifd_want:
					ctx.send_log("Knickknack O'Brian: %s declines." % ctx.runner_name())
					return

			# Runner picks which card to sacrifice.
			var tifd_chosen: InstalledCard = null
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_trash_from_rig"):
				tifd_chosen = await ctx.runner_decision_maker.choose_trash_from_rig(tifd_candidates, ctx)
			if tifd_chosen == null:
				tifd_chosen = tifd_candidates[0] as InstalledCard

			if tifd_chosen == null or tifd_chosen.card_record == null:
				ctx.send_log("Knickknack O'Brian: no card chosen.")
				return

			var tifd_cost: int = max(0, tifd_chosen.card_record.cost)

			# Trash the chosen card.
			if tifd_chosen.hosted_on_id != "":
				# Trojan hosted on ice — clean up granted subtypes then remove from host.
				_cleanup_granted_subtypes(tifd_chosen, ctx)
				var tifd_host := ctx.get_ice_by_instance_id(tifd_chosen.hosted_on_id)
				if tifd_host != null:
					tifd_host.hosted_cards.erase(tifd_chosen)
			else:
				ctx.runner_rig.erase(tifd_chosen)
			ctx.runner_discard.append(tifd_chosen.card_record)
			ctx.unregister_all_card_effects(tifd_chosen.runtime_instance_id)
			ctx.send_log("Knickknack O'Brian: %s trashes %s (printed cost %d)." % [
				ctx.runner_name(), tifd_chosen.display_name(), tifd_cost
			])

			# Gain credits equal to printed install cost.
			if tifd_cost > 0:
				ctx.runner_credits += tifd_cost
				ctx.send_log("%s gains %d credits." % [ctx.runner_name(), tifd_cost])

			# Draw N cards.
			_draw_cards("runner", tifd_draw_n, ctx)

		# ── Semak-samun: end run unless runner suffers N damage ───────────────────

		"etr_unless_runner_suffers_damage":
			# Runner chooses: suffer N damage and continue the run, or end the run.
			var eurs_amount: int = params.get("amount", 3)
			var eurs_dtype: String = params.get("damage_type", "net")
			var eurs_take: bool = false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_suffer_damage_or_etr"):
				eurs_take = await ctx.runner_decision_maker.choose_suffer_damage_or_etr(
					eurs_amount, eurs_dtype, ctx
				)
			else:
				# AI default: take damage if grip is large enough to survive
				eurs_take = ctx.runner_hand.size() >= eurs_amount
			if eurs_take:
				ctx.send_log("Runner accepts %d %s damage to continue the run." % [eurs_amount, eurs_dtype])
				_deal_damage(eurs_dtype, eurs_amount, ctx)
			else:
				ctx.run_ended = true
				ctx.send_log("Runner ends the run (refuses %d %s damage)." % [eurs_amount, eurs_dtype])

		_:
			push_error("AbilityInterpreter: unknown effect type '%s'" % etype)


# ── Effect helpers ────────────────────────────────────────────────────────────

# Default heuristic for sabotage when no decision-maker method is available.
# Returns {"source": "hq", "card_record": cr} or {"source": "rd"}.
func _sabotage_default_choice(ctx: GameContext) -> Dictionary:
	# Prefer cheapest non-agenda from HQ — safe to lose, can't be stolen from Archives
	var best_cr: CardRecord = null
	var best_cost := 9999
	for hand_entry in ctx.corp_hand:
		var cr: CardRecord = hand_entry.get("card_record") as CardRecord
		if cr == null or cr.card_type == "agenda":
			continue
		if cr.cost < best_cost:
			best_cost = cr.cost
			best_cr = cr
	if best_cr != null:
		return {"source": "hq", "card_record": best_cr}
	# No non-agendas in HQ — trash top of R&D (unknown card, less predictably bad)
	if not ctx.corp_deck.is_empty():
		return {"source": "rd"}
	# R&D empty — must trash from HQ (even an agenda)
	if not ctx.corp_hand.is_empty():
		return {"source": "hq", "card_record": ctx.corp_hand[0].get("card_record") as CardRecord}
	return {}   # nothing to trash

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
	ctx.send_log("Runner takes %d %s damage." % [amount, damage_type])
	var trashed: int = 0
	var trashed_cards: Array = []
	for i in range(amount):
		if ctx.runner_hand.is_empty():
			ctx.send_log("%s is flatlined! (no cards remaining in grip)" % ctx.runner_name())
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
		ctx.send_log("  Trashed from grip: %s" % entry.get("card_id", "unknown"))
	ctx.send_log("%d card(s) trashed from %s's grip." % [trashed, ctx.runner_name()])
	# Core damage: permanently reduce maximum hand size by the amount actually dealt.
	if damage_type == "core" and trashed > 0 and not ctx.game_over:
		ctx.runner_core_damage_taken += trashed
		ctx.send_log("%s's maximum hand size permanently reduced to %d (core damage total: %d)." % [
			ctx.runner_name(), ctx.runner_max_hand_size(), ctx.runner_core_damage_taken
		])
		if ctx.runner_max_hand_size() < 0:
			ctx.send_log("%s is flatlined! (maximum hand size below 0 from core damage)" % ctx.runner_name())
			ctx.game_over = true
			ctx.winner    = "corp"
	return trashed_cards


# ── Forfeit helper ────────────────────────────────────────────────────────────
# Removes a scored agenda from corp_score_area, places it in corp_discard,
# fires the on_forfeit event, and executes any on_forfeit ability for that card.

func _forfeit_agenda(scored_agenda: InstalledCard, ctx: GameContext) -> void:
	var idx: int = -1
	for i in range(ctx.corp_score_area_cards.size()):
		if ctx.corp_score_area_cards[i] == scored_agenda:
			idx = i
			break
	if idx < 0:
		push_error("AbilityInterpreter._forfeit_agenda: card not found in corp score area")
		return
	var record: CardRecord = ctx.corp_score_area[idx] as CardRecord
	ctx.corp_score_area_cards.remove_at(idx)
	ctx.corp_score_area.remove_at(idx)
	if record != null:
		ctx.corp_discard.append(record)
	ctx.send_log("%s forfeits %s. (%d agenda point(s) remaining)" % [
		ctx.corp_name(), scored_agenda.display_name(), ctx.corp_agenda_points()
	])
	# Fire on_forfeit event for listeners
	await ctx.notify_event("on_forfeit", {
		"card": scored_agenda,
		"card_instance_id": scored_agenda.runtime_instance_id,
		"card_id": scored_agenda.card_id
	}, self)
	# Execute on_forfeit ability trigger (e.g. Greenmail gains 9cr)
	if ctx.has_meta("ability_registry"):
		var ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
		var on_forfeit_def = ab_reg.get_on_forfeit(scored_agenda.card_id)
		if on_forfeit_def != null:
			ctx.current_event_data = {
				"card": scored_agenda,
				"card_instance_id": scored_agenda.runtime_instance_id
			}
			await execute_trigger(on_forfeit_def as Dictionary, ctx)
			ctx.current_event_data = {}


func _derez_card(card: InstalledCard, ctx: GameContext) -> void:
	card.is_rezzed = false
	ctx.unregister_all_card_effects(card.runtime_instance_id)
	ctx.send_log("%s is derezzed." % card.display_name())
	await ctx.notify_event("on_derez", {
		"card": card,
		"card_instance_id": card.runtime_instance_id
	}, self)


func _cleanup_granted_subtypes(card: InstalledCard, ctx: GameContext) -> void:
	# If this program had granted subtypes to its host ice, remove them now.
	if card.granted_subtypes_to_host.is_empty() or card.hosted_on_id == "":
		return
	var host_ice := ctx.get_ice_by_instance_id(card.hosted_on_id)
	if host_ice == null:
		return
	for st in card.granted_subtypes_to_host:
		host_ice.extra_subtypes.erase(st)
	ctx.send_log("%s: removed granted subtypes [%s] from %s." % [
		card.display_name(), ", ".join(card.granted_subtypes_to_host), host_ice.display_name()
	])
	card.granted_subtypes_to_host.clear()


func _trash_installed_card(card: InstalledCard, ctx: GameContext) -> void:
	# If this is ice with hosted programs, trash those first
	if card.zone == "ice" and not card.hosted_cards.is_empty():
		for hosted in card.hosted_cards.duplicate():
			var h: InstalledCard = hosted as InstalledCard
			ctx.runner_rig.erase(h)
			ctx.unregister_all_card_effects(h.runtime_instance_id)
			ctx.send_log("  %s trashed (host ice removed)." % h.display_name())
		card.hosted_cards.clear()

	# Remove from runner rig or from host ice
	if card.hosted_on_id != "":
		# Clean up any subtypes this program granted to its host (e.g. Chromatophores)
		_cleanup_granted_subtypes(card, ctx)
		var host_ice := ctx.get_ice_by_instance_id(card.hosted_on_id)
		if host_ice != null:
			host_ice.hosted_cards.erase(card)
	else:
		ctx.runner_rig.erase(card)

	ctx.unregister_all_card_effects(card.runtime_instance_id)
	ctx.send_log("Trashed installed card: %s" % card.display_name())

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
			ctx.send_log("%s deck empty — cannot draw." % ctx.player_name(subject))
			break
		var card: CardRecord = deck.pop_front() as CardRecord
		hand.append({"card_id": card.id, "card_record": card})
		drawn += 1
	ctx.send_log("%s draws %d card(s)." % [ctx.player_name(subject), drawn])


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
		"break_self_sub":
			# N-Pot: runner pays cost credits to break one subroutine on the ice itself.
			var bss_cost:    int = action.get("cost", 3)
			var bss_idx:     int = action.get("sub_index", -1)
			if bss_idx < 0 or bss_idx >= encounter.subroutines.size():
				push_error("AbilityInterpreter: break_self_sub — invalid sub index %d" % bss_idx)
				return false
			if encounter.is_broken(bss_idx):
				ctx.send_log("[Encounter] Sub %d is already broken." % bss_idx)
				return false
			if ctx.runner_available_credits() < bss_cost:
				ctx.send_log("[Encounter] Cannot afford self-break (need %d)." % bss_cost)
				return false
			ctx.runner_credits -= bss_cost
			encounter.break_sub(bss_idx)
			var sub_label: String = (encounter.subroutines[bss_idx] as Dictionary).get("label", "sub %d" % bss_idx)
			ctx.send_log("[Encounter] %s spends %d cr to break '%s'." % [
				ctx.runner_name(), bss_cost, sub_label
			])
			return true
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

	# Run-event cost reduction (e.g. Sang Kancil: boost costs 2cr less when run event active)
	if ctx.run_modifiers.get("run_event_active", 0) > 0:
		var run_event_discount: int = boost_dict.get("run_event_cost_reduction", 0)
		cost = max(0, cost - run_event_discount)

	var total_cost: int        = cost * times

	if ctx.runner_available_credits() < total_cost:
		ctx.send_log("[Encounter] Cannot afford boost (need %d, have %d)." % [total_cost, ctx.runner_available_credits()])
		return false

	# Calculate strength gained per use
	# Unity: 1cr → strength equal to number of installed icebreakers (including itself)
	var str_per_use: int = boost_dict.get("strength_gained", 1)
	if boost_dict.get("strength_gained_modifier", "") == "installed_icebreaker_count":
		str_per_use = ctx.count_installed_icebreakers()

	ctx.runner_spend_credits(total_cost)
	var total_boost: int = str_per_use * times
	encounter.apply_boost(breaker, total_boost)
	# GAMEDRAGON Pro: persist this boost to the run-level dict so it carries over to the next encounter.
	if ctx.has_method("has_gamedragon_attached") and ctx.has_gamedragon_attached(breaker):
		var prev_run_boost: int = ctx.run_level_strength_boosts.get(breaker.runtime_instance_id, 0)
		ctx.run_level_strength_boosts[breaker.runtime_instance_id] = prev_run_boost + total_boost

	if boost_dict.get("strength_gained_modifier", "") == "installed_icebreaker_count":
		ctx.send_log("[Encounter] %s boosted +%d str (%d icebreakers). Cost: %d cr." % [
			breaker.display_name(), total_boost, str_per_use,
			total_cost
		])
	else:
		ctx.send_log("[Encounter] %s boosted %s +%d str (now %d). Cost: %d cr." % [
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
		ctx.send_log("[Encounter] Subroutine %d already broken." % sub_index)
		return true  # not an error, just redundant

	var break_def: Variant = ability_registry.get_break(breaker.card_id)
	if break_def == null:
		push_error("AbilityInterpreter: %s has no break ability" % breaker.card_id)
		return false

	var break_dict: Dictionary = break_def as Dictionary

	# host_only: Botulus can only break subs on its host ice
	if break_dict.get("host_only", false):
		if breaker.hosted_on_id == "" or breaker.hosted_on_id != encounter.ice_card.runtime_instance_id:
			ctx.send_log("[Encounter] %s can only break subroutines on %s." % [
				breaker.display_name(),
				ctx.get_ice_by_instance_id(breaker.hosted_on_id).display_name() if breaker.hosted_on_id != "" else "its host ice"
			])
			return false

	# target_only: Boomerang can only break subs on its chosen target ice
	if break_dict.get("target_only", false):
		if breaker.target_id == "" or breaker.target_id != encounter.ice_card.runtime_instance_id:
			var target_ice := ctx.get_ice_by_instance_id(breaker.target_id) if breaker.target_id != "" else null
			ctx.send_log("[Encounter] %s can only break subroutines on %s." % [
				breaker.display_name(),
				target_ice.display_name() if target_ice != null else "its chosen target"
			])
			return false

	# Strength check (host_only and target_only bypass the strength check)
	if not break_dict.get("host_only", false) and not break_dict.get("target_only", false) \
			and not encounter.breaker_reaches(breaker):
		ctx.send_log("[Encounter] %s (str %d) cannot reach %s (str %d)." % [
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
			ctx.send_log("[Encounter] %s has no virus counters to spend." % breaker.display_name())
			return false
		breaker.remove_counter("virus", virus_cost)
	elif ctx.runner_available_credits() < cost:
		ctx.send_log("[Encounter] Cannot afford to break (need %d, have %d)." % [cost, ctx.runner_available_credits()])
		return false
	else:
		ctx.runner_spend_credits(cost)
	encounter.break_subroutine(sub_index)
	var sub_label: String = (encounter.subroutines[sub_index] as Dictionary).get("label", "subroutine %d" % sub_index)
	if virus_cost > 0:
		ctx.send_log("[Encounter] %s breaks \'%s\' (1 virus, %d remaining)." % [
			breaker.display_name(), sub_label, breaker.get_counter("virus")])
	else:
		ctx.send_log("[Encounter] %s breaks \'%s\' for %d cr." % [breaker.display_name(), sub_label, cost])

	# trash_self_on_use: card trashes itself after breaking (Boomerang).
	# Keep the run_end listener alive so the heap-recur ability can still fire.
	if break_dict.get("trash_self_on_use", false):
		ctx.runner_rig.erase(breaker)
		ctx.unregister_card_effects_except_event(breaker.runtime_instance_id, "run_end")
		if breaker.card_record != null:
			ctx.runner_discard.append(breaker.card_record)
		ctx.send_log("[Encounter] %s is trashed." % breaker.display_name())

	return true


func _do_break_all(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var breaker := _find_breaker(action.get("card_id", ""), encounter)
	if breaker == null:
		return false

	var break_def: Variant = ability_registry.get_break(breaker.card_id)
	if break_def == null:
		return false

	var break_dict: Dictionary = break_def as Dictionary

	# target_only: can only break subs on the chosen target ice (Boomerang)
	if break_dict.get("target_only", false):
		if breaker.target_id == "" or breaker.target_id != encounter.ice_card.runtime_instance_id:
			var target_ice := ctx.get_ice_by_instance_id(breaker.target_id) if breaker.target_id != "" else null
			ctx.send_log("[Encounter] %s can only break subroutines on %s." % [
				breaker.display_name(),
				target_ice.display_name() if target_ice != null else "its chosen target"
			])
			return false

	# Strength check (skip for host_only or target_only breakers)
	if not break_dict.get("host_only", false) and not break_dict.get("target_only", false) \
			and not encounter.breaker_reaches(breaker):
		ctx.send_log("[Encounter] %s cannot reach %s — boost first." % [
			breaker.display_name(), encounter.ice_card.display_name()
		])
		return false

	var cost_per_sub: int = break_dict.get("cost_per_sub", 1)
	var virus_cost: int   = break_dict.get("cost_virus_counter", 0)
	var unbroken          := encounter.unbroken_indices()

	# subs_per_use cap (Boomerang: break up to 2 subroutines per activation)
	var subs_cap: int = break_dict.get("subs_per_use", 0)
	if subs_cap > 0 and unbroken.size() > subs_cap:
		unbroken = unbroken.slice(0, subs_cap)

	if virus_cost > 0:
		# Virus-counter cost — break as many as we have virus counters for
		var available_virus: int = breaker.get_counter("virus")
		var can_break_v: int = min(available_virus, unbroken.size())
		if can_break_v == 0:
			ctx.send_log("[Encounter] %s has no virus counters to spend." % breaker.display_name())
			return false
		for i in range(can_break_v):
			breaker.remove_counter("virus", virus_cost)
			encounter.break_subroutine(unbroken[i])
			var sub_label_v: String = (encounter.subroutines[unbroken[i]] as Dictionary).get("label", "sub %d" % unbroken[i])
			ctx.send_log("[Encounter] %s breaks \'%s\' (1 virus, %d remaining)." % [
				breaker.display_name(), sub_label_v, breaker.get_counter("virus")])
	else:
		var total_cost: int = cost_per_sub * unbroken.size()
		if ctx.runner_available_credits() < total_cost:
			# Break as many as we can afford
			var can_break: int = (ctx.runner_available_credits() / cost_per_sub) if cost_per_sub > 0 else unbroken.size()
			for i in range(can_break):
				ctx.runner_spend_credits(cost_per_sub)
				encounter.break_subroutine(unbroken[i])
				var sub_label: String = (encounter.subroutines[unbroken[i]] as Dictionary).get("label", "sub %d" % unbroken[i])
				ctx.send_log("[Encounter] %s breaks \'%s\'." % [breaker.display_name(), sub_label])
			ctx.send_log("[Encounter] Out of credits — %d subs remain unbroken." % (unbroken.size() - can_break))
			if can_break == 0:
				return false  # nothing was broken
		else:
			for idx in unbroken:
				ctx.runner_spend_credits(cost_per_sub)
				encounter.break_subroutine(idx)
				var sub_label: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
				ctx.send_log("[Encounter] %s breaks \'%s\'." % [breaker.display_name(), sub_label])

	# trash_self_on_use: card trashes itself after breaking (Boomerang).
	# Keep the run_end listener alive so the heap-recur ability can still fire.
	if break_dict.get("trash_self_on_use", false):
		ctx.runner_rig.erase(breaker)
		ctx.unregister_card_effects_except_event(breaker.runtime_instance_id, "run_end")
		if breaker.card_record != null:
			ctx.runner_discard.append(breaker.card_record)
		ctx.send_log("[Encounter] %s is trashed." % breaker.display_name())

	return true


func _do_break_with_click(action: Dictionary, encounter: EncounterState, ctx: GameContext) -> bool:
	# Runner spends 1 click to break 1 subroutine on a bioroid.
	# No strength check required — this is the ice's own ability, not an icebreaker.
	if ctx.runner_clicks < 1:
		ctx.send_log("[Encounter] Runner has no clicks to spend.")
		return false
	var sub_index: int = action.get("sub_index", -1)
	if sub_index < 0 or sub_index >= encounter.subroutines.size():
		push_error("AbilityInterpreter: break_with_click — invalid sub_index %d" % sub_index)
		return false
	if encounter.is_broken(sub_index):
		ctx.send_log("[Encounter] Subroutine %d already broken." % sub_index)
		return true
	ctx.runner_clicks -= 1
	encounter.break_subroutine(sub_index)
	var sub_label: String = (encounter.subroutines[sub_index] as Dictionary).get("label", "sub %d" % sub_index)
	ctx.send_log("[Encounter] Runner spends 1 click to break '%s'. (%d clicks remaining)" % [
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
		ctx.send_log("[Encounter] %s has no hosted credits to spend." % source.display_name())
		return false
	source.remove_counter("credits", taken)
	ctx.runner_credits += taken
	ctx.send_log("[Encounter] %s takes %d cr from %s (%d remaining)." % [
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
			ctx.send_log("Bonus condition met — all modes will execute.")
			max_choices = modes.size()

	# Ask decision maker to choose.
	# "chooser" overrides the active player — used by Wildcat Strike where Corp
	# chooses even though the Runner is the active player.
	var chooser: String = trigger_def.get("chooser", ctx.active_player)
	var chosen_indices: Array = []
	var decision_maker: Object = ctx.corp_decision_maker if chooser == "corp" else ctx.runner_decision_maker
	if chooser == "corp":
		ctx.send_log("Corp chooses the effect of this card...")
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
		ctx.send_log("Modal: executing '%s'." % mode.get("label", "mode %d" % idx))
		var effects: Array = mode.get("effects", []) as Array
		for effect in effects:
			await _execute_effect(effect as Dictionary, ctx, null)

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
			var pool: Array = []
			if controller == "runner" or controller == "":
				pool.append_array(ctx.runner_rig)
			if controller == "corp" or controller == "":
				pool.append_array(ctx.all_installed())
			candidates = pool.filter(func(c: InstalledCard):
				var type_match: bool = card_types.is_empty() or card_types.has(c.card_record.card_type)
				return type_match
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
			ctx.log("%s gains %d credits." % [subject.capitalize(), amount])

		"lose_credits":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 0)
			var current: int    = ctx.get_credits(subject)
			var lost: int       = min(amount, current)  # can't go below 0
			ctx.set_credits(subject, current - lost)
			ctx.log("%s loses %d credits." % [subject.capitalize(), lost])

		"end_run":
			ctx.run_ended = true
			ctx.log("Run ended.")

		"deal_damage":
			var damage_type: String = params.get("damage_type", "net")
			var amount_def          = params.get("amount", 0)
			var amount: int         = _resolve_amount(amount_def, ctx)
			_deal_damage(damage_type, amount, ctx)

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
				ctx.log("Runner cannot afford any payment option — run ends.")
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
				ctx.log("Runner ends the run (Manegarm Skunkworks).")
				ctx.run_ended = true
				return

			# Apply chosen payment
			var c: Dictionary = chosen as Dictionary
			match c.get("type", ""):
				"clicks":
					var amount: int = c.get("amount", 0)
					ctx.runner_clicks -= amount
					ctx.log("Runner spends %d click(s) for Manegarm Skunkworks." % amount)
				"credits":
					var amount: int = c.get("amount", 0)
					ctx.runner_credits -= amount
					ctx.log("Runner pays %d cr for Manegarm Skunkworks." % amount)

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
				ctx.log("Corp has no ice in HQ%s to install." % (" or Archives" if also_archives else ""))
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
							ctx.log("Corp installs %s from %s on %s (ignoring costs)." % [
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
				ctx.log("No valid runner cards to trash.")
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
					ctx.log("Corp trashes runner\'s %s." % target.display_name())

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
						ctx.log("%s reveals and takes %s from their deck." % [subject.capitalize(), chosen.title])
					else:
						ctx.log("%s takes a card from their deck." % subject.capitalize())
					# Shuffle the deck after searching
					deck.shuffle()
					ctx.log("%s's deck is shuffled." % subject.capitalize())

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
						subject.capitalize(),
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
				ctx.log("Corp max hand size increased to %d." % ctx.corp_max_hand_size())
			else:
				ctx.runner_hand_size_bonus += amount
				ctx.log("Runner max hand size increased to %d." % ctx.runner_max_hand_size())

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
					ctx.log("Runner takes %d cr from %s (%d remaining)." % [
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
						subject.capitalize(), taken, self_card.display_name(),
						self_card.get_counter("credits")
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

		"lose_clicks_next_turn":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 1)
			var current: int    = ctx.pending_click_penalties.get(subject, 0)
			ctx.pending_click_penalties[subject] = current + amount
			ctx.log("%s will lose %d click(s) next turn." % [subject.capitalize(), amount])

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

		_:
			push_error("AbilityInterpreter: unknown effect type '%s'" % etype)


# ── Effect helpers ────────────────────────────────────────────────────────────

func _resolve_amount(amount_def: Variant, ctx: GameContext) -> int:
	if amount_def is int:
		return amount_def

	# Structured amount: {"base": 2, "plus_counters": "advancement"}
	if amount_def is Dictionary:
		var base: int        = (amount_def as Dictionary).get("base", 0)
		var plus_counters    = (amount_def as Dictionary).get("plus_counters", "")
		if plus_counters != "":
			base += ctx.get_counters_on_accessed_card(plus_counters as String)
		return base

	push_error("AbilityInterpreter: unrecognised amount definition: %s" % str(amount_def))
	return 0


func _deal_damage(damage_type: String, amount: int, ctx: GameContext) -> void:
	ctx.log("Runner takes %d %s damage." % [amount, damage_type])
	var trashed: int = 0
	for i in range(amount):
		if ctx.runner_hand.is_empty():
			ctx.log("Runner is flatlined! (no cards remaining in grip)")
			# TODO: set game_over flag when GameState exists
			break
		# Trash a random card from grip
		var idx: int = randi() % ctx.runner_hand.size()
		var trashed_card: Dictionary = ctx.runner_hand[idx] as Dictionary
		ctx.runner_hand.remove_at(idx)
		trashed += 1
		ctx.log("  Trashed from grip: %s" % trashed_card.get("card_id", "unknown"))
	ctx.log("%d card(s) trashed from grip." % trashed)


func _trash_installed_card(card: InstalledCard, ctx: GameContext) -> void:
	ctx.runner_rig.erase(card)
	ctx.log("Trashed installed card: %s" % card.card_id)

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
			ctx.log("%s deck empty — cannot draw." % subject.capitalize())
			break
		var card: CardRecord = deck.pop_front() as CardRecord
		hand.append({"card_id": card.id, "card_record": card})
		drawn += 1
	ctx.log("%s draws %d card(s)." % [subject.capitalize(), drawn])


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

	if ctx.runner_credits < total_cost:
		ctx.log("[Encounter] Cannot afford boost (need %d, have %d)." % [total_cost, ctx.runner_credits])
		return false

	# Calculate strength gained — Unity gets +1 per installed icebreaker
	var str_per_use: int = boost_dict.get("strength_gained", 1)
	if boost_dict.get("strength_gained_modifier", "") == "installed_icebreaker_count":
		var icebreaker_count: int = _count_installed_icebreakers(ctx, ability_registry)
		str_per_use = icebreaker_count

	ctx.runner_credits -= total_cost
	var total_boost: int = str_per_use * times
	encounter.apply_boost(breaker, total_boost)
	ctx.log("[Encounter] %s boosted %d times (+%d str, now %d). Cost: %d cr." % [
		breaker.display_name(), times, total_boost,
		encounter.get_breaker_strength(breaker), total_cost
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

	# Strength check
	if not encounter.breaker_reaches(breaker):
		ctx.log("[Encounter] %s (str %d) cannot reach %s (str %d)." % [
			breaker.display_name(),
			encounter.get_breaker_strength(breaker),
			encounter.ice_card.display_name(),
			encounter.ice_strength
		])
		return false

	var cost: int = break_dict.get("cost_per_sub", 1)
	if ctx.runner_credits < cost:
		ctx.log("[Encounter] Cannot afford to break (need %d, have %d)." % [cost, ctx.runner_credits])
		return false

	ctx.runner_credits -= cost
	encounter.break_subroutine(sub_index)
	var sub_label: String = (encounter.subroutines[sub_index] as Dictionary).get("label", "subroutine %d" % sub_index)
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

	if ctx.runner_credits < total_cost:
		# Break as many as we can afford
		var can_break := ctx.runner_credits / cost_per_sub
		for i in range(can_break):
			ctx.runner_credits -= cost_per_sub
			encounter.break_subroutine(unbroken[i])
			var sub_label: String = (encounter.subroutines[unbroken[i]] as Dictionary).get("label", "sub %d" % unbroken[i])
			ctx.log("[Encounter] %s breaks \'%s\'." % [breaker.display_name(), sub_label])
		ctx.log("[Encounter] Out of credits — %d subs remain unbroken." % (unbroken.size() - can_break))
	else:
		for idx in unbroken:
			ctx.runner_credits -= cost_per_sub
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
	ctx.log("[Encounter] Runner takes %d cr from %s (%d remaining)." % [
		taken, source.display_name(), source.get_counter("credits")
	])
	return true


func _find_breaker(card_id: String, encounter: EncounterState) -> InstalledCard:
	for b in encounter.available_breakers:
		var breaker: InstalledCard = b as InstalledCard
		if breaker.card_id == card_id:
			return breaker
	push_error("AbilityInterpreter: breaker '%s' not found in encounter" % card_id)
	return null


func _count_installed_icebreakers(ctx: GameContext, ability_registry: AbilityRegistry) -> int:
	var count := 0
	for card in ctx.runner_rig:
		var c: InstalledCard = card as InstalledCard
		if ability_registry.is_icebreaker(c.card_id):
			count += 1
	return count

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

	# Ask decision maker to choose
	var chosen_indices: Array = []
	var decision_maker: Object = ctx.corp_decision_maker if ctx.active_player == "corp" else ctx.runner_decision_maker
	if decision_maker != null and decision_maker.has_method("choose_modes"):
		chosen_indices = await decision_maker.choose_modes(modes, max_choices, ctx)
	else:
		# No decision maker or no method — default to first mode
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

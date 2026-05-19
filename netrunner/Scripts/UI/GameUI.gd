# GameUI.gd
extends CanvasLayer

# Outbound signal to feed actions back into the main game orchestrator
signal action_requested(action: GameAction)
signal rez_prompt_resolved(choice: bool)
signal jack_out_prompt_resolved(choice: bool)
signal trash_prompt_resolved(choice: bool)
signal encounter_action_resolved(action: Dictionary)
signal mode_choice_resolved(indices: Array)
signal modal_choice_resolved(indices: Array)
signal server_choice_resolved(server_id: String)
signal search_choice_resolved(card: CardRecord)

# Onready references using unique names (% badge in inspector)
@onready var resource_label = $MarginContainer/MainContainer/StatePanel/StateVBox/ResourceLabel
@onready var servers_container = $MarginContainer/MainContainer/StatePanel/StateVBox/ServersScroll/ServersContainer
@onready var runner_hand_container = $MarginContainer/MainContainer/StatePanel/StateVBox/RunnerHandContainer
@onready var corp_hand_container = $MarginContainer/MainContainer/StatePanel/StateVBox/CorpHandContainer
@onready var log_text = $MarginContainer/MainContainer/ControlPanel/LogText
@onready var action_menu = $MarginContainer/MainContainer/ControlPanel/ActionMenu

var _ctx: GameContext

## Initializes UI wiring by subscribing directly to engine component signals
func setup(ctx: GameContext, turn_manager: TurnManager, run_machine: RunStateMachine) -> void:
	_ctx = ctx
	
	# Wire up engine signals to automatically refresh components
	if not turn_manager.turn_started.is_connected(_on_turn_started):
		turn_manager.turn_started.connect(_on_turn_started)
	if not turn_manager.action_executed.is_connected(_on_action_executed):
		turn_manager.action_executed.connect(_on_action_executed)
	if not turn_manager.action_rejected.is_connected(_on_action_rejected):
		turn_manager.action_rejected.connect(_on_action_rejected)
	if not turn_manager.game_over.is_connected(_on_game_over):
		turn_manager.game_over.connect(_on_game_over)
	
	# Connect RunStateMachine updates to the UI logger safely using anonymized callables
	run_machine.phase_changed.connect(func(phase): _append_log("[RUN] Phase changed to: %d" % phase))
	run_machine.ice_approached.connect(func(ice): _append_log("[RUN] Approaching ICE: %s" % ice.card_record.title))
	run_machine.ice_encountered.connect(func(ice): _append_log("[RUN] Encountering ICE: %s" % ice.card_record.title))
	run_machine.ice_rezzed.connect(func(ice): _append_log("[RUN] ICE Rezzed: %s" % ice.card_record.title))
	run_machine.run_succeeded.connect(func(srv):
		_append_log("✅ [RUN] Success! Breached %s" % srv)
		_update_all_displays()
	)
	run_machine.run_ended_unsuccessfully.connect(func(reason):
		_append_log("❌ [RUN] Run ended (%s)" % reason)
		_update_all_displays()
	)
	if run_machine.has_signal("encounter_started"):
		run_machine.encounter_started.connect(func(enc):
			_append_log("⚔ [ENCOUNTER] %s" % enc.describe())
		)

	# Initialize visual configurations
	_update_all_displays()





## Forces a full structural re-render of current resources and card locations
func _update_all_displays() -> void:
	if _ctx == null:
		return
		
	# 1. Update text fields
	resource_label.text = (
		"=== RESOURCES ===\n" +
		"CORP   | Credits: %d  | Clicks: %d | Points: %d\n" % [_ctx.corp_credits, _ctx.corp_clicks, _ctx.corp_agenda_points()] +
		"RUNNER | Credits: %d  | Clicks: %d | Points: %d | Tags: %d" % [_ctx.runner_credits, _ctx.runner_clicks, _ctx.runner_agenda_points(), _ctx.runner_tags]
	)
	
	#corp_hand_label.text = "Corp HQ Hand (%d cards):\n%s" % [_ctx.corp_hand.size(), _format_hand(_ctx.corp_hand)]
	#runner_hand_label.text = "Runner Grip (%d cards):\n%s" % [_ctx.runner_hand.size(), _format_hand(_ctx.runner_hand)]
	
	# 2. Update hands (new)
	_update_hands()
	
	# 3. Rebuild the visual server hierarchy (still Tree for now)
	_update_servers()
	
	# 4. Regenerate valid action options
	_populate_action_menu()

func _update_hands() -> void:
	# Clear existing cards
	for child in corp_hand_container.get_children():
		child.queue_free()
	for child in runner_hand_container.get_children():
		child.queue_free()
	
	# Corp hand
	for entry in _ctx.corp_hand:
		var record = entry.get("card_record") if entry is Dictionary else null
		if record:
			var card_view = CardView.new()
			corp_hand_container.add_child(card_view)
			card_view.setup(record, true)   # hand cards are always face-up
			
	
	# Runner hand
	for entry in _ctx.runner_hand:
		var record = entry.get("card_record") if entry is Dictionary else null
		if record:
			var card_view = CardView.new()
			runner_hand_container.add_child(card_view)
			card_view.setup(record, true)
			card_view.clicked.connect(_on_runner_hand_card_clicked)
			

func _on_runner_hand_card_clicked(card_record: CardRecord) -> void:
	if _ctx.active_player != "runner":
		_append_log("Not your turn to play cards.")
		return
	# Determine action based on card type
	var action: GameAction = null
	match card_record.card_type:
		"event":
			action = GameAction.play_operation(card_record)
		"program", "hardware", "resource":
			action = GameAction.install(card_record, "runner_rig")
		_:
			_append_log("Cannot play/install card type: %s" % card_record.card_type)
			return
	if action:
		action_requested.emit(action)

func _format_hand(hand: Array) -> String:
	if hand.is_empty():
		return "  [Empty]"
	var lines: Array[String] = []
	for entry in hand:
		if entry is Dictionary:
			var record: CardRecord = entry.get("card_record", null)
			if record:
				lines.append("  - %s (%s)" % [record.title, record.card_type.capitalize()])
	return "\n".join(lines)


func _update_servers() -> void:
	# Clear existing columns
	for child in servers_container.get_children():
		child.queue_free()
	
	if _ctx == null or not ("servers" in _ctx):
		return
	
	# Sort servers: centrals first (HQ, R&D, Archives), then remotes by name
	var central_order = {"hq": 0, "rd": 1, "archives": 2}
	var server_ids = _ctx.servers.keys()
	server_ids.sort_custom(func(a, b):
		var a_order = central_order.get(a, 999)
		var b_order = central_order.get(b, 999)
		if a_order == b_order:
			return a < b
		return a_order < b_order
	)
	
	for server_id in server_ids:
		var server: Server = _ctx.servers[server_id]
		# Skip empty remote servers (optional – you may want to show empty slots)
		if server.is_remote() and server.is_empty():
			continue
		
		var column = _create_server_column(server_id, server)
		servers_container.add_child(column)


func _create_server_column(server_id: String, server: Server) -> VBoxContainer:
	var col = VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	
	# Server name label
	var name_label = Label.new()
	name_label.text = server.display_name()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	col.add_child(name_label)
	
	# Ice stack – only add if there are ice cards
	var ice_container = VBoxContainer.new()
	ice_container.alignment = BoxContainer.ALIGNMENT_CENTER
	for ice_card in server.ice:
		var token = IceToken.new()
		ice_container.add_child(token)
		token.setup(ice_card)
		# Optional: connect token.clicked to show full card tooltip
	if ice_container.get_child_count() > 0:
		col.add_child(ice_container)
	
	# Root card
	if not server.root.is_empty():
		var root_card: InstalledCard = server.root[0]
		var root_view = CardView.new()
		col.add_child(root_view)
		var is_rezzed_root = root_card.is_rezzed and root_card.card_record.card_type == "upgrade"
		root_view.setup(root_card.card_record, is_rezzed_root)
	
	return col

## Generates click choices dynamically based on which side holds active framework clicks
func _populate_action_menu() -> void:
	for child in action_menu.get_children():
		child.queue_free()

	if _ctx == null:
		return

	if _ctx.active_player == "corp" and _ctx.corp_clicks > 0:
		# Corp turn — AI controlled, just show status
		var lbl := Label.new()
		lbl.text = "Corp is thinking... (%d clicks remaining)" % _ctx.corp_clicks
		action_menu.add_child(lbl)

	elif _ctx.active_player == "runner" and _ctx.runner_clicks > 0:
		_add_section_label("── BASIC ACTIONS ──")
		_add_action_btn("Gain 1 Credit  (have %d¢)" % _ctx.runner_credits, GameAction.gain_credits())
		_add_action_btn("Draw 1 Card  (have %d)" % _ctx.runner_hand.size(), GameAction.draw_card())

		# Hand cards — events and installable cards
		var has_hand_cards := false
		for entry in _ctx.runner_hand:
			if not entry is Dictionary:
				continue
			var record: CardRecord = entry.get("card_record", null) as CardRecord
			if record == null:
				continue
			if not has_hand_cards:
				_add_section_label("── HAND ──")
				has_hand_cards = true
			var cost_str := "free" if record.cost <= 0 else "%d¢" % record.cost
			var type_str := record.card_type.capitalize()
			match record.card_type:
				"event":
					_add_action_btn("Play %s  [%s] (%s)" % [record.title, type_str, cost_str],
						GameAction.play_operation(record))
				"program", "hardware", "resource":
					_add_action_btn("Install %s  [%s] (%s)" % [record.title, type_str, cost_str],
						GameAction.install(record, "runner_rig"))

		# Runs — show server info
		_add_section_label("── RUNS ──")
		for s_id in _ctx.servers:
			var server: Server = _ctx.servers[s_id] as Server
			var ice_count: int = server.ice_count()
			var ice_info := ""
			if ice_count > 0:
				var rezzed := 0
				for ice in server.ice:
					if (ice as InstalledCard).is_rezzed:
						rezzed += 1
				ice_info = "  [%d ice, %d rezzed]" % [ice_count, rezzed]
			else:
				ice_info = "  [no ice]"
			_add_action_btn("Run %s%s" % [server.display_name(), ice_info], GameAction.run(s_id))

		_add_section_label("──────────")
		_add_action_btn("End Turn  (%d clicks left)" % _ctx.runner_clicks, GameAction.end_turn())

	else:
		var lbl := Label.new()
		lbl.text = "Processing..."
		action_menu.add_child(lbl)


func _add_section_label(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	action_menu.add_child(lbl)


func _add_action_btn(label_text: String, action: GameAction) -> void:
	var btn := Button.new()
	btn.text = label_text
	btn.alignment = HorizontalAlignment.HORIZONTAL_ALIGNMENT_LEFT
	btn.pressed.connect(func(): action_requested.emit(action))
	action_menu.add_child(btn)


func _append_log(message: String) -> void:
	log_text.text += message + "\n"
	log_text.scroll_vertical = log_text.get_line_count()


# ── System Signal Hook Interceptions ──────────────────────────────────────────

func _on_turn_started(player: String, turn_number: int) -> void:
	_append_log("\n⚡ --- TURN %d: %s's Turn ---" % [turn_number, player.to_upper()])
	_update_all_displays()

func _on_action_executed(player: String, action: GameAction) -> void:
	_append_log("[%s] %s" % [player.capitalize(), action.describe()])
	_update_all_displays()

func _on_action_rejected(player: String, action: GameAction, reason: String) -> void:
	_append_log("❌ REJECTED: %s -> %s" % [action.describe(), reason])

func _on_game_over(winner: String, reason: String) -> void:
	_append_log("\n🏆 GAME OVER! %s Wins. Reason: %s" % [winner.to_upper(), reason])
	for child in action_menu.get_children():
		child.queue_free()
	var game_over_lbl := Label.new()
	game_over_lbl.text = "MATCH CONCLUDED: %s Victory" % winner.to_upper()
	action_menu.add_child(game_over_lbl)


# ── Asynchronous Choice Prompt Engine ─────────────────────────────────────────

## Pops open an inline blocking prompt allowing the corp player to evaluate a Rez window
func show_rez_prompt(ice_card: InstalledCard) -> bool:
	var title_text := ice_card.card_record.title if ice_card.card_record else "ICE"
	var cost_val := ice_card.card_record.cost if ice_card.card_record else 0
	
	_append_log("PROMPT: Corp, choose whether to rez %s..." % title_text)
	
	var prompt_box := HBoxContainer.new()
	var prompt_lbl := Label.new()
	prompt_lbl.text = "Rez %s for %d cr? " % [title_text, cost_val]
	
	var yes_btn := Button.new()
	yes_btn.text = "Yes"
	var no_btn := Button.new()
	no_btn.text = "No"
	
	prompt_box.add_child(prompt_lbl)
	prompt_box.add_child(yes_btn)
	prompt_box.add_child(no_btn)
	action_menu.add_child(prompt_box)
	
	var selection: bool = await _choice_with_signal(yes_btn, no_btn, prompt_box, rez_prompt_resolved)
	return selection


func _choice_with_signal(yes: Button, no: Button, container: HBoxContainer, resolution_signal: Signal) -> bool:
	var output := false
	# Use a one-shot signal helper: whichever button fires first resolves the await
	var resolved := false
	var _yes_cb: Callable
	var _no_cb: Callable
	_yes_cb = func():
		if not resolved:
			resolved = true
			output = true
			resolution_signal.emit(true)
	_no_cb = func():
		if not resolved:
			resolved = true
			output = false
			resolution_signal.emit(false)
	yes.pressed.connect(_yes_cb, CONNECT_ONE_SHOT)
	no.pressed.connect(_no_cb, CONNECT_ONE_SHOT)
	await resolution_signal
	container.queue_free()
	return output

## Pops open a confirmation layout giving the Runner an option to escape the current run
func show_jack_out_prompt() -> bool:
	_append_log("PROMPT: Runner, do you want to jack out of this run?")
	
	var prompt_box := HBoxContainer.new()
	var prompt_lbl := Label.new()
	prompt_lbl.text = "Jack Out of Server? "
	
	var yes_btn := Button.new()
	yes_btn.text = "Yes (Jack Out)"
	var no_btn := Button.new()
	no_btn.text = "No (Continue Run)"
	
	prompt_box.add_child(prompt_lbl)
	prompt_box.add_child(yes_btn)
	prompt_box.add_child(no_btn)
	action_menu.add_child(prompt_box)
	
	var selection: bool = await _choice_with_signal(yes_btn, no_btn, prompt_box, jack_out_prompt_resolved)
	return selection

func group_signals(connections: Array) -> void:
	var wrapper := RefCounted.new()
	wrapper.add_user_signal("resolved")
	
	for conn in connections:
		var process_callable = func():
			conn["callable"].call()
			wrapper.emit_signal("resolved")
		conn["sig"].connect(process_callable, CONNECT_ONE_SHOT)
		
	await wrapper.to_signal(wrapper, "resolved")

## Pops open a prompt asking the Runner whether to trash an accessed card
func show_trash_prompt(card: CardRecord) -> bool:
	var title_text := card.title if card else "card"
	var cost_val := card.trash_cost if card else 0
	
	_append_log("PROMPT: Runner, trash %s for %d credits?" % [title_text, cost_val])
	
	var prompt_box := HBoxContainer.new()
	var prompt_lbl := Label.new()
	prompt_lbl.text = "Trash %s for %d cr? " % [title_text, cost_val]
	
	var yes_btn := Button.new()
	yes_btn.text = "Yes (Trash)"
	var no_btn := Button.new()
	no_btn.text = "No"
	
	prompt_box.add_child(prompt_lbl)
	prompt_box.add_child(yes_btn)
	prompt_box.add_child(no_btn)
	action_menu.add_child(prompt_box)
	
	var selection: bool = await _choice_with_signal(yes_btn, no_btn, prompt_box, trash_prompt_resolved)
	return selection

## Shows icebreaker controls during an ice encounter.
## Returns a Dictionary encounter action: {type, card_id, ...} or {type: "done"}
func show_encounter_prompt(encounter: EncounterState) -> Dictionary:
	var ice_name := encounter.ice_card.display_name() if encounter.ice_card else "ice"
	var ice_str  := str(encounter.ice_strength)
	_append_log("ENCOUNTER: %s (str %s) — choose an action." % [ice_name, ice_str])

	# Build a prompt container
	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var info_label := Label.new()
	info_label.text = "%s  str %s" % [ice_name, ice_str]
	info_label.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(info_label)

	# List subroutines
	for i in range(encounter.subroutines.size()):
		var sub: Dictionary = encounter.subroutines[i] as Dictionary
		var lbl := Label.new()
		var broken_marker := "[BROKEN] " if encounter.is_broken(i) else ""
		lbl.text = "  ↳ %s%s" % [broken_marker, sub.get("label", "sub %d" % i)]
		lbl.add_theme_font_size_override("font_size", 10)
		prompt_box.add_child(lbl)

	# Breaker buttons
	var breakers := encounter.breakers_for_ice()
	if breakers.is_empty():
		var no_breaker_lbl := Label.new()
		no_breaker_lbl.text = "(no matching icebreaker installed)"
		no_breaker_lbl.add_theme_font_size_override("font_size", 10)
		prompt_box.add_child(no_breaker_lbl)
	else:
		for breaker in breakers:
			var b: InstalledCard = breaker as InstalledCard
			var b_str := str(encounter.get_breaker_strength(b))
			var row := HBoxContainer.new()
			prompt_box.add_child(row)

			var b_lbl := Label.new()
			b_lbl.text = "%s (str %s)" % [b.display_name(), b_str]
			b_lbl.add_theme_font_size_override("font_size", 10)
			b_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(b_lbl)

			var break_btn := Button.new()
			break_btn.text = "Break All"
			break_btn.pressed.connect(func():
				encounter_action_resolved.emit({"type": "break_all", "card_id": b.card_id})
			)
			row.add_child(break_btn)

			var boost_btn := Button.new()
			boost_btn.text = "Boost +str"
			boost_btn.pressed.connect(func():
				encounter_action_resolved.emit({"type": "boost_strength", "card_id": b.card_id, "times": 1})
			)
			row.add_child(boost_btn)

	# Leech hosted credits — show if any Leech is installed with credits
	for rig_card in _ctx.runner_rig:
		var rc: InstalledCard = rig_card as InstalledCard
		if rc == null or rc.card_record == null:
			continue
		var hosted: int = rc.get_counter("credits")
		if hosted > 0:
			var leech_row := HBoxContainer.new()
			prompt_box.add_child(leech_row)
			var leech_lbl := Label.new()
			leech_lbl.text = "%s (%d hosted cr)" % [rc.display_name(), hosted]
			leech_lbl.add_theme_font_size_override("font_size", 10)
			leech_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			leech_row.add_child(leech_lbl)
			var spend_btn := Button.new()
			spend_btn.text = "Spend 1 cr"
			var cid := rc.card_id  # capture
			spend_btn.pressed.connect(func():
				encounter_action_resolved.emit({"type": "spend_hosted_credits", "card_id": cid, "amount": 1})
			)
			leech_row.add_child(spend_btn)

	# Pass button
	var pass_btn := Button.new()
	pass_btn.text = "Pass (let subs fire)"
	pass_btn.pressed.connect(func():
		encounter_action_resolved.emit({"type": "done"})
	)
	prompt_box.add_child(pass_btn)

	# Await the player's choice
	var result: Dictionary = await encounter_action_resolved
	prompt_box.queue_free()
	return result

## Shows a modal choice prompt for cards like Predictive Planogram.
## Returns an Array of chosen mode indices.
func show_modal_prompt(modes: Array, max_choices: int) -> Array:
	_append_log("MODAL: Choose %d option(s):" % max_choices)

	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var info_lbl := Label.new()
	info_lbl.text = "Choose %d:" % max_choices
	info_lbl.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(info_lbl)

	var chosen: Array = []

	for i in range(modes.size()):
		var mode: Dictionary = modes[i] as Dictionary
		var btn := Button.new()
		btn.text = mode.get("label", "Option %d" % i)
		var idx := i  # capture for lambda
		btn.pressed.connect(func():
			chosen.append(idx)
			if chosen.size() >= max_choices:
				modal_choice_resolved.emit(chosen.duplicate())
		)
		prompt_box.add_child(btn)

	var result: Array = await modal_choice_resolved
	prompt_box.queue_free()
	return result

## Shows a modal choice prompt for cards like Predictive Planogram.
## Returns Array of chosen mode indices.
func show_modes_prompt(modes: Array, max_choices: int) -> Array:
	_append_log("MODAL: Choose %d option(s):" % max_choices)

	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var info_lbl := Label.new()
	info_lbl.text = "Choose %d:" % max_choices
	info_lbl.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(info_lbl)

	var chosen: Array = []

	for i in range(modes.size()):
		var mode: Dictionary = modes[i] as Dictionary
		var btn := Button.new()
		btn.text = mode.get("label", "Option %d" % i)
		var idx := i
		btn.pressed.connect(func():
			if not chosen.has(idx):
				chosen.append(idx)
			if chosen.size() >= max_choices:
				mode_choice_resolved.emit(chosen)
		)
		prompt_box.add_child(btn)

	var result: Array = await mode_choice_resolved
	prompt_box.queue_free()
	return result

## Shows a server selection prompt for run-initiating events like Jailbreak.
func show_server_choice_prompt(allowed_servers: Array) -> String:
	_append_log("Choose a server to run:")

	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var lbl := Label.new()
	lbl.text = "Run on which server?"
	lbl.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(lbl)

	for server_id in allowed_servers:
		var display: String = {"hq": "HQ", "rd": "R&D", "archives": "Archives"}.get(server_id, server_id)
		var btn := Button.new()
		btn.text = display
		var sid: String = server_id  # capture
		btn.pressed.connect(func():
			server_choice_resolved.emit(sid)
		)
		prompt_box.add_child(btn)

	var result: String = await server_choice_resolved
	prompt_box.queue_free()
	return result

## Shows a deck search prompt — player picks one card from matching results.
func show_search_prompt(candidates: Array) -> CardRecord:
	_append_log("SEARCH: Choose a card to add to your grip:")

	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var lbl := Label.new()
	lbl.text = "Take which card?"
	lbl.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(lbl)

	for candidate in candidates:
		var r: CardRecord = candidate as CardRecord
		if r == null:
			continue
		var cost_str := "%d¢" % r.cost if r.cost >= 0 else "free"
		var btn := Button.new()
		btn.text = "%s  [%s] (%s)" % [r.title, r.card_type.capitalize(), cost_str]
		var record := r  # capture
		btn.pressed.connect(func():
			search_choice_resolved.emit(record)
		)
		prompt_box.add_child(btn)

	var result: CardRecord = await search_choice_resolved
	prompt_box.queue_free()
	return result

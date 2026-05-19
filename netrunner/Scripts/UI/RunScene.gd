# RunScene.gd
# Dedicated UI scene for a single run. Slides in over GameUI when a run begins,
# handles all run-time player decisions, then signals completion so Main can
# remove it and return to GameUI.
#
# Main.gd:
#   1. Instantiates RunScene and adds it as a child
#   2. Reassigns HumanDecisionMaker proxies to RunScene methods
#   3. Calls run_machine.execute(server_id) — which drives the scene
#   4. Connects run_complete signal to clean up and restore GameUI proxies

extends CanvasLayer
class_name RunScene

signal run_complete

# ── Signals used for async decision resolution ────────────────────────────────
signal encounter_action_resolved(action: Dictionary)
signal jack_out_resolved(choice: bool)
signal trash_resolved(choice: bool)
signal payment_resolved(option: Variant)
signal server_choice_resolved(server_id: String)
signal modal_resolved(indices: Array)
signal search_resolved(card: CardRecord)

# ── Engine references ─────────────────────────────────────────────────────────
var ctx:              GameContext
var ability_registry: AbilityRegistry
var run_machine:      RunStateMachine

# ── State ─────────────────────────────────────────────────────────────────────
var _current_server:  Server = null
var _current_ice:     InstalledCard = null

# ── Node references (built programmatically) ──────────────────────────────────
var _phase_label:     Label
var _server_col:      VBoxContainer
var _rig_row:         HBoxContainer
var _credits_label:   Label
var _clicks_label:    Label
var _run_log:         TextEdit
var _action_area:     VBoxContainer
var _ice_cards:       Array = []   # Array[CardView] — one per ice, outermost first


# ── Setup ─────────────────────────────────────────────────────────────────────

func setup(game_ctx: GameContext, ab_registry: AbilityRegistry, rsm: RunStateMachine) -> void:
	ctx              = game_ctx
	ability_registry = ab_registry
	run_machine      = rsm

	# Connect run machine signals
	run_machine.phase_changed.connect(_on_phase_changed)
	run_machine.ice_approached.connect(_on_ice_approached)
	run_machine.ice_encountered.connect(_on_ice_encountered)
	run_machine.ice_rezzed.connect(_on_ice_rezzed)
	run_machine.subroutine_broken.connect(_on_subroutine_broken)
	run_machine.run_succeeded.connect(_on_run_succeeded)
	run_machine.run_ended_unsuccessfully.connect(_on_run_ended)
	if run_machine.has_signal("encounter_started"):
		run_machine.encounter_started.connect(_on_encounter_started)
	if run_machine.has_signal("encounter_updated"):
		run_machine.encounter_updated.connect(_on_encounter_updated)


func start_run(server_id: String) -> void:
	_current_server = ctx.get_server(server_id)
	_rebuild_server_column()
	_rebuild_rig_row()
	_update_resources()
	_log("▶ Run declared on %s" % _current_server.display_name())


# ── UI Construction ───────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10   # above GameUI
	_build_ui()


func _build_ui() -> void:
	# Dark full-screen background
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.04, 0.04, 0.07, 0.96)
	add_child(bg)

	# Root margin
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	# Top-level HBox: server column | run info panel
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	margin.add_child(hbox)

	# ── Left: server column ───────────────────────────────────────────────────
	var server_panel := PanelContainer.new()
	server_panel.custom_minimum_size = Vector2(220, 0)
	server_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(server_panel)

	var server_vbox := VBoxContainer.new()
	server_vbox.add_theme_constant_override("separation", 8)
	server_panel.add_child(server_vbox)

	var server_title := Label.new()
	server_title.text = "SERVER"
	server_title.add_theme_font_size_override("font_size", 11)
	server_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	server_vbox.add_child(server_title)

	_server_col = VBoxContainer.new()
	_server_col.add_theme_constant_override("separation", 6)
	_server_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	server_vbox.add_child(_server_col)

	# ── Centre: runner rig ────────────────────────────────────────────────────
	var rig_panel := PanelContainer.new()
	rig_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rig_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(rig_panel)

	var rig_vbox := VBoxContainer.new()
	rig_vbox.add_theme_constant_override("separation", 8)
	rig_panel.add_child(rig_vbox)

	# Phase + resources row
	var info_hbox := HBoxContainer.new()
	info_hbox.add_theme_constant_override("separation", 16)
	rig_vbox.add_child(info_hbox)

	_phase_label = Label.new()
	_phase_label.text = "INITIATION"
	_phase_label.add_theme_font_size_override("font_size", 18)
	_phase_label.add_theme_color_override("font_color", Color(0.9, 0.75, 0.3))
	_phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_hbox.add_child(_phase_label)

	_credits_label = Label.new()
	_credits_label.add_theme_font_size_override("font_size", 14)
	_credits_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
	info_hbox.add_child(_credits_label)

	_clicks_label = Label.new()
	_clicks_label.add_theme_font_size_override("font_size", 14)
	_clicks_label.add_theme_color_override("font_color", Color(0.9, 0.6, 0.3))
	info_hbox.add_child(_clicks_label)

	# Rig label
	var rig_title := Label.new()
	rig_title.text = "INSTALLED PROGRAMS & HARDWARE"
	rig_title.add_theme_font_size_override("font_size", 11)
	rig_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	rig_vbox.add_child(rig_title)

	var rig_scroll := ScrollContainer.new()
	rig_scroll.custom_minimum_size = Vector2(0, 180)
	rig_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rig_vbox.add_child(rig_scroll)

	_rig_row = HBoxContainer.new()
	_rig_row.add_theme_constant_override("separation", 8)
	rig_scroll.add_child(_rig_row)

	# Run log
	var log_title := Label.new()
	log_title.text = "RUN LOG"
	log_title.add_theme_font_size_override("font_size", 11)
	log_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	rig_vbox.add_child(log_title)

	_run_log = TextEdit.new()
	_run_log.editable = false
	_run_log.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_run_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_run_log.add_theme_font_size_override("font_size", 11)
	rig_vbox.add_child(_run_log)

	# ── Right: action area ────────────────────────────────────────────────────
	var action_panel := PanelContainer.new()
	action_panel.custom_minimum_size = Vector2(260, 0)
	action_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(action_panel)

	var action_vbox := VBoxContainer.new()
	action_vbox.add_theme_constant_override("separation", 6)
	action_panel.add_child(action_vbox)

	var action_title := Label.new()
	action_title.text = "ACTIONS"
	action_title.add_theme_font_size_override("font_size", 11)
	action_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	action_vbox.add_child(action_title)

	_action_area = VBoxContainer.new()
	_action_area.add_theme_constant_override("separation", 6)
	_action_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	action_vbox.add_child(_action_area)


# ── Server column ─────────────────────────────────────────────────────────────

func _rebuild_server_column() -> void:
	for child in _server_col.get_children():
		child.queue_free()
	_ice_cards.clear()

	if _current_server == null:
		return

	var name_lbl := Label.new()
	name_lbl.text = _current_server.display_name()
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_server_col.add_child(name_lbl)

	# Ice — outermost first
	var ice_lbl := Label.new()
	ice_lbl.text = "ICE (outermost → innermost)"
	ice_lbl.add_theme_font_size_override("font_size", 10)
	ice_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	_server_col.add_child(ice_lbl)

	if _current_server.ice.is_empty():
		var no_ice := Label.new()
		no_ice.text = "(no ice)"
		no_ice.add_theme_font_size_override("font_size", 11)
		no_ice.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
		_server_col.add_child(no_ice)
	else:
		for ice in _current_server.ice:
			var c: InstalledCard = ice as InstalledCard
			var card_view := CardView.new()
			_server_col.add_child(card_view)
			card_view.setup(c.card_record if c.is_rezzed else null, c.is_rezzed)
			_ice_cards.append(card_view)

	# Root
	if not _current_server.root.is_empty():
		var root_lbl := Label.new()
		root_lbl.text = "ROOT"
		root_lbl.add_theme_font_size_override("font_size", 10)
		root_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		_server_col.add_child(root_lbl)
		for root_card in _current_server.root:
			var c: InstalledCard = root_card as InstalledCard
			var card_view := CardView.new()
			_server_col.add_child(card_view)
			card_view.setup(c.card_record, c.is_rezzed)


func _highlight_ice(ice_card: InstalledCard) -> void:
	# Dim all ice, highlight the current one
	for i in range(_current_server.ice.size()):
		if i < _ice_cards.size():
			var view: CardView = _ice_cards[i] as CardView
			var ice: InstalledCard = _current_server.ice[i] as InstalledCard
			var is_current := (ice == ice_card)
			view.modulate = Color(1, 1, 1, 1) if is_current else Color(0.4, 0.4, 0.4, 0.7)
			if is_current:
				view.scale = Vector2(1.1, 1.1)
			else:
				view.scale = Vector2(1.0, 1.0)


func _reset_ice_highlight() -> void:
	for view in _ice_cards:
		(view as CardView).modulate = Color(1, 1, 1, 1)
		(view as CardView).scale    = Vector2(1, 1)


# ── Runner rig ────────────────────────────────────────────────────────────────

func _rebuild_rig_row() -> void:
	for child in _rig_row.get_children():
		child.queue_free()

	for rig_card in ctx.runner_rig:
		var c: InstalledCard = rig_card as InstalledCard
		if c.card_record == null:
			continue

		var container := VBoxContainer.new()
		container.add_theme_constant_override("separation", 4)
		_rig_row.add_child(container)

		var card_view := CardView.new()
		container.add_child(card_view)
		card_view.setup(c.card_record, true)

		# Strength badge for icebreakers
		if c.card_record.has_strength():
			var str_lbl := Label.new()
			var base_str: int = c.card_record.strength
			var board_bonus: int = ctx.query_breaker_strength_bonus() if ctx.has_method("query_breaker_strength_bonus") else 0
			str_lbl.text = "STR %d" % (base_str + board_bonus)
			str_lbl.add_theme_font_size_override("font_size", 11)
			str_lbl.add_theme_color_override("font_color", Color(0.4, 0.9, 0.9))
			str_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			container.add_child(str_lbl)

		# Hosted counter badge
		var credits: int = c.get_counter("credits")
		var power: int   = c.get_counter("power")
		var virus: int   = c.get_counter("virus")
		if credits > 0 or power > 0 or virus > 0:
			var ctr_lbl := Label.new()
			var parts: Array = []
			if credits > 0: parts.append("%d¢" % credits)
			if power   > 0: parts.append("%d★" % power)
			if virus   > 0: parts.append("%d⚡" % virus)
			ctr_lbl.text = " ".join(parts)
			ctr_lbl.add_theme_font_size_override("font_size", 10)
			ctr_lbl.add_theme_color_override("font_color", Color(0.9, 0.7, 0.3))
			ctr_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			container.add_child(ctr_lbl)


# ── Resources ─────────────────────────────────────────────────────────────────

func _update_resources() -> void:
	_credits_label.text = "¢ %d" % ctx.runner_credits
	_clicks_label.text  = "● %d" % ctx.runner_clicks


# ── Action area helpers ───────────────────────────────────────────────────────

func _clear_actions() -> void:
	for child in _action_area.get_children():
		child.queue_free()


func _add_btn(label: String, callback: Callable, color: Color = Color(0.8, 0.8, 0.8)) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.alignment = HorizontalAlignment.HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_color_override("font_color", color)
	btn.pressed.connect(callback)
	_action_area.add_child(btn)
	return btn


func _add_section(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	_action_area.add_child(lbl)


func _log(msg: String) -> void:
	_run_log.text += msg + "\n"
	_run_log.scroll_vertical = _run_log.get_line_count()


# ── Run machine signal handlers ───────────────────────────────────────────────

func _on_phase_changed(phase: RunStateMachine.Phase) -> void:
	var names := ["INITIATION", "APPROACH ICE", "ENCOUNTER", "MOVEMENT", "SUCCESS", "END"]
	_phase_label.text = names[phase] if phase < names.size() else str(phase)
	_update_resources()
	_clear_actions()
	# Fire run_complete after a brief display pause when the run fully ends
	if phase == RunStateMachine.Phase.END:
		await get_tree().create_timer(0.8).timeout
		run_complete.emit()


func _on_ice_approached(ice_card: InstalledCard) -> void:
	_current_ice = ice_card
	# Refresh server column in case ice was just rezzed
	_rebuild_server_column()
	_highlight_ice(ice_card)
	var name := ice_card.display_name() if ice_card.is_rezzed else "unrezzed ice"
	_log("→ Approaching %s" % name)


func _on_ice_encountered(ice_card: InstalledCard) -> void:
	_current_ice = ice_card
	_highlight_ice(ice_card)
	_log("⚔ Encountering %s (str %d)" % [
		ice_card.display_name(),
		ice_card.card_record.strength if ice_card.card_record else 0
	])


func _on_ice_rezzed(ice_card: InstalledCard) -> void:
	_rebuild_server_column()
	_highlight_ice(ice_card)
	_log("🔓 Corp rezzes %s" % ice_card.display_name())


func _on_subroutine_broken(ice_card: InstalledCard, sub_index: int) -> void:
	_log("✓ Subroutine %d broken" % sub_index)


func _on_encounter_started(encounter: EncounterState) -> void:
	_update_resources()
	_rebuild_rig_row()


func _on_encounter_updated(encounter: EncounterState) -> void:
	_update_resources()
	_rebuild_rig_row()


func _on_run_succeeded(_server_id: String) -> void:
	_reset_ice_highlight()
	_log("✅ Run successful!")
	_update_resources()


func _on_run_ended(_reason: String) -> void:
	_reset_ice_highlight()
	_log("❌ Run ended")
	_update_resources()


# ── Decision maker methods (proxies point here during run) ────────────────────

func show_encounter_prompt(encounter: EncounterState) -> Dictionary:
	_clear_actions()
	_update_resources()
	_rebuild_rig_row()

	var ice_name := encounter.ice_card.display_name() if encounter.ice_card else "ice"
	_add_section("%s  str %d" % [ice_name, encounter.ice_strength])

	# Subroutine status
	for i in range(encounter.subroutines.size()):
		var sub: Dictionary = encounter.subroutines[i] as Dictionary
		var broken_marker := "✓ " if encounter.is_broken(i) else "↳ "
		var color := Color(0.4, 0.7, 0.4) if encounter.is_broken(i) else Color(0.8, 0.8, 0.8)
		var lbl := Label.new()
		lbl.text = broken_marker + sub.get("label", "sub %d" % i)
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_color_override("font_color", color)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		_action_area.add_child(lbl)

	# Bioroid click-break
	if encounter.ice_card != null and encounter.ice_card.card_record != null:
		if encounter.ice_card.card_record.has_subtype("bioroid") and ctx.runner_clicks > 0:
			_add_section("BIOROID — spend 1 click:")
			for i in range(encounter.subroutines.size()):
				if encounter.is_broken(i):
					continue
				var sub: Dictionary = encounter.subroutines[i] as Dictionary
				var idx := i
				_add_btn("[1●] Break: %s" % sub.get("label", "sub %d" % i),
					func(): encounter_action_resolved.emit({"type": "break_with_click", "sub_index": idx}),
					Color(0.9, 0.7, 0.3))

	# Icebreaker actions
	var breakers := encounter.breakers_for_ice()
	if not breakers.is_empty():
		_add_section("ICEBREAKERS:")
		for breaker in breakers:
			var b: InstalledCard = breaker as InstalledCard
			var b_str := encounter.get_breaker_strength(b)
			var can_reach := encounter.breaker_reaches(b)
			var reach_color := Color(0.4, 0.9, 0.5) if can_reach else Color(0.8, 0.4, 0.4)

			_add_section("%s  str %d %s" % [
				b.display_name(), b_str,
				"✓" if can_reach else "✗ (too weak)"
			])

			var break_btn := _add_btn("Break all subs  (1¢ each)",
				func(): encounter_action_resolved.emit({"type": "break_all", "card_id": b.card_id}),
				reach_color)
			break_btn.disabled = not can_reach

			_add_btn("Boost +str  (1¢ per use)",
				func(): encounter_action_resolved.emit({"type": "boost_strength", "card_id": b.card_id, "times": 1}),
				Color(0.5, 0.7, 0.9))

	# Leech hosted credits
	for rig_card in ctx.runner_rig:
		var rc: InstalledCard = rig_card as InstalledCard
		if rc == null or rc.card_record == null:
			continue
		var hosted: int = rc.get_counter("credits")
		if hosted > 0:
			var cid := rc.card_id
			_add_btn("Spend 1¢ from %s  (%d remaining)" % [rc.display_name(), hosted],
				func(): encounter_action_resolved.emit({"type": "spend_hosted_credits", "card_id": cid, "amount": 1}),
				Color(0.9, 0.7, 0.3))

	_add_section("─────────────────")
	_add_btn("Pass — let subroutines fire",
		func(): encounter_action_resolved.emit({"type": "done"}),
		Color(0.7, 0.4, 0.4))

	var result: Dictionary = await encounter_action_resolved
	_clear_actions()
	return result


func show_jack_out_prompt() -> bool:
	_clear_actions()
	_add_section("Jack out?")
	_add_btn("Yes — Jack Out",
		func(): jack_out_resolved.emit(true),
		Color(0.9, 0.6, 0.3))
	_add_btn("No — Continue Run",
		func(): jack_out_resolved.emit(false),
		Color(0.4, 0.9, 0.5))

	var result: bool = await jack_out_resolved
	_clear_actions()
	return result


func show_trash_prompt(card: CardRecord) -> bool:
	_clear_actions()
	var cost := card.trash_cost if card else 0
	var title := card.title if card else "card"
	_add_section("Trash %s for %d¢?" % [title, cost])
	_add_btn("Yes — Trash  (%d¢ available)" % ctx.runner_credits,
		func(): trash_resolved.emit(true),
		Color(0.9, 0.4, 0.4))
	_add_btn("No — Leave it",
		func(): trash_resolved.emit(false))

	var result: bool = await trash_resolved
	_clear_actions()
	return result


func show_payment_option_prompt(options: Array) -> Variant:
	_clear_actions()
	_add_section("Manegarm Skunkworks — pay to continue:")
	for opt in options:
		var o: Dictionary = opt as Dictionary
		var label := ""
		match o.get("type", ""):
			"clicks":  label = "Spend %d click(s)  (%d available)" % [o.get("amount", 0), ctx.runner_clicks]
			"credits": label = "Pay %d¢  (%d available)" % [o.get("amount", 0), ctx.runner_credits]
		var captured := o
		_add_btn(label, func(): payment_resolved.emit(captured), Color(0.9, 0.7, 0.3))
	_add_btn("End the run", func(): payment_resolved.emit(null), Color(0.7, 0.4, 0.4))

	var result: Variant = await payment_resolved
	_clear_actions()
	return result


func show_server_choice_prompt(allowed_servers: Array) -> String:
	_clear_actions()
	_add_section("Choose a server to run:")
	for server_id in allowed_servers:
		var display: String = {"hq": "HQ", "rd": "R&D", "archives": "Archives"}.get(server_id, server_id)
		var sid: String = server_id
		_add_btn(display, func(): server_choice_resolved.emit(sid))

	var result: String = await server_choice_resolved
	_clear_actions()
	return result


func show_modal_prompt(modes: Array, max_choices: int) -> Array:
	_clear_actions()
	_add_section("Choose %d option(s):" % max_choices)
	var chosen: Array = []
	for i in range(modes.size()):
		var mode: Dictionary = modes[i] as Dictionary
		var idx := i
		_add_btn(mode.get("label", "Option %d" % i), func():
			chosen.append(idx)
			if chosen.size() >= max_choices:
				modal_resolved.emit(chosen.duplicate())
		)

	var result: Array = await modal_resolved
	_clear_actions()
	return result


func show_search_prompt(candidates: Array) -> CardRecord:
	_clear_actions()
	_add_section("Search — take which card?")
	for candidate in candidates:
		var r: CardRecord = candidate as CardRecord
		if r == null:
			continue
		var cost_str := "%d¢" % r.cost if r.cost >= 0 else "free"
		var record := r
		_add_btn("%s  [%s] (%s)" % [r.title, r.card_type.capitalize(), cost_str],
			func(): search_resolved.emit(record))

	var result: CardRecord = await search_resolved
	_clear_actions()
	return result

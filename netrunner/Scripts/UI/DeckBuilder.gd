class_name DeckBuilder
extends CanvasLayer

# ── DeckBuilder ───────────────────────────────────────────────────────────────
# Collection browser for building a runner deck from unlocked cards.
# Features: card art hover, filters by type/faction, search bar, influence tracking.
# Emits deck_saved(identity_id, cards_dict) when player confirms.

signal deck_saved(identity_id: String, cards: Dictionary)
signal cancelled

const MIN_DECK_SIZE := 30
const MAX_COPIES    := 3

const COLOR_BG      := Color(0.04, 0.05, 0.07)
const COLOR_PANEL   := Color(0.07, 0.09, 0.11)
const COLOR_BORDER  := Color(0.15, 0.28, 0.18)
const COLOR_ACCENT  := Color(0.25, 0.85, 0.45)
const COLOR_WARN    := Color(0.85, 0.45, 0.25)
const COLOR_IN_DECK := Color(0.2, 0.6, 0.3)
const COLOR_DISABLED:= Color(0.25, 0.28, 0.25)

var _state:         CampaignState
var _identity:      CardRecord = null
var _card_pool:     Array = []   # Array[CardRecord] all unlocked cards
var _pool_counts:   Dictionary = {}   # card_id → max owned
var _deck_cards:    Dictionary = {}   # card_id → count in deck
var _filtered:      Array = []   # current filtered view

# Filter state
var _filter_type:    String = ""    # "" = all
var _filter_faction: String = ""    # "" = all
var _search_text:    String = ""

# UI nodes
var _collection_grid: GridContainer
var _deck_list:        VBoxContainer
var _stats_label:      Label
var _search_field:     LineEdit
var _save_btn:         Button
var _influence_label:  Label


func _ready() -> void:
	layer = 20
	_build_ui()


func setup(state: CampaignState) -> void:
	_state = state
	_identity = CardRegistry.get_card(state.get_runner_identity_id())
	_pool_counts = state.get_unlocked_card_pool()

	# Load current deck
	var deck_data := state.get_current_deck()
	_deck_cards = deck_data.get("cards", {}).duplicate() as Dictionary

	# Build card objects from pool
	_card_pool = []
	for card_id in _pool_counts:
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record != null and not record.is_identity():
			_card_pool.append(record)

	# Sort: type → title
	_card_pool.sort_custom(func(a: CardRecord, b: CardRecord):
		if a.card_type != b.card_type:
			return a.card_type < b.card_type
		return a.title < b.title
	)

	_apply_filters()
	_refresh_stats()


# ── Filtering ─────────────────────────────────────────────────────────────────

func _apply_filters() -> void:
	_filtered = _card_pool.filter(func(r: CardRecord):
		if _filter_type != "" and r.card_type != _filter_type:
			return false
		if _filter_faction != "" and r.faction != _filter_faction:
			return false
		if _search_text != "" and not r.title.to_lower().contains(_search_text.to_lower()):
			return false
		return true
	)
	_rebuild_collection_grid()


# ── Stats ─────────────────────────────────────────────────────────────────────

func _deck_size() -> int:
	var total := 0
	for count in _deck_cards.values():
		total += int(count)
	return total


func _influence_used() -> int:
	if _identity == null:
		return 0
	var identity_faction: String = _identity.faction
	var used := 0
	for card_id in _deck_cards:
		var count: int = int(_deck_cards[card_id])
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record == null:
			continue
		if record.faction != identity_faction:
			used += record.influence_cost * count
	return used


func _influence_limit() -> int:
	if _identity == null:
		return 15
	return _identity.influence_limit if _identity.influence_limit > 0 else 15


func _is_deck_legal() -> bool:
	return _deck_size() >= MIN_DECK_SIZE and _influence_used() <= _influence_limit()


func _refresh_stats() -> void:
	var size   := _deck_size()
	var inf_u  := _influence_used()
	var inf_l  := _influence_limit()
	var legal  := _is_deck_legal()

	var size_color := COLOR_ACCENT if size >= MIN_DECK_SIZE else COLOR_WARN
	var inf_color  := COLOR_ACCENT if inf_u <= inf_l else COLOR_WARN

	_stats_label.text = (
		"Cards: %d / %d min" % [size, MIN_DECK_SIZE]
	)
	_stats_label.add_theme_color_override("font_color",
		COLOR_ACCENT if size >= MIN_DECK_SIZE else COLOR_WARN)

	_influence_label.text = "Influence: %d / %d" % [inf_u, inf_l]
	_influence_label.add_theme_color_override("font_color", inf_color)

	_save_btn.disabled = not legal
	_save_btn.add_theme_color_override("font_color",
		COLOR_ACCENT if legal else COLOR_DISABLED)

	_rebuild_deck_list()


# ── UI Construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	# Scanlines
	root.add_child(_make_scanlines())

	# Header
	var header := _build_header()
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.custom_minimum_size = Vector2(0, 72)
	header.offset_bottom = 72
	root.add_child(header)

	# Main layout: collection (left) + deck (right)
	var main_hbox := HBoxContainer.new()
	main_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_hbox.offset_top    = 80
	main_hbox.offset_left   = 12
	main_hbox.offset_right  = -12
	main_hbox.offset_bottom = -12
	main_hbox.add_theme_constant_override("separation", 12)
	root.add_child(main_hbox)

	# Left: filter bar + collection grid
	var left_vbox := VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.add_theme_constant_override("separation", 6)
	main_hbox.add_child(left_vbox)

	left_vbox.add_child(_build_filter_bar())

	var collection_scroll := ScrollContainer.new()
	collection_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	collection_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_vbox.add_child(collection_scroll)

	_collection_grid = GridContainer.new()
	_collection_grid.columns = 6
	_collection_grid.add_theme_constant_override("h_separation", 8)
	_collection_grid.add_theme_constant_override("v_separation", 8)
	_collection_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collection_scroll.add_child(_collection_grid)

	# Right: deck list + stats
	var right_panel := _make_panel(360, true)
	main_hbox.add_child(right_panel)

	var right_vbox := VBoxContainer.new()
	right_vbox.add_theme_constant_override("separation", 6)
	right_panel.add_child(right_vbox)

	var deck_header := Label.new()
	deck_header.text = "// YOUR DECK //"
	deck_header.add_theme_font_size_override("font_size", 12)
	deck_header.add_theme_color_override("font_color", Color(0.3, 0.6, 0.35))
	right_vbox.add_child(deck_header)

	# Stats row
	var stats_row := HBoxContainer.new()
	right_vbox.add_child(stats_row)

	_stats_label = Label.new()
	_stats_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats_label.add_theme_font_size_override("font_size", 11)
	stats_row.add_child(_stats_label)

	_influence_label = Label.new()
	_influence_label.add_theme_font_size_override("font_size", 11)
	stats_row.add_child(_influence_label)

	var sep := HSeparator.new()
	sep.add_theme_color_override("separation_color", COLOR_BORDER)
	right_vbox.add_child(sep)

	# Deck list scroll
	var deck_scroll := ScrollContainer.new()
	deck_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	deck_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_vbox.add_child(deck_scroll)

	_deck_list = VBoxContainer.new()
	_deck_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_deck_list.add_theme_constant_override("separation", 2)
	deck_scroll.add_child(_deck_list)

	# Save / Cancel buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	right_vbox.add_child(btn_row)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func(): cancelled.emit(); queue_free())
	btn_row.add_child(cancel_btn)

	_save_btn = Button.new()
	_save_btn.text = "▶  Save Deck"
	_save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_btn.pressed.connect(_on_save_pressed)
	btn_row.add_child(_save_btn)


func _build_header() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.10)
	style.border_color = COLOR_BORDER
	style.border_width_bottom = 1
	style.content_margin_left = 20
	style.content_margin_top  = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	panel.add_child(hbox)

	var title := Label.new()
	title.text = "// DECK BUILDER"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOR_ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(title)

	var identity_label := Label.new()
	identity_label.text = "IDENTITY: %s" % (
		_identity.title if _identity != null else "Unknown"
	)
	identity_label.add_theme_font_size_override("font_size", 11)
	identity_label.add_theme_color_override("font_color", Color(0.4, 0.6, 0.45))
	hbox.add_child(identity_label)

	return panel


func _build_filter_bar() -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	# Search
	_search_field = LineEdit.new()
	_search_field.placeholder_text = "Search cards..."
	_search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_field.text_changed.connect(func(t: String):
		_search_text = t
		_apply_filters()
	)
	hbox.add_child(_search_field)

	# Type filter
	var type_opts := OptionButton.new()
	type_opts.custom_minimum_size = Vector2(120, 0)
	for pair in [["All Types", ""], ["Event", "event"], ["Program", "program"],
				 ["Hardware", "hardware"], ["Resource", "resource"]]:
		type_opts.add_item(pair[0])
		type_opts.set_item_metadata(type_opts.item_count - 1, pair[1])
	type_opts.item_selected.connect(func(idx: int):
		_filter_type = type_opts.get_item_metadata(idx)
		_apply_filters()
	)
	hbox.add_child(type_opts)

	# Faction filter
	var faction_opts := OptionButton.new()
	faction_opts.custom_minimum_size = Vector2(130, 0)
	for pair in [["All Factions", ""], ["Anarch", "anarch"],
				 ["Criminal", "criminal"], ["Shaper", "shaper"]]:
		faction_opts.add_item(pair[0])
		faction_opts.set_item_metadata(faction_opts.item_count - 1, pair[1])
	faction_opts.item_selected.connect(func(idx: int):
		_filter_faction = faction_opts.get_item_metadata(idx)
		_apply_filters()
	)
	hbox.add_child(faction_opts)

	# Clear button
	var clear_btn := Button.new()
	clear_btn.text = "✕ Clear"
	clear_btn.pressed.connect(func():
		_search_field.text = ""
		_search_text   = ""
		_filter_type   = ""
		_filter_faction = ""
		type_opts.selected   = 0
		faction_opts.selected = 0
		_apply_filters()
	)
	hbox.add_child(clear_btn)

	return hbox


# ── Collection grid ───────────────────────────────────────────────────────────

func _rebuild_collection_grid() -> void:
	for child in _collection_grid.get_children():
		child.queue_free()

	for record in _filtered:
		_collection_grid.add_child(_make_collection_card(record))


func _make_collection_card(record: CardRecord) -> Control:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)
	container.custom_minimum_size = Vector2(130, 0)

	# Card art
	var card_view := CardView.new()
	container.add_child(card_view)
	card_view.setup(record, true)

	# Count row: [-] [n/max] [+]
	var count_row := HBoxContainer.new()
	count_row.alignment = BoxContainer.ALIGNMENT_CENTER
	count_row.add_theme_constant_override("separation", 4)
	container.add_child(count_row)

	var in_deck: int   = int(_deck_cards.get(record.id, 0))
	var max_own: int   = int(_pool_counts.get(record.id, 0))
	var inf_cost: int  = record.influence_cost
	var is_faction: bool = _identity != null and record.faction == _identity.faction

	var minus_btn := Button.new()
	minus_btn.text = "−"
	minus_btn.custom_minimum_size = Vector2(28, 0)
	minus_btn.disabled = in_deck <= 0
	minus_btn.pressed.connect(func(): _change_count(record.id, -1))
	count_row.add_child(minus_btn)

	var count_label := Label.new()
	count_label.text = "%d/%d" % [in_deck, max_own]
	count_label.custom_minimum_size = Vector2(36, 0)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_label.add_theme_font_size_override("font_size", 11)
	count_label.add_theme_color_override("font_color",
		COLOR_IN_DECK if in_deck > 0 else Color(0.4, 0.45, 0.4))
	count_row.add_child(count_label)

	var plus_btn := Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size = Vector2(28, 0)
	plus_btn.disabled = in_deck >= max_own
	plus_btn.pressed.connect(func(): _change_count(record.id, +1))
	count_row.add_child(plus_btn)

	# Influence pip (show for out-of-faction cards)
	if inf_cost > 0 and not is_faction:
		var inf_label := Label.new()
		inf_label.text = "●".repeat(inf_cost)
		inf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		inf_label.add_theme_font_size_override("font_size", 9)
		inf_label.add_theme_color_override("font_color", Color(0.8, 0.5, 0.2))
		container.add_child(inf_label)

	return container


# ── Deck list ─────────────────────────────────────────────────────────────────

func _rebuild_deck_list() -> void:
	for child in _deck_list.get_children():
		child.queue_free()

	# Group by card type
	var by_type: Dictionary = {}
	for card_id in _deck_cards:
		var count: int = int(_deck_cards[card_id])
		if count <= 0:
			continue
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record == null:
			continue
		var ctype: String = record.card_type
		if ctype not in by_type:
			by_type[ctype] = []
		by_type[ctype].append({"record": record, "count": count})

	var type_order := ["event", "program", "hardware", "resource"]
	for ctype in type_order:
		if ctype not in by_type:
			continue
		var entries: Array = by_type[ctype]
		entries.sort_custom(func(a, b): return a["record"].title < b["record"].title)

		var header := Label.new()
		header.text = ctype.to_upper()
		header.add_theme_font_size_override("font_size", 9)
		header.add_theme_color_override("font_color", Color(0.3, 0.55, 0.35))
		_deck_list.add_child(header)

		for entry in entries:
			var record: CardRecord = entry["record"]
			var count: int         = entry["count"]
			_deck_list.add_child(_make_deck_entry(record, count))


func _make_deck_entry(record: CardRecord, count: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var count_lbl := Label.new()
	count_lbl.text = "%d×" % count
	count_lbl.custom_minimum_size = Vector2(22, 0)
	count_lbl.add_theme_font_size_override("font_size", 11)
	count_lbl.add_theme_color_override("font_color", COLOR_IN_DECK)
	row.add_child(count_lbl)

	var name_lbl := Label.new()
	name_lbl.text = record.title
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.add_theme_color_override("font_color", Color(0.8, 0.9, 0.82))
	row.add_child(name_lbl)

	# Influence cost if out-of-faction
	var is_faction: bool = _identity != null and record.faction == _identity.faction
	if record.influence_cost > 0 and not is_faction:
		var inf_lbl := Label.new()
		inf_lbl.text = "●".repeat(record.influence_cost)
		inf_lbl.add_theme_font_size_override("font_size", 9)
		inf_lbl.add_theme_color_override("font_color", Color(0.8, 0.5, 0.2))
		row.add_child(inf_lbl)

	# Remove button
	var rm_btn := Button.new()
	rm_btn.text = "−"
	rm_btn.custom_minimum_size = Vector2(24, 0)
	rm_btn.pressed.connect(func(): _change_count(record.id, -1))
	row.add_child(rm_btn)

	return row


# ── Card count changes ────────────────────────────────────────────────────────

func _change_count(card_id: String, delta: int) -> void:
	var current: int = int(_deck_cards.get(card_id, 0))
	var max_own: int = int(_pool_counts.get(card_id, 0))
	var new_count: int = clamp(current + delta, 0, min(max_own, MAX_COPIES))

	if new_count == 0:
		_deck_cards.erase(card_id)
	else:
		_deck_cards[card_id] = new_count

	_apply_filters()
	_refresh_stats()


# ── Save ──────────────────────────────────────────────────────────────────────

func _on_save_pressed() -> void:
	var identity_id: String = _state.get_runner_identity_id()
	_state.save_deck(identity_id, _deck_cards)
	deck_saved.emit(identity_id, _deck_cards)
	queue_free()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_panel(min_width: int = 0, expand_v: bool = false) -> PanelContainer:
	var panel := PanelContainer.new()
	if min_width > 0:
		panel.custom_minimum_size = Vector2(min_width, 0)
	if expand_v:
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.border_color = COLOR_BORDER
	for side in [0, 1, 2, 3]:
		style.set("border_width_%s" % ["top","right","bottom","left"][side], 1)
	style.corner_radius_top_left     = 6
	style.corner_radius_top_right    = 6
	style.corner_radius_bottom_left  = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left   = 14
	style.content_margin_right  = 14
	style.content_margin_top    = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _make_scanlines() -> Control:
	var scanlines := ColorRect.new()
	scanlines.set_anchors_preset(Control.PRESET_FULL_RECT)
	var shader_code := """
shader_type canvas_item;
void fragment() {
	float line = mod(FRAGCOORD.y, 4.0);
	float alpha = line < 2.0 ? 0.0 : 0.04;
	COLOR = vec4(0.0, 0.0, 0.0, alpha);
}
"""
	var shader := Shader.new()
	shader.code = shader_code
	var mat := ShaderMaterial.new()
	mat.shader = shader
	scanlines.material = mat
	return scanlines

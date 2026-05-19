class_name CardView
extends Control

# ── CardView ──────────────────────────────────────────────────────────────────
# Displays a full‑card image with rounded corners. Size is 15% larger than
# standard (130×182 → ~150×209). Art loads asynchronously via CardArt autoload.

const BASE_W := 130.0
const BASE_H := 182.0
const SCALE_FACTOR := 1.15

var CARD_W: float
var CARD_H: float

var _art_rect: TextureRect
var _unrezzed_overlay: ColorRect
var _card_record: CardRecord = null
var _is_rezzed:   bool       = true

# Shader for rounded corners – will be created once and reused
static var _rounded_corner_shader: Shader = null
static var _rounded_material: ShaderMaterial = null


func _ready() -> void:
	# Calculate scaled dimensions
	CARD_W = BASE_W * SCALE_FACTOR
	CARD_H = BASE_H * SCALE_FACTOR
	
	custom_minimum_size = Vector2(CARD_W, CARD_H)
	size                = Vector2(CARD_W, CARD_H)
	
	_build_ui()
	
	# Listen for art loading
	var art_manager = get_node_or_null("/root/CardArt")
	if art_manager:
		art_manager.texture_ready.connect(_on_texture_ready)
	else:
		print("Warning: CardArt autoload not found – art will not load.")


# ── Public API ────────────────────────────────────────────────────────────────

func setup(record: CardRecord, rezzed: bool = true) -> void:
	_card_record = record
	_is_rezzed   = rezzed
	_populate()


func set_rezzed(rezzed: bool) -> void:
	_is_rezzed = rezzed
	if _card_record != null:
		_populate()


# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Create rounded corner material (shared across all cards)
	_create_rounded_material()
	
	# Art area – covers the entire card
	_art_rect = TextureRect.new()
	_art_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_art_rect.expand = true
	_art_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art_rect.material = _rounded_material  # ← rounded corners
	add_child(_art_rect)
	
	# Unrezzed overlay
	_unrezzed_overlay = ColorRect.new()
	_unrezzed_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_unrezzed_overlay.color   = Color(0.08, 0.08, 0.12, 0.92)
	_unrezzed_overlay.visible = false
	_unrezzed_overlay.material = _rounded_material  # ← same rounded corners
	add_child(_unrezzed_overlay)
	
	var unrezzed_label := Label.new()
	unrezzed_label.text = "?"
	unrezzed_label.add_theme_font_size_override("font_size", 32)
	unrezzed_label.add_theme_color_override("font_color", Color(0.3, 0.3, 0.4, 1.0))
	unrezzed_label.set_anchors_preset(Control.PRESET_CENTER)
	unrezzed_label.offset_left = -16
	unrezzed_label.offset_top  = -20
	unrezzed_label.size        = Vector2(32, 40)
	unrezzed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_unrezzed_overlay.add_child(unrezzed_label)


# ── Rounded corner shader ─────────────────────────────────────────────────────

static func _create_rounded_material() -> void:
	if _rounded_material != null:
		return
	
	# Shader code that rounds corners (radius = 6% of the smaller dimension)
	var shader_code = """
	shader_type canvas_item;
	
	uniform float corner_radius : hint_range(0, 0.2) = 0.06;
	
	void fragment() {
		vec2 size = UV * 2.0 - 1.0;  // range -1..1
		float rx = abs(size.x);
		float ry = abs(size.y);
		float r = corner_radius * 2.0;  // because UV is 0..1, radius in UV space
		
		if (rx > 1.0 - r && ry > 1.0 - r) {
			float corner_dist = length(vec2(rx - (1.0 - r), ry - (1.0 - r)));
			if (corner_dist > r) {
				discard;
			}
		}
	}
	"""
	
	_rounded_corner_shader = Shader.new()
	_rounded_corner_shader.code = shader_code
	_rounded_material = ShaderMaterial.new()
	_rounded_material.shader = _rounded_corner_shader
	_rounded_material.set_shader_parameter("corner_radius", 0.06)  # adjust as needed


# ── Population ────────────────────────────────────────────────────────────────

func _populate() -> void:
	if _card_record == null:
		return
	
	var art_manager = get_node_or_null("/root/CardArt")
	if art_manager:
		_art_rect.texture = art_manager.get_texture(_card_record.printing_id)
	else:
		_art_rect.texture = null
	
	_unrezzed_overlay.visible = not _is_rezzed


func _on_texture_ready(printing_id: String, texture: Texture2D) -> void:
	if _card_record != null and printing_id == _card_record.printing_id:
		_art_rect.texture = texture

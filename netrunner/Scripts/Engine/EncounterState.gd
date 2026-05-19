class_name EncounterState
extends RefCounted

# ── EncounterState ────────────────────────────────────────────────────────────
# Lives for exactly one ice encounter. Tracks which subroutines are broken,
# each installed icebreaker's temporary strength boost, and credit spending.
# Discarded after the encounter ends — boosts do not persist between encounters.

# The ice being encountered
var ice_card:       InstalledCard = null
var ice_strength:   int           = 0
var subroutines:    Array         = []   # Array[Dictionary] from AbilityRegistry
var broken_indices: Array         = []   # Array[int] — broken subroutine indices

# Per-icebreaker temporary strength boosts for this encounter.
# Keys are card_id (String), values are int (temporary boost amount).
var temp_strength_boosts: Dictionary = {}

# Reference to installed icebreakers available this encounter
var available_breakers: Array = []   # Array[InstalledCard]

# Optional GameContext reference for querying board-wide modifiers (e.g. Turbine)
var ctx: Object = null


# ── Construction ──────────────────────────────────────────────────────────────

static func make(ice: InstalledCard, subs: Array, breakers: Array, game_ctx: Object = null) -> EncounterState:
	var e              := EncounterState.new()
	e.ice_card         = ice
	e.ice_strength     = ice.card_record.strength if ice.card_record != null else 0
	e.subroutines      = subs.duplicate()
	e.broken_indices   = []
	e.available_breakers = breakers.duplicate()
	e.ctx              = game_ctx
	return e


# ── Strength queries ──────────────────────────────────────────────────────────

# Current effective strength of a breaker including temporary boosts and board modifiers
func get_breaker_strength(breaker: InstalledCard) -> int:
	var base: int  = breaker.card_record.strength if breaker.card_record != null else 0
	var boost: int = temp_strength_boosts.get(breaker.card_id, 0)
	var board_bonus: int = 0
	if ctx != null and ctx.has_method("query_breaker_strength_bonus"):
		board_bonus = ctx.query_breaker_strength_bonus()
	return base + boost + board_bonus


# Whether a breaker meets or exceeds the ice strength
func breaker_reaches(breaker: InstalledCard) -> bool:
	return get_breaker_strength(breaker) >= ice_strength


# Apply a temporary strength boost to a breaker
func apply_boost(breaker: InstalledCard, amount: int) -> void:
	var current: int = temp_strength_boosts.get(breaker.card_id, 0)
	temp_strength_boosts[breaker.card_id] = current + amount


# ── Subroutine queries ────────────────────────────────────────────────────────

func is_broken(sub_index: int) -> bool:
	return broken_indices.has(sub_index)

func break_subroutine(sub_index: int) -> void:
	if not broken_indices.has(sub_index):
		broken_indices.append(sub_index)

func all_broken() -> bool:
	return broken_indices.size() >= subroutines.size()

func unbroken_indices() -> Array:
	var result: Array = []
	for i in range(subroutines.size()):
		if not broken_indices.has(i):
			result.append(i)
	return result


# ── Breaker queries ───────────────────────────────────────────────────────────

# Returns all installed breakers that can interact with the encountered ice
# based on subtype matching.
func breakers_for_ice() -> Array:
	if ice_card == null or ice_card.card_record == null:
		return []

	var ice_subtypes: Array = ice_card.card_record.subtypes
	var result: Array       = []

	for breaker in available_breakers:
		var b: InstalledCard = breaker as InstalledCard
		if b.card_record == null:
			continue
		if _breaker_matches_ice(b, ice_subtypes):
			result.append(b)

	return result


func _breaker_matches_ice(breaker: InstalledCard, ice_subtypes: Array) -> bool:
	var breaker_subtypes: Array = breaker.card_record.subtypes

	# AI breakers can interact with any ice
	if breaker_subtypes.has("ai"):
		return true

	# Standard matching: fracter/barrier, decoder/code_gate, killer/sentry
	const MATCHES := {
		"fracter": "barrier",
		"decoder": "code_gate",
		"killer":  "sentry",
	}

	for breaker_type in MATCHES:
		if breaker_subtypes.has(breaker_type):
			var ice_type: String = MATCHES[breaker_type]
			if ice_subtypes.has(ice_type):
				return true

	return false


# ── Display ───────────────────────────────────────────────────────────────────

func describe() -> String:
	var ice_name: String = ice_card.display_name() if ice_card else "?"
	var broken_count := broken_indices.size()
	var total_count  := subroutines.size()
	return "%s (str %d) — %d/%d subs broken" % [ice_name, ice_strength, broken_count, total_count]

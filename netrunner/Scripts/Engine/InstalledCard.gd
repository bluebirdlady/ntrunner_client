class_name InstalledCard
extends RefCounted

# ── InstalledCard ─────────────────────────────────────────────────────────────
# Represents a single card installed in a server's ice or root zone.
# The Corp always knows what every card is. The Runner's information model
# (what they believe about unrezzed cards) is handled separately.

var card_id:     String     = ""    # stable slug from CardRegistry
var card_record: CardRecord = null  # null only transiently during construction
var is_rezzed:   bool       = false
var counters:    Dictionary = {}    # {"advancement": 0, "power": 0, "credits": 0}
var server_id:   String     = ""    # "hq" | "rd" | "archives" | "remote_0" etc.
var zone:        String     = ""    # "ice" | "root"
var runtime_instance_id: String = ""

static func make_runtime_instance(record: CardRecord, srv_id: String, srv_zone: String, rezzed: bool = false) -> InstalledCard:
	var c = InstalledCard.make(record, srv_id, srv_zone, rezzed)
	# Assign clean global UUID or structural numeric string
	c.runtime_instance_id = "%s_%d_%d" % [record.id, Time.get_ticks_msec(), randi() % 1000]
	return c

# ── Construction ──────────────────────────────────────────────────────────────

static func make(record: CardRecord, srv_id: String, srv_zone: String, rezzed: bool = false) -> InstalledCard:
	var c        := InstalledCard.new()
	c.card_id    = record.id
	c.card_record= record
	c.server_id  = srv_id
	c.zone       = srv_zone
	c.is_rezzed  = rezzed
	c.counters   = {"advancement": 0, "power": 0, "credits": 0}
	return c


# ── Counter helpers ───────────────────────────────────────────────────────────

func get_counter(counter_type: String) -> int:
	return counters.get(counter_type, 0)

func add_counter(counter_type: String, amount: int = 1) -> void:
	counters[counter_type] = get_counter(counter_type) + amount

func remove_counter(counter_type: String, amount: int = 1) -> void:
	counters[counter_type] = max(0, get_counter(counter_type) - amount)


# ── Convenience ───────────────────────────────────────────────────────────────

func is_ice() -> bool:
	return zone == "ice"

func is_in_root() -> bool:
	return zone == "root"

func can_be_advanced() -> bool:
	if card_record == null:
		return false
	return card_record.is_agenda() or card_record.text.contains("can be advanced")

func meets_advancement_requirement() -> bool:
	if card_record == null:
		return false
	return get_counter("advancement") >= card_record.advancement_requirement

func display_name() -> String:
	if card_record != null:
		return card_record.title
	return "(%s)" % card_id

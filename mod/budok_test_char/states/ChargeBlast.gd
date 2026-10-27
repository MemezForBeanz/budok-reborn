extends CharacterState

# Spends up to `data.count` banked charges; each adds 30 damage to the blast.

const BASE_DAMAGE = 50
const DAMAGE_PER_CHARGE = 30

var spent = 0


# The character loader repacks custom character scenes after loading them,
# which drops nodes nested under states inherited from another character's
# scene (this test fighter inherits Ninja's). Recreate the hitbox if needed.
func init():
	if get_node_or_null("Hitbox") == null:
		var box = load("res://mechanics/Hitbox.gd").new()
		box.name = "Hitbox"
		box.x = 26
		box.y = -16
		box.width = 22
		box.height = 14
		box.damage = BASE_DAMAGE
		box.hitstun_ticks = 24
		box.start_tick = 8
		box.active_ticks = 3
		add_child(box)
	.init()


func _enter():
	spent = 0
	if data is Dictionary and data.has("count"):
		spent = int(min(int(data["count"]), host.charge_level))
	host.charge_level -= spent
	# Hitboxes are tracked by the state, not looked up by path at runtime.
	for box in all_hitbox_nodes:
		box.damage = BASE_DAMAGE + DAMAGE_PER_CHARGE * spent
	._enter()

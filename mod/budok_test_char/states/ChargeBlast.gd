extends CharacterState

# Spends up to `data.count` banked charges; each adds 30 damage to the blast.

const BASE_DAMAGE = 50
const DAMAGE_PER_CHARGE = 30

var spent = 0


func _enter():
	spent = 0
	if data is Dictionary and data.has("count"):
		spent = int(min(int(data["count"]), host.charge_level))
	host.charge_level -= spent
	$Hitbox.damage = BASE_DAMAGE + DAMAGE_PER_CHARGE * spent
	._enter()

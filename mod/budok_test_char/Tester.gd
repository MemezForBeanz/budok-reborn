extends "res://characters/stickman/Stickman.gd"

# Ninja with a "charge" resource: the Charge extra toggle banks one charge per
# turn (up to MAX_CHARGE); ChargeBlast spends charges for extra damage.

const MAX_CHARGE = 3

var charge_level = 0


func process_extra(extra):
	.process_extra(extra)
	if extra.has("charge") and extra["charge"] and charge_level < MAX_CHARGE:
		charge_level += 1

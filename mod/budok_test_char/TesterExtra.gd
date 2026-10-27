extends "res://ui/ActionSelector/PlayerExtra.gd"

onready var charge_button = $ChargeButton


func _ready():
	charge_button.connect("toggled", self, "_on_charge_toggled")


func _on_charge_toggled(_on):
	emit_signal("data_changed")


func show_options():
	charge_button.visible = fighter.charge_level < fighter.MAX_CHARGE
	charge_button.set_pressed_no_signal(false)


func update_selected_move(move_state):
	.update_selected_move(move_state)
	# Charging is a stance-free action; it cannot be combined with defense.
	var defending = move_state != null and move_state.get("type") == CharacterState.ActionType.Defense
	charge_button.disabled = defending
	if defending:
		charge_button.set_pressed_no_signal(false)


func get_extra():
	return {"charge": charge_button.pressed and not charge_button.disabled}


func reset():
	.reset()
	charge_button.set_pressed_no_signal(false)

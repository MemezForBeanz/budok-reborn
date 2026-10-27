extends Node

# Registers the test fighter with the game's built-in character loader.


func _init(mod_loader = ModLoader) -> void:
	mod_loader.installScriptExtension("res://budok_test_char/CharacterSelect.gd")

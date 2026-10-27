extends Node

# Mod loader entry point. The loader instances this script with itself as the
# argument and keeps it as a child of the ModLoader autoload, which outlives
# scene changes, so budok keeps running across menus and matches.

const Runtime = preload("res://budok/core/Runtime.gd")

var runtime = null


func _init(_mod_loader = null) -> void:
	name = "budok"


func _ready() -> void:
	runtime = Runtime.new()
	runtime.name = "Runtime"
	add_child(runtime)

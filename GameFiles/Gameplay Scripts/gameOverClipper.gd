extends Node2D
## The game-over screen — a film clapperboard that snaps shut on your final score.
##
## Reachable via the "clipperBoy" group. [method myCondolences] is the entry point the
## player calls on death: it plays the "GG" sting, closes the clapperboard, and prints the
## final score (distance + bonus, zero-padded). Its own button returns to the main menu.
## (The attempt itself is auto-saved by Replay.stop() as the rolling last replay — rename
## it in the Settings replay browser to keep it.)

var bg_music := AudioStreamPlayer.new()

var score:int  ## The final score shown (distance + bonus).

func _ready() -> void:
	add_to_group("clipperBoy")
	bg_music.stream = load("res://GameFiles/OST/Gameplay/GG.mp3")
	bg_music.bus = "Music"

## Show the game-over screen with the final score. ("My condolences" — you died.)
func myCondolences() -> void:
	bg_music.autoplay = true
	add_child(bg_music)
	get_tree().get_nodes_in_group("PowerupPopUps")[0].text = "REPLAY SAVED IN SETTINGS"
	get_tree().get_nodes_in_group("PowerupPopUps")[0].get_node("AnimationPlayer").play("PopUp")
	get_node("Top2").get_node("AnimationPlayer").play("close")
	visible = true
	score = get_tree().get_first_node_in_group("Score").sc
	score += get_tree().get_first_node_in_group("Score").of
	get_node("highScore").text = "00000000".substr(str(score).length()) + str(score)

func _on_animation_player_animation_finished(_anim_name:String) -> void:
	await get_tree().create_timer(0.5).timeout


func _on_button_released() -> void:
	get_tree().change_scene_to_file("res://MainMenu.tscn")

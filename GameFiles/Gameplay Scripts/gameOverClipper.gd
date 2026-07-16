extends Node2D
## The game-over screen — a film clapperboard that snaps shut on your final score.
##
## Reachable via the "clipperBoy" group. [method myCondolences] is the entry point the
## player calls on death: it plays the "GG" sting, closes the clapperboard, prints the
## final score (distance + bonus, zero-padded), and offers a SAVE REPLAY button for the
## attempt that just ended. Its own button returns to the main menu.

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
	get_node("Top2").get_node("AnimationPlayer").play("close")
	visible = true
	score = get_tree().get_first_node_in_group("Score").sc
	score += get_tree().get_first_node_in_group("Score").of
	get_node("highScore").text = "00000000".substr(str(score).length()) + str(score)
	_offer_replay_save()

## Adds the SAVE REPLAY button under the score (built in code so every mode scene gets it
## without scene edits — plain placeholder styling until it gets dedicated art). Pressing it
## writes the just-finished recording to user://replays/ and locks the button.
func _offer_replay_save() -> void:
	if not Replay.has_pending():
		return
	var b := Button.new()
	b.name = "SaveReplayBTN"
	b.text = "SAVE REPLAY"
	b.process_mode = Node.PROCESS_MODE_ALWAYS  # the tree is paused on the game-over screen
	b.custom_minimum_size = Vector2(340, 64)
	b.add_theme_font_size_override("font_size", 32)
	var hs: Label = get_node("highScore")
	b.position = hs.position + Vector2(hs.size.x / 2.0 - 170, hs.size.y + 24)
	b.pressed.connect(func():
		if Replay.save_pending():
			b.text = "REPLAY SAVED"
			b.disabled = true
	)
	add_child(b)

func _on_animation_player_animation_finished(_anim_name:String) -> void:
	await get_tree().create_timer(0.5).timeout


func _on_button_released() -> void:
	get_tree().change_scene_to_file("res://MainMenu.tscn")

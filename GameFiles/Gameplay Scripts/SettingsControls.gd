extends Control
## The interactive controls inside the main-menu Settings panel.
##
## A functional, deliberately-plain set of controls wired to the [code]Settings[/code] autoload,
## laid out in two columns: the settings (music volume, haptics, screen shake, assist draw) on the
## left, the saved-replays browser on the right. It's instanced into the Settings popup by
## settingsMenu.gd. Restyle/reposition the nodes in SettingsControls.tscn to taste — update the
## @onready paths below if you rename or reparent them.
##
## Its process_mode is ALWAYS (set in the scene) so the controls still work while the menu is paused.

@onready var music: HSlider = $Center/Columns/SettingsCol/MusicSlider
@onready var haptics: CheckButton = $Center/Columns/SettingsCol/Haptics
@onready var shake: CheckButton = $Center/Columns/SettingsCol/Shake
@onready var assist: HSlider = $Center/Columns/SettingsCol/AssistSlider
@onready var replay_list: ItemList = $Center/Columns/ReplaysCol/ReplayList
@onready var watch_btn: Button = $Center/Columns/ReplaysCol/WatchBTN
@onready var folder_btn: Button = $Center/Columns/ReplaysCol/FolderBTN

func _ready() -> void:
	# Seed the controls from the saved settings...
	music.value = Settings.music_volume
	haptics.button_pressed = Settings.haptics_on
	shake.button_pressed = Settings.shake_on
	assist.value = Settings.draw_offset
	# ...then persist + apply any change the player makes.
	music.value_changed.connect(func(v): Settings.set_value("music_volume", v))
	haptics.toggled.connect(func(on): Settings.set_value("haptics_on", on))
	shake.toggled.connect(func(on): Settings.set_value("shake_on", on))
	assist.value_changed.connect(func(v): Settings.set_value("draw_offset", v))
	# The saved-replays browser: pick a file, watch it in the replay viewer.
	for f in Replay.list_replays():
		replay_list.add_item(f)
	watch_btn.pressed.connect(_on_watch_pressed)
	folder_btn.pressed.connect(_on_folder_pressed)

func _on_watch_pressed() -> void:
	var sel: PackedInt32Array = replay_list.get_selected_items()
	if sel.is_empty():
		return
	Replay.watch(replay_list.get_item_text(sel[0]))

## Opens the replays directory in the system file manager (so replays can be backed up,
## shared, or dropped in from someone else). Desktop-oriented; Android file managers may
## not answer the request, in which case nothing happens.
func _on_folder_pressed() -> void:
	OS.shell_open("file://" + ProjectSettings.globalize_path(Replay.DIR))

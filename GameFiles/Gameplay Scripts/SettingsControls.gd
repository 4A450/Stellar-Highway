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
@onready var rename_edit: LineEdit = $Center/Columns/ReplaysCol/RenameRow/RenameEdit
@onready var rename_btn: Button = $Center/Columns/ReplaysCol/RenameRow/RenameBTN
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
	# The saved-replays browser: pick a file, watch it — or rename it to keep it (every run
	# overwrites "last", so renaming is how a replay is saved permanently).
	_refresh_replays()
	replay_list.item_selected.connect(func(i: int):
		rename_edit.text = replay_list.get_item_text(i).trim_suffix(".srp")
	)
	watch_btn.pressed.connect(_on_watch_pressed)
	rename_btn.pressed.connect(_on_rename_pressed)
	folder_btn.pressed.connect(_on_folder_pressed)

func _refresh_replays() -> void:
	replay_list.clear()
	for f in Replay.list_replays():
		replay_list.add_item(f)

func _on_watch_pressed() -> void:
	var sel: PackedInt32Array = replay_list.get_selected_items()
	if sel.is_empty():
		return
	Replay.watch(replay_list.get_item_text(sel[0]))

## Renames the selected replay to the typed name. Renaming "last" is how a run is kept —
## once it has another name, the next run's auto-save can't overwrite it.
func _on_rename_pressed() -> void:
	var sel: PackedInt32Array = replay_list.get_selected_items()
	if sel.is_empty():
		return
	var renamed := Replay.rename_replay(replay_list.get_item_text(sel[0]), rename_edit.text)
	if renamed.is_empty():
		return
	_refresh_replays()
	for i in range(replay_list.item_count):  # keep the renamed file selected
		if replay_list.get_item_text(i) == renamed:
			replay_list.select(i)
			break

## Opens the replays directory in the system file manager (so replays can be backed up,
## shared, or dropped in from someone else). Desktop-oriented; Android file managers may
## not answer the request, in which case nothing happens.
func _on_folder_pressed() -> void:
	OS.shell_open("file://" + ProjectSettings.globalize_path(Replay.DIR))

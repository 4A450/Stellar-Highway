extends Node
## Autoloaded as [code]Replay[/code]: records every run in full; save it, then watch it back.
##
## [b]Recording[/b] — the mode root script calls [method start_run] as the scene loads (before
## the generators pre-fill the world). Each physics tick (pauses excluded) the recorder samples
## the player and everything around it:
## [br]• the player's position/rotation, and the HUD powerup icons' visibility (so playback
##   knows what was carried, and so reconstructed buildings roll the same powerup odds);
## [br]• every [b]obstacle spawn[/b] — generators seed the global RNG via [method seed_spawn]
##   right before instancing and register the node with [method track], so a replay can rebuild
##   the exact same procedural obstacle from (scene path + seed + props). This is why obstacle
##   scripts must never call randomize() (see Refs._ready);
## [br]• trajectories for entities whose motion depends on the player (homing missiles, the
##   Doppelgänger clone — auto-discovered) and for the scene-authored starting platform —
##   delta-compressed, so parked entities cost almost nothing; despawn ticks for everything,
##   plus the exact detonation moment of missiles ([method mark_explosion]);
## [br]• every [b]drawn line segment[/b] (with its Rockstar star, if any) and the tick it started
##   fading — so lines vanish in playback exactly when the ball rolled off them;
## [br]• pickup [b]events[/b]: star collections, powerup grabs, speed-booster hits.
##
## On game over, player_physics calls [method stop]: the finished recording is written straight
## to [constant DIR] as the rolling [b]last replay[/b] ([code]last.srp[/code], atomic like the
## saves), overwritten by every run. To keep a run permanently, the player [b]renames[/b] it in
## the Settings replay browser ([method rename_replay]) — a renamed file is no longer "last",
## so nothing overwrites it (the BombSquad model). Quitting mid-run discards the recording.
##
## [b]Watching[/b] — the Settings panel lists [method list_replays]; [method watch] opens
## ReplayViewer.tscn, which rebuilds the run: seed-reconstructed obstacles, streamed missiles,
## the drawn lines with their true fade timing, and the pickup events.

const DIR := "user://replays"
const VIEWER_SCENE := "res://GameFiles/Sprites/UI/ReplayViewer.tscn"
const SAMPLE_EVERY := 3     ## Physics ticks between samples (60 Hz tick / 3 = 20 Hz).
const MAX_SAMPLES := 36000  ## Sampling cap (~30 min of run) so a marathon can't eat memory.
const FILE_VERSION := 2     ## v2 added entities/events/states/fades. Old files are ignored.

## Event kinds (the `events` array is flat 4-tuples: tick, kind, x, y).
const EV_STAR := 0      ## A star was collected at (x, y).
const EV_POWERUP := 1   ## A powerup was picked up at (x, y).
const EV_BOOSTER := 2   ## A speed booster was hit (and flung away) at (x, y).

## Mode-scene name → gamemode index. Mirrors EndlessRunnerModeOST.gd, but usable immediately
## (the OST script only stamps player.gamemode after a 1-second delay).
const MODE_IDS := {"EndlessRunnerMode": 0, "ChaosMode": 1, "MissilesMode": 2}

var recording := false
var viewing_path := ""                  ## The file ReplayViewer.tscn should play (set by watch()).
var _mode := 0
var _character := 0
var _tick := 0                          ## Physics ticks since the run started (pause excluded).
var _frames := PackedFloat32Array()     ## x, y, rotation per sample.
var _states := PackedFloat32Array()     ## Per sample: bitmask of PowerupPopUps[1..5] visibility.
var _segments := PackedFloat32Array()   ## tick, ax, ay, bx, by, star per drawn segment.
var _seg_fades := PackedFloat32Array()  ## Fade-start tick per segment (-1 = natural 3s timeout).
var _events := PackedFloat32Array()     ## tick, kind, x, y per pickup event.
var _entities: Array = []               ## One Dictionary per tracked obstacle (see track()).
var _open: Array = []                   ## The still-alive subset of _entities (what sampling walks).
var _player: Node                       ## The player instance being recorded.

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)

func _physics_process(_delta: float) -> void:
	if not recording:
		return
	# The player we were recording is gone (quit / restart mid-run): discard the recording.
	if not is_instance_valid(_player):
		recording = false
		return
	if _tick % SAMPLE_EVERY == 0 and _frames.size() / 3 < MAX_SAMPLES:
		_frames.push_back(_player.position.x)
		_frames.push_back(_player.position.y)
		_frames.push_back(_player.rotation)
		_states.push_back(_popup_bits())
		_discover_clone()
		_sample_entities()
	_tick += 1

## Begins recording the current run (called by the mode root script as the scene loads).
## Any earlier unsaved recording is discarded.
func start_run() -> void:
	var pf: Node = Refs.playfield()
	_player = Refs.player()
	if pf == null or _player == null:
		return
	var scene_name := String(pf.get_parent().name)
	if not MODE_IDS.has(scene_name):
		return
	_mode = MODE_IDS[scene_name]
	_character = _player.currChar
	_tick = 0
	_frames = PackedFloat32Array()
	_states = PackedFloat32Array()
	_segments = PackedFloat32Array()
	_seg_fades = PackedFloat32Array()
	_events = PackedFloat32Array()
	_entities = []
	_open = []
	recording = true
	# The starting platform is authored into the mode scene (not generator-spawned), so track
	# it explicitly — streamed, since Missiles mode slides it away once the fight begins.
	var platform: Node2D = pf.get_node_or_null("Building1")
	if platform:
		track(platform, 0, {"start_platform": true}, true)

## Seeds the global RNG with a fresh random seed and returns it. Generators call this right
## before instancing an obstacle, so the obstacle's _ready randomness becomes reproducible:
## replaying seed(s) + instantiate() rebuilds the identical procedural obstacle.
## Safe to call when not recording — the RNG stays just as random.
func seed_spawn() -> int:
	var s := randi()
	seed(s)
	return s

## Registers a spawned obstacle for the recording. [param seed_val] is what seed_spawn()
## returned for it; [param props] are the generator-set properties that affect construction
## or self-driven motion (e.g. BatWall's wall_dist/difficulty, a Dragon's drift).
## Trajectories are streamed per-tick only for player-dependent movers (missiles, the clone)
## and nodes tracked with [param force_stream]; everything else replays from
## (seed + props + spawn/despawn ticks) alone.
func track(node: Node2D, seed_val: int, props: Dictionary = {}, force_stream: bool = false) -> void:
	if not recording or node == null:
		return
	var path := node.scene_file_path
	var e := {
		"t0": _tick, "path": path, "seed": seed_val,
		"x": node.position.x, "y": node.position.y,
		"props": props, "t1": -1,
		"stream": PackedFloat32Array(),
		"_node": node,
		"_streamed": force_stream or path.ends_with("Missile.tscn") or path.ends_with("TimedMissile.tscn") or path.ends_with("PlayerSUS.tscn"),
		"_last": [],  # the last quad pushed to the stream (tick, x, y, rot)
		"_prev": [],  # the last quad sampled, pushed or not (anchors static→moving transitions)
	}
	_entities.append(e)
	_open.append(e)

## Records one drawn terrain segment; returns its id so CollLine can report its fade later.
## [param star] marks Rockstar-spawned stars riding on this segment.
func record_segment(a: Vector2, b: Vector2, star: bool) -> int:
	if not recording:
		return -1
	_segments.push_back(_tick)
	_segments.push_back(a.x)
	_segments.push_back(a.y)
	_segments.push_back(b.x)
	_segments.push_back(b.y)
	_segments.push_back(1.0 if star else 0.0)
	_seg_fades.push_back(-1.0)
	return _seg_fades.size() - 1

## Marks drawn segment [param id] as starting its fade now (the ball rolled off it, or its
## timer ran out) so playback removes it at the exact same moment.
func record_segment_fade(id: int) -> void:
	if recording and id >= 0 and id < _seg_fades.size():
		_seg_fades[id] = _tick

## Stamps the moment a tracked missile exploded (called by Missile.gd's gg/gg1). The node
## itself is freed ~a second later when its blast finishes, so without this the playback
## explosion would run late — the missile would hang frozen mid-air, then pop.
func mark_explosion(node: Node) -> void:
	if not recording:
		return
	for e in _entities:
		if e["_node"] == node and not e.has("boom"):
			e["boom"] = _tick
			return

## Records a pickup event ([constant EV_STAR]/[constant EV_POWERUP]/[constant EV_BOOSTER])
## at world position [param pos]. Called by Star.gd and the powerup pickup handlers.
func record_event(kind: int, pos: Vector2) -> void:
	if not recording:
		return
	_events.push_back(_tick)
	_events.push_back(kind)
	_events.push_back(pos.x)
	_events.push_back(pos.y)

## Ends the recording (called from the game-over path with the final score) and writes it to
## disk as the rolling last replay. Renaming the file later keeps it permanently.
func stop(score: int) -> void:
	if not recording:
		return
	recording = false
	if is_instance_valid(_player):  # final sample, so the playback ends exactly where the run did
		_frames.push_back(_player.position.x)
		_frames.push_back(_player.position.y)
		_frames.push_back(_player.rotation)
		_states.push_back(_popup_bits())
	if _frames.size() < 6:  # a run too short to play back isn't worth offering
		return
	var entities: Array = []
	for e in _entities:  # strip the live-node bookkeeping; close open-ended lifetimes
		if e["t1"] < 0 and not is_instance_valid(e["_node"]):
			e["t1"] = _tick
		entities.append({
			"t0": e["t0"], "path": e["path"], "seed": e["seed"], "x": e["x"], "y": e["y"],
			"props": e["props"], "t1": e["t1"], "stream": e["stream"],
			"boom": e.get("boom", -1),
		})
	_entities = []
	_open = []
	_store(DIR + "/last.srp", {  # every run survives as the rolling "last replay"
		"version": FILE_VERSION,
		"mode": _mode,
		"character": _character,
		"score": score,
		"date": Time.get_datetime_string_from_system(),
		"sample_every": SAMPLE_EVERY,
		"frames": _frames,
		"states": _states,
		"segments": _segments,
		"seg_fades": _seg_fades,
		"events": _events,
		"entities": entities,
	})

## Renames a saved replay — the way a run is kept permanently: once [code]last.srp[/code] has
## another name, the next run's auto-save can't overwrite it (the BombSquad model).
## [param new_base] is the wanted name without extension; invalid filename characters are
## dropped, a clashing name is uniquified with _2/_3/…, and "last" itself is refused (it would
## just be overwritten again). Returns the final file name, or "" if the rename was invalid.
func rename_replay(old_name: String, new_base: String) -> String:
	var dir := DirAccess.open(DIR)
	if dir == null or not dir.file_exists(old_name):
		return ""
	var base := new_base.strip_edges().validate_filename().trim_suffix(".srp").strip_edges()
	if base.is_empty() or base == "last":
		return ""
	if base + ".srp" == old_name:
		return old_name  # renamed to itself — nothing to do
	var target := base + ".srp"
	var n := 2
	while dir.file_exists(target):
		target = "%s_%d.srp" % [base, n]
		n += 1
	return target if dir.rename(old_name, target) == OK else ""

## The saved replay filenames, newest recording first (sorted by the date stored inside each
## file, so renamed files keep their true place), with the rolling last replay pinned on top.
## Only files the current format can actually play are listed — stale files from older
## versions (e.g. the pre-release ghost prototype's last_m*/best_m* files) would just
## bounce the viewer back to the menu, so they're hidden.
func list_replays() -> PackedStringArray:
	var names := PackedStringArray()
	var dir := DirAccess.open(DIR)
	if dir == null:
		return names
	var entries: Array = []  # [file name, recorded date] pairs
	for f in dir.get_files():
		if f.ends_with(".srp"):
			var data = load_file(DIR + "/" + f)
			if data != null:
				entries.append([f, String(data.get("date", ""))])
	entries.sort_custom(func(a, b): return a[1] > b[1])  # ISO dates: string order = time order
	for e in entries:
		names.append(e[0])
	var li := names.find("last.srp")
	if li > 0:  # the freshest run always sits at the top of the browser
		names.remove_at(li)
		names.insert(0, "last.srp")
	return names

## Opens the replay viewer on [param file_name] (a name from [method list_replays]).
## Unpauses first — it's called from the paused Settings popup.
func watch(file_name: String) -> void:
	viewing_path = DIR + "/" + file_name
	get_tree().paused = false
	get_tree().change_scene_to_file(VIEWER_SCENE)

## Loads and validates a replay file. Returns the replay Dictionary, or null if the file is
## missing, corrupt, from an incompatible version, or too short to play back.
func load_file(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data = f.get_var()
	if not (data is Dictionary):
		return null
	if int(data.get("version", -1)) != FILE_VERSION:
		return null
	for k in ["frames", "states", "segments", "seg_fades", "events"]:
		if not (data.get(k) is PackedFloat32Array):
			return null
	if not (data.get("entities") is Array):
		return null
	for e in data["entities"]:  # a malformed entity would crash the viewer mid-playback
		if not (e is Dictionary) or not (e.get("stream") is PackedFloat32Array):
			return null
		for k in ["t0", "path", "seed", "x", "y", "props", "t1"]:
			if not e.has(k):
				return null
	if (data["frames"] as PackedFloat32Array).size() < 6:  # need at least 2 samples to move
		return null
	return data

## The HUD powerup icons' visibility as 5 bits (PowerupPopUps indices 1-5). Recorded per
## sample: playback drives its stand-in popups from this, so seed-reconstructed buildings
## make the same "should I spawn a powerup?" decisions the live run made.
func _popup_bits() -> float:
	var popups := get_tree().get_nodes_in_group("PowerupPopUps")
	var bits := 0
	for i in range(1, mini(popups.size(), 6)):
		if popups[i].visible:
			bits |= 1 << (i - 1)
	return float(bits)

## Auto-tracks the Doppelgänger clone the moment it appears (it's spawned by the powerup,
## not a generator, so no generator hook covers it).
func _discover_clone() -> void:
	for p in get_tree().get_nodes_in_group("Player"):
		if p.name == "PlayerSUS" and is_instance_valid(p):
			var known := false
			for e in _entities:
				if e["_node"] == p:
					known = true
					break
			if not known:
				track(p, 0)

## Streams trajectories for the player-dependent movers, and stamps despawn ticks for anything
## that has been freed. Only the still-open entities are walked (closed ones drop out), and
## streams are delta-compressed: a quad is pushed only when the transform actually changed, with
## an anchor quad first when movement resumes after a still period — so a parked start platform
## costs a couple of quads instead of twenty per second, while the viewer's bracketing
## interpolation reads both patterns identically.
func _sample_entities() -> void:
	for i in range(_open.size() - 1, -1, -1):
		var e: Dictionary = _open[i]
		if not is_instance_valid(e["_node"]):
			e["t1"] = _tick
			_open.remove_at(i)
			continue
		if not e["_streamed"]:
			continue
		var n: Node2D = e["_node"]
		var now := [float(_tick), n.position.x, n.position.y, n.rotation]
		var last: Array = e["_last"]
		if last.is_empty() or last[1] != now[1] or last[2] != now[2] or last[3] != now[3]:
			var prev: Array = e["_prev"]
			if not last.is_empty() and not prev.is_empty() and prev[0] > last[0]:
				for v in prev:  # hold the old spot right up to this moment
					e["stream"].push_back(v)
			for v in now:
				e["stream"].push_back(v)
			e["_last"] = now
		e["_prev"] = now

## Writes [param data] atomically (temp file, then swap), mirroring Utils.gd's save pattern.
func _store(path: String, data: Dictionary) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_var(data)
	f.close()
	var dir := DirAccess.open(DIR)
	if dir == null:
		return
	var fname := path.get_file()
	if dir.file_exists(fname):
		dir.remove(fname)
	dir.rename(tmp.get_file(), fname)

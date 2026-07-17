extends Node2D
## Plays a saved replay back like a video — obstacles, powerups, stars and all.
## The scene behind ReplayViewer.tscn; opened by [code]Replay.watch()[/code].
##
## Reconstruction works in layers:
## [br]• [b]Obstacles[/b] are rebuilt exactly as they were: each recorded spawn stores the RNG
##   seed the generator used, so [code]seed(s) + instantiate()[/code] regenerates the identical
##   procedural obstacle (same building silhouette, same bat-wall gap, same rooftop powerup).
##   Self-animated obstacles keep their scripts and simply run (pendulums swing, dragons slither,
##   falling lights react to the puppet player); player-dependent movers (missiles, the clone)
##   are stripped of logic and driven along their recorded trajectories.
## [br]• The [b]player puppet[/b] is the real player scene stripped to its visuals. It joins the
##   "Player" group so reactive obstacles (bats, studio lights) chase it like they chased you.
## [br]• [b]Drawn lines[/b] appear at their recorded ticks and start fading at their recorded
##   fade ticks — a line vanishes in playback at the exact moment the ball rolled off it.
## [br]• [b]Pickups[/b] replay as events: stars play their collect animation, powerups vanish
##   from the world and appear carried on the puppet (driven by the recorded HUD state, which
##   also steers reconstructed buildings' powerup rolls via stand-in popup nodes).
## [br]• [b]Missiles[/b] join the live warning groups, so the real MissileMark/TMissileMark
##   scenes (and Missiles-mode's arrow manager) run their own scripts against the puppets;
##   each missile detonates at its recorded explosion tick and leaves at its despawn tick.
## [br]• The [b]starting platform[/b] is scene-authored (no path + seed), so it's dissected out
##   of the recorded mode's scene and driven by its recorded (delta-compressed) trajectory.
## [br]• [b]Warnings[/b] are real: the World hosts the actual indicatorManager (ReplayWorld.gd
##   provides the playfield aspect vars it needs), so airships/hotel/hanging-bars announce
##   themselves and dragons get their row arrows from the viewer at spawn.
## [br]• [b]Presentation[/b] mirrors gameplay: a random gameplay track, the star chime and
##   pickup sounds, the jetpack's flames + thrust hum, the speed trail, speed-thick ink, and
##   lines that glow underfoot.
##
## [br]• A [b]timeline[/b] along the bottom scrubs to any moment, backward or forward: the
##   reconstructed world is wiped (puppet, trail and managers persist) and every system
##   catches up to the target tick in one silent pass (see [method _seek]).
##
## BACK (or Android back) returns to the menu; when the recording ends the title says so.

## Carried-powerup attachments: recorded HUD bit → (scene, carry offset from player_physics).
## Bit 2 (Doppelgänger) is deliberately absent — the clone isn't carried, it spawns as a real
## tracked entity with its own recorded trajectory.
const CARRY := {
	0: ["res://GameFiles/Sprites/Powerups/RockstarGuitar.tscn", Vector2(12, -6)],
	1: ["res://GameFiles/Sprites/Powerups/Jetpack.tscn", Vector2(12, -6)],
	3: ["res://GameFiles/Sprites/Powerups/Umbrella.tscn", Vector2(4, -24)],
	4: ["res://GameFiles/Sprites/Powerups/Lowrider.tscn", Vector2(8, 8)],
}
const LINE_FADE_TICKS := 180  ## Natural line lifetime (3 s) when no fade tick was recorded.
const TOUCH_GLOW_DIST := 26.0 ## Puppet-to-line distance that counts as "rolling on it" (glow).

## Per-character speed-trail colour and offset — the same values player_physics.gd uses.
const TRAIL := [
	["e76f11", Vector2(0, 0)], ["e76f11", Vector2(0, 0)], ["9b7de2", Vector2(-10.5, -2)],
	["b32550", Vector2(2, 0)], ["af4589", Vector2(0, 4)], ["ff84ff", Vector2(-6, 4)],
]
## The gameplay music tracks; the viewer picks one at random like the mode scenes do.
const TRACKS := [
	"res://GameFiles/OST/Gameplay/Rollin' Blues 192.mp3",
	"res://GameFiles/OST/Gameplay/Actionator 192.mp3",
	"res://GameFiles/OST/Gameplay/Error! Error! ERROR! 192.mp3",
]
## Mode index → mode scene, for extracting scene-authored pieces (the starting platform).
const MODE_SCENES := [
	"res://GameFiles/Modes/EndlessRunnerMode.tscn",
	"res://GameFiles/Modes/ChaosMode.tscn",
	"res://GameFiles/Modes/MissilesMode.tscn",
]

@onready var cam: Camera2D = $Camera2D
@onready var title: Label = $UI/Title
@onready var world: Node2D = $World
@onready var timeline: HSlider = $UI/Timeline
@onready var time_label: Label = $UI/TimeLabel

var frames: PackedFloat32Array
var states: PackedFloat32Array
var segments: PackedFloat32Array
var seg_fades: PackedFloat32Array
var events: PackedFloat32Array
var entities: Array
var sample_every := 3
var mode := 0

var puppet: Node2D          ## The stripped player visual that re-traces the run.
var spin_visual: Node2D     ## The puppet's Characters node (spun while rolling).
var spins := true           ## Trebor and the wheeled characters don't tumble in-game.
var trail: Line2D           ## The speed trail behind the puppet (mirrors SpeedLine.gd).
var puppet_speed := 0.0     ## The puppet's current speed (px/s), derived from the samples.
var draw_cursor: Sprite2D   ## The game's guitar cursor, re-tracing the recorded drawing hand.
var _cursor_target := Vector2.ZERO  ## Latest drawn-segment tip (where the pointer was).
var _last_draw_tick := -999 ## Tick of the most recent drawn segment (drives cursor visibility).
var _tick := 0
var _seg_idx := 0
var _ev_idx := 0
var _ent_idx := 0
var _done := false
var _total_ticks := 0       ## The recording's length in physics ticks (drives the timeline).
var _scrubbing := false     ## True while the player is dragging the timeline grabber.
var _seeking := false       ## True during a seek's catch-up pass (suppresses event sounds).
var _base_title := ""       ## Title without the "REPLAY ENDED" suffix, restored on rewind.
var _live_lines := {}       ## segment id -> {node, fade_tick} for scheduled line removal.
var _live_entities := []    ## [{node, data}] spawned entities awaiting their despawn tick.
var _carried := {}          ## HUD bit -> attached visual node on the puppet.
var _popup_stubs := []      ## Stand-in PowerupPopUps nodes, driven by the recorded states.

func _ready() -> void:
	var data = Replay.load_file(Replay.viewing_path)
	if data == null:
		_back_to_menu()
		return
	frames = data["frames"]
	states = data["states"]
	segments = data["segments"]
	seg_fades = data["seg_fades"]
	events = data["events"]
	entities = data["entities"]
	entities.sort_custom(func(a, b): return a["t0"] < b["t0"])
	sample_every = maxi(1, int(data.get("sample_every", 3)))
	mode = clampi(int(data.get("mode", 0)), 0, MODE_SCENES.size() - 1)
	title.text = "REPLAY  •  SCORE %d  •  %s" % [int(data.get("score", 0)), String(data.get("date", ""))]
	_make_popup_stubs()
	var char_idx := int(data.get("character", 0))
	puppet = _build_body_puppet("res://GameFiles/Sprites/Player.tscn", char_idx)
	puppet.position = Vector2(frames[0], frames[1])
	puppet.rotation = frames[2]
	puppet.add_to_group("Player")  # reactive obstacles (bats, falling lights) target the puppet
	world.add_child(puppet)
	cam.position = Vector2(puppet.position.x, 0)
	# The REAL warning-indicator manager (it needs ../Player, so it comes after the puppet):
	# reconstructed airships/hotels/hanging bars announce themselves to it just like in gameplay,
	# and the beeping warnings spawn, track and free themselves with their own scripts.
	var ind := Node2D.new()
	ind.set_script(load("res://GameFiles/Gameplay Scripts/Indicators/indicatorManager.gd"))
	ind.name = "indicatorManager"
	world.add_child(ind)
	_add_arrows_manager()
	# The speed trail, in the character's colour (mirrors SpeedLine.gd / player_physics.gd).
	trail = Line2D.new()
	trail.width = 8.0
	var curve := Curve.new()  # taper the tail like the gameplay trail's width curve
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(1, 1))
	trail.width_curve = curve
	var style: Array = TRAIL[clampi(char_idx, 0, TRAIL.size() - 1)]
	trail.default_color = Color(style[0])
	trail.position = style[1]
	trail.add_to_group("SpeedLine")  # the jetpack's FireLine flames read the trail from this group
	world.add_child(trail)
	# The drawing hand: the game's own pointer icon rides the tip of the line as it's drawn.
	draw_cursor = Sprite2D.new()
	draw_cursor.texture = load("res://GameFiles/SpinHead IMGS/customCursor/RockstarGuitar.png")
	draw_cursor.centered = false  # position = texture top-left, matching the in-game cursor hotspot
	draw_cursor.z_index = 3
	draw_cursor.z_as_relative = false
	draw_cursor.visible = false
	world.add_child(draw_cursor)
	# The soundtrack: a random gameplay track, like the mode scenes pick.
	var music := AudioStreamPlayer.new()
	music.stream = load(TRACKS[randi() % TRACKS.size()])
	music.bus = "Music"
	music.autoplay = true
	add_child(music)
	_base_title = title.text
	# The timeline: drag (or tap) to any moment; the seek happens on release.
	_total_ticks = maxi(0, (frames.size() / 3 - 1) * sample_every)
	timeline.max_value = _total_ticks
	timeline.drag_started.connect(func(): _scrubbing = true)
	timeline.drag_ended.connect(func(_changed: bool):
		_scrubbing = false
		_seek(int(timeline.value))
	)
	timeline.value_changed.connect(func(v: float):
		if _scrubbing:  # live-preview the target time while dragging (works even when paused)
			time_label.text = "%s / %s" % [_fmt(int(v)), _fmt(_total_ticks)]
		else:  # keyboard nudges / track clicks that don't become drags
			_seek(int(v))
	)

## Missiles mode has on-screen arrows tracking every missile — replays get them too.
## Rebuilt after a seek (the wipe frees the manager's spawned arrows, so it restarts clean).
func _add_arrows_manager() -> void:
	if mode != 2:
		return
	var arrows: Node2D = Node2D.new()
	arrows.set_script(load("res://GameFiles/Gameplay Scripts/Indicators/MissileMarkerManager.gd"))
	arrows.name = "MissileMarkerManager"
	world.add_child(arrows)

## Stand-ins for the HUD powerup icons. Reconstructed buildings consult
## PowerupPopUps[1..5].visible to decide whether to spawn a powerup — driving these from the
## recorded per-sample state makes those rolls match the original run exactly.
func _make_popup_stubs() -> void:
	for i in range(6):
		var s := Node2D.new()
		s.name = "PopupStub%d" % i
		s.visible = false
		add_child(s)
		s.add_to_group("PowerupPopUps")
		_popup_stubs.append(s)

func _physics_process(_delta: float) -> void:
	if not _done:
		_tick += 1
		_apply_states()
		_spawn_due_entities()
		_despawn_due_entities()
		_apply_due_events()
		_advance_streams()
		_spawn_due_segments()
		_fade_due_lines()
		_advance_puppet()
		_glow_touched_lines()
		_update_draw_cursor()
	# The timeline stays live even once the replay has ended (you can rewind from there).
	if not _scrubbing:
		timeline.set_value_no_signal(_tick)
	var shown := int(timeline.value) if _scrubbing else _tick
	time_label.text = "%s / %s" % [_fmt(shown), _fmt(_total_ticks)]

## Ticks → "m:ss" (the sim runs at 60 ticks a second).
func _fmt(ticks: int) -> String:
	var s := ticks / 60
	return "%d:%02d" % [s / 60, s % 60]

## Jumps the playback to [param target] (ticks) — backward or forward. The reconstructed world
## is wiped (keeping the puppet, trail and managers) and every replay system then catches up
## from the recording in a single pass: only what should exist at the target moment is rebuilt,
## with event sounds suppressed so a seek doesn't fire a burst of old chimes.
func _seek(target: int) -> void:
	target = clampi(target, 0, _total_ticks)
	if target == _tick:
		return
	_seeking = true
	# Wipe everything reconstructed; keep the persistent cast.
	var keep: Array = [puppet, trail, draw_cursor, world.get_node_or_null("indicatorManager")]
	var arrows := world.get_node_or_null("MissileMarkerManager")
	if arrows:  # rebuilt below — its arrow pool is about to be freed out from under it
		arrows.free()
	for c in world.get_children():
		if not keep.has(c):
			c.free()
	for bit in _carried.keys():
		if is_instance_valid(_carried[bit]):
			_carried[bit].free()
	_carried.clear()
	_live_entities.clear()
	_live_lines.clear()
	trail.clear_points()
	_ent_idx = 0
	_ev_idx = 0
	_seg_idx = 0
	_last_draw_tick = -999  # the catch-up pass below re-derives the drawing hand's state
	for e in entities:
		e.erase("_qi")  # stream brackets only advance forward; rescan from the start
	_add_arrows_manager()
	_done = false
	title.text = _base_title
	_tick = target
	# Land the puppet first so the catch-up pass computes sane speeds and camera framing.
	var i := clampi(_tick / sample_every, 0, frames.size() / 3 - 1)
	puppet.position = Vector2(frames[i * 3], frames[i * 3 + 1])
	puppet_speed = 0.0
	# One catch-up pass over every system.
	_apply_states()
	_spawn_due_entities()
	_apply_due_events()
	_advance_streams()
	_spawn_due_segments()
	_advance_puppet()
	_update_draw_cursor()  # visible only if the hand was mid-stroke at the target moment
	_seeking = false
	# While paused the process loop is frozen, so sync the timeline readout here too.
	timeline.set_value_no_signal(_tick)
	time_label.text = "%s / %s" % [_fmt(_tick), _fmt(_total_ticks)]

## --- player -------------------------------------------------------------------------------

## Builds a display-only body from a player-type scene: script removed before entering the
## tree (so no _ready, no physics, no group joins), everything but the character visuals freed.
func _build_body_puppet(scene_path: String, char_idx: int) -> Node2D:
	var pl: Node2D = load(scene_path).instantiate()
	pl.set_script(null)
	for c in pl.get_children():
		if c.name != "Characters" and c.name != "StarCollect":  # keep the star-pickup chime too
			c.free()
	pl.collision_layer = 0
	pl.collision_mask = 0
	var chars: Node2D = pl.get_node_or_null("Characters")
	if chars:
		var kids := chars.get_children()
		for i in range(kids.size()):
			if kids[i] is CanvasItem:
				kids[i].visible = (i == char_idx)
		chars.position.y = -2 if (char_idx >= 3 and char_idx <= 5) else -4
	return pl

func _advance_puppet() -> void:
	var fidx := float(_tick) / sample_every
	var i := int(fidx)
	if (i + 1) * 3 + 2 < frames.size():
		var t := fidx - i
		var prev := puppet.position
		puppet.position.x = lerpf(frames[i * 3], frames[(i + 1) * 3], t)
		puppet.position.y = lerpf(frames[i * 3 + 1], frames[(i + 1) * 3 + 1], t)
		puppet.rotation = lerp_angle(frames[i * 3 + 2], frames[(i + 1) * 3 + 2], t)
		puppet_speed = (puppet.position - prev).length() * 60.0
		if spins and spin_visual == null:
			spin_visual = puppet.get_node_or_null("Characters")
		if spins and spin_visual:  # same feel as player_physics' rolling spin
			var gsp := (puppet.position.x - prev.x) * 60.0
			if absf(gsp) > 10.0:
				spin_visual.rotate(((5.0 / 60.0) + (gsp / 120.0)) / 10.0)
		cam.position.x = puppet.position.x
		_update_trail()
	else:
		_done = true
		title.text += "   —   REPLAY ENDED"

## The speed trail behind the puppet — the same grow-with-speed / shrink-when-slow logic
## as SpeedLine.gd, driven by the derived puppet speed.
func _update_trail() -> void:
	var mx := int(roundf(puppet_speed / 50.0))
	var pnts := trail.points
	if puppet_speed >= 600.0:
		if pnts.size() < mx:
			pnts.push_back(puppet.position)
		if pnts.size() >= mx:
			pnts.remove_at(0)
	elif pnts.size() > 1:
		pnts.remove_at(0)
		for i in range(pnts.size() - 1):
			pnts[i] = pnts[i + 1]
		pnts[pnts.size() - 1] = puppet.position
	elif pnts.size() == 1:
		pnts.remove_at(0)
	trail.set_points(pnts)

## Drives the popup stand-ins and the puppet's carried-powerup visuals from the recorded state.
func _apply_states() -> void:
	var idx := mini(_tick / sample_every, states.size() - 1)
	if idx < 0:
		return
	var bits := int(states[idx])
	for i in range(5):
		_popup_stubs[i + 1].visible = bool(bits & (1 << i))
	for bit in CARRY:
		var on := bool(bits & (1 << bit))
		if on and not _carried.has(bit):
			var vis: Node2D = load(CARRY[bit][0]).instantiate()
			vis.set_script(null)  # pickup logic off; children keep theirs (the flames need FireLine.gd)
			if vis.get_child_count() > 0:
				vis.get_child(0).free()  # the pickup glow, removed on carry in the real game
			for c in vis.get_children():
				if c is Area2D:
					c.free()  # dead pickup hitboxes
			vis.position = CARRY[bit][1]
			puppet.add_child(vis)
			# The jetpack rides with its flames burning and its thrust loop humming, like a
			# real pickup does (FireLine draws from the "SpeedLine"-group trail + the puppet).
			for fl in ["FireLine", "FireLine2"]:
				var flame = vis.get_node_or_null(fl)
				if flame:
					flame.active = true
			var hum: AudioStreamPlayer2D = vis.get_node_or_null("JetSound")
			if hum:
				hum.play()
			_carried[bit] = vis
		elif not on and _carried.has(bit):
			if is_instance_valid(_carried[bit]):
				_carried[bit].queue_free()
			_carried.erase(bit)

## --- obstacles ----------------------------------------------------------------------------

## Rebuilds obstacles at their recorded spawn ticks. Seeding the global RNG with the recorded
## seed right before instancing makes the procedural construction identical to the original.
func _spawn_due_entities() -> void:
	while _ent_idx < entities.size() and entities[_ent_idx]["t0"] <= _tick:
		var e: Dictionary = entities[_ent_idx]
		_ent_idx += 1
		# Already dead or detonated by now — only possible when catching up after a seek.
		var t1_skip := int(e["t1"])
		var boom_skip := int(e.get("boom", -1))
		if (t1_skip >= 0 and t1_skip <= _tick) or (boom_skip >= 0 and boom_skip <= _tick):
			continue
		var streamed: bool = e["stream"].size() > 0 or String(e["path"]).ends_with("PlayerSUS.tscn")
		var obj: Node2D
		if e["props"].has("start_platform"):
			obj = _extract_start_platform()
			_strip_scripts(obj)
		elif String(e["path"]).ends_with("PlayerSUS.tscn"):
			obj = _build_body_puppet(e["path"], 0)
		else:
			seed(int(e["seed"]))
			obj = load(e["path"]).instantiate()
			for k in e["props"]:
				obj.set(k, e["props"][k])
			if streamed:
				_strip_scripts(obj)
		# Position is set twice on purpose: before add_child for _readys that read their own
		# position, and again after, overriding _readys that re-roll it (e.g. Building1's
		# random height) so the recorded placement always wins.
		obj.position = Vector2(e["x"], e["y"])
		world.add_child(obj)
		obj.position = Vector2(e["x"], e["y"])
		if "killme" in obj:      # dragons: disable the "player never engaged" self-destruct;
			obj.killme = false   # the recorded despawn tick governs their lifetime instead
		var fire: AnimatedSprite2D = obj.get_node_or_null("Fire")
		if streamed and fire:    # stripped missiles still get their exhaust flame
			fire.play("fire_R" if randi() % 2 else "fire_B")
		_group_missile_and_mark(obj, String(e["path"]))
		# Dragons get their row warning from the generator in gameplay, so the viewer plays
		# that role here (the row is recovered from the recorded spawn height).
		if String(e["path"]).ends_with("/Dragon.tscn"):
			var row := 0 if e["y"] < 360.0 else (1 if e["y"] < 720.0 else 2)
			world.get_node("indicatorManager").indicateDragons(row, obj)
		_live_entities.append({"node": obj, "data": e})

## Missile puppets join the live game's missile groups, and the beeping warning marker spawns
## alongside them (one per kind, like the generators do) — its real script then runs untouched:
## it tracks the nearest grouped missile, beeps faster as it closes in, and frees itself once
## the group empties.
func _group_missile_and_mark(obj: Node2D, path: String) -> void:
	var is_timed := path.ends_with("TimedMissile.tscn")
	var is_homing := path.ends_with("/Missile.tscn")
	if not (is_timed or is_homing):
		return
	obj.add_to_group("GMissiles")
	obj.add_to_group("TMissiles" if is_timed else "Missiles")
	var mark_name := "TMissileMark" if is_timed else "MissileMark"
	if world.get_node_or_null(mark_name) == null:
		world.add_child(load("res://GameFiles/Sprites/Obstacles/%s.tscn" % mark_name).instantiate())

## Detonates missiles at their recorded explosion ticks and frees everything at its recorded
## despawn tick. The explosion (gg()'s visual) happens ~a second before the node vanished in
## the live run, so the two moments are replayed separately.
func _despawn_due_entities() -> void:
	for i in range(_live_entities.size() - 1, -1, -1):
		var le: Dictionary = _live_entities[i]
		if not is_instance_valid(le["node"]):
			_live_entities.remove_at(i)
			continue
		var boom: int = int(le["data"].get("boom", -1))
		if boom >= 0 and boom <= _tick and not le.get("boomed", false):
			le["boomed"] = true
			_explode(le["node"])
		var t1: int = le["data"]["t1"]
		if t1 >= 0 and t1 <= _tick:
			var path := String(le["data"]["path"])
			var is_missile: bool = path.ends_with("Missile.tscn")  # matches TimedMissile too
			if is_missile and not le.get("boomed", false):
				# Old recording without an explosion tick: detonate now, linger, then free.
				_explode(le["node"])
				var n: Node2D = le["node"]
				get_tree().create_timer(1.2, false).timeout.connect(func():  # respects pause
					if is_instance_valid(n):
						n.queue_free()
				)
			else:
				le["node"].queue_free()
			_live_entities.remove_at(i)

## A missile's death, exactly as gg()/gg1() stage it: the body and flame vanish, the blast
## animation and bang play, and the missile leaves the warning groups so the beeping marker
## (and Missiles-mode arrows) stop tracking it.
func _explode(n: Node2D) -> void:
	for grp in ["GMissiles", "Missiles", "TMissiles"]:
		n.remove_from_group(grp)
	for part in ["Misslie", "TimedMisslie", "Fire", "killArea", "killMe"]:
		var p := n.get_node_or_null(part)
		if p:
			p.queue_free()
	var explosion: AnimatedSprite2D = n.get_node_or_null("Explosion")
	if explosion:
		explosion.visible = true
		explosion.play("newExp")
		# The scene's own free-on-finished connection died with the stripped script.
		explosion.animation_finished.connect(func():
			if is_instance_valid(explosion):
				explosion.hide()
		)
	var snd: AudioStreamPlayer2D = n.get_node_or_null("ExpSound")
	if snd:
		snd.play()

## Moves the streamed entities (missiles, the clone) along their recorded trajectories.
func _advance_streams() -> void:
	for le in _live_entities:
		var stream: PackedFloat32Array = le["data"]["stream"]
		if stream.size() == 0 or not is_instance_valid(le["node"]):
			continue
		var n: Node2D = le["node"]
		# Find the recorded quad (tick,x,y,rot) bracket around the current tick and interpolate.
		var qi: int = le["data"].get("_qi", 0)
		while (qi + 1) * 4 < stream.size() and stream[(qi + 1) * 4] <= _tick:
			qi += 1
		le["data"]["_qi"] = qi
		if (qi + 1) * 4 + 3 < stream.size():
			var t0 := stream[qi * 4]
			var t1 := stream[(qi + 1) * 4]
			var f := clampf((float(_tick) - t0) / maxf(1.0, t1 - t0), 0.0, 1.0)
			n.position.x = lerpf(stream[qi * 4 + 1], stream[(qi + 1) * 4 + 1], f)
			n.position.y = lerpf(stream[qi * 4 + 2], stream[(qi + 1) * 4 + 2], f)
			n.rotation = lerp_angle(stream[qi * 4 + 3], stream[(qi + 1) * 4 + 3], f)
		elif qi * 4 + 3 < stream.size():
			n.position = Vector2(stream[qi * 4 + 1], stream[qi * 4 + 2])
			n.rotation = stream[qi * 4 + 3]

## --- pickups ------------------------------------------------------------------------------

## Replays the recorded pickup events by acting on the nearest matching reconstructed node.
func _apply_due_events() -> void:
	while (_ev_idx + 1) * 4 <= events.size() and events[_ev_idx * 4] <= _tick:
		var kind := int(events[_ev_idx * 4 + 1])
		var pos := Vector2(events[_ev_idx * 4 + 2], events[_ev_idx * 4 + 3])
		_ev_idx += 1
		match kind:
			Replay.EV_STAR:
				var star := _nearest_scripted(pos, "Star.gd", 96.0)
				if star:
					var fade: AnimationPlayer = star.get_node_or_null("Fade")
					if fade and not _seeking:
						fade.play("onCollect")  # the scene's finished-signal frees the star
					else:
						star.queue_free()  # seeks remove long-collected stars instantly
				if not _seeking:
					var chime: AudioStreamPlayer2D = puppet.get_node_or_null("StarCollect")
					if chime:
						chime.play()
			Replay.EV_POWERUP:
				var pu := _nearest_scripted(pos, "/Powerups/", 96.0)
				if pu:
					if not _seeking:
						_detach_pickup_sound(pu)
					pu.queue_free()  # the carried visual appears via the recorded HUD state
			Replay.EV_BOOSTER:
				var b := _nearest_scripted(pos, "SpeedBooster.gd", 96.0)
				if b:
					if not _seeking:
						_detach_pickup_sound(b)
					b.queue_free()

## Rescues a pickup's sound from the node being freed: the one-shot chime (JetStart,
## UmbrellaSound, RockstarSound…) is reparented to the world, played, and cleaned up later.
func _detach_pickup_sound(n: Node) -> void:
	for pick_name in ["RockstarSound", "UmbrellaSound", "LowriderJUMP", "JetStart", "DoppelSound", "BoosterSound"]:
		var snd: AudioStreamPlayer2D = n.get_node_or_null(pick_name)
		if snd:
			snd.reparent(world)
			snd.play()
			get_tree().create_timer(5.0, false).timeout.connect(func():  # respects pause
				if is_instance_valid(snd):
					snd.queue_free()
			)
			return

## Finds the closest node under World whose script path matches [param needle], within
## [param radius] px of [param pos]. Used to target the star/powerup a pickup event refers to.
func _nearest_scripted(pos: Vector2, needle: String, radius: float) -> Node2D:
	var best: Node2D = null
	var best_d := radius
	var stack: Array[Node] = [world]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is Node2D and n.get_script() != null:
			var sp: String = n.get_script().resource_path
			if needle in sp:
				var d: float = (n as Node2D).global_position.distance_to(pos)
				if d < best_d:
					best_d = d
					best = n
	return best

## --- drawn lines --------------------------------------------------------------------------

## Lays the recorded terrain lines down at their recorded ticks (Rockstar stars included).
func _spawn_due_segments() -> void:
	while (_seg_idx + 1) * 6 <= segments.size() and segments[_seg_idx * 6] <= _tick:
		var spawn_tick := segments[_seg_idx * 6]
		var fade_tick: float = seg_fades[_seg_idx] if _seg_idx < seg_fades.size() else -1.0
		if fade_tick < 0:
			fade_tick = spawn_tick + LINE_FADE_TICKS  # never faded before the run ended
		if fade_tick <= _tick:  # already gone by now — only possible when catching up after a seek
			_cursor_target = Vector2(segments[_seg_idx * 6 + 3], segments[_seg_idx * 6 + 4])
			_last_draw_tick = int(spawn_tick)  # the hand still passed through here
			_seg_idx += 1
			continue
		var a := Vector2(segments[_seg_idx * 6 + 1], segments[_seg_idx * 6 + 2])
		var b := Vector2(segments[_seg_idx * 6 + 3], segments[_seg_idx * 6 + 4])
		_cursor_target = b  # the newest end of the stroke = where the pointer was
		_last_draw_tick = int(spawn_tick)
		var star: bool = segments[_seg_idx * 6 + 5] > 0.5
		var ln := Line2D.new()
		ln.position = a
		ln.add_point(Vector2.ZERO)
		ln.add_point(b - a)
		# Same speed-reactive stroke as playerInput._style_segment: bold ink at speed. The speed
		# is derived from the recording at the draw tick, so it's right even after a seek.
		ln.width = clampf(3.5 + _speed_at(int(spawn_tick)) / 300.0, 3.5, 8.0)
		ln.default_color = Color(1, 0, 1, 1)
		ln.begin_cap_mode = Line2D.LINE_CAP_ROUND
		ln.end_cap_mode = Line2D.LINE_CAP_ROUND
		ln.antialiased = true
		ln.z_index = 2
		ln.z_as_relative = false
		world.add_child(ln)
		if star:
			var st: Node2D = load("res://GameFiles/Sprites/Currency/Star.tscn").instantiate()
			ln.add_child(st)
		_live_lines[_seg_idx] = {"node": ln, "fade": fade_tick, "a": a, "b": b, "glowed": false}
		_seg_idx += 1

## Shows the drawing-hand cursor while strokes are being laid (a segment landed within the
## last ~0.2 s) and glides it toward the newest stroke tip; hides it when the hand lifts.
## Snaps on reappearing so it never swoops across the screen from an old stroke.
func _update_draw_cursor() -> void:
	var drawing: bool = _tick - _last_draw_tick <= 12
	if not drawing:
		draw_cursor.visible = false
		return
	if not draw_cursor.visible:
		draw_cursor.visible = true
		draw_cursor.position = _cursor_target
	draw_cursor.position = draw_cursor.position.lerp(_cursor_target, 0.5)

## The recorded player speed (px/s) at [param t] ticks, from the sampled positions.
func _speed_at(t: int) -> float:
	var i := clampi(t / sample_every, 1, frames.size() / 3 - 1)
	var dx := frames[i * 3] - frames[(i - 1) * 3]
	var dy := frames[i * 3 + 1] - frames[(i - 1) * 3 + 1]
	return Vector2(dx, dy).length() * 60.0 / sample_every

## The same brighten-and-swell CollLine plays when the ball rolls onto it — triggered here
## by puppet proximity to the segment (the recording marks when the ball rolled OFF a line,
## so the roll-ON moment is recovered from the puppet's re-traced path).
func _glow_touched_lines() -> void:
	for id in _live_lines:
		var entry: Dictionary = _live_lines[id]
		if entry["glowed"] or not is_instance_valid(entry["node"]):
			continue
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(puppet.position, entry["a"], entry["b"])
		if puppet.position.distance_to(closest) <= TOUCH_GLOW_DIST:
			entry["glowed"] = true
			var ln: Line2D = entry["node"]
			ln.default_color = ln.default_color.lerp(Color.WHITE, 0.75)
			var tw := ln.create_tween()
			tw.tween_property(ln, "width", ln.width * 1.8, 0.08)

## Starts each line's 0.3 s fade at its recorded tick — the moment the ball rolled off it
## (or its 3-second timer ran out) in the original run.
func _fade_due_lines() -> void:
	for id in _live_lines.keys():
		var entry: Dictionary = _live_lines[id]
		if entry["fade"] <= _tick:
			var ln: Line2D = entry["node"]
			if is_instance_valid(ln):
				var tw := ln.create_tween()
				tw.tween_property(ln, "modulate:a", 0.0, 0.3)
				tw.tween_callback(ln.queue_free)
			_live_lines.erase(id)

## --- plumbing -----------------------------------------------------------------------------

## The starting platform is authored directly into each mode scene (not an instanced scene),
## so it can't be rebuilt from a path + seed. Instead, instantiate the recorded mode's scene
## without adding it to the tree (so nothing runs), detach its Building1, and discard the rest.
func _extract_start_platform() -> Node2D:
	var ms: Node = load(MODE_SCENES[mode]).instantiate()
	var b: Node2D = ms.get_node_or_null("sizeChange/Building1")
	if b == null:
		ms.free()
		return Node2D.new()
	b.get_parent().remove_child(b)
	ms.free()  # b is detached, so it survives the dissected scene being freed
	return b

## Removes every script in [param root]'s subtree, leaving pure visuals (used for entities
## whose motion is replayed from data rather than simulated).
func _strip_scripts(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		n.set_script(null)

## Pauses/resumes the playback via the tree pause, freezing the whole replay world (the
## self-animating obstacles included) in one stroke. The UI layer processes ALWAYS, so the
## timeline still scrubs — and seeking while paused works, frame-stepping the frozen scene.
func _on_pause_btn_pressed() -> void:
	get_tree().paused = not get_tree().paused
	$UI/PauseBTN.text = ">" if get_tree().paused else "II"

func _back_to_menu() -> void:
	get_tree().paused = false  # never hand a paused tree back to the menu
	get_tree().change_scene_to_file("res://MainMenu.tscn")

func _on_back_btn_pressed() -> void:
	_back_to_menu()

## The Android back button (and window close) leaves the viewer instead of quitting.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_back_to_menu()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		get_tree().quit()

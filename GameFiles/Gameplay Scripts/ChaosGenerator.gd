extends Node2D
## Spawns the mayhem for Chaos mode — Endless Runner's extreme sibling.
##
## Where ObstacleGenerator.gd keeps exactly one obstacle alive at a time, this runs two
## overlapping spawn systems so several hazards coexist:
## [br]• A [b]ground conveyor[/b]: buildings/turbines/etc. are laid end-to-end ahead of the
##   player at [member frontier], with gaps that shrink as you travel.
## [br]• [b]Air events[/b]: missiles, dragons, airships, hanging bars and bat walls fire on an
##   independent timer that speeds up with distance.
## Both ramp with [method chaos_t] (0 → 1 over [constant RAMP_DIST] px), then hold at max —
## the "until a threshold" cap. Obstacles whose warning indicators look nodes up by name
## (Airships, HangingStudioStuff, BatWall) are limited to one alive at a time; the Hotel is
## excluded entirely (its corridors are unfair with other hazards flying through them).
## Two obstacles get mercy caps here that other modes don't use: bat walls are always a
## single column, and under-construction sites build at most 2 pendulum sections.
##
## All the difficulty dials are the constants below — tune there, not in the functions.

const RAMP_DIST := 45000.0  ## Distance (px) over which the chaos ramps from chill to maxed.
const MAX_GROUND := 7       ## Cap on live ground/belt obstacles (sanity + performance).
const MAX_MISSILES := 8     ## Cap on live homing/timed missiles.
const GAP_START := 0.85     ## Belt gap between obstacles at the start of a run (screens).
const GAP_END := 0.22       ## Belt gap at full chaos (screens) — the "too tight?" dial.
const AIR_WAIT_START := 6.5 ## Seconds between air events at the start of a run.
const AIR_WAIT_END := 2.4   ## Seconds between air events at full chaos.

## The ground-conveyor pool. Indices matter to [member groundPick] below.
var groundObjs:Array[Resource] = [
	preload("res://GameFiles/Sprites/Obstacles/Buildings/Building1.tscn"),                     # 0
	preload("res://GameFiles/Sprites/Obstacles/Buildings/Building2.tscn"),                     # 1
	preload("res://GameFiles/Sprites/Obstacles/Buildings/Building3.tscn"),                     # 2
	preload("res://GameFiles/Sprites/Obstacles/Buildings/Restaurant1.tscn"),                   # 3
	preload("res://GameFiles/Sprites/Obstacles/Buildings/RandomBuilding/RandomBuilding.tscn"), # 4
	preload("res://GameFiles/Sprites/Obstacles/Buildings/UnderConstruction/UnderConstruction.tscn"), # 5
	preload("res://GameFiles/Sprites/Obstacles/Buildings/WindTurbine.tscn"),                   # 6
	preload("res://GameFiles/Sprites/Obstacles/StudioStuff.tscn"),                             # 7
	preload("res://GameFiles/Sprites/Obstacles/Buildings/RandomBuilding/RandomBuilding2.tscn"),# 8
]
## Weighted picks into groundObjs (repeats = more likely). RandomBuilding2 is rare (it's huge).
var groundPick:Array[int] = [0,0,0, 1,1,1, 2,2,2, 3,3,3, 4,4,4,4, 5,5, 6,6, 7,7, 8]

var Missile:Resource = preload("res://GameFiles/Sprites/Obstacles/Missile.tscn")
var TimedMissile:Resource = preload("res://GameFiles/Sprites/Obstacles/TimedMissile.tscn")
var Dragon:Resource = preload("res://GameFiles/Sprites/Obstacles/Dragon/Dragon.tscn")
var Airships:Resource = preload("res://GameFiles/Sprites/Obstacles/Airships.tscn")
var HangingStudioStuff:Resource = preload("res://GameFiles/Sprites/Obstacles/HangingStudioStuff.tscn")
var BatWall:Resource = preload("res://GameFiles/Sprites/Obstacles/WalloBats/BatWall.tscn")
var MissileMark:Resource = preload("res://GameFiles/Sprites/Obstacles/MissileMark.tscn")
var TMissileMark:Resource = preload("res://GameFiles/Sprites/Obstacles/TMissileMark.tscn")

@onready var player:CharacterBody2D = get_node("../Player")
@onready var parent:Node2D = get_node("../")
@onready var indMan:Node2D = get_node("../indicatorManager")

var live:Array = []            ## Belt obstacles currently alive (freed once passed).
var frontier:float = 0.0       ## Right edge (world x) of the furthest belt obstacle.
var air_clock:float = 0.0      ## Seconds since the last air event.
var startX:float = 0.0         ## Player x at the start of the run (for the difficulty ramp).
var airships_alive:Node = null ## One-at-a-time guards: these obstacles' indicators find them
var hss_alive:Node = null      ## by node name, so duplicates would confuse the warnings.
var batwall_alive:Node = null

# Same spawn geometry the endless generator uses for dragons and missile volleys.
var dragons_info:Array[int] = [100, 460, 820]  ## The three dragon rows (y).
var why:Array[int] = [64, 64, -64, -64]        ## Small per-slot x nudges for missiles.
var rockets_info:Array[Vector2] = [Vector2(0.8, 900), Vector2(0.8, 180), Vector2(-0.4, 900), Vector2(-0.4, 180)]

func _ready() -> void:
	player.position.y = get_node("../Building1").position.y - 321
	get_node("../../UI/Center/Loading").loadEnd()
	startX = player.position.x
	frontier = player.position.x

## Width of one screen in world units at the current aspect ratio.
func screen_w() -> float:
	return Refs.SCREEN_WIDTH * parent.true_scalex / parent.true_scaley

## The chaos ramp: 0 at the start of the run, 1 once RAMP_DIST px have been travelled.
func chaos_t() -> float:
	return clampf((player.position.x - startX) / RAMP_DIST, 0.0, 1.0)

func _process(delta:float) -> void:
	_despawn_passed()
	_fill_ground()
	# Air events only once the run has started (the first touch sets minSpeed).
	if player.minSpeed > 0:
		air_clock += delta
		if air_clock >= lerpf(AIR_WAIT_START, AIR_WAIT_END, chaos_t()):
			air_clock = 0.0
			_air_event()

## Keeps the ground belt filled up to ~1.6 screens ahead, laying obstacles end-to-end with a
## gap that shrinks as chaos ramps — several are alive at once, unlike the endless generator.
func _fill_ground() -> void:
	var horizon:float = player.position.x + screen_w() * 1.6
	while frontier < horizon and live.size() < MAX_GROUND:
		var idx:int = groundPick[randi() % groundPick.size()]
		var s:int = Replay.seed_spawn()
		var obj:Node2D = groundObjs[idx].instantiate()
		var props:Dictionary = {}
		if idx == 5: # UnderConstruction: cap at 2 pendulum sections (3-4 are unfair in chaos)
			obj.max_sets = 2
			props["max_sets"] = 2
		var gap:float = screen_w() * lerpf(GAP_START, GAP_END, chaos_t())
		obj.position.x = frontier + gap + obj.offx
		parent.add_child(obj)
		Replay.track(obj, s, props)
		frontier = obj.position.x + obj.offx  # offx may be recomputed in the obstacle's _ready
		live.push_back(obj)

## Frees belt obstacles the player has safely passed, and puts down any missile that fell
## hopelessly far behind (so an hour-long run can't accumulate stray chasers).
func _despawn_passed() -> void:
	for i in range(live.size() - 1, -1, -1):
		var obj = live[i]
		if not is_instance_valid(obj):
			live.remove_at(i)
		elif player.position.x > obj.position.x + obj.offx + screen_w() * 0.4:
			obj.queue_free()
			live.remove_at(i)
	for m in get_tree().get_nodes_in_group("GMissiles"):
		if m.position.x < player.position.x - screen_w() * 2.5:
			m.queue_free()

## Fires one air event, weighted-random from whatever the current ramp has unlocked:
## dragons and airships from the start, hanging bars a bit in, homing missiles, then
## timed missiles, and bat walls only deep into the run.
func _air_event() -> void:
	var t:float = chaos_t()
	var pool:Array[int] = [0, 0, 0]  # dragons are always available
	if not is_instance_valid(airships_alive):
		pool += [1, 1]
	if not is_instance_valid(hss_alive) and t > 0.1:
		pool += [2, 2]
	if t > 0.15 and _missiles_alive() < MAX_MISSILES:
		pool += [3, 3, 3]
	if t > 0.3 and _missiles_alive() < MAX_MISSILES:
		pool += [4, 4]
	if t > 0.45 and not is_instance_valid(batwall_alive):
		pool.push_back(5)
	match pool[randi() % pool.size()]:
		0: _spawn_dragons()
		1: airships_alive = _spawn_simple(Airships)
		2: hss_alive = _spawn_simple(HangingStudioStuff)
		3: _spawn_missiles(Missile, MissileMark, "MissileMark")
		4: _spawn_missiles(TimedMissile, TMissileMark, "TMissileMark")
		5: _spawn_batwall()

## How many homing/timed missiles are currently chasing the player.
func _missiles_alive() -> int:
	return get_tree().get_nodes_in_group("GMissiles").size()

## Places one self-managing obstacle just past the right edge (the endless mode's formula).
func _spawn_simple(res:Resource) -> Node:
	var s:int = Replay.seed_spawn()
	var obj:Node2D = res.instantiate()
	obj.position.x = player.position.x + obj.offx + screen_w() * 0.8
	parent.add_child(obj)
	Replay.track(obj, s)
	live.push_back(obj)
	return obj

## 1 dragon early, sometimes 2 later — same rows/geometry as the endless generator, with
## the row indicator so the player knows where to thread.
func _spawn_dragons() -> void:
	var nums:int = 1
	if chaos_t() > 0.5:
		nums += randi() % 2
	var offset:int = randi() % 3
	for i in range(nums):
		var row:int = (i + offset) % 3
		var y_jitter:int = randi() % 160  # drawn before seed_spawn so it can't shift the seeded stream
		var s:int = Replay.seed_spawn()
		var obj:Node2D = Dragon.instantiate()
		obj.position.x = player.position.x + 1.5 * screen_w()
		obj.position.y = dragons_info[row] + y_jitter
		obj.offx = 1.4 * screen_w()
		parent.add_child(obj)
		Replay.track(obj, s)
		indMan.indicateDragons(row, obj)

## A volley of 1-4 missiles (more as chaos ramps) from ahead and behind, plus the beeping
## warning marker if one isn't already up. Dragons/missiles clean themselves up.
func _spawn_missiles(res:Resource, mark:Resource, mark_name:String) -> void:
	var nums:int = 1 + randi() % maxi(1, int(1.0 + 3.0 * chaos_t()))
	nums = mini(nums, 4)
	var offset:int = randi() % (5 - nums)
	for i in range(nums):
		var s:int = Replay.seed_spawn()
		var obj:CharacterBody2D = res.instantiate()
		obj.position.x = player.position.x + why[i + offset] + screen_w() * rockets_info[i + offset].x
		obj.position.y = rockets_info[i + offset].y
		parent.add_child(obj)
		Replay.track(obj, s)
	if not get_node_or_null("../" + mark_name):
		parent.add_child(mark.instantiate())

## A late-game bat wall sweeping in from the right — always a single column, since
## everything else is still spawning around it.
func _spawn_batwall() -> void:
	var s:int = Replay.seed_spawn()
	var wall:Node2D = BatWall.instantiate()
	wall.max_walls = 1
	wall.position.x = player.position.x + 64 + screen_w() * 0.8
	wall.wall_dist = 1920 - int(500 * chaos_t())
	wall.difficulty = 1.0 + chaos_t()
	parent.add_child(wall)
	Replay.track(wall, s, {"max_walls": 1, "wall_dist": wall.wall_dist, "difficulty": wall.difficulty})
	live.push_back(wall)
	batwall_alive = wall

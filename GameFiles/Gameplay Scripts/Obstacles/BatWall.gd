extends Node2D
## A "Wall-o-Bats": one or more vertical walls of bats, each with a single gap to fit through.
##
## Builds up to [member max_walls] columns; each column is 25 bats tall except for a randomly
## placed gap (marked with stars so you can see the safe path). The whole wall scrolls left
## toward the player. Used in Endless mode and (capped to a single column, with
## [member wall_dist]/[member difficulty] scaled by the ramp) as a Chaos-mode air event.

var offx:int = 1920       ## Despawn clearance distance (depends on how many columns spawned).
var wall_dist:int = 1920  ## Horizontal spacing between columns.
var max_walls:int = 4     ## Most columns this wall may roll (set before adding to the tree).
						  ## Chaos mode caps it at 1 — multi-column walls are unfair there.

var walls:int             ## Number of columns in this wall (1 to max_walls).
var dontman:int           ## Row index of the gap in the current column.
var velocity:float = 1.0  ## Base leftward scroll speed.
var difficulty:float = 1.0 ## Scroll-speed multiplier (raised for later walls).
var WallBat:Resource = preload("res://GameFiles/Sprites/Obstacles/WalloBats/WallBat.tscn")
var Star:Resource = preload("res://GameFiles/Sprites/Currency/Star.tscn")
var wb:Node2D             ## Scratch: each bat or star being placed.

func _ready() -> void:
	walls = randi() % max_walls + 1
	offx = (walls - 1) * wall_dist + 1024
	for i in range(walls):
		dontman = randi()%22 + 1
		for j in range(25):
			# Near the gap row, place stars (the safe path); elsewhere, place a deadly bat.
			if abs(j - dontman) <= 2:
				wb = Star.instantiate()
			else:
				wb = WallBat.instantiate()
			wb.position = Vector2(i*wall_dist, j*45)
			add_child(wb)

func _process(_delta:float) -> void:
	position.x -= velocity * difficulty

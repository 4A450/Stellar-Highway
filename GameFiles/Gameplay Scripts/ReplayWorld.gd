extends Node2D
## The replay viewer's World node: a stand-in for the gameplay "sizeChange" playfield.
##
## Reconstructed obstacles and the real warning indicators read their parent's aspect-scaling
## factors (playfield code does [code]parent.true_scalex / parent.true_scaley[/code]). The viewer
## renders at the fixed 1920×1080 design aspect, so both factors are simply 1 — this script only
## exists so those lookups resolve.

var true_scalex := 1.0  ## Viewer aspect factor (fixed design resolution → always 1).
var true_scaley := 1.0  ## Viewer aspect factor (fixed design resolution → always 1).

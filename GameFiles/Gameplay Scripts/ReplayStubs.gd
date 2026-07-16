extends Node2D
## Stand-in "indicatorManager" for the replay viewer's world.
##
## Reconstructed obstacles (Airships, Hotel, HangingStudioStuff, dragons) announce themselves
## to [code]get_node("../indicatorManager")[/code] when they spawn. In the viewer nobody needs
## warnings — the run already happened — so this absorbs those calls with no-ops. It sits as a
## sibling of the reconstructed obstacles inside ReplayViewer's World node.

func indicateAirships() -> void:
	pass

func indicateHSS() -> void:
	pass

func indicateHotel() -> void:
	pass

func indicateDragons(_place: int, _dr: Node) -> void:
	pass

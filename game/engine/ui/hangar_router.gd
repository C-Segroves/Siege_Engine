class_name HangarRouter
extends ScreenRouter
## A ScreenRouter holding only the Hangar screen, for front ends that are not built from app screens:
## the original Earthsiege shell opens its career hangar in one, over its own 320x200 screen.

const HANGAR_SCREEN := "res://engine/ui/screens/hangar_screen.gd"


func make_screen_paths() -> Dictionary:
	return {"hangar": HANGAR_SCREEN}

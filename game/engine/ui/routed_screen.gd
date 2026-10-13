class_name RoutedScreen
extends ScreenFrame
## A ScreenFrame shown by a ScreenRouter. Subclasses build their widgets in `open(args)`.
## `herc_selector` is set by screens where a Herc is chosen (automation: --herc=<id>).

var router: ScreenRouter
var herc_selector: HercSelector


## Builds the screen; `args` are whatever the caller of ScreenRouter.go passed.
func open(_args: Dictionary) -> void:
	pass


## Title bar: the application's name and this page's name.
func set_page_title(page: String) -> void:
	set_title(router.make_app_title(), page)


## Adds the right-half hangar and a HercSelector for it to the content column; connect its
## signals, then call its setup(vehicle_id, initial_loadout).
func add_herc_selector(label_text := "Your Herc") -> HercSelector:
	herc_selector = HercSelector.new(show_hangar(), label_text)
	content.add_child(herc_selector)
	return herc_selector

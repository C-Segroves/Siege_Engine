class_name RoutedScreen
extends ScreenFrame
## A ScreenFrame shown by a ScreenRouter. Subclasses build their widgets in `open(args)`.

var router: ScreenRouter


## Builds the screen; `args` are whatever the caller of ScreenRouter.go passed.
func open(_args: Dictionary) -> void:
	pass


## Title bar: the application's name and this page's name.
func set_page_title(page: String) -> void:
	set_title(router.make_app_title(), page)

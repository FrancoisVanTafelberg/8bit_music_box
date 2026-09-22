package main_release

// Release entry point: the app linked straight in, no library swapping.
// Same call order as the hot-reload host, minus the reloading.

import app "../source"

main :: proc() {
	app.game_init_window()
	app.game_init()

	for app.game_update() {}

	app.game_shutdown()
	app.game_shutdown_window()
}

package dungeon_generator

import rl "vendor:raylib"
import "core:fmt"
import "core:math"

// ---------------------------------------------------------------------------
// Application state
// ---------------------------------------------------------------------------

Camera_Mode :: enum {
	Top_Down,
	Freeflight,
}

App_State :: struct {
	dungeon:           Dungeon,
	camera_mode:       Camera_Mode,
	topdown_camera:    Top_Down_Camera,
	freeflight_cam:    Freeflight_Camera,
	gen_animated:      bool,
	gen_step_timer:    f32,
	show_ui:           bool,
}

// Global state (accessible from ui.odin etc.)
state: App_State

// Custom UI font (loaded at startup)
ui_font: rl.Font
ui_font_loaded: bool

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

main :: proc() {
	config := Dungeon_Config{
		grid_width  = 64,
		grid_height = 64,
		cell_size   = 1.0,
		wall_height = 1.5,
	}

	rl.InitWindow(1280, 800, "Procedural Dungeon Generator")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	// Load custom font (Arial) - must be after InitWindow
	ui_font = rl.LoadFontEx("/System/Library/Fonts/Supplemental/Arial.ttf", 32, nil, 0)
	if ui_font.texture.id > 0 {
		ui_font_loaded = true
		rl.SetTextureFilter(ui_font.texture, .BILINEAR)
	}

	state.dungeon = dungeon_create(config)
	state.dungeon.recipe = recipe_classic_dungeon()
	state.camera_mode = .Top_Down
	state.topdown_camera = topdown_camera_create(config)
	state.freeflight_cam = freeflight_camera_create(config)
	state.gen_animated = false
	gen_step_interval = 0.05
	state.show_ui = true

	// Generate immediately on start (instant mode)
	dungeon_generate_full(&state.dungeon)

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		update(dt)
		draw()
	}

	dungeon_destroy(&state.dungeon)
	if ui_font_loaded {
		rl.UnloadFont(ui_font)
	}
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

update :: proc(dt: f32) {
	// Toggle camera mode
	if rl.IsKeyPressed(.TAB) {
		if state.camera_mode == .Top_Down {
			state.camera_mode = .Freeflight
			rl.DisableCursor()
		} else {
			state.camera_mode = .Top_Down
			rl.EnableCursor()
		}
	}

	// Toggle UI
	if rl.IsKeyPressed(.H) {
		state.show_ui = !state.show_ui
	}

	// Toggle animated generation
	if rl.IsKeyPressed(.G) {
		state.gen_animated = !state.gen_animated
	}

	// Regenerate dungeon
	if rl.IsKeyPressed(.R) {
		if state.gen_animated {
			dungeon_start_generation(&state.dungeon)
			state.gen_step_timer = 0
		} else {
			dungeon_generate_full(&state.dungeon)
		}
	}

	// Step through generation manually with Space
	if rl.IsKeyPressed(.SPACE) {
		if state.dungeon.gen_done {
			// Reset and start a new stepped generation
			dungeon_start_generation(&state.dungeon)
			state.gen_step_timer = 0
		}
		dungeon_generate_step(&state.dungeon)
	}

	// Animated generation auto-step
	if state.gen_animated && !state.dungeon.gen_done {
		state.gen_step_timer += dt
		if state.gen_step_timer >= gen_step_interval {
			state.gen_step_timer -= gen_step_interval
			dungeon_generate_step(&state.dungeon)
		}
	}

	// Update active camera
	switch state.camera_mode {
	case .Top_Down:
		topdown_camera_update(&state.topdown_camera, dt)
	case .Freeflight:
		freeflight_camera_update(&state.freeflight_cam, dt)
	}
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

draw :: proc() {
	rl.BeginDrawing()
	defer rl.EndDrawing()

	rl.ClearBackground({30, 30, 35, 255})

	// 3D viewport - offset by panel width when UI is visible
	viewport_x: i32 = state.show_ui ? PANEL_WIDTH : 0
	viewport_w := rl.GetScreenWidth() - viewport_x
	viewport_h := rl.GetScreenHeight()

	rl.BeginScissorMode(viewport_x, 0, viewport_w, viewport_h)

	rl_camera := get_active_rl_camera()
	rl.BeginMode3D(rl_camera)

	render_dungeon(&state.dungeon)
	render_grid_outline(&state.dungeon)
	render_areas(&state.dungeon)

	rl.EndMode3D()

	rl.EndScissorMode()

	if state.show_ui {
		draw_ui()
	}
}

get_active_rl_camera :: proc() -> rl.Camera3D {
	switch state.camera_mode {
	case .Top_Down:
		return topdown_to_rl_camera(&state.topdown_camera)
	case .Freeflight:
		return freeflight_to_rl_camera(&state.freeflight_cam)
	}
	return {}
}

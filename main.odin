package dungeon_generator

import rl "vendor:raylib"

import imgui "libs/odin-imgui"
import imgui_rl "imgui_rl"

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
	canvas:            Canvas_State,
}

// Global state (accessible from ui.odin etc.)
state: App_State

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

	imgui.CreateContext(nil)
	defer imgui.DestroyContext(nil)
	imgui_rl.init()
	defer imgui_rl.shutdown()
	imgui_rl.build_font_atlas()

	state.dungeon = dungeon_create(config)
	state.dungeon.recipe = recipe_classic_dungeon()
	state.camera_mode = .Top_Down
	state.topdown_camera = topdown_camera_create(config)
	state.freeflight_cam = freeflight_camera_create(config)
	state.gen_animated = false
	gen_step_interval = 0.05
	state.show_ui = true
	state.canvas = Canvas_State{selected_step = -1, scroll_to_step = -1}

	dungeon_generate_full(&state.dungeon)

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()

		imgui_rl.process_events()
		imgui_rl.new_frame()
		imgui.NewFrame()

		update(dt)
		draw()
	}

	dungeon_destroy(&state.dungeon)
}

// ---------------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------------

update :: proc(dt: f32) {
	io := imgui.GetIO()

	if !io.WantCaptureKeyboard {
		if rl.IsKeyPressed(.TAB) {
			if state.camera_mode == .Top_Down {
				state.camera_mode = .Freeflight
				rl.DisableCursor()
			} else {
				state.camera_mode = .Top_Down
				rl.EnableCursor()
			}
		}

		if rl.IsKeyPressed(.H) {
			state.show_ui = !state.show_ui
		}

		if rl.IsKeyPressed(.G) {
			state.gen_animated = !state.gen_animated
		}

		if rl.IsKeyPressed(.R) {
			if state.gen_animated {
				dungeon_start_generation(&state.dungeon)
				state.gen_step_timer = 0
			} else {
				dungeon_generate_full(&state.dungeon)
			}
		}

		if rl.IsKeyPressed(.SPACE) {
			if state.dungeon.gen_done {
				dungeon_start_generation(&state.dungeon)
				state.gen_step_timer = 0
			}
			dungeon_generate_step(&state.dungeon)
		}
	}

	if state.gen_animated && !state.dungeon.gen_done {
		state.gen_step_timer += dt
		if state.gen_step_timer >= gen_step_interval {
			state.gen_step_timer -= gen_step_interval
			dungeon_generate_step(&state.dungeon)
		}
	}

	canvas_update()

	if !io.WantCaptureMouse {
		switch state.camera_mode {
		case .Top_Down:
			topdown_camera_update(&state.topdown_camera, dt)
		case .Freeflight:
			freeflight_camera_update(&state.freeflight_cam, dt)
		}
	}
}

// ---------------------------------------------------------------------------
// Draw
// ---------------------------------------------------------------------------

draw :: proc() {
	rl.BeginDrawing()
	defer rl.EndDrawing()

	rl.ClearBackground({30, 30, 35, 255})

	viewport_x: i32 = state.show_ui ? PANEL_WIDTH : 0
	viewport_w := rl.GetScreenWidth() - viewport_x
	viewport_h := rl.GetScreenHeight()

	rl.BeginScissorMode(viewport_x, 0, viewport_w, viewport_h)

	rl_camera := get_active_rl_camera()
	rl.BeginMode3D(rl_camera)

	render_dungeon(&state.dungeon)
	render_grid_outline(&state.dungeon)
	render_areas(&state.dungeon)
	canvas_render_3d(&state.dungeon)

	rl.EndMode3D()

	rl.EndScissorMode()

	if state.show_ui {
		draw_ui()
	}

	canvas_draw_imgui()

	imgui.Render()
	imgui_rl.render_draw_data(imgui.GetDrawData())
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

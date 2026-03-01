package dungeon_generator

import rl "vendor:raylib"
import "core:math"
import "core:math/linalg"

// ---------------------------------------------------------------------------
// Top-Down Camera
// ---------------------------------------------------------------------------

Top_Down_Camera :: struct {
	target_x: f32, // grid-space center the camera looks at
	target_y: f32,
	height:   f32, // camera height above the grid
	min_h:    f32,
	max_h:    f32,
}

topdown_camera_create :: proc(config: Dungeon_Config) -> Top_Down_Camera {
	cx := f32(config.grid_width) * config.cell_size * 0.5
	cy := f32(config.grid_height) * config.cell_size * 0.5
	return Top_Down_Camera{
		target_x = cx,
		target_y = cy,
		height   = f32(max(config.grid_width, config.grid_height)) * config.cell_size * 0.8,
		min_h    = 5.0,
		max_h    = f32(max(config.grid_width, config.grid_height)) * config.cell_size * 1.5,
	}
}

topdown_camera_update :: proc(cam: ^Top_Down_Camera, dt: f32) {
	mouse_on_panel := state.show_ui && ui_mouse_on_panel()

	// Zoom (only when mouse is not on panel)
	if !mouse_on_panel {
		scroll := rl.GetMouseWheelMove()
		if scroll != 0 {
			cam.height -= scroll * cam.height * 0.1
			cam.height = clamp(cam.height, cam.min_h, cam.max_h)
		}
	}

	// Pan with arrow keys or WASD
	pan_speed := cam.height * 0.8 * dt
	if rl.IsKeyDown(.LEFT)  || rl.IsKeyDown(.A) do cam.target_x -= pan_speed
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) do cam.target_x += pan_speed
	if rl.IsKeyDown(.UP)    || rl.IsKeyDown(.W) do cam.target_y -= pan_speed
	if rl.IsKeyDown(.DOWN)  || rl.IsKeyDown(.S) do cam.target_y += pan_speed

	// Pan with middle-mouse drag (only when mouse not on panel)
	if !mouse_on_panel && rl.IsMouseButtonDown(.MIDDLE) {
		delta := rl.GetMouseDelta()
		cam.target_x -= f32(delta.x) * cam.height * 0.002
		cam.target_y -= f32(delta.y) * cam.height * 0.002
	}
}

topdown_to_rl_camera :: proc(cam: ^Top_Down_Camera) -> rl.Camera3D {
	return rl.Camera3D{
		position   = {cam.target_x, cam.height, cam.target_y + 0.01}, // slight offset to avoid gimbal lock
		target     = {cam.target_x, 0, cam.target_y},
		up         = {0, 0, -1}, // so that grid +Y maps to screen down
		fovy       = 45.0,
		projection = .PERSPECTIVE,
	}
}

// ---------------------------------------------------------------------------
// Freeflight Camera (flight-sim style)
// ---------------------------------------------------------------------------

Freeflight_Camera :: struct {
	pos:        [3]f32,
	yaw:        f32, // radians, 0 = looking along +Z
	pitch:      f32, // radians, clamped
	speed:      f32,
	mouse_sens: f32,
}

freeflight_camera_create :: proc(config: Dungeon_Config) -> Freeflight_Camera {
	cx := f32(config.grid_width) * config.cell_size * 0.5
	cy := f32(config.grid_height) * config.cell_size * 0.5
	return Freeflight_Camera{
		pos        = {cx, config.wall_height * 3.0, cy},
		yaw        = 0,
		pitch      = -0.3, // slight downward look
		speed      = 10.0,
		mouse_sens = 0.003,
	}
}

freeflight_camera_update :: proc(cam: ^Freeflight_Camera, dt: f32) {
	// Mouse look
	delta := rl.GetMouseDelta()
	cam.yaw   -= f32(delta.x) * cam.mouse_sens
	cam.pitch -= f32(delta.y) * cam.mouse_sens
	cam.pitch = clamp(cam.pitch, -math.PI / 2.0 + 0.01, math.PI / 2.0 - 0.01)

	// Compute forward and right vectors
	forward := [3]f32{
		math.sin(cam.yaw) * math.cos(cam.pitch),
		math.sin(cam.pitch),
		math.cos(cam.yaw) * math.cos(cam.pitch),
	}
	right := [3]f32{
		-math.cos(cam.yaw),
		0,
		math.sin(cam.yaw),
	}
	up := [3]f32{0, 1, 0}

	// Speed control via scroll wheel
	scroll := rl.GetMouseWheelMove()
	if scroll != 0 {
		cam.speed *= 1.0 + scroll * 0.1
		cam.speed = clamp(cam.speed, 1.0, 100.0)
	}

	move_speed := cam.speed * dt

	// WASD movement
	if rl.IsKeyDown(.W) {
		cam.pos[0] += forward[0] * move_speed
		cam.pos[1] += forward[1] * move_speed
		cam.pos[2] += forward[2] * move_speed
	}
	if rl.IsKeyDown(.S) {
		cam.pos[0] -= forward[0] * move_speed
		cam.pos[1] -= forward[1] * move_speed
		cam.pos[2] -= forward[2] * move_speed
	}
	if rl.IsKeyDown(.A) {
		cam.pos[0] -= right[0] * move_speed
		cam.pos[1] -= right[1] * move_speed
		cam.pos[2] -= right[2] * move_speed
	}
	if rl.IsKeyDown(.D) {
		cam.pos[0] += right[0] * move_speed
		cam.pos[1] += right[1] * move_speed
		cam.pos[2] += right[2] * move_speed
	}

	// Vertical movement
	if rl.IsKeyDown(.E) {
		cam.pos[1] += move_speed
	}
	if rl.IsKeyDown(.Q) {
		cam.pos[1] -= move_speed
	}
}

freeflight_to_rl_camera :: proc(cam: ^Freeflight_Camera) -> rl.Camera3D {
	forward := [3]f32{
		math.sin(cam.yaw) * math.cos(cam.pitch),
		math.sin(cam.pitch),
		math.cos(cam.yaw) * math.cos(cam.pitch),
	}
	target := [3]f32{
		cam.pos[0] + forward[0],
		cam.pos[1] + forward[1],
		cam.pos[2] + forward[2],
	}
	return rl.Camera3D{
		position   = {cam.pos[0], cam.pos[1], cam.pos[2]},
		target     = {target[0], target[1], target[2]},
		up         = {0, 1, 0},
		fovy       = 60.0,
		projection = .PERSPECTIVE,
	}
}

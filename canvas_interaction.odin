package dungeon_generator

import rl "vendor:raylib"
import "core:math"
import "core:fmt"
import "core:c"

import imgui "libs/odin-imgui"

// ---------------------------------------------------------------------------
// Canvas interaction state
// ---------------------------------------------------------------------------

Canvas_Mode :: enum {
	None,
	Drawing_Area,
	Dragging,
}

Canvas_Hit :: enum {
	None,
	Corner_NW, Corner_NE, Corner_SE, Corner_SW,
	Edge_North, Edge_East, Edge_South, Edge_West,
}

Canvas_State :: struct {
	mode:             Canvas_Mode,
	selected_step:    int,   // recipe step index of selected area, -1 = none
	scroll_to_step:   int,   // one-shot request to scroll UI to this step, -1 = none
	// Context menu
	context_open:     bool,
	context_gx:       int,
	context_gy:       int,
	context_screen_x: f32,
	context_screen_y: f32,
	// Drawing mode
	drawing:          bool,
	draw_start_gx:    int,
	draw_start_gy:    int,
	draw_end_gx:      int,
	draw_end_gy:      int,
	// Dragging (corners resize, edges move)
	drag_hit:         Canvas_Hit,
	drag_start_gx:    int,
	drag_start_gy:    int,
	drag_orig_x:      int,
	drag_orig_y:      int,
	drag_orig_w:      int,
	drag_orig_h:      int,
}

// ---------------------------------------------------------------------------
// Coordinate conversion
// ---------------------------------------------------------------------------

// Raycast from screen position to the Y=0 ground plane.
screen_to_ground :: proc(screen_pos: rl.Vector2, camera: rl.Camera3D) -> (world_x, world_z: f32, ok: bool) {
	ray := rl.GetScreenToWorldRay(screen_pos, camera)
	if abs(ray.direction.y) < 0.0001 do return 0, 0, false
	t := -ray.position.y / ray.direction.y
	if t < 0 do return 0, 0, false
	return ray.position.x + t * ray.direction.x, ray.position.z + t * ray.direction.z, true
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

// Find what part of an area the cursor is near. Corners are prioritised over edges.
canvas_find_area_near :: proc(d: ^Dungeon, gx, gy: f32, threshold: f32) -> (area_id: int, hit: Canvas_Hit, found: bool) {
	best_dist: f32 = threshold + 1

	corner_dist :: proc(gx, gy, cx, cy: f32) -> f32 {
		dx := gx - cx
		dy := gy - cy
		return math.sqrt(dx * dx + dy * dy)
	}

	// First pass: check corners (tighter radius wins over edges)
	for &area in d.areas {
		if area.shape != .Rectangle do continue

		ax0 := f32(area.x)
		ay0 := f32(area.y)
		ax1 := f32(area.x + area.w)
		ay1 := f32(area.y + area.h)

		corners := [4]struct{ cx, cy: f32, h: Canvas_Hit }{
			{ax0, ay0, .Corner_NW},
			{ax1, ay0, .Corner_NE},
			{ax1, ay1, .Corner_SE},
			{ax0, ay1, .Corner_SW},
		}

		for c in corners {
			d := corner_dist(gx, gy, c.cx, c.cy)
			if d < best_dist {
				best_dist = d
				area_id = area.id
				hit = c.h
				found = true
			}
		}
	}

	// If we found a corner within threshold, return it
	if found do return

	// Second pass: check edges (point must be within the edge span)
	for &area in d.areas {
		if area.shape != .Rectangle do continue

		ax0 := f32(area.x)
		ay0 := f32(area.y)
		ax1 := f32(area.x + area.w)
		ay1 := f32(area.y + area.h)

		if gx >= ax0 && gx <= ax1 {
			dn := abs(gy - ay0)
			if dn < best_dist { best_dist = dn; area_id = area.id; hit = .Edge_North; found = true }
			ds := abs(gy - ay1)
			if ds < best_dist { best_dist = ds; area_id = area.id; hit = .Edge_South; found = true }
		}
		if gy >= ay0 && gy <= ay1 {
			dw := abs(gx - ax0)
			if dw < best_dist { best_dist = dw; area_id = area.id; hit = .Edge_West; found = true }
			de := abs(gx - ax1)
			if de < best_dist { best_dist = de; area_id = area.id; hit = .Edge_East; found = true }
		}
	}
	return
}

// Find the first Define_Area recipe step whose area_id matches.
canvas_find_step_for_area_id :: proc(d: ^Dungeon, aid: int) -> int {
	for si in 0 ..< len(d.recipe.steps) {
		step := &d.recipe.steps[si]
		if step.type == .Define_Area && step.define_area.area_id == aid {
			return si
		}
	}
	return -1
}

// Find the next unused area ID across all Define_Area steps.
canvas_next_area_id :: proc(d: ^Dungeon) -> int {
	max_id := -1
	for &step in d.recipe.steps {
		if step.type == .Define_Area && step.define_area.area_id > max_id {
			max_id = step.define_area.area_id
		}
	}
	return max_id + 1
}

// Sync a Dungeon_Area entry in d.areas to match a Define_Area step's params.
canvas_sync_area :: proc(d: ^Dungeon, p: ^Define_Area_Params) {
	for &a in d.areas {
		if a.id == p.area_id {
			a.shape = p.shape
			a.x = p.x
			a.y = p.y
			a.w = p.w
			a.h = p.h
			return
		}
	}
	// Not found — add it for immediate visibility
	append(&d.areas, Dungeon_Area{
		id    = p.area_id,
		shape = p.shape,
		x     = p.x,
		y     = p.y,
		w     = p.w,
		h     = p.h,
	})
}

// ---------------------------------------------------------------------------
// Update (called every frame from main update)
// ---------------------------------------------------------------------------

canvas_update :: proc() {
	if state.camera_mode != .Top_Down do return

	io := imgui.GetIO()
	if io.WantCaptureMouse do return

	d := &state.dungeon
	cs := d.config.cell_size
	camera := get_active_rl_camera()
	mouse_pos := rl.GetMousePosition()

	world_x, world_z, ground_ok := screen_to_ground(mouse_pos, camera)
	if !ground_ok do return

	grid_fx := world_x / cs
	grid_fy := world_z / cs
	gx := int(math.floor(grid_fx))
	gy := int(math.floor(grid_fy))

	cv := &state.canvas

	switch cv.mode {
	case .None:
		if rl.IsMouseButtonPressed(.RIGHT) {
			cv.context_gx = gx
			cv.context_gy = gy
			cv.context_screen_x = mouse_pos.x
			cv.context_screen_y = mouse_pos.y
			cv.context_open = true
		}

		if rl.IsMouseButtonPressed(.LEFT) {
			threshold: f32 = 1.5
			aid, hit, found := canvas_find_area_near(d, grid_fx, grid_fy, threshold)
			if found {
				step_idx := canvas_find_step_for_area_id(d, aid)
				if step_idx >= 0 {
					cv.selected_step = step_idx
					cv.scroll_to_step = step_idx
					cv.drag_hit = hit
					cv.drag_start_gx = gx
					cv.drag_start_gy = gy
					step := &d.recipe.steps[step_idx]
					cv.drag_orig_x = step.define_area.x
					cv.drag_orig_y = step.define_area.y
					cv.drag_orig_w = step.define_area.w
					cv.drag_orig_h = step.define_area.h
					cv.mode = .Dragging
				}
			} else {
				cv.selected_step = -1
			}
		}

	case .Drawing_Area:
		if rl.IsKeyPressed(.ESCAPE) || rl.IsMouseButtonPressed(.RIGHT) {
			cv.mode = .None
			cv.drawing = false
			return
		}

		cv.draw_end_gx = gx
		cv.draw_end_gy = gy

		if !cv.drawing && rl.IsMouseButtonPressed(.LEFT) {
			cv.drawing = true
			cv.draw_start_gx = gx
			cv.draw_start_gy = gy
			cv.draw_end_gx = gx
			cv.draw_end_gy = gy
		}

		if cv.drawing && rl.IsMouseButtonReleased(.LEFT) {
			x0 := min(cv.draw_start_gx, cv.draw_end_gx)
			y0 := min(cv.draw_start_gy, cv.draw_end_gy)
			x1 := max(cv.draw_start_gx, cv.draw_end_gx)
			y1 := max(cv.draw_start_gy, cv.draw_end_gy)
			w := max(x1 - x0, 1)
			h := max(y1 - y0, 1)

			new_id := canvas_next_area_id(d)
			new_step := make_step(.Define_Area)
			new_step.define_area = {
				area_id = new_id,
				shape   = .Rectangle,
				x       = x0,
				y       = y0,
				w       = w,
				h       = h,
			}
			append(&d.recipe.steps, new_step)
			canvas_sync_area(d, &d.recipe.steps[len(d.recipe.steps) - 1].define_area)

			cv.selected_step = len(d.recipe.steps) - 1
			cv.scroll_to_step = len(d.recipe.steps) - 1
			cv.drawing = false
			cv.mode = .None
		}

	case .Dragging:
		if rl.IsMouseButtonReleased(.LEFT) || rl.IsKeyPressed(.ESCAPE) {
			cv.mode = .None
			return
		}

		if cv.selected_step >= 0 && cv.selected_step < len(d.recipe.steps) {
			step := &d.recipe.steps[cv.selected_step]
			if step.type == .Define_Area {
				p := &step.define_area
				dx := gx - cv.drag_start_gx
				dy := gy - cv.drag_start_gy

				switch cv.drag_hit {
				case .None:

				// Corners: resize by moving the dragged corner, opposite stays fixed
				case .Corner_NW:
					dx_c := min(dx, cv.drag_orig_w - 1)
					dy_c := min(dy, cv.drag_orig_h - 1)
					p.x = cv.drag_orig_x + dx_c
					p.y = cv.drag_orig_y + dy_c
					p.w = cv.drag_orig_w - dx_c
					p.h = cv.drag_orig_h - dy_c
				case .Corner_NE:
					dy_c := min(dy, cv.drag_orig_h - 1)
					p.y = cv.drag_orig_y + dy_c
					p.w = max(cv.drag_orig_w + dx, 1)
					p.h = cv.drag_orig_h - dy_c
				case .Corner_SE:
					p.w = max(cv.drag_orig_w + dx, 1)
					p.h = max(cv.drag_orig_h + dy, 1)
				case .Corner_SW:
					dx_c := min(dx, cv.drag_orig_w - 1)
					p.x = cv.drag_orig_x + dx_c
					p.w = cv.drag_orig_w - dx_c
					p.h = max(cv.drag_orig_h + dy, 1)

				// Edges: move the entire area
				case .Edge_North, .Edge_South, .Edge_East, .Edge_West:
					p.x = cv.drag_orig_x + dx
					p.y = cv.drag_orig_y + dy
				}

				canvas_sync_area(d, p)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Imgui context menu (called every frame from draw)
// ---------------------------------------------------------------------------

canvas_draw_imgui :: proc() {
	d := &state.dungeon
	cv := &state.canvas

	imgui.SetNextWindowPos({-100, -100})
	imgui.SetNextWindowSize({1, 1})
	if imgui.Begin("##canvas_popup_host", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .NoBringToFrontOnFocus, .NoFocusOnAppearing}) {
		if cv.context_open {
			imgui.OpenPopup("##canvas_ctx")
			cv.context_open = false
		}

		imgui.SetNextWindowPos({cv.context_screen_x, cv.context_screen_y}, .Appearing)
		if imgui.BeginPopup("##canvas_ctx") {
			imgui.Text("Grid: (%d, %d)", c.int(cv.context_gx), c.int(cv.context_gy))
			imgui.Separator()

			if imgui.MenuItem("Define Area Here") {
				new_id := canvas_next_area_id(d)
				new_step := make_step(.Define_Area)
				cx := cv.context_gx
				cy := cv.context_gy
				new_step.define_area = {
					area_id = new_id,
					shape   = .Rectangle,
					x       = cx - 8,
					y       = cy - 8,
					w       = 16,
					h       = 16,
				}
				append(&d.recipe.steps, new_step)
				canvas_sync_area(d, &d.recipe.steps[len(d.recipe.steps) - 1].define_area)
				cv.selected_step = len(d.recipe.steps) - 1
				cv.scroll_to_step = len(d.recipe.steps) - 1
			}

			if imgui.MenuItem("Draw Area...") {
				cv.mode = .Drawing_Area
				cv.drawing = false
			}

			imgui.EndPopup()
		}
	}
	imgui.End()

	// Status overlay when in drawing mode
	if cv.mode == .Drawing_Area {
		display_size := imgui.GetIO().DisplaySize
		text: cstring = cv.drawing ? "Drag to size, release to place" : "Click and drag to define area  [Esc] cancel"
		text_size := imgui.CalcTextSize(text)
		imgui.SetNextWindowPos({(display_size.x - text_size.x) * 0.5 - 8, 8})
		imgui.SetNextWindowSize({text_size.x + 16, text_size.y + 12})
		imgui.SetNextWindowBgAlpha(0.7)
		if imgui.Begin("##draw_hint", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .NoBringToFrontOnFocus, .NoFocusOnAppearing}) {
			imgui.TextColored({0.4, 1.0, 0.7, 1.0}, text)
		}
		imgui.End()
	}
}

// ---------------------------------------------------------------------------
// 3D overlay rendering (called inside Mode3D)
// ---------------------------------------------------------------------------

canvas_render_3d :: proc(d: ^Dungeon) {
	cs := d.config.cell_size
	cv := &state.canvas
	y: f32 = 0.04

	// Highlight selected area
	if cv.selected_step >= 0 && cv.selected_step < len(d.recipe.steps) {
		step := &d.recipe.steps[cv.selected_step]
		if step.type == .Define_Area {
			p := &step.define_area
			if p.shape == .Rectangle {
				x0 := f32(p.x) * cs
				z0 := f32(p.y) * cs
				x1 := f32(p.x + p.w) * cs
				z1 := f32(p.y + p.h) * cs
				highlight := rl.Color{255, 255, 255, 240}

				// Bright outline
				rl.DrawLine3D({x0, y, z0}, {x1, y, z0}, highlight)
				rl.DrawLine3D({x1, y, z0}, {x1, y, z1}, highlight)
				rl.DrawLine3D({x1, y, z1}, {x0, y, z1}, highlight)
				rl.DrawLine3D({x0, y, z1}, {x0, y, z0}, highlight)

				// Corner handles (resize)
				hs: f32 = cs * 0.35
				corner_color := rl.Color{255, 255, 100, 255}
				rl.DrawCube({x0, y, z0}, hs, 0.02, hs, corner_color)
				rl.DrawCube({x1, y, z0}, hs, 0.02, hs, corner_color)
				rl.DrawCube({x1, y, z1}, hs, 0.02, hs, corner_color)
				rl.DrawCube({x0, y, z1}, hs, 0.02, hs, corner_color)

				// Edge midpoint handles (move)
				move_color := rl.Color{100, 200, 255, 255}
				mx := (x0 + x1) * 0.5
				mz := (z0 + z1) * 0.5
				eh: f32 = cs * 0.25
				rl.DrawCube({mx, y, z0}, eh, 0.02, eh, move_color)
				rl.DrawCube({mx, y, z1}, eh, 0.02, eh, move_color)
				rl.DrawCube({x0, y, mz}, eh, 0.02, eh, move_color)
				rl.DrawCube({x1, y, mz}, eh, 0.02, eh, move_color)
			}
		}
	}

	// Draw preview rectangle
	if cv.mode == .Drawing_Area && cv.drawing {
		x0 := f32(min(cv.draw_start_gx, cv.draw_end_gx)) * cs
		z0 := f32(min(cv.draw_start_gy, cv.draw_end_gy)) * cs
		x1 := f32(max(cv.draw_start_gx, cv.draw_end_gx) + 1) * cs
		z1 := f32(max(cv.draw_start_gy, cv.draw_end_gy) + 1) * cs
		preview := rl.Color{100, 255, 180, 255}

		rl.DrawLine3D({x0, y, z0}, {x1, y, z0}, preview)
		rl.DrawLine3D({x1, y, z0}, {x1, y, z1}, preview)
		rl.DrawLine3D({x1, y, z1}, {x0, y, z1}, preview)
		rl.DrawLine3D({x0, y, z1}, {x0, y, z0}, preview)

		// Translucent fill
		cx := (x0 + x1) * 0.5
		cz := (z0 + z1) * 0.5
		rl.DrawCube({cx, 0.01, cz}, x1 - x0, 0.001, z1 - z0, {100, 255, 180, 30})
	}
}

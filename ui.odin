package dungeon_generator

import rl "vendor:raylib"
import "core:fmt"
import "core:math"

// ---------------------------------------------------------------------------
// Side panel UI
// ---------------------------------------------------------------------------

PANEL_WIDTH :: 280

// Colors
UI_BG           :: rl.Color{35, 35, 42, 245}
UI_HEADER_BG    :: rl.Color{45, 45, 55, 255}
UI_WIDGET_BG    :: rl.Color{55, 55, 65, 255}
UI_WIDGET_HOVER :: rl.Color{70, 70, 85, 255}
UI_WIDGET_ACTIVE:: rl.Color{85, 85, 105, 255}
UI_ACCENT       :: rl.Color{100, 160, 255, 255}
UI_ACCENT_HOVER :: rl.Color{130, 180, 255, 255}
UI_TEXT          :: rl.Color{220, 220, 230, 255}
UI_TEXT_DIM      :: rl.Color{140, 140, 155, 255}
UI_SEPARATOR    :: rl.Color{60, 60, 72, 255}
UI_STEP_BG      :: rl.Color{42, 42, 52, 255}
UI_STEP_ACTIVE  :: rl.Color{50, 55, 70, 255}
UI_REMOVE_BG    :: rl.Color{120, 50, 50, 255}
UI_REMOVE_HOVER :: rl.Color{160, 60, 60, 255}

// Step type colors for visual distinction
STEP_TYPE_COLORS := [Step_Type]rl.Color{
	.Seed_Rooms      = rl.Color{100, 200, 120, 255},
	.Grow_Clusters   = rl.Color{200, 180, 80, 255},
	.Connect_MST     = rl.Color{100, 160, 255, 255},
	.Mark_Doors      = rl.Color{200, 130, 200, 255},
	.Add_Loops       = rl.Color{120, 200, 255, 255},
	.Widen_Corridors = rl.Color{255, 160, 80, 255},
	.BSP_Partition   = rl.Color{80, 220, 180, 255},
	.Fill_Dead_Ends  = rl.Color{220, 100, 100, 255},
	.Place_Grid      = rl.Color{180, 220, 100, 255},
	.Room_Corridor   = rl.Color{255, 200, 150, 255},
	.Define_Area     = rl.Color{200, 200, 255, 255},
	.Pack_Rooms      = rl.Color{160, 255, 180, 255},
	.Join_Rooms      = rl.Color{255, 220, 180, 255},
	.Connect_Doors   = rl.Color{255, 180, 220, 255},
}

// UI layout state (reset each frame)
UI_Layout :: struct {
	x:       i32, // left edge of content area
	y:       i32, // current y cursor
	w:       i32, // content width
	padding: i32,
	spacing: i32,
	mouse_on_panel: bool, // true if mouse is over the panel
}

ui_layout: UI_Layout

// Active dropdown tracking (only one can be open at a time)
active_dropdown: cstring  // label of currently open dropdown, nil if none
dropdown_scroll: i32      // scroll offset for open dropdown

// Recipe editor state
preset_selected: int = 0
add_step_type_selected: int = 0
expanded_steps: [32]bool   // which steps are expanded (up to 32 steps)

// Check if mouse is over the side panel
ui_mouse_on_panel :: proc() -> bool {
	mx := rl.GetMouseX()
	return mx < PANEL_WIDTH
}

// ---------------------------------------------------------------------------
// Widget primitives
// ---------------------------------------------------------------------------

// Section header
ui_section :: proc(label: cstring) {
	l := &ui_layout
	l.y += l.spacing
	rl.DrawRectangle(0, l.y, PANEL_WIDTH, 24, UI_HEADER_BG)
	rl.DrawText(label, l.x, l.y + 4, 14, UI_ACCENT)
	l.y += 24 + l.spacing
}

// Separator line
ui_separator :: proc() {
	l := &ui_layout
	l.y += l.spacing / 2
	rl.DrawLine(l.x, l.y, l.x + l.w, l.y, UI_SEPARATOR)
	l.y += l.spacing / 2
}

ui_spacer :: proc(amount: i32 = 4) {
	ui_layout.y += amount
}

// Label
ui_label :: proc(text: cstring, color: rl.Color = UI_TEXT) {
	l := &ui_layout
	rl.DrawText(text, l.x, l.y, 14, color)
	l.y += 18
}

// Label with value on the right side
ui_label_value :: proc(label: cstring, value: cstring, value_color: rl.Color = UI_ACCENT) {
	l := &ui_layout
	rl.DrawText(label, l.x, l.y, 14, UI_TEXT_DIM)
	val_width := rl.MeasureText(value, 14)
	rl.DrawText(value, l.x + l.w - val_width, l.y, 14, value_color)
	l.y += 18
}

// Button - returns true if clicked
ui_button :: proc(label: cstring, accent: bool = false) -> bool {
	l := &ui_layout
	btn_h: i32 = 28
	rect := rl.Rectangle{f32(l.x), f32(l.y), f32(l.w), f32(btn_h)}

	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, rect) && active_dropdown == nil
	pressed := hovered && rl.IsMouseButtonPressed(.LEFT)

	bg: rl.Color
	if accent {
		bg = pressed ? UI_WIDGET_ACTIVE : (hovered ? UI_ACCENT_HOVER : UI_ACCENT)
	} else {
		bg = pressed ? UI_WIDGET_ACTIVE : (hovered ? UI_WIDGET_HOVER : UI_WIDGET_BG)
	}
	rl.DrawRectangleRec(rect, bg)

	text_color: rl.Color = accent ? rl.Color{20, 20, 25, 255} : UI_TEXT
	tw := rl.MeasureText(label, 14)
	rl.DrawText(label, l.x + (l.w - tw) / 2, l.y + 7, 14, text_color)

	l.y += btn_h + l.spacing

	return pressed
}

// Small inline button - returns true if clicked
ui_small_button :: proc(x, y, w, h: i32, label: cstring, bg_color, hover_color: rl.Color) -> bool {
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, rect) && active_dropdown == nil
	pressed := hovered && rl.IsMouseButtonPressed(.LEFT)

	rl.DrawRectangleRec(rect, hovered ? hover_color : bg_color)
	tw := rl.MeasureText(label, 12)
	rl.DrawText(label, x + (w - tw) / 2, y + (h - 12) / 2, 12, UI_TEXT)

	return pressed
}

// Integer stepper: [label]  [-] value [+]
ui_int_stepper :: proc(label: cstring, value: ^int, min_val, max_val, step: int) -> bool {
	l := &ui_layout
	row_h: i32 = 26
	btn_w: i32 = 28
	changed := false

	// Label
	rl.DrawText(label, l.x, l.y + 5, 14, UI_TEXT_DIM)

	// Value display + buttons on right side
	right_x := l.x + l.w
	mouse := rl.GetMousePosition()

	// [+] button
	plus_rect := rl.Rectangle{f32(right_x - btn_w), f32(l.y), f32(btn_w), f32(row_h)}
	plus_hovered := rl.CheckCollisionPointRec(mouse, plus_rect) && active_dropdown == nil
	rl.DrawRectangleRec(plus_rect, plus_hovered ? UI_WIDGET_HOVER : UI_WIDGET_BG)
	rl.DrawText("+", right_x - btn_w + 9, l.y + 6, 14, UI_TEXT)
	if plus_hovered && rl.IsMouseButtonPressed(.LEFT) {
		value^ = min(max_val, value^ + step)
		changed = true
	}

	// Value text
	val_text := fmt.ctprintf("%d", value^)
	val_w := rl.MeasureText(val_text, 14)
	val_x := right_x - btn_w - 8 - val_w
	rl.DrawText(val_text, val_x, l.y + 6, 14, UI_TEXT)

	// [-] button
	minus_rect := rl.Rectangle{f32(val_x - 8 - btn_w), f32(l.y), f32(btn_w), f32(row_h)}
	minus_hovered := rl.CheckCollisionPointRec(mouse, minus_rect) && active_dropdown == nil
	rl.DrawRectangleRec(minus_rect, minus_hovered ? UI_WIDGET_HOVER : UI_WIDGET_BG)
	rl.DrawText("-", val_x - 8 - btn_w + 10, l.y + 6, 14, UI_TEXT)
	if minus_hovered && rl.IsMouseButtonPressed(.LEFT) {
		value^ = max(min_val, value^ - step)
		changed = true
	}

	l.y += row_h + l.spacing

	return changed
}

// Integer stepper with a custom text label instead of the raw number: [label]  [-] text [+]
ui_labeled_stepper :: proc(label: cstring, value: ^int, min_val, max_val, step: int, display_text: cstring) -> bool {
	l := &ui_layout
	row_h: i32 = 26
	btn_w: i32 = 28
	changed := false

	// Label
	rl.DrawText(label, l.x, l.y + 5, 14, UI_TEXT_DIM)

	// Value display + buttons on right side
	right_x := l.x + l.w
	mouse := rl.GetMousePosition()

	// [+] button
	plus_rect := rl.Rectangle{f32(right_x - btn_w), f32(l.y), f32(btn_w), f32(row_h)}
	plus_hovered := rl.CheckCollisionPointRec(mouse, plus_rect) && active_dropdown == nil
	rl.DrawRectangleRec(plus_rect, plus_hovered ? UI_WIDGET_HOVER : UI_WIDGET_BG)
	rl.DrawText("+", right_x - btn_w + 9, l.y + 6, 14, UI_TEXT)
	if plus_hovered && rl.IsMouseButtonPressed(.LEFT) {
		value^ = min(max_val, value^ + step)
		changed = true
	}

	// Display text (custom label instead of number)
	val_w := rl.MeasureText(display_text, 14)
	val_x := right_x - btn_w - 8 - val_w
	rl.DrawText(display_text, val_x, l.y + 6, 14, UI_TEXT)

	// [-] button
	minus_rect := rl.Rectangle{f32(val_x - 8 - btn_w), f32(l.y), f32(btn_w), f32(row_h)}
	minus_hovered := rl.CheckCollisionPointRec(mouse, minus_rect) && active_dropdown == nil
	rl.DrawRectangleRec(minus_rect, minus_hovered ? UI_WIDGET_HOVER : UI_WIDGET_BG)
	rl.DrawText("-", val_x - 8 - btn_w + 10, l.y + 6, 14, UI_TEXT)
	if minus_hovered && rl.IsMouseButtonPressed(.LEFT) {
		value^ = max(min_val, value^ - step)
		changed = true
	}

	l.y += row_h + l.spacing

	return changed
}

// Float slider
ui_slider :: proc(label: cstring, value: ^f32, min_val, max_val: f32, fmt_str: string = "%.1f") -> bool {
	l := &ui_layout
	row_h: i32 = 16
	slider_h: i32 = 12
	changed := false

	// Label + value
	val_text := fmt.ctprintf(fmt_str, value^)
	rl.DrawText(label, l.x, l.y, 14, UI_TEXT_DIM)
	val_w := rl.MeasureText(val_text, 14)
	rl.DrawText(val_text, l.x + l.w - val_w, l.y, 14, UI_TEXT)
	l.y += row_h + 2

	// Slider track
	track_rect := rl.Rectangle{f32(l.x), f32(l.y), f32(l.w), f32(slider_h)}
	rl.DrawRectangleRec(track_rect, UI_WIDGET_BG)

	// Slider fill
	t := (value^ - min_val) / (max_val - min_val)
	fill_w := f32(l.w) * t
	rl.DrawRectangle(l.x, l.y, i32(fill_w), slider_h, UI_ACCENT)

	// Handle
	handle_x := f32(l.x) + fill_w
	rl.DrawCircle(i32(handle_x), l.y + slider_h / 2, 7, UI_ACCENT_HOVER)

	// Interaction
	mouse := rl.GetMousePosition()
	if rl.CheckCollisionPointRec(mouse, track_rect) && active_dropdown == nil {
		if rl.IsMouseButtonDown(.LEFT) {
			new_t := clamp((mouse.x - f32(l.x)) / f32(l.w), 0, 1)
			value^ = min_val + new_t * (max_val - min_val)
			changed = true
		}
	}

	l.y += slider_h + l.spacing + 2

	return changed
}

// Toggle / checkbox
ui_toggle :: proc(label: cstring, value: ^bool) -> bool {
	l := &ui_layout
	row_h: i32 = 24
	box_size: i32 = 18
	changed := false

	rect := rl.Rectangle{f32(l.x), f32(l.y), f32(l.w), f32(row_h)}
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, rect) && active_dropdown == nil

	// Checkbox
	box_y := l.y + (row_h - box_size) / 2
	rl.DrawRectangle(l.x, box_y, box_size, box_size, hovered ? UI_WIDGET_HOVER : UI_WIDGET_BG)
	if value^ {
		rl.DrawRectangle(l.x + 3, box_y + 3, box_size - 6, box_size - 6, UI_ACCENT)
	}

	// Label
	rl.DrawText(label, l.x + box_size + 8, l.y + 5, 14, UI_TEXT)

	if hovered && rl.IsMouseButtonPressed(.LEFT) {
		value^ = !value^
		changed = true
	}

	l.y += row_h + l.spacing

	return changed
}

// Dropdown - returns true if selection changed
// Supports scrolling when there are more options than max_visible.
ui_dropdown :: proc(label: cstring, options: []cstring, selected: ^int) -> bool {
	l := &ui_layout
	row_h: i32 = 26
	changed := false
	mouse := rl.GetMousePosition()
	is_open := active_dropdown == label

	// Label
	rl.DrawText(label, l.x, l.y, 14, UI_TEXT_DIM)
	l.y += 16

	// Dropdown button
	btn_rect := rl.Rectangle{f32(l.x), f32(l.y), f32(l.w), f32(row_h)}
	btn_hovered := rl.CheckCollisionPointRec(mouse, btn_rect)
	rl.DrawRectangleRec(btn_rect, btn_hovered && !is_open ? UI_WIDGET_HOVER : UI_WIDGET_BG)

	// Current value text
	current_text: cstring = selected^ >= 0 && selected^ < len(options) ? options[selected^] : "---"
	rl.DrawText(current_text, l.x + 8, l.y + 6, 14, UI_TEXT)

	// Arrow
	arrow: cstring = is_open ? "^" : "v"
	rl.DrawText(arrow, l.x + l.w - 18, l.y + 6, 14, UI_TEXT_DIM)

	// Toggle open/close
	if btn_hovered && rl.IsMouseButtonPressed(.LEFT) {
		if is_open {
			active_dropdown = nil
		} else {
			active_dropdown = label
			// Reset scroll, try to keep selected item visible
			max_visible: i32 = 10
			opt_count := i32(len(options))
			if opt_count <= max_visible {
				dropdown_scroll = 0
			} else {
				// Center the selected item in the visible window
				dropdown_scroll = clamp(i32(selected^) - max_visible / 2, 0, opt_count - max_visible)
			}
		}
	}

	l.y += row_h

	// Draw dropdown options if open
	if is_open {
		opt_count := i32(len(options))
		max_visible: i32 = 10
		visible := min(opt_count, max_visible)
		can_scroll := opt_count > max_visible
		max_scroll := opt_count - max_visible

		list_h := visible * row_h

		// Background
		list_rect := rl.Rectangle{f32(l.x), f32(l.y), f32(l.w), f32(list_h)}
		rl.DrawRectangleRec(list_rect, rl.Color{45, 45, 55, 250})

		// Mouse wheel scrolling when hovering the list
		if can_scroll && rl.CheckCollisionPointRec(mouse, list_rect) {
			wheel := rl.GetMouseWheelMove()
			if wheel != 0 {
				dropdown_scroll = clamp(dropdown_scroll - i32(wheel), 0, max_scroll)
			}
		}

		// Draw visible items (offset by scroll)
		for vi in 0 ..< visible {
			item_idx := vi + dropdown_scroll
			opt_y := l.y + vi * row_h
			opt_rect := rl.Rectangle{f32(l.x), f32(opt_y), f32(l.w), f32(row_h)}
			opt_hovered := rl.CheckCollisionPointRec(mouse, opt_rect)

			if i32(selected^) == item_idx {
				rl.DrawRectangleRec(opt_rect, UI_ACCENT)
				rl.DrawText(options[item_idx], l.x + 8, opt_y + 6, 14, rl.Color{20, 20, 25, 255})
			} else {
				if opt_hovered {
					rl.DrawRectangleRec(opt_rect, UI_WIDGET_HOVER)
				}
				rl.DrawText(options[item_idx], l.x + 8, opt_y + 6, 14, UI_TEXT)
			}

			if opt_hovered && rl.IsMouseButtonPressed(.LEFT) {
				selected^ = int(item_idx)
				active_dropdown = nil
				changed = true
			}
		}

		// Scroll indicators
		if can_scroll {
			indicator_color := rl.Color{180, 180, 200, 180}
			if dropdown_scroll > 0 {
				// Up arrow at top-right of list
				rl.DrawText("^", l.x + l.w - 16, l.y + 2, 12, indicator_color)
			}
			if dropdown_scroll < max_scroll {
				// Down arrow at bottom-right of list
				rl.DrawText("v", l.x + l.w - 16, l.y + list_h - 14, 12, indicator_color)
			}
		}

		l.y += list_h
	}

	l.y += l.spacing

	return changed
}

// ---------------------------------------------------------------------------
// Recipe step editor - draws controls for a single step's parameters
// ---------------------------------------------------------------------------

ui_step_params :: proc(step: ^Gen_Step) {
	l := &ui_layout
	// Indent step params
	old_x := l.x
	old_w := l.w
	l.x += 12
	l.w -= 12

	switch step.type {
	case .Seed_Rooms:
		ui_int_stepper("Count", &step.seed_rooms.count, 1, 50, 1)
	case .Grow_Clusters:
		ui_slider("Chance", &step.grow_clusters.chance, 0.0, 1.0)
		ui_int_stepper("Min Rooms", &step.grow_clusters.min_rooms, 0, 20, 1)
		ui_int_stepper("Max Rooms", &step.grow_clusters.max_rooms, 0, 20, 1)
	case .Connect_MST:
		ui_slider("Manhattan", &step.connect_mst.manhattan_weight, 0.0, 1.0)
	case .Mark_Doors:
		ui_label("(no parameters)", UI_TEXT_DIM)
	case .Add_Loops:
		ui_slider("Loop Chance", &step.add_loops.loop_chance, 0.0, 1.0)
		ui_int_stepper("Max Extra", &step.add_loops.max_extra, 1, 20, 1)
		ui_slider("Manhattan", &step.add_loops.manhattan_weight, 0.0, 1.0)
	case .Widen_Corridors:
		ui_int_stepper("Width", &step.widen_corridors.width, 2, 5, 1)
	case .BSP_Partition:
		ui_int_stepper("Min Size", &step.bsp_partition.min_size, 4, 32, 1)
		ui_int_stepper("Padding", &step.bsp_partition.padding, 1, 8, 1)
	case .Fill_Dead_Ends:
		ui_int_stepper("Iterations", &step.fill_dead_ends.iterations, 1, 20, 1)
	case .Place_Grid:
		ui_int_stepper("Columns", &step.place_grid.cols, 1, 10, 1)
		ui_int_stepper("Rows", &step.place_grid.rows, 1, 10, 1)
		ui_slider("Jitter", &step.place_grid.jitter, 0.0, 1.0)
	case .Room_Corridor:
		ui_slider("Strictness", &step.room_corridor.strictness, 0.0, 1.0)
		ui_slider("Manhattan", &step.room_corridor.manhattan_weight, 0.0, 1.0)
		ui_int_stepper("Max Chain", &step.room_corridor.max_chain, 1, 20, 1)
	case .Define_Area:
		ui_int_stepper("Area ID", &step.define_area.area_id, 0, 9, 1)
		// Shape toggle (Rectangle / Circle)
		shape_val := int(step.define_area.shape)
		ui_int_stepper("Shape", &shape_val, 0, 1, 1)
		step.define_area.shape = Area_Shape(shape_val)
		ui_int_stepper("X", &step.define_area.x, 0, 128, 1)
		ui_int_stepper("Y", &step.define_area.y, 0, 128, 1)
		ui_int_stepper("W", &step.define_area.w, 1, 128, 1)
		ui_int_stepper("H", &step.define_area.h, 1, 128, 1)
	case .Pack_Rooms:
		ui_int_stepper("Max Rooms", &step.pack_rooms.max_rooms, 0, 200, 5)
	case .Join_Rooms:
		ui_label("(no parameters)", UI_TEXT_DIM)
	case .Connect_Doors:
		// Mode toggle (All / Minimal) - display text labels
		mode_val := int(step.connect_doors.mode)
		ui_labeled_stepper("Mode", &mode_val, 0, 1, 1, CONNECT_DOORS_MODE_NAMES[step.connect_doors.mode])
		step.connect_doors.mode = Connect_Doors_Mode(mode_val)
		// Max/Pair - show "No limit" when 0
		max_label: cstring = step.connect_doors.max_per_pair == 0 ? "No limit" : fmt.ctprintf("%d", step.connect_doors.max_per_pair)
		ui_labeled_stepper("Max/Pair", &step.connect_doors.max_per_pair, 0, 10, 1, max_label)
	}

	// Area constraint controls (for all steps except Define_Area)
	if step.type != .Define_Area {
		ui_spacer(2)
		// area_id: -1 = none, 0..9 = constrain to area
		ui_int_stepper("Area", &step.area_id, -1, 9, 1)
		if step.area_id >= 0 {
			// Show exclude toggle only when an area is selected
			exclude_val := int(step.area_exclude)
			ui_int_stepper("Exclude", &exclude_val, 0, 1, 1)
			step.area_exclude = exclude_val != 0
		}
	}

	l.x = old_x
	l.w = old_w
}

// ---------------------------------------------------------------------------
// Main draw_ui - builds the side panel
// ---------------------------------------------------------------------------

// Grid size options for dropdown
GRID_SIZE_OPTIONS  := [?]cstring{"32 x 32", "48 x 48", "64 x 64", "96 x 96", "128 x 128"}
GRID_SIZE_VALUES   := [?]int{32, 48, 64, 96, 128}
grid_size_selected: int = 2 // default 64x64

// Step type options for the "Add Step" dropdown
ADD_STEP_OPTIONS := [?]cstring{
	"Seed Rooms", "Grow Clusters", "Connect MST", "Mark Doors",
	"Add Loops", "Widen Corridors", "BSP Partition", "Fill Dead Ends",
	"Place Grid", "Room Corridor", "Define Area", "Pack Rooms",
	"Join Rooms", "Connect Doors",
}
ADD_STEP_TYPES := [?]Step_Type{
	.Seed_Rooms, .Grow_Clusters, .Connect_MST, .Mark_Doors,
	.Add_Loops, .Widen_Corridors, .BSP_Partition, .Fill_Dead_Ends,
	.Place_Grid, .Room_Corridor, .Define_Area, .Pack_Rooms,
	.Join_Rooms, .Connect_Doors,
}

draw_ui :: proc() {
	screen_h := rl.GetScreenHeight()

	// Panel background
	rl.DrawRectangle(0, 0, PANEL_WIDTH, screen_h, UI_BG)
	rl.DrawLine(PANEL_WIDTH, 0, PANEL_WIDTH, screen_h, UI_SEPARATOR)

	// Init layout
	ui_layout = UI_Layout{
		x       = 12,
		y       = 8,
		w       = PANEL_WIDTH - 24,
		padding = 12,
		spacing = 4,
		mouse_on_panel = ui_mouse_on_panel(),
	}

	// Title
	rl.DrawText("Dungeon Generator", ui_layout.x, ui_layout.y, 18, rl.RAYWHITE)
	ui_layout.y += 26

	// ---- Status section ----
	ui_section("Status")

	cam_text: cstring = state.camera_mode == .Top_Down ? "Top-Down" : "Freeflight"
	ui_label_value("Camera", cam_text)

	// Generation status from recipe execution state
	d := &state.dungeon
	gen_text: cstring
	if d.gen_done {
		gen_text = "Done"
	} else if d.current_step < len(d.recipe.steps) {
		step_type := d.recipe.steps[d.current_step].type
		gen_text = STEP_TYPE_NAMES[step_type]
	} else {
		gen_text = "Finishing..."
	}
	ui_label_value("Generation", gen_text)

	ui_label_value("Rooms", fmt.ctprintf("%d", len(d.modules)))
	ui_label_value("Seed", fmt.ctprintf("%d", d.actual_seed), UI_TEXT_DIM)
	ui_label_value("FPS", fmt.ctprintf("%d", rl.GetFPS()), rl.GREEN)

	// ---- Recipe section ----
	ui_section("Recipe")

	// Preset dropdown
	if ui_dropdown("Preset", PRESET_NAMES[:], &preset_selected) {
		recipe_destroy(&d.recipe)
		d.recipe = preset_recipe_by_index(preset_selected)
		// Reset expanded steps
		for i in 0 ..< len(expanded_steps) {
			expanded_steps[i] = false
		}
	}

	// Seed stepper (u64 displayed as int for stepper convenience)
	seed_int := int(d.recipe.seed)
	if ui_int_stepper("Seed (0=rand)", &seed_int, 0, 99999, 1) {
		d.recipe.seed = u64(seed_int)
	}

	ui_separator()

	// Step list
	ui_label("Steps:", UI_TEXT_DIM)

	remove_idx := -1  // index of step to remove (deferred)
	swap_idx   := -1  // index of step to swap with the one below (deferred)

	for si in 0 ..< len(d.recipe.steps) {
		step := &d.recipe.steps[si]
		l := &ui_layout

		// Step row background - highlight if currently executing
		is_active := !d.gen_done && si == d.current_step
		step_bg := is_active ? UI_STEP_ACTIVE : UI_STEP_BG
		row_h: i32 = 22
		rl.DrawRectangle(l.x, l.y, l.w, row_h, step_bg)

		// Step number + type label (colored)
		type_color := STEP_TYPE_COLORS[step.type]
		step_label := fmt.ctprintf("%d. %s", si + 1, STEP_TYPE_NAMES[step.type])
		rl.DrawText(step_label, l.x + 4, l.y + 4, 13, type_color)

		mouse := rl.GetMousePosition()

		// Right-side buttons: [^] [v] [X]
		btn_sz: i32 = 20
		btn_y := l.y + 1

		// Remove button [X]
		remove_x := l.x + l.w - btn_sz - 2
		if ui_small_button(remove_x, btn_y, btn_sz, btn_sz, "X", UI_REMOVE_BG, UI_REMOVE_HOVER) {
			remove_idx = si
		}

		// Move down [v]
		down_x := remove_x - btn_sz - 2
		if si < len(d.recipe.steps) - 1 {
			if ui_small_button(down_x, btn_y, btn_sz, btn_sz, "v", UI_WIDGET_BG, UI_WIDGET_HOVER) {
				swap_idx = si // swap si with si+1
			}
		} else {
			rl.DrawRectangle(down_x, btn_y, btn_sz, btn_sz, UI_STEP_BG)
			rl.DrawText("v", down_x + 5, btn_y + 4, 12, rl.Color{60, 60, 70, 255})
		}

		// Move up [^]
		up_x := down_x - btn_sz - 2
		if si > 0 {
			if ui_small_button(up_x, btn_y, btn_sz, btn_sz, "^", UI_WIDGET_BG, UI_WIDGET_HOVER) {
				swap_idx = si - 1 // swap si-1 with si
			}
		} else {
			rl.DrawRectangle(up_x, btn_y, btn_sz, btn_sz, UI_STEP_BG)
			rl.DrawText("^", up_x + 5, btn_y + 4, 12, rl.Color{60, 60, 70, 255})
		}

		// Expand/collapse toggle - click on the row (excluding the buttons)
		buttons_w: i32 = (btn_sz + 2) * 3
		row_rect := rl.Rectangle{f32(l.x), f32(l.y), f32(l.w - buttons_w), f32(row_h)}
		if rl.CheckCollisionPointRec(mouse, row_rect) && rl.IsMouseButtonPressed(.LEFT) && active_dropdown == nil {
			if si < len(expanded_steps) {
				expanded_steps[si] = !expanded_steps[si]
			}
		}

		l.y += row_h + 2

		// Show params if expanded
		if si < len(expanded_steps) && expanded_steps[si] {
			ui_step_params(step)
		}
	}

	// Deferred step reorder (swap idx with idx+1)
	if swap_idx >= 0 && swap_idx < len(d.recipe.steps) - 1 {
		d.recipe.steps[swap_idx], d.recipe.steps[swap_idx + 1] = d.recipe.steps[swap_idx + 1], d.recipe.steps[swap_idx]
		// Swap expanded state too
		if swap_idx < len(expanded_steps) - 1 {
			expanded_steps[swap_idx], expanded_steps[swap_idx + 1] = expanded_steps[swap_idx + 1], expanded_steps[swap_idx]
		}
	}

	// Deferred step removal
	if remove_idx >= 0 && len(d.recipe.steps) > 0 {
		ordered_remove(&d.recipe.steps, remove_idx)
		// Shift expanded state
		for i in remove_idx ..< len(expanded_steps) - 1 {
			expanded_steps[i] = expanded_steps[i + 1]
		}
		if len(expanded_steps) > 0 {
			expanded_steps[len(expanded_steps) - 1] = false
		}
	}

	// Add step controls
	ui_layout.y += 4

	l := &ui_layout
	// Dropdown + Add button on same row
	add_row_h: i32 = 24
	dropdown_w := l.w - 50
	mouse := rl.GetMousePosition()

	// Mini dropdown for step type
	add_dd_rect := rl.Rectangle{f32(l.x), f32(l.y), f32(dropdown_w), f32(add_row_h)}
	add_dd_hovered := rl.CheckCollisionPointRec(mouse, add_dd_rect)
	is_add_open := active_dropdown == "add_step"

	rl.DrawRectangleRec(add_dd_rect, add_dd_hovered && !is_add_open ? UI_WIDGET_HOVER : UI_WIDGET_BG)
	rl.DrawText(ADD_STEP_OPTIONS[add_step_type_selected], l.x + 6, l.y + 5, 12, UI_TEXT)
	rl.DrawText(is_add_open ? "^" : "v", l.x + dropdown_w - 16, l.y + 5, 12, UI_TEXT_DIM)

	if add_dd_hovered && rl.IsMouseButtonPressed(.LEFT) {
		if is_add_open {
			active_dropdown = nil
		} else {
			active_dropdown = "add_step"
			// Reset scroll, keep selected item visible
			add_opt_count := i32(len(ADD_STEP_OPTIONS))
			add_max_vis: i32 = 10
			if add_opt_count <= add_max_vis {
				dropdown_scroll = 0
			} else {
				dropdown_scroll = clamp(i32(add_step_type_selected) - add_max_vis / 2, 0, add_opt_count - add_max_vis)
			}
		}
	}

	// [Add] button
	add_btn_x := l.x + dropdown_w + 4
	add_btn_w := l.w - dropdown_w - 4
	if ui_small_button(add_btn_x, l.y, add_btn_w, add_row_h, "Add", UI_ACCENT, UI_ACCENT_HOVER) {
		new_step := make_step(ADD_STEP_TYPES[add_step_type_selected])
		// Set sensible defaults
		switch new_step.type {
		case .Seed_Rooms:
			new_step.seed_rooms = {count = 8}
		case .Grow_Clusters:
			new_step.grow_clusters = {chance = 0.4, min_rooms = 1, max_rooms = 4}
		case .Connect_MST:
			new_step.connect_mst = {manhattan_weight = 0.8}
		case .Mark_Doors:
			// no params
		case .Add_Loops:
			new_step.add_loops = {loop_chance = 0.3, max_extra = 4, manhattan_weight = 0.5}
		case .Widen_Corridors:
			new_step.widen_corridors = {width = 3}
		case .BSP_Partition:
			new_step.bsp_partition = {min_size = 8, padding = 2}
		case .Fill_Dead_Ends:
			new_step.fill_dead_ends = {iterations = 3}
		case .Place_Grid:
			new_step.place_grid = {cols = 3, rows = 3, jitter = 0.2}
		case .Room_Corridor:
			new_step.room_corridor = {strictness = 0.5, manhattan_weight = 0.8, max_chain = 6}
		case .Define_Area:
			new_step.define_area = {area_id = 0, shape = .Rectangle, x = 8, y = 8, w = 16, h = 16}
		case .Pack_Rooms:
			new_step.pack_rooms = {max_rooms = 0}
		case .Join_Rooms:
			// no params
		case .Connect_Doors:
			new_step.connect_doors = {mode = .Minimal, max_per_pair = 1}
		}
		append(&d.recipe.steps, new_step)
	}

	l.y += add_row_h

	// Add step type dropdown list (if open) - with scrolling
	if is_add_open {
		opt_h: i32 = 24
		opt_count := i32(len(ADD_STEP_OPTIONS))
		max_visible: i32 = 10
		visible := min(opt_count, max_visible)
		can_scroll := opt_count > max_visible
		max_scroll := opt_count - max_visible
		list_h := visible * opt_h

		// Background
		list_rect := rl.Rectangle{f32(l.x), f32(l.y), f32(dropdown_w), f32(list_h)}
		rl.DrawRectangleRec(list_rect, rl.Color{45, 45, 55, 250})

		// Mouse wheel scrolling
		if can_scroll && rl.CheckCollisionPointRec(mouse, list_rect) {
			wheel := rl.GetMouseWheelMove()
			if wheel != 0 {
				dropdown_scroll = clamp(dropdown_scroll - i32(wheel), 0, max_scroll)
			}
		}

		for vi in 0 ..< visible {
			item_idx := int(vi + dropdown_scroll)
			opt_y := l.y + vi * opt_h
			opt_rect := rl.Rectangle{f32(l.x), f32(opt_y), f32(dropdown_w), f32(opt_h)}
			opt_hovered := rl.CheckCollisionPointRec(mouse, opt_rect)

			if item_idx == add_step_type_selected {
				rl.DrawRectangleRec(opt_rect, UI_ACCENT)
				rl.DrawText(ADD_STEP_OPTIONS[item_idx], l.x + 6, opt_y + 5, 12, rl.Color{20, 20, 25, 255})
			} else {
				rl.DrawRectangleRec(opt_rect, opt_hovered ? UI_WIDGET_HOVER : rl.Color{45, 45, 55, 250})
				rl.DrawText(ADD_STEP_OPTIONS[item_idx], l.x + 6, opt_y + 5, 12, UI_TEXT)
			}

			if opt_hovered && rl.IsMouseButtonPressed(.LEFT) {
				add_step_type_selected = item_idx
				active_dropdown = nil
			}
		}

		// Scroll indicators
		if can_scroll {
			indicator_color := rl.Color{180, 180, 200, 180}
			if dropdown_scroll > 0 {
				rl.DrawText("^", l.x + dropdown_w - 14, l.y + 2, 10, indicator_color)
			}
			if dropdown_scroll < max_scroll {
				rl.DrawText("v", l.x + dropdown_w - 14, l.y + list_h - 12, 10, indicator_color)
			}
		}

		l.y += list_h
	}

	l.y += l.spacing

	// ---- Display settings ----
	ui_section("Display")

	// Grid size dropdown
	if ui_dropdown("Grid Size", GRID_SIZE_OPTIONS[:], &grid_size_selected) {
		new_size := GRID_SIZE_VALUES[grid_size_selected]
		if new_size != d.config.grid_width {
			// Save config before destroying, since d points into state.dungeon
			new_config := d.config
			new_config.grid_width = new_size
			new_config.grid_height = new_size
			dungeon_destroy(d)
			state.dungeon = dungeon_create(new_config)
			d = &state.dungeon
			d.recipe = preset_recipe_by_index(preset_selected)
			state.topdown_camera = topdown_camera_create(d.config)
			state.freeflight_cam = freeflight_camera_create(d.config)
			dungeon_generate_full(d)
		}
	}

	ui_slider("Wall Height", &d.config.wall_height, 0.5, 4.0)

	ui_toggle("Show Ceilings", &show_ceilings)

	ui_toggle("Join Rooms", &join_rooms)

	ui_slider("Anim Speed", &gen_step_interval, 0.01, 0.3, "%.2fs")

	ui_toggle("Animated Mode", &state.gen_animated)

	ui_separator()

	// ---- Actions ----
	ui_section("Actions")

	if ui_button("Generate (Instant)", accent = true) {
		dungeon_generate_full(d)
	}

	if ui_button("Generate (Animated)") {
		dungeon_start_generation(d)
		state.gen_animated = true
		state.gen_step_timer = 0
	}

	if ui_button("Step") {
		if d.gen_done {
			dungeon_start_generation(d)
			state.gen_step_timer = 0
		}
		dungeon_generate_step(d)
	}

	if ui_button("Reset") {
		dungeon_reset(d)
		d.gen_done = true
	}

	// ---- Controls help ----
	ui_section("Controls")
	ui_label("[Tab]   Toggle camera", UI_TEXT_DIM)
	ui_label("[R]     Regenerate", UI_TEXT_DIM)
	ui_label("[Space] Step generation", UI_TEXT_DIM)
	ui_label("[H]     Toggle panel", UI_TEXT_DIM)
	ui_label("[G]     Toggle animated", UI_TEXT_DIM)

	// Close dropdown if clicked outside panel
	if active_dropdown != nil && rl.IsMouseButtonPressed(.LEFT) && !ui_mouse_on_panel() {
		active_dropdown = nil
	}
}

// Expose gen_step_interval for the slider to work
gen_step_interval: f32 = 0.05

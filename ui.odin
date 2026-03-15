package dungeon_generator

import rl "vendor:raylib"
import "core:fmt"
import "core:c"

import imgui "libs/odin-imgui"

// ---------------------------------------------------------------------------
// Side panel constants
// ---------------------------------------------------------------------------

PANEL_WIDTH :: 280

// Check if mouse is over the side panel (kept for camera.odin compatibility)
ui_mouse_on_panel :: proc() -> bool {
	return rl.GetMouseX() < PANEL_WIDTH
}

// Recipe editor state
preset_selected: int = 0
add_step_type_selected: int = 0

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

rl_color_to_vec4 :: proc(col: rl.Color) -> imgui.Vec4 {
	return {f32(col.r) / 255.0, f32(col.g) / 255.0, f32(col.b) / 255.0, f32(col.a) / 255.0}
}

// DragInt wrapper: bridges Odin int <-> imgui c.int, with clamping.
ui_drag_int :: proc(label: cstring, v: ^int, min_val, max_val: int) -> bool {
	tmp := c.int(v^)
	if imgui.DragInt(label, &tmp, 1.0, c.int(min_val), c.int(max_val)) {
		v^ = int(tmp)
		return true
	}
	return false
}

// Step type options (parallel arrays for the "Add Step" combo)
ADD_STEP_OPTIONS := [?]cstring{
	"Seed Rooms", "Grow Clusters", "Connect MST", "Mark Doors",
	"Add Loops", "Widen Corridors", "BSP Partition", "Fill Dead Ends",
	"Place Grid", "Room Corridor", "Define Area", "Pack Rooms",
	"Join Rooms", "Connect Doors", "Place Specific", "Mirror Rooms",
	"Place Symmetric", "Place Perimeter", "Place Along Line",
	"Fill Area", "Wall Border", "Connect Linear",
}
ADD_STEP_TYPES := [?]Step_Type{
	.Seed_Rooms, .Grow_Clusters, .Connect_MST, .Mark_Doors,
	.Add_Loops, .Widen_Corridors, .BSP_Partition, .Fill_Dead_Ends,
	.Place_Grid, .Room_Corridor, .Define_Area, .Pack_Rooms,
	.Join_Rooms, .Connect_Doors, .Place_Specific, .Mirror_Rooms,
	.Place_Symmetric, .Place_Perimeter, .Place_Along_Line,
	.Fill_Area, .Wall_Border, .Connect_Linear,
}

// Grid size options
GRID_SIZE_OPTIONS  := [?]cstring{"32 x 32", "48 x 48", "64 x 64", "96 x 96", "128 x 128"}
GRID_SIZE_VALUES   := [?]int{32, 48, 64, 96, 128}
grid_size_selected: int = 2

// Step type colors for visual distinction
STEP_TYPE_COLORS := [Step_Type]rl.Color{
	.Seed_Rooms      = {100, 200, 120, 255},
	.Grow_Clusters   = {200, 180, 80, 255},
	.Connect_MST     = {100, 160, 255, 255},
	.Mark_Doors      = {200, 130, 200, 255},
	.Add_Loops       = {120, 200, 255, 255},
	.Widen_Corridors = {255, 160, 80, 255},
	.BSP_Partition   = {80, 220, 180, 255},
	.Fill_Dead_Ends  = {220, 100, 100, 255},
	.Place_Grid      = {180, 220, 100, 255},
	.Room_Corridor   = {255, 200, 150, 255},
	.Define_Area     = {200, 200, 255, 255},
	.Pack_Rooms      = {160, 255, 180, 255},
	.Join_Rooms      = {255, 220, 180, 255},
	.Connect_Doors   = {255, 180, 220, 255},
	.Place_Specific  = {255, 140, 100, 255},
	.Mirror_Rooms    = {200, 160, 255, 255},
	.Place_Symmetric = {180, 255, 220, 255},
	.Place_Perimeter  = {255, 200, 100, 255},
	.Place_Along_Line = {100, 220, 180, 255},
	.Fill_Area        = {180, 160, 120, 255},
	.Wall_Border      = {140, 130, 110, 255},
	.Connect_Linear   = {120, 180, 255, 255},
}

// ---------------------------------------------------------------------------
// Step parameters editor
// ---------------------------------------------------------------------------

ui_step_params :: proc(step: ^Gen_Step) {
	switch step.type {
	case .Seed_Rooms:
		ui_drag_int("Count", &step.seed_rooms.count, 1, 50)
	case .Grow_Clusters:
		imgui.SliderFloat("Chance", &step.grow_clusters.chance, 0.0, 1.0)
		ui_drag_int("Min Rooms", &step.grow_clusters.min_rooms, 0, 20)
		ui_drag_int("Max Rooms", &step.grow_clusters.max_rooms, 0, 20)
	case .Connect_MST:
		imgui.SliderFloat("Manhattan", &step.connect_mst.manhattan_weight, 0.0, 1.0)
	case .Mark_Doors:
		imgui.TextColored({0.5, 0.5, 0.6, 1.0}, "(no parameters)")
	case .Add_Loops:
		imgui.SliderFloat("Loop Chance", &step.add_loops.loop_chance, 0.0, 1.0)
		ui_drag_int("Max Extra", &step.add_loops.max_extra, 1, 20)
		imgui.SliderFloat("Manhattan", &step.add_loops.manhattan_weight, 0.0, 1.0)
	case .Widen_Corridors:
		ui_drag_int("Width", &step.widen_corridors.width, 2, 5)
	case .BSP_Partition:
		ui_drag_int("Min Size", &step.bsp_partition.min_size, 4, 32)
		ui_drag_int("Padding", &step.bsp_partition.padding, 1, 8)
	case .Fill_Dead_Ends:
		ui_drag_int("Iterations", &step.fill_dead_ends.iterations, 1, 20)
	case .Place_Grid:
		ui_drag_int("Columns", &step.place_grid.cols, 1, 10)
		ui_drag_int("Rows", &step.place_grid.rows, 1, 10)
		imgui.SliderFloat("Jitter", &step.place_grid.jitter, 0.0, 1.0)
	case .Room_Corridor:
		imgui.SliderFloat("Strictness", &step.room_corridor.strictness, 0.0, 1.0)
		imgui.SliderFloat("Manhattan", &step.room_corridor.manhattan_weight, 0.0, 1.0)
		ui_drag_int("Max Chain", &step.room_corridor.max_chain, 1, 20)
	case .Define_Area:
		ui_drag_int("Area ID", &step.define_area.area_id, 0, 9)
		shape_val := c.int(step.define_area.shape)
		if imgui.Combo("Shape", &shape_val, "Rectangle\x00Circle\x00\x00") {
			step.define_area.shape = Area_Shape(shape_val)
		}
		ui_drag_int("X", &step.define_area.x, 0, 128)
		ui_drag_int("Y", &step.define_area.y, 0, 128)
		ui_drag_int("W", &step.define_area.w, 1, 128)
		ui_drag_int("H", &step.define_area.h, 1, 128)
	case .Pack_Rooms:
		ui_drag_int("Max Rooms", &step.pack_rooms.max_rooms, 0, 200)
	case .Join_Rooms:
		imgui.TextColored({0.5, 0.5, 0.6, 1.0}, "(no parameters)")
	case .Connect_Doors:
		mode_val := c.int(step.connect_doors.mode)
		if imgui.Combo("Mode", &mode_val, "All\x00Minimal\x00\x00") {
			step.connect_doors.mode = Connect_Doors_Mode(mode_val)
		}
		ui_drag_int("Max/Pair", &step.connect_doors.max_per_pair, 0, 10)
	case .Place_Specific:
		tmpl_idx := clamp(step.place_specific.template_index, 0, len(MODULE_TEMPLATES) - 1)
		tmpl_val := c.int(tmpl_idx)
		if imgui.Combo("Template", &tmpl_val, "Small Room\x00Large Room\x00Long Hall\x00L-Shape\x00Cross\x00Grand Hall\x00Throne Room\x00\x00") {
			step.place_specific.template_index = int(tmpl_val)
		}
		ui_drag_int("X", &step.place_specific.x, 0, 128)
		ui_drag_int("Y", &step.place_specific.y, 0, 128)
		rot_val := c.int(step.place_specific.rotation)
		if imgui.Combo("Rotation", &rot_val, "0 deg\x0090 deg\x00180 deg\x00270 deg\x00\x00") {
			step.place_specific.rotation = int(rot_val)
		}
	case .Mirror_Rooms:
		axis_val := c.int(step.mirror_rooms.axis)
		if imgui.Combo("Axis", &axis_val, "X (L/R)\x00Y (T/B)\x00\x00") {
			step.mirror_rooms.axis = Mirror_Axis(axis_val)
		}
		ui_drag_int("Axis Pos", &step.mirror_rooms.axis_pos, 0, 128)
	case .Place_Symmetric:
		sym_val := c.int(step.place_symmetric.symmetry)
		if imgui.Combo("Symmetry", &sym_val, "Mirror X\x00Mirror Y\x00Mirror XY\x00Rotate 4\x00\x00") {
			step.place_symmetric.symmetry = Symmetry_Mode(sym_val)
		}
		ui_drag_int("Axis X", &step.place_symmetric.axis_x, 0, 128)
		ui_drag_int("Axis Y", &step.place_symmetric.axis_y, 0, 128)
		ui_drag_int("Max Rooms", &step.place_symmetric.max_rooms, 0, 200)
	case .Place_Perimeter:
		imgui.SliderFloat("Gap Chance", &step.place_perimeter.gap_chance, 0.0, 0.5)
		ui_drag_int("Max Rooms", &step.place_perimeter.max_rooms, 0, 200)
	case .Place_Along_Line:
		ui_drag_int("X1", &step.place_along_line.x1, 0, 128)
		ui_drag_int("Y1", &step.place_along_line.y1, 0, 128)
		ui_drag_int("X2", &step.place_along_line.x2, 0, 128)
		ui_drag_int("Y2", &step.place_along_line.y2, 0, 128)
		side_val := c.int(step.place_along_line.door_side)
		if imgui.Combo("Door Side", &side_val, "Left\x00Right\x00Both\x00\x00") {
			step.place_along_line.door_side = int(side_val)
		}
		ui_drag_int("Spacing", &step.place_along_line.spacing, 0, 10)
	case .Fill_Area:
		ui_drag_int("Red", &step.fill_area.color_r, 0, 255)
		ui_drag_int("Green", &step.fill_area.color_g, 0, 255)
		ui_drag_int("Blue", &step.fill_area.color_b, 0, 255)
	case .Wall_Border:
		ui_drag_int("Thickness", &step.wall_border.thickness, 1, 5)
	case .Connect_Linear:
		imgui.SliderFloat("Manhattan", &step.connect_linear.manhattan_weight, 0.0, 1.0)
	}

	// Area constraint (for all steps except Define_Area)
	if step.type != .Define_Area {
		imgui.Spacing()
		ui_drag_int("Area", &step.area_id, -1, 9)
		if step.area_id >= 0 {
			imgui.Checkbox("Exclude", &step.area_exclude)
		}
	}
}

// ---------------------------------------------------------------------------
// Main draw_ui
// ---------------------------------------------------------------------------

draw_ui :: proc() {
	screen_h := f32(rl.GetScreenHeight())
	d := &state.dungeon

	imgui.SetNextWindowPos({0, 0})
	imgui.SetNextWindowSize({f32(PANEL_WIDTH), screen_h})
	if !imgui.Begin("Dungeon Generator", nil, {.NoMove, .NoResize, .NoCollapse, .NoBringToFrontOnFocus}) {
		imgui.End()
		return
	}
	defer imgui.End()

	// ---- Status (always visible) ----
	cam_text: cstring = state.camera_mode == .Top_Down ? "Top-Down" : "Freeflight"
	imgui.Text("Camera:     %s", cam_text)

	gen_text: cstring
	if d.gen_done {
		gen_text = "Done"
	} else if d.current_step < len(d.recipe.steps) {
		gen_text = STEP_TYPE_NAMES[d.recipe.steps[d.current_step].type]
	} else {
		gen_text = "Finishing..."
	}
	imgui.Text("Generation: %s", gen_text)
	imgui.Text("Rooms: %d  Seed: %d  FPS: %d", len(d.modules), d.actual_seed, rl.GetFPS())

	imgui.Spacing()

	// ---- Actions (always visible) ----
	half_width := (imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x) * 0.5
	if imgui.Button("Generate", {half_width, 0}) {
		dungeon_generate_full(d)
	}
	imgui.SameLine()
	if imgui.Button("Animated", {half_width, 0}) {
		dungeon_start_generation(d)
		state.gen_animated = true
		state.gen_step_timer = 0
	}
	if imgui.Button("Step", {half_width, 0}) {
		if d.gen_done {
			dungeon_start_generation(d)
			state.gen_step_timer = 0
		}
		dungeon_generate_step(d)
	}
	imgui.SameLine()
	if imgui.Button("Reset", {half_width, 0}) {
		dungeon_reset(d)
		d.gen_done = true
	}

	imgui.Separator()

	// ---- Tabbed sections ----
	if imgui.BeginTabBar("##main_tabs", {.FittingPolicyResizeDown}) {

		// ---- Recipe tab ----
		if imgui.BeginTabItem("Recipe") {
			if imgui.BeginCombo("Preset", PRESET_NAMES[preset_selected]) {
				for i in 0 ..< len(PRESET_NAMES) {
					is_sel := i == preset_selected
					if imgui.Selectable(PRESET_NAMES[i], is_sel) {
						preset_selected = i
						recipe_destroy(&d.recipe)
						d.recipe = preset_recipe_by_index(preset_selected)
					}
					if is_sel do imgui.SetItemDefaultFocus()
				}
				imgui.EndCombo()
			}

			seed_int := c.int(d.recipe.seed)
			if imgui.DragInt("Seed (0=rand)", &seed_int, 1.0, 0, 99999) {
				d.recipe.seed = u64(seed_int)
			}

			imgui.Separator()
			imgui.Text("Steps:")

			remove_idx := -1
			swap_idx := -1

			for si in 0 ..< len(d.recipe.steps) {
				step := &d.recipe.steps[si]
				imgui.PushIDInt(c.int(si))

				is_active := !d.gen_done && si == d.current_step
				type_color := rl_color_to_vec4(STEP_TYPE_COLORS[step.type])
				label := fmt.ctprintf("%d. %s", si + 1, STEP_TYPE_NAMES[step.type])

				flags: imgui.TreeNodeFlags = {.OpenOnArrow, .SpanAvailWidth}
				if is_active do flags |= {.Selected}

				imgui.PushStyleColorImVec4(.Text, type_color)
				is_open := imgui.TreeNodeEx(label, flags)
				imgui.PopStyleColor()

				imgui.SameLine(imgui.GetWindowWidth() - 75)
				if si > 0 {
					if imgui.SmallButton("^") do swap_idx = si - 1
				} else {
					imgui.SmallButton("^")
				}
				imgui.SameLine()
				if si < len(d.recipe.steps) - 1 {
					if imgui.SmallButton("v") do swap_idx = si
				} else {
					imgui.SmallButton("v")
				}
				imgui.SameLine()
				if imgui.SmallButton("X") do remove_idx = si

				if is_open {
					ui_step_params(step)
					imgui.TreePop()
				}

				imgui.PopID()
			}

			if swap_idx >= 0 && swap_idx < len(d.recipe.steps) - 1 {
				d.recipe.steps[swap_idx], d.recipe.steps[swap_idx + 1] = d.recipe.steps[swap_idx + 1], d.recipe.steps[swap_idx]
			}

			if remove_idx >= 0 && len(d.recipe.steps) > 0 {
				ordered_remove(&d.recipe.steps, remove_idx)
			}

			imgui.Spacing()

			imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x - 40)
			if imgui.BeginCombo("##add_type", ADD_STEP_OPTIONS[add_step_type_selected]) {
				for i in 0 ..< len(ADD_STEP_OPTIONS) {
					is_sel := i == add_step_type_selected
					if imgui.Selectable(ADD_STEP_OPTIONS[i], is_sel) {
						add_step_type_selected = i
					}
					if is_sel do imgui.SetItemDefaultFocus()
				}
				imgui.EndCombo()
			}
			imgui.SameLine()
			if imgui.Button("Add") {
				new_step := make_step(ADD_STEP_TYPES[add_step_type_selected])
				switch new_step.type {
				case .Seed_Rooms:
					new_step.seed_rooms = {count = 8}
				case .Grow_Clusters:
					new_step.grow_clusters = {chance = 0.4, min_rooms = 1, max_rooms = 4}
				case .Connect_MST:
					new_step.connect_mst = {manhattan_weight = 0.8}
				case .Mark_Doors:
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
				case .Connect_Doors:
					new_step.connect_doors = {mode = .Minimal, max_per_pair = 1}
				case .Place_Specific:
					new_step.place_specific = {template_index = 1, x = 30, y = 30, rotation = 0}
				case .Mirror_Rooms:
					new_step.mirror_rooms = {axis = .X, axis_pos = 0}
				case .Place_Symmetric:
					new_step.place_symmetric = {symmetry = .Mirror_X, axis_x = 0, axis_y = 0, max_rooms = 30}
				case .Place_Perimeter:
					new_step.place_perimeter = {gap_chance = 0.05, max_rooms = 0}
				case .Place_Along_Line:
					new_step.place_along_line = {x1 = 10, y1 = 32, x2 = 54, y2 = 32, door_side = 1, spacing = 0}
				case .Fill_Area:
					new_step.fill_area = {color_r = 120, color_g = 100, color_b = 70}
				case .Wall_Border:
					new_step.wall_border = {thickness = 2}
				case .Connect_Linear:
					new_step.connect_linear = {manhattan_weight = 0.8}
				}
				append(&d.recipe.steps, new_step)
			}

			imgui.EndTabItem()
		}

		// ---- Display tab ----
		if imgui.BeginTabItem("Display") {
			if imgui.BeginCombo("Grid Size", GRID_SIZE_OPTIONS[grid_size_selected]) {
				for i in 0 ..< len(GRID_SIZE_OPTIONS) {
					is_sel := i == grid_size_selected
					if imgui.Selectable(GRID_SIZE_OPTIONS[i], is_sel) {
						grid_size_selected = i
						new_size := GRID_SIZE_VALUES[grid_size_selected]
						if new_size != d.config.grid_width {
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
					if is_sel do imgui.SetItemDefaultFocus()
				}
				imgui.EndCombo()
			}

			imgui.SliderFloat("Wall Height", &d.config.wall_height, 0.5, 4.0)
			imgui.Checkbox("Show Ceilings", &show_ceilings)
			imgui.Checkbox("Join Rooms", &join_rooms)
			imgui.Separator()
			imgui.SliderFloat("Anim Speed", &gen_step_interval, 0.01, 0.3, "%.2fs")
			imgui.Checkbox("Animated Mode", &state.gen_animated)

			imgui.EndTabItem()
		}

		// ---- Controls tab ----
		if imgui.BeginTabItem("Keys") {
			imgui.TextColored({0.5, 0.5, 0.6, 1.0}, "[Tab]   Toggle camera")
			imgui.TextColored({0.5, 0.5, 0.6, 1.0}, "[R]     Regenerate")
			imgui.TextColored({0.5, 0.5, 0.6, 1.0}, "[Space] Step generation")
			imgui.TextColored({0.5, 0.5, 0.6, 1.0}, "[H]     Toggle panel")
			imgui.TextColored({0.5, 0.5, 0.6, 1.0}, "[G]     Toggle animated")

			imgui.EndTabItem()
		}

		imgui.EndTabBar()
	}
}

// Expose gen_step_interval for the slider to work
gen_step_interval: f32 = 0.05

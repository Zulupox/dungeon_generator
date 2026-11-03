package dungeon_generator

import rl "vendor:raylib"
import "core:fmt"
import "core:c"
import "core:os"
import "core:strings"

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

// File save/load state
save_name_buf: [128]c.char
save_status_msg: cstring = nil
save_status_timer: f32 = 0
saved_file_list: []string
saved_file_list_dirty: bool = true
load_selected: int = -1

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
	"Fill Area", "Wall Border", "Connect Linear", "Room Graph", "Place Graph",
	"Define Palette", "Connect Groups",
}
ADD_STEP_TYPES := [?]Step_Type{
	.Seed_Rooms, .Grow_Clusters, .Connect_MST, .Mark_Doors,
	.Add_Loops, .Widen_Corridors, .BSP_Partition, .Fill_Dead_Ends,
	.Place_Grid, .Room_Corridor, .Define_Area, .Pack_Rooms,
	.Join_Rooms, .Connect_Doors, .Place_Specific, .Mirror_Rooms,
	.Place_Symmetric, .Place_Perimeter, .Place_Along_Line,
	.Fill_Area, .Wall_Border, .Connect_Linear, .Room_Graph, .Place_Graph,
	.Define_Palette, .Connect_Groups,
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
	.Room_Graph       = {255, 230, 120, 255},
	.Place_Graph      = {255, 200, 90, 255},
	.Define_Palette   = {220, 200, 140, 255},
	.Connect_Groups   = {140, 220, 255, 255},
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
		tmpl_idx := clamp(step.place_specific.template_index, 0, len(module_templates) - 1)
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
		if imgui.Combo("Symmetry", &sym_val, "Mirror X\x00Mirror Y\x00Mirror XY\x00Rotate 4\x00Rotate 2\x00Mirror Diagonal\x00\x00") {
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
	case .Connect_Groups:
		imgui.SliderFloat("Manhattan", &step.connect_groups.manhattan_weight, 0.0, 1.0)
	case .Connect_Linear:
		imgui.SliderFloat("Manhattan", &step.connect_linear.manhattan_weight, 0.0, 1.0)
	case .Room_Graph:
		ui_room_graph_params(&step.room_graph)
	case .Place_Graph:
		imgui.SliderFloat("Manhattan", &step.place_graph.manhattan_weight, 0.0, 1.0)
		imgui.Checkbox("Corridor fallback", &step.place_graph.corridor_fallback)
		imgui.Checkbox("Loop corridors", &step.place_graph.loop_corridors)
		ui_drag_int("Retries", &step.place_graph.retries, 1, 50)
	case .Define_Palette:
		imgui.Checkbox("Use Defaults", &step.define_palette.use_defaults)
		if step.define_palette.use_defaults {
			imgui.TextColored({0.5, 0.7, 0.5, 1.0}, "Castle adjacency rules")
		}
		imgui.Separator()
		imgui.Text("Quotas:")
		ui_drag_int("Num Quotas", &step.define_palette.num_quotas, 0, 16)
		for qi in 0 ..< step.define_palette.num_quotas {
			imgui.PushIDInt(c.int(qi))
			rt_val := c.int(step.define_palette.quota_types[qi])
			if imgui.Combo("Type", &rt_val,
				"Generic\x00Throne_Room\x00Great_Hall\x00Barracks\x00Armory\x00Kitchen\x00Dining_Hall\x00Bedroom\x00Treasury\x00Guard_Room\x00Chapel\x00Library\x00Storage\x00Courtyard\x00Gatehouse\x00Corridor\x00\x00") {
				step.define_palette.quota_types[qi] = Room_Type(rt_val)
			}
			ui_drag_int("Max", &step.define_palette.quota_max_counts[qi], 0, 50)
			imgui.SliderFloat("Weight", &step.define_palette.quota_weights[qi], 0.0, 5.0)
			imgui.PopID()
		}
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

	if state.editor.active {
		editor_draw_panel()
		return
	}

	// ---- Status (always visible) ----
	cam_text: cstring = state.camera_mode == .Top_Down ? "Top-Down" : "Freeflight"
	imgui.Text("Camera:     %s", cam_text)

	gen_text: cstring
	if d.showcase {
		gen_text = "Module showcase"
	} else if d.gen_done {
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
	if imgui.Button("Modules", {half_width, 0}) {
		dungeon_show_modules(d)
		select_modules_tab = true
	}
	imgui.SameLine()
	if imgui.Button("Editor", {half_width, 0}) {
		editor_enter()
	}
	if imgui.IsItemHovered() do imgui.SetTooltip("Edit room templates")

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
			is_canvas_sel := si == state.canvas.scroll_to_step
			type_color := rl_color_to_vec4(STEP_TYPE_COLORS[step.type])
			if step.muted do type_color = {0.4, 0.4, 0.4, 0.5}
			label := fmt.ctprintf("%d. %s", si + 1, STEP_TYPE_NAMES[step.type])

			if is_canvas_sel {
				imgui.SetNextItemOpen(true)
			}

			flags: imgui.TreeNodeFlags = {.OpenOnArrow, .SpanAvailWidth, .AllowOverlap}
			if is_active || is_canvas_sel do flags |= {.Selected}

			imgui.PushStyleColorImVec4(.Text, type_color)
			is_open := imgui.TreeNodeEx(label, flags)
			imgui.PopStyleColor()

			if is_canvas_sel {
				imgui.SetScrollHereY(0.5)
				state.canvas.scroll_to_step = -1
			}

			imgui.SameLine(imgui.GetWindowWidth() - 90)
			was_muted := step.muted
			if was_muted {
				imgui.PushStyleColorImVec4(.Button, {0.6, 0.35, 0.1, 1.0})
				imgui.PushStyleColorImVec4(.ButtonHovered, {0.7, 0.4, 0.15, 1.0})
				imgui.PushStyleColorImVec4(.ButtonActive, {0.5, 0.3, 0.1, 1.0})
			}
			if imgui.SmallButton("M") do step.muted = !step.muted
			if was_muted do imgui.PopStyleColor(3)
			imgui.SameLine()
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
				case .Connect_Groups:
					new_step.connect_groups = {manhattan_weight = 0.8}
				case .Connect_Linear:
					new_step.connect_linear = {manhattan_weight = 0.8}
				case .Room_Graph:
					if len(room_profiles) > 0 do new_step.room_graph.profile = room_profiles[0].name
				case .Place_Graph:
					new_step.place_graph = DEFAULT_PLACE_GRAPH
				case .Define_Palette:
					new_step.define_palette = {use_defaults = true}
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
			imgui.Checkbox("Merge Room Walls", &merge_room_walls)
			if imgui.IsItemHovered() do imgui.SetTooltip("Hide walls between touching rooms.\nDisplay only; the Join Rooms step merges rooms for real.")
			imgui.Separator()
			imgui.SliderFloat("Anim Speed", &gen_step_interval, 0.01, 0.3, "%.2fs")
			imgui.Checkbox("Animated Mode", &state.gen_animated)

			imgui.EndTabItem()
		}

		// ---- Modules tab ----
		modules_tab_flags: imgui.TabItemFlags = select_modules_tab ? {.SetSelected} : {}
		select_modules_tab = false
		if imgui.BeginTabItem("Modules", nil, modules_tab_flags) {
			ui_module_table()
			imgui.EndTabItem()
		}

		// ---- Graph tab ----
		if imgui.BeginTabItem("Graph") {
			ui_graph_tab(d)
			imgui.EndTabItem()
		}

		// ---- Stats tab ----
		if imgui.BeginTabItem("Stats") {
			ui_stats_tab(d)
			imgui.EndTabItem()
		}

		// ---- Files tab (save/load recipes) ----
		if imgui.BeginTabItem("Files") {
			ui_files_tab(d)
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

// ---------------------------------------------------------------------------
// Files tab - save/load recipes to disk
// ---------------------------------------------------------------------------

ui_files_tab :: proc(d: ^Dungeon) {
	avail_w := imgui.GetContentRegionAvail().x

	// ---- Save section ----
	imgui.TextColored({0.8, 0.9, 1.0, 1.0}, "Save Recipe")
	imgui.Separator()

	imgui.SetNextItemWidth(avail_w - 55)
	imgui.InputTextWithHint("##save_name", "filename", cstring(&save_name_buf[0]), c.size_t(len(save_name_buf)))

	imgui.SameLine()
	if imgui.Button("Save", {50, 0}) {
		name_str := string(cstring(&save_name_buf[0]))
		if len(name_str) > 0 {
			// Append .json if not already present
			filename: string
			if strings.has_suffix(name_str, ".json") {
				filename = name_str
			} else {
				filename = fmt.tprintf("%s.json", name_str)
			}
			filepath := fmt.tprintf("%s/%s", RECIPES_DIR, filename)

			// Save with actual_seed so reloading reproduces the same dungeon
			saved_seed := d.recipe.seed
			if d.actual_seed != 0 {
				d.recipe.seed = d.actual_seed
			}

			if recipe_save(&d.recipe, filepath) {
				save_status_msg = "Saved!"
				save_status_timer = 2.0
				saved_file_list_dirty = true
			} else {
				save_status_msg = "Save failed!"
				save_status_timer = 3.0
			}

			d.recipe.seed = saved_seed
		} else {
			save_status_msg = "Enter a filename"
			save_status_timer = 2.0
		}
	}

	// Status message with fade
	if save_status_timer > 0 {
		alpha := min(save_status_timer, 1.0)
		is_error := save_status_msg == "Save failed!" || save_status_msg == "Enter a filename"
		col := imgui.Vec4{0.3, 1.0, 0.3, alpha} if !is_error else imgui.Vec4{1.0, 0.4, 0.3, alpha}
		imgui.TextColored(col, save_status_msg)
		save_status_timer -= rl.GetFrameTime()
	}

	imgui.Spacing()
	imgui.Spacing()

	// ---- Load section ----
	imgui.TextColored({0.8, 0.9, 1.0, 1.0}, "Load Recipe")
	imgui.Separator()

	// Refresh file list when needed
	if saved_file_list_dirty {
		// Free old list
		for s in saved_file_list {
			delete(s)
		}
		delete(saved_file_list)
		saved_file_list = recipes_list_files()
		saved_file_list_dirty = false
		load_selected = -1
	}

	if imgui.SmallButton("Refresh") {
		saved_file_list_dirty = true
	}

	if len(saved_file_list) == 0 {
		imgui.TextColored({0.5, 0.5, 0.6, 1.0}, "No saved recipes found.")
		imgui.TextColored({0.5, 0.5, 0.6, 1.0}, fmt.ctprintf("(%s/)", RECIPES_DIR))
	} else {
		// File list box
		list_height := min(f32(len(saved_file_list)) * imgui.GetTextLineHeightWithSpacing() + 8, 200.0)
		if imgui.BeginListBox("##file_list", {avail_w, list_height}) {
			for i in 0 ..< len(saved_file_list) {
				is_sel := i == load_selected
				label := fmt.ctprintf("%s", saved_file_list[i])
				if imgui.Selectable(label, is_sel) {
					load_selected = i
				}
			}
			imgui.EndListBox()
		}

		btn_w := (avail_w - 8) / 2

		has_selection := load_selected >= 0 && load_selected < len(saved_file_list)

		if !has_selection { imgui.BeginDisabled() }
		if imgui.Button("Load", {btn_w, 0}) && has_selection {
			filepath := fmt.tprintf("%s/%s", RECIPES_DIR, saved_file_list[load_selected])
			loaded, ok := recipe_load(filepath)
			if ok {
				recipe_destroy(&d.recipe)
				d.recipe = loaded
				save_status_msg = "Loaded!"
				save_status_timer = 2.0
			} else {
				save_status_msg = "Load failed!"
				save_status_timer = 3.0
			}
		}
		if !has_selection { imgui.EndDisabled() }

		imgui.SameLine()

		if !has_selection { imgui.BeginDisabled() }
		// Delete button with confirmation color
		imgui.PushStyleColorImVec4(.Button, {0.6, 0.15, 0.15, 1.0})
		imgui.PushStyleColorImVec4(.ButtonHovered, {0.8, 0.2, 0.2, 1.0})
		imgui.PushStyleColorImVec4(.ButtonActive, {0.5, 0.1, 0.1, 1.0})
		if imgui.Button("Delete", {btn_w, 0}) && has_selection {
			filepath := fmt.tprintf("%s/%s", RECIPES_DIR, saved_file_list[load_selected])
			os.remove(filepath)
			saved_file_list_dirty = true
			save_status_msg = "Deleted."
			save_status_timer = 2.0
		}
		imgui.PopStyleColor(3)
		if !has_selection { imgui.EndDisabled() }
	}
}

// Expose gen_step_interval for the slider to work
gen_step_interval: f32 = 0.05

// One-shot request to switch to the Modules tab (set by the Modules button)
select_modules_tab: bool = false

// ---------------------------------------------------------------------------
// Module info
// ---------------------------------------------------------------------------

color4_to_vec4 :: proc(col: Color4) -> imgui.Vec4 {
	return {f32(col[0]) / 255.0, f32(col[1]) / 255.0, f32(col[2]) / 255.0, f32(col[3]) / 255.0}
}

// Table of all module templates with their stats. Hover a row for door directions.
ui_module_table :: proc() {
	table_flags := imgui.TableFlags_RowBg | imgui.TableFlags_BordersInnerH | imgui.TableFlags_SizingFixedFit
	if !imgui.BeginTable("##modules", 4, table_flags) do return
	defer imgui.EndTable()

	imgui.TableSetupColumn("Name", {.WidthStretch})
	imgui.TableSetupColumn("Size")
	imgui.TableSetupColumn("Cells")
	imgui.TableSetupColumn("Doors")
	imgui.TableHeadersRow()

	for &tmpl, i in module_templates {
		imgui.PushIDInt(c.int(i))
		imgui.TableNextRow()

		imgui.TableNextColumn()
		imgui.ColorButton("##col", color4_to_vec4(tmpl.color), {.NoTooltip}, {12, 12})
		imgui.SameLine()
		imgui.Text("%d. %s", c.int(i), fmt.ctprintf("%s", tmpl.name))
		if imgui.IsItemHovered() {
			doors := template_door_counts(&tmpl)
			imgui.SetTooltip("Doors  N:%d  S:%d  E:%d  W:%d",
				c.int(doors[.North]), c.int(doors[.South]), c.int(doors[.East]), c.int(doors[.West]))
		}

		imgui.TableNextColumn()
		imgui.Text("%dx%d", c.int(tmpl.width), c.int(tmpl.height))
		imgui.TableNextColumn()
		imgui.Text("%d", c.int(template_cell_count(&tmpl)))
		imgui.TableNextColumn()
		imgui.Text("%d", c.int(len(tmpl.door_slots)))

		imgui.PopID()
	}
}

// Name/stat labels under each showcased module, drawn behind the UI panel.
draw_module_labels :: proc(d: ^Dungeon, camera: rl.Camera3D) {
	if !d.showcase {
		draw_graph_room_labels(d, camera)
		return
	}

	draw_list := imgui.GetBackgroundDrawList()
	forward := rl.Vector3Normalize(camera.target - camera.position)
	cs := d.config.cell_size
	name_col := imgui.ColorConvertFloat4ToU32({1, 1, 1, 1})
	stat_col := imgui.ColorConvertFloat4ToU32({0.7, 0.7, 0.75, 1})

	for &m in d.modules {
		tmpl := &module_templates[m.template_index]
		// Anchor just past the module's south edge, on the floor
		world := rl.Vector3{m.center_x * cs, 0, (f32(m.grid_y + m.rot_height) + 0.3) * cs}

		// Skip modules behind the camera (freeflight)
		if rl.Vector3DotProduct(world - camera.position, forward) <= 0 do continue

		screen := rl.GetWorldToScreen(world, camera)
		lines := [3]cstring{
			fmt.ctprintf("%s", tmpl.name),
			fmt.ctprintf("%dx%d, %d cells", tmpl.width, tmpl.height, template_cell_count(tmpl)),
			fmt.ctprintf("%d doors", len(tmpl.door_slots)),
		}

		box_w: f32 = 0
		box_h: f32 = 6
		for line in lines {
			size := imgui.CalcTextSize(line)
			box_w = max(box_w, size.x + 8)
			box_h += size.y
		}
		top_left := imgui.Vec2{screen.x - box_w * 0.5, screen.y}
		imgui.DrawList_AddRectFilled(draw_list, top_left, {top_left.x + box_w, top_left.y + box_h},
			imgui.ColorConvertFloat4ToU32({0, 0, 0, 0.65}), 3)

		y := top_left.y + 3
		for line, li in lines {
			size := imgui.CalcTextSize(line)
			imgui.DrawList_AddText(draw_list, {screen.x - size.x * 0.5, y}, li == 0 ? name_col : stat_col, line)
			y += size.y
		}
	}
}

// ---------------------------------------------------------------------------
// Room inspector (left-click a room in the top-down view)
// ---------------------------------------------------------------------------

ROTATION_NAMES := [Rotation]cstring{
	.R0   = "0",
	.R90  = "90",
	.R180 = "180",
	.R270 = "270",
}

DIRECTION_NAMES := [Direction]cstring{
	.North = "N",
	.South = "S",
	.East  = "E",
	.West  = "W",
}

draw_inspector :: proc() {
	d := &state.dungeon
	cv := &state.canvas
	id := cv.inspect_module
	if id < 0 || id >= len(d.modules) do return

	m := &d.modules[id]
	tmpl := &module_templates[m.template_index]
	label_col := imgui.Vec4{0.6, 0.6, 0.7, 1.0}

	display_size := imgui.GetIO().DisplaySize
	imgui.SetNextWindowPos({display_size.x - 10, 10}, .Always, {1, 0})
	imgui.SetNextWindowSize({310, 0}, .Always)
	open := true
	if !imgui.Begin(fmt.ctprintf("Room #%d###inspector", id), &open, {.NoResize, .NoMove, .NoCollapse, .NoSavedSettings, .NoFocusOnAppearing}) {
		imgui.End()
		return
	}
	defer imgui.End()
	if !open {
		cv.inspect_module = -1
		return
	}

	// ---- Template ----
	imgui.ColorButton("##col", color4_to_vec4(tmpl.color), {.NoTooltip}, {12, 12})
	imgui.SameLine()
	imgui.Text("%s", fmt.ctprintf("%s  (template %d)", tmpl.name, m.template_index))

	// ---- Room graph ----
	if g, node, ok := graph_node_for_module(d, id); ok {
		p := &room_profiles[g.profile]
		t := &p.types[g.nodes[node].type]
		imgui.TextColored(label_col, "Room:")
		imgui.SameLine()
		imgui.TextColored(zone_color(t.zone), "%s", graph_node_label(p, g, node))
		imgui.SameLine()
		imgui.TextColored(label_col, "(%s, depth %d)", fmt.ctprintf("%s", p.zones[t.zone]), c.int(g.nodes[node].depth))
		for e in g.edges {
			other := e.a == node ? e.b : e.b == node ? e.a : -1
			if other < 0 do continue
			status: cstring = e.realized ? "" : "  (not connected)"
			imgui.TextColored(e.realized ? label_col : imgui.Vec4{0.9, 0.5, 0.45, 1}, "  -> %s%s", graph_node_label(p, g, other), status)
		}
	}

	// ---- Origin ----
	imgui.TextColored(label_col, "Placed by:")
	imgui.SameLine()
	if m.placed_by_step < 0 {
		imgui.Text("Module showcase")
	} else if m.placed_by_step < len(d.recipe.steps) {
		step := &d.recipe.steps[m.placed_by_step]
		if imgui.SmallButton(fmt.ctprintf("%d. %s", m.placed_by_step + 1, STEP_TYPE_NAMES[step.type])) {
			cv.scroll_to_step = m.placed_by_step
		}
		if imgui.IsItemHovered() do imgui.SetTooltip("Show this step in the Recipe tab")
	} else {
		imgui.Text("step %d", c.int(m.placed_by_step + 1))
	}

	imgui.TextColored(label_col, "Position:")
	imgui.SameLine()
	imgui.Text("(%d, %d)", c.int(m.grid_x), c.int(m.grid_y))
	imgui.SameLine()
	imgui.TextColored(label_col, "  Rotation:")
	imgui.SameLine()
	if m.mirrored {
		imgui.Text("mirrored")
	} else {
		imgui.Text("%s", ROTATION_NAMES[m.rotation])
	}

	// ---- Size ----
	own_cells := 0
	for filled in m.rot_mask {
		if filled do own_cells += 1
	}
	grid_cells := 0
	for &cell in d.grid {
		if cell.module_id == id do grid_cells += 1
	}
	imgui.TextColored(label_col, "Size:")
	imgui.SameLine()
	imgui.Text("%dx%d, %d cells", c.int(m.rot_width), c.int(m.rot_height), c.int(own_cells))
	if grid_cells != own_cells {
		imgui.TextColored({1.0, 0.8, 0.4, 1.0}, "Joined: %d cells total", c.int(grid_cells))
	}

	// ---- Groups ----
	imgui.TextColored(label_col, "Groups:")
	in_any := false
	for &g in d.groups {
		for gid in g.module_ids {
			if gid != id do continue
			imgui.SameLine()
			imgui.Text("%s", fmt.ctprintf("%s", g.name))
			in_any = true
			break
		}
	}
	if !in_any {
		imgui.SameLine()
		imgui.TextDisabled("none")
	}

	// ---- Doors ----
	connected, two_sided := 0, 0
	for di in 0 ..< len(m.rot_doors) {
		if module_door_connected(m, di) do connected += 1
		if module_door_two_sided(m, di) do two_sided += 1
	}
	imgui.Separator()
	imgui.Text("Doors: %d slots, %d connected, %d two-sided",
		c.int(len(m.rot_doors)), c.int(connected), c.int(two_sided))

	table_flags := imgui.TableFlags_RowBg | imgui.TableFlags_BordersInnerH | imgui.TableFlags_SizingFixedFit
	if imgui.BeginTable("##doors", 4, table_flags) {
		imgui.TableSetupColumn("#")
		imgui.TableSetupColumn("Cell")
		imgui.TableSetupColumn("Dir")
		imgui.TableSetupColumn("Status", {.WidthStretch})
		imgui.TableHeadersRow()

		for slot, di in m.rot_doors {
			imgui.TableNextRow()
			imgui.TableNextColumn()
			imgui.Text("%d", c.int(di))
			imgui.TableNextColumn()
			dgx, dgy := door_global(slot, m.grid_x, m.grid_y)
			imgui.Text("(%d, %d)", c.int(dgx), c.int(dgy))
			imgui.TableNextColumn()
			imgui.Text("%s", DIRECTION_NAMES[slot.direction])
			imgui.TableNextColumn()
			if module_door_two_sided(m, di) {
				imgui.TextColored({1.0, 0.86, 0.2, 1.0}, "two-sided")
			} else if module_door_connected(m, di) {
				imgui.TextColored({0.3, 1.0, 0.5, 1.0}, "connected")
			} else {
				imgui.TextDisabled("unused")
			}
		}
		imgui.EndTable()
	}

	imgui.TextDisabled("[Esc] or click empty space to close")
}

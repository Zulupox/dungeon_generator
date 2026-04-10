package dungeon_generator

import "core:math/rand"
import "base:intrinsics"

// ---------------------------------------------------------------------------
// Grid + Dungeon data structures
// ---------------------------------------------------------------------------

Cell_Type :: enum u8 {
	Empty,
	Room,
	Corridor,
	Door,
}

Grid_Cell :: struct {
	cell_type: Cell_Type,
	module_id: int, // index into dungeon.modules, -1 if empty/corridor
	color:     Color4,
}

Color4 :: [4]u8

// ---------------------------------------------------------------------------
// Area definitions
// ---------------------------------------------------------------------------

Dungeon_Area :: struct {
	id:    int,         // 0, 1, 2, ...
	shape: Area_Shape,
	x, y:  int,         // top-left for rect, center for circle (absolute grid coords)
	w, h:  int,         // width/height for rect, w=radius for circle
}

// Config only holds grid + render settings.
// All generation parameters live in Recipe steps.
Dungeon_Config :: struct {
	grid_width:  int,
	grid_height: int,
	cell_size:   f32, // world units per grid cell
	wall_height: f32,
}

Rotation :: enum u8 {
	R0,
	R90,
	R180,
	R270,
}

Placed_Module :: struct {
	template_index:  int,
	rotation:        Rotation,
	grid_x, grid_y:  int, // top-left corner on grid
	center_x:        f32, // cached center in grid coords
	center_y:        f32,
	// Rotated data (pre-computed at placement time)
	rot_width:       int,
	rot_height:      int,
	rot_mask:        [dynamic]bool,
	rot_doors:       [dynamic]Door_Slot,
	connected_doors: [dynamic]int, // indices into rot_doors that are in use
	two_sided_doors: [dynamic]int, // subset of connected_doors that have a matching door on the other side
}

Corridor_Job :: struct {
	from_module:  int,
	to_module:    int,
	from_door_gx: int,
	from_door_gy: int,
	to_door_gx:   int,
	to_door_gy:   int,
}

// Placement target for BSP / Place_Grid - a region where a room should be placed
Placement_Target :: struct {
	center_x: int,
	center_y: int,
	max_w:    int, // maximum room dimensions allowed in this slot
	max_h:    int,
}

// ---------------------------------------------------------------------------
// Room Groups - named collections of module indices
// ---------------------------------------------------------------------------

Room_Group :: struct {
	name:       string,
	module_ids: [dynamic]int,
}

// ---------------------------------------------------------------------------
// Room Palette - adjacency rules and room budgets
// ---------------------------------------------------------------------------

Room_Quota :: struct {
	room_type: Room_Type,
	min_count: int,
	max_count: int,  // 0 = unlimited
	weight:    f32,  // relative probability when eligible (default 1.0)
}

Room_Palette :: struct {
	// Adjacency table: for each room type, which types are allowed next to it.
	// An empty slice means "allow everything" (used for Generic/Courtyard).
	adjacency: [Room_Type][]Room_Type,
	quotas:    [dynamic]Room_Quota,
	active:    bool,  // false = no palette constraints (backward compatible)
}

Dungeon :: struct {
	config:  Dungeon_Config,
	grid:    []Grid_Cell,
	modules: [dynamic]Placed_Module,

	// Recipe execution state
	recipe:        Recipe,
	current_step:  int,   // index into recipe.steps
	step_progress: int,   // sub-step progress within current step
	step_done:     bool,  // current step is complete, advance on next call
	gen_done:      bool,  // all steps complete
	actual_seed:   u64,   // the seed that was actually used (for display)

	// Area system
	areas:               [dynamic]Dungeon_Area,
	active_area_id:      int,   // set by dispatcher from step's area_id; -1 = no constraint
	active_area_exclude: bool,  // set by dispatcher from step's area_exclude

	// Group system
	groups:              [dynamic]Room_Group,
	active_group:        string,  // set by dispatcher from step's group; "" = no tagging
	active_source_group: string,  // set by dispatcher from step's source_group; "" = no filter

	// Room palette system
	palette:          Room_Palette,
	room_type_counts: [Room_Type]int,  // how many of each type have been placed

	// Per-step working data (cleared between steps)
	mst_edges:        [dynamic]Corridor_Job,
	loop_edges:       [dynamic]Corridor_Job,
	placement_queue:  [dynamic]Placement_Target,
}

// ---------------------------------------------------------------------------
// Dungeon lifecycle
// ---------------------------------------------------------------------------

dungeon_create :: proc(config: Dungeon_Config) -> Dungeon {
	d: Dungeon
	d.config = config
	d.grid = make([]Grid_Cell, config.grid_width * config.grid_height)
	dungeon_clear_grid(&d)
	d.gen_done = true
	return d
}

free_placed_module :: proc(m: ^Placed_Module) {
	delete(m.connected_doors)
	delete(m.two_sided_doors)
	delete(m.rot_mask)
	delete(m.rot_doors)
}

dungeon_destroy :: proc(d: ^Dungeon) {
	delete(d.grid)
	for &m in d.modules {
		free_placed_module(&m)
	}
	delete(d.modules)
	delete(d.areas)
	for &g in d.groups {
		delete(g.module_ids)
	}
	delete(d.groups)
	delete(d.mst_edges)
	delete(d.loop_edges)
	delete(d.placement_queue)
	palette_destroy(&d.palette)
	recipe_destroy(&d.recipe)
}

dungeon_reset :: proc(d: ^Dungeon) {
	dungeon_clear_grid(d)
	for &m in d.modules {
		free_placed_module(&m)
	}
	clear(&d.modules)
	clear(&d.areas)
	for &g in d.groups {
		delete(g.module_ids)
	}
	clear(&d.groups)
	clear(&d.mst_edges)
	clear(&d.loop_edges)
	clear(&d.placement_queue)
	d.current_step = 0
	d.step_progress = 0
	d.step_done = false
	d.gen_done = false
	d.active_area_id = -1
	d.active_area_exclude = false
	d.active_group = ""
	d.active_source_group = ""
	// Reset palette
	palette_reset(&d.palette)
	d.room_type_counts = {}
}

dungeon_clear_grid :: proc(d: ^Dungeon) {
	for &cell in d.grid {
		cell = Grid_Cell{
			cell_type = .Empty,
			module_id = -1,
			color     = {0, 0, 0, 0},
		}
	}
}

// ---------------------------------------------------------------------------
// Grid helpers
// ---------------------------------------------------------------------------

grid_index :: proc(d: ^Dungeon, x, y: int) -> int {
	return y * d.config.grid_width + x
}

grid_in_bounds :: proc(d: ^Dungeon, x, y: int) -> bool {
	return x >= 0 && x < d.config.grid_width && y >= 0 && y < d.config.grid_height
}

grid_get :: proc(d: ^Dungeon, x, y: int) -> ^Grid_Cell {
	return &d.grid[grid_index(d, x, y)]
}

grid_is_empty :: proc(d: ^Dungeon, x, y: int) -> bool {
	if !grid_in_bounds(d, x, y) do return false
	return d.grid[grid_index(d, x, y)].cell_type == .Empty
}

grid_is_passable :: proc(d: ^Dungeon, x, y: int) -> bool {
	if !grid_in_bounds(d, x, y) do return false
	ct := d.grid[grid_index(d, x, y)].cell_type
	return ct == .Empty || ct == .Corridor || ct == .Door
}

// ---------------------------------------------------------------------------
// Area helpers
// ---------------------------------------------------------------------------

// Find an area by ID. Returns pointer or nil.
find_area_by_id :: proc(d: ^Dungeon, id: int) -> ^Dungeon_Area {
	for &a in d.areas {
		if a.id == id do return &a
	}
	return nil
}

// Check if a cell (x, y) satisfies the active area constraint.
// Uses d.active_area_id and d.active_area_exclude set by the dispatcher.
// Returns true if the cell is allowed (passes the constraint).
cell_in_active_area :: proc(d: ^Dungeon, x, y: int) -> bool {
	if d.active_area_id < 0 do return true  // no constraint
	area := find_area_by_id(d, d.active_area_id)
	if area == nil do return true  // area not defined yet, allow all

	inside := point_in_area(area, x, y)
	return inside != d.active_area_exclude  // include mode: want inside; exclude mode: want outside
}

// Test if a point is geometrically inside an area.
point_in_area :: proc(area: ^Dungeon_Area, x, y: int) -> bool {
	switch area.shape {
	case .Rectangle:
		return x >= area.x && x < area.x + area.w && y >= area.y && y < area.y + area.h
	case .Circle:
		dx := f64(x) - f64(area.x)
		dy := f64(y) - f64(area.y)
		r := f64(area.w)
		return dx * dx + dy * dy <= r * r
	}
	return true
}

// ---------------------------------------------------------------------------
// Generation - seed the RNG and start
// ---------------------------------------------------------------------------

dungeon_start_generation :: proc(d: ^Dungeon) {
	dungeon_reset(d)

	// Seed the RNG
	d.actual_seed = d.recipe.seed
	if d.actual_seed == 0 {
		d.actual_seed = u64(intrinsics.read_cycle_counter())
	}
	rand.reset(d.actual_seed)
}

// ---------------------------------------------------------------------------
// Full generation (instant mode)
// ---------------------------------------------------------------------------

dungeon_generate_full :: proc(d: ^Dungeon) {
	dungeon_start_generation(d)
	for !d.gen_done {
		dungeon_generate_step(d)
	}
}

// ---------------------------------------------------------------------------
// Stepped generation - recipe dispatcher
// ---------------------------------------------------------------------------

dungeon_generate_step :: proc(d: ^Dungeon) {
	if d.gen_done do return

	// Advance to next step if current one just finished
	if d.step_done {
		d.current_step += 1
		d.step_progress = 0
		d.step_done = false
		clear(&d.mst_edges)
		clear(&d.loop_edges)
		clear(&d.placement_queue)
	}

	// Check if recipe is complete
	if d.current_step >= len(d.recipe.steps) {
		// Always finalize doors at the end
		mark_connected_doors(d)
		d.gen_done = true
		return
	}

	step := &d.recipe.steps[d.current_step]

	if step.muted {
		d.step_done = true
		return
	}

	// Set active area constraint from this step
	d.active_area_id = step.area_id
	d.active_area_exclude = step.area_exclude

	// Set active group context from this step
	d.active_group = step.group
	d.active_source_group = step.source_group

	switch step.type {
	case .Seed_Rooms:
		execute_seed_rooms(d, &step.seed_rooms)
	case .Grow_Clusters:
		execute_grow_clusters(d, &step.grow_clusters)
	case .Connect_MST:
		execute_connect_mst(d, &step.connect_mst)
	case .Mark_Doors:
		execute_mark_doors(d)
	case .Add_Loops:
		execute_add_loops(d, &step.add_loops)
	case .Widen_Corridors:
		execute_widen_corridors(d, &step.widen_corridors)
	case .BSP_Partition:
		execute_bsp_partition(d, &step.bsp_partition)
	case .Fill_Dead_Ends:
		execute_fill_dead_ends(d, &step.fill_dead_ends)
	case .Place_Grid:
		execute_place_grid(d, &step.place_grid)
	case .Room_Corridor:
		execute_room_corridor(d, &step.room_corridor)
	case .Define_Area:
		execute_define_area(d, &step.define_area)
	case .Pack_Rooms:
		execute_pack_rooms(d, &step.pack_rooms)
	case .Join_Rooms:
		execute_join_rooms(d)
	case .Connect_Doors:
		execute_connect_doors(d, &step.connect_doors)
	case .Place_Specific:
		execute_place_specific(d, &step.place_specific)
	case .Mirror_Rooms:
		execute_mirror_rooms(d, &step.mirror_rooms)
	case .Place_Symmetric:
		execute_place_symmetric(d, &step.place_symmetric)
	case .Place_Perimeter:
		execute_place_perimeter(d, &step.place_perimeter)
	case .Place_Along_Line:
		execute_place_along_line(d, &step.place_along_line)
	case .Fill_Area:
		execute_fill_area(d, &step.fill_area)
	case .Wall_Border:
		execute_wall_border(d, &step.wall_border)
	case .Connect_Linear:
		execute_connect_linear(d, &step.connect_linear)
	case .Define_Palette:
		execute_define_palette(d, &step.define_palette)
	}
}

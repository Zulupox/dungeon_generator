package dungeon_generator

import "core:encoding/json"
import "core:os"
import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// Step types and parameters
// ---------------------------------------------------------------------------

Step_Type :: enum {
	Seed_Rooms,
	Grow_Clusters,
	Connect_MST,
	Mark_Doors,
	Add_Loops,
	Widen_Corridors,
	BSP_Partition,
	Fill_Dead_Ends,
	Place_Grid,
	Room_Corridor,
	Define_Area,
	Pack_Rooms,
	Join_Rooms,
	Connect_Doors,
}

STEP_TYPE_NAMES := [Step_Type]cstring{
	.Seed_Rooms      = "Seed Rooms",
	.Grow_Clusters   = "Grow Clusters",
	.Connect_MST     = "Connect MST",
	.Mark_Doors      = "Mark Doors",
	.Add_Loops       = "Add Loops",
	.Widen_Corridors = "Widen Corridors",
	.BSP_Partition   = "BSP Partition",
	.Fill_Dead_Ends  = "Fill Dead Ends",
	.Place_Grid      = "Place Grid",
	.Room_Corridor   = "Room Corridor",
	.Define_Area     = "Define Area",
	.Pack_Rooms      = "Pack Rooms",
	.Join_Rooms      = "Join Rooms",
	.Connect_Doors   = "Connect Doors",
}

Seed_Rooms_Params :: struct {
	count: int,
}

Grow_Clusters_Params :: struct {
	chance:    f32,
	min_rooms: int,
	max_rooms: int,
}

Connect_MST_Params :: struct {
	manhattan_weight: f32,
}

Add_Loops_Params :: struct {
	loop_chance:      f32,
	max_extra:        int,
	manhattan_weight: f32,
}

Widen_Corridors_Params :: struct {
	width: int,
}

BSP_Partition_Params :: struct {
	min_size: int,
	padding:  int,
}

Fill_Dead_Ends_Params :: struct {
	iterations: int,
}

Place_Grid_Params :: struct {
	cols:   int,
	rows:   int,
	jitter: f32,
}

Room_Corridor_Params :: struct {
	strictness:       f32, // 0.0 = sloppy, 1.0 = strict path following
	manhattan_weight: f32, // corridor style for fallback A* bridging
	max_chain:        int, // max rooms per connection before falling back
}

Area_Shape :: enum {
	Rectangle,
	Circle,
}

AREA_SHAPE_NAMES := [Area_Shape]cstring{
	.Rectangle = "Rectangle",
	.Circle    = "Circle",
}

Define_Area_Params :: struct {
	area_id: int,
	shape:   Area_Shape,
	x, y:    int, // top-left for rect, center for circle (absolute grid coords)
	w, h:    int, // width/height for rect, w=radius for circle
}

Pack_Rooms_Params :: struct {
	max_rooms: int, // safety cap, 0 = unlimited
}

Connect_Doors_Mode :: enum {
	All,      // Open every matching door-to-door pair (up to max_per_pair)
	Minimal,  // Open just enough so every room has at least one connection
}

CONNECT_DOORS_MODE_NAMES := [Connect_Doors_Mode]cstring{
	.All     = "All",
	.Minimal = "Minimal",
}

Connect_Doors_Params :: struct {
	mode:         Connect_Doors_Mode,
	max_per_pair: int, // max doors between any two modules (0 = unlimited)
}

// Gen_Step uses a flat struct with all param fields.
// Only the fields relevant to the step type are used.
// This makes JSON serialization straightforward.
Gen_Step :: struct {
	type:            Step_Type             `json:"type"`,
	seed_rooms:      Seed_Rooms_Params     `json:"seed_rooms"`,
	grow_clusters:   Grow_Clusters_Params  `json:"grow_clusters"`,
	connect_mst:     Connect_MST_Params    `json:"connect_mst"`,
	add_loops:       Add_Loops_Params      `json:"add_loops"`,
	widen_corridors: Widen_Corridors_Params `json:"widen_corridors"`,
	bsp_partition:   BSP_Partition_Params   `json:"bsp_partition"`,
	fill_dead_ends:  Fill_Dead_Ends_Params  `json:"fill_dead_ends"`,
	place_grid:      Place_Grid_Params      `json:"place_grid"`,
	room_corridor:   Room_Corridor_Params   `json:"room_corridor"`,
	define_area:     Define_Area_Params     `json:"define_area"`,
	pack_rooms:      Pack_Rooms_Params      `json:"pack_rooms"`,
	connect_doors:   Connect_Doors_Params   `json:"connect_doors"`,
	// Area constraint: -1 = no constraint (whole grid), >= 0 = constrain to area
	area_id:         int                   `json:"area_id"`,
	area_exclude:    bool                  `json:"area_exclude"`,
}

// Helper to create a Gen_Step with proper defaults (area_id = -1)
make_step :: proc(type: Step_Type) -> Gen_Step {
	return Gen_Step{
		type    = type,
		area_id = -1,
	}
}

// ---------------------------------------------------------------------------
// Recipe
// ---------------------------------------------------------------------------

Recipe :: struct {
	name:  string          `json:"name"`,
	seed:  u64             `json:"seed"`,
	steps: [dynamic]Gen_Step `json:"steps"`,
}

// ---------------------------------------------------------------------------
// Recipe lifecycle
// ---------------------------------------------------------------------------

recipe_destroy :: proc(r: ^Recipe) {
	delete(r.steps)
}

recipe_clone :: proc(src: ^Recipe) -> Recipe {
	r: Recipe
	r.name = src.name
	r.seed = src.seed
	r.steps = make([dynamic]Gen_Step, len(src.steps))
	for i in 0 ..< len(src.steps) {
		r.steps[i] = src.steps[i]
	}
	return r
}

// ---------------------------------------------------------------------------
// Built-in preset recipes
// ---------------------------------------------------------------------------

recipe_classic_dungeon :: proc() -> Recipe {
	r: Recipe
	r.name = "Classic Dungeon"
	r.seed = 0
	s: Gen_Step
	s = make_step(.Seed_Rooms);      s.seed_rooms = {count = 8};                                       append(&r.steps, s)
	s = make_step(.Grow_Clusters);    s.grow_clusters = {chance = 0.4, min_rooms = 1, max_rooms = 4};   append(&r.steps, s)
	s = make_step(.Connect_MST);      s.connect_mst = {manhattan_weight = 0.8};                         append(&r.steps, s)
	s = make_step(.Mark_Doors);                                                                         append(&r.steps, s)
	return r
}

recipe_dense_catacombs :: proc() -> Recipe {
	r: Recipe
	r.name = "Dense Catacombs"
	r.seed = 0
	s: Gen_Step
	s = make_step(.Seed_Rooms);      s.seed_rooms = {count = 4};                                       append(&r.steps, s)
	s = make_step(.Grow_Clusters);    s.grow_clusters = {chance = 1.0, min_rooms = 3, max_rooms = 6};   append(&r.steps, s)
	s = make_step(.Connect_MST);      s.connect_mst = {manhattan_weight = 1.0};                         append(&r.steps, s)
	s = make_step(.Mark_Doors);                                                                         append(&r.steps, s)
	return r
}

recipe_scattered_ruins :: proc() -> Recipe {
	r: Recipe
	r.name = "Scattered Ruins"
	r.seed = 0
	s: Gen_Step
	s = make_step(.Seed_Rooms);  s.seed_rooms = {count = 15};               append(&r.steps, s)
	s = make_step(.Connect_MST); s.connect_mst = {manhattan_weight = 0.3};  append(&r.steps, s)
	s = make_step(.Mark_Doors);                                              append(&r.steps, s)
	return r
}

recipe_mega_complex :: proc() -> Recipe {
	r: Recipe
	r.name = "Mega Complex"
	r.seed = 0
	s: Gen_Step
	s = make_step(.Seed_Rooms);      s.seed_rooms = {count = 3};                                       append(&r.steps, s)
	s = make_step(.Grow_Clusters);    s.grow_clusters = {chance = 0.8, min_rooms = 4, max_rooms = 8};   append(&r.steps, s)
	s = make_step(.Seed_Rooms);       s.seed_rooms = {count = 6};                                       append(&r.steps, s)
	s = make_step(.Connect_MST);      s.connect_mst = {manhattan_weight = 0.5};                         append(&r.steps, s)
	s = make_step(.Mark_Doors);                                                                         append(&r.steps, s)
	return r
}

recipe_loopy_labyrinth :: proc() -> Recipe {
	r: Recipe
	r.name = "Loopy Labyrinth"
	r.seed = 0
	s: Gen_Step
	s = make_step(.Seed_Rooms);      s.seed_rooms = {count = 6};                                                            append(&r.steps, s)
	s = make_step(.Grow_Clusters);    s.grow_clusters = {chance = 0.5, min_rooms = 1, max_rooms = 3};                        append(&r.steps, s)
	s = make_step(.Connect_MST);      s.connect_mst = {manhattan_weight = 0.6};                                              append(&r.steps, s)
	s = make_step(.Add_Loops);        s.add_loops = {loop_chance = 0.3, max_extra = 4, manhattan_weight = 0.4};              append(&r.steps, s)
	s = make_step(.Fill_Dead_Ends);   s.fill_dead_ends = {iterations = 2};                                                   append(&r.steps, s)
	s = make_step(.Mark_Doors);                                                                                              append(&r.steps, s)
	return r
}

recipe_grand_fortress :: proc() -> Recipe {
	r: Recipe
	r.name = "Grand Fortress"
	r.seed = 0
	s: Gen_Step
	s = make_step(.Place_Grid);       s.place_grid = {cols = 3, rows = 3, jitter = 0.1};   append(&r.steps, s)
	s = make_step(.Connect_MST);      s.connect_mst = {manhattan_weight = 1.0};             append(&r.steps, s)
	s = make_step(.Widen_Corridors);   s.widen_corridors = {width = 3};                      append(&r.steps, s)
	s = make_step(.Mark_Doors);                                                              append(&r.steps, s)
	return r
}

recipe_organic_caverns :: proc() -> Recipe {
	r: Recipe
	r.name = "Organic Caverns"
	r.seed = 0
	s: Gen_Step
	s = make_step(.BSP_Partition);    s.bsp_partition = {min_size = 8, padding = 2};                                         append(&r.steps, s)
	s = make_step(.Connect_MST);      s.connect_mst = {manhattan_weight = 0.0};                                              append(&r.steps, s)
	s = make_step(.Add_Loops);        s.add_loops = {loop_chance = 0.5, max_extra = 6, manhattan_weight = 0.0};              append(&r.steps, s)
	s = make_step(.Mark_Doors);                                                                                              append(&r.steps, s)
	return r
}

recipe_temple_complex :: proc() -> Recipe {
	r: Recipe
	r.name = "Temple Complex"
	r.seed = 0
	s: Gen_Step
	s = make_step(.Seed_Rooms);       s.seed_rooms = {count = 4};                                                           append(&r.steps, s)
	s = make_step(.Room_Corridor);    s.room_corridor = {strictness = 0.7, manhattan_weight = 0.8, max_chain = 6};          append(&r.steps, s)
	s = make_step(.Mark_Doors);                                                                                              append(&r.steps, s)
	return r
}

recipe_walled_castle :: proc() -> Recipe {
	r: Recipe
	r.name = "Walled Castle"
	r.seed = 0
	s: Gen_Step
	// Define a rectangular area in the center of the grid
	s = make_step(.Define_Area);      s.define_area = {area_id = 0, shape = .Rectangle, x = 16, y = 16, w = 32, h = 32};   append(&r.steps, s)
	// Pack the area with rooms, then merge them
	s = make_step(.Pack_Rooms);       s.pack_rooms = {max_rooms = 0};  s.area_id = 0;                   append(&r.steps, s)
	s = make_step(.Join_Rooms);       s.area_id = 0;                                                    append(&r.steps, s)
	// Connect and finalize
	s = make_step(.Connect_MST);      s.connect_mst = {manhattan_weight = 0.8};  s.area_id = 0;        append(&r.steps, s)
	s = make_step(.Mark_Doors);                                                                         append(&r.steps, s)
	return r
}

recipe_walled_castle_2 :: proc() -> Recipe {
	r: Recipe
	r.name = "Walled Castle 2"
	r.seed = 0
	s: Gen_Step
	// Define a rectangular area in the center of the grid
	s = make_step(.Define_Area);      s.define_area = {area_id = 0, shape = .Rectangle, x = 16, y = 16, w = 32, h = 32};   append(&r.steps, s)
	// Pack the area with rooms
	s = make_step(.Pack_Rooms);       s.pack_rooms = {max_rooms = 0};  s.area_id = 0;                   append(&r.steps, s)
	// Connect adjacent rooms via door-to-door pairs (minimal, max 1 per pair)
	s = make_step(.Connect_Doors);    s.connect_doors = {mode = .Minimal, max_per_pair = 1};  s.area_id = 0;  append(&r.steps, s)
	// Mark any remaining corridor-facing doors
	s = make_step(.Mark_Doors);                                                                         append(&r.steps, s)
	return r
}

PRESET_NAMES := [?]cstring{
	"Classic Dungeon",
	"Dense Catacombs",
	"Scattered Ruins",
	"Mega Complex",
	"Loopy Labyrinth",
	"Grand Fortress",
	"Organic Caverns",
	"Temple Complex",
	"Walled Castle",
	"Walled Castle 2",
}

preset_recipe_by_index :: proc(index: int) -> Recipe {
	switch index {
	case 0: return recipe_classic_dungeon()
	case 1: return recipe_dense_catacombs()
	case 2: return recipe_scattered_ruins()
	case 3: return recipe_mega_complex()
	case 4: return recipe_loopy_labyrinth()
	case 5: return recipe_grand_fortress()
	case 6: return recipe_organic_caverns()
	case 7: return recipe_temple_complex()
	case 8: return recipe_walled_castle()
	case 9: return recipe_walled_castle_2()
	}
	return recipe_classic_dungeon()
}

// ---------------------------------------------------------------------------
// JSON serialization
// ---------------------------------------------------------------------------

// JSON-friendly structures (use fixed arrays instead of dynamic for marshal)

Json_Step :: struct {
	type:            string                `json:"type"`,
	seed_rooms:      Seed_Rooms_Params     `json:"seed_rooms"`,
	grow_clusters:   Grow_Clusters_Params  `json:"grow_clusters"`,
	connect_mst:     Connect_MST_Params    `json:"connect_mst"`,
	add_loops:       Add_Loops_Params      `json:"add_loops"`,
	widen_corridors: Widen_Corridors_Params `json:"widen_corridors"`,
	bsp_partition:   BSP_Partition_Params   `json:"bsp_partition"`,
	fill_dead_ends:  Fill_Dead_Ends_Params  `json:"fill_dead_ends"`,
	place_grid:      Place_Grid_Params      `json:"place_grid"`,
	room_corridor:   Room_Corridor_Params   `json:"room_corridor"`,
	define_area:     Define_Area_Params     `json:"define_area"`,
	pack_rooms:      Pack_Rooms_Params      `json:"pack_rooms"`,
	connect_doors:   Connect_Doors_Params   `json:"connect_doors"`,
	area_id:         int                   `json:"area_id"`,
	area_exclude:    bool                  `json:"area_exclude"`,
}

Json_Recipe :: struct {
	name:  string      `json:"name"`,
	seed:  u64         `json:"seed"`,
	steps: []Json_Step `json:"steps"`,
}

step_type_to_string :: proc(t: Step_Type) -> string {
	switch t {
	case .Seed_Rooms:      return "Seed_Rooms"
	case .Grow_Clusters:   return "Grow_Clusters"
	case .Connect_MST:     return "Connect_MST"
	case .Mark_Doors:      return "Mark_Doors"
	case .Add_Loops:       return "Add_Loops"
	case .Widen_Corridors: return "Widen_Corridors"
	case .BSP_Partition:   return "BSP_Partition"
	case .Fill_Dead_Ends:  return "Fill_Dead_Ends"
	case .Place_Grid:      return "Place_Grid"
	case .Room_Corridor:   return "Room_Corridor"
	case .Define_Area:     return "Define_Area"
	case .Pack_Rooms:      return "Pack_Rooms"
	case .Join_Rooms:      return "Join_Rooms"
	case .Connect_Doors:   return "Connect_Doors"
	}
	return "Unknown"
}

string_to_step_type :: proc(s: string) -> (Step_Type, bool) {
	switch s {
	case "Seed_Rooms":      return .Seed_Rooms, true
	case "Grow_Clusters":   return .Grow_Clusters, true
	case "Connect_MST":     return .Connect_MST, true
	case "Mark_Doors":      return .Mark_Doors, true
	case "Add_Loops":       return .Add_Loops, true
	case "Widen_Corridors": return .Widen_Corridors, true
	case "BSP_Partition":   return .BSP_Partition, true
	case "Fill_Dead_Ends":  return .Fill_Dead_Ends, true
	case "Place_Grid":      return .Place_Grid, true
	case "Room_Corridor":   return .Room_Corridor, true
	case "Define_Area":     return .Define_Area, true
	case "Pack_Rooms":      return .Pack_Rooms, true
	case "Join_Rooms":      return .Join_Rooms, true
	case "Connect_Doors":   return .Connect_Doors, true
	}
	return .Seed_Rooms, false
}

recipe_save :: proc(recipe: ^Recipe, filepath: string) -> bool {
	// Convert to JSON-friendly format
	json_steps := make([]Json_Step, len(recipe.steps))
	defer delete(json_steps)

	for i in 0 ..< len(recipe.steps) {
		s := &recipe.steps[i]
		json_steps[i] = Json_Step{
			type            = step_type_to_string(s.type),
			seed_rooms      = s.seed_rooms,
			grow_clusters   = s.grow_clusters,
			connect_mst     = s.connect_mst,
			add_loops       = s.add_loops,
			widen_corridors = s.widen_corridors,
			bsp_partition   = s.bsp_partition,
			fill_dead_ends  = s.fill_dead_ends,
			place_grid      = s.place_grid,
			room_corridor   = s.room_corridor,
			define_area     = s.define_area,
			pack_rooms      = s.pack_rooms,
			connect_doors   = s.connect_doors,
			area_id         = s.area_id,
			area_exclude    = s.area_exclude,
		}
	}

	jr := Json_Recipe{
		name  = recipe.name,
		seed  = recipe.seed,
		steps = json_steps,
	}

	opts := json.Marshal_Options{
		spec = .JSON,
		pretty = true,
		use_enum_names = true,
	}

	data, err := json.marshal(jr, opts)
	if err != nil do return false
	defer delete(data)

	return os.write_entire_file(filepath, data) == nil
}

recipe_load :: proc(filepath: string) -> (Recipe, bool) {
	data, read_err := os.read_entire_file(filepath, context.allocator)
	if read_err != nil do return {}, false
	defer delete(data)

	jr: Json_Recipe
	uerr := json.unmarshal(data, &jr)
	if uerr != nil do return {}, false

	r: Recipe
	r.name = jr.name
	r.seed = jr.seed

	for js in jr.steps {
		st, type_ok := string_to_step_type(js.type)
		if !type_ok do continue
		append(&r.steps, Gen_Step{
			type            = st,
			seed_rooms      = js.seed_rooms,
			grow_clusters   = js.grow_clusters,
			connect_mst     = js.connect_mst,
			add_loops       = js.add_loops,
			widen_corridors = js.widen_corridors,
			bsp_partition   = js.bsp_partition,
			fill_dead_ends  = js.fill_dead_ends,
			place_grid      = js.place_grid,
			room_corridor   = js.room_corridor,
			define_area     = js.define_area,
			pack_rooms      = js.pack_rooms,
			connect_doors   = js.connect_doors,
			area_id         = js.area_id,
			area_exclude    = js.area_exclude,
		})
	}

	// Fix up area_id for legacy recipes: if no Define_Area steps exist,
	// all area_ids should be -1 (no constraint). This handles old JSON files
	// that don't have the area_id field (which defaults to 0 on unmarshal).
	has_define_area := false
	for s in r.steps {
		if s.type == .Define_Area {
			has_define_area = true
			break
		}
	}
	if !has_define_area {
		for &s in r.steps {
			s.area_id = -1
		}
	}

	return r, true
}

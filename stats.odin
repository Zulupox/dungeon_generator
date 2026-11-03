package dungeon_generator

import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

import imgui "libs/odin-imgui"

// ---------------------------------------------------------------------------
// Dungeon analysis: connectivity and layout stats
//
// Connections follow the Merge Room Walls display setting, so the stats match what you
// see (the layout graph and its connection rule are in layout.odin).
// ---------------------------------------------------------------------------

Dungeon_Stats :: struct {
	rooms:             int,
	room_cells:        int,
	corridor_cells:    int,
	coverage:          f32, // fraction of the grid that is room or corridor
	groups:            int, // groups of rooms that can reach each other
	unreachable_rooms: int, // rooms outside the largest group
	isolated_rooms:    int, // rooms with no way in or out
	dead_end_rooms:    int, // rooms with exactly one way in
	loops:             int, // independent cycles in the layout graph
	longest_path:      int, // most room-to-room steps on a shortest route between two rooms
	dead_ends:         int, // corridor cells with exactly one open side
	stray_corridors:   int, // corridor cells that reach no room
	// From an Assign Roles step (zero without one)
	has_roles:         bool,
	path_to_boss:      int, // room steps from start to boss with every lock open
	locks:             int, // locks placed
	locks_requested:   int,
	unsolvable:        int, // 1 if the boss can't be reached by collecting keys from the start
}

// Per-cell flags for the problem overlay
STAT_UNREACHABLE :: u8(1 << 0) // room cell outside the largest group
STAT_DEAD_END    :: u8(1 << 1)
STAT_PATH_END    :: u8(1 << 2) // room cell at one end of the longest path
STAT_STRAY       :: u8(1 << 3)

// Analyze the dungeon. If flags is given (one per grid cell) it is filled with STAT_* bits.
// Connections follow the Merge Room Walls setting (see layout.odin).
dungeon_analyze :: proc(d: ^Dungeon, flags: []u8 = nil) -> (s: Dungeon_Stats) {
	context.allocator = context.temp_allocator
	W := d.config.grid_width
	n := len(d.grid)

	g := layout_graph_build(d, !merge_room_walls)
	R := g.rooms
	V := len(g.adj)
	s.rooms = R
	s.room_cells = g.room_cells
	s.corridor_cells = g.corridor_cells
	s.coverage = f32(s.room_cells + s.corridor_cells) / f32(max(n, 1))

	for r in 0 ..< R {
		switch len(g.adj[r]) {
		case 0: s.isolated_rooms += 1
		case 1: s.dead_end_rooms += 1
		}
	}

	// Connected components; a group is a component with at least one room
	comp := make([]int, V)
	slice.fill(comp, -1)
	comp_rooms := make([dynamic]int)
	queue := make([dynamic]int, 0, V)
	for root in 0 ..< V {
		if comp[root] >= 0 do continue
		c := len(comp_rooms)
		append(&comp_rooms, 0)
		comp[root] = c
		clear(&queue)
		append(&queue, root)
		for head := 0; head < len(queue); head += 1 {
			v := queue[head]
			if v < R do comp_rooms[c] += 1
			for ei in g.adj[v] {
				nb := layout_other(g.edges[ei], v)
				if comp[nb] >= 0 do continue
				comp[nb] = c
				append(&queue, nb)
			}
		}
	}
	main_comp := 0
	for rooms, c in comp_rooms {
		if rooms > 0 do s.groups += 1
		if rooms > comp_rooms[main_comp] do main_comp = c
	}
	s.unreachable_rooms = R - (R > 0 ? comp_rooms[main_comp] : 0)
	s.loops = len(g.edges) - V + len(comp_rooms)

	// Longest shortest route between two rooms, in room steps (two edges each)
	path_a, path_b := -1, -1
	for root in 0 ..< R {
		dist, _ := layout_distances(&g, root)
		for r in 0 ..< R {
			if dist[r] / 2 > s.longest_path {
				s.longest_path = dist[r] / 2
				path_a, path_b = root, r
			}
		}
	}

	// Corridor dead ends, and corridor networks that touch no room
	for &cell, i in d.grid {
		if cell.cell_type != .Corridor && cell.cell_type != .Door do continue
		open := 0
		for dir in Direction {
			if _, _, ok := layout_edge_open(d, g.doors, g.strict, i % W, i / W, dir); ok do open += 1
		}
		if open == 1 {
			s.dead_ends += 1
			if flags != nil do flags[i] |= STAT_DEAD_END
		}
		if len(g.adj[g.node_of[i]]) == 0 {
			s.stray_corridors += 1
			if flags != nil do flags[i] |= STAT_STRAY
		}
	}

	if flags != nil {
		for v, i in g.node_of {
			if v < 0 || v >= R do continue
			if comp[v] != main_comp do flags[i] |= STAT_UNREACHABLE
			if v == path_a || v == path_b do flags[i] |= STAT_PATH_END
		}
	}

	if d.roles.assigned {
		s.has_roles = true
		solvable: bool
		solvable, s.path_to_boss = roles_simulate(d, &g)
		s.unsolvable = solvable ? 0 : 1
		s.locks = len(d.roles.locks)
		s.locks_requested = d.roles.locks_requested
	}
	return
}

// ---------------------------------------------------------------------------
// Stats for the dungeon on screen (recomputed only when generation moves on)
// ---------------------------------------------------------------------------

Stats_Key :: struct {
	grid:     rawptr,
	seed:     u64,
	modules:  int,
	step:     int,
	progress: int,
	gen_done: bool,
	showcase: bool,
	merge:    bool,
}

current_stats: Dungeon_Stats
current_stats_flags: [dynamic]u8
current_stats_key: Stats_Key
stats_show_overlay: bool = false

stats_update_current :: proc(d: ^Dungeon) {
	key := Stats_Key{
		grid     = raw_data(d.grid),
		seed     = d.actual_seed,
		modules  = len(d.modules),
		step     = d.current_step,
		progress = d.step_progress,
		gen_done = d.gen_done,
		showcase = d.showcase,
		merge    = merge_room_walls,
	}
	if key == current_stats_key && len(current_stats_flags) == len(d.grid) do return
	current_stats_key = key
	resize(&current_stats_flags, len(d.grid))
	slice.zero(current_stats_flags[:])
	current_stats = dungeon_analyze(d, current_stats_flags[:])
}

// Problem markers drawn on top of the ceilings (call inside Mode3D).
stats_render_3d :: proc(d: ^Dungeon) {
	if !stats_show_overlay || len(current_stats_flags) != len(d.grid) do return
	cs := d.config.cell_size
	y := d.config.wall_height + 0.06
	W := d.config.grid_width
	for flag, i in current_stats_flags {
		if flag == 0 do continue
		pos := rl.Vector3{(f32(i % W) + 0.5) * cs, y, (f32(i / W) + 0.5) * cs}
		if flag & STAT_UNREACHABLE != 0 do rl.DrawCube(pos, cs * 0.9, 0.04, cs * 0.9, STATS_COLOR_UNREACHABLE)
		if flag & STAT_PATH_END != 0    do rl.DrawCube(pos, cs * 0.9, 0.04, cs * 0.9, STATS_COLOR_PATH_END)
		if flag & STAT_STRAY != 0       do rl.DrawCube(pos, cs * 0.7, 0.05, cs * 0.7, STATS_COLOR_STRAY)
		if flag & STAT_DEAD_END != 0    do rl.DrawCube(pos, cs * 0.45, 0.3, cs * 0.45, STATS_COLOR_DEAD_END)
	}
}

STATS_COLOR_UNREACHABLE :: rl.Color{230, 60, 60, 170}
STATS_COLOR_PATH_END    :: rl.Color{80, 200, 255, 170}
STATS_COLOR_STRAY       :: rl.Color{200, 90, 220, 220}
STATS_COLOR_DEAD_END    :: rl.Color{255, 160, 40, 255}

// ---------------------------------------------------------------------------
// Batch runs: generate a recipe over many seeds on a private dungeon
// ---------------------------------------------------------------------------

Batch_Result :: struct {
	seed:  u64,
	stats: Dungeon_Stats,
}

Batch_State :: struct {
	runs:        int, // requested number of seeds
	start_seed:  int,
	running:     bool,
	dungeon:     Dungeon, // private copy; only valid while running
	recipe_name: string,
	results:     [dynamic]Batch_Result,
	gen_time:    time.Duration, // total generation + analysis time
}

batch := Batch_State{runs = 50, start_seed = 1}

BATCH_FRAME_BUDGET :: 12 * time.Millisecond

batch_start :: proc(d: ^Dungeon) {
	if batch.running do return
	clear(&batch.results)
	delete(batch.recipe_name)
	batch.recipe_name = strings.clone(d.recipe.name)
	batch.gen_time = 0
	batch.start_seed = max(batch.start_seed, 1) // seed 0 means random
	batch.dungeon = dungeon_create(d.config)
	batch.dungeon.recipe = recipe_clone(&d.recipe)
	batch.running = true
}

batch_stop :: proc() {
	if !batch.running do return
	dungeon_destroy(&batch.dungeon)
	batch.running = false
}

// Run as many seeds as fit in the frame budget. Pauses while the main dungeon is
// mid-generation, since both share the global random generator.
batch_update :: proc() {
	if !batch.running || !state.dungeon.gen_done do return
	frame_start := time.tick_now()
	for time.tick_since(frame_start) < BATCH_FRAME_BUDGET {
		if len(batch.results) >= batch.runs {
			batch_stop()
			return
		}
		seed := u64(batch.start_seed + len(batch.results))
		run_start := time.tick_now()
		batch.dungeon.recipe.seed = seed
		dungeon_generate_full(&batch.dungeon)
		append(&batch.results, Batch_Result{seed = seed, stats = dungeon_analyze(&batch.dungeon)})
		batch.gen_time += time.tick_since(run_start)
	}
}

batch_destroy :: proc() {
	batch_stop()
	delete(batch.results)
	delete(batch.recipe_name)
	delete(current_stats_flags)
}

// ---------------------------------------------------------------------------
// Stats tab
// ---------------------------------------------------------------------------

STAT_ROWS := [?]struct {
	label: cstring,
	tip:   cstring,
	bad:   bool, // above zero is a problem
}{
	{"Rooms",          "Distinct rooms (joined rooms count once)", false},
	{"Coverage %",     "Share of the grid that is room or corridor", false},
	{"Groups",         "Groups of rooms that can reach each other.\n1 = everything is connected", false},
	{"Unreachable",    "Rooms outside the largest group", true},
	{"Isolated",       "Rooms with no way in or out", true},
	{"Dead-end rooms", "Rooms with only one way in\n(one doorway, or one corridor network)", false},
	{"Loops",          "Independent loops you could walk around.\n0 = a tree: only one route between any two rooms", false},
	{"Longest path",   "Most room-to-room steps needed between two rooms", false},
	{"Dead ends",      "Corridor cells with only one open side", true},
	{"Stray corridor", "Corridor cells that lead to no room", true},
	{"Path to boss",   "Room steps from start to boss (Assign Roles)", false},
	{"Locks",          "Locked doors placed (Assign Roles)", false},
	{"Unsolvable",     "1 if collecting keys from the start\ncan't open the way to the boss", true},
}

// Coverage has one decimal; the other rows are whole numbers.
stats_format :: proc(row: int, v: f32) -> cstring {
	return row == 1 ? fmt.ctprintf("%.1f", v) : fmt.ctprintf("%d", int(v))
}

stats_values :: proc(s: Dungeon_Stats) -> [len(STAT_ROWS)]f32 {
	return {
		f32(s.rooms), s.coverage * 100, f32(s.groups), f32(s.unreachable_rooms),
		f32(s.isolated_rooms), f32(s.dead_end_rooms), f32(s.loops),
		f32(s.longest_path), f32(s.dead_ends), f32(s.stray_corridors),
		f32(s.path_to_boss), f32(s.locks), f32(s.unsolvable),
	}
}

STATS_TEXT_BAD :: imgui.Vec4{1.0, 0.45, 0.4, 1.0}

color_to_vec4 :: proc(col: rl.Color) -> imgui.Vec4 {
	return {f32(col.r) / 255, f32(col.g) / 255, f32(col.b) / 255, 1}
}

ui_stats_tab :: proc(d: ^Dungeon) {
	// ---- Current dungeon ----
	imgui.TextColored({0.8, 0.9, 1.0, 1.0}, "This dungeon")
	imgui.Separator()
	s := current_stats
	if !d.gen_done {
		imgui.TextDisabled("(generation in progress)")
	}
	values := stats_values(s)
	if imgui.BeginTable("##stats_now", 2, imgui.TableFlags_RowBg | imgui.TableFlags_SizingStretchProp) {
		for row, i in STAT_ROWS {
			imgui.TableNextRow()
			imgui.TableNextColumn()
			imgui.Text("%s", row.label)
			if imgui.IsItemHovered() do imgui.SetTooltip("%s", row.tip)
			imgui.TableNextColumn()
			text := stats_format(i, values[i])
			if row.bad && values[i] > 0 {
				imgui.TextColored(STATS_TEXT_BAD, "%s", text)
			} else {
				imgui.Text("%s", text)
			}
		}
		imgui.EndTable()
	}
	if merge_room_walls {
		imgui.TextDisabled("Touching rooms count as connected\n(Merge Room Walls is on)")
	} else {
		imgui.TextDisabled("Rooms connect only through doors\n(Merge Room Walls is off)")
	}

	imgui.Checkbox("Show on map", &stats_show_overlay)
	if stats_show_overlay {
		imgui.TextColored(color_to_vec4(STATS_COLOR_UNREACHABLE), "  Unreachable room")
		imgui.TextColored(color_to_vec4(STATS_COLOR_PATH_END),    "  Longest path ends")
		imgui.TextColored(color_to_vec4(STATS_COLOR_DEAD_END),    "  Dead end")
		imgui.TextColored(color_to_vec4(STATS_COLOR_STRAY),       "  Stray corridor")
	}

	// ---- Batch ----
	imgui.Spacing()
	imgui.TextColored({0.8, 0.9, 1.0, 1.0}, "Batch over seeds")
	imgui.Separator()

	imgui.BeginDisabled(batch.running)
	ui_drag_int("Runs", &batch.runs, 1, 1000)
	ui_drag_int("First seed", &batch.start_seed, 1, 1_000_000)
	imgui.EndDisabled()

	if batch.running {
		done := len(batch.results)
		imgui.ProgressBar(f32(done) / f32(max(batch.runs, 1)), {-1, 0}, fmt.ctprintf("%d / %d", done, batch.runs))
		if !d.gen_done do imgui.TextDisabled("(paused while this dungeon generates)")
		if imgui.Button("Stop", {-1, 0}) do batch_stop()
	} else {
		imgui.BeginDisabled(!d.gen_done)
		if imgui.Button("Run batch", {-1, 0}) do batch_start(d)
		imgui.EndDisabled()
		if imgui.IsItemHovered() do imgui.SetTooltip("Generate the current recipe with seeds First seed .. First seed + Runs - 1")
	}

	n := len(batch.results)
	if n == 0 do return

	imgui.Text("%s: %d runs, %.1f ms each", fmt.ctprintf("%s", batch.recipe_name), c.int(n),
		time.duration_milliseconds(batch.gen_time) / f64(n))

	sum, lo, hi: [len(STAT_ROWS)]f32
	connected, solvable, with_roles, problems := 0, 0, 0, 0
	for &res, ri in batch.results {
		v := stats_values(res.stats)
		for i in 0 ..< len(v) {
			sum[i] += v[i]
			lo[i] = ri == 0 ? v[i] : min(lo[i], v[i])
			hi[i] = ri == 0 ? v[i] : max(hi[i], v[i])
		}
		if res.stats.groups <= 1 do connected += 1
		if res.stats.has_roles {
			with_roles += 1
			if res.stats.unsolvable == 0 do solvable += 1
		}
		if stats_has_problem(res.stats) do problems += 1
	}

	ratio_line :: proc(label: string, good, total: int) {
		text := fmt.ctprintf("%s: %d / %d (%.0f%%)", label, good, total, 100 * f32(good) / f32(total))
		if good < total {
			imgui.TextColored(STATS_TEXT_BAD, "%s", text)
		} else {
			imgui.Text("%s", text)
		}
	}
	ratio_line("Fully connected", connected, n)
	if with_roles > 0 {
		ratio_line("Solvable", solvable, with_roles)
		requested := batch.results[0].stats.locks_requested
		imgui.Text("Locks placed: %.1f of %d asked", sum[len(STAT_ROWS) - 2] / f32(n), c.int(requested))
	}

	if imgui.BeginTable("##stats_batch", 4, imgui.TableFlags_RowBg | imgui.TableFlags_SizingStretchProp) {
		imgui.TableSetupColumn("Metric")
		imgui.TableSetupColumn("Avg")
		imgui.TableSetupColumn("Min")
		imgui.TableSetupColumn("Max")
		imgui.TableHeadersRow()
		for row, i in STAT_ROWS {
			imgui.TableNextRow()
			imgui.TableNextColumn()
			imgui.Text("%s", row.label)
			if imgui.IsItemHovered() do imgui.SetTooltip("%s", row.tip)
			imgui.TableNextColumn()
			imgui.Text("%s", fmt.ctprintf("%.1f", sum[i] / f32(n)))
			imgui.TableNextColumn()
			imgui.Text("%s", stats_format(i, lo[i]))
			imgui.TableNextColumn()
			if row.bad && hi[i] > 0 {
				imgui.TextColored(STATS_TEXT_BAD, "%s", stats_format(i, hi[i]))
			} else {
				imgui.Text("%s", stats_format(i, hi[i]))
			}
		}
		imgui.EndTable()
	}

	// Seeds that left rooms unreachable or can't be completed; click one to generate it here
	if problems > 0 {
		imgui.Text("Problem seeds (click to load):")
		shown := 0
		for &res in batch.results {
			if !stats_has_problem(res.stats) do continue
			if shown >= 30 {
				imgui.TextDisabled("... and %d more", c.int(problems - shown))
				break
			}
			if shown % 5 != 0 do imgui.SameLine()
			if imgui.SmallButton(fmt.ctprintf("%d", res.seed)) {
				d.recipe.seed = res.seed
				dungeon_generate_full(d)
				stats_show_overlay = true
			}
			shown += 1
		}
	}
}

// Disconnected, or (with roles) not completable.
stats_has_problem :: proc(s: Dungeon_Stats) -> bool {
	return s.groups > 1 || s.unsolvable > 0
}

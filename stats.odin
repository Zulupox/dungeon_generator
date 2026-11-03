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
// Follows the Merge Room Walls display setting, so the stats match what you see:
// - on:  any two touching room or corridor cells connect
// - off: corridor cells connect freely, cells of the same room connect, and anything
//        else (room to room, room to corridor) only through a connected door on that edge
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
}

// Per-cell flags for the problem overlay
STAT_UNREACHABLE :: u8(1 << 0) // room cell outside the largest group
STAT_DEAD_END    :: u8(1 << 1)
STAT_PATH_END    :: u8(1 << 2) // room cell at one end of the longest path
STAT_STRAY       :: u8(1 << 3)

DIR_OFFSETS := [Direction][2]int{
	.North = {0, -1},
	.South = {0, 1},
	.East  = {1, 0},
	.West  = {-1, 0},
}

// Can you walk from cell (x, y) to its neighbour in direction dir?
// doors holds a bit per direction for each room cell with a connected door.
stats_edge_open :: proc(d: ^Dungeon, doors: []u8, x, y: int, dir: Direction) -> (nx, ny: int, ok: bool) {
	off := DIR_OFFSETS[dir]
	nx, ny = x + off.x, y + off.y
	if !grid_in_bounds(d, nx, ny) do return
	W := d.config.grid_width
	a := &d.grid[y * W + x]
	b := &d.grid[ny * W + nx]
	if a.cell_type == .Empty || b.cell_type == .Empty do return
	// Room cells without a module are solid walls (Wall Border)
	if (a.cell_type == .Room && a.module_id < 0) || (b.cell_type == .Room && b.module_id < 0) do return
	if merge_room_walls do return nx, ny, true

	a_room := a.cell_type == .Room
	b_room := b.cell_type == .Room
	if !a_room && !b_room do return nx, ny, true
	if a_room && b_room && a.module_id == b.module_id do return nx, ny, true

	ok = doors[y * W + x] & (1 << u8(dir)) != 0 ||
	     doors[ny * W + nx] & (1 << u8(opposite_direction(dir))) != 0
	return
}

// Analyze the dungeon. If flags is given (one per grid cell) it is filled with STAT_* bits.
//
// The layout is turned into a graph: one node per room, one per connected corridor
// network, and a link node between rooms that open straight into each other. Every
// step from one room to the next is then two edges, wherever it goes through.
dungeon_analyze :: proc(d: ^Dungeon, flags: []u8 = nil) -> (s: Dungeon_Stats) {
	context.allocator = context.temp_allocator
	W := d.config.grid_width
	n := len(d.grid)

	doors := make([]u8, n)
	for &m in d.modules {
		for di in m.connected_doors {
			slot := m.rot_doors[di]
			gx, gy := door_global(slot, m.grid_x, m.grid_y)
			if grid_in_bounds(d, gx, gy) do doors[gy * W + gx] |= 1 << u8(slot.direction)
		}
	}

	// Graph node of each cell: rooms are the distinct module ids on the grid (Join Rooms
	// merges ids), numbered first; corridor networks are numbered after them.
	node_of := make([]int, n)
	slice.fill(node_of, -1)
	id_to_room := make([]int, len(d.modules))
	slice.fill(id_to_room, -1)
	R := 0
	for &cell, i in d.grid {
		switch cell.cell_type {
		case .Room:
			id := cell.module_id
			if id < 0 || id >= len(d.modules) do continue // wall cell
			if id_to_room[id] < 0 {
				id_to_room[id] = R
				R += 1
			}
			node_of[i] = id_to_room[id]
			s.room_cells += 1
		case .Corridor, .Door:
			s.corridor_cells += 1
		case .Empty:
		}
	}
	s.rooms = R
	s.coverage = f32(s.room_cells + s.corridor_cells) / f32(max(n, 1))

	V := R
	queue := make([dynamic]int, 0, n)
	for &cell, i in d.grid {
		if (cell.cell_type != .Corridor && cell.cell_type != .Door) || node_of[i] >= 0 do continue
		node_of[i] = V
		clear(&queue)
		append(&queue, i)
		for head := 0; head < len(queue); head += 1 {
			ci := queue[head]
			for dir in Direction {
				nx, ny, ok := stats_edge_open(d, doors, ci % W, ci / W, dir)
				if !ok do continue
				ni := ny * W + nx
				if node_of[ni] >= 0 || d.grid[ni].cell_type == .Room do continue
				node_of[ni] = V
				append(&queue, ni)
			}
		}
		V += 1
	}

	// Edges between different nodes, from every open cell edge (each pair once)
	pairs := make(map[[2]int]bool)
	for i in 0 ..< n {
		a := node_of[i]
		if a < 0 do continue
		for dir in ([2]Direction{.East, .South}) {
			nx, ny, ok := stats_edge_open(d, doors, i % W, i / W, dir)
			if !ok do continue
			b := node_of[ny * W + nx]
			if b < 0 || b == a do continue
			pairs[{min(a, b), max(a, b)}] = true
		}
	}
	adj := make([dynamic][dynamic]int, V)
	for pair in pairs {
		a, b := pair[0], pair[1]
		if a < R && b < R {
			// room opens straight into room: add a link node so it is two edges too
			append(&adj, make([dynamic]int))
			l := len(adj) - 1
			append(&adj[a], l); append(&adj[l], a)
			append(&adj[b], l); append(&adj[l], b)
		} else {
			append(&adj[a], b)
			append(&adj[b], a)
		}
	}
	V = len(adj)

	edges := 0
	for v in 0 ..< V do edges += len(adj[v])
	edges /= 2
	for r in 0 ..< R {
		switch len(adj[r]) {
		case 0: s.isolated_rooms += 1
		case 1: s.dead_end_rooms += 1
		}
	}

	// Connected components; a group is a component with at least one room
	comp := make([]int, V)
	slice.fill(comp, -1)
	comp_rooms := make([dynamic]int)
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
			for nb in adj[v] {
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
	s.loops = edges - V + len(comp_rooms)

	// Longest shortest route between two rooms, in room steps (two edges each)
	dist := make([]int, V)
	path_a, path_b := -1, -1
	for root in 0 ..< R {
		slice.fill(dist, -1)
		dist[root] = 0
		clear(&queue)
		append(&queue, root)
		for head := 0; head < len(queue); head += 1 {
			v := queue[head]
			if v < R && dist[v] / 2 > s.longest_path {
				s.longest_path = dist[v] / 2
				path_a, path_b = root, v
			}
			for nb in adj[v] {
				if dist[nb] >= 0 do continue
				dist[nb] = dist[v] + 1
				append(&queue, nb)
			}
		}
	}

	// Corridor dead ends, and corridor networks that touch no room
	for &cell, i in d.grid {
		if cell.cell_type != .Corridor && cell.cell_type != .Door do continue
		open := 0
		for dir in Direction {
			if _, _, ok := stats_edge_open(d, doors, i % W, i / W, dir); ok do open += 1
		}
		if open == 1 {
			s.dead_ends += 1
			if flags != nil do flags[i] |= STAT_DEAD_END
		}
		if len(adj[node_of[i]]) == 0 {
			s.stray_corridors += 1
			if flags != nil do flags[i] |= STAT_STRAY
		}
	}

	if flags != nil {
		for v, i in node_of {
			if v < 0 || v >= R do continue
			if comp[v] != main_comp do flags[i] |= STAT_UNREACHABLE
			if v == path_a || v == path_b do flags[i] |= STAT_PATH_END
		}
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
	connected := 0
	for &res, ri in batch.results {
		v := stats_values(res.stats)
		for i in 0 ..< len(v) {
			sum[i] += v[i]
			lo[i] = ri == 0 ? v[i] : min(lo[i], v[i])
			hi[i] = ri == 0 ? v[i] : max(hi[i], v[i])
		}
		if res.stats.groups <= 1 do connected += 1
	}

	connected_text := fmt.ctprintf("Fully connected: %d / %d (%.0f%%)", connected, n, 100 * f32(connected) / f32(n))
	if connected < n {
		imgui.TextColored(STATS_TEXT_BAD, "%s", connected_text)
	} else {
		imgui.Text("%s", connected_text)
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

	// Seeds that left rooms unreachable; click one to generate it here
	if connected < n {
		imgui.Text("Disconnected seeds (click to load):")
		shown := 0
		for &res in batch.results {
			if res.stats.groups <= 1 do continue
			if shown >= 30 {
				imgui.TextDisabled("... and %d more", c.int(n - connected - shown))
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

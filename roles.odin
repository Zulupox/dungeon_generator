package dungeon_generator

import "core:fmt"
import "core:slice"
import rl "vendor:raylib"

import imgui "libs/odin-imgui"

// ---------------------------------------------------------------------------
// Room roles: start, boss, locks with their keys, and treasure
//
// Assigned by the Assign Roles step on the finished layout. Locks only go on
// connections every route to the boss must pass (bridges in the layout graph), so
// each one really gates progress; if there are fewer such spots than requested, fewer
// locks are placed. Rooms use the grid's module ids (Join Rooms merges them).
// ---------------------------------------------------------------------------

Room_Role :: enum u8 {
	None,
	Start,
	Boss,
	Key,
	Treasure,
}

// A cell edge closed by a lock: between (x, y) and its neighbour in direction dir.
Lock_Opening :: struct {
	x, y: int,
	dir:  Direction,
}

Dungeon_Roles :: struct {
	assigned:        bool,
	start:           int,                            // module id, -1 = none
	boss:            int,                            // module id, -1 = none
	keys:            [dynamic]int,                   // module holding key i, which opens locks[i]
	locks:           [dynamic][dynamic]Lock_Opening, // lock i, ordered from start to boss
	treasure:        [dynamic]int,                   // module ids
	main_path:       [dynamic]int,                   // module ids of the rooms from start to boss
	locks_requested: int,
}

MAX_LOCKS :: 4

roles_clear :: proc(r: ^Dungeon_Roles) {
	clear(&r.keys)
	for &l in r.locks do delete(l)
	clear(&r.locks)
	clear(&r.treasure)
	clear(&r.main_path)
	r.assigned = false
	r.start, r.boss = -1, -1
	r.locks_requested = 0
}

roles_destroy :: proc(r: ^Dungeon_Roles) {
	roles_clear(r)
	delete(r.keys)
	delete(r.locks)
	delete(r.treasure)
	delete(r.main_path)
}

// Role of a module (resolving Join Rooms merges); key is the key index for .Key.
module_role :: proc(d: ^Dungeon, module_id: int) -> (role: Room_Role, key: int) {
	r := &d.roles
	if !r.assigned || module_id < 0 || module_id >= len(d.modules) do return .None, -1
	id := grid_module_id(d, module_id)
	if id == r.start do return .Start, -1
	if id == r.boss do return .Boss, -1
	for k, i in r.keys do if k == id do return .Key, i
	for t in r.treasure do if t == id do return .Treasure, -1
	return .None, -1
}

// Module id on the grid at a module's cells (differs after Join Rooms).
grid_module_id :: proc(d: ^Dungeon, module_id: int) -> int {
	m := &d.modules[module_id]
	for filled, ci in m.rot_mask {
		if !filled do continue
		x, y := m.grid_x + ci % m.rot_width, m.grid_y + ci / m.rot_width
		if grid_in_bounds(d, x, y) do return d.grid[grid_index(d, x, y)].module_id
		break
	}
	return module_id
}

// Edges whose removal disconnects the graph (Tarjan, iterative). Temp-allocated.
layout_bridges :: proc(g: ^Layout_Graph) -> []bool {
	V := len(g.adj)
	bridge := make([]bool, len(g.edges), context.temp_allocator)
	disc := make([]int, V, context.temp_allocator)
	low := make([]int, V, context.temp_allocator)
	slice.fill(disc, -1)
	Frame :: struct {
		v, parent_edge, next: int,
	}
	stack := make([dynamic]Frame, context.temp_allocator)
	timer := 0
	for root in 0 ..< V {
		if disc[root] >= 0 do continue
		disc[root], low[root] = timer, timer
		timer += 1
		append(&stack, Frame{v = root, parent_edge = -1})
		for len(stack) > 0 {
			top := &stack[len(stack) - 1]
			if top.next < len(g.adj[top.v]) {
				ei := g.adj[top.v][top.next]
				top.next += 1
				if ei == top.parent_edge do continue
				w := layout_other(g.edges[ei], top.v)
				if disc[w] < 0 {
					disc[w], low[w] = timer, timer
					timer += 1
					append(&stack, Frame{v = w, parent_edge = ei})
				} else {
					low[top.v] = min(low[top.v], disc[w])
				}
			} else {
				done := pop(&stack)
				if len(stack) > 0 {
					parent := &stack[len(stack) - 1]
					low[parent.v] = min(low[parent.v], low[done.v])
					if low[done.v] > disc[parent.v] do bridge[done.parent_edge] = true
				}
			}
		}
	}
	return bridge
}

// ---------------------------------------------------------------------------
// Assign Roles step
// ---------------------------------------------------------------------------

execute_assign_roles :: proc(d: ^Dungeon, params: ^Assign_Roles_Params) {
	assign_roles(d, params)
	d.step_done = true
}

assign_roles :: proc(d: ^Dungeon, params: ^Assign_Roles_Params) {
	r := &d.roles
	roles_clear(r)
	r.assigned = true
	r.locks_requested = clamp(params.locks, 0, MAX_LOCKS)

	// Doors facing corridors are otherwise only marked when generation finishes
	mark_connected_doors(d)
	g := layout_graph_build(d, true)
	R := g.rooms
	if R == 0 do return

	room_cells := make([]int, R, context.temp_allocator)
	for v in g.node_of do if v >= 0 && v < R do room_cells[v] += 1
	is_dead_end :: proc(g: ^Layout_Graph, room: int) -> bool { return len(g.adj[room]) == 1 }

	// ---- Roles asked for by a room-graph profile ----
	start, boss := -1, -1
	wanted_treasure := make([dynamic]int, context.temp_allocator)
	if len(d.room_graphs) > 0 && room_graph_is_placed(&d.room_graphs[0]) {
		rg := &d.room_graphs[0]
		p := &room_profiles[rg.profile]
		for node in rg.nodes {
			if node.module_id < 0 do continue
			room := g.module_room[grid_module_id(d, node.module_id)]
			if room < 0 do continue
			#partial switch p.types[node.type].role {
			case .Start:    if start < 0 do start = room
			case .Boss:     if boss < 0 do boss = room
			case .Treasure: append(&wanted_treasure, room)
			}
		}
		if start < 0 {
			if entry := rg.nodes[rg.entry].module_id; entry >= 0 do start = g.module_room[grid_module_id(d, entry)]
		}
	}

	// ---- Start: profile, else a room in group "entrance", else one end of the longest path ----
	if start < 0 {
		for mi in get_group_modules(d, "entrance") {
			if room := g.module_room[grid_module_id(d, mi)]; room >= 0 {
				start = room
				break
			}
		}
	}
	if start < 0 {
		far_a, far_b, far := 0, 0, -1
		for a in 0 ..< R {
			dist, _ := layout_distances(&g, a)
			for b in 0 ..< R {
				if dist[b] > far {
					far_a, far_b, far = a, b, dist[b]
				}
			}
		}
		// Of the two ends, start at the one nearer the grid edge
		border_dist :: proc(d: ^Dungeon, m: ^Placed_Module) -> f32 {
			return min(m.center_x, m.center_y, f32(d.config.grid_width) - m.center_x, f32(d.config.grid_height) - m.center_y)
		}
		ma := &d.modules[g.room_module[far_a]]
		mb := &d.modules[g.room_module[far_b]]
		start = border_dist(d, ma) <= border_dist(d, mb) ? far_a : far_b
	}
	dist, parent_edge := layout_distances(&g, start)

	// ---- Boss: profile, else far from the start, preferring a dead end, then size ----
	if boss < 0 || dist[boss] < 0 {
		best: f32 = -1
		for room in 0 ..< R {
			if room == start || dist[room] < 0 do continue
			score := f32(dist[room]) + (is_dead_end(&g, room) ? 2 : 0) + f32(room_cells[room]) * 0.01
			if score > best {
				best = score
				boss = room
			}
		}
	}
	r.start = g.room_module[start]
	if boss < 0 do return // a single room
	r.boss = g.room_module[boss]

	// ---- Main path: edges from start to boss ----
	path_edges := make([dynamic]int, context.temp_allocator)
	on_path := make([]bool, len(g.adj), context.temp_allocator)
	for v := boss; v != start; {
		ei := parent_edge[v]
		append(&path_edges, ei)
		on_path[v] = true
		v = layout_other(g.edges[ei], v)
	}
	on_path[start] = true
	slice.reverse(path_edges[:])
	for ei in path_edges {
		e := g.edges[ei]
		for v in ([2]int{e.a, e.b}) {
			if v < R && !slice.contains(r.main_path[:], g.room_module[v]) do append(&r.main_path, g.room_module[v])
		}
	}
	if len(r.main_path) == 0 do append(&r.main_path, r.start)

	// ---- Locks: bridges on the main path, spread out, the last one nearest the boss ----
	bridges := layout_bridges(&g)
	candidates := make([dynamic]int, context.temp_allocator)
	for ei, i in path_edges {
		if !bridges[ei] do continue
		// A room-to-room link is two edges (room, link, room); lock only the second
		if i + 1 < len(path_edges) {
			e, ne := g.edges[ei], g.edges[path_edges[i + 1]]
			link := e.a >= g.first_link ? e.a : e.b >= g.first_link ? e.b : -1
			if link >= 0 && (ne.a == link || ne.b == link) do continue
		}
		append(&candidates, ei)
	}
	chosen := make([dynamic]int, context.temp_allocator)
	want := min(r.locks_requested, len(candidates))
	for i in 0 ..< want {
		idx := (i + 1) * len(candidates) / want - 1
		append(&chosen, candidates[idx])
	}

	// ---- Keys: each in the area reachable before its lock, preferring newly opened
	// areas, dead ends and rooms off the main path. A lock without a room for its key is dropped.
	taken := make([]bool, R, context.temp_allocator)
	taken[start], taken[boss] = true, true
	blocked := make([]bool, len(g.edges), context.temp_allocator)
	prev_reach: []int
	for ei in chosen {
		blocked[ei] = true
		reach, _ := layout_distances(&g, start, blocked)
		blocked[ei] = false
		key, best := -1, -1
		for room in 0 ..< R {
			if taken[room] || reach[room] < 0 do continue
			score := reach[room]
			if prev_reach == nil || prev_reach[room] < 0 do score += 1000 // opened by the previous lock
			if is_dead_end(&g, room) do score += 50
			if !on_path[room] do score += 50
			if score > best {
				best = score
				key = room
			}
		}
		if key < 0 do continue
		taken[key] = true
		append(&r.keys, g.room_module[key])
		lock := make([dynamic]Lock_Opening)
		W := d.config.grid_width
		for op in g.edges[ei].openings do append(&lock, Lock_Opening{x = op.cell % W, y = op.cell / W, dir = op.dir})
		append(&r.locks, lock)
		prev_reach = reach
	}

	// ---- Treasure: profile rooms, then rooms off the main path: dead ends first,
	// farthest from the start first ----
	for room in wanted_treasure {
		if taken[room] do continue
		taken[room] = true
		append(&r.treasure, g.room_module[room])
	}
	Treasure_Candidate :: struct {
		room, score: int,
	}
	extra := make([dynamic]Treasure_Candidate, context.temp_allocator)
	for room in 0 ..< R {
		if taken[room] || on_path[room] || dist[room] < 0 do continue
		append(&extra, Treasure_Candidate{room, dist[room] + (is_dead_end(&g, room) ? 1000 : 0)})
	}
	slice.sort_by(extra[:], proc(a, b: Treasure_Candidate) -> bool { return a.score > b.score })
	for c in extra {
		if len(r.treasure) >= params.treasure do break
		append(&r.treasure, g.room_module[c.room])
	}
}

// ---------------------------------------------------------------------------
// Playthrough check (used by Stats): walk from the start, pick up keys, open their
// locks, repeat. Solvable if the boss is reached.
// ---------------------------------------------------------------------------

roles_simulate :: proc(d: ^Dungeon, g: ^Layout_Graph) -> (solvable: bool, path_to_boss: int) {
	r := &d.roles
	if !r.assigned || r.start < 0 do return false, 0
	if r.boss < 0 do return true, 0 // a single room: nothing to reach
	start := g.module_room[r.start]
	boss := g.module_room[r.boss]
	if start < 0 || boss < 0 do return false, 0

	// Edges each lock closes, found through its cell edges
	W := d.config.grid_width
	opening_edge := make(map[Layout_Opening]int, context.temp_allocator)
	for &e, ei in g.edges do for op in e.openings do opening_edge[op] = ei
	lock_edges := make([][dynamic]int, len(r.locks), context.temp_allocator)
	for &lock, li in r.locks {
		lock_edges[li] = make([dynamic]int, context.temp_allocator)
		for op in lock {
			if ei, ok := opening_edge[{cell = op.y * W + op.x, dir = op.dir}]; ok do append(&lock_edges[li], ei)
		}
	}

	open := make([]bool, len(r.locks), context.temp_allocator)
	blocked := make([]bool, len(g.edges), context.temp_allocator)
	for {
		for &edges, li in lock_edges do for ei in edges do blocked[ei] = !open[li]
		reach, _ := layout_distances(g, start, blocked)
		changed := false
		for k, li in r.keys {
			if open[li] do continue
			if room := g.module_room[k]; room >= 0 && reach[room] >= 0 {
				open[li] = true
				changed = true
			}
		}
		if !changed {
			solvable = reach[boss] >= 0
			break
		}
	}
	all, _ := layout_distances(g, start)
	return solvable, max(all[boss], 0) / 2
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

show_roles: bool = true

ROLE_COLOR_START    :: rl.Color{70, 220, 110, 255}
ROLE_COLOR_BOSS     :: rl.Color{235, 50, 50, 255}
ROLE_COLOR_TREASURE :: rl.Color{255, 200, 40, 255}
KEY_COLORS := [MAX_LOCKS]rl.Color{
	{255, 230, 60, 255},
	{60, 220, 255, 255},
	{240, 90, 240, 255},
	{150, 255, 90, 255},
}

role_color :: proc(role: Room_Role, key: int) -> rl.Color {
	switch role {
	case .Start:    return ROLE_COLOR_START
	case .Boss:     return ROLE_COLOR_BOSS
	case .Treasure: return ROLE_COLOR_TREASURE
	case .Key:      return KEY_COLORS[key % MAX_LOCKS]
	case .None:
	}
	return rl.WHITE
}

// Tint role rooms on top of the ceiling and draw locks as gates (call inside Mode3D).
roles_render_3d :: proc(d: ^Dungeon) {
	r := &d.roles
	if !show_roles || !r.assigned do return
	cs := d.config.cell_size
	wh := d.config.wall_height
	W := d.config.grid_width

	for cell, i in d.grid {
		if cell.cell_type != .Room || cell.module_id < 0 do continue
		role, key := module_role(d, cell.module_id)
		if role == .None do continue
		col := role_color(role, key)
		col.a = 110
		rl.DrawCube({(f32(i % W) + 0.5) * cs, wh + 0.07, (f32(i / W) + 0.5) * cs}, cs, 0.03, cs, col)
	}

	for &lock, li in r.locks {
		col := KEY_COLORS[li % MAX_LOCKS]
		for op in lock {
			off := DIR_OFFSETS[op.dir]
			pos := rl.Vector3{(f32(op.x) + 0.5 + f32(off.x) * 0.5) * cs, (wh + 0.3) * 0.5, (f32(op.y) + 0.5 + f32(off.y) * 0.5) * cs}
			size_x := off.x != 0 ? cs * 0.3 : cs * 0.95
			size_z := off.y != 0 ? cs * 0.3 : cs * 0.95
			rl.DrawCube(pos, size_x, wh + 0.3, size_z, col)
			rl.DrawCubeWires(pos, size_x, wh + 0.3, size_z, color_darken(col, 0.5))
		}
	}
}

// Text labels over role rooms and locks (drawn behind the UI panel).
roles_draw_labels :: proc(d: ^Dungeon, camera: rl.Camera3D) {
	r := &d.roles
	if !show_roles || !r.assigned do return
	draw_list := imgui.GetBackgroundDrawList()
	forward := rl.Vector3Normalize(camera.target - camera.position)
	cs := d.config.cell_size
	wh := d.config.wall_height

	// above: sit above the point (keeps lock gates visible); otherwise just below it,
	// leaving the centre for room-graph names
	label :: proc(dl: ^imgui.DrawList, camera: rl.Camera3D, forward, world: rl.Vector3, text: cstring, col: rl.Color, above := false) {
		if rl.Vector3DotProduct(world - camera.position, forward) <= 0 do return
		screen := rl.GetWorldToScreen(world, camera)
		if screen_behind_panel(screen) do return
		size := imgui.CalcTextSize(text)
		tl := imgui.Vec2{screen.x - size.x * 0.5 - 4, above ? screen.y - size.y - 14 : screen.y + 6}
		imgui.DrawList_AddRectFilled(dl, tl, {tl.x + size.x + 8, tl.y + size.y + 4}, imgui.ColorConvertFloat4ToU32({0, 0, 0, 0.7}), 3)
		imgui.DrawList_AddText(dl, {tl.x + 4, tl.y + 2}, imgui.ColorConvertFloat4ToU32(color_to_vec4(col)), text)
	}
	room_label :: proc(d: ^Dungeon, dl: ^imgui.DrawList, camera: rl.Camera3D, forward: rl.Vector3, module_id: int, text: cstring, col: rl.Color) {
		if module_id < 0 do return
		m := &d.modules[module_id]
		cs := d.config.cell_size
		label(dl, camera, forward, {m.center_x * cs, d.config.wall_height + 0.1, m.center_y * cs}, text, col)
	}

	room_label(d, draw_list, camera, forward, r.start, "Start", ROLE_COLOR_START)
	room_label(d, draw_list, camera, forward, r.boss, "Boss", ROLE_COLOR_BOSS)
	for k, i in r.keys do room_label(d, draw_list, camera, forward, k, fmt.ctprintf("Key %d", i + 1), KEY_COLORS[i % MAX_LOCKS])
	for t in r.treasure do room_label(d, draw_list, camera, forward, t, "Treasure", ROLE_COLOR_TREASURE)
	for &lock, li in r.locks {
		if len(lock) == 0 do continue
		op := lock[0]
		off := DIR_OFFSETS[op.dir]
		world := rl.Vector3{(f32(op.x) + 0.5 + f32(off.x) * 0.5) * cs, wh + 0.4, (f32(op.y) + 0.5 + f32(off.y) * 0.5) * cs}
		label(draw_list, camera, forward, world, fmt.ctprintf("Lock %d", li + 1), KEY_COLORS[li % MAX_LOCKS], above = true)
	}
}

// True if a screen point is under the side panel (labels there would show through it).
screen_behind_panel :: proc(screen: rl.Vector2) -> bool {
	return state.show_ui && screen.x < f32(PANEL_WIDTH)
}

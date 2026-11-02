package dungeon_generator

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"

// ---------------------------------------------------------------------------
// Place Graph - turn the best room graph into geometry
//
// Rooms are placed in BFS order from the entry. Each room docks wall-to-wall
// against an already-placed graph neighbour through a matching door pair. If
// no dock fits, the room goes to a free spot nearby and gets an A* corridor.
// Failed layouts are retried, then the next-best graph is tried.
// ---------------------------------------------------------------------------

// A candidate placement for one room.
Dock_Candidate :: struct {
	template_index: int,
	rot:            Rotation,
	gx, gy:         int,
	child_door:     int, // door index on the new room (-1 = not docked)
	parent_door:    int, // door index on the parent module
	score:          f32,
}

template_index_by_name :: proc(name: string) -> int {
	for &t, i in module_templates {
		if t.name == name do return i
	}
	return -1
}

// Template indices a room type may use; all templates if none of its names resolve.
room_type_templates :: proc(t: ^Room_Type_Def) -> []int {
	list := make([dynamic]int, 0, len(t.templates), context.temp_allocator)
	for name in t.templates {
		if ti := template_index_by_name(name); ti >= 0 do append(&list, ti)
	}
	if len(list) == 0 {
		for i in 0 ..< len(module_templates) do append(&list, i)
	}
	return list[:]
}

// Graph node shown by a placed module, if any.
graph_node_for_module :: proc(d: ^Dungeon, module_id: int) -> (g: ^Room_Graph, node: int, ok: bool) {
	if len(d.room_graphs) == 0 do return nil, -1, false
	g = &d.room_graphs[0]
	for n, i in g.nodes {
		if n.module_id == module_id do return g, i, true
	}
	return nil, -1, false
}

connect_door :: proc(m: ^Placed_Module, di: int, two_sided: bool) {
	if !module_door_connected(m, di) do append(&m.connected_doors, di)
	if two_sided && !module_door_two_sided(m, di) do append(&m.two_sided_doors, di)
}

// Paint a module's cells with its room type colour.
tint_module :: proc(d: ^Dungeon, module_id: int, color: Color4) {
	m := &d.modules[module_id]
	for ly in 0 ..< m.rot_height {
		for lx in 0 ..< m.rot_width {
			if !m.rot_mask[ly * m.rot_width + lx] do continue
			grid_get(d, m.grid_x + lx, m.grid_y + ly).color = color
		}
	}
}

// Door indices (a on ma, b on mb) of a two-sided pair where the modules touch, or -1.
find_touching_door_pair :: proc(d: ^Dungeon, ma, mb: int) -> (int, int) {
	a := &d.modules[ma]
	b := &d.modules[mb]
	for da in 0 ..< len(a.rot_doors) {
		slot := a.rot_doors[da]
		nx, ny := door_neighbor(slot, a.grid_x, a.grid_y)
		back := opposite_direction(slot.direction)
		for db in 0 ..< len(b.rot_doors) {
			bd := b.rot_doors[db]
			if bd.direction != back do continue
			bx, by := door_global(bd, b.grid_x, b.grid_y)
			if bx == nx && by == ny do return da, db
		}
	}
	return -1, -1
}

// Every cell of the mask plus a 1-cell ring around it is placeable/empty, so a corridor can reach it.
can_place_with_margin :: proc(d: ^Dungeon, mask: []bool, rw, rh, gx, gy: int) -> bool {
	if !can_place_module(d, mask, rw, rh, gx, gy) do return false
	for y in gy - 1 ..= gy + rh {
		for x in gx - 1 ..= gx + rw {
			if !grid_in_bounds(d, x, y) do return false
			if !grid_is_empty(d, x, y) do return false
		}
	}
	return true
}

// Count how many other placed graph neighbours of `node` this candidate would touch via a door pair.
dock_neighbour_bonus :: proc(d: ^Dungeon, g: ^Room_Graph, node, parent_node: int, rot_doors: []Door_Slot, gx, gy: int) -> int {
	bonus := 0
	for e in g.edges {
		other := e.a == node ? e.b : e.b == node ? e.a : -1
		if other < 0 || other == parent_node do continue
		om := g.nodes[other].module_id
		if om < 0 do continue
		o := &d.modules[om]
		for slot in rot_doors {
			nx, ny := door_neighbor(slot, gx, gy)
			back := opposite_direction(slot.direction)
			for od in o.rot_doors {
				if od.direction != back do continue
				ox, oy := door_global(od, o.grid_x, o.grid_y)
				if ox == nx && oy == ny do bonus += 1
			}
		}
	}
	return bonus
}

// Best docking candidate for `node` against the placed `parent_node`.
find_dock :: proc(d: ^Dungeon, g: ^Room_Graph, p: ^Room_Profile, node, parent_node: int, center_x, center_y: f32) -> (best: Dock_Candidate, found: bool) {
	context.allocator = context.temp_allocator // candidate masks and doors are scratch
	pm := &d.modules[g.nodes[parent_node].module_id]
	best.score = -1e9

	for ti in room_type_templates(&p.types[g.nodes[node].type]) {
		tmpl := &module_templates[ti]
		for rot in Rotation {
			mask, rw, rh := build_rotated_mask(tmpl, rot)
			doors := build_rotated_doors(tmpl, rot)

			for pd in 0 ..< len(pm.rot_doors) {
				if module_door_connected(pm, pd) do continue
				pslot := pm.rot_doors[pd]
				nx, ny := door_neighbor(pslot, pm.grid_x, pm.grid_y)
				want := opposite_direction(pslot.direction)

				for cd in 0 ..< len(doors) {
					if doors[cd].direction != want do continue
					gx := nx - doors[cd].local_x
					gy := ny - doors[cd].local_y
					if !can_place_module(d, mask[:], rw, rh, gx, gy) do continue

					// Prefer touching other graph neighbours, then staying compact
					cx := f32(gx) + f32(rw) * 0.5
					cy := f32(gy) + f32(rh) * 0.5
					dist := math.sqrt((cx - center_x) * (cx - center_x) + (cy - center_y) * (cy - center_y))
					score := f32(dock_neighbour_bonus(d, g, node, parent_node, doors[:], gx, gy)) * 10 - dist * 0.3 + rand.float32() * 2

					if score > best.score {
						best = {template_index = ti, rot = rot, gx = gx, gy = gy, child_door = cd, parent_door = pd, score = score}
						found = true
					}
				}
			}
		}
	}
	return
}

// A free spot near (cx, cy) with a margin for corridors. Searches outward in rings.
find_free_spot :: proc(d: ^Dungeon, p: ^Room_Profile, node_type: int, cx, cy: f32, min_r, max_r: int) -> (best: Dock_Candidate, found: bool) {
	context.allocator = context.temp_allocator
	templates := room_type_templates(&p.types[node_type])
	for r in min_r ..= max_r {
		for _ in 0 ..< 24 {
			ti := templates[rand.int_max(len(templates))]
			rot := Rotation(rand.int_max(4))
			mask, rw, rh := build_rotated_mask(&module_templates[ti], rot)
			angle := rand.float32() * 2 * math.PI
			gx := int(cx + math.cos(angle) * f32(r)) - rw / 2
			gy := int(cy + math.sin(angle) * f32(r)) - rh / 2
			if can_place_with_margin(d, mask[:], rw, rh, gx, gy) {
				return {template_index = ti, rot = rot, gx = gx, gy = gy, child_door = -1, parent_door = -1}, true
			}
		}
	}
	return {}, false
}

// Corridor between two placed modules using their closest free doors. True if a path was carved.
graph_corridor :: proc(d: ^Dungeon, ma, mb: int, manhattan_weight: f32) -> bool {
	job := find_best_door_pair(d, ma, mb)
	sx, sy := job.from_door_gx, job.from_door_gy
	tx, ty := job.to_door_gx, job.to_door_gy
	if !grid_is_passable(d, sx, sy) || !grid_is_passable(d, tx, ty) do return false

	path := astar_find_path(d, sx, sy, tx, ty, manhattan_weight)
	defer delete(path)
	adjacent := abs(sx - tx) + abs(sy - ty) <= 1
	if len(path) == 0 && !adjacent do return false

	connect_rooms_astar(d, job, manhattan_weight)
	return true
}

// Starting point for the entry room: centre of the active area, else the grid centre.
placement_center :: proc(d: ^Dungeon) -> (f32, f32) {
	if d.active_area_id >= 0 && !d.active_area_exclude {
		if area := find_area_by_id(d, d.active_area_id); area != nil {
			switch area.shape {
			case .Rectangle: return f32(area.x) + f32(area.w) * 0.5, f32(area.y) + f32(area.h) * 0.5
			case .Circle:    return f32(area.x) + 0.5, f32(area.y) + 0.5
			}
		}
	}
	return f32(d.config.grid_width) * 0.5, f32(d.config.grid_height) * 0.5
}

// Place every room of `g`. Returns false (leaving partial geometry) if some room couldn't be placed.
place_graph_attempt :: proc(d: ^Dungeon, g: ^Room_Graph, params: ^Place_Graph_Params) -> bool {
	p := &room_profiles[g.profile]
	for &n in g.nodes do n.module_id = -1
	for &e in g.edges do e.realized = false

	center_x, center_y := placement_center(d)

	place :: proc(d: ^Dungeon, g: ^Room_Graph, p: ^Room_Profile, node: int, c: Dock_Candidate) -> int {
		mi := stamp_module(d, c.template_index, c.gx, c.gy, c.rot)
		tint_module(d, mi, p.types[g.nodes[node].type].color)
		g.nodes[node].module_id = mi
		return mi
	}

	// Entry room
	{
		spot, ok := find_free_spot(d, p, g.nodes[g.entry].type, center_x, center_y, 0, 12)
		if !ok do return false
		place(d, g, p, g.entry, spot)
	}

	// BFS over all edges; each room docks to a placed neighbour (tree edges first)
	queue := make([dynamic]int, 0, len(g.nodes), context.temp_allocator)
	queued := make([]bool, len(g.nodes), context.temp_allocator)
	append(&queue, g.entry)
	queued[g.entry] = true

	for head := 0; head < len(queue); head += 1 {
		u := queue[head]
		if g.nodes[u].module_id < 0 {
			// Candidate parents: placed neighbours, tree edges first
			parents := make([dynamic]int, 0, 4, context.temp_allocator)
			for pass in 0 ..< 2 {
				for e in g.edges {
					if e.tree != (pass == 0) do continue
					other := e.a == u ? e.b : e.b == u ? e.a : -1
					if other >= 0 && g.nodes[other].module_id >= 0 do append(&parents, other)
				}
			}

			placed := false
			for parent in parents {
				c, ok := find_dock(d, g, p, u, parent, center_x, center_y)
				if !ok do continue
				mi := place(d, g, p, u, c)
				pm := g.nodes[parent].module_id
				connect_door(&d.modules[mi], c.child_door, true)
				connect_door(&d.modules[pm], c.parent_door, true)
				placed = true
				break
			}

			if !placed && params.corridor_fallback && len(parents) > 0 {
				pm := &d.modules[g.nodes[parents[0]].module_id]
				if spot, ok := find_free_spot(d, p, g.nodes[u].type, pm.center_x, pm.center_y, 4, 16); ok {
					place(d, g, p, u, spot)
					placed = true
				}
			}
			if !placed do return false
		}

		for e in g.edges {
			other := e.a == u ? e.b : e.b == u ? e.a : -1
			if other >= 0 && !queued[other] {
				queued[other] = true
				append(&queue, other)
			}
		}
	}

	// Realize edges: touching door pairs first, corridors where allowed
	for &e in g.edges {
		ma, mb := g.nodes[e.a].module_id, g.nodes[e.b].module_id
		da, db := find_touching_door_pair(d, ma, mb)
		if da >= 0 {
			connect_door(&d.modules[ma], da, true)
			connect_door(&d.modules[mb], db, true)
			e.realized = true
		}
	}
	for &e in g.edges {
		if e.realized do continue
		if e.tree ? !params.corridor_fallback : !params.loop_corridors do continue
		e.realized = graph_corridor(d, g.nodes[e.a].module_id, g.nodes[e.b].module_id, params.manhattan_weight)
	}

	// Every room must be reachable through realized edges. Bridge any cut-off
	// part with a corridor along one of its graph edges, or fail the attempt.
	for {
		reached := realized_reachable(g)
		bridged, any_cut := false, false
		for &e in g.edges {
			if e.realized || reached[e.a] == reached[e.b] do continue
			any_cut = true
			if graph_corridor(d, g.nodes[e.a].module_id, g.nodes[e.b].module_id, params.manhattan_weight) {
				e.realized = true
				bridged = true
				break
			}
		}
		if !any_cut do return true
		if !bridged do return false
	}
}

// Which nodes the entry reaches through realized edges. Temp-allocated.
realized_reachable :: proc(g: ^Room_Graph) -> []bool {
	reached := make([]bool, len(g.nodes), context.temp_allocator)
	reached[g.entry] = true
	for changed := true; changed; {
		changed = false
		for e in g.edges {
			if e.realized && reached[e.a] != reached[e.b] {
				reached[e.a], reached[e.b] = true, true
				changed = true
			}
		}
	}
	return reached
}

// Undo a failed attempt: remove modules placed after `first_module` and restore the grid (corridors included).
rollback_placement :: proc(d: ^Dungeon, first_module: int, grid_snapshot: []Grid_Cell) {
	for len(d.modules) > first_module {
		unstamp_module(d, len(d.modules) - 1)
	}
	copy(d.grid, grid_snapshot)
}

execute_place_graph :: proc(d: ^Dungeon, params: ^Place_Graph_Params) {
	d.step_done = true
	if len(d.room_graphs) == 0 do return

	first_module := len(d.modules)
	grid_snapshot := slice.clone(d.grid, context.temp_allocator)
	retries := max(params.retries, 1)
	for gi in 0 ..< len(d.room_graphs) {
		for attempt in 0 ..< retries {
			ok := place_graph_attempt(d, &d.room_graphs[gi], params)
			last := gi == len(d.room_graphs) - 1 && attempt == retries - 1
			if ok || last {
				if gi != 0 do d.room_graphs[0], d.room_graphs[gi] = d.room_graphs[gi], d.room_graphs[0]
				// Other graphs hold stale placement data from rolled-back attempts
				for &other in d.room_graphs[1:] {
					for &n in other.nodes do n.module_id = -1
					for &e in other.edges do e.realized = false
				}
				graph_view_index = 0
				return
			}
			rollback_placement(d, first_module, grid_snapshot)
		}
	}
}

// Self-test: place each profile's graph for many seeds and report how well it fits.
graph_placement_selftest :: proc() -> bool {
	SEEDS :: 100
	all_ok := true
	config := Dungeon_Config{grid_width = 64, grid_height = 64, cell_size = 1, wall_height = 1.5}
	for &p in room_profiles {
		full_rooms, full_edges, rooms_total, rooms_placed, edges_total, edges_realized, corridor_cells := 0, 0, 0, 0, 0, 0, 0
		unreachable := 0
		for seed in 1 ..= SEEDS {
			d := dungeon_create(config)
			defer dungeon_destroy(&d)
			d.recipe = recipe_room_graph(p.name)
			d.recipe.seed = u64(seed)
			dungeon_generate_full(&d)

			if len(d.room_graphs) == 0 {
				fmt.printf("  [%s] seed %d: no graph\n", p.name, seed)
				all_ok = false
				continue
			}
			g := &d.room_graphs[0]
			placed, realized := room_graph_placement_counts(g)
			rooms_total += len(g.nodes)
			rooms_placed += placed
			edges_total += len(g.edges)
			edges_realized += realized
			if placed == len(g.nodes) do full_rooms += 1
			if realized == len(g.edges) do full_edges += 1
			for r in realized_reachable(g) {
				if !r do unreachable += 1
			}
			for cell in d.grid {
				if cell.cell_type == .Corridor do corridor_cells += 1
			}
			free_all(context.temp_allocator)
		}
		fmt.printf("%-20s all rooms placed %d/%d seeds (%d/%d rooms), all edges realized %d/%d seeds (%d/%d edges), avg corridor cells %.1f, unreachable rooms %d\n",
			p.name, full_rooms, SEEDS, rooms_placed, rooms_total, full_edges, SEEDS, edges_realized, edges_total, f32(corridor_cells) / SEEDS, unreachable)
		if full_rooms < SEEDS || unreachable > 0 do all_ok = false
	}
	return all_ok
}

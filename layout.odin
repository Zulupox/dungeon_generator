package dungeon_generator

import "core:slice"

// ---------------------------------------------------------------------------
// Layout graph: how rooms connect on the grid. Shared by Stats and room roles.
//
// One node per room (numbered first), one per connected corridor network, and a link
// node between two rooms that open straight into each other, so a step from one room
// to the next is always two edges, whatever it goes through.
//
// Not strict: any two touching room or corridor cells connect (what Merge Room Walls
// shows). Strict: corridor cells connect freely, cells of the same room connect, and
// anything else only through a connected door on that edge. Wall Border cells (room
// cells without a module) always block.
// ---------------------------------------------------------------------------

DIR_OFFSETS := [Direction][2]int{
	.North = {0, -1},
	.South = {0, 1},
	.East  = {1, 0},
	.West  = {-1, 0},
}

Layout_Opening :: struct {
	cell: int,       // grid index of the cell on one side
	dir:  Direction, // side of that cell the opening is on
}

Layout_Edge :: struct {
	a, b:     int,
	openings: [dynamic]Layout_Opening, // cell edges this connection passes through
}

Layout_Graph :: struct {
	strict:         bool,
	rooms:          int,   // room nodes are 0 ..< rooms
	first_link:     int,   // nodes from here on are room-to-room link nodes
	room_module:    []int, // module id of each room node
	module_room:    []int, // room node of each module id, -1 if none (merged by Join Rooms)
	node_of:        []int, // node of each grid cell, -1 for empty and wall cells
	doors:          []u8,  // per cell: bit per direction with a connected door
	edges:          [dynamic]Layout_Edge,
	adj:            [dynamic][dynamic]int, // edge indices per node
	room_cells:     int,
	corridor_cells: int,
}

layout_other :: proc(e: Layout_Edge, v: int) -> int {
	return e.a == v ? e.b : e.a
}

// Can you walk from cell (x, y) to its neighbour in direction dir?
layout_edge_open :: proc(d: ^Dungeon, doors: []u8, strict: bool, x, y: int, dir: Direction) -> (nx, ny: int, ok: bool) {
	off := DIR_OFFSETS[dir]
	nx, ny = x + off.x, y + off.y
	if !grid_in_bounds(d, nx, ny) do return
	W := d.config.grid_width
	a := &d.grid[y * W + x]
	b := &d.grid[ny * W + nx]
	if a.cell_type == .Empty || b.cell_type == .Empty do return
	if (a.cell_type == .Room && a.module_id < 0) || (b.cell_type == .Room && b.module_id < 0) do return
	if !strict do return nx, ny, true

	a_room := a.cell_type == .Room
	b_room := b.cell_type == .Room
	if !a_room && !b_room do return nx, ny, true
	if a_room && b_room && a.module_id == b.module_id do return nx, ny, true

	ok = doors[y * W + x] & (1 << u8(dir)) != 0 ||
	     doors[ny * W + nx] & (1 << u8(opposite_direction(dir))) != 0
	return
}

// Build the layout graph. Temp-allocated. Nodes and edges are numbered in grid order,
// so the same grid always gives the same graph.
layout_graph_build :: proc(d: ^Dungeon, strict: bool) -> (g: Layout_Graph) {
	context.allocator = context.temp_allocator
	W := d.config.grid_width
	n := len(d.grid)
	g.strict = strict

	g.doors = make([]u8, n)
	for &m in d.modules {
		for di in m.connected_doors {
			slot := m.rot_doors[di]
			gx, gy := door_global(slot, m.grid_x, m.grid_y)
			if grid_in_bounds(d, gx, gy) do g.doors[gy * W + gx] |= 1 << u8(slot.direction)
		}
	}

	// Rooms are the distinct module ids on the grid (Join Rooms merges ids)
	g.node_of = make([]int, n)
	slice.fill(g.node_of, -1)
	g.module_room = make([]int, len(d.modules))
	slice.fill(g.module_room, -1)
	room_module := make([dynamic]int)
	for &cell, i in d.grid {
		switch cell.cell_type {
		case .Room:
			id := cell.module_id
			if id < 0 || id >= len(d.modules) do continue // wall cell
			if g.module_room[id] < 0 {
				g.module_room[id] = len(room_module)
				append(&room_module, id)
			}
			g.node_of[i] = g.module_room[id]
			g.room_cells += 1
		case .Corridor, .Door:
			g.corridor_cells += 1
		case .Empty:
		}
	}
	g.rooms = len(room_module)
	g.room_module = room_module[:]

	// Corridor networks
	V := g.rooms
	queue := make([dynamic]int, 0, n)
	for &cell, i in d.grid {
		if (cell.cell_type != .Corridor && cell.cell_type != .Door) || g.node_of[i] >= 0 do continue
		g.node_of[i] = V
		clear(&queue)
		append(&queue, i)
		for head := 0; head < len(queue); head += 1 {
			ci := queue[head]
			for dir in Direction {
				nx, ny, ok := layout_edge_open(d, g.doors, strict, ci % W, ci / W, dir)
				if !ok do continue
				ni := ny * W + nx
				if g.node_of[ni] >= 0 || d.grid[ni].cell_type == .Room do continue
				g.node_of[ni] = V
				append(&queue, ni)
			}
		}
		V += 1
	}

	g.adj = make([dynamic][dynamic]int, V)
	g.first_link = V
	add_edge :: proc(g: ^Layout_Graph, a, b: int) {
		append(&g.edges, Layout_Edge{a = a, b = b})
		append(&g.adj[a], len(g.edges) - 1)
		append(&g.adj[b], len(g.edges) - 1)
	}

	// Edges between different nodes, from every open cell edge
	pair_edge := make(map[[2]int]int)
	for i in 0 ..< n {
		a := g.node_of[i]
		if a < 0 do continue
		for dir in ([2]Direction{.East, .South}) {
			nx, ny, ok := layout_edge_open(d, g.doors, strict, i % W, i / W, dir)
			if !ok do continue
			b := g.node_of[ny * W + nx]
			if b < 0 || b == a do continue
			room_pair := a < g.rooms && b < g.rooms
			key := [2]int{min(a, b), max(a, b)}
			ei, found := pair_edge[key]
			if !found {
				ei = len(g.edges)
				pair_edge[key] = ei
				if room_pair {
					// room opens straight into room: a link node keeps it two edges
					append(&g.adj, make([dynamic]int))
					l := len(g.adj) - 1
					add_edge(&g, key[0], l)
					add_edge(&g, l, key[1])
				} else {
					add_edge(&g, key[0], key[1])
				}
			}
			op := Layout_Opening{cell = i, dir = dir}
			append(&g.edges[ei].openings, op)
			if room_pair do append(&g.edges[ei + 1].openings, op)
		}
	}
	return
}

// BFS distances (in edges) from `from`, not crossing any edge in `blocked`. Temp-allocated.
layout_distances :: proc(g: ^Layout_Graph, from: int, blocked: []bool = nil) -> (dist: []int, parent_edge: []int) {
	V := len(g.adj)
	dist = make([]int, V, context.temp_allocator)
	parent_edge = make([]int, V, context.temp_allocator)
	slice.fill(dist, -1)
	slice.fill(parent_edge, -1)
	if from < 0 do return
	queue := make([dynamic]int, 0, V, context.temp_allocator)
	dist[from] = 0
	append(&queue, from)
	for head := 0; head < len(queue); head += 1 {
		v := queue[head]
		for ei in g.adj[v] {
			if blocked != nil && blocked[ei] do continue
			nb := layout_other(g.edges[ei], v)
			if dist[nb] >= 0 do continue
			dist[nb] = dist[v] + 1
			parent_edge[nb] = ei
			append(&queue, nb)
		}
	}
	return
}

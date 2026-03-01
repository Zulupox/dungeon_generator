package dungeon_generator

import "core:math"
import "core:container/priority_queue"

// ---------------------------------------------------------------------------
// A* pathfinding with manhattan weight
// ---------------------------------------------------------------------------

AStar_Node :: struct {
	x, y:    int,
	g_cost:  f32,
	f_cost:  f32,
	parent:  [2]int, // {px, py}, -1,-1 if start
	from_dir: [2]int, // direction we came from {dx, dy}
}

// Run A* from (sx,sy) to (gx,gy) on the dungeon grid.
// manhattan_weight controls corridor style:
//   1.0 = strongly prefers axis-aligned, penalizes turns
//   0.0 = allows more organic/winding paths
// Returns a list of grid coordinates forming the path (excluding start, including goal),
// or empty if no path found.
astar_find_path :: proc(
	d: ^Dungeon,
	sx, sy: int,
	gx, gy: int,
	manhattan_weight: f32,
) -> [dynamic][2]int {
	W := d.config.grid_width
	H := d.config.grid_height

	result: [dynamic][2]int

	if !grid_in_bounds(d, sx, sy) || !grid_in_bounds(d, gx, gy) {
		return result
	}

	// Costs stored in a flat array
	UNVISITED :: f32(1e18)
	g_costs := make([]f32, W * H)
	defer delete(g_costs)
	parents := make([][2]int, W * H)
	defer delete(parents)
	from_dirs := make([][2]int, W * H)
	defer delete(from_dirs)
	closed := make([]bool, W * H)
	defer delete(closed)

	for i in 0 ..< W * H {
		g_costs[i] = UNVISITED
		parents[i] = {-1, -1}
		from_dirs[i] = {0, 0}
	}

	heuristic :: proc(x, y, gx, gy: int, manhattan_weight: f32) -> f32 {
		dx := abs(f32(x - gx))
		dy := abs(f32(y - gy))
		// Blend between Chebyshev (diagonal-friendly) and Manhattan
		chebyshev := max(dx, dy)
		manhattan := dx + dy
		return chebyshev + manhattan_weight * (manhattan - chebyshev)
	}

	// Neighbors: 4-directional (no diagonals in corridor generation)
	DIRS :: [4][2]int{{0, -1}, {0, 1}, {1, 0}, {-1, 0}}

	// Priority queue - stores {f_cost, index_into_grid}
	PQ_Entry :: struct {
		f_cost: f32,
		x, y:   int,
	}

	pq_less :: proc(a, b: PQ_Entry) -> bool {
		return a.f_cost < b.f_cost
	}
	pq_swap :: proc(q: []PQ_Entry, i, j: int) {
		q[i], q[j] = q[j], q[i]
	}

	pq: priority_queue.Priority_Queue(PQ_Entry)
	priority_queue.init(&pq, pq_less, pq_swap)
	defer priority_queue.destroy(&pq)

	start_idx := sy * W + sx
	g_costs[start_idx] = 0
	h := heuristic(sx, sy, gx, gy, manhattan_weight)
	priority_queue.push(&pq, PQ_Entry{f_cost = h, x = sx, y = sy})

	found := false

	for priority_queue.len(pq) > 0 {
		current := priority_queue.pop(&pq)
		cx, cy := current.x, current.y
		ci := cy * W + cx

		if closed[ci] do continue
		closed[ci] = true

		if cx == gx && cy == gy {
			found = true
			break
		}

		cur_dir := from_dirs[ci]

		for dir in DIRS {
			nx := cx + dir[0]
			ny := cy + dir[1]

			if !grid_in_bounds(d, nx, ny) do continue
			ni := ny * W + nx

			if closed[ni] do continue

			// Check passability: empty cells, or the goal cell itself
			// (goal might be a room cell / door)
			cell := d.grid[ni]
			is_goal := (nx == gx && ny == gy)
			is_start := (nx == sx && ny == sy)

			if !is_goal && cell.cell_type != .Empty && cell.cell_type != .Corridor {
				continue
			}

			// Area constraint: don't path through cells outside the active area
			// (but always allow start and goal cells)
			if !is_goal && !is_start && !cell_in_active_area(d, nx, ny) {
				continue
			}

			// Movement cost
			base_cost: f32 = 1.0

			// Turn penalty: if we had a direction and this one differs, add penalty
			no_dir := [2]int{0, 0}
			if cur_dir != no_dir && dir != cur_dir {
				base_cost += manhattan_weight * 2.0
			}

			new_g := g_costs[ci] + base_cost

			if new_g < g_costs[ni] {
				g_costs[ni] = new_g
				parents[ni] = {cx, cy}
				from_dirs[ni] = dir
				h2 := heuristic(nx, ny, gx, gy, manhattan_weight)
				priority_queue.push(&pq, PQ_Entry{f_cost = new_g + h2, x = nx, y = ny})
			}
		}
	}

	if !found {
		return result
	}

	// Reconstruct path (reverse)
	path_stack: [dynamic][2]int
	defer delete(path_stack)

	px, py := gx, gy
	for {
		if px == sx && py == sy do break
		append(&path_stack, [2]int{px, py})
		parent := parents[py * W + px]
		px = parent[0]
		py = parent[1]
		if px == -1 do break // shouldn't happen if found
	}

	// Reverse into result
	#reverse for p in path_stack {
		append(&result, p)
	}

	return result
}

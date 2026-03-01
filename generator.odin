package dungeon_generator

import "core:math"
import "core:math/rand"

// ---------------------------------------------------------------------------
// Step Executors - called by the dispatcher in dungeon.odin
// ---------------------------------------------------------------------------

// --- Seed Rooms ---
// Each call places one room. step_progress tracks how many have been placed.

execute_seed_rooms :: proc(d: ^Dungeon, params: ^Seed_Rooms_Params) {
	if d.step_progress < params.count {
		place_random_room(d)
		d.step_progress += 1
	}
	if d.step_progress >= params.count {
		d.step_done = true
	}
}

// --- Grow Clusters ---
// Processes all modules that exist at the start of this step.
// Each call processes one module's cluster roll.
// step_progress tracks which module index we're processing.
// We snapshot the target count on first call (when step_progress == 0).

// We store the target count in a file-scope variable since Dungeon doesn't have
// a general-purpose "step local" field. This is fine because only one step runs at a time.
grow_clusters_target_count: int = 0

execute_grow_clusters :: proc(d: ^Dungeon, params: ^Grow_Clusters_Params) {
	// On first call, snapshot how many modules currently exist
	if d.step_progress == 0 {
		grow_clusters_target_count = len(d.modules)
	}

	if d.step_progress < grow_clusters_target_count {
		module_idx := d.step_progress
		try_grow_cluster_for_module(d, module_idx, params)
		d.step_progress += 1
	}

	if d.step_progress >= grow_clusters_target_count {
		d.step_done = true
	}
}

// --- Connect MST ---
// First sub-step (progress==0): build the MST.
// Subsequent sub-steps: lay one corridor each.

execute_connect_mst :: proc(d: ^Dungeon, params: ^Connect_MST_Params) {
	if d.step_progress == 0 {
		build_mst(d)
		d.step_progress = 1
		if len(d.mst_edges) == 0 {
			d.step_done = true
		}
		return
	}

	corridor_idx := d.step_progress - 1
	if corridor_idx < len(d.mst_edges) {
		job := d.mst_edges[corridor_idx]
		connect_rooms_astar(d, job, params.manhattan_weight)
		d.step_progress += 1
	}

	if d.step_progress - 1 >= len(d.mst_edges) {
		d.step_done = true
	}
}

// --- Mark Doors ---
// One-shot: marks which doors are connected to corridors.

execute_mark_doors :: proc(d: ^Dungeon) {
	mark_connected_doors(d)
	d.step_done = true
}

// ---------------------------------------------------------------------------
// Phase 1: Random room placement
// ---------------------------------------------------------------------------

place_random_room :: proc(d: ^Dungeon) -> bool {
	num_templates := len(MODULE_TEMPLATES)
	MAX_RETRIES :: 50

	for attempt in 0 ..< MAX_RETRIES {
		ti := rand.int_max(num_templates)
		tmpl := &MODULE_TEMPLATES[ti]
		rot := Rotation(rand.int_max(4))

		rw, rh := rotated_dims(tmpl.width, tmpl.height, rot)

		if d.config.grid_width - rw - 2 <= 0 || d.config.grid_height - rh - 2 <= 0 {
			continue
		}
		gx := rand.int_max(d.config.grid_width - rw - 2) + 1
		gy := rand.int_max(d.config.grid_height - rh - 2) + 1

		rot_mask, rmw, rmh := build_rotated_mask(tmpl, rot)

		if can_place_module(d, rot_mask[:], rmw, rmh, gx, gy) {
			delete(rot_mask)
			stamp_module(d, ti, gx, gy, rot)
			return true
		}
		delete(rot_mask)
	}
	return false
}

// ---------------------------------------------------------------------------
// Cluster growth
// ---------------------------------------------------------------------------

// Try to grow a cluster around a specific module.
try_grow_cluster_for_module :: proc(d: ^Dungeon, module_idx: int, params: ^Grow_Clusters_Params) {
	// Roll for cluster
	if rand.float32() >= params.chance do return

	// Determine cluster size
	extra := params.min_rooms
	range_val := params.max_rooms - params.min_rooms
	if range_val > 0 {
		extra += rand.int_max(range_val + 1)
	}

	// Track which modules are in this cluster
	cluster: [dynamic]int
	defer delete(cluster)
	append(&cluster, module_idx)

	for _ in 0 ..< extra {
		if !grow_cluster(d, &cluster) do break
	}
}

// Try to attach a new room to a random door of a random module in the cluster.
grow_cluster :: proc(d: ^Dungeon, cluster: ^[dynamic]int) -> bool {
	MAX_RETRIES :: 30
	num_templates := len(MODULE_TEMPLATES)

	for attempt in 0 ..< MAX_RETRIES {
		ci := rand.int_max(len(cluster))
		parent_idx := cluster[ci]
		parent := &d.modules[parent_idx]

		if len(parent.rot_doors) == 0 do continue

		di := rand.int_max(len(parent.rot_doors))
		door := parent.rot_doors[di]

		nx, ny := door_neighbor(door, parent.grid_x, parent.grid_y)
		if !grid_in_bounds(d, nx, ny) do continue
		if !grid_is_empty(d, nx, ny) do continue

		ti := rand.int_max(num_templates)
		tmpl := &MODULE_TEMPLATES[ti]
		rot := Rotation(rand.int_max(4))

		needed_dir := opposite_direction(door.direction)

		rot_doors := build_rotated_doors(tmpl, rot)
		defer delete(rot_doors)

		found_door := -1
		for rdi in 0 ..< len(rot_doors) {
			if rot_doors[rdi].direction == needed_dir {
				found_door = rdi
				break
			}
		}
		if found_door == -1 do continue

		matching_door := rot_doors[found_door]
		gx := nx - matching_door.local_x
		gy := ny - matching_door.local_y

		rw, rh := rotated_dims(tmpl.width, tmpl.height, rot)
		rot_mask, rmw, rmh := build_rotated_mask(tmpl, rot)

		if can_place_module(d, rot_mask[:], rmw, rmh, gx, gy) {
			delete(rot_mask)
			new_idx := stamp_module(d, ti, gx, gy, rot)
			append(cluster, new_idx)
			return true
		}
		delete(rot_mask)
	}
	return false
}

opposite_direction :: proc(dir: Direction) -> Direction {
	switch dir {
	case .North: return .South
	case .South: return .North
	case .East:  return .West
	case .West:  return .East
	}
	return dir
}

// ---------------------------------------------------------------------------
// MST construction (Prim's algorithm on room centers)
// ---------------------------------------------------------------------------

build_mst :: proc(d: ^Dungeon) {
	clear(&d.mst_edges)

	n := len(d.modules)
	if n < 2 do return

	in_mst := make([]bool, n)
	defer delete(in_mst)

	in_mst[0] = true
	mst_count := 1

	for mst_count < n {
		best_dist: f32 = 1e18
		best_from := -1
		best_to := -1

		for i in 0 ..< n {
			if !in_mst[i] do continue
			for j in 0 ..< n {
				if in_mst[j] do continue
				dx := d.modules[i].center_x - d.modules[j].center_x
				dy := d.modules[i].center_y - d.modules[j].center_y
				dist := dx * dx + dy * dy
				if dist < best_dist {
					best_dist = dist
					best_from = i
					best_to = j
				}
			}
		}

		if best_from == -1 do break

		in_mst[best_to] = true
		mst_count += 1

		job := find_best_door_pair(d, best_from, best_to)
		append(&d.mst_edges, job)
	}
}

find_best_door_pair :: proc(d: ^Dungeon, from_idx, to_idx: int) -> Corridor_Job {
	from_mod := &d.modules[from_idx]
	to_mod := &d.modules[to_idx]

	best_dist: f32 = 1e18
	job: Corridor_Job
	job.from_module = from_idx
	job.to_module = to_idx

	for fi in 0 ..< len(from_mod.rot_doors) {
		fd := from_mod.rot_doors[fi]
		fnx, fny := door_neighbor(fd, from_mod.grid_x, from_mod.grid_y)

		if !grid_in_bounds(d, fnx, fny) do continue
		fn_cell := d.grid[grid_index(d, fnx, fny)]
		if fn_cell.cell_type == .Room do continue

		for ti in 0 ..< len(to_mod.rot_doors) {
			td := to_mod.rot_doors[ti]
			tnx, tny := door_neighbor(td, to_mod.grid_x, to_mod.grid_y)

			if !grid_in_bounds(d, tnx, tny) do continue
			tn_cell := d.grid[grid_index(d, tnx, tny)]
			if tn_cell.cell_type == .Room do continue

			dx := f32(fnx - tnx)
			dy := f32(fny - tny)
			dist := dx * dx + dy * dy

			if dist < best_dist {
				best_dist = dist
				job.from_door_gx = fnx
				job.from_door_gy = fny
				job.to_door_gx = tnx
				job.to_door_gy = tny
			}
		}
	}

	return job
}

// ---------------------------------------------------------------------------
// Connect Doors - mark door-to-door connections between adjacent rooms
// ---------------------------------------------------------------------------
// Finds door connections between adjacent rooms.
// Two-sided: room A has a door facing room B, AND room B has a door facing back
//            at the exact same boundary cell. Both doors get marked connected.
// One-sided: room A has a door whose neighbor cell is inside room B (any Room
//            cell), but room B doesn't have a matching door there. Only room A's
//            door gets marked connected.
// Modes:
//   All     - connect every valid connection (up to max_per_pair between any two modules)
//   Minimal - connect just enough so every room has at least one door

execute_connect_doors :: proc(d: ^Dungeon, params: ^Connect_Doors_Params) {
	// A connection candidate: either two-sided (both mod_a and mod_b have doors)
	// or one-sided (only mod_a has a door facing into mod_b).
	Door_Connection :: struct {
		mod_a, door_a: int,  // module A index and door index
		mod_b, door_b: int,  // module B index and door index (-1 if one-sided)
		two_sided:     bool,
	}

	connections: [dynamic]Door_Connection
	defer delete(connections)

	// To avoid duplicate two-sided pairs, track which (mi, di) have already
	// been recorded as part of a two-sided pair.
	Two_Sided_Key :: struct { mod_idx, door_idx: int }
	recorded_two_sided: [dynamic]Two_Sided_Key
	defer delete(recorded_two_sided)

	is_recorded :: proc(keys: ^[dynamic]Two_Sided_Key, mi, di: int) -> bool {
		for k in keys {
			if k.mod_idx == mi && k.door_idx == di do return true
		}
		return false
	}

	for mi in 0 ..< len(d.modules) {
		m := &d.modules[mi]
		for di in 0 ..< len(m.rot_doors) {
			slot := m.rot_doors[di]

			// Check area constraint on the door cell itself
			dgx, dgy := door_global(slot, m.grid_x, m.grid_y)
			if !cell_in_active_area(d, dgx, dgy) do continue

			nx, ny := door_neighbor(slot, m.grid_x, m.grid_y)
			if !grid_in_bounds(d, nx, ny) do continue

			ncell := d.grid[grid_index(d, nx, ny)]
			if ncell.cell_type != .Room do continue
			if ncell.module_id < 0 || ncell.module_id == mi do continue

			// Check if the adjacent module has a matching door pointing back
			adj := &d.modules[ncell.module_id]
			back_dir := opposite_direction(slot.direction)
			found_match := false
			for adi in 0 ..< len(adj.rot_doors) {
				ad := adj.rot_doors[adi]
				if ad.direction != back_dir do continue
				adx, ady := door_global(ad, adj.grid_x, adj.grid_y)
				if adx == nx && ady == ny {
					// Two-sided pair found. Record only once (lower module id first).
					if mi < ncell.module_id && !is_recorded(&recorded_two_sided, mi, di) {
						append(&connections, Door_Connection{
							mod_a = mi, door_a = di,
							mod_b = ncell.module_id, door_b = adi,
							two_sided = true,
						})
						append(&recorded_two_sided, Two_Sided_Key{mi, di})
						append(&recorded_two_sided, Two_Sided_Key{ncell.module_id, adi})
					}
					found_match = true
					break
				}
			}

			// One-sided: room A has door facing into room B but no matching door back
			if !found_match {
				append(&connections, Door_Connection{
					mod_a = mi, door_a = di,
					mod_b = ncell.module_id, door_b = -1,
					two_sided = false,
				})
			}
		}
	}

	if len(connections) == 0 {
		d.step_done = true
		return
	}

	// Shuffle for variety
	for i := len(connections) - 1; i > 0; i -= 1 {
		j := rand.int_max(i + 1)
		connections[i], connections[j] = connections[j], connections[i]
	}

	// Track how many doors have been opened between each module pair
	Pair_Count :: struct {
		a, b:  int,
		count: int,
	}
	pair_counts: [dynamic]Pair_Count
	defer delete(pair_counts)

	get_pair_count :: proc(pcs: ^[dynamic]Pair_Count, a, b: int) -> int {
		lo := min(a, b)
		hi := max(a, b)
		for &pc in pcs {
			if pc.a == lo && pc.b == hi do return pc.count
		}
		return 0
	}

	inc_pair_count :: proc(pcs: ^[dynamic]Pair_Count, a, b: int) {
		lo := min(a, b)
		hi := max(a, b)
		for &pc in pcs {
			if pc.a == lo && pc.b == hi {
				pc.count += 1
				return
			}
		}
		append(pcs, Pair_Count{a = lo, b = hi, count = 1})
	}

	// Helper: check if a door index is already in a module's connected_doors
	is_door_connected :: proc(m: ^Placed_Module, di: int) -> bool {
		for cd in m.connected_doors {
			if cd == di do return true
		}
		return false
	}

	// Helper: check if a door index is already in two_sided_doors
	is_two_sided_recorded :: proc(m: ^Placed_Module, di: int) -> bool {
		for td in m.two_sided_doors {
			if td == di do return true
		}
		return false
	}

	// Apply a single connection
	apply_connection :: proc(d: ^Dungeon, c: ^Door_Connection) {
		ma := &d.modules[c.mod_a]
		if !is_door_connected(ma, c.door_a) {
			append(&ma.connected_doors, c.door_a)
		}
		if c.two_sided {
			mb := &d.modules[c.mod_b]
			if !is_door_connected(mb, c.door_b) {
				append(&mb.connected_doors, c.door_b)
			}
			// Record both doors as two-sided
			if !is_two_sided_recorded(ma, c.door_a) {
				append(&ma.two_sided_doors, c.door_a)
			}
			if !is_two_sided_recorded(mb, c.door_b) {
				append(&mb.two_sided_doors, c.door_b)
			}
		}
	}

	// Process connections based on mode
	switch params.mode {
	case .All:
		for &c in connections {
			if params.max_per_pair > 0 {
				if get_pair_count(&pair_counts, c.mod_a, c.mod_b) >= params.max_per_pair {
					continue
				}
			}
			apply_connection(d, &c)
			inc_pair_count(&pair_counts, c.mod_a, c.mod_b)
		}

	case .Minimal:
		has_connection := make([]bool, len(d.modules))
		defer delete(has_connection)

		// Pre-mark modules that already have connections from prior steps
		for mi in 0 ..< len(d.modules) {
			if len(d.modules[mi].connected_doors) > 0 {
				has_connection[mi] = true
			}
		}

		// First pass: connect where at least one module has no connection yet
		for &c in connections {
			if has_connection[c.mod_a] && has_connection[c.mod_b] do continue

			if params.max_per_pair > 0 {
				if get_pair_count(&pair_counts, c.mod_a, c.mod_b) >= params.max_per_pair {
					continue
				}
			}

			apply_connection(d, &c)
			has_connection[c.mod_a] = true
			has_connection[c.mod_b] = true
			inc_pair_count(&pair_counts, c.mod_a, c.mod_b)
		}
	}

	d.step_done = true
}

// ---------------------------------------------------------------------------
// Corridor connection
// ---------------------------------------------------------------------------

connect_rooms_astar :: proc(d: ^Dungeon, job: Corridor_Job, manhattan_weight: f32) {
	path := astar_find_path(
		d,
		job.from_door_gx, job.from_door_gy,
		job.to_door_gx, job.to_door_gy,
		manhattan_weight,
	)
	defer delete(path)

	corridor_color := Color4{80, 80, 90, 255}

	mark_corridor_cell(d, job.from_door_gx, job.from_door_gy, corridor_color)

	for p in path {
		mark_corridor_cell(d, p[0], p[1], corridor_color)
	}

	mark_corridor_cell(d, job.to_door_gx, job.to_door_gy, corridor_color)
}

// ---------------------------------------------------------------------------
// Post-processing
// ---------------------------------------------------------------------------

mark_connected_doors :: proc(d: ^Dungeon) {
	// Additive: preserve existing connections (e.g. from Connect_Doors step)
	// and only add corridor-facing doors that aren't already connected.
	for &m in d.modules {
		for di in 0 ..< len(m.rot_doors) {
			slot := m.rot_doors[di]
			nx, ny := door_neighbor(slot, m.grid_x, m.grid_y)
			if !grid_in_bounds(d, nx, ny) do continue
			cell := d.grid[grid_index(d, nx, ny)]
			if cell.cell_type == .Corridor {
				// Check if already connected (from a prior step)
				already := false
				for cd in m.connected_doors {
					if cd == di { already = true; break }
				}
				if !already {
					append(&m.connected_doors, di)
				}
			}
		}
	}
}

mark_corridor_cell :: proc(d: ^Dungeon, x, y: int, color: Color4) {
	if !grid_in_bounds(d, x, y) do return
	if !cell_in_active_area(d, x, y) do return
	cell := grid_get(d, x, y)
	if cell.cell_type == .Empty {
		cell.cell_type = .Corridor
		cell.module_id = -1
		cell.color = color
	}
}

// ===========================================================================
// New Step Executors
// ===========================================================================

// ---------------------------------------------------------------------------
// Add Loops - extra corridor connections beyond the MST
// ---------------------------------------------------------------------------
// First sub-step (progress==0): pick random room pairs and build loop_edges.
// Subsequent sub-steps: lay one corridor each.

execute_add_loops :: proc(d: ^Dungeon, params: ^Add_Loops_Params) {
	if d.step_progress == 0 {
		build_loop_edges(d, params)
		d.step_progress = 1
		if len(d.loop_edges) == 0 {
			d.step_done = true
		}
		return
	}

	corridor_idx := d.step_progress - 1
	if corridor_idx < len(d.loop_edges) {
		job := d.loop_edges[corridor_idx]
		connect_rooms_astar(d, job, params.manhattan_weight)
		d.step_progress += 1
	}

	if d.step_progress - 1 >= len(d.loop_edges) {
		d.step_done = true
	}
}

build_loop_edges :: proc(d: ^Dungeon, params: ^Add_Loops_Params) {
	clear(&d.loop_edges)
	n := len(d.modules)
	if n < 2 do return

	// Build a set of MST-connected pairs to avoid duplicating them.
	// We use a simple approach: hash pairs as i*N+j (i < j).
	mst_pairs := make(map[[2]int]bool)
	defer delete(mst_pairs)

	for edge in d.mst_edges {
		i := min(edge.from_module, edge.to_module)
		j := max(edge.from_module, edge.to_module)
		mst_pairs[{i, j}] = true
	}

	// Collect candidate non-MST pairs
	candidates: [dynamic][2]int
	defer delete(candidates)

	for i in 0 ..< n {
		for j in i + 1 ..< n {
			if !({i, j} in mst_pairs) {
				append(&candidates, [2]int{i, j})
			}
		}
	}

	// Shuffle candidates (Fisher-Yates)
	for i := len(candidates) - 1; i > 0; i -= 1 {
		j := rand.int_max(i + 1)
		candidates[i], candidates[j] = candidates[j], candidates[i]
	}

	// Pick up to max_extra pairs with loop_chance roll
	added := 0
	for pair in candidates {
		if added >= params.max_extra do break
		if rand.float32() >= params.loop_chance do continue

		job := find_best_door_pair(d, pair[0], pair[1])
		// Verify the door pair is valid (both doors found)
		if job.from_door_gx == 0 && job.from_door_gy == 0 && job.to_door_gx == 0 && job.to_door_gy == 0 {
			continue // no valid door pair found
		}
		append(&d.loop_edges, job)
		added += 1
	}
}

// ---------------------------------------------------------------------------
// Widen Corridors - expand corridors to target width
// ---------------------------------------------------------------------------
// One-shot step: scans all corridor cells and expands them perpendicular to
// their local direction. Only expands into Empty cells.

execute_widen_corridors :: proc(d: ^Dungeon, params: ^Widen_Corridors_Params) {
	target_width := max(2, params.width) // at least 2 to have any effect
	expand := (target_width - 1) / 2     // cells to expand on each side

	corridor_color := Color4{80, 80, 90, 255}

	// Snapshot which cells are currently corridors (so we don't expand newly-placed cells)
	W := d.config.grid_width
	H := d.config.grid_height
	is_corridor := make([]bool, W * H)
	defer delete(is_corridor)

	for i in 0 ..< W * H {
		is_corridor[i] = d.grid[i].cell_type == .Corridor
	}

	DIRS :: [4][2]int{{0, -1}, {0, 1}, {1, 0}, {-1, 0}}

	for gy in 0 ..< H {
		for gx in 0 ..< W {
			if !is_corridor[gy * W + gx] do continue
			if !cell_in_active_area(d, gx, gy) do continue

			// Determine local direction: check corridor neighbors
			has_h := false // has horizontal corridor neighbor
			has_v := false // has vertical corridor neighbor

			// Check horizontal neighbors
			if gx > 0 && is_corridor[gy * W + (gx - 1)] do has_h = true
			if gx < W - 1 && is_corridor[gy * W + (gx + 1)] do has_h = true
			// Check vertical neighbors
			if gy > 0 && is_corridor[(gy - 1) * W + gx] do has_v = true
			if gy < H - 1 && is_corridor[(gy + 1) * W + gx] do has_v = true

			// Expand perpendicular to the corridor direction
			// Horizontal corridor -> expand vertically (N/S)
			// Vertical corridor -> expand horizontally (E/W)
			// Junction (both) or isolated -> expand in both directions
			if has_h {
				// Expand vertically
				for e in 1 ..= expand {
					mark_corridor_cell(d, gx, gy - e, corridor_color)
					mark_corridor_cell(d, gx, gy + e, corridor_color)
				}
			}
			if has_v {
				// Expand horizontally
				for e in 1 ..= expand {
					mark_corridor_cell(d, gx - e, gy, corridor_color)
					mark_corridor_cell(d, gx + e, gy, corridor_color)
				}
			}
			if !has_h && !has_v {
				// Isolated corridor cell - expand in all directions
				for e in 1 ..= expand {
					mark_corridor_cell(d, gx - e, gy, corridor_color)
					mark_corridor_cell(d, gx + e, gy, corridor_color)
					mark_corridor_cell(d, gx, gy - e, corridor_color)
					mark_corridor_cell(d, gx, gy + e, corridor_color)
				}
			}
		}
	}

	d.step_done = true
}

// ---------------------------------------------------------------------------
// BSP Partition - binary space partition room placement
// ---------------------------------------------------------------------------
// First sub-step (progress==0): build BSP tree, collect leaf partitions into
// placement_queue. Subsequent sub-steps: place one room per sub-step.

BSP_Rect :: struct {
	x, y, w, h: int,
}

execute_bsp_partition :: proc(d: ^Dungeon, params: ^BSP_Partition_Params) {
	if d.step_progress == 0 {
		clear(&d.placement_queue)
		min_sz := max(4, params.min_size) // enforce minimum
		pad := max(1, params.padding)

		// Start with full grid (minus 1 cell border)
		root := BSP_Rect{1, 1, d.config.grid_width - 2, d.config.grid_height - 2}
		bsp_split(d, root, min_sz, pad)

		d.step_progress = 1
		if len(d.placement_queue) == 0 {
			d.step_done = true
		}
		return
	}

	target_idx := d.step_progress - 1
	if target_idx < len(d.placement_queue) {
		target := d.placement_queue[target_idx]
		place_room_in_region(d, target)
		d.step_progress += 1
	}

	if d.step_progress - 1 >= len(d.placement_queue) {
		d.step_done = true
	}
}

// Recursively split a rectangle and collect leaf partitions.
bsp_split :: proc(d: ^Dungeon, rect: BSP_Rect, min_size, padding: int) {
	// If too small to split further, this is a leaf
	can_split_h := rect.h >= min_size * 2
	can_split_v := rect.w >= min_size * 2

	if !can_split_h && !can_split_v {
		// Leaf partition - add placement target
		append(&d.placement_queue, Placement_Target{
			center_x = rect.x + rect.w / 2,
			center_y = rect.y + rect.h / 2,
			max_w    = rect.w - padding * 2,
			max_h    = rect.h - padding * 2,
		})
		return
	}

	// Choose split direction
	split_h: bool
	if can_split_h && can_split_v {
		// Prefer splitting the longer dimension, with some randomness
		if rect.w > rect.h {
			split_h = rand.float32() < 0.3 // mostly vertical split
		} else if rect.h > rect.w {
			split_h = rand.float32() < 0.7 // mostly horizontal split
		} else {
			split_h = rand.float32() < 0.5
		}
	} else {
		split_h = can_split_h
	}

	if split_h {
		// Horizontal split: split along Y axis
		split_min := rect.y + min_size
		split_max := rect.y + rect.h - min_size
		if split_min > split_max {
			// Can't split - treat as leaf
			append(&d.placement_queue, Placement_Target{
				center_x = rect.x + rect.w / 2,
				center_y = rect.y + rect.h / 2,
				max_w    = rect.w - padding * 2,
				max_h    = rect.h - padding * 2,
			})
			return
		}
		split_y := split_min + rand.int_max(split_max - split_min + 1)
		top := BSP_Rect{rect.x, rect.y, rect.w, split_y - rect.y}
		bottom := BSP_Rect{rect.x, split_y, rect.w, rect.y + rect.h - split_y}
		bsp_split(d, top, min_size, padding)
		bsp_split(d, bottom, min_size, padding)
	} else {
		// Vertical split: split along X axis
		split_min := rect.x + min_size
		split_max := rect.x + rect.w - min_size
		if split_min > split_max {
			append(&d.placement_queue, Placement_Target{
				center_x = rect.x + rect.w / 2,
				center_y = rect.y + rect.h / 2,
				max_w    = rect.w - padding * 2,
				max_h    = rect.h - padding * 2,
			})
			return
		}
		split_x := split_min + rand.int_max(split_max - split_min + 1)
		left := BSP_Rect{rect.x, rect.y, split_x - rect.x, rect.h}
		right := BSP_Rect{split_x, rect.y, rect.x + rect.w - split_x, rect.h}
		bsp_split(d, left, min_size, padding)
		bsp_split(d, right, min_size, padding)
	}
}

// Place a room template within a target region.
place_room_in_region :: proc(d: ^Dungeon, target: Placement_Target) {
	num_templates := len(MODULE_TEMPLATES)
	MAX_RETRIES :: 30

	for attempt in 0 ..< MAX_RETRIES {
		ti := rand.int_max(num_templates)
		tmpl := &MODULE_TEMPLATES[ti]
		rot := Rotation(rand.int_max(4))

		rw, rh := rotated_dims(tmpl.width, tmpl.height, rot)

		// Check if room fits in the allowed region
		if rw > target.max_w || rh > target.max_h do continue

		// Place centered on target with slight random offset
		gx := target.center_x - rw / 2
		gy := target.center_y - rh / 2

		// Add small random offset within remaining space
		slack_x := target.max_w - rw
		slack_y := target.max_h - rh
		if slack_x > 0 {
			gx += rand.int_max(slack_x + 1) - slack_x / 2
		}
		if slack_y > 0 {
			gy += rand.int_max(slack_y + 1) - slack_y / 2
		}

		// Clamp to grid bounds
		gx = max(1, min(gx, d.config.grid_width - rw - 1))
		gy = max(1, min(gy, d.config.grid_height - rh - 1))

		rot_mask, rmw, rmh := build_rotated_mask(tmpl, rot)

		if can_place_module(d, rot_mask[:], rmw, rmh, gx, gy) {
			delete(rot_mask)
			stamp_module(d, ti, gx, gy, rot)
			return
		}
		delete(rot_mask)
	}
}

// ---------------------------------------------------------------------------
// Fill Dead Ends - remove corridor dead-end cells
// ---------------------------------------------------------------------------
// One pass per sub-step. A dead-end is a corridor cell with exactly 1
// non-empty (corridor or room) orthogonal neighbor.

execute_fill_dead_ends :: proc(d: ^Dungeon, params: ^Fill_Dead_Ends_Params) {
	total_iterations := max(1, params.iterations)

	// Each sub-step performs one pass
	removed := fill_dead_ends_pass(d)

	d.step_progress += 1

	// Done if we've done all iterations or nothing was removed (stable)
	if d.step_progress >= total_iterations || removed == 0 {
		d.step_done = true
	}
}

fill_dead_ends_pass :: proc(d: ^Dungeon) -> int {
	W := d.config.grid_width
	H := d.config.grid_height
	removed := 0

	DIRS :: [4][2]int{{0, -1}, {0, 1}, {1, 0}, {-1, 0}}

	// Collect dead ends first, then remove (to avoid order-dependent issues)
	dead_ends: [dynamic][2]int
	defer delete(dead_ends)

	for gy in 0 ..< H {
		for gx in 0 ..< W {
			if !cell_in_active_area(d, gx, gy) do continue
			cell := &d.grid[gy * W + gx]
			if cell.cell_type != .Corridor do continue

			// Count non-empty orthogonal neighbors
			neighbor_count := 0
			for dir in DIRS {
				nx := gx + dir[0]
				ny := gy + dir[1]
				if !grid_in_bounds(d, nx, ny) do continue
				n_type := d.grid[ny * W + nx].cell_type
				if n_type != .Empty {
					neighbor_count += 1
				}
			}

			if neighbor_count <= 1 {
				append(&dead_ends, [2]int{gx, gy})
			}
		}
	}

	for de in dead_ends {
		cell := grid_get(d, de[0], de[1])
		cell.cell_type = .Empty
		cell.module_id = -1
		cell.color = {0, 0, 0, 0}
		removed += 1
	}

	return removed
}

// ---------------------------------------------------------------------------
// Place Grid - place rooms in a regular grid pattern with jitter
// ---------------------------------------------------------------------------
// First sub-step (progress==0): compute grid positions into placement_queue.
// Subsequent sub-steps: place one room per sub-step.

execute_place_grid :: proc(d: ^Dungeon, params: ^Place_Grid_Params) {
	if d.step_progress == 0 {
		clear(&d.placement_queue)
		cols := max(1, params.cols)
		rows := max(1, params.rows)

		W := d.config.grid_width
		H := d.config.grid_height

		// Compute spacing
		spacing_x := W / (cols + 1)
		spacing_y := H / (rows + 1)

		for ry in 0 ..< rows {
			for cx in 0 ..< cols {
				base_x := spacing_x * (cx + 1)
				base_y := spacing_y * (ry + 1)

				// Apply jitter
				jitter_range_x := int(params.jitter * f32(spacing_x) * 0.5)
				jitter_range_y := int(params.jitter * f32(spacing_y) * 0.5)

				jx := 0
				jy := 0
				if jitter_range_x > 0 {
					jx = rand.int_max(jitter_range_x * 2 + 1) - jitter_range_x
				}
				if jitter_range_y > 0 {
					jy = rand.int_max(jitter_range_y * 2 + 1) - jitter_range_y
				}

				final_x := clamp(base_x + jx, 2, W - 2)
				final_y := clamp(base_y + jy, 2, H - 2)

				// Allow room size up to slightly less than spacing
				max_w := max(3, spacing_x - 2)
				max_h := max(3, spacing_y - 2)

				append(&d.placement_queue, Placement_Target{
					center_x = final_x,
					center_y = final_y,
					max_w    = max_w,
					max_h    = max_h,
				})
			}
		}

		d.step_progress = 1
		if len(d.placement_queue) == 0 {
			d.step_done = true
		}
		return
	}

	target_idx := d.step_progress - 1
	if target_idx < len(d.placement_queue) {
		target := d.placement_queue[target_idx]
		place_room_in_region(d, target)
		d.step_progress += 1
	}

	if d.step_progress - 1 >= len(d.placement_queue) {
		d.step_done = true
	}
}

// ===========================================================================
// Room Corridor - connect rooms by chaining rooms along the path
// ===========================================================================
// First sub-step (progress==0): build MST.
// Subsequent sub-steps: process one MST edge per sub-step, building a chain
// of rooms along the connection and falling back to A* for any remaining gap.

execute_room_corridor :: proc(d: ^Dungeon, params: ^Room_Corridor_Params) {
	if d.step_progress == 0 {
		build_mst(d)
		d.step_progress = 1
		if len(d.mst_edges) == 0 {
			d.step_done = true
		}
		return
	}

	edge_idx := d.step_progress - 1
	if edge_idx < len(d.mst_edges) {
		job := d.mst_edges[edge_idx]
		build_room_chain(d, job, params)
		d.step_progress += 1
	}

	if d.step_progress - 1 >= len(d.mst_edges) {
		d.step_done = true
	}
}

// Direction vectors for the 4 cardinal directions.
dir_vector :: proc(dir: Direction) -> [2]f32 {
	switch dir {
	case .North: return {0, -1}
	case .South: return {0,  1}
	case .East:  return {1,  0}
	case .West:  return {-1, 0}
	}
	return {0, 0}
}

// Score how well a door direction aligns with a target direction vector.
// Returns a value from -1 (opposite) to +1 (perfectly aligned).
dir_dot :: proc(dir: Direction, target_dx, target_dy: f32) -> f32 {
	dv := dir_vector(dir)
	// Normalize target (avoid div by zero)
	len_sq := target_dx * target_dx + target_dy * target_dy
	if len_sq < 0.001 do return 0
	inv_len := 1.0 / math.sqrt(len_sq)
	return dv[0] * target_dx * inv_len + dv[1] * target_dy * inv_len
}

// Build a chain of rooms from one MST edge endpoint to the other.
// Falls back to A* corridor if the chain can't reach the destination.
build_room_chain :: proc(d: ^Dungeon, job: Corridor_Job, params: ^Room_Corridor_Params) {
	max_chain := max(1, params.max_chain)

	// Current position: start from the "from" door neighbor cell
	cur_x := job.from_door_gx
	cur_y := job.from_door_gy

	// Target position: the "to" door neighbor cell
	target_x := job.to_door_gx
	target_y := job.to_door_gy

	// Determine the entry direction for the first chain room.
	// The from-room has a door facing outward toward cur_x,cur_y.
	// The chain room's entry door must face the opposite direction (back toward the from-room).
	entry_dir := Direction.North // will be overwritten
	from_mod := &d.modules[job.from_module]
	for slot in from_mod.rot_doors {
		nx, ny := door_neighbor(slot, from_mod.grid_x, from_mod.grid_y)
		if nx == cur_x && ny == cur_y {
			entry_dir = opposite_direction(slot.direction)
			break
		}
	}

	// Track the last exit position for fallback bridging
	last_exit_x := cur_x
	last_exit_y := cur_y
	reached_target := false

	for chain_i in 0 ..< max_chain {
		// If we're right on top of the target, we're done
		if cur_x == target_x && cur_y == target_y {
			reached_target = true
			break
		}

		// Direction toward target
		target_dx := f32(target_x - cur_x)
		target_dy := f32(target_y - cur_y)

		// Try to place a room here
		placed := try_place_chain_room(d, cur_x, cur_y, entry_dir,
			target_dx, target_dy, params.strictness)

		if !placed.success do break

		// Update position to the exit door's neighbor
		cur_x = placed.exit_x
		cur_y = placed.exit_y
		last_exit_x = cur_x
		last_exit_y = cur_y
		entry_dir = opposite_direction(placed.exit_dir)

		// Check if exit lands directly on the target module
		if grid_in_bounds(d, cur_x, cur_y) {
			cell := d.grid[grid_index(d, cur_x, cur_y)]
			if cell.cell_type == .Room && cell.module_id == job.to_module {
				reached_target = true
				break
			}
		} else {
			break
		}
	}

	// Always bridge the remaining gap with A* corridor unless we landed
	// exactly on the target module. This handles the common case where
	// the chain gets close but doesn't perfectly dock.
	if !reached_target {
		fallback_job := Corridor_Job{
			from_module  = job.from_module,
			to_module    = job.to_module,
			from_door_gx = last_exit_x,
			from_door_gy = last_exit_y,
			to_door_gx   = target_x,
			to_door_gy   = target_y,
		}
		connect_rooms_astar(d, fallback_job, params.manhattan_weight)
	}
}

// Result of trying to place a chain room.
Chain_Place_Result :: struct {
	success:  bool,
	exit_x:   int,      // grid coord of the exit door's neighbor
	exit_y:   int,
	exit_dir: Direction, // direction the exit door faces
}

// Try to place a room at the chain's current position.
// entry_dir: the direction the entry door must face
// target_dx/dy: direction toward the ultimate destination
// strictness: how tightly the exit door must align with target direction
try_place_chain_room :: proc(
	d: ^Dungeon,
	cur_x, cur_y: int,
	entry_dir: Direction,
	target_dx, target_dy: f32,
	strictness: f32,
) -> Chain_Place_Result {
	num_templates := len(MODULE_TEMPLATES)
	MAX_RETRIES :: 40

	for attempt in 0 ..< MAX_RETRIES {
		ti := rand.int_max(num_templates)
		tmpl := &MODULE_TEMPLATES[ti]
		rot := Rotation(rand.int_max(4))

		rot_doors := build_rotated_doors(tmpl, rot)

		// Find an entry door that matches the required direction
		entry_door_idx := -1
		for rdi in 0 ..< len(rot_doors) {
			if rot_doors[rdi].direction == entry_dir {
				entry_door_idx = rdi
				break
			}
		}
		if entry_door_idx == -1 {
			delete(rot_doors)
			continue
		}

		entry_door := rot_doors[entry_door_idx]

		// Position the template so the entry door cell is at cur_x, cur_y
		gx := cur_x - entry_door.local_x
		gy := cur_y - entry_door.local_y

		// Check if we can place
		rot_mask, rmw, rmh := build_rotated_mask(tmpl, rot)

		if !can_place_module(d, rot_mask[:], rmw, rmh, gx, gy) {
			delete(rot_mask)
			delete(rot_doors)
			continue
		}

		// Find the best exit door (not the entry door)
		best_exit_idx := -1
		best_exit_score: f32 = -2.0

		for rdi in 0 ..< len(rot_doors) {
			if rdi == entry_door_idx do continue

			door := rot_doors[rdi]
			dot := dir_dot(door.direction, target_dx, target_dy)

			// Strictness filtering: at high strictness, reject doors pointing away
			min_dot := -1.0 + strictness * 1.0 // at 1.0: min_dot=0, at 0.0: min_dot=-1
			if dot < f32(min_dot) do continue

			// Score: blend between random and direction-aligned
			random_bonus := rand.float32() * (1.0 - strictness) * 0.5
			score := dot * strictness + random_bonus

			if score > best_exit_score {
				best_exit_score = score
				best_exit_idx = rdi
			}
		}

		// If no valid exit door found, skip this template
		if best_exit_idx == -1 {
			delete(rot_mask)
			delete(rot_doors)
			continue
		}

		exit_door := rot_doors[best_exit_idx]
		exit_nx, exit_ny := door_neighbor(exit_door, gx, gy)

		// Make sure exit neighbor is in bounds
		if !grid_in_bounds(d, exit_nx, exit_ny) {
			delete(rot_mask)
			delete(rot_doors)
			continue
		}

		// Place the room
		delete(rot_mask)
		delete(rot_doors)
		stamp_module(d, ti, gx, gy, rot)

		return Chain_Place_Result{
			success  = true,
			exit_x   = exit_nx,
			exit_y   = exit_ny,
			exit_dir = exit_door.direction,
		}
	}

	return Chain_Place_Result{success = false}
}

// ---------------------------------------------------------------------------
// Define Area - registers an area on the dungeon (instant step)
// ---------------------------------------------------------------------------

execute_define_area :: proc(d: ^Dungeon, params: ^Define_Area_Params) {
	// Check if area with this ID already exists, update it
	existing := find_area_by_id(d, params.area_id)
	if existing != nil {
		existing.shape = params.shape
		existing.x = params.x
		existing.y = params.y
		existing.w = params.w
		existing.h = params.h
	} else {
		append(&d.areas, Dungeon_Area{
			id    = params.area_id,
			shape = params.shape,
			x     = params.x,
			y     = params.y,
			w     = params.w,
			h     = params.h,
		})
	}
	d.step_done = true
}

// ---------------------------------------------------------------------------
// Pack Rooms - flood-fill an area with rooms by attaching to open doors
// ---------------------------------------------------------------------------
// Each sub-step places one room. When no more rooms can be placed, the step is done.
// step_progress tracks rooms placed so far.

// File-scope state for pack_rooms: tracks consecutive failed full passes.
pack_rooms_fail_count: int = 0

execute_pack_rooms :: proc(d: ^Dungeon, params: ^Pack_Rooms_Params) {
	num_templates := len(MODULE_TEMPLATES)

	// Safety cap
	if params.max_rooms > 0 && d.step_progress >= params.max_rooms {
		d.step_done = true
		pack_rooms_fail_count = 0
		return
	}

	// If no modules exist yet, place a seed room
	if len(d.modules) == 0 {
		if place_random_room(d) {
			d.step_progress += 1
			pack_rooms_fail_count = 0
		} else {
			d.step_done = true
			pack_rooms_fail_count = 0
		}
		return
	}

	// Collect all open (unconnected) doors across all modules
	Open_Door :: struct {
		module_idx: int,
		door_idx:   int,
	}

	open_doors: [dynamic]Open_Door
	defer delete(open_doors)

	for mi in 0 ..< len(d.modules) {
		m := &d.modules[mi]
		for di in 0 ..< len(m.rot_doors) {
			// Check if this door is already connected
			is_connected := false
			for cd in m.connected_doors {
				if cd == di {
					is_connected = true
					break
				}
			}
			if is_connected do continue

			// Check if the neighbor cell of this door is empty and in bounds
			door := m.rot_doors[di]
			nx, ny := door_neighbor(door, m.grid_x, m.grid_y)
			if !grid_in_bounds(d, nx, ny) do continue
			if !grid_is_empty(d, nx, ny) do continue

			append(&open_doors, Open_Door{module_idx = mi, door_idx = di})
		}
	}

	if len(open_doors) == 0 {
		d.step_done = true
		pack_rooms_fail_count = 0
		return
	}

	// Shuffle open doors
	for i := len(open_doors) - 1; i > 0; i -= 1 {
		j := rand.int_max(i + 1)
		open_doors[i], open_doors[j] = open_doors[j], open_doors[i]
	}

	// Try to attach a room to each open door
	for od in open_doors {
		parent := &d.modules[od.module_idx]
		door := parent.rot_doors[od.door_idx]
		nx, ny := door_neighbor(door, parent.grid_x, parent.grid_y)

		// Re-check since earlier placements in this step may have filled the cell
		if !grid_is_empty(d, nx, ny) do continue

		needed_dir := opposite_direction(door.direction)

		// Try several random templates/rotations
		TEMPLATE_RETRIES :: 15
		for _ in 0 ..< TEMPLATE_RETRIES {
			ti := rand.int_max(num_templates)
			tmpl := &MODULE_TEMPLATES[ti]
			rot := Rotation(rand.int_max(4))

			rot_doors := build_rotated_doors(tmpl, rot)

			// Find a door on the new template matching the needed direction
			found_door := -1
			for rdi in 0 ..< len(rot_doors) {
				if rot_doors[rdi].direction == needed_dir {
					found_door = rdi
					break
				}
			}
			if found_door == -1 {
				delete(rot_doors)
				continue
			}

			matching_door := rot_doors[found_door]
			gx := nx - matching_door.local_x
			gy := ny - matching_door.local_y

			rot_mask, rmw, rmh := build_rotated_mask(tmpl, rot)

			if can_place_module(d, rot_mask[:], rmw, rmh, gx, gy) {
				delete(rot_mask)
				delete(rot_doors)
				new_idx := stamp_module(d, ti, gx, gy, rot)

				// Post-placement validation: check the new room has at least
				// one door with a viable neighbor (empty, corridor, or a
				// matching door on an adjacent room).
				new_mod := &d.modules[new_idx]
				has_viable_door := false
				for ndi in 0 ..< len(new_mod.rot_doors) {
					nd := new_mod.rot_doors[ndi]
					dnx, dny := door_neighbor(nd, new_mod.grid_x, new_mod.grid_y)
					if !grid_in_bounds(d, dnx, dny) do continue
					ncell := grid_get(d, dnx, dny)

					if ncell.cell_type == .Empty || ncell.cell_type == .Corridor {
						has_viable_door = true
						break
					}
					// Check if neighbor is a room cell with a door pointing back
					if ncell.cell_type == .Room && ncell.module_id >= 0 && ncell.module_id != new_idx {
						adj_mod := &d.modules[ncell.module_id]
						back_dir := opposite_direction(nd.direction)
						for adi in 0 ..< len(adj_mod.rot_doors) {
							ad := adj_mod.rot_doors[adi]
							adx, ady := door_global(ad, adj_mod.grid_x, adj_mod.grid_y)
							if adx == dnx && ady == dny && ad.direction == back_dir {
								has_viable_door = true
								break
							}
						}
						if has_viable_door do break
					}
				}

				if has_viable_door {
					d.step_progress += 1
					pack_rooms_fail_count = 0
					return // one room per sub-step (for animation)
				}

				// Undo: clear grid cells and remove the module
				unstamp_module(d, new_idx)
				// Continue trying next template/rotation
				continue
			}
			delete(rot_mask)
			delete(rot_doors)
		}
	}

	// Full pass with zero placements — count consecutive failures
	pack_rooms_fail_count += 1
	if pack_rooms_fail_count >= 3 {
		// 3 consecutive failed passes means we're truly stuck
		d.step_done = true
		pack_rooms_fail_count = 0
	}
}

// ---------------------------------------------------------------------------
// Join Rooms - merge adjacent rooms into one by reassigning module IDs
// ---------------------------------------------------------------------------
// Finds all pairs of adjacent room cells from different modules (within active
// area), merges them via union-find, then reassigns grid cell module_ids.
// Also cleans up connected_doors that are now internal.

execute_join_rooms :: proc(d: ^Dungeon) {
	W := d.config.grid_width
	H := d.config.grid_height
	n_modules := len(d.modules)

	if n_modules < 2 {
		d.step_done = true
		return
	}

	// Union-Find over module indices
	parent := make([]int, n_modules)
	defer delete(parent)
	for i in 0 ..< n_modules {
		parent[i] = i
	}

	uf_find :: proc(parent: []int, x: int) -> int {
		r := x
		for parent[r] != r {
			r = parent[r]
		}
		// Path compression
		c := x
		for c != r {
			next := parent[c]
			parent[c] = r
			c = next
		}
		return r
	}

	uf_union :: proc(parent: []int, a, b: int) {
		ra := uf_find(parent, a)
		rb := uf_find(parent, b)
		if ra != rb {
			parent[rb] = ra
		}
	}

	// Scan grid for adjacent room cells from different modules
	DIRS :: [4][2]int{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}

	for gy in 0 ..< H {
		for gx in 0 ..< W {
			if !cell_in_active_area(d, gx, gy) do continue
			cell := &d.grid[gy * W + gx]
			if cell.cell_type != .Room do continue
			if cell.module_id < 0 do continue

			for dir in DIRS {
				nx := gx + dir[0]
				ny := gy + dir[1]
				if !grid_in_bounds(d, nx, ny) do continue
				if !cell_in_active_area(d, nx, ny) do continue

				neighbor := &d.grid[ny * W + nx]
				if neighbor.cell_type != .Room do continue
				if neighbor.module_id < 0 do continue
				if neighbor.module_id == cell.module_id do continue

				uf_union(parent, cell.module_id, neighbor.module_id)
			}
		}
	}

	// Build canonical root for each module
	roots := make([]int, n_modules)
	defer delete(roots)
	for i in 0 ..< n_modules {
		roots[i] = uf_find(parent, i)
	}

	// Reassign grid cell module_ids to the root
	for gy in 0 ..< H {
		for gx in 0 ..< W {
			cell := &d.grid[gy * W + gx]
			if cell.cell_type != .Room do continue
			if cell.module_id < 0 do continue
			cell.module_id = roots[cell.module_id]
		}
	}

	// Also adopt the color of the root module for merged cells
	// so they visually unify
	for gy in 0 ..< H {
		for gx in 0 ..< W {
			cell := &d.grid[gy * W + gx]
			if cell.cell_type != .Room do continue
			if cell.module_id < 0 do continue
			// Get the root module's color from any cell that was originally that module
			root_mod := &d.modules[cell.module_id]
			// Use the root module's first cell color - find it from the grid
			// Actually simpler: stamp_module sets color per cell from template,
			// so just use the root module's grid position to sample color
			root_gx := root_mod.grid_x
			root_gy := root_mod.grid_y
			if grid_in_bounds(d, root_gx, root_gy) {
				root_cell := &d.grid[root_gy * W + root_gx]
				if root_cell.cell_type == .Room {
					cell.color = root_cell.color
				}
			}
		}
	}

	// Clean up connected_doors: remove doors whose neighbor cell now has
	// the same module_id (internal door after merge)
	for mi in 0 ..< n_modules {
		m := &d.modules[mi]
		effective_id := roots[mi]

		// Rebuild connected_doors, keeping only doors that face outside
		i := 0
		for i < len(m.connected_doors) {
			di := m.connected_doors[i]
			slot := m.rot_doors[di]
			nx, ny := door_neighbor(slot, m.grid_x, m.grid_y)

			remove := false
			if grid_in_bounds(d, nx, ny) {
				neighbor := &d.grid[ny * W + nx]
				// If neighbor is a room cell with the same effective module, remove the door
				if neighbor.cell_type == .Room && neighbor.module_id == effective_id {
					remove = true
				}
			}

			if remove {
				// Swap with last and shrink
				last := len(m.connected_doors) - 1
				if i != last {
					m.connected_doors[i] = m.connected_doors[last]
				}
				pop(&m.connected_doors)
				// Don't increment i - check the swapped element
			} else {
				i += 1
			}
		}
	}

	d.step_done = true
}

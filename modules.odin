package dungeon_generator

// ---------------------------------------------------------------------------
// Module template definitions
// ---------------------------------------------------------------------------

Direction :: enum u8 {
	North, // -Y in grid space
	South, // +Y in grid space
	East,  // +X in grid space
	West,  // -X in grid space
}

Door_Slot :: struct {
	local_x:   int, // position relative to module top-left
	local_y:   int,
	direction: Direction,
}

Module_Template :: struct {
	name:       string,
	width:      int,
	height:     int,
	mask:       []bool, // width*height; true = cell is part of the module
	door_slots: []Door_Slot,
	color:      Color4,
}

// ---------------------------------------------------------------------------
// Template registry
// ---------------------------------------------------------------------------

// Masks: row-major, true means that cell is part of the module.
// Using global variables (not constants) so they are addressable and can be sliced.

small_room_mask := [4]bool{true, true, true, true} // 2x2
large_room_mask := [9]bool{true, true, true, true, true, true, true, true, true} // 3x3
long_hall_mask  := [8]bool{true, true, true, true, true, true, true, true} // 4x2

// L-shape (3x3 grid, bottom-right corner missing):
// X X X
// X X X
// X X .
l_shape_mask := [9]bool{
	true,  true,  true,
	true,  true,  true,
	true,  true,  false,
}

// Cross shape 3x3:
// . X .
// X X X
// . X .
cross_mask := [9]bool{
	false, true,  false,
	true,  true,  true,
	false, true,  false,
}

// Door slot arrays (also need to be addressable)
small_room_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 1, local_y = 1, direction = .South},
	{local_x = 1, local_y = 0, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

large_room_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 2, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

long_hall_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .West},
	{local_x = 0, local_y = 1, direction = .West},
	{local_x = 3, local_y = 0, direction = .East},
	{local_x = 3, local_y = 1, direction = .East},
}

l_shape_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 0, local_y = 2, direction = .South},
	{local_x = 2, local_y = 1, direction = .East},
}

cross_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 2, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Grand Hall (4x5) - all cells occupied
grand_hall_mask := [20]bool{
	true, true, true, true,
	true, true, true, true,
	true, true, true, true,
	true, true, true, true,
	true, true, true, true,
}

grand_hall_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 2, local_y = 0, direction = .North},
	{local_x = 1, local_y = 4, direction = .South},
	{local_x = 2, local_y = 4, direction = .South},
	{local_x = 3, local_y = 1, direction = .East},
	{local_x = 3, local_y = 3, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
	{local_x = 0, local_y = 3, direction = .West},
}

// Throne Room (6x8) - all cells occupied
throne_room_mask := [48]bool{
	true, true, true, true, true, true,
	true, true, true, true, true, true,
	true, true, true, true, true, true,
	true, true, true, true, true, true,
	true, true, true, true, true, true,
	true, true, true, true, true, true,
	true, true, true, true, true, true,
	true, true, true, true, true, true,
}

throne_room_doors := [?]Door_Slot{
	{local_x = 2, local_y = 0, direction = .North},
	{local_x = 3, local_y = 0, direction = .North},
	{local_x = 2, local_y = 7, direction = .South},
	{local_x = 3, local_y = 7, direction = .South},
	{local_x = 5, local_y = 2, direction = .East},
	{local_x = 5, local_y = 4, direction = .East},
	{local_x = 5, local_y = 6, direction = .East},
	{local_x = 0, local_y = 2, direction = .West},
	{local_x = 0, local_y = 4, direction = .West},
	{local_x = 0, local_y = 6, direction = .West},
}

MODULE_TEMPLATES := [?]Module_Template{
	// 0: Small Room (2x2)
	{
		name       = "Small Room",
		width      = 2,
		height     = 2,
		mask       = small_room_mask[:],
		door_slots = small_room_doors[:],
		color      = {210, 140, 70, 255}, // warm orange
	},
	// 1: Large Room (3x3)
	{
		name       = "Large Room",
		width      = 3,
		height     = 3,
		mask       = large_room_mask[:],
		door_slots = large_room_doors[:],
		color      = {70, 100, 180, 255}, // deep blue
	},
	// 2: Long Hall (4x2)
	{
		name       = "Long Hall",
		width      = 4,
		height     = 2,
		mask       = long_hall_mask[:],
		door_slots = long_hall_doors[:],
		color      = {60, 170, 160, 255}, // teal
	},
	// 3: L-Shape (3x3 with bottom-right missing)
	{
		name       = "L-Shape",
		width      = 3,
		height     = 3,
		mask       = l_shape_mask[:],
		door_slots = l_shape_doors[:],
		color      = {150, 80, 180, 255}, // purple
	},
	// 4: Cross (3x3 with corners missing)
	{
		name       = "Cross",
		width      = 3,
		height     = 3,
		mask       = cross_mask[:],
		door_slots = cross_doors[:],
		color      = {180, 60, 80, 255}, // crimson
	},
	// 5: Grand Hall (4x5)
	{
		name       = "Grand Hall",
		width      = 4,
		height     = 5,
		mask       = grand_hall_mask[:],
		door_slots = grand_hall_doors[:],
		color      = {200, 170, 50, 255}, // gold
	},
	// 6: Throne Room (6x8)
	{
		name       = "Throne Room",
		width      = 6,
		height     = 8,
		mask       = throne_room_mask[:],
		door_slots = throne_room_doors[:],
		color      = {160, 40, 40, 255}, // dark red
	},
}

// ---------------------------------------------------------------------------
// Rotation helpers
// ---------------------------------------------------------------------------

// Rotate a direction by N * 90 degrees clockwise.
// CW cycle: North -> East -> South -> West -> North
rotate_direction :: proc(dir: Direction, rot: Rotation) -> Direction {
	// Rotate one step CW at a time
	d := dir
	steps := int(rot)
	for _ in 0 ..< steps {
		switch d {
		case .North: d = .East
		case .East:  d = .South
		case .South: d = .West
		case .West:  d = .North
		}
	}
	return d
}

// Rotate a local (x, y) coordinate within a WxH bounding box by 90 CW steps.
// 90 CW:  (x, y) in WxH -> (H-1-y, x) in HxW
// 180:    (x, y) in WxH -> (W-1-x, H-1-y) in WxH
// 270 CW: (x, y) in WxH -> (y, W-1-x) in HxW
rotate_local_pos :: proc(x, y, w, h: int, rot: Rotation) -> (int, int) {
	switch rot {
	case .R0:   return x, y
	case .R90:  return h - 1 - y, x
	case .R180: return w - 1 - x, h - 1 - y
	case .R270: return y, w - 1 - x
	}
	return x, y
}

// Get the rotated dimensions.
rotated_dims :: proc(w, h: int, rot: Rotation) -> (int, int) {
	switch rot {
	case .R0, .R180: return w, h
	case .R90, .R270: return h, w
	}
	return w, h
}

// Build rotated mask from a template.
build_rotated_mask :: proc(tmpl: ^Module_Template, rot: Rotation) -> (mask: [dynamic]bool, rw: int, rh: int) {
	rw, rh = rotated_dims(tmpl.width, tmpl.height, rot)
	mask = make([dynamic]bool, rw * rh)

	for ly in 0 ..< tmpl.height {
		for lx in 0 ..< tmpl.width {
			if !tmpl.mask[ly * tmpl.width + lx] do continue
			rx, ry := rotate_local_pos(lx, ly, tmpl.width, tmpl.height, rot)
			mask[ry * rw + rx] = true
		}
	}
	return
}

// Build rotated door slots from a template.
build_rotated_doors :: proc(tmpl: ^Module_Template, rot: Rotation) -> [dynamic]Door_Slot {
	doors := make([dynamic]Door_Slot, 0, len(tmpl.door_slots))
	for slot in tmpl.door_slots {
		rx, ry := rotate_local_pos(slot.local_x, slot.local_y, tmpl.width, tmpl.height, rot)
		append(&doors, Door_Slot{
			local_x   = rx,
			local_y   = ry,
			direction = rotate_direction(slot.direction, rot),
		})
	}
	return doors
}

// ---------------------------------------------------------------------------
// Module placement helpers
// ---------------------------------------------------------------------------

// Check if a rotated module can be placed at (gx, gy) without collisions.
can_place_module :: proc(d: ^Dungeon, rot_mask: []bool, rw, rh, gx, gy: int) -> bool {
	for ly in 0 ..< rh {
		for lx in 0 ..< rw {
			if !rot_mask[ly * rw + lx] do continue
			wx := gx + lx
			wy := gy + ly
			if !grid_in_bounds(d, wx, wy) do return false
			if !grid_is_empty(d, wx, wy) do return false
			if !cell_in_active_area(d, wx, wy) do return false
		}
	}
	return true
}

// Place a module on the grid with a given rotation.
stamp_module :: proc(d: ^Dungeon, template_index: int, gx, gy: int, rot: Rotation) -> int {
	tmpl := &MODULE_TEMPLATES[template_index]
	module_id := len(d.modules)

	// Build rotated data
	rot_mask, rw, rh := build_rotated_mask(tmpl, rot)
	rot_doors := build_rotated_doors(tmpl, rot)

	// Compute center in grid coordinates
	count: f32 = 0
	cx, cy: f32 = 0, 0
	for ly in 0 ..< rh {
		for lx in 0 ..< rw {
			if !rot_mask[ly * rw + lx] do continue
			cx += f32(gx + lx) + 0.5
			cy += f32(gy + ly) + 0.5
			count += 1
		}
	}
	cx /= count
	cy /= count

	append(&d.modules, Placed_Module{
		template_index = template_index,
		rotation       = rot,
		grid_x         = gx,
		grid_y         = gy,
		center_x       = cx,
		center_y       = cy,
		rot_width      = rw,
		rot_height     = rh,
		rot_mask       = rot_mask,
		rot_doors      = rot_doors,
	})

	// Mark grid cells
	for ly in 0 ..< rh {
		for lx in 0 ..< rw {
			if !rot_mask[ly * rw + lx] do continue
			cell := grid_get(d, gx + lx, gy + ly)
			cell.cell_type = .Room
			cell.module_id = module_id
			cell.color = tmpl.color
		}
	}

	return module_id
}

// Undo a stamp_module: clear grid cells and remove the module from d.modules.
// Only safe to call on the last-appended module (pop from dynamic array).
unstamp_module :: proc(d: ^Dungeon, module_id: int) {
	assert(module_id == len(d.modules) - 1, "unstamp_module: can only remove the last module")

	m := &d.modules[module_id]

	// Clear grid cells belonging to this module
	for ly in 0 ..< m.rot_height {
		for lx in 0 ..< m.rot_width {
			if !m.rot_mask[ly * m.rot_width + lx] do continue
			wx := m.grid_x + lx
			wy := m.grid_y + ly
			if grid_in_bounds(d, wx, wy) {
				cell := grid_get(d, wx, wy)
				if cell.module_id == module_id {
					cell.cell_type = .Empty
					cell.module_id = -1
					cell.color = {0, 0, 0, 0}
				}
			}
		}
	}

	// Free and pop
	free_placed_module(m)
	pop(&d.modules)
}

// Get the global grid coordinate of the cell just outside a door.
door_neighbor :: proc(slot: Door_Slot, gx, gy: int) -> (int, int) {
	wx := gx + slot.local_x
	wy := gy + slot.local_y
	switch slot.direction {
	case .North: return wx, wy - 1
	case .South: return wx, wy + 1
	case .East:  return wx + 1, wy
	case .West:  return wx - 1, wy
	}
	return wx, wy
}

// Get the global grid coordinate of a door cell itself.
door_global :: proc(slot: Door_Slot, gx, gy: int) -> (int, int) {
	return gx + slot.local_x, gy + slot.local_y
}

package dungeon_generator

import "core:math"
import rl "vendor:raylib"

// Render settings
show_ceilings: bool = true
join_rooms: bool = true // when false, walls stay between adjacent rooms from different modules

// ---------------------------------------------------------------------------
// 3D Dungeon Renderer
// ---------------------------------------------------------------------------

render_dungeon :: proc(d: ^Dungeon) {
	cs := d.config.cell_size
	wh := d.config.wall_height
	wall_thickness: f32 = 0.05

	for gy in 0 ..< d.config.grid_height {
		for gx in 0 ..< d.config.grid_width {
			cell := &d.grid[grid_index(d, gx, gy)]
			if cell.cell_type == .Empty do continue

			// World position of cell center
			wx := f32(gx) * cs + cs * 0.5
			wz := f32(gy) * cs + cs * 0.5

			color := rl.Color{cell.color[0], cell.color[1], cell.color[2], cell.color[3]}

			// Floor
			floor_color := color_darken(color, 0.3)
			rl.DrawCube({wx, 0, wz}, cs, 0.05, cs, floor_color)

			// Ceiling
			if show_ceilings {
				ceiling_color := color_darken(color, 0.6)
				rl.DrawCube({wx, wh, wz}, cs, 0.05, cs, ceiling_color)
			}

			// Walls on edges that border empty cells (or out of bounds)
			// North wall (gy - 1)
			if should_draw_wall(d, gx, gy, 0, -1) {
				wall_color := color_darken(color, 0.15)
				rl.DrawCube(
					{wx, wh * 0.5, wz - cs * 0.5},
					cs, wh, wall_thickness,
					wall_color,
				)
			}
			// South wall (gy + 1)
			if should_draw_wall(d, gx, gy, 0, 1) {
				wall_color := color_darken(color, 0.2)
				rl.DrawCube(
					{wx, wh * 0.5, wz + cs * 0.5},
					cs, wh, wall_thickness,
					wall_color,
				)
			}
			// West wall (gx - 1)
			if should_draw_wall(d, gx, gy, -1, 0) {
				wall_color := color_darken(color, 0.1)
				rl.DrawCube(
					{wx - cs * 0.5, wh * 0.5, wz},
					wall_thickness, wh, cs,
					wall_color,
				)
			}
			// East wall (gx + 1)
			if should_draw_wall(d, gx, gy, 1, 0) {
				wall_color := color_darken(color, 0.25)
				rl.DrawCube(
					{wx + cs * 0.5, wh * 0.5, wz},
					wall_thickness, wh, cs,
					wall_color,
				)
			}
		}
	}

	// Render door markers on all placed modules
	render_doors(d)
}

// ---------------------------------------------------------------------------
// Door markers
// ---------------------------------------------------------------------------

render_doors :: proc(d: ^Dungeon) {
	cs := d.config.cell_size
	wh := d.config.wall_height
	two_sided_color      := rl.Color{255, 220, 50, 255}  // bright yellow for matching pairs
	two_sided_wire_color := rl.Color{180, 150, 30, 255}
	one_sided_color      := rl.Color{80, 220, 200, 255}   // cyan/teal for one-sided
	one_sided_wire_color := rl.Color{50, 160, 140, 255}
	door_size: f32 = cs * 0.3
	door_height: f32 = wh * 0.8

	for &m in d.modules {
		for di in m.connected_doors {
			slot := m.rot_doors[di]
			// Door cell position (on the room edge)
			dgx, dgy := door_global(slot, m.grid_x, m.grid_y)
			wx := f32(dgx) * cs + cs * 0.5
			wz := f32(dgy) * cs + cs * 0.5

			// Choose color based on two-sided vs one-sided
			is_two_sided := false
			for td in m.two_sided_doors {
				if td == di { is_two_sided = true; break }
			}
			color := is_two_sided ? two_sided_color : one_sided_color
			wire  := is_two_sided ? two_sided_wire_color : one_sided_wire_color

			// Offset toward the wall edge based on direction
			offset_x: f32 = 0
			offset_z: f32 = 0
			size_x := door_size
			size_z := door_size
			switch slot.direction {
			case .North:
				offset_z = -cs * 0.5 + door_size * 0.5
				size_x = cs * 0.6
				size_z = door_size * 0.5
			case .South:
				offset_z = cs * 0.5 - door_size * 0.5
				size_x = cs * 0.6
				size_z = door_size * 0.5
			case .East:
				offset_x = cs * 0.5 - door_size * 0.5
				size_x = door_size * 0.5
				size_z = cs * 0.6
			case .West:
				offset_x = -cs * 0.5 + door_size * 0.5
				size_x = door_size * 0.5
				size_z = cs * 0.6
			}

			rl.DrawCube(
				{wx + offset_x, door_height * 0.5, wz + offset_z},
				size_x, door_height, size_z,
				color,
			)
			rl.DrawCubeWires(
				{wx + offset_x, door_height * 0.5, wz + offset_z},
				size_x, door_height, size_z,
				wire,
			)
		}
	}
}

// Determine if a wall should be drawn on the given edge of a cell.
should_draw_wall :: proc(d: ^Dungeon, gx, gy, dx, dy: int) -> bool {
	nx := gx + dx
	ny := gy + dy
	if !grid_in_bounds(d, nx, ny) do return true

	neighbor := &d.grid[grid_index(d, nx, ny)]

	// Always wall against empty
	if neighbor.cell_type == .Empty do return true

	// Corridors always connect openly
	if neighbor.cell_type == .Corridor do return false

	// Neighbor is a Room - check join_rooms setting
	if !join_rooms {
		current := &d.grid[grid_index(d, gx, gy)]
		// Wall between cells from different modules
		if neighbor.module_id != current.module_id {
			// Check if a connected door opens this boundary edge.
			// Either side having a connected door here means no wall.
			if has_connected_door_at_edge(d, gx, gy, dx, dy) do return false
			if has_connected_door_at_edge(d, nx, ny, -dx, -dy) do return false
			return true
		}
	}

	return false
}

// Check if the module at cell (gx, gy) has a connected door pointing in direction (dx, dy).
has_connected_door_at_edge :: proc(d: ^Dungeon, gx, gy, dx, dy: int) -> bool {
	cell := &d.grid[grid_index(d, gx, gy)]
	if cell.module_id < 0 do return false

	dir: Direction
	if dx == 0 && dy == -1      { dir = .North }
	else if dx == 0 && dy == 1  { dir = .South }
	else if dx == 1 && dy == 0  { dir = .East }
	else if dx == -1 && dy == 0 { dir = .West }
	else { return false }

	m := &d.modules[cell.module_id]
	for di in m.connected_doors {
		slot := m.rot_doors[di]
		if slot.direction != dir do continue
		dgx, dgy := door_global(slot, m.grid_x, m.grid_y)
		if dgx == gx && dgy == gy do return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Grid outline (thin lines showing the grid boundary)
// ---------------------------------------------------------------------------

render_grid_outline :: proc(d: ^Dungeon) {
	cs := d.config.cell_size
	gw := d.config.grid_width
	gh := d.config.grid_height
	w := f32(gw) * cs
	h := f32(gh) * cs
	y: f32 = 0.005 // slightly above ground to avoid z-fighting

	grid_color := rl.Color{45, 45, 55, 255}

	// Vertical lines (along Z axis)
	for i in 0 ..= gw {
		x := f32(i) * cs
		rl.DrawLine3D({x, y, 0}, {x, y, h}, grid_color)
	}

	// Horizontal lines (along X axis)
	for j in 0 ..= gh {
		z := f32(j) * cs
		rl.DrawLine3D({0, y, z}, {w, y, z}, grid_color)
	}
}

// ---------------------------------------------------------------------------
// Area boundary visualization
// ---------------------------------------------------------------------------

render_areas :: proc(d: ^Dungeon) {
	cs := d.config.cell_size
	y: f32 = 0.02 // slightly above grid lines

	AREA_COLORS := [?]rl.Color{
		{100, 100, 255, 200}, // area 0 - blue
		{255, 100, 100, 200}, // area 1 - red
		{100, 255, 100, 200}, // area 2 - green
		{255, 255, 100, 200}, // area 3 - yellow
		{255, 100, 255, 200}, // area 4 - magenta
		{100, 255, 255, 200}, // area 5 - cyan
		{255, 180, 100, 200}, // area 6 - orange
		{180, 100, 255, 200}, // area 7 - purple
		{100, 200, 180, 200}, // area 8 - teal
		{200, 180, 100, 200}, // area 9 - tan
	}

	for &area in d.areas {
		color_idx := clamp(area.id, 0, len(AREA_COLORS) - 1)
		color := AREA_COLORS[color_idx]

		switch area.shape {
		case .Rectangle:
			x0 := f32(area.x) * cs
			z0 := f32(area.y) * cs
			x1 := f32(area.x + area.w) * cs
			z1 := f32(area.y + area.h) * cs
			// Draw 4 edges
			rl.DrawLine3D({x0, y, z0}, {x1, y, z0}, color)
			rl.DrawLine3D({x1, y, z0}, {x1, y, z1}, color)
			rl.DrawLine3D({x1, y, z1}, {x0, y, z1}, color)
			rl.DrawLine3D({x0, y, z1}, {x0, y, z0}, color)

		case .Circle:
			cx := f32(area.x) * cs + cs * 0.5
			cz := f32(area.y) * cs + cs * 0.5
			r := f32(area.w) * cs
			SEGMENTS :: 48
			for i in 0 ..< SEGMENTS {
				a0 := f32(i) * 2.0 * math.PI / f32(SEGMENTS)
				a1 := f32(i + 1) * 2.0 * math.PI / f32(SEGMENTS)
				p0 := rl.Vector3{cx + math.cos(a0) * r, y, cz + math.sin(a0) * r}
				p1 := rl.Vector3{cx + math.cos(a1) * r, y, cz + math.sin(a1) * r}
				rl.DrawLine3D(p0, p1, color)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Color helpers
// ---------------------------------------------------------------------------

color_darken :: proc(c: rl.Color, amount: f32) -> rl.Color {
	factor := 1.0 - amount
	return rl.Color{
		u8(f32(c.r) * factor),
		u8(f32(c.g) * factor),
		u8(f32(c.b) * factor),
		c.a,
	}
}

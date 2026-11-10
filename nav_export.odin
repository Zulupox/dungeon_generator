package dungeon_generator

import "core:fmt"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// Export the dungeon as mesh_any navigation input (.navin, integer mm).
// Format spec: D:/code/mesh_any/docs/03_formats.md
//
// Geometry is three box pieces (floor tile, ceiling tile, wall segment)
// placed with integer offsets and axis rotations, so every client that
// generates the same dungeon produces byte-identical input.
// Walls follow the renderer's rule (should_draw_wall), deduplicated per edge.
// ---------------------------------------------------------------------------

NAV_EXPORT_DIR  :: "exports"
NAV_EXPORT_PATH :: "exports/dungeon.navin"

NAV_SLAB_MM :: 100 // floor / ceiling / wall thickness in mm (even)

// Area ids written to the file (mesh_any Area_Id).
NAV_AREA_ROOM     :: 1
NAV_AREA_CORRIDOR :: 2
NAV_AREA_DOOR     :: 3
NAV_AREA_WALL     :: 4
NAV_AREA_CEILING  :: 5

nav_mm :: proc(m: f32) -> i32 {
	v := m * 1000
	return i32(v + (v >= 0 ? 0.5 : -0.5))
}

// Round up to an even number so box half extents are integral.
nav_even :: proc(v: i32) -> i32 { return v + (v & 1) }

nav_write_box_piece :: proc(b: ^strings.Builder, name: string, sx, sy, sz: i32, area: int) {
	hx, hy, hz := sx / 2, sy / 2, sz / 2
	fmt.sbprintf(b, "piece %s 8 12\n", name)
	for i in 0 ..< 8 {
		x := (i & 1) != 0 ? hx : -hx
		y := (i & 2) != 0 ? hy : -hy
		z := (i & 4) != 0 ? hz : -hz
		fmt.sbprintf(b, "v %d %d %d\n", x, y, z)
	}
	TRIS := [12][3]int{
		{0, 4, 6}, {0, 6, 2}, {1, 3, 7}, {1, 7, 5},
		{0, 1, 5}, {0, 5, 4}, {2, 6, 7}, {2, 7, 3},
		{0, 2, 3}, {0, 3, 1}, {4, 5, 7}, {4, 7, 6},
	}
	for t in TRIS do fmt.sbprintf(b, "t %d %d %d %d\n", t[0], t[1], t[2], area)
}

nav_cell_area :: proc(ct: Cell_Type) -> int {
	#partial switch ct {
	case .Corridor: return NAV_AREA_CORRIDOR
	case .Door:     return NAV_AREA_DOOR
	}
	return NAV_AREA_ROOM
}

// Does an (undirected) edge between (gx,gy) and its neighbour in (dx,dy) need a wall?
nav_edge_has_wall :: proc(d: ^Dungeon, gx, gy, dx, dy: int) -> bool {
	nx, ny := gx + dx, gy + dy
	if !grid_in_bounds(d, nx, ny) || d.grid[grid_index(d, nx, ny)].cell_type == .Empty {
		return true
	}
	// Renderer draws a wall if either side wants one.
	return should_draw_wall(d, gx, gy, dx, dy) || should_draw_wall(d, nx, ny, -dx, -dy)
}

dungeon_export_navin :: proc(d: ^Dungeon, include_ceilings := true) -> string {
	cs  := nav_mm(d.config.cell_size)
	wh  := nav_mm(d.config.wall_height)
	t   := i32(NAV_SLAB_MM)
	csE := nav_even(cs)
	whE := nav_even(wh)

	b := strings.builder_make()
	fmt.sbprintf(&b, "# dungeon_generator export, seed %d, grid %dx%d, cell %d mm, wall %d mm\n",
		d.actual_seed, d.config.grid_width, d.config.grid_height, cs, wh)
	strings.write_string(&b, "mesh_any_input 1\nunits mm\n")

	// Pieces: 0 floor, 1 ceiling, 2 wall (length along X).
	nav_write_box_piece(&b, "floor_tile",   csE, t,   csE, NAV_AREA_ROOM)
	nav_write_box_piece(&b, "ceiling_tile", csE, t,   csE, NAV_AREA_CEILING)
	nav_write_box_piece(&b, "wall_x",       csE + t, whE, t, NAV_AREA_WALL)

	ROT_ID    :: "+x+y+z"
	ROT_YAW90 :: "+z+y-x" // maps the wall's X length onto Z

	DIRS := [4][2]int{{0, -1}, {0, 1}, {-1, 0}, {1, 0}}

	for gy in 0 ..< d.config.grid_height {
		for gx in 0 ..< d.config.grid_width {
			cell := &d.grid[grid_index(d, gx, gy)]
			if cell.cell_type == .Empty do continue

			// Cell centre in mm (x right, z down the grid, y up).
			cx := i32(gx) * cs + cs / 2
			cz := i32(gy) * cs + cs / 2

			// Floor top at y = 0.
			fmt.sbprintf(&b, "place 0 %s %d %d %d %d\n", ROT_ID, cx, -t / 2, cz, nav_cell_area(cell.cell_type))
			if include_ceilings {
				fmt.sbprintf(&b, "place 1 %s %d %d %d\n", ROT_ID, cx, wh + t / 2, cz)
			}

			for dir in DIRS {
				dx, dy := dir[0], dir[1]
				nx, ny := gx + dx, gy + dy
				neighbour_open := grid_in_bounds(d, nx, ny) && d.grid[grid_index(d, nx, ny)].cell_type != .Empty
				// Interior edges are emitted once, from the cell on the -x / -y side.
				if neighbour_open && (dx < 0 || dy < 0) do continue
				if !nav_edge_has_wall(d, gx, gy, dx, dy) do continue

				wx := cx + i32(dx) * (cs / 2)
				wz := cz + i32(dy) * (cs / 2)
				rot := dx != 0 ? ROT_YAW90 : ROT_ID
				fmt.sbprintf(&b, "place 2 %s %d %d %d\n", rot, wx, wh / 2, wz)
			}
		}
	}
	return strings.to_string(b)
}

dungeon_export_navin_file :: proc(d: ^Dungeon, path: string) -> bool {
	s := dungeon_export_navin(d)
	defer delete(s)
	if dir_end := strings.last_index_any(path, "/\\"); dir_end > 0 {
		os.make_directory_all(path[:dir_end])
	}
	return os.write_entire_file(path, s) == nil
}

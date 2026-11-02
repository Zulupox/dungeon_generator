package dungeon_generator

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// Runtime module templates: ownership, editing helpers, JSON save/load
// ---------------------------------------------------------------------------

TEMPLATES_FILE :: "modules.json"
TEMPLATE_MAX_SIZE :: 16

// Deep copy; the result owns its name, mask and door slots.
template_clone :: proc(src: ^Module_Template) -> Module_Template {
	return Module_Template{
		name       = strings.clone(src.name),
		width      = src.width,
		height     = src.height,
		mask       = slice.clone(src.mask),
		door_slots = slice.clone(src.door_slots),
		color      = src.color,
	}
}

template_free :: proc(t: ^Module_Template) {
	delete(t.name)
	delete(t.mask)
	delete(t.door_slots)
}

templates_clear :: proc() {
	for &t in module_templates {
		template_free(&t)
	}
	clear(&module_templates)
}

templates_set_defaults :: proc() {
	templates_clear()
	for &t in DEFAULT_MODULE_TEMPLATES {
		append(&module_templates, template_clone(&t))
	}
}

// Load modules.json if present and valid, otherwise use the built-in templates.
templates_init :: proc() {
	if !templates_load(TEMPLATES_FILE) {
		templates_set_defaults()
	}
}

templates_destroy :: proc() {
	templates_clear()
	delete(module_templates)
}

// ---------------------------------------------------------------------------
// Editing helpers
// ---------------------------------------------------------------------------

template_cell :: proc(t: ^Module_Template, x, y: int) -> bool {
	if x < 0 || y < 0 || x >= t.width || y >= t.height do return false
	return t.mask[y * t.width + x]
}

// Set a cell; refuses to clear the last remaining cell (an empty template can't be placed).
template_set_cell :: proc(t: ^Module_Template, x, y: int, filled: bool) -> bool {
	if x < 0 || y < 0 || x >= t.width || y >= t.height do return false
	idx := y * t.width + x
	if t.mask[idx] == filled do return false
	if !filled && template_cell_count(t) <= 1 do return false
	t.mask[idx] = filled
	template_prune_doors(t)
	return true
}

// Change the template size, keeping the overlapping cells.
template_resize :: proc(t: ^Module_Template, w, h: int) {
	w := clamp(w, 1, TEMPLATE_MAX_SIZE)
	h := clamp(h, 1, TEMPLATE_MAX_SIZE)
	if w == t.width && h == t.height do return

	mask := make([]bool, w * h)
	for y in 0 ..< min(h, t.height) {
		for x in 0 ..< min(w, t.width) {
			mask[y * w + x] = t.mask[y * t.width + x]
		}
	}
	delete(t.mask)
	t.mask = mask
	t.width = w
	t.height = h
	if template_cell_count(t) == 0 do t.mask[0] = true
	template_prune_doors(t)
}

// The cell on the other side of a door edge.
door_outside_cell :: proc(x, y: int, dir: Direction) -> (int, int) {
	switch dir {
	case .North: return x, y - 1
	case .South: return x, y + 1
	case .East:  return x + 1, y
	case .West:  return x - 1, y
	}
	return x, y
}

// A door is valid on an edge between a filled cell and an empty/outside cell.
template_door_valid :: proc(t: ^Module_Template, x, y: int, dir: Direction) -> bool {
	ox, oy := door_outside_cell(x, y, dir)
	return template_cell(t, x, y) && !template_cell(t, ox, oy)
}

template_door_index :: proc(t: ^Module_Template, x, y: int, dir: Direction) -> int {
	for slot, i in t.door_slots {
		if slot.local_x == x && slot.local_y == y && slot.direction == dir do return i
	}
	return -1
}

// Add or remove a door; returns false if the edge can't hold a door.
template_toggle_door :: proc(t: ^Module_Template, x, y: int, dir: Direction) -> bool {
	if !template_door_valid(t, x, y, dir) do return false

	doors := slice.to_dynamic(t.door_slots)
	if i := template_door_index(t, x, y, dir); i >= 0 {
		ordered_remove(&doors, i)
	} else {
		append(&doors, Door_Slot{local_x = x, local_y = y, direction = dir})
	}
	delete(t.door_slots)
	t.door_slots = doors[:]
	return true
}

// Drop doors that no longer sit on an outer edge (after cells were painted or erased).
template_prune_doors :: proc(t: ^Module_Template) {
	kept := make([dynamic]Door_Slot, 0, len(t.door_slots))
	for slot in t.door_slots {
		if template_door_valid(t, slot.local_x, slot.local_y, slot.direction) {
			append(&kept, slot)
		}
	}
	delete(t.door_slots)
	t.door_slots = kept[:]
}

// ---------------------------------------------------------------------------
// JSON save/load
// ---------------------------------------------------------------------------

// Masks are stored as rows of 'X' (filled) and '.' (empty) so the file is easy to hand-edit.
Json_Door :: struct {
	x:   int    `json:"x"`,
	y:   int    `json:"y"`,
	dir: string `json:"dir"`, // "N", "S", "E", "W"
}

Json_Template :: struct {
	name:  string      `json:"name"`,
	color: [4]u8       `json:"color"`,
	rows:  []string    `json:"rows"`,
	doors: []Json_Door `json:"doors"`,
}

Json_Templates :: struct {
	templates: []Json_Template `json:"templates"`,
}

DIRECTION_CODES := [Direction]string{
	.North = "N",
	.South = "S",
	.East  = "E",
	.West  = "W",
}

templates_save :: proc(filepath: string) -> bool {
	context.allocator = context.temp_allocator

	jts := make([]Json_Template, len(module_templates))
	for &t, i in module_templates {
		rows := make([]string, t.height)
		for y in 0 ..< t.height {
			row := make([]u8, t.width)
			for x in 0 ..< t.width {
				row[x] = t.mask[y * t.width + x] ? 'X' : '.'
			}
			rows[y] = string(row)
		}
		doors := make([]Json_Door, len(t.door_slots))
		for slot, di in t.door_slots {
			doors[di] = {x = slot.local_x, y = slot.local_y, dir = DIRECTION_CODES[slot.direction]}
		}
		jts[i] = {name = t.name, color = t.color, rows = rows, doors = doors}
	}

	opts := json.Marshal_Options{
		spec   = .JSON,
		pretty = true,
	}
	data, err := json.marshal(Json_Templates{templates = jts}, opts)
	if err != nil do return false

	return os.write_entire_file(filepath, data) == nil
}

// Replace module_templates with the file's contents. Leaves them untouched on failure.
templates_load :: proc(filepath: string) -> bool {
	data, read_err := os.read_entire_file(filepath, context.temp_allocator)
	if read_err != nil do return false

	jt: Json_Templates
	if json.unmarshal(data, &jt, allocator = context.temp_allocator) != nil do return false

	loaded := make([dynamic]Module_Template)
	for &j in jt.templates {
		h := len(j.rows)
		w := 0
		for row in j.rows do w = max(w, len(row))
		if w == 0 || h == 0 || w > TEMPLATE_MAX_SIZE || h > TEMPLATE_MAX_SIZE do continue

		t := Module_Template{
			name   = strings.clone(j.name),
			width  = w,
			height = h,
			mask   = make([]bool, w * h),
			color  = j.color,
		}
		for row, y in j.rows {
			for x in 0 ..< len(row) {
				t.mask[y * w + x] = row[x] == 'X'
			}
		}
		if template_cell_count(&t) == 0 {
			template_free(&t)
			continue
		}

		doors := make([dynamic]Door_Slot)
		for jd in j.doors {
			for code, dir in DIRECTION_CODES {
				if code != jd.dir do continue
				if template_door_valid(&t, jd.x, jd.y, dir) {
					append(&doors, Door_Slot{local_x = jd.x, local_y = jd.y, direction = dir})
				}
			}
		}
		t.door_slots = doors[:]
		append(&loaded, t)
	}

	if len(loaded) == 0 {
		delete(loaded)
		return false
	}

	templates_clear()
	delete(module_templates)
	module_templates = loaded
	return true
}

package dungeon_generator

import rl "vendor:raylib"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"

import imgui "libs/odin-imgui"

// ---------------------------------------------------------------------------
// Template editor mode
//
// The template being edited is stamped alone into the dungeon grid so the normal
// renderer draws it; this file adds painting, door editing, an overlay and the panel.
// ---------------------------------------------------------------------------

Template_Editor :: struct {
	active:       bool,
	template:     int, // index into module_templates
	origin_x:     int, // grid position of the template's top-left cell
	origin_y:     int,
	// Painting (left mouse)
	painting:     bool,
	paint_value:  bool,
	// Hover feedback
	hover_ok:     bool,
	hover_x:      int, // local cell under the cursor
	hover_y:      int,
	door_ok:      bool, // a door can be toggled on the edge nearest the cursor
	door_x:       int,
	door_y:       int,
	door_dir:     Direction,
	// File state
	dirty:        bool,   // changed since last save/load
	status:       string, // result of the last save/load (string literal)
	name_buf:     [64]u8,
	// Restored on exit
	saved_camera: Top_Down_Camera,
	saved_mode:   Camera_Mode,
}

editor_current :: proc() -> ^Module_Template {
	return &module_templates[state.editor.template]
}

editor_enter :: proc() {
	ed := &state.editor
	ed.active = true
	ed.painting = false
	ed.saved_camera = state.topdown_camera
	ed.saved_mode = state.camera_mode
	if state.camera_mode == .Freeflight {
		state.camera_mode = .Top_Down
		rl.EnableCursor()
	}
	state.canvas.mode = .None
	editor_select(clamp(ed.template, 0, len(module_templates) - 1))
}

// Leave the editor and regenerate so the dungeon uses the edited templates.
editor_exit :: proc() {
	ed := &state.editor
	ed.active = false
	ed.painting = false
	state.topdown_camera = ed.saved_camera
	state.camera_mode = ed.saved_mode
	if state.camera_mode == .Freeflight do rl.DisableCursor()
	dungeon_generate_full(&state.dungeon)
}

editor_select :: proc(index: int) {
	ed := &state.editor
	ed.template = index
	ed.name_buf = {}
	copy(ed.name_buf[:len(ed.name_buf) - 1], editor_current().name)
	editor_refresh()
	editor_frame_camera()
}

// Re-stamp the edited template, centered on the grid.
editor_refresh :: proc() {
	d := &state.dungeon
	ed := &state.editor
	t := editor_current()

	dungeon_reset(d)
	d.gen_done = true
	ed.origin_x = (d.config.grid_width - t.width) / 2
	ed.origin_y = (d.config.grid_height - t.height) / 2
	stamp_module(d, ed.template, ed.origin_x, ed.origin_y, .R0)
}

// Zoom the top-down camera so the template (with some margin) fills the view.
editor_frame_camera :: proc() {
	d := &state.dungeon
	ed := &state.editor
	t := editor_current()
	cs := d.config.cell_size
	cam := &state.topdown_camera

	cam.target_x = (f32(ed.origin_x) + f32(t.width) * 0.5) * cs
	cam.target_y = (f32(ed.origin_y) + f32(t.height) * 0.5) * cs
	// fovy 45 shows about 0.83 * height vertically
	cam.height = clamp(f32(max(t.width, t.height, 6) + 4) * cs / 0.83 + d.config.wall_height, cam.min_h, cam.max_h)
}

editor_overlay_y :: proc(d: ^Dungeon) -> f32 {
	return d.config.wall_height + 0.06
}

// ---------------------------------------------------------------------------
// Update (replaces canvas_update while the editor is active)
// ---------------------------------------------------------------------------

editor_update :: proc() {
	ed := &state.editor
	ed.hover_ok = false
	ed.door_ok = false

	if !rl.IsMouseButtonDown(.LEFT) do ed.painting = false
	if state.camera_mode != .Top_Down do return
	if imgui.GetIO().WantCaptureMouse do return

	d := &state.dungeon
	t := editor_current()
	cs := d.config.cell_size

	// Raycast onto the overlay plane (ceiling height) so clicks match what is seen from above
	wx, wz, ok := screen_to_ground(rl.GetMousePosition(), get_active_rl_camera(), editor_overlay_y(d))
	if !ok do return
	fx := wx / cs - f32(ed.origin_x)
	fy := wz / cs - f32(ed.origin_y)
	cx := int(math.floor(fx))
	cy := int(math.floor(fy))

	ed.hover_ok = cx >= 0 && cy >= 0 && cx < t.width && cy < t.height
	ed.hover_x = cx
	ed.hover_y = cy
	ed.door_x, ed.door_y, ed.door_dir, ed.door_ok = editor_door_near(t, fx, fy)

	changed := false

	// Left mouse: paint/erase cells. The first cell decides whether this stroke paints or erases.
	if rl.IsMouseButtonPressed(.LEFT) && ed.hover_ok {
		ed.painting = true
		ed.paint_value = !template_cell(t, cx, cy)
	}
	if ed.painting && ed.hover_ok {
		changed |= template_set_cell(t, cx, cy, ed.paint_value)
	}

	// Right mouse: toggle a door on the outer edge nearest the cursor
	if rl.IsMouseButtonPressed(.RIGHT) && ed.door_ok {
		changed |= template_toggle_door(t, ed.door_x, ed.door_y, ed.door_dir)
	}

	if changed {
		ed.dirty = true
		editor_refresh()
	}
}

// Find the outer edge nearest a local position. Works from either side of the edge,
// so clicking just outside the room also hits its wall.
editor_door_near :: proc(t: ^Module_Template, fx, fy: f32) -> (x, y: int, dir: Direction, ok: bool) {
	cx := int(math.floor(fx))
	cy := int(math.floor(fy))
	u := fx - f32(cx)
	v := fy - f32(cy)

	// Nearest edge of the cell under the cursor
	dir = .West
	best := u
	if 1 - u < best { best = 1 - u; dir = .East }
	if v < best     { best = v;     dir = .North }
	if 1 - v < best { best = 1 - v; dir = .South }

	if template_door_valid(t, cx, cy, dir) {
		return cx, cy, dir, true
	}
	ox, oy := door_outside_cell(cx, cy, dir)
	odir := opposite_direction(dir)
	if template_door_valid(t, ox, oy, odir) {
		return ox, oy, odir, true
	}
	return 0, 0, .North, false
}

// ---------------------------------------------------------------------------
// 3D overlay (drawn inside Mode3D, above the ceilings)
// ---------------------------------------------------------------------------

editor_render_3d :: proc(d: ^Dungeon) {
	ed := &state.editor
	t := editor_current()
	cs := d.config.cell_size
	y := editor_overlay_y(d)
	ox := f32(ed.origin_x) * cs
	oz := f32(ed.origin_y) * cs
	w := f32(t.width) * cs
	h := f32(t.height) * cs

	// Cell grid inside the bounds
	grid_col := rl.Color{90, 90, 110, 255}
	for x in 0 ..= t.width {
		lx := ox + f32(x) * cs
		rl.DrawLine3D({lx, y, oz}, {lx, y, oz + h}, grid_col)
	}
	for z in 0 ..= t.height {
		lz := oz + f32(z) * cs
		rl.DrawLine3D({ox, y, lz}, {ox + w, y, lz}, grid_col)
	}

	// Hovered cell: green = will paint, red = will erase
	if ed.hover_ok {
		erase := ed.painting ? !ed.paint_value : template_cell(t, ed.hover_x, ed.hover_y)
		col := erase ? rl.Color{255, 90, 90, 90} : rl.Color{90, 255, 140, 90}
		rl.DrawCube({ox + (f32(ed.hover_x) + 0.5) * cs, y, oz + (f32(ed.hover_y) + 0.5) * cs},
			cs * 0.9, 0.01, cs * 0.9, col)
	}

	// Doors as bars along their edge
	for slot in t.door_slots {
		editor_draw_edge_bar(ox, oz, y, cs, slot.local_x, slot.local_y, slot.direction, {80, 220, 255, 255})
	}

	// Door hover: yellow = add, red = remove
	if ed.door_ok && !ed.painting {
		removing := template_door_index(t, ed.door_x, ed.door_y, ed.door_dir) >= 0
		col := removing ? rl.Color{255, 90, 90, 255} : rl.Color{255, 220, 60, 200}
		editor_draw_edge_bar(ox, oz, y + 0.01, cs, ed.door_x, ed.door_y, ed.door_dir, col)
	}
}

editor_draw_edge_bar :: proc(ox, oz, y, cs: f32, x, z: int, dir: Direction, color: rl.Color) {
	cx := ox + (f32(x) + 0.5) * cs
	cz := oz + (f32(z) + 0.5) * cs
	long := cs * 0.7
	thin := cs * 0.14
	switch dir {
	case .North: rl.DrawCube({cx, y, cz - cs * 0.5}, long, 0.02, thin, color)
	case .South: rl.DrawCube({cx, y, cz + cs * 0.5}, long, 0.02, thin, color)
	case .East:  rl.DrawCube({cx + cs * 0.5, y, cz}, thin, 0.02, long, color)
	case .West:  rl.DrawCube({cx - cs * 0.5, y, cz}, thin, 0.02, long, color)
	}
}

// ---------------------------------------------------------------------------
// Side panel (replaces the normal panel contents while the editor is active)
// ---------------------------------------------------------------------------

editor_draw_panel :: proc() {
	ed := &state.editor
	t := editor_current()
	full_w := imgui.GetContentRegionAvail().x
	half_w := (full_w - imgui.GetStyle().ItemSpacing.x) * 0.5

	imgui.Text("Template Editor")
	if imgui.Button("Exit Editor", {full_w, 0}) {
		editor_exit()
		return
	}
	imgui.Separator()

	// ---- Template selection ----
	if imgui.BeginCombo("##template", fmt.ctprintf("%d. %s", ed.template, t.name)) {
		for &tmpl, i in module_templates {
			if imgui.Selectable(fmt.ctprintf("%d. %s", i, tmpl.name), i == ed.template) {
				editor_select(i)
			}
		}
		imgui.EndCombo()
	}
	t = editor_current()

	third_w := (full_w - imgui.GetStyle().ItemSpacing.x * 2) / 3
	if imgui.Button("New", {third_w, 0}) {
		editor_add_new()
		t = editor_current()
	}
	imgui.SameLine()
	if imgui.Button("Duplicate", {third_w, 0}) {
		dup := template_clone(t)
		delete(dup.name)
		dup.name = strings.concatenate({t.name, " copy"})
		append(&module_templates, dup)
		ed.dirty = true
		editor_select(len(module_templates) - 1)
		t = editor_current()
	}
	imgui.SameLine()
	imgui.BeginDisabled(len(module_templates) <= 1)
	if imgui.Button("Delete", {third_w, 0}) {
		template_free(t)
		ordered_remove(&module_templates, ed.template)
		ed.dirty = true
		editor_select(min(ed.template, len(module_templates) - 1))
		t = editor_current()
	}
	imgui.EndDisabled()
	if imgui.IsItemHovered(imgui.HoveredFlags_AllowWhenDisabled) {
		imgui.SetTooltip("Later templates shift down one index.\nPlace Specific steps refer to templates by index.")
	}

	imgui.Separator()

	// ---- Properties ----
	if imgui.InputText("Name", cstring(&ed.name_buf[0]), len(ed.name_buf)) {
		delete(t.name)
		t.name = strings.clone_from_cstring(cstring(&ed.name_buf[0]))
		ed.dirty = true
	}

	w, h := t.width, t.height
	resized := ui_drag_int("Width", &w, 1, TEMPLATE_MAX_SIZE)
	resized |= ui_drag_int("Height", &h, 1, TEMPLATE_MAX_SIZE)
	if resized {
		template_resize(t, w, h)
		ed.dirty = true
		editor_refresh()
		editor_frame_camera()
	}

	col := [3]f32{f32(t.color[0]) / 255, f32(t.color[1]) / 255, f32(t.color[2]) / 255}
	if imgui.ColorEdit3("Color", &col) {
		t.color = {u8(col[0] * 255), u8(col[1] * 255), u8(col[2] * 255), 255}
		ed.dirty = true
		editor_refresh()
	}

	// ---- Stats ----
	imgui.Separator()
	doors := template_door_counts(t)
	imgui.Text("Cells: %d   Doors: %d", c.int(template_cell_count(t)), c.int(len(t.door_slots)))
	imgui.Text("Doors  N:%d  S:%d  E:%d  W:%d",
		c.int(doors[.North]), c.int(doors[.South]), c.int(doors[.East]), c.int(doors[.West]))
	if len(t.door_slots) == 0 {
		imgui.TextColored({1.0, 0.6, 0.3, 1.0}, "No doors: corridors and other")
		imgui.TextColored({1.0, 0.6, 0.3, 1.0}, "rooms can't connect to this one.")
	}

	// ---- File ----
	imgui.Separator()
	if imgui.Button("Save", {half_w, 0}) {
		if templates_save(TEMPLATES_FILE) {
			ed.status = "Saved to " + TEMPLATES_FILE
			ed.dirty = false
		} else {
			ed.status = "Save failed"
		}
	}
	if imgui.IsItemHovered() do imgui.SetTooltip("Write all templates to %s", cstring(TEMPLATES_FILE))
	imgui.SameLine()
	if imgui.Button("Reload", {half_w, 0}) {
		if templates_load(TEMPLATES_FILE) {
			ed.status = "Loaded " + TEMPLATES_FILE
			ed.dirty = false
			editor_select(min(ed.template, len(module_templates) - 1))
		} else {
			ed.status = "No valid " + TEMPLATES_FILE + " to load"
		}
	}
	if imgui.IsItemHovered() do imgui.SetTooltip("Discard changes and reload %s", cstring(TEMPLATES_FILE))
	if imgui.Button("Reset to Built-in", {full_w, 0}) {
		templates_set_defaults()
		ed.status = "Built-in templates restored (not saved)"
		ed.dirty = true
		editor_select(min(ed.template, len(module_templates) - 1))
	}

	if ed.dirty {
		imgui.TextColored({1.0, 0.8, 0.4, 1.0}, "Unsaved changes")
	}
	if ed.status != "" {
		imgui.TextDisabled("%s", fmt.ctprintf("%s", ed.status))
	}

	// ---- Help ----
	imgui.Separator()
	help_col := imgui.Vec4{0.5, 0.5, 0.6, 1.0}
	imgui.TextColored(help_col, "[LMB]    Paint / erase cells")
	imgui.TextColored(help_col, "[RMB]    Add / remove door on edge")
	imgui.TextColored(help_col, "[Wheel]  Zoom   [MMB] Pan")
	imgui.TextColored(help_col, "Edits apply when you exit.")
}

// Append a 3x3 room with a door in the middle of each side and select it.
editor_add_new :: proc() {
	t := Module_Template{
		name   = strings.clone("New Room"),
		width  = 3,
		height = 3,
		mask   = make([]bool, 9),
		color  = {150, 150, 160, 255},
	}
	for &cell in t.mask do cell = true
	doors := make([]Door_Slot, 4)
	doors[0] = {local_x = 1, local_y = 0, direction = .North}
	doors[1] = {local_x = 1, local_y = 2, direction = .South}
	doors[2] = {local_x = 2, local_y = 1, direction = .East}
	doors[3] = {local_x = 0, local_y = 1, direction = .West}
	t.door_slots = doors
	append(&module_templates, t)
	state.editor.dirty = true
	editor_select(len(module_templates) - 1)
}

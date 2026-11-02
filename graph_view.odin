package dungeon_generator

import "core:c"
import "core:fmt"
import "core:math"
import "core:slice"

import rl "vendor:raylib"

import imgui "libs/odin-imgui"

// ---------------------------------------------------------------------------
// Room graph view: Graph tab (score + stats) and a floating graph window
// ---------------------------------------------------------------------------

graph_view_index: int = 0     // which of the kept graphs is shown (0 = best)
show_graph_window: bool = true
show_room_labels: bool = true

ZONE_COLORS := [?]imgui.Vec4{
	{0.86, 0.72, 0.30, 1}, // gold
	{0.45, 0.62, 0.85, 1}, // blue
	{0.88, 0.52, 0.30, 1}, // orange
	{0.66, 0.42, 0.82, 1}, // purple
	{0.42, 0.76, 0.52, 1}, // green
	{0.82, 0.40, 0.50, 1}, // rose
}

zone_color :: proc(zone: int) -> imgui.Vec4 {
	return ZONE_COLORS[zone % len(ZONE_COLORS)]
}

graph_node_label :: proc(p: ^Room_Profile, g: ^Room_Graph, n: int) -> cstring {
	node := &g.nodes[n]
	t := &p.types[node.type]
	if t.count_max > 1 do return fmt.ctprintf("%s %d", t.name, node.ordinal)
	return fmt.ctprintf("%s", t.name)
}

// The graph currently shown, or nil when there is none.
graph_view_current :: proc(d: ^Dungeon) -> (^Room_Graph, ^Room_Profile) {
	if len(d.room_graphs) == 0 do return nil, nil
	graph_view_index = clamp(graph_view_index, 0, len(d.room_graphs) - 1)
	g := &d.room_graphs[graph_view_index]
	if g.profile < 0 || g.profile >= len(room_profiles) do return nil, nil
	return g, &room_profiles[g.profile]
}

// ---------------------------------------------------------------------------
// Graph tab
// ---------------------------------------------------------------------------

ui_graph_tab :: proc(d: ^Dungeon) {
	label_col := imgui.Vec4{0.6, 0.6, 0.7, 1.0}

	if len(room_profiles) == 0 {
		imgui.TextWrapped("No profiles loaded. Put room profiles in %s/*.json.", PROFILES_DIR)
		return
	}

	g, p := graph_view_current(d)
	if g == nil {
		imgui.TextWrapped("No room graph yet. Add a Room Graph step to the recipe (or pick the Apartment / Dungeon Keep preset) and generate.")
		return
	}

	imgui.TextColored(label_col, "Profile:")
	imgui.SameLine()
	imgui.Text("%s", fmt.ctprintf("%s", p.name))
	imgui.TextColored(label_col, "Rooms:")
	imgui.SameLine()
	imgui.Text("%d  Edges: %d", c.int(len(g.nodes)), c.int(len(g.edges)))
	if room_graph_is_placed(g) {
		placed_rooms, realized := room_graph_placement_counts(g)
		ok_col := imgui.Vec4{0.5, 0.85, 0.5, 1}
		bad_col := imgui.Vec4{0.9, 0.5, 0.45, 1}
		imgui.TextColored(label_col, "Placed:")
		imgui.SameLine()
		imgui.TextColored(placed_rooms == len(g.nodes) ? ok_col : bad_col, "%d/%d rooms", c.int(placed_rooms), c.int(len(g.nodes)))
		imgui.SameLine()
		imgui.TextColored(realized == len(g.edges) ? ok_col : bad_col, " %d/%d edges", c.int(realized), c.int(len(g.edges)))
		if imgui.IsItemHovered() do imgui.SetTooltip("Edges with a door or corridor.\nUnrealized edges are dashed red in the graph window.")
	}
	imgui.TextColored(label_col, "Attempts:")
	imgui.SameLine()
	imgui.Text("%d valid of %d", c.int(g.valid), c.int(g.attempts))
	imgui.TextColored(label_col, "Avg score:")
	imgui.SameLine()
	imgui.Text("%.1f", g.avg_score)

	if len(d.room_graphs) > 1 {
		imgui.TextColored(label_col, "Show:")
		for i in 0 ..< len(d.room_graphs) {
			imgui.SameLine()
			label := i == 0 ? fmt.ctprintf("Best##g%d", i) : fmt.ctprintf("#%d##g%d", i + 1, i)
			if imgui.RadioButton(label, graph_view_index == i) do graph_view_index = i
		}
	}

	imgui.Separator()
	imgui.Text("Score: %.1f", g.score)
	for kind in Score_Kind {
		v := g.terms[kind]
		col := v > 0 ? imgui.Vec4{0.5, 0.85, 0.5, 1} : v < 0 ? imgui.Vec4{0.9, 0.5, 0.45, 1} : label_col
		imgui.TextColored(label_col, "  %s", SCORE_KIND_NAMES[kind])
		imgui.SameLine(190)
		imgui.TextColored(col, "%+.1f", v)
	}

	imgui.Separator()
	imgui.Text("Zones")
	for zone, zi in p.zones {
		imgui.ColorButton(fmt.ctprintf("##zone%d", zi), zone_color(zi), {.NoTooltip}, {12, 12})
		imgui.SameLine()
		imgui.Text("%s", fmt.ctprintf("%d. %s", zi, zone))
	}

	imgui.Separator()
	imgui.Checkbox("Show graph window", &show_graph_window)
	imgui.Checkbox("Label placed rooms", &show_room_labels)
}

// ---------------------------------------------------------------------------
// Graph window
// ---------------------------------------------------------------------------

// Layered layout: column = depth from the entry; rows ordered by the average
// row of each node's neighbours in the previous column to reduce crossings.
graph_layout :: proc(g: ^Room_Graph, origin, size: imgui.Vec2) -> []imgui.Vec2 {
	n := len(g.nodes)
	pos := make([]imgui.Vec2, n, context.temp_allocator)
	row_key := make([]f32, n, context.temp_allocator)

	// Unreachable nodes (depth -1) go in an extra column on the right
	max_depth := 0
	has_unreached := false
	for node in g.nodes {
		max_depth = max(max_depth, node.depth)
		if node.depth < 0 do has_unreached = true
	}
	columns := max_depth + 1 + (has_unreached ? 1 : 0)

	MARGIN_X :: 60
	MARGIN_Y :: 24
	usable_w := max(size.x - 2 * MARGIN_X, 1)
	usable_h := max(size.y - 2 * MARGIN_Y, 1)

	Keyed :: struct {
		id:  int,
		key: f32,
	}

	for col in 0 ..< columns {
		ids := make([dynamic]Keyed, 0, n, context.temp_allocator)
		for node, i in g.nodes {
			depth := node.depth >= 0 ? node.depth : max_depth + 1
			if depth != col do continue

			// Barycenter of neighbours in earlier columns
			sum: f32 = 0
			count := 0
			for e in g.edges {
				other := e.a == i ? e.b : e.b == i ? e.a : -1
				if other < 0 do continue
				od := g.nodes[other].depth
				if od >= 0 && od < col {
					sum += row_key[other]
					count += 1
				}
			}
			append(&ids, Keyed{i, count > 0 ? sum / f32(count) : f32(i)})
		}
		slice.stable_sort_by(ids[:], proc(a, b: Keyed) -> bool { return a.key < b.key })

		x := origin.x + MARGIN_X + (columns > 1 ? usable_w * f32(col) / f32(columns - 1) : usable_w * 0.5)
		for k, row in ids {
			pos[k.id] = {x, origin.y + MARGIN_Y + usable_h * (f32(row) + 0.5) / f32(len(ids))}
			row_key[k.id] = (f32(row) + 0.5) / f32(len(ids)) // normalised row for later columns
		}
	}
	return pos
}

draw_graph_window :: proc(d: ^Dungeon) {
	if !show_graph_window do return
	g, p := graph_view_current(d)
	if g == nil do return

	display := imgui.GetIO().DisplaySize
	imgui.SetNextWindowSize({620, 380}, .FirstUseEver)
	imgui.SetNextWindowPos({display.x - 630, display.y - 390}, .FirstUseEver)
	open := true
	if !imgui.Begin(fmt.ctprintf("Room Graph: %s  (score %.1f)###room_graph", p.name, g.score), &open, {.NoFocusOnAppearing}) {
		imgui.End()
		return
	}
	defer imgui.End()
	if !open {
		show_graph_window = false
		return
	}

	origin := imgui.GetCursorScreenPos()
	size := imgui.GetContentRegionAvail()
	if size.x < 50 || size.y < 50 do return
	imgui.InvisibleButton("##graph_canvas", size)

	dl := imgui.GetWindowDrawList()
	pos := graph_layout(g, origin, size)
	u32col :: imgui.ColorConvertFloat4ToU32

	// Edges first so nodes sit on top. Unrealized edges (after placement) are dashed red.
	placed := room_graph_is_placed(g)
	for e in g.edges {
		t := clamp(e.weight / 100, 0.1, 1)
		col: imgui.Vec4 = e.tree ? {0.9, 0.9, 0.92, 0.35 + 0.55 * t} : {0.45, 0.7, 1.0, 0.3 + 0.5 * t}
		thick: f32 = e.tree ? 1 + 2.5 * t : 1 + 1.2 * t
		if placed && !e.realized {
			draw_dashed_line(dl, pos[e.a], pos[e.b], u32col({1.0, 0.35, 0.3, 0.9}), 2)
			continue
		}
		imgui.DrawList_AddLine(dl, pos[e.a], pos[e.b], u32col(col), thick)
	}

	// Nodes
	hovered := -1
	mouse := imgui.GetMousePos()
	for node, i in g.nodes {
		label := graph_node_label(p, g, i)
		ts := imgui.CalcTextSize(label)
		half := imgui.Vec2{ts.x * 0.5 + 6, ts.y * 0.5 + 4}
		lo := pos[i] - half
		hi := pos[i] + half
		zc := zone_color(p.types[node.type].zone)

		imgui.DrawList_AddRectFilled(dl, lo, hi, u32col({zc.x * 0.45, zc.y * 0.45, zc.z * 0.45, 1}), 4)
		border: f32 = i == g.entry ? 2.5 : 1.5
		imgui.DrawList_AddRect(dl, lo, hi, u32col(zc), 4, {}, border)
		imgui.DrawList_AddText(dl, {pos[i].x - ts.x * 0.5, pos[i].y - ts.y * 0.5}, u32col({1, 1, 1, 1}), label)

		if mouse.x >= lo.x && mouse.x <= hi.x && mouse.y >= lo.y && mouse.y <= hi.y do hovered = i
	}

	if hovered >= 0 && imgui.IsItemHovered() {
		node := &g.nodes[hovered]
		t := &p.types[node.type]
		imgui.BeginTooltip()
		imgui.Text("%s", graph_node_label(p, g, hovered))
		imgui.Text("Zone:  %s", fmt.ctprintf("%s", p.zones[t.zone]))
		imgui.Text("Depth: %d%s", c.int(node.depth), node.depth > t.max_depth && t.max_depth > 0 ? cstring("  (over max)") : cstring(""))
		imgui.Text("Doors: %d", c.int(room_graph_degree(g, hovered)))
		if len(t.templates) > 0 {
			imgui.Text("Templates:")
			for name in t.templates do imgui.Text("  %s", fmt.ctprintf("%s", name))
		}
		imgui.EndTooltip()
	}
}

// ---------------------------------------------------------------------------
// Room Graph step parameters
// ---------------------------------------------------------------------------

ui_room_graph_params :: proc(params: ^Room_Graph_Params) {
	if len(room_profiles) == 0 {
		imgui.TextColored({0.9, 0.5, 0.45, 1}, "No profiles in %s/", PROFILES_DIR)
		return
	}
	current := find_profile(params.profile)
	preview: cstring = current >= 0 ? fmt.ctprintf("%s", room_profiles[current].name) : "(first profile)"
	if imgui.BeginCombo("Profile", preview) {
		for &p, i in room_profiles {
			if imgui.Selectable(fmt.ctprintf("%s##p%d", p.name, i), i == current) {
				params.profile = p.name
			}
		}
		imgui.EndCombo()
	}
	ui_drag_int("Attempts", &params.attempts, 0, 2000)
	if imgui.IsItemHovered() do imgui.SetTooltip("Graphs sampled; the best one is kept.\n0 = use the profile's setting.")
}

// True once a Place Graph step has placed at least one room of this graph.
room_graph_is_placed :: proc(g: ^Room_Graph) -> bool {
	for n in g.nodes {
		if n.module_id >= 0 do return true
	}
	return false
}

draw_dashed_line :: proc(dl: ^imgui.DrawList, a, b: imgui.Vec2, col: u32, thickness: f32) {
	DASH :: 6
	d := b - a
	length := math.sqrt(d.x * d.x + d.y * d.y)
	if length < 1 do return
	dir := d / length
	for t: f32 = 0; t < length; t += DASH * 2 {
		imgui.DrawList_AddLine(dl, a + dir * t, a + dir * min(t + DASH, length), col, thickness)
	}
}

room_graph_placement_counts :: proc(g: ^Room_Graph) -> (placed_rooms, realized_edges: int) {
	for n in g.nodes {
		if n.module_id >= 0 do placed_rooms += 1
	}
	for e in g.edges {
		if e.realized do realized_edges += 1
	}
	return
}

// Room type names over graph-placed rooms, drawn behind the UI panel.
draw_graph_room_labels :: proc(d: ^Dungeon, camera: rl.Camera3D) {
	if len(d.room_graphs) == 0 || !show_room_labels do return
	g := &d.room_graphs[0]
	if g.profile < 0 || g.profile >= len(room_profiles) do return
	p := &room_profiles[g.profile]

	draw_list := imgui.GetBackgroundDrawList()
	forward := rl.Vector3Normalize(camera.target - camera.position)
	cs := d.config.cell_size
	bg := imgui.ColorConvertFloat4ToU32({0, 0, 0, 0.6})
	fg := imgui.ColorConvertFloat4ToU32({1, 1, 1, 1})

	for node, i in g.nodes {
		if node.module_id < 0 || node.module_id >= len(d.modules) do continue
		m := &d.modules[node.module_id]
		world := rl.Vector3{m.center_x * cs, d.config.wall_height + 0.05, m.center_y * cs}
		if rl.Vector3DotProduct(world - camera.position, forward) <= 0 do continue

		screen := rl.GetWorldToScreen(world, camera)
		label := graph_node_label(p, g, i)
		size := imgui.CalcTextSize(label)
		lo := imgui.Vec2{screen.x - size.x * 0.5 - 3, screen.y - size.y * 0.5 - 1}
		imgui.DrawList_AddRectFilled(draw_list, lo, {lo.x + size.x + 6, lo.y + size.y + 2}, bg, 3)
		imgui.DrawList_AddText(draw_list, {lo.x + 3, lo.y + 1}, fg, label)
	}
}

package dungeon_generator

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// Semantic room graph
//
// A profile (profiles/*.json) describes room types, privacy zones and weighted
// connection rules. A Room_Graph is one sampled set of rooms + connections,
// scored against the profile. Generation runs many attempts and keeps the best.
// ---------------------------------------------------------------------------

PROFILES_DIR :: "profiles"
GRAPH_KEEP_BEST :: 3 // best graphs kept per Room_Graph step (fallbacks for placement)

Room_Type_Def :: struct {
	name:       string,
	zone:       int,      // index into profile.zones; higher = more private
	count_min:  int,
	count_max:  int,
	entry:      bool,     // graph grows from the first room of an entry type
	max_doors:  int,      // hard cap on connections, 0 = unlimited
	pref_doors: int,      // soft cap, scored as door_overflow, 0 = none
	max_depth:  int,      // max hops from the entry, scored as depth_overflow, 0 = none
	templates:  []string, // module template names this room may use
	color:      Color4,
}

Only_Via_Rule :: struct {
	room:  int, // room type
	via:   int, // room type that must not be the only way in
	score: f32, // added when violated (usually negative)
}

Graph_Scoring :: struct {
	edge_weight:       f32 `json:"edge_weight"`,       // multiplier for mean (w - 50) / 50 over all edges
	zone_order:        f32 `json:"zone_order"`,        // penalty per zone step backwards along the tree
	depth_overflow:    f32 `json:"depth_overflow"`,    // penalty per hop beyond max_depth
	door_overflow:     f32 `json:"door_overflow"`,     // penalty per connection beyond pref_doors
	extra_edge_chance: f32 `json:"extra_edge_chance"`, // loop edge chance, scaled by w / 100
	default_weight:    f32 `json:"default_weight"`,    // pair weight when no rule or zone transition applies
}

DEFAULT_GRAPH_SCORING :: Graph_Scoring{
	edge_weight       = 40,
	zone_order        = 20,
	depth_overflow    = 30,
	door_overflow     = 30,
	extra_edge_chance = 0.3,
	default_weight    = 10,
}

Room_Profile :: struct {
	name:        string,
	zones:       []string,
	attempts:    int,
	types:       []Room_Type_Def,
	pair_weight: []f32, // len(types)^2, symmetric; 0 = never connect
	pair_bonus:  []f32, // len(types)^2, symmetric; score added per matching edge
	only_via:    []Only_Via_Rule,
	scoring:     Graph_Scoring,
}

room_profiles: [dynamic]Room_Profile

profile_pair_weight :: proc(p: ^Room_Profile, a, b: int) -> f32 {
	return p.pair_weight[a * len(p.types) + b]
}

profile_pair_bonus :: proc(p: ^Room_Profile, a, b: int) -> f32 {
	return p.pair_bonus[a * len(p.types) + b]
}

find_profile :: proc(name: string) -> int {
	for &p, i in room_profiles {
		if p.name == name do return i
	}
	return -1
}

// ---------------------------------------------------------------------------
// Graph data
// ---------------------------------------------------------------------------

Graph_Node :: struct {
	type:      int, // index into profile.types
	ordinal:   int, // 1-based number among nodes of the same type ("Bedroom 2")
	depth:     int, // hops from the entry node
	module_id: int, // placed module, -1 = not placed
}

Graph_Edge :: struct {
	a, b:     int,
	weight:   f32,
	tree:     bool, // part of the spanning tree (vs. an extra loop edge)
	realized: bool, // has a door or corridor in the geometry
}

Score_Kind :: enum {
	Edge_Weight,
	Rule_Bonus,
	Zone_Order,
	Depth_Overflow,
	Door_Overflow,
	Only_Via,
}

SCORE_KIND_NAMES := [Score_Kind]cstring{
	.Edge_Weight    = "Edge weights",
	.Rule_Bonus     = "Rule bonuses",
	.Zone_Order     = "Zone order",
	.Depth_Overflow = "Depth overflow",
	.Door_Overflow  = "Door overflow",
	.Only_Via       = "Only-via rules",
}

Room_Graph :: struct {
	profile: int,
	entry:   int, // entry node index
	nodes:   [dynamic]Graph_Node,
	edges:   [dynamic]Graph_Edge,
	score:   f32,
	terms:   [Score_Kind]f32,
	// Stats from the generation run that produced this graph
	attempts:   int,
	valid:      int,
	best_score: f32,
	avg_score:  f32,
}

room_graph_destroy :: proc(g: ^Room_Graph) {
	delete(g.nodes)
	delete(g.edges)
}

room_graph_clone :: proc(src: ^Room_Graph) -> Room_Graph {
	g := src^
	g.nodes = make([dynamic]Graph_Node, len(src.nodes))
	copy(g.nodes[:], src.nodes[:])
	g.edges = make([dynamic]Graph_Edge, len(src.edges))
	copy(g.edges[:], src.edges[:])
	return g
}

room_graph_degree :: proc(g: ^Room_Graph, n: int) -> int {
	deg := 0
	for e in g.edges {
		if e.a == n || e.b == n do deg += 1
	}
	return deg
}

room_graph_has_edge :: proc(g: ^Room_Graph, a, b: int) -> bool {
	for e in g.edges {
		if (e.a == a && e.b == b) || (e.a == b && e.b == a) do return true
	}
	return false
}

// BFS hop counts from the entry, skipping nodes of type `skip_type` (-1 = skip none).
// Unreached nodes get -1. Result is in the temp allocator.
room_graph_bfs :: proc(g: ^Room_Graph, skip_type: int = -1) -> []int {
	dist := make([]int, len(g.nodes), context.temp_allocator)
	slice.fill(dist, -1)
	if len(g.nodes) == 0 do return dist

	queue := make([dynamic]int, 0, len(g.nodes), context.temp_allocator)
	dist[g.entry] = 0
	append(&queue, g.entry)
	for head := 0; head < len(queue); head += 1 {
		n := queue[head]
		for e in g.edges {
			other := -1
			if e.a == n do other = e.b
			if e.b == n do other = e.a
			if other < 0 || dist[other] >= 0 do continue
			if g.nodes[other].type == skip_type do continue
			dist[other] = dist[n] + 1
			append(&queue, other)
		}
	}
	return dist
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

// Room has a free connection slot under its type's hard cap.
node_has_free_door :: proc(p: ^Room_Profile, g: ^Room_Graph, degree: []int, n: int) -> bool {
	max_doors := p.types[g.nodes[n].type].max_doors
	return max_doors <= 0 || degree[n] < max_doors
}

// One weighted-growth attempt. Fails if some room can't be connected.
room_graph_attempt :: proc(p: ^Room_Profile, g: ^Room_Graph) -> bool {
	clear(&g.nodes)
	clear(&g.edges)
	g.entry = -1

	// 1. Instantiate rooms
	for &t, ti in p.types {
		n := t.count_min + rand.int_max(max(t.count_max - t.count_min, 0) + 1)
		for k in 0 ..< n {
			if t.entry && g.entry < 0 do g.entry = len(g.nodes)
			append(&g.nodes, Graph_Node{type = ti, ordinal = k + 1, module_id = -1})
		}
	}
	n := len(g.nodes)
	if n == 0 do return false
	if g.entry < 0 do g.entry = 0

	connected := make([]bool, n, context.temp_allocator)
	degree := make([]int, n, context.temp_allocator)
	connected[g.entry] = true

	// 2. Weighted spanning growth: roulette over (unconnected, connected) pairs
	for _ in 1 ..< n {
		total: f32 = 0
		for u in 0 ..< n {
			if connected[u] do continue
			for v in 0 ..< n {
				if !connected[v] || !node_has_free_door(p, g, degree, v) do continue
				total += profile_pair_weight(p, g.nodes[u].type, g.nodes[v].type)
			}
		}
		if total <= 0 do return false

		pick := rand.float32() * total
		pu, pv := -1, -1
		pick_loop: for u in 0 ..< n {
			if connected[u] do continue
			for v in 0 ..< n {
				if !connected[v] || !node_has_free_door(p, g, degree, v) do continue
				w := profile_pair_weight(p, g.nodes[u].type, g.nodes[v].type)
				if w <= 0 do continue
				pu, pv = u, v
				pick -= w
				if pick <= 0 do break pick_loop
			}
		}

		append(&g.edges, Graph_Edge{a = pv, b = pu, weight = profile_pair_weight(p, g.nodes[pu].type, g.nodes[pv].type), tree = true})
		connected[pu] = true
		degree[pu] += 1
		degree[pv] += 1
	}

	// 3. Extra loop edges
	for a in 0 ..< n {
		for b in a + 1 ..< n {
			w := profile_pair_weight(p, g.nodes[a].type, g.nodes[b].type)
			if w <= 0 || room_graph_has_edge(g, a, b) do continue
			if !node_has_free_door(p, g, degree, a) || !node_has_free_door(p, g, degree, b) do continue
			if rand.float32() < p.scoring.extra_edge_chance * w / 100 {
				append(&g.edges, Graph_Edge{a = a, b = b, weight = w})
				degree[a] += 1
				degree[b] += 1
			}
		}
	}

	// 4. Depths
	dist := room_graph_bfs(g)
	for &node, i in g.nodes {
		node.depth = dist[i]
	}
	return true
}

room_graph_score :: proc(p: ^Room_Profile, g: ^Room_Graph) {
	g.terms = {}
	sc := &p.scoring

	for e in g.edges {
		ta, tb := g.nodes[e.a].type, g.nodes[e.b].type
		g.terms[.Edge_Weight] += (e.weight - 50) / 50 * sc.edge_weight / f32(len(g.edges))
		g.terms[.Rule_Bonus] += profile_pair_bonus(p, ta, tb)

		// Privacy should not decrease moving away from the entry
		if e.tree {
			parent, child := e.a, e.b
			if g.nodes[child].depth < g.nodes[parent].depth do parent, child = child, parent
			drop := p.types[g.nodes[parent].type].zone - p.types[g.nodes[child].type].zone
			if drop > 0 do g.terms[.Zone_Order] -= f32(drop) * sc.zone_order
		}
	}

	for &node, i in g.nodes {
		t := &p.types[node.type]
		if t.max_depth > 0 && node.depth > t.max_depth {
			g.terms[.Depth_Overflow] -= f32(node.depth - t.max_depth) * sc.depth_overflow
		}
		if t.pref_doors > 0 {
			extra := room_graph_degree(g, i) - t.pref_doors
			if extra > 0 do g.terms[.Door_Overflow] -= f32(extra) * sc.door_overflow
		}
	}

	for rule in p.only_via {
		dist := room_graph_bfs(g, rule.via)
		for &node, i in g.nodes {
			if node.type == rule.room && dist[i] < 0 do g.terms[.Only_Via] += rule.score
		}
	}

	g.score = 0
	for v in g.terms do g.score += v
}

// Run `attempts` attempts and return up to GRAPH_KEEP_BEST graphs, best first.
// Every returned graph carries the run's stats. Caller owns the result.
room_graph_generate :: proc(profile_idx: int, attempts: int) -> [dynamic]Room_Graph {
	best := make([dynamic]Room_Graph)
	if profile_idx < 0 || profile_idx >= len(room_profiles) do return best
	p := &room_profiles[profile_idx]

	scratch := Room_Graph{profile = profile_idx}
	defer room_graph_destroy(&scratch)

	valid := 0
	total_score: f32 = 0
	for _ in 0 ..< max(attempts, 1) {
		if !room_graph_attempt(p, &scratch) do continue
		room_graph_score(p, &scratch)
		valid += 1
		total_score += scratch.score

		// Insert into the sorted best list
		pos := len(best)
		for b, i in best {
			if scratch.score > b.score {
				pos = i
				break
			}
		}
		if pos >= GRAPH_KEEP_BEST do continue
		inject_at(&best, pos, room_graph_clone(&scratch))
		if len(best) > GRAPH_KEEP_BEST {
			room_graph_destroy(&best[len(best) - 1])
			pop(&best)
		}
	}

	for &g in best {
		g.attempts = max(attempts, 1)
		g.valid = valid
		g.best_score = best[0].score
		g.avg_score = total_score / f32(valid)
	}
	return best
}

// Recipe step: replace the dungeon's room graphs with a fresh run.
execute_room_graph :: proc(d: ^Dungeon, params: ^Room_Graph_Params) {
	dungeon_clear_room_graphs(d)
	pi := find_profile(params.profile)
	if pi < 0 && len(room_profiles) > 0 do pi = 0
	if pi >= 0 {
		attempts := params.attempts > 0 ? params.attempts : room_profiles[pi].attempts
		delete(d.room_graphs)
		d.room_graphs = room_graph_generate(pi, attempts)
	}
	d.step_done = true
}

dungeon_clear_room_graphs :: proc(d: ^Dungeon) {
	for &g in d.room_graphs {
		room_graph_destroy(&g)
	}
	clear(&d.room_graphs)
}

// ---------------------------------------------------------------------------
// Profile loading
// ---------------------------------------------------------------------------

Json_Room_Type :: struct {
	name:       string    `json:"name"`,
	zone:       string    `json:"zone"`,
	count:      [2]int    `json:"count"`,
	entry:      bool      `json:"entry"`,
	max_doors:  int       `json:"max_doors"`,
	pref_doors: int       `json:"pref_doors"`,
	max_depth:  int       `json:"max_depth"`,
	templates:  []string  `json:"templates"`,
	color:      [4]u8     `json:"color"`,
}

Json_Connection :: struct {
	a:      string `json:"a"`,
	b:      string `json:"b"`,
	weight: f32    `json:"weight"`,
	bonus:  f32    `json:"bonus"`,
}

Json_Pair :: struct {
	a: string `json:"a"`,
	b: string `json:"b"`,
}

Json_Only_Via :: struct {
	room:  string `json:"room"`,
	via:   string `json:"via"`,
	score: f32    `json:"score"`,
}

Json_Profile :: struct {
	name:             string            `json:"name"`,
	zones:            []string          `json:"zones"`,
	attempts:         int               `json:"attempts"`,
	room_types:       []Json_Room_Type  `json:"room_types"`,
	connections:      []Json_Connection `json:"connections"`,
	forbidden:        []Json_Pair       `json:"forbidden"`,
	zone_transitions: []Json_Connection `json:"zone_transitions"`,
	only_via:         []Json_Only_Via   `json:"only_via"`,
	scoring:          Graph_Scoring     `json:"scoring"`,
}

index_of_string :: proc(list: []string, s: string) -> int {
	for item, i in list {
		if item == s do return i
	}
	return -1
}

// Load one profile file. Unknown zone/type names make the rule (or room type) be skipped.
room_profile_load :: proc(filepath: string) -> (p: Room_Profile, ok: bool) {
	data, read_err := os.read_entire_file(filepath, context.temp_allocator)
	if read_err != nil do return {}, false

	jp := Json_Profile{scoring = DEFAULT_GRAPH_SCORING}
	if json.unmarshal(data, &jp, allocator = context.temp_allocator) != nil do return {}, false
	if len(jp.zones) == 0 || len(jp.room_types) == 0 do return {}, false

	p.name = strings.clone(jp.name != "" ? jp.name : filepath)
	p.attempts = jp.attempts > 0 ? jp.attempts : 100
	p.scoring = jp.scoring

	p.zones = make([]string, len(jp.zones))
	for z, i in jp.zones do p.zones[i] = strings.clone(z)

	types := make([dynamic]Room_Type_Def)
	type_names := make([dynamic]string, context.temp_allocator)
	for &jt in jp.room_types {
		zone := index_of_string(jp.zones, jt.zone)
		if zone < 0 || jt.name == "" do continue
		t := Room_Type_Def{
			name       = strings.clone(jt.name),
			zone       = zone,
			count_min  = max(jt.count[0], 0),
			count_max  = max(jt.count[1], jt.count[0], 0),
			entry      = jt.entry,
			max_doors  = jt.max_doors,
			pref_doors = jt.pref_doors,
			max_depth  = jt.max_depth,
			templates  = make([]string, len(jt.templates)),
			color      = jt.color.a > 0 ? jt.color : {160, 160, 160, 255},
		}
		for name, i in jt.templates do t.templates[i] = strings.clone(name)
		append(&types, t)
		append(&type_names, jt.name)
	}
	p.types = types[:]
	nt := len(p.types)

	// Pair weights: zone transitions, then explicit rules, then forbidden (strongest)
	p.pair_weight = make([]f32, nt * nt)
	p.pair_bonus = make([]f32, nt * nt)
	set_pair :: proc(m: []f32, nt, a, b: int, v: f32) {
		m[a * nt + b] = v
		m[b * nt + a] = v
	}
	for a in 0 ..< nt {
		for b in 0 ..< nt {
			p.pair_weight[a * nt + b] = p.scoring.default_weight
		}
	}
	for zt in jp.zone_transitions {
		za := index_of_string(jp.zones, zt.a)
		zb := index_of_string(jp.zones, zt.b)
		if za < 0 || zb < 0 do continue
		for a in 0 ..< nt {
			for b in 0 ..< nt {
				if p.types[a].zone == za && p.types[b].zone == zb do set_pair(p.pair_weight, nt, a, b, zt.weight)
			}
		}
	}
	for cr in jp.connections {
		a := index_of_string(type_names[:], cr.a)
		b := index_of_string(type_names[:], cr.b)
		if a < 0 || b < 0 do continue
		set_pair(p.pair_weight, nt, a, b, cr.weight)
		set_pair(p.pair_bonus, nt, a, b, cr.bonus)
	}
	for fp in jp.forbidden {
		a := index_of_string(type_names[:], fp.a)
		b := index_of_string(type_names[:], fp.b)
		if a < 0 || b < 0 do continue
		set_pair(p.pair_weight, nt, a, b, 0)
		set_pair(p.pair_bonus, nt, a, b, 0)
	}

	rules := make([dynamic]Only_Via_Rule)
	for ov in jp.only_via {
		room := index_of_string(type_names[:], ov.room)
		via := index_of_string(type_names[:], ov.via)
		if room < 0 || via < 0 do continue
		append(&rules, Only_Via_Rule{room = room, via = via, score = ov.score})
	}
	p.only_via = rules[:]

	return p, true
}

room_profile_free :: proc(p: ^Room_Profile) {
	delete(p.name)
	for z in p.zones do delete(z)
	delete(p.zones)
	for &t in p.types {
		delete(t.name)
		for name in t.templates do delete(name)
		delete(t.templates)
	}
	delete(p.types)
	delete(p.pair_weight)
	delete(p.pair_bonus)
	delete(p.only_via)
}

// Load every profiles/*.json, sorted by file name.
room_profiles_init :: proc() {
	infos, err := os.read_all_directory_by_path(PROFILES_DIR, context.temp_allocator)
	if err != nil do return
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for info in infos {
		if !strings.has_suffix(info.name, ".json") do continue
		if p, ok := room_profile_load(info.fullpath); ok {
			append(&room_profiles, p)
		}
	}
}

room_profiles_destroy :: proc() {
	for &p in room_profiles do room_profile_free(&p)
	delete(room_profiles)
}

// ---------------------------------------------------------------------------
// Self-test: odin run . -define:GRAPH_SELFTEST=true
// ---------------------------------------------------------------------------

GRAPH_SELFTEST :: #config(GRAPH_SELFTEST, false)

room_graph_selftest :: proc() -> bool {
	SEEDS :: 500
	all_ok := true
	for &p, pi in room_profiles {
		failures := 0
		min_s, max_s, sum_s: f32 = 1e9, -1e9, 0
		generated := 0
		for seed in 1 ..= SEEDS {
			rand.reset(u64(seed))
			graphs := room_graph_generate(pi, p.attempts)
			defer {
				for &g in graphs do room_graph_destroy(&g)
				delete(graphs)
			}
			if len(graphs) == 0 {
				failures += 1
				continue
			}
			g := &graphs[0]
			generated += 1
			min_s = min(min_s, g.score)
			max_s = max(max_s, g.score)
			sum_s += g.score

			if seed <= 2 do room_graph_print(&p, g)

			problem := room_graph_check(&p, g)
			if problem != "" {
				fmt.printf("  [%s] seed %d: %s\n", p.name, seed, problem)
				all_ok = false
			}
			free_all(context.temp_allocator)
		}
		fmt.printf("%-20s %d/%d seeds produced a graph, score min %.1f avg %.1f max %.1f\n",
			p.name, generated, SEEDS, min_s, sum_s / f32(max(generated, 1)), max_s)
		if failures > 0 do all_ok = false
	}
	if len(room_profiles) == 0 {
		fmt.printf("no profiles found in %s/\n", PROFILES_DIR)
		all_ok = false
	}
	return all_ok
}

// Returns "" when the graph satisfies the profile's hard rules.
room_graph_check :: proc(p: ^Room_Profile, g: ^Room_Graph) -> string {
	counts := make([]int, len(p.types), context.temp_allocator)
	for node in g.nodes do counts[node.type] += 1
	for &t, ti in p.types {
		if counts[ti] < t.count_min || counts[ti] > t.count_max do return "room count out of range"
	}
	for e in g.edges {
		if profile_pair_weight(p, g.nodes[e.a].type, g.nodes[e.b].type) <= 0 do return "forbidden edge"
	}
	dist := room_graph_bfs(g)
	for dd in dist {
		if dd < 0 do return "graph not connected"
	}
	for &node, i in g.nodes {
		md := p.types[node.type].max_doors
		if md > 0 && room_graph_degree(g, i) > md do return "max_doors exceeded"
	}
	return ""
}

room_graph_print :: proc(p: ^Room_Profile, g: ^Room_Graph) {
	node_name :: proc(p: ^Room_Profile, g: ^Room_Graph, n: int) -> string {
		t := &p.types[g.nodes[n].type]
		return t.count_max > 1 ? fmt.tprintf("%s %d", t.name, g.nodes[n].ordinal) : t.name
	}
	fmt.printf("%s: %d rooms, %d edges, score %.1f\n", p.name, len(g.nodes), len(g.edges), g.score)
	for e in g.edges {
		fmt.printf("    %-14s %s %-14s (w %.0f)\n", node_name(p, g, e.a), e.tree ? "--" : "..", node_name(p, g, e.b), e.weight)
	}
}

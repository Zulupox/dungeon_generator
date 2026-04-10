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

// Room types for adjacency rules and budget tracking.
Room_Type :: enum u8 {
	Generic,       // fallback, connects to anything
	Throne_Room,
	Great_Hall,
	Barracks,
	Armory,
	Kitchen,
	Dining_Hall,
	Bedroom,
	Treasury,
	Guard_Room,
	Chapel,
	Library,
	Storage,
	Courtyard,
	Gatehouse,
	Corridor,
}

Module_Template :: struct {
	name:       string,
	width:      int,
	height:     int,
	mask:       []bool, // width*height; true = cell is part of the module
	door_slots: []Door_Slot,
	color:      Color4,
	room_type:  Room_Type,
}

// ---------------------------------------------------------------------------
// Template registry
// ---------------------------------------------------------------------------

// Masks: row-major, true means that cell is part of the module.
// Using global variables (not constants) so they are addressable and can be sliced.

// --- Original templates (indices 0-6) ---

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

grand_hall_mask := [20]bool{
	true, true, true, true,
	true, true, true, true,
	true, true, true, true,
	true, true, true, true,
	true, true, true, true,
}

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

// --- New templates (indices 7+) ---

rect_2x3_mask := [6]bool{true, true, true, true, true, true}     // 2x3
rect_3x4_mask := [12]bool{                                        // 3x4
	true, true, true,
	true, true, true,
	true, true, true,
	true, true, true,
}
rect_4x3_mask := [12]bool{                                        // 4x3
	true, true, true, true,
	true, true, true, true,
	true, true, true, true,
}
rect_5x3_mask := [15]bool{                                        // 5x3
	true, true, true, true, true,
	true, true, true, true, true,
	true, true, true, true, true,
}
rect_3x2_mask := [6]bool{true, true, true, true, true, true}     // 3x2
rect_2x4_mask := [8]bool{true, true, true, true, true, true, true, true} // 2x4

// T-shape (3x3, top-right missing):
// X X .
// X X X
// X X .
t_shape_mask := [9]bool{
	true,  true,  false,
	true,  true,  true,
	true,  true,  false,
}

// Courtyard (4x4, hollow center):
// X X X X
// X . . X
// X . . X
// X X X X
courtyard_mask := [16]bool{
	true,  true,  true,  true,
	true,  false, false, true,
	true,  false, false, true,
	true,  true,  true,  true,
}

// Small yard (3x3, hollow center):
// X X X
// X . X
// X X X
small_yard_mask := [9]bool{
	true,  true,  true,
	true,  false, true,
	true,  true,  true,
}

// Gate passage (2x4):
gate_passage_mask := [8]bool{true, true, true, true, true, true, true, true} // 2x4

// Fortified gate (3x3, bottom-center open):
// X X X
// X X X
// X . X
fortified_gate_mask := [9]bool{
	true,  true,  true,
	true,  true,  true,
	true,  false, true,
}

// --- Door slot arrays ---

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

// Barracks doors (2x3)
barracks_small_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 1, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Barracks large doors (3x4)
barracks_large_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 1, local_y = 3, direction = .South},
	{local_x = 2, local_y = 1, direction = .East},
	{local_x = 0, local_y = 2, direction = .West},
}

// Armory narrow doors (2x3)
armory_narrow_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 1, local_y = 0, direction = .East},
}

// Armory wide doors (3x3)
armory_wide_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 2, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Kitchen doors (2x3)
kitchen_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 1, local_y = 1, direction = .East},
}

// Large kitchen doors (3x3)
kitchen_large_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 2, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Dining hall doors (4x3)
dining_hall_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 2, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 3, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Banquet hall doors (5x3)
banquet_hall_doors := [?]Door_Slot{
	{local_x = 2, local_y = 0, direction = .North},
	{local_x = 2, local_y = 2, direction = .South},
	{local_x = 4, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Bedroom doors (2x2) - single entrance
bedroom_doors := [?]Door_Slot{
	{local_x = 1, local_y = 1, direction = .South},
	{local_x = 0, local_y = 0, direction = .West},
}

// Suite doors (3x2) - two entrances
suite_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 1, local_y = 1, direction = .South},
	{local_x = 0, local_y = 0, direction = .West},
}

// Vault doors (2x2) - single door (dead-end)
vault_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
}

// Treasury doors (3x2) - single door (dead-end)
treasury_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
}

// Guard post doors (2x2) - two doors (pass-through)
guard_post_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 1, local_y = 1, direction = .South},
	{local_x = 1, local_y = 0, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Guardhouse doors (2x3)
guardhouse_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 1, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Chapel doors (3x4)
chapel_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 1, local_y = 3, direction = .South},
	{local_x = 2, local_y = 2, direction = .East},
	{local_x = 0, local_y = 2, direction = .West},
}

// Small shrine doors (2x3) - T-shape
shrine_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 0, local_y = 2, direction = .South},
	{local_x = 2, local_y = 1, direction = .East},
}

// Study doors (2x3)
study_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 0, local_y = 2, direction = .West},
}

// Library doors (3x4)
library_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 1, local_y = 3, direction = .South},
	{local_x = 0, local_y = 2, direction = .West},
}

// Store room doors (2x2) - two doors
store_room_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 1, local_y = 1, direction = .East},
}

// Cellar doors (2x3)
cellar_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 1, local_y = 1, direction = .East},
	{local_x = 0, local_y = 2, direction = .West},
}

// Courtyard doors (4x4)
courtyard_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 2, local_y = 0, direction = .North},
	{local_x = 1, local_y = 3, direction = .South},
	{local_x = 2, local_y = 3, direction = .South},
	{local_x = 3, local_y = 1, direction = .East},
	{local_x = 3, local_y = 2, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
	{local_x = 0, local_y = 2, direction = .West},
}

// Small yard doors (3x3)
small_yard_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 1, local_y = 2, direction = .South},
	{local_x = 2, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Gate passage doors (2x4) - through-passage N/S
gate_passage_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .North},
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 0, local_y = 3, direction = .South},
	{local_x = 1, local_y = 3, direction = .South},
	{local_x = 1, local_y = 1, direction = .East},
	{local_x = 0, local_y = 2, direction = .West},
}

// Fortified gate doors (3x3) - U-shape opening south
fortified_gate_doors := [?]Door_Slot{
	{local_x = 1, local_y = 0, direction = .North},
	{local_x = 0, local_y = 2, direction = .South},
	{local_x = 2, local_y = 2, direction = .South},
	{local_x = 2, local_y = 1, direction = .East},
	{local_x = 0, local_y = 1, direction = .West},
}

// Long corridor doors (5x1)
long_corridor_mask := [5]bool{true, true, true, true, true}
long_corridor_doors := [?]Door_Slot{
	{local_x = 0, local_y = 0, direction = .West},
	{local_x = 4, local_y = 0, direction = .East},
}

// --- Template registry ---

MODULE_TEMPLATES := [?]Module_Template{
	// ---- Original templates (0-6) ----

	// 0: Small Room (2x2)
	{
		name       = "Small Room",
		width      = 2,
		height     = 2,
		mask       = small_room_mask[:],
		door_slots = small_room_doors[:],
		color      = {210, 140, 70, 255},  // warm orange
		room_type  = .Generic,
	},
	// 1: Large Room (3x3)
	{
		name       = "Large Room",
		width      = 3,
		height     = 3,
		mask       = large_room_mask[:],
		door_slots = large_room_doors[:],
		color      = {70, 100, 180, 255},  // deep blue
		room_type  = .Generic,
	},
	// 2: Long Hall (4x2)
	{
		name       = "Long Hall",
		width      = 4,
		height     = 2,
		mask       = long_hall_mask[:],
		door_slots = long_hall_doors[:],
		color      = {60, 170, 160, 255},  // teal
		room_type  = .Corridor,
	},
	// 3: L-Shape (3x3 with bottom-right missing)
	{
		name       = "L-Shape",
		width      = 3,
		height     = 3,
		mask       = l_shape_mask[:],
		door_slots = l_shape_doors[:],
		color      = {150, 80, 180, 255},  // purple
		room_type  = .Barracks,
	},
	// 4: Cross (3x3 with corners missing)
	{
		name       = "Cross",
		width      = 3,
		height     = 3,
		mask       = cross_mask[:],
		door_slots = cross_doors[:],
		color      = {180, 60, 80, 255},   // crimson
		room_type  = .Generic,
	},
	// 5: Grand Hall (4x5)
	{
		name       = "Grand Hall",
		width      = 4,
		height     = 5,
		mask       = grand_hall_mask[:],
		door_slots = grand_hall_doors[:],
		color      = {200, 170, 50, 255},  // gold
		room_type  = .Great_Hall,
	},
	// 6: Throne Room (6x8)
	{
		name       = "Throne Room",
		width      = 6,
		height     = 8,
		mask       = throne_room_mask[:],
		door_slots = throne_room_doors[:],
		color      = {160, 40, 40, 255},   // dark red
		room_type  = .Throne_Room,
	},

	// ---- Barracks (7-8) ----

	// 7: Small Barracks (2x3)
	{
		name       = "Small Barracks",
		width      = 2,
		height     = 3,
		mask       = rect_2x3_mask[:],
		door_slots = barracks_small_doors[:],
		color      = {140, 90, 170, 255},  // muted purple
		room_type  = .Barracks,
	},
	// 8: Large Barracks (3x4)
	{
		name       = "Large Barracks",
		width      = 3,
		height     = 4,
		mask       = rect_3x4_mask[:],
		door_slots = barracks_large_doors[:],
		color      = {130, 70, 160, 255},  // deep purple
		room_type  = .Barracks,
	},

	// ---- Armory (9-10) ----

	// 9: Armory Narrow (2x3)
	{
		name       = "Armory Narrow",
		width      = 2,
		height     = 3,
		mask       = rect_2x3_mask[:],
		door_slots = armory_narrow_doors[:],
		color      = {90, 110, 130, 255},  // steel blue
		room_type  = .Armory,
	},
	// 10: Armory Wide (3x3)
	{
		name       = "Armory Wide",
		width      = 3,
		height     = 3,
		mask       = large_room_mask[:],
		door_slots = armory_wide_doors[:],
		color      = {80, 100, 140, 255},  // dark steel
		room_type  = .Armory,
	},

	// ---- Kitchen (11-12) ----

	// 11: Kitchen (2x3)
	{
		name       = "Kitchen",
		width      = 2,
		height     = 3,
		mask       = rect_2x3_mask[:],
		door_slots = kitchen_doors[:],
		color      = {190, 140, 90, 255},  // warm brown
		room_type  = .Kitchen,
	},
	// 12: Large Kitchen (3x3)
	{
		name       = "Large Kitchen",
		width      = 3,
		height     = 3,
		mask       = large_room_mask[:],
		door_slots = kitchen_large_doors[:],
		color      = {180, 130, 80, 255},  // darker brown
		room_type  = .Kitchen,
	},

	// ---- Dining Hall (13-14) ----

	// 13: Dining Hall (4x3)
	{
		name       = "Dining Hall",
		width      = 4,
		height     = 3,
		mask       = rect_4x3_mask[:],
		door_slots = dining_hall_doors[:],
		color      = {170, 120, 60, 255},  // wood brown
		room_type  = .Dining_Hall,
	},
	// 14: Banquet Hall (5x3)
	{
		name       = "Banquet Hall",
		width      = 5,
		height     = 3,
		mask       = rect_5x3_mask[:],
		door_slots = banquet_hall_doors[:],
		color      = {160, 110, 50, 255},  // rich wood
		room_type  = .Dining_Hall,
	},

	// ---- Bedroom (15-16) ----

	// 15: Bedroom (2x2)
	{
		name       = "Bedroom",
		width      = 2,
		height     = 2,
		mask       = small_room_mask[:],
		door_slots = bedroom_doors[:],
		color      = {120, 160, 200, 255}, // light blue
		room_type  = .Bedroom,
	},
	// 16: Suite (3x2)
	{
		name       = "Suite",
		width      = 3,
		height     = 2,
		mask       = rect_3x2_mask[:],
		door_slots = suite_doors[:],
		color      = {100, 140, 190, 255}, // soft blue
		room_type  = .Bedroom,
	},

	// ---- Treasury (17-18) ----

	// 17: Vault (2x2) - single door dead-end
	{
		name       = "Vault",
		width      = 2,
		height     = 2,
		mask       = small_room_mask[:],
		door_slots = vault_doors[:],
		color      = {220, 190, 60, 255},  // bright gold
		room_type  = .Treasury,
	},
	// 18: Treasury (3x2) - single door dead-end
	{
		name       = "Treasury",
		width      = 3,
		height     = 2,
		mask       = rect_3x2_mask[:],
		door_slots = treasury_doors[:],
		color      = {200, 180, 40, 255},  // deep gold
		room_type  = .Treasury,
	},

	// ---- Guard Room (19-20) ----

	// 19: Guard Post (2x2)
	{
		name       = "Guard Post",
		width      = 2,
		height     = 2,
		mask       = small_room_mask[:],
		door_slots = guard_post_doors[:],
		color      = {160, 150, 140, 255}, // stone gray
		room_type  = .Guard_Room,
	},
	// 20: Guardhouse (2x3)
	{
		name       = "Guardhouse",
		width      = 2,
		height     = 3,
		mask       = rect_2x3_mask[:],
		door_slots = guardhouse_doors[:],
		color      = {150, 140, 130, 255}, // darker stone
		room_type  = .Guard_Room,
	},

	// ---- Chapel (21-22) ----

	// 21: Chapel (3x4)
	{
		name       = "Chapel",
		width      = 3,
		height     = 4,
		mask       = rect_3x4_mask[:],
		door_slots = chapel_doors[:],
		color      = {200, 200, 230, 255}, // pale lavender
		room_type  = .Chapel,
	},
	// 22: Small Shrine (T-shape 3x3)
	{
		name       = "Small Shrine",
		width      = 3,
		height     = 3,
		mask       = t_shape_mask[:],
		door_slots = shrine_doors[:],
		color      = {190, 190, 220, 255}, // muted lavender
		room_type  = .Chapel,
	},

	// ---- Library (23-24) ----

	// 23: Study (2x3)
	{
		name       = "Study",
		width      = 2,
		height     = 3,
		mask       = rect_2x3_mask[:],
		door_slots = study_doors[:],
		color      = {100, 70, 50, 255},   // dark wood
		room_type  = .Library,
	},
	// 24: Library (3x4)
	{
		name       = "Library",
		width      = 3,
		height     = 4,
		mask       = rect_3x4_mask[:],
		door_slots = library_doors[:],
		color      = {110, 80, 60, 255},   // rich wood
		room_type  = .Library,
	},

	// ---- Storage (25-26) ----

	// 25: Store Room (2x2)
	{
		name       = "Store Room",
		width      = 2,
		height     = 2,
		mask       = small_room_mask[:],
		door_slots = store_room_doors[:],
		color      = {140, 130, 100, 255}, // dusty tan
		room_type  = .Storage,
	},
	// 26: Cellar (2x3)
	{
		name       = "Cellar",
		width      = 2,
		height     = 3,
		mask       = rect_2x3_mask[:],
		door_slots = cellar_doors[:],
		color      = {130, 120, 90, 255},  // darker tan
		room_type  = .Storage,
	},

	// ---- Courtyard (27-28) ----

	// 27: Courtyard (4x4, hollow center)
	{
		name       = "Courtyard",
		width      = 4,
		height     = 4,
		mask       = courtyard_mask[:],
		door_slots = courtyard_doors[:],
		color      = {100, 160, 100, 255}, // grass green
		room_type  = .Courtyard,
	},
	// 28: Small Yard (3x3, hollow center)
	{
		name       = "Small Yard",
		width      = 3,
		height     = 3,
		mask       = small_yard_mask[:],
		door_slots = small_yard_doors[:],
		color      = {110, 170, 110, 255}, // light green
		room_type  = .Courtyard,
	},

	// ---- Gatehouse (29-30) ----

	// 29: Gate Passage (2x4)
	{
		name       = "Gate Passage",
		width      = 2,
		height     = 4,
		mask       = rect_2x4_mask[:],
		door_slots = gate_passage_doors[:],
		color      = {140, 140, 150, 255}, // cool gray
		room_type  = .Gatehouse,
	},
	// 30: Fortified Gate (3x3, U-shape)
	{
		name       = "Fortified Gate",
		width      = 3,
		height     = 3,
		mask       = fortified_gate_mask[:],
		door_slots = fortified_gate_doors[:],
		color      = {130, 130, 140, 255}, // darker gray
		room_type  = .Gatehouse,
	},

	// ---- Extra Corridor (31) ----

	// 31: Long Corridor (5x1)
	{
		name       = "Long Corridor",
		width      = 5,
		height     = 1,
		mask       = long_corridor_mask[:],
		door_slots = long_corridor_doors[:],
		color      = {50, 150, 140, 255},  // dark teal
		room_type  = .Corridor,
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

	// Track room type counts for palette budget system
	d.room_type_counts[tmpl.room_type] += 1

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

	// Decrement room type count
	ti := m.template_index
	if ti >= 0 && ti < len(MODULE_TEMPLATES) {
		rt := MODULE_TEMPLATES[ti].room_type
		if d.room_type_counts[rt] > 0 {
			d.room_type_counts[rt] -= 1
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

// ---------------------------------------------------------------------------
// Mirror helpers
// ---------------------------------------------------------------------------

// Flip a mask along the given axis.
// Mirror_Axis.X = flip horizontally (left/right), .Y = flip vertically (top/bottom).
mirror_mask :: proc(src: []bool, w, h: int, axis: Mirror_Axis) -> [dynamic]bool {
	result := make([dynamic]bool, w * h)
	for ly in 0 ..< h {
		for lx in 0 ..< w {
			if !src[ly * w + lx] do continue
			mx, my: int
			switch axis {
			case .X: mx = w - 1 - lx; my = ly
			case .Y: mx = lx;          my = h - 1 - ly
			}
			result[my * w + mx] = true
		}
	}
	return result
}

// Flip door positions and swap directions along the given axis.
mirror_doors :: proc(src: []Door_Slot, w, h: int, axis: Mirror_Axis) -> [dynamic]Door_Slot {
	result := make([dynamic]Door_Slot, 0, len(src))
	for slot in src {
		ms: Door_Slot
		switch axis {
		case .X:
			ms.local_x = w - 1 - slot.local_x
			ms.local_y = slot.local_y
			switch slot.direction {
			case .East:  ms.direction = .West
			case .West:  ms.direction = .East
			case .North: ms.direction = .North
			case .South: ms.direction = .South
			}
		case .Y:
			ms.local_x = slot.local_x
			ms.local_y = h - 1 - slot.local_y
			switch slot.direction {
			case .North: ms.direction = .South
			case .South: ms.direction = .North
			case .East:  ms.direction = .East
			case .West:  ms.direction = .West
			}
		}
		append(&result, ms)
	}
	return result
}

// Transpose a mask (reflect across the diagonal): w×h becomes h×w.
transpose_mask :: proc(src: []bool, w, h: int) -> (result: [dynamic]bool, rw: int, rh: int) {
	rw, rh = h, w
	result = make([dynamic]bool, rw * rh)
	for ly in 0 ..< h {
		for lx in 0 ..< w {
			if !src[ly * w + lx] do continue
			result[lx * rw + ly] = true
		}
	}
	return
}

// Transpose door positions and swap directions across the diagonal.
// North <-> West, South <-> East (swapping the two axes).
transpose_doors :: proc(src: []Door_Slot, w, h: int) -> [dynamic]Door_Slot {
	result := make([dynamic]Door_Slot, 0, len(src))
	for slot in src {
		ms: Door_Slot
		ms.local_x = slot.local_y
		ms.local_y = slot.local_x
		switch slot.direction {
		case .North: ms.direction = .West
		case .South: ms.direction = .East
		case .East:  ms.direction = .South
		case .West:  ms.direction = .North
		}
		append(&result, ms)
	}
	return result
}

// Stamp a module with pre-built mask and doors (for mirrored rooms).
// The caller owns mask and doors — they are moved into the Placed_Module.
stamp_module_raw :: proc(d: ^Dungeon, mask: [dynamic]bool, doors: [dynamic]Door_Slot,
                         rw, rh, gx, gy: int, color: Color4, template_index: int) -> int {
	module_id := len(d.modules)

	// Compute center
	count: f32 = 0
	cx, cy: f32 = 0, 0
	for ly in 0 ..< rh {
		for lx in 0 ..< rw {
			if !mask[ly * rw + lx] do continue
			cx += f32(gx + lx) + 0.5
			cy += f32(gy + ly) + 0.5
			count += 1
		}
	}
	if count > 0 {
		cx /= count
		cy /= count
	}

	append(&d.modules, Placed_Module{
		template_index = template_index,
		rotation       = .R0, // not meaningful for mirrored rooms
		grid_x         = gx,
		grid_y         = gy,
		center_x       = cx,
		center_y       = cy,
		rot_width      = rw,
		rot_height     = rh,
		rot_mask       = mask,
		rot_doors      = doors,
	})

	// Mark grid cells
	for ly in 0 ..< rh {
		for lx in 0 ..< rw {
			if !mask[ly * rw + lx] do continue
			cell := grid_get(d, gx + lx, gy + ly)
			cell.cell_type = .Room
			cell.module_id = module_id
			cell.color = color
		}
	}

	// Track room type counts for palette budget system
	if template_index >= 0 && template_index < len(MODULE_TEMPLATES) {
		d.room_type_counts[MODULE_TEMPLATES[template_index].room_type] += 1
	}

	return module_id
}

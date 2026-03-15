package imgui_impl_raylib

import "core:c"
import "core:mem"
import "core:math"

import imgui "../libs/odin-imgui"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

current_mouse_cursor: imgui.MouseCursor = imgui.MouseCursor.COUNT
mouse_cursor_map: [imgui.MouseCursor.COUNT]rl.MouseCursor

last_frame_focused := false
last_control_pressed := false
last_shift_pressed := false
last_alt_pressed := false
last_super_pressed := false

raylib_key_map: map[rl.KeyboardKey]imgui.Key = {}

init :: proc() -> bool {
	setup_globals()
	setup_keymap()
	setup_mouse_cursor()
	setup_backend()
	return true
}

build_font_atlas :: proc() -> mem.Allocator_Error {
	io := imgui.GetIO()

	pixels: ^c.uchar
	width, height: c.int
	imgui.FontAtlas_GetTexDataAsRGBA32(io.Fonts, &pixels, &width, &height, nil)
	image := rl.GenImageColor(width, height, rl.BLANK)
	mem.copy(image.data, pixels, int(width * height * 4))

	old_id := u32(io.Fonts.TexID)
	if old_id != 0 {
		rl.UnloadTexture(rl.Texture2D{id = old_id})
	}

	tex := rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	io.Fonts.TexID = imgui.TextureID(tex.id)

	return nil
}

shutdown :: proc() {
	io := imgui.GetIO()
	tex_id := u32(io.Fonts.TexID)
	if tex_id != 0 {
		rl.UnloadTexture(rl.Texture2D{id = tex_id})
	}
	io.Fonts.TexID = 0
}

new_frame :: proc() {
	io := imgui.GetIO()

	if rl.IsWindowFullscreen() {
		monitor := rl.GetCurrentMonitor()
		io.DisplaySize.x = f32(rl.GetMonitorWidth(monitor))
		io.DisplaySize.y = f32(rl.GetMonitorHeight(monitor))
	} else {
		io.DisplaySize.x = f32(rl.GetScreenWidth())
		io.DisplaySize.y = f32(rl.GetScreenHeight())
	}

	io.DisplayFramebufferScale = rl.GetWindowScaleDPI()
	io.DeltaTime = rl.GetFrameTime()

	if io.WantSetMousePos {
		rl.SetMousePosition(c.int(io.MousePos.x), c.int(io.MousePos.y))
	} else {
		mouse_pos := rl.GetMousePosition()
		imgui.IO_AddMousePosEvent(io, mouse_pos.x, mouse_pos.y)
	}

	set_mouse_event :: proc(io: ^imgui.IO, rl_mouse: rl.MouseButton, imgui_mouse: c.int) {
		if rl.IsMouseButtonPressed(rl_mouse) {
			imgui.IO_AddMouseButtonEvent(io, imgui_mouse, true)
		} else if rl.IsMouseButtonReleased(rl_mouse) {
			imgui.IO_AddMouseButtonEvent(io, imgui_mouse, false)
		}
	}

	set_mouse_event(io, rl.MouseButton.LEFT, c.int(imgui.MouseButton.Left))
	set_mouse_event(io, rl.MouseButton.RIGHT, c.int(imgui.MouseButton.Right))
	set_mouse_event(io, rl.MouseButton.MIDDLE, c.int(imgui.MouseButton.Middle))
	set_mouse_event(io, rl.MouseButton.FORWARD, c.int(imgui.MouseButton.Middle) + 1)
	set_mouse_event(io, rl.MouseButton.BACK, c.int(imgui.MouseButton.Middle) + 2)

	mouse_wheel := rl.GetMouseWheelMoveV()
	imgui.IO_AddMouseWheelEvent(io, mouse_wheel.x, mouse_wheel.y)

	if imgui.ConfigFlag.NoMouseCursorChange not_in io.ConfigFlags {
		imgui_cursor := imgui.GetMouseCursor()
		if imgui_cursor != current_mouse_cursor || io.MouseDrawCursor {
			current_mouse_cursor = imgui_cursor
			if io.MouseDrawCursor || imgui_cursor == imgui.MouseCursor.None {
				rl.HideCursor()
			} else {
				rl.ShowCursor()
				if c.int(imgui_cursor) > -1 && imgui_cursor < imgui.MouseCursor.COUNT {
					rl.SetMouseCursor(mouse_cursor_map[imgui_cursor])
				} else {
					rl.SetMouseCursor(rl.MouseCursor.DEFAULT)
				}
			}
		}
	}
}

render_draw_data :: proc(draw_data: ^imgui.DrawData) {
	rlgl.DrawRenderBatchActive()
	rlgl.DisableBackfaceCulling()

	command_lists := mem.slice_ptr(draw_data.CmdLists.Data, int(draw_data.CmdLists.Size))
	for command_list in command_lists {
		cmd_slice := mem.slice_ptr(command_list.CmdBuffer.Data, int(command_list.CmdBuffer.Size))
		for i in 0 ..< command_list.CmdBuffer.Size {
			cmd := cmd_slice[i]
			enable_scissor(
				cmd.ClipRect.x - draw_data.DisplayPos.x,
				cmd.ClipRect.y,
				cmd.ClipRect.z - (cmd.ClipRect.x - draw_data.DisplayPos.x),
				cmd.ClipRect.w - (cmd.ClipRect.y - draw_data.DisplayPos.y),
			)

			if cmd.UserCallback != nil {
				cmd.UserCallback(command_list, &cmd)
				continue
			}

			render_triangles(cmd.ElemCount, cmd.IdxOffset, command_list.IdxBuffer, command_list.VtxBuffer, cmd.TextureId)
			rlgl.DrawRenderBatchActive()
		}
	}

	rlgl.SetTexture(0)
	rlgl.DisableScissorTest()
	rlgl.EnableBackfaceCulling()
}

@(private)
enable_scissor :: proc(x, y, width, height: f32) {
	rlgl.EnableScissorTest()
	io := imgui.GetIO()
	rlgl.Scissor(
		i32(x * io.DisplayFramebufferScale.x),
		i32((io.DisplaySize.y - math.floor(y + height)) * io.DisplayFramebufferScale.y),
		i32(width * io.DisplayFramebufferScale.x),
		i32(height * io.DisplayFramebufferScale.y),
	)
}

@(private)
render_triangles :: proc(count: u32, index_start: u32, index_buffer: imgui.Vector_DrawIdx, vert_buffer: imgui.Vector_DrawVert, texture_id: imgui.TextureID) {
	if count < 3 do return

	texture_gl_id := c.uint(texture_id)

	rlgl.Begin(rlgl.TRIANGLES)
	rlgl.SetTexture(texture_gl_id)

	index_slice := mem.slice_ptr(index_buffer.Data, int(index_buffer.Size))
	vert_slice := mem.slice_ptr(vert_buffer.Data, int(vert_buffer.Size))

	for i: u32 = 0; i <= (count - 3); i += 3 {
		if rlgl.CheckRenderBatchLimit(3) != 0 {
			rlgl.Begin(rlgl.TRIANGLES)
			rlgl.SetTexture(texture_gl_id)
		}

		index_a := index_slice[index_start + i]
		index_b := index_slice[index_start + i + 1]
		index_c := index_slice[index_start + i + 2]

		vertex_a := vert_slice[index_a]
		vertex_b := vert_slice[index_b]
		vertex_c := vert_slice[index_c]

		draw_triangle_vert :: proc(vert: imgui.DrawVert) {
			col: rl.Color = transmute(rl.Color)vert.col
			rlgl.Color4ub(col.r, col.g, col.b, col.a)
			rlgl.TexCoord2f(vert.uv.x, vert.uv.y)
			rlgl.Vertex2f(vert.pos.x, vert.pos.y)
		}

		draw_triangle_vert(vertex_a)
		draw_triangle_vert(vertex_b)
		draw_triangle_vert(vertex_c)
	}

	rlgl.End()
}

is_control_down :: proc() -> bool { return rl.IsKeyDown(.RIGHT_CONTROL) || rl.IsKeyDown(.LEFT_CONTROL) }
is_shift_down   :: proc() -> bool { return rl.IsKeyDown(.RIGHT_SHIFT)   || rl.IsKeyDown(.LEFT_SHIFT) }
is_alt_down     :: proc() -> bool { return rl.IsKeyDown(.RIGHT_ALT)     || rl.IsKeyDown(.LEFT_ALT) }
is_super_down   :: proc() -> bool { return rl.IsKeyDown(.RIGHT_SUPER)   || rl.IsKeyDown(.LEFT_SUPER) }

process_events :: proc() -> bool {
	io := imgui.GetIO()

	focused := rl.IsWindowFocused()
	if focused != last_frame_focused {
		imgui.IO_AddFocusEvent(io, focused)
	}
	last_frame_focused = focused

	ctrl_down := is_control_down()
	if ctrl_down != last_control_pressed {
		imgui.IO_AddKeyEvent(io, imgui.Key.ImGuiMod_Ctrl, ctrl_down)
	}
	last_control_pressed = ctrl_down

	shift_down := is_shift_down()
	if shift_down != last_shift_pressed {
		imgui.IO_AddKeyEvent(io, imgui.Key.ImGuiMod_Shift, shift_down)
	}
	last_shift_pressed = shift_down

	alt_down := is_alt_down()
	if alt_down != last_alt_pressed {
		imgui.IO_AddKeyEvent(io, imgui.Key.ImGuiMod_Alt, alt_down)
	}
	last_alt_pressed = alt_down

	super_down := is_super_down()
	if super_down != last_super_pressed {
		imgui.IO_AddKeyEvent(io, imgui.Key.ImGuiMod_Super, super_down)
	}
	last_super_pressed = super_down

	key_id := rl.GetKeyPressed()
	for key_id != .KEY_NULL {
		key, ok := raylib_key_map[key_id]
		if ok {
			imgui.IO_AddKeyEvent(io, key, true)
		}
		key_id = rl.GetKeyPressed()
	}

	for key in raylib_key_map {
		if rl.IsKeyReleased(key) {
			imgui.IO_AddKeyEvent(io, raylib_key_map[key], false)
		}
	}

	pressed: rune = rl.GetCharPressed()
	for pressed != 0 {
		imgui.IO_AddInputCharacter(io, u32(pressed))
		pressed = rl.GetCharPressed()
	}

	return true
}

@(private)
setup_globals :: proc() {
	last_frame_focused = rl.IsWindowFocused()
	last_control_pressed = false
	last_shift_pressed = false
	last_alt_pressed = false
	last_super_pressed = false
}

@(private)
setup_keymap :: proc() {
	raylib_key_map[.APOSTROPHE] = .Apostrophe
	raylib_key_map[.COMMA] = .Comma
	raylib_key_map[.MINUS] = .Minus
	raylib_key_map[.PERIOD] = .Period
	raylib_key_map[.SLASH] = .Slash
	raylib_key_map[.ZERO] = ._0
	raylib_key_map[.ONE] = ._1
	raylib_key_map[.TWO] = ._2
	raylib_key_map[.THREE] = ._3
	raylib_key_map[.FOUR] = ._4
	raylib_key_map[.FIVE] = ._5
	raylib_key_map[.SIX] = ._6
	raylib_key_map[.SEVEN] = ._7
	raylib_key_map[.EIGHT] = ._8
	raylib_key_map[.NINE] = ._9
	raylib_key_map[.SEMICOLON] = .Semicolon
	raylib_key_map[.EQUAL] = .Equal
	raylib_key_map[.A] = .A
	raylib_key_map[.B] = .B
	raylib_key_map[.C] = .C
	raylib_key_map[.D] = .D
	raylib_key_map[.E] = .E
	raylib_key_map[.F] = .F
	raylib_key_map[.G] = .G
	raylib_key_map[.H] = .H
	raylib_key_map[.I] = .I
	raylib_key_map[.J] = .J
	raylib_key_map[.K] = .K
	raylib_key_map[.L] = .L
	raylib_key_map[.M] = .M
	raylib_key_map[.N] = .N
	raylib_key_map[.O] = .O
	raylib_key_map[.P] = .P
	raylib_key_map[.Q] = .Q
	raylib_key_map[.R] = .R
	raylib_key_map[.S] = .S
	raylib_key_map[.T] = .T
	raylib_key_map[.U] = .U
	raylib_key_map[.V] = .V
	raylib_key_map[.W] = .W
	raylib_key_map[.X] = .X
	raylib_key_map[.Y] = .Y
	raylib_key_map[.Z] = .Z
	raylib_key_map[.SPACE] = .Space
	raylib_key_map[.ESCAPE] = .Escape
	raylib_key_map[.ENTER] = .Enter
	raylib_key_map[.TAB] = .Tab
	raylib_key_map[.BACKSPACE] = .Backspace
	raylib_key_map[.INSERT] = .Insert
	raylib_key_map[.DELETE] = .Delete
	raylib_key_map[.RIGHT] = .RightArrow
	raylib_key_map[.LEFT] = .LeftArrow
	raylib_key_map[.DOWN] = .DownArrow
	raylib_key_map[.UP] = .UpArrow
	raylib_key_map[.PAGE_UP] = .PageUp
	raylib_key_map[.PAGE_DOWN] = .PageDown
	raylib_key_map[.HOME] = .Home
	raylib_key_map[.END] = .End
	raylib_key_map[.CAPS_LOCK] = .CapsLock
	raylib_key_map[.SCROLL_LOCK] = .ScrollLock
	raylib_key_map[.NUM_LOCK] = .NumLock
	raylib_key_map[.PRINT_SCREEN] = .PrintScreen
	raylib_key_map[.PAUSE] = .Pause
	raylib_key_map[.F1] = .F1
	raylib_key_map[.F2] = .F2
	raylib_key_map[.F3] = .F3
	raylib_key_map[.F4] = .F4
	raylib_key_map[.F5] = .F5
	raylib_key_map[.F6] = .F6
	raylib_key_map[.F7] = .F7
	raylib_key_map[.F8] = .F8
	raylib_key_map[.F9] = .F9
	raylib_key_map[.F10] = .F10
	raylib_key_map[.F11] = .F11
	raylib_key_map[.F12] = .F12
	raylib_key_map[.LEFT_SHIFT] = .LeftShift
	raylib_key_map[.LEFT_CONTROL] = .LeftCtrl
	raylib_key_map[.LEFT_ALT] = .LeftAlt
	raylib_key_map[.LEFT_SUPER] = .LeftSuper
	raylib_key_map[.RIGHT_SHIFT] = .RightShift
	raylib_key_map[.RIGHT_CONTROL] = .RightCtrl
	raylib_key_map[.RIGHT_ALT] = .RightAlt
	raylib_key_map[.RIGHT_SUPER] = .RightSuper
	raylib_key_map[.KB_MENU] = .Menu
	raylib_key_map[.LEFT_BRACKET] = .LeftBracket
	raylib_key_map[.BACKSLASH] = .Backslash
	raylib_key_map[.RIGHT_BRACKET] = .RightBracket
	raylib_key_map[.GRAVE] = .GraveAccent
	raylib_key_map[.KP_0] = .Keypad0
	raylib_key_map[.KP_1] = .Keypad1
	raylib_key_map[.KP_2] = .Keypad2
	raylib_key_map[.KP_3] = .Keypad3
	raylib_key_map[.KP_4] = .Keypad4
	raylib_key_map[.KP_5] = .Keypad5
	raylib_key_map[.KP_6] = .Keypad6
	raylib_key_map[.KP_7] = .Keypad7
	raylib_key_map[.KP_8] = .Keypad8
	raylib_key_map[.KP_9] = .Keypad9
	raylib_key_map[.KP_DECIMAL] = .KeypadDecimal
	raylib_key_map[.KP_DIVIDE] = .KeypadDivide
	raylib_key_map[.KP_MULTIPLY] = .KeypadMultiply
	raylib_key_map[.KP_SUBTRACT] = .KeypadSubtract
	raylib_key_map[.KP_ADD] = .KeypadAdd
	raylib_key_map[.KP_ENTER] = .KeypadEnter
	raylib_key_map[.KP_EQUAL] = .KeypadEqual
}

@(private)
setup_mouse_cursor :: proc() {
	mouse_cursor_map[imgui.MouseCursor.Arrow] = .ARROW
	mouse_cursor_map[imgui.MouseCursor.TextInput] = .IBEAM
	mouse_cursor_map[imgui.MouseCursor.Hand] = .POINTING_HAND
	mouse_cursor_map[imgui.MouseCursor.ResizeAll] = .RESIZE_ALL
	mouse_cursor_map[imgui.MouseCursor.ResizeEW] = .RESIZE_EW
	mouse_cursor_map[imgui.MouseCursor.ResizeNESW] = .RESIZE_NESW
	mouse_cursor_map[imgui.MouseCursor.ResizeNS] = .RESIZE_NS
	mouse_cursor_map[imgui.MouseCursor.ResizeNWSE] = .RESIZE_NWSE
	mouse_cursor_map[imgui.MouseCursor.NotAllowed] = .NOT_ALLOWED
}

@(private)
setup_backend :: proc() {
	io := imgui.GetIO()
	io.BackendPlatformName = "imgui_impl_raylib"
	io.BackendFlags |= {.HasMouseCursors}
	io.MousePos = {0, 0}

	pio := imgui.GetPlatformIO()
	pio.Platform_SetClipboardTextFn = set_clip_text_callback
	pio.Platform_GetClipboardTextFn = get_clip_text_callback
	pio.Platform_ClipboardUserData = nil
}

@(private)
set_clip_text_callback :: proc "c" (ctx: ^imgui.Context, text: cstring) {
	rl.SetClipboardText(text)
}

@(private)
get_clip_text_callback :: proc "c" (ctx: ^imgui.Context) -> cstring {
	return rl.GetClipboardText()
}

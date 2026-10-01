package app

/*
    The engraved shapes of the Score view (score.odin): clefs, rests, flags,
    accidentals, note heads.

    No music font: every shape is drawn here, in staff spaces, so it scales
    with the staff and looks the same on every machine. A curved shape is a
    STROKE - a smooth line through a handful of points, each with its own
    width, the way a pen would draw it (thin where it turns, thick on the
    bowls) - plus the odd dot or bar.

    Coordinates are in staff spaces with y UP, (0, 0) on the staff's middle
    line where the glyph is placed; `glyph_draw` turns them into pixels.
*/

import "core:math"
import rl "vendor:raylib"

// A point of a stroke: where, and how wide the pen is there (staff spaces).
Pen :: [3]f32

Glyph :: struct {
	strokes: [][]Pen,
	dots:    [][3]f32, // x, y, radius
	bars:    [][4]f32, // x0, y0, x1, y1: filled rectangles
	dy:      f32, // drawn this far up from where it is placed
}

TREBLE_PATH := [?]Pen {
	{0.40, 0.30, 0.10}, {0.10, 0.55, 0.14}, {-0.45, 0.20, 0.22}, {-0.55, -0.50, 0.30},
	{0.05, -1.05, 0.32}, {0.85, -0.85, 0.28}, {1.25, -0.05, 0.20}, {0.95, 0.85, 0.15},
	{0.20, 1.45, 0.15}, {-0.30, 2.20, 0.18}, {-0.25, 3.40, 0.20}, {0.20, 4.20, 0.12},
	{0.55, 3.85, 0.12}, {0.50, 3.00, 0.15}, {0.10, 2.30, 0.12}, {0.30, 0.60, 0.11},
	{0.45, -1.00, 0.11}, {0.55, -2.10, 0.11}, {0.30, -2.60, 0.15}, {-0.20, -2.55, 0.20},
	{-0.35, -2.20, 0.10},
}
TREBLE_STROKES := [?][]Pen{TREBLE_PATH[:]}
TREBLE_DOTS := [?][3]f32{{-0.12, -2.2, 0.33}}

BASS_PATH := [?]Pen {
	{0.10, 1.00, 0.20}, {0.20, 1.45, 0.20}, {0.60, 1.90, 0.16}, {1.25, 1.98, 0.18},
	{1.85, 1.50, 0.32}, {1.95, 0.70, 0.40}, {1.50, -0.40, 0.30}, {0.70, -1.40, 0.18},
	{-0.10, -1.95, 0.06},
}
BASS_STROKES := [?][]Pen{BASS_PATH[:]}
BASS_DOTS := [?][3]f32{{0.32, 1.0, 0.32}, {2.45, 1.5, 0.16}, {2.45, 0.5, 0.16}}

C_UPPER := [?]Pen{{0.80, 0.00, 0.08}, {1.05, 0.35, 0.16}, {1.35, 0.70, 0.12}, {1.85, 0.75, 0.20}, {2.20, 1.25, 0.38}, {2.00, 1.90, 0.22}, {1.50, 1.95, 0.12}}
C_LOWER := [?]Pen{{0.80, 0.00, 0.08}, {1.05, -0.35, 0.16}, {1.35, -0.70, 0.12}, {1.85, -0.75, 0.20}, {2.20, -1.25, 0.38}, {2.00, -1.90, 0.22}, {1.50, -1.95, 0.12}}
C_STROKES := [?][]Pen{C_UPPER[:], C_LOWER[:]}
C_DOTS := [?][3]f32{{1.55, 1.55, 0.30}, {1.55, -1.55, 0.30}}
C_BARS := [?][4]f32{{0, -2, 0.42, 2}, {0.62, -2, 0.76, 2}}

PERC_BARS := [?][4]f32{{0.3, -1, 0.65, 1}, {1.05, -1, 1.4, 1}}

QREST_PATH := [?]Pen{{0.15, 1.5, 0.06}, {0.6, 0.85, 0.34}, {0.2, 0.25, 0.12}, {0.65, -0.45, 0.36}, {0.5, -0.85, 0.08}, {0.1, -0.8, 0.22}, {0.35, -1.5, 0.06}}
QREST_STROKES := [?][]Pen{QREST_PATH[:]}

// The eighth rest and its kin: a hook and a dot per level, on a slanting
// stem. `hook` is one level's hook, placed a space lower for each level.
REST_HOOK := [?]Pen{{0.35, 0.35, 0.10}, {0.75, 0.50, 0.10}, {1.00, 0.75, 0.10}}

FLAT_PATH := [?]Pen{{0.06, 0.2, 0.12}, {0.45, 0.55, 0.16}, {0.75, 0.3, 0.22}, {0.5, -0.15, 0.14}, {0.06, -0.5, 0.10}}
FLAT_STROKES := [?][]Pen{FLAT_PATH[:]}
FLAT_BARS := [?][4]f32{{0, -0.5, 0.12, 2.1}}

// A flag, hanging from the top of an up stem (y down from 0); a down stem's
// is the same shape turned upside down.
FLAG_PATH := [?]Pen{{0.05, 0.0, 0.3}, {0.15, -0.55, 0.4}, {0.75, -1.2, 0.32}, {1.05, -1.95, 0.2}, {0.85, -2.8, 0.1}}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

// One filled triangle, whichever way round its corners come (raylib only
// fills counter-clockwise ones).
tri :: proc(a, b, c: rl.Vector2, col: rl.Color) {
	cross := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	if cross < 0 do rl.DrawTriangle(a, b, c, col)
	else do rl.DrawTriangle(a, c, b, col)
}

quad :: proc(a, b, c, d: rl.Vector2, col: rl.Color) {
	tri(a, b, c, col)
	tri(a, c, d, col)
}

// A smooth pen line through `pts` (Catmull-Rom), in staff spaces from
// (ox, oy), `sp` pixels to the space. `flip_y`: upside down.
pen_stroke :: proc(pts: []Pen, ox, oy, sp: f32, col: rl.Color, flip_y := false, flip_x := false) {
	if len(pts) < 2 do return
	STEPS :: 8
	fy: f32 = flip_y ? -1 : 1
	fx: f32 = flip_x ? -1 : 1
	at :: proc(pts: []Pen, i: int) -> Pen {return pts[clamp(i, 0, len(pts) - 1)]}
	prev: [3]f32
	have := false
	prev_l, prev_r: rl.Vector2
	for i in 0 ..< len(pts) - 1 {
		p0, p1, p2, p3 := at(pts, i - 1), pts[i], at(pts, i + 1), at(pts, i + 2)
		for s in 0 ..= STEPS {
			if s == 0 && have do continue
			t := f32(s) / STEPS
			t2, t3 := t * t, t * t * t
			q := 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
			pt := [3]f32{ox + fx * q.x * sp, oy - fy * q.y * sp, max(q.z, 0.02) * sp / 2}
			if have {
				dx, dy := pt.x - prev.x, pt.y - prev.y
				l := max(math.sqrt(dx * dx + dy * dy), 1e-4)
				nx, ny := -dy / l, dx / l
				l2 := rl.Vector2{pt.x + nx * pt.z, pt.y + ny * pt.z}
				r2 := rl.Vector2{pt.x - nx * pt.z, pt.y - ny * pt.z}
				l1 := rl.Vector2{prev.x + nx * prev.z, prev.y + ny * prev.z}
				r1 := rl.Vector2{prev.x - nx * prev.z, prev.y - ny * prev.z}
				quad(l1, l2, r2, r1, col)
				// Fill the wedge where the line turns.
				if s > 1 || i > 0 {
					tri(prev_l, l1, {prev.x, prev.y}, col)
					tri(prev_r, r1, {prev.x, prev.y}, col)
				}
				prev_l, prev_r = l2, r2
			}
			prev = pt
			have = true
		}
	}
}

glyph_draw :: proc(gl: Glyph, x, y, sp: f32, col: rl.Color, flip_y := false) {
	oy := y - gl.dy * sp
	fy: f32 = flip_y ? -1 : 1
	for b in gl.bars {
		y0, y1 := oy - fy * b[1] * sp, oy - fy * b[3] * sp
		rl.DrawRectangleRec({x + b[0] * sp, min(y0, y1), (b[2] - b[0]) * sp, abs(y1 - y0)}, col)
	}
	for s in gl.strokes do pen_stroke(s, x, oy, sp, col, flip_y)
	for d in gl.dots do rl.DrawCircleV({x + d[0] * sp, oy - fy * d[1] * sp}, d[2] * sp, col)
}

// A filled ellipse, turned by `angle` degrees.
ellipse_fill :: proc(c: rl.Vector2, rx, ry, angle: f32, col: rl.Color) {
	N :: 20
	a := angle * math.RAD_PER_DEG
	ca, sa := math.cos(a), math.sin(a)
	pt :: proc(c: rl.Vector2, rx, ry, ca, sa, t: f32) -> rl.Vector2 {
		x, y := rx * math.cos(t), ry * math.sin(t)
		return {c.x + x * ca - y * sa, c.y + x * sa + y * ca}
	}
	for i in 0 ..< N {
		t0 := f32(i) / N * math.TAU
		t1 := f32(i + 1) / N * math.TAU
		tri(c, pt(c, rx, ry, ca, sa, t0), pt(c, rx, ry, ca, sa, t1), col)
	}
}

// A ring: the outer ellipse less an inner one (its own size and angle) -
// a hollow note head, the staff line showing through the hole.
ellipse_ring :: proc(c: rl.Vector2, rx, ry, angle, irx, iry, iangle: f32, col: rl.Color) {
	N :: 24
	a, ia := angle * math.RAD_PER_DEG, iangle * math.RAD_PER_DEG
	pt :: proc(c: rl.Vector2, rx, ry, an, t: f32) -> rl.Vector2 {
		ca, sa := math.cos(an), math.sin(an)
		x, y := rx * math.cos(t), ry * math.sin(t)
		return {c.x + x * ca - y * sa, c.y + x * sa + y * ca}
	}
	for i in 0 ..< N {
		t0 := f32(i) / N * math.TAU
		t1 := f32(i + 1) / N * math.TAU
		// The inner ellipse's angle is added to the parameter so both run
		// round together.
		o0, o1 := pt(c, rx, ry, a, t0), pt(c, rx, ry, a, t1)
		i0, i1 := pt(c, irx, iry, ia, t0 + a - ia), pt(c, irx, iry, ia, t1 + a - ia)
		quad(o0, o1, i1, i0, col)
	}
}

clef_glyph :: proc(c: Clef_Shape) -> Glyph {
	switch c {
	case .G:
		return {strokes = TREBLE_STROKES[:], dots = TREBLE_DOTS[:], dy = -1}
	case .F:
		return {strokes = BASS_STROKES[:], dots = BASS_DOTS[:], dy = 0}
	case .C:
		return {strokes = C_STROKES[:], dots = C_DOTS[:], bars = C_BARS[:]}
	case .Perc:
		return {bars = PERC_BARS[:]}
	}
	return {}
}

// What a clef looks like, and where it sits: the G clef curls round the
// line the treble staff's G is on.
Clef_Shape :: enum {
	G,
	F,
	C,
	Perc,
}

// A rest of `value` (ticks of the plain value: 96 whole .. 3 thirty-second),
// its middle at (x, the middle line `y`).
rest_draw :: proc(value: i32, x, y, sp: f32, col: rl.Color) {
	switch {
	case value >= 96:
		// Hangs from the fourth line.
		rl.DrawRectangleRec({x - 0.6 * sp, y - sp, 1.2 * sp, 0.5 * sp}, col)
	case value >= 48:
		// Sits on the middle line.
		rl.DrawRectangleRec({x - 0.6 * sp, y - 0.5 * sp, 1.2 * sp, 0.5 * sp}, col)
	case value >= 24:
		pen_stroke(QREST_PATH[:], x - 0.4 * sp, y, sp, col)
	case:
		levels := value >= 12 ? 1 : (value >= 6 ? 2 : 3)
		// The stem: from the top hook down past the last.
		top := f32(0.75)
		bottom := -1.0 - f32(levels - 1) * 1.0
		stem := [2]Pen{{1.0, top, 0.12}, {1.0 + (bottom - top) * 0.33, bottom, 0.12}}
		ox := x - 0.5 * sp
		pen_stroke(stem[:], ox, y, sp, col)
		for k in 0 ..< levels {
			dyk := -f32(k) * 1.0
			dxk := f32(k) * -0.33
			hook := REST_HOOK
			for &p in hook {p.x += dxk; p.y += dyk}
			pen_stroke(hook[:], ox, y, sp, col)
			rl.DrawCircleV({ox + (0.3 + dxk) * sp, y - (0.55 + dyk) * sp}, 0.24 * sp, col)
		}
	}
}

// An accidental (`alter`: 1 sharp, -1 flat, 0 natural, 2 double sharp, -2
// double flat), its middle at (x, y). Returns nothing; its width is
// ACC_W (a double flat twice that).
ACC_W :: f32(0.95) // staff spaces

accidental_draw :: proc(alter: i8, x, y, sp: f32, col: rl.Color) {
	th := max(sp * 0.12, 1)
	switch alter {
	case 1:
		// Two thin uprights, two thick slanting bars.
		rl.DrawLineEx({x + 0.28 * sp, y - 1.3 * sp}, {x + 0.28 * sp, y + 1.4 * sp}, th, col)
		rl.DrawLineEx({x + 0.68 * sp, y - 1.4 * sp}, {x + 0.68 * sp, y + 1.3 * sp}, th, col)
		for dy in ([2]f32{-0.5, 0.5}) {
			quad({x, y + (dy + 0.12) * sp}, {x + 0.95 * sp, y + (dy - 0.12) * sp}, {x + 0.95 * sp, y + (dy - 0.42) * sp}, {x, y + (dy - 0.18) * sp}, col)
		}
	case -1:
		glyph_draw({strokes = FLAT_STROKES[:], bars = FLAT_BARS[:]}, x + 0.1 * sp, y, sp, col)
	case -2:
		glyph_draw({strokes = FLAT_STROKES[:], bars = FLAT_BARS[:]}, x + 0.1 * sp, y, sp, col)
		glyph_draw({strokes = FLAT_STROKES[:], bars = FLAT_BARS[:]}, x + 0.95 * sp, y, sp, col)
	case 0:
		// Natural: two uprights, offset, and two slanting bars.
		rl.DrawLineEx({x + 0.2 * sp, y - 1.35 * sp}, {x + 0.2 * sp, y + 0.75 * sp}, th, col)
		rl.DrawLineEx({x + 0.72 * sp, y - 0.75 * sp}, {x + 0.72 * sp, y + 1.35 * sp}, th, col)
		quad({x + 0.2 * sp, y - 0.3 * sp}, {x + 0.72 * sp, y - 0.52 * sp}, {x + 0.72 * sp, y - 0.25 * sp}, {x + 0.2 * sp, y - 0.03 * sp}, col)
		quad({x + 0.2 * sp, y + 0.25 * sp}, {x + 0.72 * sp, y + 0.03 * sp}, {x + 0.72 * sp, y + 0.3 * sp}, {x + 0.2 * sp, y + 0.52 * sp}, col)
	case 2:
		// Double sharp: an x with square ends.
		h := 0.42 * sp
		rl.DrawLineEx({x + 0.5 * sp - h, y - h}, {x + 0.5 * sp + h, y + h}, th * 1.4, col)
		rl.DrawLineEx({x + 0.5 * sp - h, y + h}, {x + 0.5 * sp + h, y - h}, th * 1.4, col)
		for cx in ([2]f32{-1, 1}) do for cy in ([2]f32{-1, 1}) {
			rl.DrawRectangleRec({x + 0.5 * sp + cx * h - 0.15 * sp, y + cy * h - 0.15 * sp, 0.3 * sp, 0.3 * sp}, col)
		}
	}
}

// A flag (or `n` stacked) at the end of a stem at (x, y).
flags_draw :: proc(n: int, x, y, sp: f32, up: bool, col: rl.Color) {
	for k in 0 ..< n {
		off := f32(k) * 0.85 * sp
		pen_stroke(FLAG_PATH[:], x, up ? y + off : y - off, sp, col, !up)
	}
}

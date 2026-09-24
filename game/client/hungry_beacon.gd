extends RefCounted

## What an administrator's `beacon` looks like on one monster: a ring round the whole of
## it that sends out a ripple once a second, and — when the monster is off this screen — a
## pointer at the screen's edge saying which way it is.
##
## [b]Drawn on every client, from one replicated flag.[/b] The server decides who is
## beaconed ([member HungryMonster.beacon], carried as `HungryPieceNet.net_beacon`) and
## nothing about the picture travels: the ripple's phase is each client's own, because two
## screens a quarter of a second apart in a ripple is not something anybody can see, and
## sending a phase would be a message a second per beaconed player for nothing.
##
## [b]The edge pointer is this game's version of "through walls".[/b] A top-down arena has
## no wall to hide behind, but it has a screen edge: a beacon exists so everybody can find
## somebody, and a ring nobody can see because it is two screens away fails in exactly the
## case it is used for. The server makes a beaconed monster always relevant, so the
## position to point at is there however far away it is.
##
## [b]Round the whole monster, not one piece.[/b] A split monster is one player, and a ring
## on the biggest piece would leave the rest of them looking like somebody else.
##
## A plain object rather than a node, because the renderer already draws every monster in
## one `_draw`, and a node per beacon would be one more thing to create, free and keep in
## step with a monster that bursts and respawns.

## Seconds between ripples, and between pings.
const PERIOD_SEC := 1.0

## How far a ripple spreads before it has faded, as a multiple of the ring.
const RIPPLE_SCALE := 2.4

## Red-orange: the colour nothing else in this arena is — the food is every colour but
## this, the threat ring is a darker red and the level is blue — so it reads as a mark
## rather than as another monster's rim. The same colour game-arena's beacon is.
const COLOUR := Color(1.0, 0.28, 0.18)

## Clearance between the monster's outermost edge and the ring, in world units.
const MARGIN := 14.0

## How far in from the screen edge the pointer sits, and how big it is, in SCREEN pixels.
const POINTER_INSET_PX := 34.0
const POINTER_SIZE_PX := 16.0

## Seconds into the current period. Starts at the end of one, so the first advance pings:
## an admin who turns a beacon on should hear it start, not a second later.
var _phase: float = PERIOD_SEC


## Moves the time on by [param delta]. Returns true when a new ripple starts, which is
## when the caller plays the ping.
func advance(delta: float) -> bool:
	_phase += maxf(delta, 0.0)

	if _phase >= PERIOD_SEC:
		_phase = fmod(_phase, PERIOD_SEC)
		return true

	return false


## The fraction of a period the ripple is through, for a check.
func phase() -> float:
	return _phase / PERIOD_SEC


## Draws the ring and the ripple round a monster at [param centre] whose outermost piece
## reaches [param radius], onto [param canvas], in its own coordinates.
func draw_ring(canvas: CanvasItem, centre: Vector2, radius: float) -> void:
	var t := phase()
	var ring := radius + MARGIN

	# The ring breathes with the ripple rather than holding still, so a beacon seen at the
	# size a zoomed-out camera draws it — a few pixels of ring — still reads as alive.
	var ring_alpha := lerpf(0.95, 0.55, t)
	canvas.draw_arc(centre, ring, 0.0, TAU, 64, Color(COLOUR, ring_alpha), 5.0, true)

	var ripple_alpha := 0.8 * (1.0 - t) * (1.0 - t)

	if ripple_alpha > 0.01:
		canvas.draw_arc(
			centre, ring * lerpf(1.0, RIPPLE_SCALE, t), 0.0, TAU, 64,
			Color(COLOUR, ripple_alpha), 3.0, true
		)


## Draws a pointer at the edge of [param view] toward [param target], if the target is
## outside it. [param px] is the size of one screen pixel in world units, so the pointer is
## the same size on screen however far the camera has zoomed out. Returns whether it drew.
func draw_pointer(canvas: CanvasItem, view: Rect2, target: Vector2, px: float) -> bool:
	if view.has_point(target) or view.size.x <= 0.0 or view.size.y <= 0.0:
		return false

	var inset := POINTER_INSET_PX * px
	var inner := view.grow(-inset)

	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		return false

	var centre := inner.get_center()
	var toward := target - centre
	# Where the line from the middle of the screen to the target leaves the inner rect:
	# the pointer sits on the edge nearest the monster, in the direction it actually is.
	var half := inner.size * 0.5
	var scale := minf(
		half.x / maxf(absf(toward.x), 0.0001), half.y / maxf(absf(toward.y), 0.0001)
	)
	var at := centre + toward * minf(scale, 1.0)
	var forward := toward.normalized()
	var side := Vector2(-forward.y, forward.x)
	var size := POINTER_SIZE_PX * px
	var alpha := lerpf(1.0, 0.6, phase())

	canvas.draw_colored_polygon(
		PackedVector2Array([
			at + forward * size,
			at - forward * size * 0.6 + side * size * 0.8,
			at - forward * size * 0.6 - side * size * 0.8,
		]),
		Color(COLOUR, alpha)
	)
	canvas.draw_circle(at - forward * size * 1.4, size * 0.3, Color(COLOUR, alpha))
	return true

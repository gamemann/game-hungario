extends RefCounted

const HungryLayout := preload("hungry_layout.gd")

## The solid geometry a level is built out of, derived rather than replicated.
##
## [b]Every world this game has run until now has been an empty box.[/b] `classic` and
## `frenzy` are the same square at two sizes and `gauntlet` is a corridor: in all three the
## only thing between two monsters is distance, so a chase is decided by speed and nothing
## else. A layout puts things in the way — and in a game where your [i]mass is your
## radius[/i], a thing in the way is not the same obstacle for everybody.
##
## [b]That is the whole design and it is why this is a level rather than a decoration.[/b]
## A gap 360 units across admits anything with a radius under 180, which on this mass curve
## is a monster under about 500 mass. The leader physically cannot follow you through it.
## What they [i]can[/i] do is split — half the mass is [code]1/sqrt(2)[/code] of the radius
## — and pay [member HungryPreset.merge_delay_sec] for the privilege, which turns the
## single most consequential number in the game into a navigation decision as well as a
## fighting one.
##
## [b]Nothing here goes on the wire.[/b] A layout is a pure function of its id and the
## arena rectangle, so a client that is told which level is playing builds exactly the same
## discs the server pushes it out of — the same trick [Dot2DScatter] plays with the food,
## for the same reason. [HungryHazards] is the other half of this and is deliberately not
## it: a hazard is placed at runtime by an operator or the director, so it travels, it can
## be cleared, and it is owned. A layout is the map.
##
## A disc rather than a polygon, because a disc is the one shape whose push-out is exact,
## has no corner cases at a vertex, and costs a subtraction and a length. Sixteen of them
## make a room; a convex hull solver makes a bug.

const CHANNEL := "hungry.layout"

## Nothing standing in the arena. What `classic`, `frenzy` and `gauntlet` use.
const NONE := &""

## A ring of gates around a middle, with cover in the corners.
const WARRENS := &"warrens"


## What is solid, as `(x, y, radius)` in world units.
var blocks: PackedVector3Array = PackedVector3Array()

var id: StringName = NONE


static func none() -> HungryLayout:
	return HungryLayout.new()


## The layout of a level, laid out inside the rectangle that level actually has.
##
## [b]Built from the bounds rather than from absolute coordinates[/b], so a mode whose
## world size an operator has changed still gets a layout that fits inside it rather than
## one that hangs half outside the wall. `gauntlet` is the reminder that world size here is
## not a constant.
static func for_id(layout_id: StringName, bounds: Rect2) -> HungryLayout:
	match layout_id:
		WARRENS:
			return _warrens(bounds)
		_:
			return none()


# --- warrens ---------------------------------------------------------------

## How far out the ring of gate rocks stands, as a fraction of the smaller half-extent.
const RING_AT := 0.548

## How big one gate rock is, as a fraction of the smaller half-extent.
const RING_RADIUS := 0.124

## How many rocks the ring is made of. Eight gives eight gates, which is enough that
## being locked out of the middle is a detour rather than a wall.
const RING_COUNT := 8

## The corner cover: one rock per quadrant, on the diagonal.
const CORNER_AT := 0.657
const CORNER_RADIUS := 0.114


## A ring of eight rocks around an open middle, and a rock in each quadrant.
##
## [b]The gaps between the ring's rocks are the level.[/b] At the proportions above they
## are about a fifth of the arena's half-width across, which admits a monster of roughly a
## third of the winning mass — so the middle is a shortcut that closes to you as you grow,
## and the players who are behind get the best food. A leader who wants it has to split to
## fit, in the one part of the map where being in two halves is most dangerous.
##
## [b]The corner rocks are not gates and are there for the opposite reason.[/b] A ring on
## its own leaves a featureless perimeter lane, and a lane with nothing in it is a chase
## decided by speed again. One rock per quadrant is something to break a line of sight
## against and something to be cornered against, and it is deliberately not big enough to
## hide behind for ever.
static func _warrens(bounds: Rect2) -> HungryLayout:
	var out := HungryLayout.new()
	out.id = WARRENS

	# The SMALLER half-extent, so a layout asked for inside a non-square world scales to
	# the axis that actually constrains it. Against `.x` alone a corridor would get a ring
	# wider than the corridor is, and every rock would be clamped into the walls.
	var half := minf(bounds.size.x, bounds.size.y) * 0.5
	var centre := bounds.get_center()

	var ring_at := half * RING_AT
	var ring_radius := half * RING_RADIUS

	for step in range(RING_COUNT):
		# Offset by half a step so that no gate sits on an axis. A gate on the axis lines
		# up with the arena's own centre lines, and a player running the perimeter would
		# find every gate exactly where the last one was.
		var angle := TAU * (float(step) + 0.5) / float(RING_COUNT)
		out.blocks.append(Vector3(
			centre.x + cos(angle) * ring_at,
			centre.y + sin(angle) * ring_at,
			ring_radius
		))

	var corner_at := half * CORNER_AT
	var corner_radius := half * CORNER_RADIUS

	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			out.blocks.append(Vector3(
				centre.x + sx * corner_at, centre.y + sy * corner_at, corner_radius
			))

	return out


# --- Reading ---------------------------------------------------------------

func is_empty() -> bool:
	return blocks.is_empty()


func count() -> int:
	return blocks.size()


## Whether a circle of [param radius] at [param at] overlaps anything solid.
func blocked(at: Vector2, radius: float = 0.0) -> bool:
	for block in blocks:
		var clearance := block.z + radius

		if at.distance_squared_to(Vector2(block.x, block.y)) < clearance * clearance:
			return true

	return false


## The narrowest gap between two adjacent blocks, edge to edge.
##
## What a level's design is actually asserted against: a gate is a number, and a gate that
## drifted when somebody changed a constant is a mode where either everybody or nobody fits
## through the middle. Returns [code]INF[/code] when there is nothing to measure.
func narrowest_gap() -> float:
	var narrowest := INF

	for i in range(blocks.size()):
		for j in range(i + 1, blocks.size()):
			var a := blocks[i]
			var b := blocks[j]
			var gap := (
				Vector2(a.x, a.y).distance_to(Vector2(b.x, b.y)) - a.z - b.z
			)

			if gap < narrowest:
				narrowest = gap

	return narrowest


## The largest monster radius that fits through [method narrowest_gap].
func fits_through() -> float:
	var gap := narrowest_gap()
	return gap * 0.5 if is_finite(gap) else INF


# --- Resolving -------------------------------------------------------------

## Pushes one moving circle out of anything it is inside, and takes the velocity with it.
##
## [b]Both halves, and the second one is the half that is easy to leave out.[/b] Without
## it a player holding a direction into a rock is pushed out by this call and accelerated
## straight back into it by the motor sixty times a second: the position ends up correct
## and the movement reads as packet loss, which is the worst way for a level to be wrong
## because it sends the next person to look at the netcode. [HungryHazards.resolve] says
## the same thing about the same problem, and game-simple-lobby's furniture says it again.
##
## Returns true when it moved something, which is what a check can assert on.
func resolve_circle(state: Dot2DState, radius: float) -> bool:
	if state == null or blocks.is_empty():
		return false

	var moved := false

	for block in blocks:
		var at := Vector2(block.x, block.y)
		var clearance := block.z + radius
		var away := state.position - at
		var distance := away.length()

		if distance >= clearance:
			continue

		# Dead centre is unreachable in play and reachable by a spawn, a teleport or a
		# test. A fixed direction is arbitrary and correct; the alternative is a NaN
		# normal and a piece at infinity.
		var normal := away / distance if distance > 0.001 else Vector2.RIGHT
		state.position = at + normal * clearance
		moved = true

		var into := state.velocity.dot(normal)

		if into < 0.0:
			state.velocity -= normal * into

	return moved


## A point outside everything solid, searched outward from [param at].
##
## Used where something has to go somewhere and the obvious somewhere is inside a rock: a
## spawn, mostly. Rather than refusing, it walks out along the shortest way out — which is
## the direction the push-out would have taken it anyway, so a spawn resolved this way
## lands where a piece pushed out of the same rock would have ended up.
func nearest_clear(at: Vector2, radius: float, bounds: Rect2) -> Vector2:
	var here := at

	# Bounded, because two overlapping rocks can hand a point back and forth. Twelve is
	# far more than the three or four a real layout needs and still terminates.
	for _attempt in range(12):
		var pushed := here
		var hit := false

		for block in blocks:
			var block_at := Vector2(block.x, block.y)
			var clearance := block.z + radius
			var away := pushed - block_at
			var distance := away.length()

			if distance >= clearance:
				continue

			var normal := away / distance if distance > 0.001 else Vector2.RIGHT
			pushed = block_at + normal * clearance
			hit = true

		here = Vector2(
			clampf(pushed.x, bounds.position.x + radius, bounds.end.x - radius),
			clampf(pushed.y, bounds.position.y + radius, bounds.end.y - radius)
		)

		if not hit:
			break

	return here


func describe() -> Dictionary:
	return {
		"id": String(id),
		"blocks": blocks.size(),
		"gap": narrowest_gap() if not blocks.is_empty() else 0.0,
	}


func _to_string() -> String:
	return "HungryLayout(%s, %d blocks)" % [id, blocks.size()]

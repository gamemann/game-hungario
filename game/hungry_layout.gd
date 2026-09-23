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

## Nothing standing in the arena. What `classic` and `frenzy` use.
##
## Deliberately still two of them: the square modes are the control this game measures a
## level against, and "the same square with rocks in it" is only a claim if there is a
## square without them.
const NONE := &""

## A ring of gates around a middle, with cover in the corners.
const WARRENS := &"warrens"

## A line of rocks down a corridor, alternately near one wall and the other.
const SLALOM := &"slalom"

## A barrier across the world whose channels widen from one end to the other, and a
## second one behind it whose channels widen the other way. See [method _reef].
const REEF := &"reef"


## Every layout that is a level, so a check can ask all of them the same question.
##
## [b]This list exists because of the failure it prevents rather than because anything
## needed to enumerate layouts.[/b] `warrens` was the only layout for as long as there was
## one, so the suite's gate section named it, built it, and asked it whether its gates were
## the width the design wants. That check is about the gates of whatever level is playing,
## and written against a name it proves nothing about the second level — which arrived
## with its gates measured against a WALL rather than against another rock, a case the
## question as originally asked cannot even see. See [method narrowest_gate].
static func ids() -> Array[StringName]:
	return [WARRENS, SLALOM, REEF]


## What is solid, as `(x, y, radius)` in world units.
var blocks: PackedVector3Array = PackedVector3Array()

var id: StringName = NONE

## Which runs of [member blocks] are one barrier, as `(first, count)`.
##
## [b]Empty for a layout that is not made of barriers[/b], which is every one but the reef.
## It exists because the reef stopped being one chain: a channel is a gap between two
## ADJACENT rocks of the SAME chain, and the last rock of one barrier and the first of the
## next are neighbours in [member blocks] and nothing at all on the map. A check that
## walked the array pairwise — which is what the reef's section did while there was one
## chain — would report a "channel" nine hundred units wide running along the lagoon.
var chains: Array[Vector2i] = []


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
		SLALOM:
			return _slalom(bounds)
		REEF:
			return _reef(bounds)
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


# --- slalom ----------------------------------------------------------------

## How many rocks the slalom is made of.
##
## Odd, so one of them stands on the middle of the corridor and neither end of it is the
## same as the other. An even count makes the two spawn ends mirror images, and a
## corridor whose two halves are the same is one half twice.
const SLALOM_COUNT := 5

## How big one slalom rock is, as a fraction of the corridor's HALF-WIDTH.
const SLALOM_RADIUS := 0.38

## How far off the corridor's centre line each rock stands, same fraction.
##
## [b]The level is the difference between the two lanes this leaves[/b], and both numbers
## above are chosen for that difference rather than for how a rock looks. A rock at
## [constant SLALOM_OFFSET] with radius [constant SLALOM_RADIUS] leaves
## `1 - OFFSET - RADIUS` of half-width on the near side and `1 - RADIUS + OFFSET` on the
## far side: 0.40 against 0.84, a shortcut a little over a third the width of the way
## round.
const SLALOM_OFFSET := 0.22


## A line of rocks down a corridor, alternately near one wall and the other.
##
## [b]`gauntlet` was a corridor with nothing in it, which is a chase decided by speed with
## the sideways directions removed.[/b] That is a different game from `classic` and it is
## still a game with one move in it. The slalom is the corridor's answer to what the
## warrens does for the square, and it has to be a different shape to be one: a ring has a
## middle to be shut out of, and a corridor has no middle — everything in it is on the way
## from one end to the other.
##
## So the gate here is not a way IN, it is a way PAST, and there are two of them at every
## rock. The near lane is about a third of the width of the far one, so a monster that has
## grown takes the long way round every single rock while the one chasing it cuts the
## inside line — and over five rocks that is a real distance rather than a flourish. The
## far lane is wide enough for a monster that has already won, deliberately: a corridor
## whose gates a leader cannot pass at all is not a catch-up mechanic, it is a cage, and
## the ring in the warrens is escapable precisely because it is a ring.
##
## [b]The rocks alternate sides, which is what makes the inside line a choice rather than
## a lane.[/b] Taking it at one rock puts you on the wrong side for the next, so the
## shortcut is paid for by the crossing that follows it. Five rocks with the same offset
## would be a wall with a corridor beside it.
static func _slalom(bounds: Rect2) -> HungryLayout:
	var out := HungryLayout.new()
	out.id = SLALOM

	# [b]Which way the corridor runs is read from the rectangle, not assumed.[/b]
	# `gauntlet` is five-to-one in x today and the aspect ratio is an operator's dial;
	# a slalom built along x inside a portrait world is five rocks stacked through both
	# side walls, which is a layout that reports twelve blocks and is not a level.
	var along_x := bounds.size.x >= bounds.size.y
	var long_extent := maxf(bounds.size.x, bounds.size.y)
	var short_half := minf(bounds.size.x, bounds.size.y) * 0.5
	var centre := bounds.get_center()

	var radius := short_half * SLALOM_RADIUS
	var offset := short_half * SLALOM_OFFSET

	for step in range(SLALOM_COUNT):
		# Evenly spaced with a half-station of clear floor at each end, so neither spawn
		# end opens straight onto a rock.
		var along := (float(step + 1) / float(SLALOM_COUNT + 1) - 0.5) * long_extent
		var across := offset if step % 2 == 0 else -offset

		out.blocks.append(
			Vector3(centre.x + along, centre.y + across, radius) if along_x
			else Vector3(centre.x + across, centre.y + along, radius)
		)

	return out


# --- reef ------------------------------------------------------------------

## How many rocks the barrier is made of. Five leaves four channels through it.
const REEF_COUNT := 5

## How big one reef rock is, as a fraction of the SHORT half-extent.
const REEF_RADIUS := 0.075

## The narrowest channel, edge to edge, as the same fraction.
##
## At `reef`'s world size this is 248 units, so it admits a radius of 124 — a mass of
## 240 on this curve (`base_radius` 8, square root), a sixth of the winning mass. It is deliberately the tightest thing on the
## map, walls included: see [method reef_end_fraction], which is what keeps it so.
const REEF_TIGHT := 0.108

## The widest channel, same units.
##
## 828 units at `reef`'s size, so a radius of 414 and a mass of 2680 — well past
## [member HungryPreset.win_mass] for that mode. [b]That margin is the mode's promise
## that it is not a cage[/b]: the only way to be too big for every channel is to be
## nearly twice the mass that ends the round. (This said 2140 until the lagoon was sized
## against the real curve; the radius was right and the mass was worked from the wrong
## base radius.)
const REEF_WIDE := 0.36

## How far behind the fore reef the back reef stands, as a fraction of the short
## half-extent, centre to centre.
##
## [b]Sized by the thing that has to travel along it.[/b] At `reef`'s size this is 1265
## units, which leaves a lagoon 920 across between the two faces and a strip 862 deep
## behind the back reef. A monster at the winning mass is 620 across, so both are about
## half as wide again as the leader: room to travel along and to turn in, and NOT room to
## be passed in — two monsters that size cannot stand abreast in 920, which is the point
## of a lagoon. At 0.5 it is 805 and a leader has 90 units either side for the whole walk;
## at 0.6 the strip behind shrinks to 747 and stops being floor anybody grown can use.
const LAGOON_AT := 0.55


## A barrier across the world with four channels through it, tight at one end and open at
## the other.
##
## [b]The warrens and the slalom both ask the same question everywhere on the map.[/b] The
## warrens' eight gates are eight copies of one gate, because a ring of identical rocks
## has to be; the slalom's five rocks leave the same near lane and the same far lane at
## every one of them. So in both, "can I fit through" has one answer, and a monster
## learns it once and then knows the whole level.
##
## [b]Here the answer depends on WHERE you cross.[/b] The channels widen along the
## barrier — 248, 442, 635 and 828 units at this mode's size — so a monster's size does
## not decide whether it can cross, it decides [i]how far it has to walk first[/i]. A
## small one crosses on the spot. A grown one has to commit to a journey down the length
## of the reef, in the open, to the one end that will let it through, while everybody
## watching knows exactly where it is going. That is the level: not a gate you fit or do
## not fit, but a tax on crossing that is paid in distance and in being predictable.
##
## [b]The ends are the other half, and they close as you grow.[/b] The chain stops
## [method reef_end_fraction] of a half-extent short of each wall, which is wider than the
## tight channel and narrower than the two open ones — so the run-round is a route for a
## small monster, a worse route than the third channel for a middling one, and shut to a
## large one. The
## warrens' perimeter lane is open to everybody for ever and is why its ring is escapable;
## this map's is not, which is what makes the far end worth owning.
##
## [b]The lagoon is the second half, and it is the half the leader pays for.[/b] A second
## barrier stands [constant LAGOON_AT] behind the first with one door the width of the
## fore reef's widest channel and three gates the width of its second — see [method
## back_reef_widths]. The door is behind the fore reef's TIGHT end, and the fore reef's two
## channels a grown monster fits are both at the other end. So a small monster crosses
## both barriers on one line, and anything over about 760 mass comes through the fore reef
## in the southern half and has to walk the lagoon — 1284 units from the third channel,
## 2360 from the widest, between two walls of rock in a strip too narrow to be passed in —
## to the door before it can cross again. The first half made crossing cost distance; the
## second makes it cost distance in the one place a leader cannot turn aside.
##
## Built along the SHORT axis and sized off the short half-extent, so the barrier spans
## the world rather than sitting in the middle of it: across a corridor it is a wall with
## four channels, and in a square it is the same thing at the same proportions. A chain
## built along the long axis would divide a corridor into two lanes, which is a different
## level and a worse one.
static func _reef(bounds: Rect2) -> HungryLayout:
	var out := HungryLayout.new()
	out.id = REEF

	var short_half := minf(bounds.size.x, bounds.size.y) * 0.5

	# The fore reef, through the middle of the world, tight end first. Unchanged since the
	# reef was one barrier, deliberately: the lagoon is a second half added behind it, and
	# a first half that moved to make room would be a different level wearing its name.
	_append_chain(out, _reef_chain(bounds, 0.0, channel_widths(short_half)))
	# The back reef, LAGOON_AT behind it: one door at the end behind the fore reef's tight
	# channel, and three equal gates. See [method back_reef_widths].
	_append_chain(out, _reef_chain(
		bounds, short_half * LAGOON_AT, back_reef_widths(short_half)
	))

	return out


## One barrier of rocks [param behind] units along the crossing axis from the world's
## centre, leaving [param gaps] between them in order from the chain axis's low end.
##
## Both reefs are laid out from the same end, so block order and [method channels] order
## are the same direction along the chain for both — the fore reef's tight channel and the
## back reef's door are each the first channel of their barrier, and they are behind one
## another on the map.
static func _reef_chain(bounds: Rect2, behind: float, gaps: PackedFloat32Array) -> PackedVector3Array:
	var out := PackedVector3Array()

	# The chain runs along the SHORTER axis, so it is a barrier rather than a central
	# reservation. `slalom` reads the same rectangle and takes the opposite answer,
	# because a slalom is a thing you go along and a reef is a thing you go through.
	var along_x := bounds.size.x < bounds.size.y
	var short_half := minf(bounds.size.x, bounds.size.y) * 0.5
	var centre := bounds.get_center()

	var radius := short_half * REEF_RADIUS

	# Laid out from one end so the cumulative sum is the position, rather than from the
	# middle outward: the channels are not symmetric, so there is no middle to work from.
	var span := 0.0

	for gap in gaps:
		span += gap + radius * 2.0

	var along := -span * 0.5

	for step in range(gaps.size() + 1):
		if step > 0:
			along += gaps[step - 1] + radius * 2.0

		out.append(
			Vector3(centre.x + along, centre.y + behind, radius) if along_x
			else Vector3(centre.x + behind, centre.y + along, radius)
		)

	return out


static func _append_chain(layout: HungryLayout, chain: PackedVector3Array) -> void:
	layout.chains.append(Vector2i(layout.blocks.size(), chain.size()))
	layout.blocks.append_array(chain)


## The four channel widths, tight end first, in world units.
##
## [b]Public because the level IS this list[/b], and a check that re-derives it from the
## rock positions is checking arithmetic rather than design. `headless_round` asks for it
## and then walks the blocks to confirm the rocks it built actually leave these gaps,
## which is the two-representations-from-one-description rule the 3D maps in this family
## follow.
static func channel_widths(short_half: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()

	for step in range(REEF_COUNT - 1):
		out.append(short_half * lerpf(
			REEF_TIGHT, REEF_WIDE, float(step) / float(REEF_COUNT - 2)
		))

	return out


## The back reef's four gaps, door first, in world units.
##
## [b]One door and three gates, and the same total opening as the fore reef.[/b] The door
## is the fore reef's widest channel; each gate is the MEAN of the fore reef's other three,
## which on a linear spread is exactly its second channel (442 at `reef`'s size). So the
## chain is as long as the fore reef's, its ends leave the same run-round, and the two
## barriers let the same total width through — distributed so that the fore reef sorts
## monsters by size ALONG its length and the back reef sorts them in one step: under
## about 760 mass you cross it anywhere, over it you cross at the door and nowhere else.
##
## [b]Why not the fore reef mirrored, which was the first design.[/b] A mirror puts the
## back reef's open end behind the fore reef's tight one, and on paper a leader walks the
## whole lagoon. On this mass curve it does not: `base_radius` is 8, a monster at `reef`'s
## winning mass is 620 across, and that fits the 635 third channel of BOTH barriers —
## which a mirror leaves 207 units apart, in the middle. The mirrored lagoon taxed only
## monsters over 1575 mass, which is past the mass that ends the round. The gates here
## are sized so the band that pays is everybody over the second channel, which is the
## leader and whoever is big enough to be chasing them.
static func back_reef_widths(short_half: float) -> PackedFloat32Array:
	var fore := channel_widths(short_half)
	var door := fore[fore.size() - 1]
	var rest := 0.0

	for index in range(fore.size() - 1):
		rest += fore[index]

	var gate := rest / float(fore.size() - 1)
	var out := PackedFloat32Array([door])

	for _step in range(fore.size() - 1):
		out.append(gate)

	return out


## How much clear floor the barrier leaves at each end, as a fraction of the short
## half-extent.
##
## Derived rather than chosen, because it is not a dial — it is whatever is left once the
## chain and its channels have been laid out, and the whole design depends on where it
## falls between [constant REEF_TIGHT] and [constant REEF_WIDE]. Stating it as a constant
## would be a second copy of the arithmetic and it would be the copy that went stale.
static func reef_end_fraction() -> float:
	var span := 0.0

	for gap in channel_widths(1.0):
		span += gap + REEF_RADIUS * 2.0

	return 1.0 - span * 0.5 - REEF_RADIUS


# --- Reading ---------------------------------------------------------------

func is_empty() -> bool:
	return blocks.is_empty()


func count() -> int:
	return blocks.size()


## How much floor the rocks stand on, in square units.
##
## [b]What a food target has to be read against once a level has geometry in it.[/b] The
## field is scattered over the whole rectangle and [method HungryWorld._cull_blocked]
## deletes whatever lands in a rock, so the same target over a smaller floor is less food
## per unit of walkable ground — a starvation change arriving as a side effect of a level,
## which is exactly the kind of thing nobody attributes to the level.
##
## Summed rather than unioned, so overlapping blocks are counted twice. Every layout here
## has a positive [method narrowest_gap] and therefore no overlap at all; a layout that
## grew one would over-report, which errs toward saying there is less floor than there is.
func covered_area() -> float:
	var total := 0.0

	for block in blocks:
		total += PI * block.z * block.z

	return total


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


## The narrowest way past anything solid, counting the arena's own walls.
##
## [b][method narrowest_gap] measures rock against rock, and that is only the whole
## question for a layout whose gates happen to be between two rocks.[/b] The warrens' are,
## because it is a ring; the slalom's are not, because a rock standing off one wall of a
## corridor makes its narrow lane against that wall and its wide one against the other,
## and neither is a gap between two rocks at all. Asked of the slalom, `narrowest_gap`
## answers 646 — the distance between two rocks a thousand units apart, which is not a
## gate, is not the level, and is not a number anybody would notice was wrong.
##
## This is the question every layout should be asked instead, and it reduces to the old
## one where the old one was right: the warrens' corner rocks stand further off the wall
## than its ring rocks stand from each other, so its answer is unchanged.
func narrowest_gate(bounds: Rect2) -> float:
	var narrowest := narrowest_gap()

	for block in blocks:
		narrowest = minf(narrowest, block.x - bounds.position.x - block.z)
		narrowest = minf(narrowest, bounds.end.x - block.x - block.z)
		narrowest = minf(narrowest, block.y - bounds.position.y - block.z)
		narrowest = minf(narrowest, bounds.end.y - block.y - block.z)

	return narrowest


## The largest monster radius that fits through [method narrowest_gate].
func fits_through_gate(bounds: Rect2) -> float:
	var gap := narrowest_gate(bounds)
	return gap * 0.5 if is_finite(gap) else INF


## The WIDEST way past the tightest rock, counting the walls.
##
## The other half of [method narrowest_gate], and a layout with no answer to it is a cage:
## a level whose narrowest gate shuts out a grown monster has to have a way round for one,
## or the mode ends with the leader stuck against a rock. Measured per block — the widest
## way past each, then the tightest of those — because a route is only as open as its
## worst rock.
func widest_way_past(bounds: Rect2) -> float:
	if blocks.is_empty():
		return INF

	var tightest := INF

	for block in blocks:
		var widest := maxf(
			maxf(block.x - bounds.position.x, bounds.end.x - block.x),
			maxf(block.y - bounds.position.y, bounds.end.y - block.y)
		) - block.z
		tightest = minf(tightest, widest)

	return tightest


## The channels through one barrier, measured off the discs it is actually built of.
##
## Each is `{"mouth": Vector2, "width": float, "normal": Vector2}`: the midpoint between
## two adjacent rocks of the chain, the clear distance between their faces, and the unit
## direction THROUGH the gap (either sign — [method route_across] picks the one it
## needs). In block order, which for every barrier here is tight end first.
##
## [b]Measured rather than recomputed from [method channel_widths][/b], because this is
## the representation a monster meets. The reef's section compares the two; if they are
## asked to agree they must come from different places.
func channels(chain: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	if chain < 0 or chain >= chains.size():
		return out

	var run := chains[chain]

	for index in range(run.x, run.x + run.y - 1):
		var here := blocks[index]
		var next := blocks[index + 1]
		var a := Vector2(here.x, here.y)
		var b := Vector2(next.x, next.y)
		var along := (b - a).normalized()
		var gap := a.distance_to(b) - here.z - next.z

		out.append({
			"mouth": a + along * (here.z + gap * 0.5),
			"width": gap,
			"normal": Vector2(-along.y, along.x),
		})

	return out


## Where to steer to get from [param from] to the far side of every barrier, for a
## monster of [param radius], or nothing when there is no way across for one that size.
##
## [b]Three points per barrier: in front of the mouth, the mouth, and behind it[/b], at
## the nearest channel that admits the radius plus [param margin], measured from where the
## route already is. The approach and exit points stand the rock's radius plus the
## monster's plus the margin off the chain's line, so a monster steering at one is never
## steering at a point inside a rock — a waypoint placed without its radius is how a
## bus in this family was once aimed at the middle of a pillar.
##
## [b]It ignores the run-round at each end, deliberately.[/b] That gap is narrower than
## the third channel, so it only ever matters to a monster small enough to cross anywhere,
## and a route that sometimes goes round the end and sometimes through the reef is two
## routes to check rather than one.
##
## Barriers are crossed nearest first, measured along each one's own normal, which is the
## order a monster meets them in from either side.
func route_across(from: Vector2, radius: float, margin: float = 24.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	var order: Array[int] = []

	for chain in range(chains.size()):
		order.append(chain)

	order.sort_custom(func(a: int, b: int) -> bool:
		return _chain_distance(a, from) < _chain_distance(b, from)
	)

	var here := from

	for chain in order:
		var best: Dictionary = {}
		var best_cost := INF

		for channel in channels(chain):
			if float(channel["width"]) < (radius + margin) * 2.0:
				continue

			var cost := here.distance_to(channel["mouth"])

			if cost < best_cost:
				best_cost = cost
				best = channel

		if best.is_empty():
			return PackedVector2Array()

		var mouth: Vector2 = best["mouth"]
		var normal: Vector2 = best["normal"]

		# Pointed from where the route is toward the far side of this barrier.
		if normal.dot(mouth - here) < 0.0:
			normal = -normal

		var standoff := blocks[chains[chain].x].z + radius + margin
		out.append(mouth - normal * standoff)
		out.append(mouth)
		out.append(mouth + normal * standoff)
		here = mouth + normal * standoff

	return out


## How far [param at] is from the line of one barrier's rocks.
func _chain_distance(chain: int, at: Vector2) -> float:
	var run := chains[chain]
	var first := blocks[run.x]
	var last := blocks[run.x + run.y - 1]
	var a := Vector2(first.x, first.y)
	var b := Vector2(last.x, last.y)
	var along := (b - a).normalized()
	return absf((at - a).dot(Vector2(-along.y, along.x)))


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
		"chains": chains.size(),
		"gap": narrowest_gap() if not blocks.is_empty() else 0.0,
	}


func _to_string() -> String:
	return "HungryLayout(%s, %d blocks)" % [id, blocks.size()]

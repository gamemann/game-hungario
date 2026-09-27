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

# No CHANNEL: a pure function of an id and a rectangle, with nothing at runtime to report.

## Nothing standing in the arena. What `classic` and `frenzy` use.
##
## Deliberately still two of them: the square modes are the control this game measures a
## level against, and "the same square with rocks in it" is only a claim if there is a
## square without them.
const NONE := &""

## A ring of gates around a middle, with cover in the corners.
const WARRENS := &"warrens"

## A line of rocks down a corridor, alternately near one wall and the other, and a fence of
## posts across each end of it with a harbour behind. See [method _slalom] and
## [method _append_harbours].
const SLALOM := &"slalom"

## A barrier across the world whose channels widen from one end to the other, a second
## one behind it with one door, an atoll in the open sea in front of it whose gates widen
## from the wall side to the reef side, and a spit from the sea wall either side of the
## atoll. See [method _reef], [method _append_atoll] and [method _append_spits].
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

## Which runs of [member blocks] are one CLOSED ring, as `(first, count)`.
##
## [b]The warrens' two rings, and why they are named rather than inferred.[/b] A ring's
## gates are between cyclic neighbours — the last rock and the first are a gate too — and
## its gate width is the level. Once the den stood inside the ring, "the narrowest gate on
## the map" stopped being the ring's gate and became the den's, so a check that asked the
## whole layout for the warrens' gate would have been asking about a different ring.
## [method ring_gates] asks one ring.
var rings: Array[Vector2i] = []

## Which runs of [member blocks] are one barrier, as `(first, count)`.
##
## [b]Empty for a layout that is not made of barriers[/b], which is the warrens. The reef
## has two, and the slalom has two short ones: the harbour fences across the corridor's
## ends, which are barriers in exactly this sense — a run of rocks across the world whose
## gaps are its doors.
## It exists because the reef stopped being one chain: a channel is a gap between two
## ADJACENT rocks of the SAME chain, and the last rock of one barrier and the first of the
## next are neighbours in [member blocks] and nothing at all on the map. A check that
## walked the array pairwise — which is what the reef's section did while there was one
## chain — would report a "channel" nine hundred units wide running along the lagoon.
var chains: Array[Vector2i] = []

## Which runs of [member blocks] are one of the reef's spits, as `(first, count)`, each
## laid out from the sea wall out. See [method _append_spits].
##
## [b]Not [member chains], although a spit is a run of rocks with gaps in it.[/b] A chain
## is a barrier ACROSS the world, and [method route_across] crosses every chain on the
## map, nearest first: handed a spit it would plan the lagoon's leader through the gap
## between two spit rocks it does not fit, or refuse it a route at all. A spit is
## something a monster goes through or round on the way to a barrier, not one of the
## barriers, so it has its own list and its own [method spit_gaps].
var spits: Array[Vector2i] = []


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

## The den: how many rocks, how far out, and how big, same fraction as the ring.
##
## [b]Sized by the three gaps it makes, not by how it looks.[/b] At `warrens`' size these
## are four rocks of 137 at 336 from the centre, which leaves:
##
## - [b]a den gate of 202[/b] — a radius of 101, a mass of about 160, a tenth of the winning
##   mass. A starting monster (22 mass, radius 38) walks in; anything that has eaten for a
##   minute does not.
## - [b]a moat of 418[/b] between the den's outer face and the ring's inner face, wider
##   than the ring's own 361 gate — so anything that came through the ring can walk round
##   the den. A moat narrower than the ring gate would be a second, hidden gate that only
##   showed itself to a monster already inside.
## - [b]an inside 200 across in radius[/b], room for two starting monsters to circle and
##   for one at the den limit to turn round.
const DEN_COUNT := 4
const DEN_AT := 0.16
const DEN_RADIUS := 0.065


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
		# Offset by half a step, which puts the ROCKS off the axes and therefore the
		# GATES on them — every 45 degrees, axes and diagonals. (This comment said the
		# opposite until the den was lined up against it, 2026-09-24; the geometry is
		# unchanged, and the den's straight run in from each wall depends on it.)
		var angle := TAU * (float(step) + 0.5) / float(RING_COUNT)
		out.blocks.append(Vector3(
			centre.x + cos(angle) * ring_at,
			centre.y + sin(angle) * ring_at,
			ring_radius
		))

	out.rings.append(Vector2i(0, RING_COUNT))

	var corner_at := half * CORNER_AT
	var corner_radius := half * CORNER_RADIUS

	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			out.blocks.append(Vector3(
				centre.x + sx * corner_at, centre.y + sy * corner_at, corner_radius
			))

	# [b]The den, appended LAST[/b], so the ring is still blocks 0-7 and the corners 8-11
	# for everything that was written against the warrens before it had a middle's middle.
	_append_den(out, centre, half)

	return out


## The warrens' second half: a ring inside the ring.
##
## [b]The ring made the middle a catch-up mechanic for whoever is behind; the den makes
## one for whoever is FURTHEST behind.[/b] The ring's gates admit about a third of the
## winning mass, so the middle is shared by everybody who has not yet run away with the
## round — and a monster of 480 in the middle eats a monster of 30 there as readily as it
## would outside. The den's gates admit about a tenth, so the one place on the map a
## newly spawned or just-eaten player cannot be followed into is the very centre, and
## getting there means crossing the middle first. Three tiers, one rule: mass is radius.
##
## [b]Its gates are on the axes, and so are four of the ring's.[/b] The ring's rocks sit
## half a step off the axes, which puts its gates ON them; the den's rocks sit on the
## diagonals, which puts its gates on the axes too. So from each wall's midpoint there is
## one straight line through a ring gate and a den gate to the centre — the route a small
## monster can read at a glance and run — and the four diagonal ring gates open onto the
## face of a den rock, so arriving by one of those means walking round to a door.
##
## [b]It is a room a monster can outgrow.[/b] Anything that eats its way past the den
## limit inside it has to split (half the mass is 1/sqrt(2) of the radius) or eject to get
## out, which is the warrens' own price for the middle, one tier down.
static func _append_den(layout: HungryLayout, centre: Vector2, half: float) -> void:
	var den_at := half * DEN_AT
	var den_radius := half * DEN_RADIUS
	var first := layout.blocks.size()

	for step in range(DEN_COUNT):
		var angle := TAU * (float(step) + 0.5) / float(DEN_COUNT)
		layout.blocks.append(Vector3(
			centre.x + cos(angle) * den_at, centre.y + sin(angle) * den_at, den_radius
		))

	layout.rings.append(Vector2i(first, DEN_COUNT))


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

	# [b]The harbours, appended AFTER the slalom[/b], so the slalom is still blocks 0-4 for
	# everything written against it before the corridor had ends.
	_append_harbours(out, bounds)

	return out


## How many posts stand in each harbour's fence. Three leaves four doors: two against the
## walls and two between posts, and the middle post stands on the centre line.
const HARBOUR_POSTS := 3

## How wide one door is, as a fraction of the corridor's HALF-WIDTH.
##
## 201 units at `gauntlet`'s size, so a radius of 100 and a mass of about 158 — a sixth of
## the winning mass, and a tier below the slalom's near lane (268, about 280 mass). A
## starting monster (radius 38) walks in; anything that has fed for a minute does not.
const HARBOUR_DOOR := 0.3

## How far each fence stands from its end wall, centre line to wall, same fraction.
##
## [b]Sized by the two gaps it makes.[/b] At `gauntlet`'s size the fence stands 386 from
## the end wall, which leaves a harbour 296 deep behind the posts' back faces — room for a
## crowd of starting monsters and about thirty crumbs — and 402 between the end slalom
## rock and the middle post: wider than the slalom's near lane, so the water in front of
## the fence is not a hidden gate. Further out and the harbour grows at the moat's
## expense; the end slalom rock is 1118 from the wall and nothing here moves it.
const HARBOUR_AT := 0.575


## The corridor's ends: a fence of posts across each, with four doors a monster outgrows.
##
## [b]In a corridor the end is where a chase finishes.[/b] A square has no dead end — a
## monster being chased turns and keeps running — and the slalom made the corridor's
## middle a choice of lanes, but the two ends were still walls with nowhere to go, and a
## small monster driven down the corridor was eaten against one of them. The harbour turns
## the worst place on the map into the only refuge on it: behind the fence is floor that
## nobody over about a sixth of the winning mass can follow a player onto.
##
## [b]Four doors, not one, because one door is a cork.[/b] A single gap in the middle of
## the fence can be sat outside by anybody bigger, and the small monster in the harbour is
## then trapped rather than safe. With four doors across 1342 units, a monster waiting
## outside one is 450 units from the next, and the refuge is a place to wait out a chase
## rather than a cell.
##
## [b]The warrens' den is the same rule in a different place.[/b] The den is a refuge in
## the middle of a map everybody crosses; a harbour is a refuge at the end of a map that
## everybody is chased along. Both are a tier below the level's main gate, both are rooms
## a monster can outgrow — one that eats past the limit inside has to split or eject to
## leave — and both are open to the players furthest behind and to nobody else.
static func _append_harbours(layout: HungryLayout, bounds: Rect2) -> void:
	var along_x := bounds.size.x >= bounds.size.y
	var long_half := maxf(bounds.size.x, bounds.size.y) * 0.5
	var short_half := minf(bounds.size.x, bounds.size.y) * 0.5
	var centre := bounds.get_center()
	var door := short_half * HARBOUR_DOOR
	var post := harbour_post_radius(short_half)
	var at := long_half - short_half * HARBOUR_AT

	# West (or north) end first, then east; each fence laid out from the short axis's low
	# end, so its first channel is the door next to the first post.
	for side in [-1.0, 1.0]:
		var fence := PackedVector3Array()

		for step in range(HARBOUR_POSTS):
			var across := -short_half + door * float(step + 1) + post * float(step * 2 + 1)
			var along: float = side * at
			fence.append(
				Vector3(centre.x + along, centre.y + across, post) if along_x
				else Vector3(centre.x + across, centre.y + along, post)
			)

		_append_chain(layout, fence)


## The radius of one harbour post: whatever is left of the corridor's width once the four
## doors are taken out, shared between the posts. Derived, so the doors are the number
## that was chosen and the posts are what that choice leaves.
static func harbour_post_radius(short_half: float) -> float:
	return (short_half * 2.0 - short_half * HARBOUR_DOOR * float(HARBOUR_POSTS + 1)) \
		/ float(HARBOUR_POSTS * 2)


## Which harbour [param at] stands in — the index into [member chains] of the fence it is
## behind — or -1 if it is not behind one. "Behind" is past the fence's FRONT face, the
## side facing the corridor's middle, so a point between two posts counts as in the
## harbour: it is past the line a monster outgrows. Only the slalom has harbours.
func harbour_of(at: Vector2, bounds: Rect2) -> int:
	if id != SLALOM:
		return -1

	var along_x := bounds.size.x >= bounds.size.y
	var centre := bounds.get_center()
	var here := (at.x - centre.x) if along_x else (at.y - centre.y)

	for chain in range(chains.size()):
		var first := blocks[chains[chain].x]
		var fence := (first.x - centre.x) if along_x else (first.y - centre.y)

		if here * fence > 0.0 and absf(here) > absf(fence) - first.z:
			return chain

	return -1


## The rocks of runs [param first] to [param first] + [param count] as a layout of their
## own, so a check about one part of a level can ask the part rather than the whole: the
## slalom's lanes are a question about its five rocks, and with the harbours on the map
## "the narrowest gate" is a harbour door.
func part(first: int, count: int) -> HungryLayout:
	var out := HungryLayout.new()
	out.id = id
	out.blocks = blocks.slice(first, first + count)
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
	# [b]The atoll, appended after both barriers[/b], so the two barriers are still blocks
	# 0-9 for everything written against the reef before its open sea had anything in it.
	_append_atoll(out, bounds)
	# [b]The spits, appended LAST[/b], so the atoll is still blocks 10-13 and still
	# `rings[0]`. They are neither chains nor rings: see [member spits].
	_append_spits(out, bounds)

	return out


## How many rocks the atoll is made of: four, two on the wall side and two on the reef
## side, which is what makes its gates a gradient — see [method atoll_widths].
const ATOLL_COUNT := 4

## How big one atoll rock is, as a fraction of the short half-extent. Smaller than a reef
## rock (0.075): the gates are the design number and the rocks are what holds them apart.
const ATOLL_RADIUS := 0.025

## How far in front of the fore reef the atoll's centre stands, as the same fraction.
##
## [b]Sized by the leader who has to walk past it.[/b] At `reef`'s size the atoll's centre
## is 1472 in front of the fore reef, which leaves 902 of open water between its reef-side
## rocks and the fore reef's face — room for a leader 620 across to walk along the reef to
## the open end without touching either — and 430 between its wall-side rocks and the wall:
## wider than the tight channel, so it is not a hidden gate tighter than the map's
## tightest, and narrower than a leader, so the leader's way past is the reef side. The
## atoll is well clear of both walls along the reef, so nothing behind that 430 is a pocket.
const ATOLL_AT := 0.595


## The reef's third part: an atoll in the open sea in front of the fore reef.
##
## [b]The lagoon made crossing cost a grown monster distance; the open sea in front of the
## fore reef was still 2128 units of empty water where a chase is decided by speed.[/b] The
## atoll is a ring of four rocks standing in it, and it is the reef's own rule turned
## round into a room: the fore reef asks "how far along me will you walk to cross", and
## the atoll asks "which side of me will you walk round to get in". Its gates widen from
## the wall side to the reef side — the fore reef's tight channel facing the wall, the fore
## reef's second channel facing the reef, and their mean on the two flanks — so a starting
## monster gets in from anywhere, a middling one has to go round to a flank or the reef
## side, and one near the back reef's limit has to go round to the one gate that faces the
## reef. Anything that fits no gate is exactly who the back reef shuts out everywhere but
## its door: the atoll is shut to the leader band and to nobody else.
##
## [b]Built as an isosceles trapezoid rather than on a circle[/b], because that is the
## shape whose gates are the design numbers in closed form: the wall-side pair stand the
## tight gate apart, the reef-side pair the wide gate apart, and their distance along the
## crossing axis is whatever leaves the mean between each flank pair. Blocks are appended
## wall-side low end first and round, so [method ring_gates] reads tight, flank, wide,
## flank — the order [method atoll_widths] describes.
static func _append_atoll(layout: HungryLayout, bounds: Rect2) -> void:
	# The crossing axis is the one the reef is NOT built along; the lagoon is on its
	# positive side, so the open sea — and the atoll — is on its negative side.
	var chain_along_x := bounds.size.x < bounds.size.y
	var short_half := minf(bounds.size.x, bounds.size.y) * 0.5
	var centre := bounds.get_center()
	var along := Vector2(1.0, 0.0) if chain_along_x else Vector2(0.0, 1.0)
	var toward_reef := Vector2(0.0, 1.0) if chain_along_x else Vector2(1.0, 0.0)
	var middle := centre - toward_reef * short_half * ATOLL_AT

	var gates := atoll_widths(short_half)
	var radius := short_half * ATOLL_RADIUS
	var wall_half := gates[0] * 0.5 + radius
	var reef_half := gates[2] * 0.5 + radius
	var flank := gates[1] + radius * 2.0
	var depth := sqrt(flank * flank - (reef_half - wall_half) * (reef_half - wall_half)) * 0.5
	var first := layout.blocks.size()

	for rock in [
		Vector2(-depth, -wall_half), Vector2(-depth, wall_half),
		Vector2(depth, reef_half), Vector2(depth, -reef_half),
	]:
		var at: Vector2 = middle + toward_reef * rock.x + along * rock.y
		layout.blocks.append(Vector3(at.x, at.y, radius))

	layout.rings.append(Vector2i(first, ATOLL_COUNT))


## The atoll's four gates in ring order — wall side, flank, reef side, flank — in world
## units.
##
## [b]The fore reef's list again, rather than a third set of constants.[/b] The wall-side
## gate is the fore reef's tight channel, the reef-side gate its second channel (which is
## also every gate of the back reef), and each flank their mean. So the atoll sorts the
## same band the back reef does — under about 760 mass gets in, over it does not — and
## sorts it by side: about 240 mass fits every gate, about 465 the flanks and the reef
## side, and the rest only the side that faces the reef.
static func atoll_widths(short_half: float) -> PackedFloat32Array:
	var fore := channel_widths(short_half)
	var flank := (fore[0] + fore[1]) * 0.5
	return PackedFloat32Array([fore[0], flank, fore[1], flank])


## The atoll's centre, the point its gates are measured toward. Only the reef has one.
func atoll_centre() -> Vector2:
	if id != REEF or rings.is_empty():
		return Vector2.INF

	var total := Vector2.ZERO
	var run := rings[0]

	for index in range(run.x, run.x + run.y):
		total += Vector2(blocks[index].x, blocks[index].y)

	return total / float(run.y)


## How many rocks one spit is made of. Two leave two gaps: one against the sea wall and
## one between the rocks — see [method spit_widths].
const SPIT_COUNT := 2

## How far either side of the crossing axis each spit stands, as a fraction of the short
## half-extent: half way from the atoll's line to the wall, 1150 at `reef`'s size.
const SPIT_AT := 0.5

## How big one spit rock is, same fraction. 92 at `reef`'s size.
##
## [b]Sized by the leader who walks past the end of it, like the atoll.[/b] The gaps are
## the design numbers and are fixed; the rock is what decides how far the spit reaches
## from the wall. At 0.04 it ends 1070 short of the fore reef — wider than a leader (620)
## and 74 clear of one on the leg the lagoon section drives from the tight end to the open
## end, which runs 852 from the centre line as it passes the northern spit. At 0.045 the
## spit ends 4 units off that leg; at 0.05 it stands on it.
const SPIT_RADIUS := 0.04


## The reef's fourth part: a spit from the sea wall on each side of the atoll.
##
## [b]The atoll made the middle of the open sea a room; the water north and south of it
## was still one sea a leader crossed in any direction it liked.[/b] Each spit is two rocks
## running from the sea wall toward the fore reef, with the fore reef's first two channels
## for gaps — the tight one against the wall and the second between the rocks — and open
## water at its reef end. So the sea is one water for anybody under the back reef's band
## (about 760 mass fits the gap between the rocks, about 240 the one at the wall) and
## three for a leader: the sea in front of the tight end, the atoll's water, and the sea in
## front of the open end are joined for it only round the spits' reef ends, in the lane
## along the fore reef. A middling monster chased across the sea goes through a spit; the
## leader chasing it goes round, a thousand units further, down the lane everybody can see.
## It is the reef's rule once more — size decides where you cross, not whether — turned
## from the reef's own axis onto the sea's.
##
## [b]It encloses nothing.[/b] Every gap faces open water on both sides, so no floor is
## behind a door and nothing here is a refuge a hunter must be refused: a flood at every
## size up to the widest gap reaches the whole of the sea.
static func _append_spits(layout: HungryLayout, bounds: Rect2) -> void:
	var chain_along_x := bounds.size.x < bounds.size.y
	var short_half := minf(bounds.size.x, bounds.size.y) * 0.5
	var centre := bounds.get_center()
	var along := Vector2(1.0, 0.0) if chain_along_x else Vector2(0.0, 1.0)
	var toward_reef := Vector2(0.0, 1.0) if chain_along_x else Vector2(1.0, 0.0)
	# The sea wall is the crossing axis's low wall, which in a non-square world is the
	# LONG half-extent away: the reef is built across the short axis.
	var sea_half := (bounds.size.y if chain_along_x else bounds.size.x) * 0.5
	var gaps := spit_widths(short_half)
	var radius := short_half * SPIT_RADIUS

	for side in [-1.0, 1.0]:
		var first := layout.blocks.size()
		var from_wall := 0.0

		for step in range(SPIT_COUNT):
			from_wall += gaps[step] + radius * (1.0 if step == 0 else 2.0)
			var at: Vector2 = centre - toward_reef * (sea_half - from_wall) \
				+ along * (side * short_half * SPIT_AT)
			layout.blocks.append(Vector3(at.x, at.y, radius))

		layout.spits.append(Vector2i(first, SPIT_COUNT))


## A spit's gaps, from the sea wall out, in world units: the fore reef's tight channel
## against the wall and its second channel between the rocks.
##
## [b]The fore reef's list again[/b], for the atoll's reason: the second channel is also
## every back reef gate and the atoll's reef-side gate, so a spit is shut to exactly the
## band the back reef shuts out everywhere but its door, and its wall gap to exactly the
## band the fore reef's tight channel shuts out.
static func spit_widths(short_half: float) -> PackedFloat32Array:
	var fore := channel_widths(short_half)
	return PackedFloat32Array([fore[0], fore[1]])


## One spit's gaps as the rocks the world built leave them, from the sea wall out: the
## first rock to the wall along the crossing axis, then rock to rock. Measured off the
## discs, like [method channels], so the section compares two representations.
func spit_gaps(spit: int, bounds: Rect2) -> PackedFloat32Array:
	var out := PackedFloat32Array()

	if id != REEF or spit < 0 or spit >= spits.size():
		return out

	var chain_along_x := bounds.size.x < bounds.size.y
	var run := spits[spit]
	var first := blocks[run.x]
	out.append(
		(first.y - bounds.position.y if chain_along_x else first.x - bounds.position.x) - first.z
	)

	for index in range(run.x, run.x + run.y - 1):
		var a := blocks[index]
		var b := blocks[index + 1]
		out.append(Vector2(a.x, a.y).distance_to(Vector2(b.x, b.y)) - a.z - b.z)

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


## The gaps between cyclic neighbours of one closed ring, edge to edge, in block order.
##
## Measured off the discs, like [method channels], so a check that compares it with the
## design is comparing two representations rather than one number with itself.
func ring_gates(ring: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()

	if ring < 0 or ring >= rings.size():
		return out

	var run := rings[ring]

	for step in range(run.y):
		var a := blocks[run.x + step]
		var b := blocks[run.x + (step + 1) % run.y]
		out.append(Vector2(a.x, a.y).distance_to(Vector2(b.x, b.y)) - a.z - b.z)

	return out


# --- Reach -----------------------------------------------------------------

## Every gap on the map a monster could be asked to pass through, rock to rock and rock to
## wall.
##
## Each is `{"a": int, "b": int, "mouth": Vector2, "across": Vector2, "normal": Vector2,
## "width": float}`: the two things either side (`b` is -1 to -4 for the left, right, top
## and bottom walls), the midpoint of the clear span, the unit direction ALONG that span,
## the unit direction THROUGH it, and its width.
##
## [b]A gap is a gap only if nothing else stands in it[/b] — the Gabriel rule: no third
## rock touches the circle whose diameter is the clear span. Without it rock 0 and rock 2
## of a ring would be reported as a 1108-unit "gate" with rock 1 standing in its mouth,
## and every pair on the map would be a gate to something. [method narrowest_gate] and
## [method channels] each answer one layout's question; this answers every layout's, and
## is what [method gate_passes] is driven over.
func gates(bounds: Rect2) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for i in range(blocks.size()):
		var a := blocks[i]
		var at := Vector2(a.x, a.y)

		for j in range(i + 1, blocks.size()):
			var b := blocks[j]
			var bt := Vector2(b.x, b.y)
			var across := (bt - at).normalized()
			var width := at.distance_to(bt) - a.z - b.z

			if width <= 0.0:
				continue

			var mouth := at + across * (a.z + width * 0.5)

			if not _gap_clear(bounds, mouth, width * 0.5, [i, j]):
				continue

			out.append({
				"a": i, "b": j, "mouth": mouth, "across": across,
				"normal": Vector2(-across.y, across.x), "width": width,
			})

		# The four walls: the perpendicular from the rock to each one.
		var walls := [
			[-1, Vector2.LEFT, at.x - bounds.position.x],
			[-2, Vector2.RIGHT, bounds.end.x - at.x],
			[-3, Vector2.UP, at.y - bounds.position.y],
			[-4, Vector2.DOWN, bounds.end.y - at.y],
		]

		for wall in walls:
			var across: Vector2 = wall[1]
			var width: float = float(wall[2]) - a.z

			if width <= 0.0:
				continue

			var mouth := at + across * (a.z + width * 0.5)

			if not _gap_clear(bounds, mouth, width * 0.5, [i]):
				continue

			out.append({
				"a": i, "b": int(wall[0]), "mouth": mouth, "across": across,
				"normal": Vector2(-across.y, across.x), "width": width,
			})

	return out


## Whether the circle across a gap is empty of everything but the gap's own two sides —
## no third rock, and no wall it does not belong to. The wall half is what stops the reef's
## end rock and the far wall, 2128 apart across a strip 361 deep, being reported as a gate
## a monster of radius 1060 should pass.
func _gap_clear(bounds: Rect2, mouth: Vector2, reach: float, except: Array) -> bool:
	if not bounds.grow(1.0).encloses(Rect2(mouth - Vector2(reach, reach), Vector2(reach, reach) * 2.0)):
		return false

	for k in range(blocks.size()):
		if except.has(k):
			continue

		var c := blocks[k]

		if mouth.distance_to(Vector2(c.x, c.y)) < reach + c.z:
			return false

	return true


## Whether a monster of [param radius] can get through one gap from [method gates], found
## by a flood fill on the geometry rather than by comparing its width.
##
## [b]Filled inside the gap's own box[/b] — the clear span one way, a monster's radius and
## a few cells either side of the throat the other — and it passes when a fill from any
## free cell BEFORE the throat reaches any free cell AFTER it. The box's span is exactly
## the gap, so the only way across the throat is through it; a box any wider lets the fill
## walk round a rock and report a shut gate as open. And the far rows are not required to
## be free: a corridor's wall or the next rock of a chain can stand in the box's corners
## without being in the gate, and the first version of this, which demanded the box's
## outer rows, reported the lagoon and the den's inside as shut.
func gate_passes(bounds: Rect2, gate: Dictionary, radius: float, cell: float = 6.0) -> bool:
	var mouth: Vector2 = gate["mouth"]
	var across: Vector2 = gate["across"]
	var normal: Vector2 = gate["normal"]
	var half_width := float(gate["width"]) * 0.5
	var half_rows := int(ceil((radius + cell * 3.0) / cell))
	var columns := int(ceil(half_width * 2.0 / cell)) + 1
	var rows := half_rows * 2 + 1
	var inner := bounds.grow(-radius)
	var free := PackedByteArray()
	free.resize(columns * rows)

	for row in range(rows):
		for column in range(columns):
			var at := mouth \
				+ across * (-half_width + float(column) * cell) \
				+ normal * (float(row - half_rows) * cell)
			free[row * columns + column] = 1 if inner.has_point(at) and not blocked(at, radius) else 0

	var seen := PackedByteArray()
	seen.resize(free.size())
	var queue := PackedInt32Array()

	for index in range(half_rows * columns):
		if free[index] == 1:
			seen[index] = 1
			queue.append(index)

	var head := 0

	while head < queue.size():
		var index := queue[head]
		head += 1

		if index / columns > half_rows:
			return true

		for next in _neighbours(index, columns, rows):
			if free[next] == 1 and seen[next] == 0:
				seen[next] = 1
				queue.append(next)

	return false


static func _neighbours(index: int, columns: int, rows: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var column := index % columns
	var row := index / columns

	if column > 0:
		out.append(index - 1)
	if column < columns - 1:
		out.append(index + 1)
	if row > 0:
		out.append(index - columns)
	if row < rows - 1:
		out.append(index + columns)

	return out


## The whole-world sweep: which of the floor a monster of [param radius] can get to from
## [param from], sampled on a grid of [param cell].
##
## Returns `{"free": int, "reached": int, "stranded": PackedVector2Array}` — the sampled
## points a monster that size can stand on, how many of those the fill from [param from]
## got to, and the ones it did not. `free - reached` is floor nobody that size can reach:
## deliberate for a grown monster behind a gate it has outgrown, and a bug at the starting
## size — a pocket a spawn can land in and never leave, or one the food fills and nobody
## eats.
func reach(bounds: Rect2, from: Vector2, radius: float, cell: float = 24.0) -> Dictionary:
	var grid := _grid(bounds, radius, cell)
	var columns: int = grid["columns"]
	var rows: int = grid["rows"]
	var free: PackedByteArray = grid["free"]
	var start := _cell_of(bounds, from, cell, columns, rows)
	var seen := _fill(free, columns, rows, start, _diagonal_check(bounds, radius, cell, columns))
	var total := 0
	var reached := 0
	var stranded := PackedVector2Array()

	for index in range(free.size()):
		if free[index] == 0:
			continue

		total += 1

		if seen[index] == 1:
			reached += 1
		else:
			stranded.append(_centre_of(bounds, index, cell, columns))

	return {"free": total, "reached": reached, "stranded": stranded}


## The biggest stretch of floor a disc of [param radius] can move about in, as
## `{"columns", "rows", "cell", "seen": PackedByteArray, "reached": int, "free": int}`:
## [method reach] turned round, asking "which floor is the map" rather than "where can I
## get from here", because a thing placed with no player to walk from has no here.
##
## [b]For a spawn that must not land in a pocket.[/b] Floor outside the biggest region is
## floor a thing that size cannot leave: a room whose door it does not fit, or a cranny
## between two rocks. Asked of a hunter's size, it is where a hunter must not appear.
## Every free cell is flooded once, whichever region it belongs to.
func main_region(bounds: Rect2, radius: float, cell: float = 24.0) -> Dictionary:
	var grid := _grid(bounds, radius, cell)
	var columns: int = grid["columns"]
	var rows: int = grid["rows"]
	var free: PackedByteArray = grid["free"]
	var diagonal := _diagonal_check(bounds, radius, cell, columns)
	var taken := PackedByteArray()
	taken.resize(free.size())
	var best := PackedByteArray()
	best.resize(free.size())
	var best_count := 0
	var total := 0

	for index in range(free.size()):
		if free[index] == 1:
			total += 1

	for index in range(free.size()):
		if free[index] == 0 or taken[index] == 1:
			continue

		var seen := _fill(free, columns, rows, index, diagonal)
		var count := 0

		for at in range(seen.size()):
			if seen[at] == 1:
				taken[at] = 1
				count += 1

		if count > best_count:
			best_count = count
			best = seen

		# Past half, nothing left can be bigger.
		if best_count * 2 > total:
			break

	return {
		"columns": columns, "rows": rows, "cell": cell, "seen": best,
		"reached": best_count, "free": total,
	}


## Whether [param at] stands in [param region] ([method main_region]'s answer for the same
## bounds). A point exactly at a rock's clearance can sit in a cell whose centre is just
## inside it, so the cell's eight neighbours count as well: a region is floor a disc moves
## about in, and a disc one cell off it is on it.
static func in_region(region: Dictionary, bounds: Rect2, at: Vector2) -> bool:
	var columns: int = region["columns"]
	var rows: int = region["rows"]
	var seen: PackedByteArray = region["seen"]
	var home := _cell_of(bounds, at, float(region["cell"]), columns, rows)

	if home < 0:
		return false

	if seen[home] == 1:
		return true

	for next in _neighbours(home, columns, rows):
		if seen[next] == 1:
			return true

	var column := home % columns
	var row := home / columns

	for dy in [-1, 1]:
		for dx in [-1, 1]:
			var c: int = column + dx
			var r: int = row + dy

			if c >= 0 and r >= 0 and c < columns and r < rows and seen[r * columns + c] == 1:
				return true

	return false


## A route from [param from] to [param to] for a monster of [param radius], as waypoints
## no straight leg of which passes through a rock, or nothing when there is none.
##
## [b]The general answer [method route_across] gives for barriers[/b]: that one knows the
## reef's chains and steers by channel; this knows nothing but the discs, so it answers
## for a ring, a den and anything after them. A grid fill for the path and then the
## string pulled tight — each waypoint is the furthest point on the path still in a
## clear straight line — so a monster steering at the next one is never steering at a
## point on the far side of a rock.
func route_to(bounds: Rect2, from: Vector2, to: Vector2, radius: float, cell: float = 24.0) -> PackedVector2Array:
	var grid := _grid(bounds, radius, cell)
	var columns: int = grid["columns"]
	var rows: int = grid["rows"]
	var free: PackedByteArray = grid["free"]
	var start := _cell_of(bounds, from, cell, columns, rows)
	var goal := _cell_of(bounds, to, cell, columns, rows)

	if start < 0 or goal < 0 or free[start] == 0 or free[goal] == 0:
		return PackedVector2Array()

	var parent := PackedInt32Array()
	parent.resize(free.size())
	parent.fill(-1)
	parent[start] = start
	var queue := PackedInt32Array([start])
	var head := 0

	var diagonal := _diagonal_check(bounds, radius, cell, columns)

	while head < queue.size() and parent[goal] == -1:
		var index := queue[head]
		head += 1

		for next in _steps(index, columns, rows, free, diagonal):
			if free[next] == 1 and parent[next] == -1:
				parent[next] = index
				queue.append(next)

	if parent[goal] == -1:
		return PackedVector2Array()

	var path := PackedVector2Array([to])
	var walk := parent[goal]

	while walk != start:
		path.append(_centre_of(bounds, walk, cell, columns))
		walk = parent[walk]

	path.append(from)
	path.reverse()

	var out := PackedVector2Array()
	var here := 0

	while here < path.size() - 1:
		var furthest := here + 1

		for ahead in range(path.size() - 1, here, -1):
			if _clear_line(path[here], path[ahead], radius, cell * 0.5):
				furthest = ahead
				break

		out.append(path[furthest])
		here = furthest

	return out


func _clear_line(from: Vector2, to: Vector2, radius: float, step: float) -> bool:
	var steps := maxi(1, int(ceil(from.distance_to(to) / step)))

	for index in range(steps + 1):
		if blocked(from.lerp(to, float(index) / float(steps)), radius):
			return false

	return true


func _grid(bounds: Rect2, radius: float, cell: float) -> Dictionary:
	var columns := int(floor(bounds.size.x / cell))
	var rows := int(floor(bounds.size.y / cell))
	var inner := bounds.grow(-radius)
	var free := PackedByteArray()
	free.resize(columns * rows)

	for index in range(columns * rows):
		var at := _centre_of(bounds, index, cell, columns)
		free[index] = 1 if inner.has_point(at) and not blocked(at, radius) else 0

	return {"columns": columns, "rows": rows, "free": free}


static func _centre_of(bounds: Rect2, index: int, cell: float, columns: int) -> Vector2:
	return bounds.position + Vector2(
		(float(index % columns) + 0.5) * cell, (float(index / columns) + 0.5) * cell
	)


static func _cell_of(bounds: Rect2, at: Vector2, cell: float, columns: int, rows: int) -> int:
	var column := int(floor((at.x - bounds.position.x) / cell))
	var row := int(floor((at.y - bounds.position.y) / cell))

	if column < 0 or row < 0 or column >= columns or row >= rows:
		return -1

	return row * columns + column


## Eight ways out of a cell rather than four. [b]Four was a finding:[/b] a diagonal gate's
## outer funnel narrows along the diagonal, so a sampled point in it can be free while
## both its orthogonal neighbours are inside the rocks either side — reachable by any
## monster walking in along the diagonal, stranded to a fill that can only step across.
## The warrens' four diagonal gates each reported one such point. A diagonal step is
## taken when either orthogonal neighbour is free (it is then two orthogonal steps) or
## the midpoint of the step is clear, so it cannot hop between two rocks.
static func _steps(index: int, columns: int, rows: int, free: PackedByteArray, diagonal: Callable) -> PackedInt32Array:
	var out := _neighbours(index, columns, rows)
	var column := index % columns
	var row := index / columns

	for dy in [-1, 1]:
		for dx in [-1, 1]:
			var c: int = column + dx
			var r: int = row + dy

			if c < 0 or r < 0 or c >= columns or r >= rows:
				continue

			var next: int = r * columns + c

			if free[next] == 0:
				continue

			if free[row * columns + c] == 1 or free[r * columns + column] == 1 or diagonal.call(index, next):
				out.append(next)

	return out


func _diagonal_check(bounds: Rect2, radius: float, cell: float, columns: int) -> Callable:
	return func(from: int, to: int) -> bool:
		var mid := (_centre_of(bounds, from, cell, columns) + _centre_of(bounds, to, cell, columns)) * 0.5
		return not blocked(mid, radius)


static func _fill(free: PackedByteArray, columns: int, rows: int, start: int, diagonal: Callable) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(free.size())

	if start < 0 or free[start] == 0:
		return seen

	seen[start] = 1
	var queue := PackedInt32Array([start])
	var head := 0

	while head < queue.size():
		var index := queue[head]
		head += 1

		for next in _steps(index, columns, rows, free, diagonal):
			if free[next] == 1 and seen[next] == 0:
				seen[next] = 1
				queue.append(next)

	return seen


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
		"rings": rings.size(),
		"spits": spits.size(),
		"gap": narrowest_gap() if not blocks.is_empty() else 0.0,
	}


func _to_string() -> String:
	return "HungryLayout(%s, %d blocks)" % [id, blocks.size()]

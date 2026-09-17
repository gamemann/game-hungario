@tool
extends Resource

const HungryContent := preload("hungry_content.gd")
const HungryLayout := preload("hungry_layout.gd")
const HungryPreset := preload("hungry_preset.gd")

## The handful of numbers that make one mode of this game different from another.
##
## [b]A resource rather than a subclass, because a mode is a tuning and not a
## behaviour.[/b] Everything here is something an operator might reasonably want to change
## between two servers, and none of it changes what the code does — which is the line that
## decides whether something belongs in [HungryContent] (where the relationships live) or
## here (where the dials are).
##
## It is also what makes [DotGameManager]'s game change worth demonstrating: two scenes,
## two presets, and a server that swaps between them while everybody stays connected.

@export var id: StringName = &"classic"

@export var display_name: String = "Classic"

@export_group("World")

@export var world_size: Vector2 = HungryContent.WORLD_SIZE

@export_range(0, 20000, 50) var food_target: int = HungryContent.FOOD_TARGET
@export_range(0, 200, 1) var fruit_target: int = HungryContent.FRUIT_TARGET
@export_range(0, 200, 1) var item_target: int = HungryContent.ITEM_TARGET

## Which solid geometry stands in the world. Empty is an empty box.
##
## [b]A name rather than a list of shapes, because it has to survive the wire.[/b] A client
## is told which layout is playing and builds the discs itself — see [HungryLayout] — so
## what travels is one short string and not a hundred and forty-four bytes of circles that
## both ends already know.
@export var layout: StringName = HungryLayout.NONE

@export_group("Growing")

@export_range(10.0, 1000000.0, 10.0) var win_mass: float = HungryContent.WIN_MASS

@export_range(1.0, 5000.0, 5.0) var max_speed: float = 415.0

## Seconds before two pieces of the same monster merge back.
##
## The single most consequential number in the game: it decides how long a split costs
## you, and therefore whether splitting to catch somebody is ever worth it.
@export_range(0.0, 300.0, 0.5) var merge_delay_sec: float = 16.0

@export_group("Round")

@export_range(0.0, 7200.0, 10.0) var time_limit_sec: float = 900.0


static func classic() -> HungryPreset:
	return HungryPreset.new()


## Small, fast, and over quickly. What a server switches to when six people are waiting.
static func frenzy() -> HungryPreset:
	var preset := HungryPreset.new()
	preset.id = &"frenzy"
	preset.display_name = "Frenzy"
	preset.world_size = Vector2(3000.0, 3000.0)
	preset.food_target = 700
	preset.fruit_target = 18
	preset.item_target = 26
	preset.win_mass = 900.0
	preset.max_speed = 520.0
	# Four seconds rather than sixteen. Splitting stops being a commitment and starts
	# being a move, which is the whole character of the mode.
	preset.merge_delay_sec = 4.0
	preset.time_limit_sec = 300.0
	return preset


## Long and narrow. A corridor rather than a square, which is a different game.
##
## [b]This is a LEVEL, not a third set of dials, and the difference is the aspect
## ratio.[/b] Classic and Frenzy are the same square at two sizes: everything is reachable
## in every direction, so being caught is a failure of speed. A five-to-one corridor
## removes the third and fourth directions — there is nowhere sideways to run, being
## chased means being chased *along* something, and splitting to get past somebody is the
## move rather than an alternative to it. Nothing about the code changes; the shape does.
##
## [b]It is also the first non-square world this game has ever run[/b], which is worth
## more than the mode is. A square world hides every place that reads `world_size.x` where
## it meant `.y`, or that derives a radius from one component: the value is the same, so
## the bug is invisible. `headless_round` walks a monster into all four walls here for
## exactly that reason.
##
## [b]And it is a corridor with things in it now, which is the half that was missing.[/b]
## Removing the sideways directions makes being chased different; it does not make getting
## away from somebody a decision, because along a bare corridor the faster monster still
## arrives. [constant HungryLayout.SLALOM] puts five rocks down it, alternately near one
## wall and the other, so every one of them has a narrow lane and a wide one and a monster
## that has grown can only use the wide one. The shortcut changes sides at every rock, so
## taking it is paid for by the crossing that follows. See [method HungryLayout._slalom].
static func gauntlet() -> HungryPreset:
	var preset := HungryPreset.new()
	preset.id = &"gauntlet"
	preset.display_name = "Gauntlet"
	preset.layout = HungryLayout.SLALOM

	# Five to one, and the same area as Frenzy's square. Same amount of food per unit of
	# floor, so the mode is the shape and not the density — otherwise a corridor would
	# also be a starvation mode and there would be no telling which half was doing the
	# work.
	preset.world_size = Vector2(6708.0, 1342.0)

	# [b]Raised from 700 when the slalom arrived, so the mode's density did not quietly
	# drop when its floor did.[/b] Five rocks cover about an eighth of the corridor and
	# `HungryWorld._cull_blocked` deletes everything the scatter puts inside one, so the
	# old number over the new floor is an eighth less food on the same amount of walkable
	# ground — a starvation change nobody asked for, arriving as a side effect of a level.
	preset.food_target = 790
	preset.fruit_target = 18
	preset.item_target = 26
	preset.win_mass = 900.0
	preset.max_speed = 480.0

	# Between the other two. A corridor punishes a split harder than a square does —
	# there is nowhere to spread out to while the pieces are apart — so sixteen seconds
	# would make splitting never worth it and four would make it free.
	preset.merge_delay_sec = 9.0
	preset.time_limit_sec = 300.0
	return preset


## A square with things in it, and the things are the mode.
##
## [b]Every world before this one was an empty box.[/b] Classic and Frenzy differ by a
## size, Gauntlet by an aspect ratio, and in all three the only thing between two monsters
## is distance — so being caught is a failure of speed, always, and the leader catches
## everybody eventually because the leader is not slow enough for it to matter.
##
## Warrens puts a ring of rocks around the middle with gates in it. [b]In this game your
## mass IS your radius[/b], so a gap is not the same obstacle for everybody: the gates are
## about a third of the winning mass wide, so the good middle of the map is open to the
## players who are behind and shut to the player who is ahead. That is a catch-up mechanic
## made out of geometry rather than out of a rule, and it is the first one here that no
## dial in this file could have produced.
##
## The leader is not locked out, and that is the other half. Half the mass is
## [code]1/sqrt(2)[/code] of the radius, so splitting fits — at the cost of
## [member merge_delay_sec], in the one part of the map where being in two halves is most
## dangerous. A pepper does the same thing to somebody else, against their will, which
## makes a throwable a way through a wall as well as a way into a fight.
static func warrens() -> HungryPreset:
	var preset := HungryPreset.new()
	preset.id = &"warrens"
	preset.display_name = "Warrens"
	preset.layout = HungryLayout.WARRENS

	# Between Classic and Frenzy. Small enough that the ring is most of the map rather
	# than an ornament in the middle of it, and big enough that the perimeter lane is a
	# route rather than a corridor.
	preset.world_size = Vector2(4200.0, 4200.0)

	# [b]Classic's food density over the floor that is actually left.[/b] The layout
	# covers about an eighth of the rectangle and the field is scattered over the whole of
	# it, so a target set against the rectangle would be an eighth of a mode's food buried
	# inside rocks. The world culls what lands in one — see `HungryWorld._cull_blocked` —
	# and this number is what is left standing.
	preset.food_target = 620

	# [b]Above Classic's density, unlike the food, and that is the mode rather than an
	# oversight.[/b] Warrens is full of people you cannot reach; a throwable is how you
	# deal with one, and a pepper that bursts somebody into halves small enough to fit
	# through a gate is both an attack and a door.
	preset.fruit_target = 14
	preset.item_target = 26

	# Reached through gates rather than across open ground, so it takes about as long as
	# Frenzy's despite the arena being twice the size.
	preset.win_mass = 1600.0
	preset.max_speed = 460.0

	# [b]The gate tax.[/b] Splitting to fit through the middle is the mode's signature
	# move, and the delay is what stops it being free: four seconds would make the ring
	# irrelevant and sixteen would make the middle unreachable for anybody who had grown
	# at all.
	preset.merge_delay_sec = 8.0
	preset.time_limit_sec = 360.0
	return preset


static func for_id(preset_id: StringName) -> HungryPreset:
	match preset_id:
		&"frenzy":
			return frenzy()
		&"gauntlet":
			return gauntlet()
		&"warrens":
			return warrens()
		_:
			return classic()


func validate() -> DotResult:
	if minf(world_size.x, world_size.y) < 400.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A world smaller than 400 units is smaller than a grown monster."
		)

	if win_mass <= HungryContent.START_MASS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A win mass of %.0f is at or below the starting mass, so the first player "
				% win_mass
			+ "to spawn has already won."
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"name": display_name,
		"world": world_size,
		"food": food_target,
		"win": win_mass,
		"speed": max_speed,
		"merge": merge_delay_sec,
		"layout": String(layout),
	}


func _to_string() -> String:
	return "HungryPreset(%s)" % id

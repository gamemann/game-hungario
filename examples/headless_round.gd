extends Node

const HungryBot := preload("../game/hungry_bot.gd")
const HungryConfig := preload("../game/hungry_config.gd")
const HungryContent := preload("../game/hungry_content.gd")
const HungryContentSource := preload("../game/client/hungry_content_source.gd")
const HungryEvents := preload("../game/net/hungry_events.gd")
const HungryField := preload("../game/hungry_field.gd")
const HungryHud := preload("../game/client/hungry_hud.gd")
const HungryInput := preload("../game/client/hungry_input.gd")
const HungryMenus := preload("../game/client/hungry_menus.gd")
const HungryMonster := preload("../game/hungry_monster.gd")
const HungryNetCommand := preload("../game/net/hungry_net_command.gd")
const HungryLayout := preload("../game/hungry_layout.gd")
const HungryPreset := preload("../game/hungry_preset.gd")
const HungryProjectile := preload("../game/hungry_projectile.gd")
const HungryRenderer := preload("../game/client/hungry_renderer.gd")
const HungryRider := preload("../game/client/hungry_rider.gd")
const HungrySound := preload("../game/client/hungry_sound.gd")
const HungryTouch := preload("../game/client/hungry_touch.gd")
const HungryWorld := preload("../game/hungry_world.gd")

## Plays whole rounds of the game with nobody watching, and checks that they work.
##
## [codeblock]
## godot --headless --path . res://examples/headless_round.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## [b]This is the file that finds the bugs.[/b] Everything here parses cleanly whether it
## is right or wrong: a monster that grows outside the wall, a field that hands out the
## same slot twice, a burst that quietly does nothing because the piece cap was already
## reached. None of those produce an error, and none of them are visible by reading the
## code. They are visible by running eight monsters for two minutes and measuring.

const SEED := 20260828
const TICK_RATE := 60

const CHECKS := 317

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

## Sections entered, and sections that ran to their last line.
##
## [b]A check count is not coverage.[/b] A runtime error inside a section — asking a dead
## monster where it is, indexing an array that emptied — aborts that function and nothing
## says so: the checks that already ran still print ok, the ones after it simply never
## happen, and the total at the bottom cannot reveal a check that never ran. Eight of them
## stopped running here for exactly that reason and the number went up, because other
## sections had been added in the same change.
##
## Every section increments the first on entry and the second on its last line, and
## [method _run] compares them. dot-net's demo carries the same pair for the same reason,
## reached from the other direction: there it was a suspending section called without
## `await`.
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-hungario: a round")
	print("")

	_test_setup()
	_test_food_tiers()
	_test_growing()
	_test_fruit()
	_test_items_and_throwing()
	_test_lure()
	_test_splitting()
	_test_merging()
	_test_devouring()
	_test_interest()
	_test_round_reset()
	_test_determinism()
	_test_full_round()
	_test_sound()
	_test_ejecting()
	_test_loadout()
	_test_rider()
	_test_interface()
	_test_the_gauntlet()
	_test_the_warrens()
	_test_the_slalom()
	_test_the_reef()
	_test_the_lagoon()
	_test_the_den()
	_test_the_reach()
	_test_food_on_the_floor()
	_test_spectating()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## Opens a section. Pair with [method _done] on the last line.
func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


## Closes a section. Anything that returns early has to call it before returning.
func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


# --- Fixtures --------------------------------------------------------------

## A world nobody else can see, so a test can do what it likes to it.
##
## `register_service` is off for every one of these: two worlds registered under the same
## name would displace each other, and several of these tests hold two at once.
func _make_world(preset: HungryPreset = null, world_seed: int = SEED) -> HungryWorld:
	var world := HungryWorld.new()
	world.name = "World"
	world.preset = preset if preset != null else HungryPreset.classic()
	world.tick_rate = TICK_RATE
	world.world_seed = world_seed
	world.register_service = false
	add_child(world)

	var ready_result := world.setup()

	if not ready_result.ok:
		push_error(str(ready_result.error))

	world.start(0)
	return world


func _drop(world: HungryWorld) -> void:
	if world != null and is_instance_valid(world):
		remove_child(world)
		world.free()


## Ticks a world, feeding every monster a fixed command.
func _run_ticks(world: HungryWorld, count: int, commands: Dictionary = {}) -> void:
	for _i in range(count):
		world.tick(commands)


## Ticks until the round is actually live.
##
## [b]Not optional, and the first thing every arrangement in this file learned.[/b] The
## transition into [constant DotMatch.State.LIVE] runs [method HungryWorld.reset_world] —
## that is what a new round [i]is[/i] — and it clears every piece, every carried item and
## every effect, then respawns everybody somewhere safe. A test that arranged the world
## before that happened had its arrangement thrown away, and the symptom was a monster
## standing a thousand units from where it was put, holding nothing.
##
## [b]And it has to be able to go live, which a world with nobody in it cannot.[/b]
## dot-match waits in warmup for its minimum head count, so a settle called before the
## first player is added runs out its five seconds and returns with the round still in
## warmup — and then the FIRST tick after somebody joins is the transition, which resets
## the world and respawns them wherever the safe spawn likes. Every level section here
## settled before adding its player, so every one of them arranged a monster in front of
## a rock or a gate, ticked twice, and drove whatever the reset had put somewhere else.
## The reef's "a starting monster comes out the far side of the tight channel" was
## measuring a monster respawned 900 units past it. A settle that gives up is a failure
## now, recorded without adding to the total so a passing run's count is unchanged.
func _settle(world: HungryWorld) -> void:
	# A client's round state arrives from the authority; its own match never advances,
	# and nothing it holds is reset by a transition it does not run.
	if not world.is_authority:
		return

	for _i in range(TICK_RATE * 5):
		if world.match_node.is_live():
			return

		world.tick({})

	if not world.match_node.is_live():
		_failed += 1
		_failures.append(
			"a world never went live, so anything arranged in it is thrown away at the "
			+ "first tick after a player joins (state %d, %d monsters)"
				% [world.match_node.state, world.monsters().size()]
		)
		print("  FAIL  a world never went live before its arrangement (%d monsters)"
			% world.monsters().size())


func _aim_at(from: Vector2, to: Vector2, buttons: int = 0) -> Dot2DCommand:
	var command := Dot2DCommand.new()
	var offset := to - from
	command.aim = offset.normalized() if offset.length_squared() > 0.000001 else Vector2.RIGHT
	command.reach = minf(offset.length(), HungryNetCommand.MAX_REACH)
	command.buttons = buttons
	return command


# --- Setup -----------------------------------------------------------------

func _test_setup() -> void:
	_section("setting up")

	var world := _make_world()

	_check(world.arena != null, "the arena exists")
	_check(
		world.field.food_count() == HungryContent.FOOD_TARGET,
		"the food field is full (%d)" % world.field.food_count()
	)
	_check(
		world.field.fruit_count() == HungryContent.FRUIT_TARGET,
		"and the fruit is out (%d)" % world.field.fruit_count()
	)
	_check(
		world.field.item_count() == HungryContent.ITEM_TARGET,
		"and the item drops (%d)" % world.field.item_count()
	)

	# Everything alive has to be in the grid, or it cannot be eaten and nothing says so.
	var indexed := 0

	for grid_id in world.field.alive_ids():
		if world.arena.grid.has(grid_id):
			indexed += 1

	_check(
		indexed == world.field.alive_count(),
		"every slot is indexed into the grid",
		"%d of %d" % [indexed, world.field.alive_count()]
	)

	var added := world.add_player(1, "Ada")
	_check(added.ok, "a player joins")

	world.spawn(1)
	var monster := world.monster_for(1)

	_check(monster != null and monster.alive, "and is in the world")
	# The starting mass is the constant *times the trait's*: a loadout that traded nothing
	# on the way in would be a choice with no consequence until much later.
	_check(
		monster != null and is_equal_approx(
			monster.mass(),
			HungryContent.START_MASS * HungryContent.trait_mass(monster.trait_id)
		),
		"at the starting mass their trait gives them (%.1f)"
			% (monster.mass() if monster != null else 0.0)
	)
	_check(
		monster != null and monster.carried.size() == 1
			and monster.carried[0] == monster.starter_item(),
		"holding the throwable their loadout chose (%s)"
			% (String(monster.starter_item()) if monster != null else "-")
	)
	_check(
		monster != null and monster.piece_count() == 1,
		"as a single piece"
	)
	_check(
		monster != null and monster.rider_piece() != null
			and monster.rider_piece().state.has_flag(HungryContent.FLAG_RIDER),
		"whose one piece carries the rider"
	)

	_drop(world)
	_done()


func _test_food_tiers() -> void:
	_section("food comes in sizes")

	var world := _make_world()
	var counts := [0, 0, 0, 0]

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) != HungryField.Kind.FOOD:
			continue

		counts[world.field.tier_of(grid_id)] += 1

	for tier in range(4):
		_check(
			counts[tier] > 0,
			"tier %d (%s) appears %d times" % [
				tier, HungryContent.FOOD_TIER_NAMES[tier], counts[tier]
			]
		)

	# The rarest tier must actually be rare, or "different sizes" is four names for the
	# same thing. The weights say 4%; anything over a tenth means the cutoffs are wrong.
	var total: int = counts[0] + counts[1] + counts[2] + counts[3]
	var rarest := float(counts[3]) / maxf(1.0, float(total))

	_check(
		rarest > 0.01 and rarest < 0.10,
		"haunches are rare (%.1f%%)" % (rarest * 100.0)
	)
	_check(
		counts[0] > counts[1] and counts[1] > counts[2] and counts[2] > counts[3],
		"and the tiers get rarer in order",
		str(counts)
	)

	# The size a client draws and the size the server eats at must be the same function
	# of the same slot, or a crumb is eaten from somewhere it is not drawn.
	var sample := world.field.alive_ids()[0]
	_check(
		is_equal_approx(
			world.field.radius_of(sample),
			HungryContent.FOOD_TIER_RADIUS[world.field.tier_of(sample)]
		),
		"radius and tier agree"
	)

	_drop(world)


# --- Growing ---------------------------------------------------------------
	_done()

func _test_growing() -> void:
	_section("growing")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)

	# Somewhere with food around it, rather than wherever the safe spawn picked.
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	var before := monster.mass()
	var eaten := [0]

	world.food_eaten.connect(func(_p: int, _g: int, _m: float) -> void:
		eaten[0] += 1
	)

	# Chase the nearest crumb for a few seconds. A monster that simply sat still would
	# prove nothing: the field has a margin and the centre may be empty.
	for _i in range(600):
		var head := monster.rider_piece()
		var target := _nearest_food(world, head.position())
		world.tick({1: _aim_at(head.position(), target)})

	_check(eaten[0] > 0, "a monster eats what it runs over (%d)" % eaten[0])
	_check(
		monster.mass() > before,
		"and gets bigger (%.0f -> %.0f)" % [before, monster.mass()]
	)
	_check(
		monster.food_eaten == eaten[0],
		"and the counter agrees with the signal"
	)

	# Radius must follow mass through the same function the eat check uses.
	var rules := world.tunables.mass_rules
	_check(
		is_equal_approx(
			monster.rider_piece().radius(), rules.radius_for(monster.rider_piece().mass())
		),
		"the radius follows the mass"
	)

	# Growing is a move. A monster pinned against a wall that eats gets wider, and only a
	# *moving* entity is clamped by the motor — this is the check that catches it.
	_check(_furthest_edge(world) <= 0.5, "nothing has grown through a wall")

	_drop(world)


## The distance the furthest monster edge sticks out past the arena, or zero.
	_done()
func _furthest_edge(world: HungryWorld) -> float:
	var bounds := world.arena.bounds
	var worst := 0.0

	for piece in world.pieces():
		var at := piece.position()
		var radius := piece.radius()

		worst = maxf(worst, bounds.position.x - (at.x - radius))
		worst = maxf(worst, bounds.position.y - (at.y - radius))
		worst = maxf(worst, (at.x + radius) - bounds.end.x)
		worst = maxf(worst, (at.y + radius) - bounds.end.y)

	return worst


func _nearest_food(world: HungryWorld, from: Vector2) -> Vector2:
	var best := from + Vector2.RIGHT * 100.0
	var best_distance := INF

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) == HungryField.Kind.ITEM:
			continue

		var at := world.field.position_of(grid_id)
		var distance := from.distance_squared_to(at)

		if distance < best_distance:
			best_distance = distance
			best = at

	return best


# --- Fruit -----------------------------------------------------------------

func _test_fruit() -> void:
	_section("fruit")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	var kinds := {}

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) == HungryField.Kind.FRUIT:
			kinds[world.field.fruit_kind_of(grid_id)] = true

	_check(kinds.size() >= 2, "several kinds of fruit are out (%d)" % kinds.size())

	# Put a known fruit under the monster rather than hunting one down: what is being
	# tested is the effect, not the pathfinding.
	var fruit_id := _first_of(world, HungryField.Kind.FRUIT)
	var kind := world.field.fruit_kind_of(fruit_id)
	var at := world.field.position_of(fruit_id)

	world.spawn(1, at)
	var before := monster.mass()
	world.tick({})

	_check(
		monster.mass() > before + HungryContent.FRUIT_MASS * 0.5,
		"eating one is worth a lot of mass (%.0f -> %.0f)" % [before, monster.mass()]
	)

	var flag: int = [
		HungryContent.FLAG_RUSH, HungryContent.FLAG_MAW, HungryContent.FLAG_RIND
	][int(kind)]

	_check(
		monster.has_effect(flag, world.current_tick()),
		"and applies its effect (%s)" % HungryContent.FRUIT_NAMES[int(kind)]
	)
	_check(
		(monster.rider_piece().state.flags & flag) != 0,
		"which is on the piece's flags, so a client can draw it"
	)

	if kind == HungryContent.Fruit.RUSH:
		_check(
			monster.speed_multiplier(world.current_tick())
				> HungryContent.RUSH_SPEED_MULTIPLIER - 0.01,
			"and rush makes them faster"
		)

	# Effects are counted in ticks and must actually run out. An effect that never
	# expired would be invisible for eight seconds and permanent afterwards.
	_run_ticks(world, int(HungryContent.FRUIT_EFFECT_SEC * TICK_RATE) + 2)
	_check(
		not monster.has_effect(flag, world.current_tick()),
		"and it expires on time"
	)
	_check(
		is_equal_approx(
			monster.speed_multiplier(world.current_tick()),
			HungryContent.trait_speed(monster.trait_id)
		),
		"leaving the monster at whatever its trait gives it (%.2f)"
			% monster.speed_multiplier(world.current_tick())
	)

	_drop(world)
	_done()


func _first_of(world: HungryWorld, kind: HungryField.Kind) -> int:
	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) == kind:
			return grid_id

	return 0


# --- Items -----------------------------------------------------------------

func _test_items_and_throwing() -> void:
	_section("throwables")

	var world := _make_world()
	world.add_player(1, "Ada")
	world.add_player(2, "Bo")
	_settle(world)

	var thrower := world.monster_for(1)
	var victim := world.monster_for(2)

	var drop := _first_of(world, HungryField.Kind.ITEM)
	world.spawn(1, world.field.position_of(drop))

	# One already, from the loadout. What is being checked is that running over a drop
	# adds to it.
	var held := thrower.carried.size()
	world.tick({})

	_check(
		thrower.carried.size() == held + 1,
		"running over a drop picks it up (%d -> %d)" % [held, thrower.carried.size()]
	)

	# The cap has to refuse rather than swallow. An item that vanished because you were
	# full reads as a bug every single time.
	thrower.carried.clear()

	for _i in range(HungryContent.MAX_CARRIED):
		thrower.take_item(HungryContent.ITEM_PEPPER)

	var another := _first_of(world, HungryField.Kind.ITEM)
	var still_there := world.field.take(another)
	_check(still_there, "a full monster leaves the drop where it is")

	# Now the pepper. A victim large enough to be worth bursting, right in front.
	world.spawn(1, Vector2(-300.0, 0.0))
	world.spawn(2, Vector2(100.0, 0.0))

	# Spawn protection stops a thrown pepper too, and that rule has its own check in
	# `_test_devouring`. Cleared here rather than waited out, so that four seconds of
	# ticks do not move either of them somewhere else first.
	thrower.clear_effect(HungryContent.FLAG_PROTECTED)
	victim.clear_effect(HungryContent.FLAG_PROTECTED)

	thrower.carried.clear()
	thrower.take_item(HungryContent.ITEM_PEPPER)
	thrower.throw_ready_tick = world.current_tick()

	var grown := victim.rider_piece()
	grown.set_mass(HungryContent.MIN_BURST_MASS * 3.0, world.tunables.mass_rules)

	var pieces_before := victim.piece_count()
	var burst_seen := [0]
	world.monster_burst.connect(func(_p: int, _b: int, count: int) -> void:
		burst_seen[0] += count
	)

	var throw_command := _aim_at(
		thrower.rider_piece().position(),
		victim.rider_piece().position(),
		Dot2DCommand.BUTTON_ACTION
	)
	# Held still, so the two do not drift into each other while the pepper is in flight.
	var hold := Dot2DCommand.new()

	world.tick({1: throw_command, 2: hold})
	_check(world.projectiles().size() == 1, "throwing puts a pepper in flight")
	_check(thrower.carried.is_empty(), "and spends the charge")

	for _i in range(90):
		world.tick({1: hold, 2: hold})

		if victim.piece_count() > pieces_before:
			break

	_check(
		victim.piece_count() > pieces_before,
		"the pepper bursts them (%d -> %d pieces)" % [
			pieces_before, victim.piece_count()
		]
	)
	_check(burst_seen[0] > 0, "and says so")
	_check(world.projectiles().is_empty(), "and the pepper is gone")

	# You still control the pieces, and they still all belong to you.
	var mine := true

	for piece in victim.pieces:
		mine = mine and piece.owner_id == victim.id

	_check(mine, "and every piece is still theirs")

	# A burst piece cannot re-merge immediately, or a burst heals itself instantly and
	# is not a threat at all.
	var delayed := true

	for piece in victim.pieces:
		delayed = delayed and not piece.can_merge(world.current_tick())

	_check(delayed, "and none of them may merge yet")

	# The rind fruit eats a burst outright. Not "reduces": a fruit whose effect is
	# invisible is a fruit nobody picks up on purpose.
	victim.apply_effect(
		HungryContent.FLAG_RIND, world.current_tick() + TICK_RATE * 10
	)
	var protected_before := victim.piece_count()
	var made := world.burst(victim, 1)

	_check(made == 0, "a rind absorbs a burst entirely")
	_check(
		victim.piece_count() == protected_before,
		"leaving the monster whole"
	)
	_check(
		not victim.has_effect(HungryContent.FLAG_RIND, world.current_tick()),
		"and is spent doing it"
	)

	# Frost.
	thrower.carried.clear()
	thrower.take_item(HungryContent.ITEM_FROST)
	var frost_command := _aim_at(
		thrower.rider_piece().position(),
		victim.rider_piece().position(),
		Dot2DCommand.BUTTON_ACTION
	)
	thrower.throw_ready_tick = world.current_tick()
	world.tick({1: frost_command, 2: hold})

	for _i in range(90):
		world.tick({1: hold, 2: hold})

		if victim.has_effect(HungryContent.FLAG_FROSTED, world.current_tick()):
			break

	_check(
		victim.has_effect(HungryContent.FLAG_FROSTED, world.current_tick()),
		"a frostberry slows its target"
	)
	_check(
		victim.speed_multiplier(world.current_tick()) < 1.0,
		"which is a real speed change (%.2f)"
			% victim.speed_multiplier(world.current_tick())
	)

	_drop(world)
	_done()


func _test_lure() -> void:
	_section("the lure")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2(-800.0, 0.0))

	var monster := world.monster_for(1)
	# After the spawn, because a spawn hands out the loadout's charge and clears whatever
	# was there.
	monster.carried.clear()
	monster.take_item(HungryContent.ITEM_LURE)
	monster.throw_ready_tick = world.current_tick()

	var planted_before := world.field.planted_count()
	var head := monster.rider_piece()

	world.tick({
		1: _aim_at(
			head.position(),
			head.position() + Vector2.RIGHT * 400.0,
			Dot2DCommand.BUTTON_ACTION
		)
	})

	var hold := Dot2DCommand.new()

	for _i in range(180):
		world.tick({1: hold})

		if world.field.planted_count() > planted_before:
			break

	_check(
		world.field.planted_count() >= HungryContent.LURE_FOOD_COUNT,
		"a lure plants a ring of food (%d)" % world.field.planted_count()
	)

	# Planted food is the one kind whose position is *sent* rather than derived, so it
	# has to be in the grid at the position the field reports.
	var mismatched := 0
	var planted_ids: Array[int] = []

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) != HungryField.Kind.PLANTED:
			continue

		planted_ids.append(grid_id)

		if not world.arena.grid.has(grid_id) \
				or world.arena.grid.position_of(grid_id).distance_to(
					world.field.position_of(grid_id)
				) > 0.01:
			mismatched += 1

	_check(mismatched == 0, "and every crumb of it is in the grid where it says")

	var rows := world.field.planted_rows(planted_ids)
	_check(
		rows.size() == planted_ids.size(),
		"and each one has a position to send"
	)

	# Inside the world, including near a wall. A ring clamped badly is food nobody can
	# reach.
	var outside := 0

	for grid_id in planted_ids:
		if not world.arena.bounds.has_point(world.field.position_of(grid_id)):
			outside += 1

	_check(outside == 0, "and none of it is outside the arena")

	_drop(world)


# --- Splitting and merging -------------------------------------------------
	_done()

func _test_splitting() -> void:
	_section("splitting")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	monster.rider_piece().set_mass(400.0, world.tunables.mass_rules)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)

	var mass_before := monster.mass()
	var split := _aim_at(Vector2.ZERO, Vector2.RIGHT * 500.0, Dot2DCommand.BUTTON_SPLIT)
	var release := _aim_at(Vector2.ZERO, Vector2.RIGHT * 500.0)

	world.tick({1: split})

	_check(monster.piece_count() == 2, "a split makes two pieces")
	# Not exactly: a monster this wide covers a lot of ground and eats whatever it is
	# sitting on during the same tick. What a split must not do is lose mass.
	_check(
		monster.mass() >= mass_before * 0.98,
		"and conserves mass (%.1f -> %.1f)" % [mass_before, monster.mass()]
	)

	var halves := monster.pieces
	_check(
		absf(halves[0].mass() - halves[1].mass()) < mass_before * 0.15,
		"into two roughly equal halves (%.0f and %.0f)"
			% [halves[0].mass(), halves[1].mass()]
	)

	# Both halves, not just the new one. A parent that could re-absorb its child at once
	# makes splitting free, and splitting is supposed to be a risk.
	var both_delayed := true

	for piece in monster.pieces:
		both_delayed = both_delayed and not piece.can_merge(world.current_tick())

	_check(both_delayed, "and both halves have to wait to merge")

	# Held down, a split must not fire every tick. Without a cooldown the piece cap is
	# reached in a fifth of a second, which is a stutter rather than a decision.
	var after_one := monster.piece_count()
	world.tick({1: split})
	_check(
		monster.piece_count() == after_one,
		"a held key does not split again (edge-triggered)"
	)

	# Released and pressed again, but still inside the cooldown.
	world.tick({1: release})
	world.tick({1: split})
	_check(
		monster.piece_count() == after_one,
		"and the cooldown holds even after a release"
	)

	# Past the cooldown it works again.
	for _i in range(HungryContent.SPLIT_COOLDOWN_TICKS + 2):
		world.tick({1: release})

	world.tick({1: split})
	_check(monster.piece_count() > after_one, "and works again once it has passed")

	# The cap. Splitting repeatedly must stop at max_pieces rather than growing for ever.
	for _i in range(40):
		for _j in range(HungryContent.SPLIT_COOLDOWN_TICKS + 1):
			world.tick({1: release})

		world.tick({1: split})

	_check(
		monster.piece_count() <= world.tunables.mass_rules.max_pieces,
		"the piece cap holds (%d of %d)" % [
			monster.piece_count(), world.tunables.mass_rules.max_pieces
		]
	)

	# Separation. Pieces that cannot merge must not sit inside each other, or a split
	# collapses back into a pile and stops meaning anything.
	var overlapping := 0

	for a in range(monster.pieces.size()):
		for b in range(a + 1, monster.pieces.size()):
			var first := monster.pieces[a]
			var second := monster.pieces[b]
			var gap := first.position().distance_to(second.position())

			if gap < (first.radius() + second.radius()) * 0.5:
				overlapping += 1

	_check(overlapping == 0, "and the pieces push apart (%d piles)" % overlapping)
	_check(_furthest_edge(world) <= 0.5, "and stay inside the world")

	_drop(world)
	_done()


func _test_merging() -> void:
	_section("merging back")

	# A preset with a short delay, so this does not take sixteen seconds of ticks.
	var preset := HungryPreset.classic()
	preset.merge_delay_sec = 1.0

	var world := _make_world(preset)
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	monster.rider_piece().set_mass(600.0, world.tunables.mass_rules)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)

	var split := _aim_at(Vector2.ZERO, Vector2.RIGHT * 500.0, Dot2DCommand.BUTTON_SPLIT)
	var release := _aim_at(Vector2.ZERO, Vector2.RIGHT * 500.0)

	# Twice, with the cooldown in between, so there are three or four pieces rather than
	# two. Three in a pile is what the repeated pass in `_resolve_merges` exists for: a
	# single pass a tick merges two of them and leaves the third, which reads as a merge
	# that stutters.
	world.tick({1: split})

	for _i in range(HungryContent.SPLIT_COOLDOWN_TICKS + 2):
		world.tick({1: release})

	world.tick({1: split})

	var most := monster.piece_count()
	_check(most >= 3, "there are pieces to merge (%d)" % most)

	var mass_before := monster.mass()

	# Pull everything to one point: merging needs the delay *and* proximity.
	var gather := Dot2DCommand.new()

	for _i in range(TICK_RATE * 6):
		world.tick({1: gather})

		if monster.piece_count() == 1:
			break

	_check(
		monster.piece_count() == 1,
		"they come back together (%d -> %d)" % [most, monster.piece_count()]
	)
	_check(
		monster.mass() > mass_before * 0.9,
		"keeping the mass (%.0f -> %.0f)" % [mass_before, monster.mass()]
	)

	# Three pieces in a pile merge two at a time, so a single pass a tick would leave the
	# third behind and look like a merge that stutters. The loop in `_resolve_merges` is
	# what this checks — it only shows up above two pieces.
	_check(most > 2, "and this ran with more than two pieces (%d)" % most)

	_drop(world)


# --- Eating each other -----------------------------------------------------
	_done()

func _test_devouring() -> void:
	_section("eating each other")

	var world := _make_world()
	world.add_player(1, "Big")
	world.add_player(2, "Small")
	_settle(world)

	world.spawn(1, Vector2(0.0, 0.0))
	world.spawn(2, Vector2(40.0, 0.0))

	var big := world.monster_for(1)
	var small := world.monster_for(2)

	big.rider_piece().set_mass(500.0, world.tunables.mass_rules)

	# Spawn protection first: this is a rule, and a test that cleared it would never
	# notice if it stopped working.
	var eaten := [0]
	world.piece_eaten.connect(func(_e: int, _v: int, _m: float) -> void:
		eaten[0] += 1
	)

	world.tick({})
	_check(eaten[0] == 0, "spawn protection stops an instant kill")

	# Cleared rather than waited out. Four seconds of ticks with a 500-mass monster forty
	# units from a 22-mass one is four seconds in which the kill happens on its own — and
	# then the chase below starts by asking a dead monster where it is, which is a runtime
	# error that aborts the rest of this function while every check that already ran still
	# says ok. That is how eight checks stopped running without the count going down.
	big.clear_effect(HungryContent.FLAG_PROTECTED)
	small.clear_effect(HungryContent.FLAG_PROTECTED)

	var deaths := [0]
	world.player_died.connect(func(_p: int, _k: int) -> void: deaths[0] += 1)

	var stand := Dot2DCommand.new()
	var chase := _aim_at(
		big.rider_piece().position(), small.rider_piece().position()
	)

	for _i in range(180):
		world.tick({1: chase, 2: stand})

		if not small.alive:
			break

		var hunter := big.rider_piece()
		var prey := small.rider_piece()

		if hunter == null or prey == null:
			break

		chase = _aim_at(hunter.position(), prey.position())

	_check(not small.alive, "a bigger monster devours a smaller one")
	_check(deaths[0] == 1, "and it is reported once")
	_check(big.players_eaten == 1, "and counted")
	_check(
		big.mass() > 500.0,
		"and the eater keeps the mass (%.0f)" % big.mass()
	)
	_check(
		world.match_node.scoreboard.find("1").kills == 1,
		"and dot-match recorded the kill"
	)

	# Respawning is dot-match's, driven from a tick count rather than a timer.
	for _i in range(int(TICK_RATE * 5)):
		world.tick({})

		if small.alive:
			break

	_check(small.alive, "and the victim comes back")
	_check(
		is_equal_approx(
			small.mass(),
			HungryContent.START_MASS * HungryContent.trait_mass(small.trait_id)
		),
		"at the starting mass their trait gives them again (%.1f)" % small.mass()
	)

	# Two monsters of equal size must never eat each other, whichever is resolved first.
	# That is what an eat ratio above 1 is for, and it is the difference between a rule
	# and a coin flip.
	world.spawn(1, Vector2(0.0, 500.0))
	world.spawn(2, Vector2(10.0, 500.0))
	big.rider_piece().set_mass(200.0, world.tunables.mass_rules)
	small.rider_piece().set_mass(200.0, world.tunables.mass_rules)
	big.clear_effect(HungryContent.FLAG_PROTECTED)
	small.clear_effect(HungryContent.FLAG_PROTECTED)

	_run_ticks(world, 30)
	_check(
		big.alive and small.alive,
		"two equal monsters cannot eat each other"
	)

	_drop(world)


# --- Interest --------------------------------------------------------------
	_done()

## Where a dead monster's owner looks.
func _test_spectating() -> void:
	_section("spectating")

	var world := _make_world()
	world.add_player(1, "Eaten")
	world.add_player(2, "Eater")
	_settle(world)

	world.spawn(1, Vector2(0.0, 0.0))
	world.spawn(2, Vector2(300.0, 0.0))

	if not _check(world.spectate != null, "the world builds a spectate layer"):
		_done()
		return

	var rules := world.spectate.manager.rules
	_check(rules.force_camera == 0, "a free-for-all restricts the camera to nobody")
	_check(
		not rules.allow_while_alive,
		"and a LIVING player may not watch: knowing where the biggest monster is "
		+ "standing is the whole skill of this game"
	)
	_check(
		not rules.allow_roaming,
		"nor roam, because a free camera over a 2D arena is the entire map"
	)

	_check(
		not world.spectate.is_spectating(1),
		"a living player is not watching anything"
	)

	# Killing them the way the world does it.
	var monster := world.monster_for(1)
	monster.alive = false
	world.player_died.emit(1, 2)

	_check(world.spectate.is_spectating(1), "a dead one is")

	# The death camera first, then a real target — the hand-over every game that writes
	# this itself gets wrong.
	_run_ticks(world, world.tick_rate * 3)

	_check(
		world.spectate.watching(1) == 2,
		"and ends up watching the player who is still alive",
		str(world.spectate.watching(1))
	)

	var where: Variant = world.spectate.camera_position(1)
	_check(where != null, "with a camera position rather than null")

	if where is Vector2:
		var target := world.monster_for(2)
		_check(
			(where as Vector2).distance_to(target.centre()) < 1.0,
			"which is where that player's monster actually is, on the XZ plane the "
			+ "whole family maps 2D onto",
			"%v against %v" % [where as Vector2, target.centre()]
		)

	# And coming back stops it.
	world.spawn(1, Vector2(0.0, 0.0))
	_check(
		not world.spectate.is_spectating(1),
		"and respawning puts them back in their own view"
	)

	_done()


func _test_interest() -> void:
	_section("what a client is told")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	var everything := world.field.alive_count() + world.piece_count()
	var seen := world.interest_for(1)

	_check(
		seen.size() < everything,
		"a player is not told about the whole world (%d of %d)" % [
			seen.size(), everything
		]
	)

	# The cap must bound *everything*, not only the food. Sixteen players at the piece
	# limit is two hundred and fifty-six pieces, and a cap that exempted them would not
	# be a cap.
	for id in range(2, 18):
		world.add_player(id, "Crowd %d" % id)
		world.spawn(id, Vector2(float(id) * 12.0, 0.0))

	world.tick({})
	var capped := world.interest_for(1, 6)
	_check(capped.size() <= 6, "the cap holds (%d)" % capped.size())

	var pieces_first := 0

	for grid_id in capped:
		if grid_id < HungryField.PIECE_ID_LIMIT:
			pieces_first += 1

	_check(
		pieces_first == capped.size(),
		"and pieces come before food when it bites (%d of %d)" % [
			pieces_first, capped.size()
		]
	)

	# A bigger monster fills more screen and must see further, or it cannot see anything
	# it might eat.
	var small_view := world.interest_for(1).size()
	monster.rider_piece().set_mass(4000.0, world.tunables.mass_rules)
	world.tick({})
	var big_view := world.interest_for(1).size()

	_check(
		big_view > small_view,
		"a huge monster sees further (%d -> %d)" % [small_view, big_view]
	)

	_drop(world)


# --- Rounds ----------------------------------------------------------------
	_done()

func _test_round_reset() -> void:
	_section("a new round")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var before_ids := world.field.alive_ids()
	world.reset_world()
	var after_ids := world.field.alive_ids()

	# Slot indices are never reused, so the new field's grid ids sit *beside* the old
	# field's. If the old ones are not removed, the grid ends up holding twice as much
	# food as exists — half of it phantoms at stale positions that `take()` refuses —
	# and eating quietly stops working. This is game-blob's bug, three fields wide.
	var overlap := 0
	var after_set := {}

	for grid_id in after_ids:
		after_set[grid_id] = true

	for grid_id in before_ids:
		if after_set.has(grid_id):
			overlap += 1

	_check(overlap == 0, "the new field reuses no slot from the old one")
	_check(
		world.arena.grid.size() == after_ids.size() + world.piece_count(),
		"and the grid holds exactly the new field",
		"grid %d, field %d, pieces %d" % [
			world.arena.grid.size(), after_ids.size(), world.piece_count()
		]
	)

	# Every id in the grid must be takeable. A phantom is an id the grid has and the
	# field does not, and its only symptom is food that cannot be eaten.
	var phantoms := 0

	for grid_id in world.arena.grid.ids():
		if grid_id < HungryField.PIECE_ID_LIMIT:
			continue

		if not after_set.has(grid_id):
			phantoms += 1

	_check(phantoms == 0, "and there are no phantoms (%d)" % phantoms)

	_drop(world)
	_done()


## The Gauntlet: a five-to-one corridor, and the first non-square world this game runs.
##
## [b]The mode is the point and the shape is the reason it is worth a section.[/b] Classic
## and Frenzy are the same square at two sizes, so every place that reads `world_size.x`
## where it meant `.y` — or derives one bound from one component — gives the right answer
## and is invisible. A corridor is where the two components disagree, so it is the only
## arrangement in which those are findable at all.
##
## Every check below would pass on a square world whether or not the code were right.
func _test_the_gauntlet() -> void:
	_section("the gauntlet")

	var preset := HungryPreset.gauntlet()

	if not _check(preset.validate().ok, "the preset is usable"):
		_done()
		return

	_check(
		preset.world_size.x > preset.world_size.y * 4.0,
		"and it is a corridor rather than a square",
		"%.0f by %.0f" % [preset.world_size.x, preset.world_size.y]
	)

	# The same area as Frenzy's square, so the mode is the SHAPE and not the density. A
	# corridor with the same food count in a quarter of the floor would be a starvation
	# mode as well, and there would be no telling which half was doing the work.
	var frenzy := HungryPreset.frenzy()
	var area := preset.world_size.x * preset.world_size.y
	var square := frenzy.world_size.x * frenzy.world_size.y

	_check(
		absf(area / square - 1.0) < 0.02,
		"with the same floor area as Frenzy",
		"%.0f against %.0f" % [area, square]
	)
	# [b]The same food per unit of WALKABLE floor, which stopped being the same number
	# as the target the day this mode got a level.[/b] Five slalom rocks stand on about
	# an eighth of the corridor. Whatever the scatter puts inside one is culled and the
	# field then REFILLS to its target on open floor, so the target is the food standing
	# on the floor and the density is the target over the floor that is left.
	#
	# [b]This line used to multiply by the floor instead of dividing by it[/b] — the
	# arithmetic of a cull that is a permanent loss, which it is not — and the preset
	# had been tuned to the same backwards arithmetic, so the two agreed about a corridor
	# 27% richer than the square. "food on the floor that is left" measures the living
	# field now, which is the check that caught it; this one is the arithmetic, kept
	# because a preset argued in a comment should be checked in the same terms.
	var covered := HungryLayout.for_id(
		preset.layout, Rect2(Vector2.ZERO, preset.world_size)
	).covered_area()
	var density := float(preset.food_target) / (area - covered)
	var frenzy_density := float(frenzy.food_target) / square

	_check(
		absf(density / frenzy_density - 1.0) < 0.03,
		"and the same amount of food on the floor that is left",
		"%.1f per million units against %.1f, with %.0f%% of it under rock"
			% [density * 1.0e6, frenzy_density * 1.0e6, covered / area * 100.0]
	)

	var world := _make_world(preset, SEED + 31)
	world.add_player(1, "Ada")
	_settle(world)

	var bounds := world.arena.bounds

	_check(
		absf(bounds.size.x - preset.world_size.x) < 0.5
			and absf(bounds.size.y - preset.world_size.y) < 0.5,
		"the arena is the shape the preset asked for",
		"%s" % str(bounds.size)
	)

	world.spawn(1, bounds.get_center())
	_settle(world)

	var monster := world.monster_for(1)

	if not _check(monster != null and monster.alive, "a monster spawns in it"):
		_drop(world)
		_done()
		return

	# Walked into all four walls in turn, and it is the pair on the SHORT axis that a
	# square world can never test: a clamp using the wrong component would let a monster
	# out of the top and bottom of a corridor while the left and right looked perfect.
	var corners := {
		"east": Vector2(bounds.end.x + 4000.0, bounds.get_center().y),
		"west": Vector2(bounds.position.x - 4000.0, bounds.get_center().y),
		"north": Vector2(bounds.get_center().x, bounds.position.y - 4000.0),
		"south": Vector2(bounds.get_center().x, bounds.end.y + 4000.0),
	}

	for side in corners:
		var target: Vector2 = corners[side]

		for _i in range(TICK_RATE * 6):
			world.tick({1: _aim_at(monster.centre(), target)})

		var here := monster.centre()
		var out := (
			here.x < bounds.position.x - 1.0
			or here.x > bounds.end.x + 1.0
			or here.y < bounds.position.y - 1.0
			or here.y > bounds.end.y + 1.0
		)

		_check(not out, "and cannot walk out of the %s wall" % side, "at %s" % str(here))

	# It reached the far end. A corridor whose length nothing can cross is a corridor
	# nobody meets anybody in, and the run above is the only thing that would say so.
	#
	# [b]Sixty seconds, not twenty, and twenty only ever passed by accident.[/b] A starting
	# monster moves about 130 units a second and this one starts at the west wall with
	# five rocks to slide round. The old budget passed because the section settled before
	# anybody had joined, the round went live on the first tick after, and the reset put
	# the monster wherever the safe spawn liked — usually most of the way there already.
	for _i in range(TICK_RATE * 60):
		world.tick({1: _aim_at(monster.centre(), corners["east"])})

	_check(
		monster.centre().x > bounds.get_center().x + bounds.size.x * 0.3,
		"and can cross the length of it",
		"%.0f of %.0f" % [monster.centre().x - bounds.position.x, bounds.size.x]
	)

	# The food is spread over the whole corridor rather than bunched into the square the
	# generator would produce if it hashed into one component. Measured as the span of
	# what actually exists, because the count is right either way.
	var spread_x := 0.0
	var spread_y := 0.0
	var lowest := Vector2(INF, INF)
	var highest := Vector2(-INF, -INF)

	for grid_id in world.field.alive_ids():
		var at := world.field.position_of(grid_id)
		lowest = lowest.min(at)
		highest = highest.max(at)

	spread_x = highest.x - lowest.x
	spread_y = highest.y - lowest.y

	_check(
		spread_x > bounds.size.x * 0.8 and spread_y > bounds.size.y * 0.8,
		"and the food is spread over the whole of it",
		"%.0f by %.0f in a %.0f by %.0f room"
			% [spread_x, spread_y, bounds.size.x, bounds.size.y]
	)

	_drop(world)
	_done()


## The corridor's own level, and the question the warrens section could not ask.
##
## [b]A gate is a gap between two things, and until now both of them were rocks.[/b] The
## warrens is a ring, so every gate in it is rock-to-rock and `narrowest_gap` is the whole
## answer. A slalom rock stands off one wall of a corridor: its narrow lane is against
## that wall and its wide one against the other, and neither is a gap between two rocks at
## all. Asked the old question the slalom answers 646 units — two rocks a thousand apart —
## which is not a gate, is not the level, and would have passed every threshold a reviewer
## would think to write.
func _test_the_slalom() -> void:
	_section("the slalom")

	var preset := HungryPreset.gauntlet()

	if not _check(preset.validate().ok, "the corridor preset is usable"):
		_done()
		return

	_check(
		preset.layout == HungryLayout.SLALOM,
		"and the corridor is not an empty box any more",
		"layout %s" % String(preset.layout)
	)

	var world := _make_world(preset, SEED + 83)
	world.add_player(1, "Bram")
	_settle(world)

	var bounds := world.arena.bounds
	var layout := world.layout

	if not _check(
		layout != null and layout.count() == HungryLayout.SLALOM_COUNT,
		"five rocks stand down it (%d)" % (layout.count() if layout != null else -1)
	):
		_drop(world)
		_done()
		return

	# Derived, like the warrens: the same id and the same rectangle, twice.
	var again := HungryLayout.for_id(HungryLayout.SLALOM, bounds)
	var identical := again.count() == layout.count()

	for index in range(mini(again.count(), layout.count())):
		if not again.blocks[index].is_equal_approx(layout.blocks[index]):
			identical = false

	_check(identical, "and a second build of the same layout is the same rocks")

	var inside := true

	for block in layout.blocks:
		if not bounds.grow(-block.z).has_point(Vector2(block.x, block.y)):
			inside = false

	_check(inside, "and every one of them is wholly inside the corridor")

	# [b]They alternate, which is the whole of what makes the shortcut a decision.[/b]
	# Five rocks on the same side of the centre line is a wall with a corridor beside it,
	# and it is one constant's sign away at all times.
	var alternates := true
	var centre_across := bounds.get_center().y

	for index in range(layout.count() - 1):
		var here := layout.blocks[index].y - centre_across
		var next := layout.blocks[index + 1].y - centre_across

		if here * next >= 0.0:
			alternates = false

	_check(
		alternates,
		"and they alternate sides, so the inside line changes wall at every rock"
	)

	# --- The two lanes, which are the level ---------------------------------

	var rules := world.tunables.mass_rules
	var gate := layout.narrowest_gate(bounds)
	var fits := layout.fits_through_gate(bounds)
	var admits := fits * fits / (rules.base_radius * rules.base_radius)

	_check(
		gate < layout.narrowest_gap(),
		"the narrowest way past a rock is against a WALL, not against another rock",
		"%.0f against a wall, %.0f between two rocks" % [gate, layout.narrowest_gap()]
	)
	_check(
		admits > preset.win_mass * 0.2 and admits < preset.win_mass * 0.45,
		"the inside lane admits a monster of about a third of the winning mass",
		"%.0f of %.0f, through a %.0f unit lane" % [admits, preset.win_mass, gate]
	)
	_check(
		rules.radius_for(preset.win_mass) > fits,
		"so a monster that has won has to take the long way round every rock",
		"%.0f against %.0f" % [rules.radius_for(preset.win_mass), fits]
	)

	# [b]And the long way round is open to it, which the ring did not have to prove.[/b]
	# A ring is escapable by construction — the middle is the part you are shut out of. A
	# corridor is not: a rock whose wide lane is also too narrow is a cork, and the mode
	# ends with the leader parked against it. This is the check that says the slalom is a
	# level rather than a cage.
	var widest := world.layout.widest_way_past(bounds)
	_check(
		widest * 0.5 > rules.radius_for(preset.win_mass),
		"and the way round is open even to one that has already won",
		"%.0f unit lane against a radius of %.0f"
			% [widest, rules.radius_for(preset.win_mass)]
	)

	# --- A rock stops somebody ----------------------------------------------

	var rock: Vector3 = layout.blocks[0]
	var rock_at := Vector2(rock.x, rock.y)
	# Up the corridor from the first rock, on its own line, driving straight at it.
	world.spawn(1, Vector2(rock_at.x - rock.z * 3.0, rock_at.y))
	_run_ticks(world, 2)

	var monster := world.monster_for(1)

	if not _check(monster != null and monster.alive, "a monster spawns up the corridor"):
		_drop(world)
		_done()
		return

	# [b]Aimed, not moved.[/b] This drive used to set `command.move` and nothing else, and
	# this game steers by `aim` and `reach` — `move` is carried through to the motor and
	# ignored by it. The monster never moved; the section settled before the player
	# joined, the first tick after reset the round and respawned it, and "it gets past
	# the rock" was measuring where the respawn had put it.
	#
	# Two legs, because driven for real a pointer held on a line through a disc's centre
	# holds the monster against that disc's face for ever — the push-out takes the normal
	# component and there is no tangent left to slide on. So: four seconds straight at
	# the rock, which is the push-out's test, and then the pointer moves to the middle of
	# the far lane beyond it, which is what a player going past does.
	var piece_radius := monster.pieces[0].radius()
	var entered := false
	var lane_side := -signf(rock_at.y - bounds.get_center().y)
	var wall := bounds.position.y if lane_side < 0.0 else bounds.end.y
	var lane_mid := (rock_at.y + lane_side * rock.z + wall) * 0.5
	var legs := [
		[Vector2(rock_at.x + 4000.0, rock_at.y), TICK_RATE * 4],
		[Vector2(rock_at.x + rock.z * 3.0, lane_mid), TICK_RATE * 12],
	]

	for leg in legs:
		for _tick in range(int(leg[1])):
			_run_ticks(world, 1, {1: _full_reach(monster.centre(), leg[0])})

			if monster.alive and monster.pieces[0].state.position.distance_to(rock_at) \
					< rock.z + piece_radius - 1.0:
				entered = true

	_check(not entered, "and driving straight at a rock never puts it inside one")

	# Round it, rather than through it. The far side, reached at all, is the level
	# working: a walker that only ever gets pushed back is a wall, and the whole design
	# is that a rock is something you go past.
	_check(
		monster.alive and monster.pieces[0].state.position.x > rock_at.x + rock.z,
		"and it gets past the rock rather than stopping at it (%.0f past %.0f)"
			% [monster.pieces[0].state.position.x, rock_at.x + rock.z]
	)

	_drop(world)
	_done()


func _test_the_warrens() -> void:
	_section("the warrens")

	var preset := HungryPreset.warrens()

	if not _check(preset.validate().ok, "the preset is usable"):
		_done()
		return

	_check(
		preset.layout == HungryLayout.WARRENS,
		"and it is the first mode that asks for any geometry at all",
		"layout %s" % String(preset.layout)
	)
	_check(
		HungryPreset.classic().layout == HungryLayout.NONE
			and HungryPreset.frenzy().layout == HungryLayout.NONE,
		"and the two square modes are still empty boxes",
		"a layout nobody asked for would change every mode in the game"
	)

	var world := _make_world(preset, SEED + 57)
	world.add_player(1, "Ada")
	_settle(world)

	var bounds := world.arena.bounds
	var layout := world.layout

	# Eight ring, four corner and four den rocks. The den was added 2026-09-24 and appended
	# last, so blocks 0 and 1 below are still the ring's.
	if not _check(
		layout != null and layout.count() == HungryLayout.RING_COUNT + 4 + HungryLayout.DEN_COUNT,
		"sixteen rocks stand in it: the ring, the corners and the den",
		"%d" % (layout.count() if layout != null else -1)
	):
		_drop(world)
		_done()
		return

	# [b]Derived and not stored, which is what makes it free on the wire.[/b] The same id
	# and the same rectangle have to produce the same discs every time, because that is the
	# only reason a client can be told a name instead of a hundred and forty-four bytes of
	# circles.
	var again := HungryLayout.for_id(HungryLayout.WARRENS, bounds)
	var identical := again.count() == layout.count()

	for index in range(mini(again.count(), layout.count())):
		if not again.blocks[index].is_equal_approx(layout.blocks[index]):
			identical = false

	_check(identical, "and a second build of the same layout is the same rocks")

	# Everything is inside the arena. A rock half outside the wall is a rock a player is
	# pushed through the boundary by.
	var inside := true

	for block in layout.blocks:
		var at := Vector2(block.x, block.y)

		if not bounds.grow(-block.z).has_point(at):
			inside = false

	_check(inside, "and every one of them is wholly inside the arena")

	# --- The gate, which is the level ---------------------------------------

	# [b]The one number the design rests on.[/b] Mass IS radius here, so a gap is a mass
	# limit: `radius_for` inverted says who fits. The gates are meant to be open to a
	# player who is behind and shut to the player who is ahead, and a constant changed
	# without meaning to would quietly make the middle open to everybody or to nobody.
	var rules := world.tunables.mass_rules
	# [method HungryLayout.narrowest_gate] rather than `fits_through`, which measures rock
	# against rock alone. It is the same answer here — the corner rocks stand further off
	# the wall than the ring rocks stand from each other — and it is deliberately the same
	# call the slalom section makes, because a level whose gates are against a wall gets a
	# meaningless number out of the other one and nothing says so.
	#
	# [b]The RING's gate, since the den (2026-09-24).[/b] The narrowest gate on the map is
	# the den's now, a third of this one's mass limit; asked of the whole layout this check
	# would have been asserting the den was the warrens' ring. `ring_gates(0)` asks the
	# ring; the den has its own section.
	var fits: float = Array(layout.ring_gates(0)).min() * 0.5
	var admits := fits * fits / (rules.base_radius * rules.base_radius)

	_check(
		admits > preset.win_mass * 0.2 and admits < preset.win_mass * 0.45,
		"the gates admit a monster of about a third of the winning mass",
		"%.0f of %.0f, through a %.0f unit gap" % [admits, preset.win_mass, fits * 2.0]
	)
	_check(
		rules.radius_for(preset.win_mass) > fits,
		"so a monster that has won cannot fit through one",
		"%.0f against %.0f" % [rules.radius_for(preset.win_mass), fits]
	)
	# [b]And splitting is the way through, which is the mode.[/b] Half the mass is
	# 1/sqrt(2) of the radius, so a monster up to twice the gate limit can halve itself and
	# fit — at the cost of the merge delay, in the most dangerous part of the map.
	_check(
		rules.radius_for(admits * 1.9 * 0.5) < fits,
		"and one twice that size fits by splitting",
		"%.0f mass halves to a radius of %.0f"
			% [admits * 1.9, rules.radius_for(admits * 1.9 * 0.5)]
	)

	# --- A rock stops somebody ----------------------------------------------


	var ring: Vector3 = layout.blocks[0]
	var ring_at := Vector2(ring.x, ring.y)
	# Outside the ring, driving inward AT the rock — four degrees off its centre line,
	# which at this range is 80 units: well inside the rock's face, so the drive still
	# meets it, and not exactly on its centre, which no pointer ever is. Dead centre on a
	# disc is the one approach with no side to slide off to, and a monster held there
	# stops against the face for good; see the note on the slide below.
	var outside := bounds.get_center() \
		+ (ring_at - bounds.get_center()).rotated(deg_to_rad(4.0)) * 1.9

	world.spawn(1, outside)
	_run_ticks(world, 2)

	var monster := world.monster_for(1)

	if not _check(monster != null and monster.alive, "a monster spawns outside the ring"):
		_drop(world)
		_done()
		return

	var piece_radius := monster.pieces[0].radius()

	# [b]Sampled every tick, not read at the end.[/b] A push-out that let somebody through
	# for one frame and recovered is indistinguishable from one that never failed if the
	# only reading is the last one — and one frame inside a rock is one frame of eating
	# through a wall, which is the whole reason [HungryHazards] resolves before eating too.
	var deepest := INF

	for _i in range(TICK_RATE * 20):
		world.tick({1: _aim_at(monster.centre(), bounds.get_center())})
		deepest = minf(deepest, monster.centre().distance_to(ring_at))

	_check(
		deepest > ring.z - 2.0,
		"and driving straight at a rock never puts it inside one, on any tick",
		"closest approach %.0f to the middle of a %.0f rock" % [deepest, ring.z]
	)

	# [b]And it gets past anyway, which is the level working rather than failing.[/b] A
	# starting monster driven at a rock slides along its face, arrives at a gate and goes
	# through. That is what a ring with gates in it is FOR.
	#
	# [b]This check was rewritten once to match a monster that had been teleported.[/b]
	# The first version asserted the monster stayed outside the ring, failed, and was
	# turned round on the reading that the monster had slid in through a gate. It had not:
	# the section settled before the player joined, the round went live on the first tick
	# after, and the reset respawned the monster wherever the safe spawn liked. Driven for
	# real and dead on the rock's centre it stays against the face for ever — the first
	# version was right about that approach. Four degrees off, it slides in.
	_check(
		monster.centre().distance_to(bounds.get_center()) < ring_at.length() * 0.5,
		"but slides round the face of it and in through a gate",
		"%.0f from the centre, the ring is at %.0f"
			% [monster.centre().distance_to(bounds.get_center()), ring_at.length()]
	)

	# --- The same push on the prediction path -------------------------------

	# [b]The one thing a client does for itself.[/b] A client predicts by calling
	# `simulate_piece` and a reconciliation replays it, so a push-out that only the
	# authority's loop applied would make every tick spent against a rock a misprediction —
	# and the correction would ease the player back into the rock they are standing
	# against. It reads as packet loss, which sends the next person to the netcode.
	var predicted := _make_world(preset, SEED + 57)
	predicted.is_authority = false
	predicted.add_player(2, "Bo")
	_settle(predicted)
	predicted.spawn(2, ring_at)
	_run_ticks(predicted, 1)

	var mirror := predicted.monster_for(2)
	var mirror_piece := mirror.pieces[0] if mirror != null and not mirror.pieces.is_empty() \
		else null

	if mirror_piece != null:
		mirror_piece.state.position = ring_at
		predicted.simulate_piece(
			mirror_piece, mirror, _aim_at(ring_at, bounds.get_center()), 1.0 / TICK_RATE, 1
		)

	_check(
		mirror_piece != null
			and mirror_piece.position().distance_to(ring_at) >= ring.z - 1.0,
		"a client predicting itself is pushed out by the same rocks",
		"%.0f from the middle of a %.0f rock"
			% [mirror_piece.position().distance_to(ring_at) if mirror_piece != null else -1.0,
				ring.z]
	)

	# A client is TOLD which layout, and builds it. Nothing about the rocks travels.
	predicted.adopt_layout(HungryLayout.WARRENS)
	_check(
		predicted.layout.count() == layout.count()
			and predicted.layout.narrowest_gate(bounds) == layout.narrowest_gate(bounds),
		"and builds the same sixteen from one name in the hello"
	)

	_drop(predicted)

	# --- A small monster gets through, a big one does not -------------------

	# The gate between the first two ring rocks, on the bearing halfway between them.
	var second: Vector3 = layout.blocks[1]
	var gate := (ring_at + Vector2(second.x, second.y)) * 0.5
	var approach := bounds.get_center() + (gate - bounds.get_center()) * 1.75

	world.spawn(1, approach)
	_run_ticks(world, 2)

	for _i in range(TICK_RATE * 14):
		world.tick({1: _aim_at(monster.centre(), bounds.get_center())})

	var small_reach := monster.centre().distance_to(bounds.get_center())

	_check(
		small_reach < Vector2(ring_at - bounds.get_center()).length() * 0.8,
		"a starting monster fits through a gate and reaches the middle",
		"%.0f from the centre, the ring is at %.0f"
			% [small_reach, Vector2(ring_at - bounds.get_center()).length()]
	)

	# The same journey at the winning mass. Nothing else changes — same seed, same gate,
	# same commands — so the only thing that can make the second run end somewhere else is
	# the radius.
	world.spawn(1, approach)
	_run_ticks(world, 2)
	world.feed_player(1, preset.win_mass - monster.mass())
	_run_ticks(world, 2)

	var grown := monster.pieces[0].radius()

	for _i in range(TICK_RATE * 14):
		world.tick({1: _aim_at(monster.centre(), bounds.get_center())})

	var big_reach := monster.centre().distance_to(bounds.get_center())

	_check(
		grown > fits,
		"a monster at the winning mass is too wide for the gate",
		"a radius of %.0f against %.0f" % [grown, fits]
	)
	_check(
		big_reach > small_reach + 100.0,
		"and the same run leaves it outside the ring",
		"%.0f from the centre, where the small one got to %.0f"
			% [big_reach, small_reach]
	)

	# --- Nothing edible is buried -------------------------------------------

	# [b]A crumb inside a rock cannot be eaten and never expires.[/b] It holds its slot
	# against the field's budget for ever, so a mode with a layout would quietly run at
	# seven eighths of the food it claims with nothing anywhere saying so.
	var buried := 0

	for grid_id in world.field.alive_ids():
		if layout.blocked(world.field.position_of(grid_id), world.field.radius_of(grid_id)):
			buried += 1

	_check(buried == 0, "nothing edible is standing inside a rock", "%d buried" % buried)
	_check(
		world.field.alive_count() > preset.food_target,
		"and the field still fills to the target it asks for",
		"%d alive against a food target of %d"
			% [world.field.alive_count(), preset.food_target]
	)

	# --- And nobody spawns inside one ---------------------------------------

	var spawned_inside := 0

	for player in range(10, 30):
		world.add_player(player, "P%d" % player)
		world.spawn(player)

		var born := world.monster_for(player)

		if born != null and born.alive and layout.blocked(born.centre(), piece_radius):
			spawned_inside += 1

	_check(
		spawned_inside == 0,
		"and twenty spawns all land on floor rather than in a rock",
		"%d inside" % spawned_inside
	)

	_drop(world)
	_done()


## The reef: a barrier whose channels widen along it, driven through at two sizes.
##
## [b]The question this section asks that the other two levels cannot.[/b] Warrens and
## Slalom both have one gate width, so "can this monster get through" is a single number
## and every check over them is a comparison against it. The reef's channels are 248, 442,
## 635 and 828 units, so the interesting property is not whether a monster fits — it is
## *which* channels it fits, and therefore how far along the barrier it has to travel
## before it can cross. That is a list rather than a number, and it is what
## [method HungryLayout.channel_widths] exists to be asked for.
##
## [b]Driven rather than asserted, at both ends of the size range.[/b] Every level check
## in this file that only compares radii would pass over a barrier that had been built
## with its rocks in the wrong order, or overlapping, or with the whole chain outside the
## world: the arithmetic is the same either way. A small monster is driven at the tight
## channel and has to come out the far side; a monster at the winning mass is driven at
## the same channel and has to still be on the near side when the clock runs out.
func _test_the_reef() -> void:
	_section("the reef")

	var preset := HungryPreset.reef()

	if not _check(preset.validate().ok, "the reef preset is usable"):
		_done()
		return

	_check(
		preset.layout == HungryLayout.REEF,
		"and it is the third mode with geometry in it",
		"layout %s" % String(preset.layout)
	)

	var world := _make_world(preset, SEED + 131)
	world.add_player(1, "Ada")
	_settle(world)

	var bounds := world.arena.bounds
	var layout := world.layout

	if not _check(
		layout != null and layout.count() == HungryLayout.REEF_COUNT * 2
			and layout.chains.size() == 2,
		"ten rocks stand across it, in two barriers (%d)"
			% (layout.count() if layout != null else -1)
	):
		_drop(world)
		_done()
		return

	var again := HungryLayout.for_id(HungryLayout.REEF, bounds)
	var identical := again.count() == layout.count()

	for index in range(mini(again.count(), layout.count())):
		if not again.blocks[index].is_equal_approx(layout.blocks[index]):
			identical = false

	_check(identical, "and a second build of the same layout is the same rocks")

	var inside := true

	for block in layout.blocks:
		if not bounds.grow(-block.z).has_point(Vector2(block.x, block.y)):
			inside = false

	_check(inside, "and every one of them is wholly inside the world")

	# --- The channels, which are the level ----------------------------------

	# [b]The rocks are walked rather than the constants re-read.[/b] This is the same rule
	# the 3D maps in this family follow: one description, more than one representation,
	# and every representation derived from the description rather than restated. The
	# widths below come from `channel_widths`; the gaps come from the discs the world
	# actually built. A chain laid out in the wrong order, or with a sign flipped, agrees
	# with the constants and disagrees here.
	#
	# [b]Per barrier, not pairwise down the array.[/b] This loop walked `blocks` two at a
	# time while there was one chain; with the back reef behind it, the last rock of the
	# fore reef and the first of the back are neighbours in the array and 1,500 units apart
	# on the map, and the pairwise walk reported a fifth "channel" that is not one.
	# `channels(0)` is the fore reef's four; the lagoon section asks for the back's.
	var short_half := minf(bounds.size.x, bounds.size.y) * 0.5
	var wanted := HungryLayout.channel_widths(short_half)
	var measured := PackedFloat32Array()

	for channel in layout.channels(0):
		measured.append(float(channel["width"]))

	var agree := wanted.size() == measured.size()

	for index in range(mini(wanted.size(), measured.size())):
		if absf(wanted[index] - measured[index]) > 1.0:
			agree = false

	_check(
		agree,
		"the four channels it builds are the four channels it describes",
		"built %s, described %s" % [_widths(measured), _widths(wanted)]
	)

	var widens := measured.size() >= 2

	for index in range(measured.size() - 1):
		if measured[index + 1] <= measured[index] + 1.0:
			widens = false

	_check(
		widens,
		"and every one of them is wider than the one before it",
		"%s" % _widths(measured)
	)

	# [b]The end run-round is what stops this being the warrens with fewer gates.[/b] It
	# has to sit between the tight channel and the two open ones: wider and the tight
	# channel is decoration because everybody can walk round instead, narrower and it is a
	# slot nothing can use and the barrier is really a wall with four holes.
	var gate := layout.narrowest_gate(bounds)
	var run_round := INF

	for block in layout.blocks:
		run_round = minf(run_round, minf(
			minf(block.x - bounds.position.x, bounds.end.x - block.x),
			minf(block.y - bounds.position.y, bounds.end.y - block.y)
		) - block.z)

	_check(
		absf(gate - measured[0]) <= 1.0,
		"the tightest thing on the map is the tight channel, walls included",
		"%.0f, against %.0f round the end" % [gate, run_round]
	)
	_check(
		run_round > measured[0] and run_round < measured[2],
		"and the way round the end is better than the tight channel and worse than the third",
		"%.0f, between %.0f and %.0f" % [run_round, measured[0], measured[2]]
	)
	# The layout's own arithmetic for the same distance, which is what the design is
	# argued in. Two ways to the one number: if they ever disagree, the reasoning in
	# `_reef`'s docs is about a map that is not the one being built.
	_check(
		absf(run_round - short_half * HungryLayout.reef_end_fraction()) <= 1.0,
		"and it is the distance the layout says it leaves",
		"%.0f measured, %.0f derived"
			% [run_round, short_half * HungryLayout.reef_end_fraction()]
	)

	# --- Not a cage ---------------------------------------------------------

	var rules := world.tunables.mass_rules
	var won := rules.radius_for(preset.win_mass)

	_check(
		measured[measured.size() - 1] * 0.5 > won,
		"a monster at the winning mass still fits the open end",
		"a radius of %.0f through a %.0f channel" % [won, measured[measured.size() - 1]]
	)
	_check(
		measured[0] * 0.5 < won and run_round * 0.5 < won,
		"and it fits neither the tight channel nor the way round, so it has to travel",
		"%.0f against a %.0f channel and a %.0f run-round"
			% [won, measured[0], run_round]
	)

	# --- Driven through, small ----------------------------------------------

	# The tight channel's middle, and the two points either side of the barrier on its own
	# line. The barrier runs along the shorter axis, so crossing it is a move along the
	# other one.
	var mouth: Vector2 = layout.channels(0)[0]["mouth"]
	var across := Vector2(0.0, 1.0) if bounds.size.x < bounds.size.y \
		else Vector2(1.0, 0.0)
	var start := mouth - across * 600.0
	var target := mouth + across * 900.0

	world.spawn(1, start)
	_run_ticks(world, 2)

	var monster := world.monster_for(1)

	if not _check(monster != null and monster.alive, "a monster spawns short of the reef"):
		_drop(world)
		_done()
		return

	# [b]Sampled every tick.[/b] A push-out that fails for one frame and recovers is
	# invisible to a reading taken at the end, and one frame inside a rock is one frame of
	# eating through a wall.
	var deepest := INF
	var small_progress := 0.0

	for _i in range(TICK_RATE * 12):
		world.tick({1: _aim_at(monster.centre(), target)})

		for block in layout.blocks:
			deepest = minf(
				deepest,
				monster.centre().distance_to(Vector2(block.x, block.y)) - block.z
			)

		small_progress = maxf(small_progress, (monster.centre() - mouth).dot(across))

	_check(
		deepest > -2.0,
		"driving a monster through the tight channel never puts it inside a rock",
		"closest approach to a face %.0f" % deepest
	)
	_check(
		small_progress > 400.0,
		"and a starting monster comes out the far side of it",
		"%.0f past the mouth of a %.0f channel" % [small_progress, measured[0]]
	)

	# --- Driven at the same channel, grown ----------------------------------

	# [b]Nothing changes but the radius.[/b] Same seed, same world, same channel, same
	# commands, twice the ticks — so the only thing that can make the second run end on
	# the near side is the size of the thing running it.
	world.spawn(1, start)
	_run_ticks(world, 2)
	world.feed_player(1, preset.win_mass - monster.mass())
	_run_ticks(world, 2)

	var grown := monster.pieces[0].radius()
	var big_progress := -INF

	for _i in range(TICK_RATE * 24):
		world.tick({1: _aim_at(monster.centre(), target)})
		big_progress = maxf(big_progress, (monster.centre() - mouth).dot(across))

	_check(
		grown * 2.0 > measured[0],
		"a monster at the winning mass is wider than the tight channel",
		"%.0f across, against a %.0f channel" % [grown * 2.0, measured[0]]
	)
	_check(
		big_progress < small_progress - 200.0,
		"and the same run leaves it on the near side of the reef",
		"%.0f past the mouth, where the small one reached %.0f"
			% [big_progress, small_progress]
	)

	# --- Nothing edible is buried, and nobody spawns in a rock --------------

	var buried := 0

	for grid_id in world.field.alive_ids():
		if layout.blocked(world.field.position_of(grid_id), world.field.radius_of(grid_id)):
			buried += 1

	_check(buried == 0, "nothing edible is standing inside a rock", "%d buried" % buried)
	_check(
		world.field.alive_count() > preset.food_target,
		"and the field still fills to the target it asks for",
		"%d alive against a food target of %d"
			% [world.field.alive_count(), preset.food_target]
	)

	# A client is TOLD which layout, and builds it. Nothing about the rocks travels.
	var predicted := _make_world(preset, SEED + 131)
	predicted.is_authority = false
	predicted.add_player(2, "Bo")
	_settle(predicted)
	predicted.adopt_layout(HungryLayout.REEF)
	_check(
		predicted.layout.count() == layout.count()
			and predicted.layout.narrowest_gate(bounds) == layout.narrowest_gate(bounds),
		"and a client builds the same ten from one name in the hello"
	)
	_drop(predicted)

	_drop(world)
	_done()


## The reef's second half: a lagoon, and a back reef with one door in it.
##
## [b]What this section is about is a DISTANCE a grown monster is made to travel, so it
## drives one along it.[/b] The back reef's door is behind the fore reef's tight end and
## the two fore channels a grown monster fits are both at the other end, so the lagoon
## between them is a walk that only the big pay. Every arithmetic check below would pass
## over a back reef built on the wrong side, the wrong way round, or so close to the fore
## reef that nothing fits between them; the drive would not.
##
## [b]It is driven along [method HungryLayout.route_across][/b], the layout's own answer
## to "where do I steer to get across", rather than along waypoints written here — so the
## route a check follows is derived from the same discs the world pushes a monster out of,
## and a waypoint inside a rock is a failure of the layout rather than of the test.
func _test_the_lagoon() -> void:
	_section("the lagoon")

	var preset := HungryPreset.reef()
	# [b]The leader's size is read BEFORE the round is told it cannot end.[/b] A leader
	# walks this route for over a minute at a fifth of full speed, eating the whole way,
	# and the first version of this section fed it to the winning mass and drove it: it
	# ate its way past the mass that ends the round a little way up the lagoon, the world
	# reset under it, and the "leader" that came out behind the back reef was a freshly
	# spawned monster somewhere else. The check is about the walk, so the round is
	# lifted out of the way and the size stays the one the mode is played at.
	var leader_mass := preset.win_mass
	preset.win_mass = 1000000.0
	var world := _make_world(preset, SEED + 173)
	world.add_player(1, "Lea")
	_settle(world)

	var bounds := world.arena.bounds
	var layout := world.layout

	if not _check(
		layout != null and layout.chains.size() == 2,
		"the reef has a second barrier behind the first (%d)"
			% (layout.chains.size() if layout != null else -1)
	):
		_drop(world)
		_done()
		return

	var short_half := minf(bounds.size.x, bounds.size.y) * 0.5
	var fore := layout.channels(0)
	var back := layout.channels(1)
	var wanted := HungryLayout.back_reef_widths(short_half)
	var measured := PackedFloat32Array()

	for channel in back:
		measured.append(float(channel["width"]))

	var agree := wanted.size() == measured.size()

	for index in range(mini(wanted.size(), measured.size())):
		if absf(wanted[index] - measured[index]) > 1.0:
			agree = false

	_check(
		agree,
		"the back reef builds the door and three gates it describes",
		"built %s, described %s" % [_widths(measured), _widths(wanted)]
	)

	# [b]The door is behind the fore reef's TIGHT end.[/b] That one relation is the whole
	# level: the other way round, a grown monster comes through the fore reef's open end
	# and finds the door straight ahead of it, and the lagoon is a corridor nobody walks.
	var chain_axis: Vector2 = (
		Vector2(fore[fore.size() - 1]["mouth"]) - Vector2(fore[0]["mouth"])
	).normalized()
	var centre := bounds.get_center()
	var door_at := (Vector2(back[0]["mouth"]) - centre).dot(chain_axis)
	var tight_at := (Vector2(fore[0]["mouth"]) - centre).dot(chain_axis)
	var third_at := (Vector2(fore[2]["mouth"]) - centre).dot(chain_axis)
	var wide_at := (Vector2(fore[3]["mouth"]) - centre).dot(chain_axis)

	_check(
		door_at * tight_at > 0.0 and door_at * wide_at < 0.0 and door_at * third_at < 0.0,
		"and the door is behind the fore reef's tight end, away from both its open channels",
		"door at %.0f, tight %.0f, third %.0f, widest %.0f along the reef"
			% [door_at, tight_at, third_at, wide_at]
	)

	# --- The lagoon, sized by the monster that has to walk it -----------------

	var rules := world.tunables.mass_rules
	var won := rules.radius_for(leader_mass)
	var small := rules.radius_for(HungryContent.START_MASS)
	var rock := layout.blocks[0].z
	var across: Vector2 = fore[0]["normal"]

	if (Vector2(back[0]["mouth"]) - Vector2(fore[0]["mouth"])).dot(across) < 0.0:
		across = -across

	var fore_line := Vector2(fore[0]["mouth"]).dot(across)
	var back_line := Vector2(back[0]["mouth"]).dot(across)
	var far_wall := maxf(bounds.position.dot(across), bounds.end.dot(across))
	var lagoon := back_line - fore_line - rock * 2.0
	var strip := far_wall - back_line - rock

	_check(
		lagoon > won * 2.0 * 1.3 and strip > won * 2.0 * 1.3,
		"a monster at the winning mass has room to travel the lagoon and the strip behind it",
		"lagoon %.0f, strip %.0f, against a leader %.0f across" % [lagoon, strip, won * 2.0]
	)
	_check(
		lagoon < won * 4.0,
		"and not room to be passed in it: two leaders cannot stand abreast",
		"lagoon %.0f against two leaders %.0f" % [lagoon, won * 4.0]
	)

	# --- Who walks it, from the routes the layout gives ----------------------

	# From in front of the fore reef's tight channel, which is the end the door is behind:
	# the cheapest place to start for everybody, so the walk measured is the tax and not
	# the approach.
	var west: Vector2 = Vector2(fore[0]["mouth"]) - across * 900.0
	var middling := rules.radius_for(1000.0)

	_check(
		_lagoon_walk(layout.route_across(west, small), chain_axis) < 400.0,
		"a starting monster crosses both barriers almost on one line",
		"walks %.0f along the lagoon" % _lagoon_walk(layout.route_across(west, small), chain_axis)
	)
	_check(
		_lagoon_walk(layout.route_across(west, middling), chain_axis) > 1000.0,
		"one of 1000 mass has to walk the lagoon from the third channel to the door",
		"walks %.0f along the lagoon"
			% _lagoon_walk(layout.route_across(west, middling), chain_axis)
	)
	_check(
		_lagoon_walk(layout.route_across(west, won), chain_axis) > 2000.0,
		"and one at the winning mass walks nearly all of it",
		"walks %.0f along the lagoon" % _lagoon_walk(layout.route_across(west, won), chain_axis)
	)

	# [b]Not a cage, from either side.[/b] A leader in the strip behind the back reef has to
	# have a way home, or the far side is a place the round ends with somebody parked in.
	var behind := centre + across * (back_line - centre.dot(across) + rock + won + 100.0)
	_check(
		layout.route_across(behind, won).size() == 6,
		"a leader behind the back reef has a way back across both",
		"%d waypoints" % layout.route_across(behind, won).size()
	)
	_check(
		layout.route_across(west, float(wanted[0]) * 0.5 + 1.0).is_empty(),
		"and something too wide for the door has no route at all, rather than a wrong one"
	)

	# --- Driven: a leader walks the lagoon to the door ------------------------

	world.spawn(1, west)
	_run_ticks(world, 2)

	var monster := world.monster_for(1)

	if not _check(monster != null and monster.alive, "a monster spawns short of the reef"):
		_drop(world)
		_done()
		return

	world.feed_player(1, leader_mass - monster.mass())
	_run_ticks(world, 2)

	var route := layout.route_across(monster.centre(), monster.pieces[0].radius())
	var reached := 0
	var deepest := INF
	var lagoon_low := INF
	var lagoon_high := -INF
	var ticks := 0

	# Full reach toward the next waypoint and on to the one after it at 60 units: near is
	# slow in this game, and a monster steered with the reach it would get from the
	# distance to a point crawls the last hundred units of every leg.
	for _i in range(TICK_RATE * 120):
		if reached >= route.size():
			break

		if monster.centre().distance_to(route[reached]) < 60.0:
			reached += 1
			continue

		world.tick({1: _full_reach(monster.centre(), route[reached])})
		ticks += 1

		var piece := monster.pieces[0]

		for block in layout.blocks:
			deepest = minf(
				deepest,
				piece.position().distance_to(Vector2(block.x, block.y)) - block.z
					- piece.radius()
			)

		var here := monster.centre()

		if here.dot(across) > fore_line + rock and here.dot(across) < back_line - rock:
			lagoon_low = minf(lagoon_low, here.dot(chain_axis))
			lagoon_high = maxf(lagoon_high, here.dot(chain_axis))

	_check(
		deepest > -2.0,
		"a leader driven along its route never overlaps a rock, on any tick",
		"deepest %.0f into a face" % deepest
	)
	_check(
		reached == route.size() and monster.centre().dot(across) > back_line + rock,
		"and comes out behind the back reef",
		"%d of %d waypoints in %.1f s" % [reached, route.size(), float(ticks) / TICK_RATE]
	)
	_check(
		lagoon_high - lagoon_low > 2000.0,
		"having walked the lagoon from one end to the other to get there",
		"%.0f along the lagoon" % (lagoon_high - lagoon_low)
	)

	# --- The straight line: the same start, the same commands, two sizes -----

	# From in front of the fore reef's widest channel, straight across. A starting monster
	# goes through the fore reef and a gate of the back one; a leader goes through the
	# fore reef and meets gates it does not fit, and is still in the lagoon when the clock
	# runs out. Nothing but the radius differs between the two runs.
	var straight_from: Vector2 = Vector2(fore[3]["mouth"]) - across * 700.0
	var straight_to := straight_from + across * 4000.0
	var small_far := _straight_run(world, 1, straight_from, straight_to, 0.0)
	var big_far := _straight_run(world, 1, straight_from, straight_to, leader_mass)

	_check(
		small_far > back_line + rock,
		"a starting monster driven straight across goes through both barriers",
		"reached %.0f, the back reef is at %.0f" % [small_far, back_line]
	)
	_check(
		big_far > fore_line + rock and big_far < back_line - rock,
		"and a leader on the same line is held in the lagoon",
		"reached %.0f, between %.0f and %.0f" % [big_far, fore_line, back_line]
	)

	_drop(world)
	_done()


## How far a route runs along the reef between leaving the first barrier and reaching the
## second: the walk the lagoon charges. Waypoints 2 and 3 are the fore exit and the back
## approach — see [method HungryLayout.route_across].
func _lagoon_walk(route: PackedVector2Array, chain_axis: Vector2) -> float:
	if route.size() < 6:
		return INF

	return absf((route[3] - route[2]).dot(chain_axis))


## A command at full reach toward [param to].
func _full_reach(from: Vector2, to: Vector2) -> Dot2DCommand:
	var command := Dot2DCommand.new()
	var offset := to - from
	command.aim = offset.normalized() if offset.length_squared() > 0.000001 else Vector2.RIGHT
	command.reach = HungryNetCommand.MAX_REACH
	return command


## Respawns [param player] at [param from], grows it to [param mass] if that is above
## where it starts, and drives it at [param to] for twenty-four seconds — a starting
## monster covers about 130 units a second, so this is room for about 3000. Returns how far it got
## along the line.
func _straight_run(
	world: HungryWorld, player: int, from: Vector2, to: Vector2, mass: float
) -> float:
	world.spawn(player, from)
	_run_ticks(world, 2)

	var monster := world.monster_for(player)

	if monster == null or not monster.alive:
		return -INF

	if mass > monster.mass():
		world.feed_player(player, mass - monster.mass())
		_run_ticks(world, 2)

	var direction := (to - from).normalized()
	var furthest := -INF

	for _i in range(TICK_RATE * 24):
		world.tick({player: _full_reach(monster.centre(), to)})
		furthest = maxf(furthest, monster.centre().dot(direction))

	return furthest


## The warrens' den: a ring inside the ring, driven into by a starting monster and refused
## to one that has eaten.
##
## [b]The warrens' section asks the ring its question; this asks the den its own.[/b] The
## den's gates admit about a tenth of the winning mass where the ring's admit about a
## third, so the map has three tiers now and each has to be proved at the size it is FOR:
## a starting monster from the wall gets through both, one between the two limits gets
## through the ring and no further, and nothing about the den may narrow the moat it
## stands in below the ring's own gate — that would be a hidden gate only a monster
## already inside could find.
##
## [b]Driven along a route found on the geometry[/b], `HungryLayout.route_to`, rather
## than along a line picked by hand: a line picked by hand is a claim about where the
## gates are, and the route is what the rocks the world built actually leave.
func _test_the_den() -> void:
	_section("the den")

	var preset := HungryPreset.warrens()
	var world := _make_world(preset, SEED + 211)
	world.add_player(1, "Ada")
	_settle(world)

	var bounds := world.arena.bounds
	var centre := bounds.get_center()
	var layout := world.layout
	var rules := world.tunables.mass_rules

	if not _check(
		layout != null and layout.rings.size() == 2,
		"the warrens has two rings: the ring, and the den inside it",
		"%d rings" % (layout.rings.size() if layout != null else -1)
	):
		_drop(world)
		_done()
		return

	var ring_gates := layout.ring_gates(0)
	var den_gates := layout.ring_gates(1)
	var den_gate: float = Array(den_gates).min()
	var ring_gate: float = Array(ring_gates).min()

	_check(
		den_gates.size() == HungryLayout.DEN_COUNT
			and float(Array(den_gates).max()) - den_gate < 0.5,
		"the den has four gates, all the same width",
		_widths(den_gates)
	)

	# [b]The design number.[/b] Mass IS radius, so the gate is a mass limit, and this one
	# is meant for the players furthest behind: past a starting monster, short of anybody
	# who has fed for a minute.
	var den_admits := rules.mass_for(den_gate * 0.5)
	_check(
		den_admits > preset.win_mass * 0.05 and den_admits < preset.win_mass * 0.15,
		"its gates admit about a tenth of the winning mass",
		"%.0f of %.0f, through %.0f" % [den_admits, preset.win_mass, den_gate]
	)
	_check(
		rules.radius_for(HungryContent.START_MASS) * 2.0 < den_gate * 0.5,
		"a starting monster fits with room to spare",
		"a radius of %.0f through a half-gate of %.0f"
			% [rules.radius_for(HungryContent.START_MASS), den_gate * 0.5]
	)
	_check(
		den_gate < ring_gate * 0.6,
		"and it is a tier below the ring rather than another copy of it",
		"%.0f against the ring's %.0f" % [den_gate, ring_gate]
	)
	_check(
		is_equal_approx(layout.narrowest_gate(bounds), den_gate),
		"nothing else on the map is tighter than the den",
		"narrowest %.0f, the den %.0f" % [layout.narrowest_gate(bounds), den_gate]
	)

	# The moat: the ring's inner face to the den's outer face.
	var ring_rock: Vector3 = layout.blocks[layout.rings[0].x]
	var den_rock: Vector3 = layout.blocks[layout.rings[1].x]
	var ring_at := Vector2(ring_rock.x, ring_rock.y).distance_to(centre)
	var den_at := Vector2(den_rock.x, den_rock.y).distance_to(centre)
	var moat := (ring_at - ring_rock.z) - (den_at + den_rock.z)
	_check(
		moat > ring_gate + 20.0,
		"the moat round the den is wider than the ring's gate",
		"%.0f against %.0f" % [moat, ring_gate]
	)

	# --- Reach, at the size each tier is for -------------------------------

	# Off the axis on purpose: from a wall's midpoint the line to the centre runs through a
	# ring gate AND a den gate (both are on the axes), and a route that is one straight leg
	# proves nothing about finding a way. From here it has to bend at both rings.
	var wall := Vector2(bounds.position.x + 200.0, centre.y - bounds.size.y * 0.22)
	var between := (den_gate * 0.5 + ring_gate * 0.5) * 0.5
	var tiers := layout.reach(bounds, wall, between)
	var outside_den := 0

	for point in tiers["stranded"]:
		if point.distance_to(centre) > den_at:
			outside_den += 1

	_check(
		tiers["free"] - tiers["reached"] > 0 and outside_den == 0,
		"one between the two limits reaches everything but the den",
		"radius %.0f: %d of %d reached, %d stranded outside the den"
			% [between, tiers["reached"], tiers["free"], outside_den]
	)
	_check(
		layout.route_to(bounds, wall, centre, between).is_empty()
			and not layout.route_to(
				bounds, wall, centre + Vector2(den_at + den_rock.z + moat * 0.5, 0.0), between
			).is_empty(),
		"so it has a route into the moat and none into the den"
	)

	# --- Driven: a starting monster from the wall to the centre -------------

	world.spawn(1, wall)
	_run_ticks(world, 2)

	var monster := world.monster_for(1)

	if not _check(monster != null and monster.alive, "a starting monster spawns by the west wall, off the axis"):
		_drop(world)
		_done()
		return

	var small := monster.pieces[0].radius()
	# Planned 24 wider than the monster — `route_across`'s margin — because a monster
	# steered at a waypoint swings wide of the leg on every turn. At 12 it pressed a den
	# rock's face, ate on the same tick, and grew 2.3 units into it before the next
	# push-out.
	var route := layout.route_to(bounds, monster.centre(), centre, small + 24.0)

	_check(
		route.size() >= 2,
		"and has a route to the centre that has to turn to find the gates",
		"%d waypoints" % route.size()
	)

	var reached := 0
	var deepest := INF
	var ring_crossed := false

	for _i in range(TICK_RATE * 40):
		if reached >= route.size():
			break

		if monster.centre().distance_to(route[reached]) < 40.0:
			reached += 1
			continue

		world.tick({1: _full_reach(monster.centre(), route[reached])})

		for piece in monster.pieces:
			for block in layout.blocks:
				deepest = minf(
					deepest,
					piece.position().distance_to(Vector2(block.x, block.y)) - block.z
						- piece.radius()
				)

		if monster.centre().distance_to(centre) < ring_at - ring_rock.z:
			ring_crossed = true

	_check(
		deepest > -2.0,
		"driven along it, it never overlaps a rock on any tick",
		"deepest %.1f into a face" % deepest
	)
	_check(
		ring_crossed and reached == route.size()
			and monster.centre().distance_to(centre) < den_at - den_rock.z,
		"and it comes through the ring and the den to the middle of it",
		"%d of %d waypoints, %.0f from the centre, the den's inside is %.0f"
			% [reached, route.size(), monster.centre().distance_to(centre), den_at - den_rock.z]
	)

	# --- And one that has eaten is held at the door --------------------------

	# In the moat on the east axis, driven straight at the centre: the line runs through a
	# den GATE, so the only thing that can stop it is the gate's width.
	var door := centre + Vector2(den_at + den_rock.z + moat * 0.5, 0.0)
	var fed := rules.mass_for(den_gate * 0.5) * 1.6
	_straight_run(world, 1, door, centre, fed)
	monster = world.monster_for(1)

	_check(
		monster != null and monster.alive and monster.centre().distance_to(centre) > den_at,
		"one at %.0f mass driven through a den gate is held outside it" % fed,
		"stopped %.0f from the centre, the den's rocks stand at %.0f"
			% [monster.centre().distance_to(centre) if monster != null else -1.0, den_at]
	)

	_drop(world)
	_done()


## [reach-1]: every level, swept. Every gap passes what it is meant to pass, and nothing on
## the floor is out of a starting monster's reach.
##
## [b]Two questions every level check before this one answered for its own level by
## hand[/b] — the warrens' gate, the slalom's lanes, the reef's channels — and none of
## them could see a pocket: floor a spawn can land on and never leave, or food the scatter
## puts where nobody can eat it. So this asks every mode the same two things, off the
## geometry alone:
##
## - [b]Every gate passes a monster just under its width and refuses one just over.[/b]
##   [method HungryLayout.gates] finds every gap on the map — rock to rock and rock to
##   wall, anything with no third rock standing in its mouth — and
##   [method HungryLayout.gate_passes] floods each one inside its own box, so the only way
##   through is through. A gap a neighbouring rock has narrowed fails the first half; one
##   that is not actually the limit its width says fails the second.
## - [b]A starting monster can reach every sampled point of the floor from the wall.[/b]
##   And a monster at the winning mass is kept out only where the level means it to be:
##   the warrens' ring, and nowhere at all on the corridor or the reef, whose designs
##   promise the leader a way everywhere.
func _test_the_reach() -> void:
	_section("the reach of every level")

	var modes: Array[StringName] = [&"classic", &"frenzy", &"gauntlet", &"warrens", &"reef"]
	var covered := {}

	for mode in modes:
		covered[HungryPreset.for_id(mode).layout] = true

	var missing := PackedStringArray()

	for layout_id in HungryLayout.ids():
		if not covered.has(layout_id):
			missing.append(String(layout_id))

	_check(missing.is_empty(), "every layout is swept here", "not swept: %s" % ", ".join(missing))

	var slack := 8.0
	var rules := HungryContent.mass_rules()

	for mode in modes:
		var preset := HungryPreset.for_id(mode)
		var bounds := Rect2(-preset.world_size * 0.5, preset.world_size)
		var layout := HungryLayout.for_id(preset.layout, bounds)
		var start := rules.radius_for(HungryContent.START_MASS)
		var won := rules.radius_for(preset.win_mass)
		var wall := Vector2(bounds.position.x + won + 30.0, bounds.get_center().y)

		var small := layout.reach(bounds, wall, start)
		var stranded_small: PackedVector2Array = small["stranded"]
		_check(
			small["free"] > 0 and small["reached"] == small["free"],
			"%s: a starting monster reaches all of the floor" % mode,
			"%d of %d sampled points, %d stranded%s"
				% [small["reached"], small["free"], small["free"] - small["reached"],
					"" if stranded_small.is_empty() else ", first at %s" % stranded_small[0]]
		)
		print("        %s: %d of %d points at radius %.0f" % [
			mode, small["reached"], small["free"], start
		])

		var big := layout.reach(bounds, wall, won)
		var stranded_big: PackedVector2Array = big["stranded"]
		var big_note := "%d of %d at the winning radius %.0f" % [big["reached"], big["free"], won]
		print("        %s: %s" % [mode, big_note])

		if preset.layout == HungryLayout.WARRENS:
			# [b]A finding, not the design (2026-09-24).[/b] The corner rocks stand 481
			# units off each wall and 491 off the nearest ring rock, so past a radius of
			# about 240 — 903 mass, 56% of the winning mass — the perimeter lane is four
			# lanes, and a leader is held in one quarter of it unless it splits. This file's
			# CLAUDE.md said the lane was open to everybody for ever; the sweep says it is
			# open to everybody the RING shuts out, which is the half the mode rests on, and
			# that is what is asserted. Whether the corners should close it at all is a
			# design question left open in the Queue.
			var corner_limit := INF

			for gate in layout.gates(bounds):
				var a: int = gate["a"]
				var b: int = gate["b"]
				var corner_first := HungryLayout.RING_COUNT

				if (a >= corner_first and a < corner_first + 4) or (b >= corner_first and b < corner_first + 4):
					corner_limit = minf(corner_limit, float(gate["width"]) * 0.5)

			# Two grid cells under the limit: the sweep samples every 24 units, and the corner
			# gaps leave 17 to spare at 8 under, which a grid can step straight over.
			var lane := layout.reach(bounds, wall, corner_limit - 48.0)
			var ring: Vector3 = layout.blocks[layout.rings[0].x]
			var ring_at := Vector2(ring.x, ring.y).distance_to(bounds.get_center())
			var outside := 0

			for point in lane["stranded"]:
				if point.distance_to(bounds.get_center()) > ring_at:
					outside += 1

			var ring_admits := rules.mass_for(Array(layout.ring_gates(0)).min() * 0.5)
			var lane_admits := rules.mass_for(corner_limit)
			_check(
				outside == 0 and lane_admits > ring_admits * 1.5,
				"%s: anybody the ring shuts out still has the whole perimeter lane" % mode,
				"whole up to %.0f mass (radius %.0f), the ring shuts out %.0f; %d stranded outside the ring at radius %.0f; at the winning radius: %s"
					% [lane_admits, corner_limit, ring_admits, outside, corner_limit - 48.0, big_note]
			)
			print("        %s: the lane is quartered past %.0f mass; %d of %d stranded at the winning radius" % [
				mode, lane_admits, stranded_big.size(), big["free"]
			])
		else:
			_check(
				big["reached"] == big["free"],
				"%s: a leader can reach all of the floor too" % mode,
				big_note
			)

		if layout.is_empty():
			continue

		var gates := layout.gates(bounds)
		var shut := PackedStringArray()
		var leaky := PackedStringArray()
		var narrowest := INF

		for gate in gates:
			var width: float = gate["width"]
			narrowest = minf(narrowest, width)

			if width * 0.5 - slack > start and not layout.gate_passes(bounds, gate, width * 0.5 - slack):
				shut.append("%d-%d %.0f" % [gate["a"], gate["b"], width])

			if layout.gate_passes(bounds, gate, width * 0.5 + slack):
				leaky.append("%d-%d %.0f" % [gate["a"], gate["b"], width])

		print("        %s: %d gates, narrowest %.0f" % [mode, gates.size(), narrowest])
		_check(
			gates.size() > 0 and shut.is_empty(),
			"%s: every one of its %d gates passes a monster %.0f under its width" % [
				mode, gates.size(), slack * 2.0
			],
			"shut: %s" % ", ".join(shut)
		)
		_check(
			leaky.is_empty(),
			"%s: and refuses one %.0f over it" % [mode, slack * 2.0],
			"leaky: %s" % ", ".join(leaky)
		)

	_done()

## Food per unit of the floor that is left, MEASURED, for every mode with a level in it.
##
## [b]The arithmetic this replaces was backwards and a check agreed with it.[/b] The
## gauntlet's density check multiplied the target by the walkable fraction — the model of
## a cull that is a permanent loss — and the gauntlet's target had been raised to 790 by
## the same model. But [method HungryWorld._cull_blocked] takes a slot OUT of the field
## and the scatter tops the field back up to its target on the next ticks, so the target
## is what stands on the floor: 790 over the corridor's floor was 27% more food per unit
## than Frenzy, and the reef's 880 was 4.5% more than Classic. Warrens alone had it right,
## and the check and the preset agreeing with each other is exactly why nobody saw it.
##
## So this section counts the food that is alive in a settled world and divides it by the
## floor, which is the only version of the number a player eats. Each mode is compared
## with the empty square it was built to match.
func _test_food_on_the_floor() -> void:
	_section("food on the floor that is left")

	# The control each level claims to match, as its own preset comment argues it.
	var controls := {
		&"gauntlet": HungryPreset.frenzy(),
		&"warrens": HungryPreset.classic(),
		&"reef": HungryPreset.classic(),
	}

	# Every layout is somebody's, so a sixth mode with rocks in it cannot arrive without
	# being asked this. A check named after the levels that existed when it was written is
	# the shape this project keeps finding.
	var covered_layouts := {}

	for mode in controls:
		covered_layouts[HungryPreset.for_id(mode).layout] = true

	var missing := PackedStringArray()

	for layout_id in HungryLayout.ids():
		if not covered_layouts.has(layout_id):
			missing.append(String(layout_id))

	_check(
		missing.is_empty(),
		"every layout is measured here against the square it claims to match",
		"not measured: %s" % ", ".join(missing)
	)

	for mode in controls:
		var preset := HungryPreset.for_id(mode)
		var control: HungryPreset = controls[mode]
		var world := _make_world(preset, SEED + 199)
		world.add_player(1, "Ada")
		_settle(world)
		_run_ticks(world, TICK_RATE * 2)

		var area := world.arena.bounds.size.x * world.arena.bounds.size.y
		var floor_area := area - world.layout.covered_area()
		var here := float(world.field.food.alive_count()) / floor_area
		var there := float(control.food_target) / (control.world_size.x * control.world_size.y)

		_check(
			absf(here / there - 1.0) < 0.03,
			"%s has %s's food per unit of open floor" % [mode, control.id],
			"%.1f per million against %.1f: %d alive on %.2f million, %.1f%% under rock"
				% [here * 1.0e6, there * 1.0e6, world.field.food.alive_count(),
					floor_area / 1.0e6, (1.0 - floor_area / area) * 100.0]
		)

		_drop(world)

	_done()


## A list of gap widths, for a check's detail line.
func _widths(gaps: PackedFloat32Array) -> String:
	var parts := PackedStringArray()

	for gap in gaps:
		parts.append("%.0f" % gap)

	return "/".join(parts)


func _test_determinism() -> void:
	_section("determinism")

	# Two worlds, the same seed, the same commands. The property everything else in the
	# netcode rests on: a client predicting a move and a server re-running it have to
	# reach the same answer, and nothing else in this project can check that.
	var first := _make_world()
	var second := _make_world()

	for world in [first, second]:
		world.add_player(1, "Ada")
		world.add_player(2, "Bo")
		_settle(world)
		world.spawn(1, Vector2(-200.0, 0.0))
		world.spawn(2, Vector2(200.0, 60.0))

	var commands: Array[Dictionary] = []

	for step in range(240):
		var angle := float(step) * 0.11
		commands.append({
			1: _aim_at(
				Vector2.ZERO,
				Vector2.from_angle(angle) * 400.0,
				Dot2DCommand.BUTTON_SPLIT if step == 90 else 0
			),
			2: _aim_at(Vector2.ZERO, Vector2.from_angle(-angle) * 300.0),
		})

	for step in range(commands.size()):
		first.tick(commands[step])
		second.tick(commands[step])

	var exact := true
	var worst := 0.0

	for piece in first.pieces():
		var twin := second.piece_for(piece.id)

		if twin == null:
			exact = false
			break

		worst = maxf(worst, piece.position().distance_to(twin.position()))
		exact = exact and piece.position() == twin.position()

	_check(
		exact,
		"two worlds replaying the same commands are bit-identical (%.6f apart)" % worst
	)
	_check(
		first.field.alive_count() == second.field.alive_count(),
		"and ate exactly the same food"
	)

	# And it must not pass for a world that ignores its inputs.
	var third := _make_world()
	third.add_player(1, "Ada")
	third.add_player(2, "Bo")
	_settle(third)
	third.spawn(1, Vector2(-200.0, 0.0))
	third.spawn(2, Vector2(200.0, 60.0))

	for step in range(commands.size()):
		var changed := commands[step].duplicate()

		if step == 120:
			changed[1] = _aim_at(Vector2.ZERO, Vector2.LEFT * 400.0)

		third.tick(changed)

	var differs := false

	for piece in first.pieces():
		var twin := third.piece_for(piece.id)

		if twin == null or piece.position() != twin.position():
			differs = true
			break

	_check(differs, "and a different command produces a different world")

	_drop(first)
	_drop(second)
	_drop(third)


# --- The whole thing -------------------------------------------------------
	_done()

func _test_full_round() -> void:
	_section("a whole round, eight bots")

	# Frenzy, because a classic round to 2400 mass is a very long time in ticks and this
	# is a smoke test rather than a soak.
	var world := _make_world(HungryPreset.frenzy(), SEED + 7)
	var ended := [false]
	var winner := [""]

	world.match_node.round_ended.connect(
		func(_round_number: int, _winner: int, _outcome: DotMatchRules.Outcome) -> void:
			ended[0] = true
			var leader := world.match_node.scoreboard.leader()
			winner[0] = leader.display_name if leader != null else ""
	)

	for id in range(1, 9):
		world.add_player(id, "Bot %d" % id)

	_settle(world)

	var burst_total := [0]
	var throws := [0]
	var deaths := [0]

	world.monster_burst.connect(func(_p: int, _b: int, c: int) -> void:
		burst_total[0] += c
	)
	world.projectile_thrown.connect(func(_s: HungryProjectile) -> void:
		throws[0] += 1
	)
	world.player_died.connect(func(_p: int, _k: int) -> void: deaths[0] += 1)

	var ticks := 0
	var limit := TICK_RATE * 240

	while not ended[0] and ticks < limit:
		var commands: Dictionary = {}

		for monster in world.monsters():
			commands[monster.id] = HungryBot.command_for(world, monster, ticks)

		world.tick(commands)
		ticks += 1

	_check(ended[0], "the round ends (%d ticks, %.0fs)" % [ticks, float(ticks) / TICK_RATE])
	_check(winner[0] != "", "and there is a winner: %s" % winner[0])

	var top := world.leaderboard(1)
	_check(
		not top.is_empty() and top[0].mass() > HungryContent.START_MASS * 5.0,
		"who actually grew (%.0f)" % (top[0].mass() if not top.is_empty() else 0.0)
	)

	_check(deaths[0] > 0, "monsters ate each other (%d deaths)" % deaths[0])
	_check(throws[0] > 0, "and threw things (%d)" % throws[0])
	_check(burst_total[0] > 0, "and burst each other (%d pieces)" % burst_total[0])

	# The two invariants that hold whatever happened.
	_check(_furthest_edge(world) <= 0.5, "nothing ended up outside the world")

	var stale := 0

	for grid_id in world.arena.grid.ids():
		if grid_id >= HungryField.PIECE_ID_LIMIT:
			if not world.field.food.is_alive(HungryField.index_of(grid_id)) \
					and HungryField.kind_of(grid_id) == HungryField.Kind.FOOD:
				stale += 1
		elif world.piece_for(grid_id) == null:
			stale += 1

	_check(stale == 0, "and the grid holds nothing that no longer exists (%d)" % stale)

	var over_cap := 0

	for monster in world.monsters():
		if monster.piece_count() > world.tunables.mass_rules.max_pieces:
			over_cap += 1

	_check(over_cap == 0, "and nobody exceeded the piece cap")

	print("")
	for line in world.describe_lines():
		print("  %s" % line)

	_drop(world)


# --- The rider -------------------------------------------------------------
	_done()

func _test_rider() -> void:
	_section("the rider")

	var schema := HungryContent.avatar_schema()
	var valid := schema.validate_schema()

	_check(valid.ok, "the rider schema is legal", str(valid.error))

	# A server decides whether an avatar is legal from ids alone. If this ever needs a
	# load(), a ResourceLoader.exists() or a scene path, that is the thing to push back
	# on — it is the whole reason an avatar is a document.
	var avatar := HungryContent.default_avatar(7)
	var checked := schema.validate(avatar, DotAvatarEntitlements.everything())
	_check(checked.ok, "and a default avatar passes it", str(checked.error))
	_check(
		avatar.has_slot(&"body"),
		"with the required slot filled, so nobody is invisible"
	)

	# Deterministic on the id: a client that has not been sent somebody's avatar draws
	# the same guest as everybody else rather than a different one per machine.
	_check(
		HungryContent.default_avatar(7).digest() == avatar.digest(),
		"and the same id always produces the same one"
	)
	_check(
		HungryContent.default_avatar(8).digest() != avatar.digest(),
		"while a different id does not"
	)

	# An entitlement set of nothing must still dress somebody. Every part that is not
	# free is refused, and conform fills the required slot from its default.
	var greedy := DotAvatar.make(schema.id)
	greedy.set_part(&"body", &"rider_spike")
	greedy.set_part(&"hat", &"hat_crown")

	var conformed := schema.conform(greedy, DotAvatarEntitlements.none())
	_check(conformed.ok, "conform repairs an avatar nobody owns", str(conformed.error))
	_check(
		greedy.part_in(&"body") == &"rider_pip",
		"back to the free body (%s)" % greedy.part_in(&"body")
	)
	_check(
		greedy.part_in(&"hat") != &"hat_crown",
		"and drops the hat they do not own"
	)

	# The rig. Parts resolve through HungryContentSource, which prefers a mounted pack and
	# falls back to what shipped in the build — which is the path taken here, because
	# nothing has mounted anything.
	var catalogue := DotAvatarCatalogue.new()
	var source := HungryContentSource.new()
	source.install(catalogue)

	var dressed := DotAvatar.make(schema.id)
	dressed.set_part(&"body", &"rider_blob")
	dressed.set_part(&"hat", &"hat_cap")
	dressed.set_colour(&"body", 0, Color(0.9, 0.3, 0.4))

	var rider := HungryRider.make(schema, catalogue)
	add_child(rider)
	rider.wear(dressed)

	_check(
		rider.built_slots() == 2,
		"both parts build from the content in this build (%d)" % rider.built_slots()
	)
	_check(rider.drawn_slots() == 0, "so none of them has to be drawn")
	_check(
		source.mount_prefix == "",
		"and none of it came from a pack, because none is mounted"
	)

	# The whole contract between this game and its content: a Node2D that answers
	# `hungry_dress`. A part that does not is still shown, which is why this is checked
	# rather than assumed.
	var body: Node2D = rider._built.get(&"body")
	_check(
		body != null and body.has_method(&"hungry_dress"),
		"the built part takes its colours through hungry_dress"
	)
	_check(
		body != null and (body.get("tint_a") as Color).is_equal_approx(
			DotAvatar.quantise(Color(0.9, 0.3, 0.4))
		),
		"and wears the colour the document asked for"
	)

	# Resizing is called every frame for every player on screen, so it must be cheap and
	# it must actually reach the part.
	rider.resize(64.0)
	_check(
		body != null and is_equal_approx(float(body.get("unit")), 64.0),
		"and follows the monster as it grows"
	)

	# Wearing the same document twice must be free.
	var before := rider.get_child_count()
	rider.wear(dressed)
	_check(
		rider.get_child_count() == before,
		"re-wearing the same document rebuilds nothing"
	)

	# A part with no content anywhere falls back to being drawn rather than to nothing.
	# A player you cannot see is a competitive advantage.
	var ghost := DotAvatar.make(schema.id)
	ghost.set_part(&"body", &"rider_pip")
	ghost.set_part(&"trail", &"trail_ember")

	var bare := DotAvatarCatalogue.new()
	bare.resolver = func(_part: DotAvatarPart) -> String: return ""

	var drawn := HungryRider.make(schema, bare)
	add_child(drawn)
	drawn.wear(ghost)

	_check(
		drawn.built_slots() == 0 and drawn.drawn_slots() == 2,
		"a rider whose content is missing is drawn instead (%d built, %d drawn)"
			% [drawn.built_slots(), drawn.drawn_slots()]
	)

	remove_child(drawn)
	drawn.free()
	remove_child(rider)
	rider.free()


# --- The interface ---------------------------------------------------------
	_done()

func _test_interface() -> void:
	_section("the interface")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)

	var ui_config := DotUiConfig.new()
	ui_config.allow_pause = false

	var stack := DotScreenStack.new()
	stack.name = "Screens"
	stack.config = ui_config
	stack.load_layered_config = false
	stack.register_service = false
	stack.manage_mouse = false
	add_child(stack)
	stack.setup()

	var hud := HungryHud.new()
	hud.name = "Hud"
	hud.config = ui_config
	add_child(hud)
	hud.build(world, null, 1)
	hud.bind_stack(stack)

	_check(hud.mass_bar != null, "the HUD builds its widgets")
	_check(hud.minimap != null, "including a minimap")

	hud.refresh_leaderboard()
	_check(
		hud.leaderboard.row_count() == 1,
		"and a leaderboard with a row in it (%d)" % hud.leaderboard.row_count()
	)

	# The feed takes coloured fragments, which is all dot-ui knows about this game.
	hud.say("hello")
	hud.chat({"name": "Bo", "text": "hi"})
	hud.note(HungryEvents.Kind.DIED, {"first": 1, "second": 0, "extra": 0})
	_check(hud.feed.line_count() >= 3, "the feed takes lines (%d)" % hud.feed.line_count())

	var game_config := HungryConfig.new()
	var pause := HungryMenus.install(stack, world, null, ui_config, game_config)
	# Five, and it was six: chat left the stack when it became a `DotChatWindow`. A chat
	# box is eight lines in a corner that has to leave the game visible behind it, which is
	# a HUD widget rather than a modal screen.
	_check(
		stack.registered_ids().size() == 5,
		"five screens register (%d)" % stack.registered_ids().size()
	)

	# The loadout screen offers what the schema and this player's entitlements allow, and
	# nothing else. A screen that filtered on its own would drift from the server the
	# first time an unlock changed; one the server trusted would be a client choosing its
	# own stats.
	# The one readability affordance this genre cannot do without. Eating needs a ratio —
	# a quarter bigger — and a quarter of a difference in *area* is about 12% of a
	# difference in *width*, which nobody judges by eye under pressure. What the renderer
	# must not do is call something food that is merely smaller.
	var renderer := HungryRenderer.new()
	renderer.name = "Renderer"
	add_child(renderer)
	renderer.bind(world, null, 1)

	var rules := world.tunables.mass_rules
	var ours := 100.0

	_check(
		ours >= (ours / rules.eat_ratio - 1.0) * rules.eat_ratio,
		"something a quarter smaller is food"
	)
	_check(
		not (ours >= (ours * 0.9) * rules.eat_ratio),
		"and something merely smaller is not (%.2f ratio)" % rules.eat_ratio
	)
	_check(
		renderer.show_threat,
		"the rings are on by default, because judging it by eye is the failure mode"
	)

	remove_child(renderer)
	renderer.free()

	# The settings screen has no layout code: DotSettingsPanel reads the config's own
	# `@export` annotations and builds the editors from them, so a setting added to
	# HungryConfig appears there and nothing else changes.
	var settings := stack.screen(&"settings") as DotSettingsScreen
	_check(settings != null, "the settings screen registers")
	# dot-ui's screens rather than copies of them. This game carried its own pause menu and
	# its own settings screen for as long as `DotPauseScreen` and `DotSettingsScreen` have
	# existed, which is the duplication that addon was written to end.
	_check(pause is DotPauseScreen, "the pause screen is the shared one")
	_check(
		pause.ids() == ([&"resume", &"loadout", &"settings", &"controls", HungryMenus.LEAVE]
			as Array[StringName]),
		"and its ids come from its labels (%s)" % [pause.ids()]
	)
	# The button id IS the screen id for the three that open one, which is what makes the
	# match in `install` a lookup rather than a second table.
	for id in [&"loadout", &"settings", &"controls"]:
		_check(
			stack.screen(id) != null,
			"a button called %s opens a screen registered under that id" % id
		)

	if settings != null:
		_check(
			settings.panel != null and settings.panel.bound_config() is HungryConfig,
			"bound to this game's own config rather than the interface's"
		)
		_check(
			settings.panel != null and settings.panel.editor_for("volume_db") != null,
			"with an editor generated for a setting nobody laid out"
		)
		_check(
			settings.panel != null and settings.panel.editor_for("show_minimap") != null,
			"and for one of a different type"
		)

	# Settings survive a restart, which is the only reason to have them.
	var saved_path := "user://hungry_settings_test.json"
	DotPaths.remove_tree(saved_path)

	var chosen := HungryConfig.new()
	chosen.volume_db = -21.0
	chosen.muted = true
	chosen.show_names = false
	chosen.follow_sec = 0.25

	var written := chosen.save(saved_path)
	_check(written.ok, "settings write", str(written.error))

	var reloaded := HungryConfig.load_saved(saved_path)
	_check(
		is_equal_approx(reloaded.volume_db, -21.0) and reloaded.muted
			and not reloaded.show_names,
		"and come back (%s)" % reloaded.describe_summary()
	)

	# A first run has no file. That is not an error and must not read as one.
	var fresh := HungryConfig.load_saved("user://hungry_settings_missing.json")
	_check(
		is_equal_approx(fresh.volume_db, HungryConfig.new().volume_db),
		"a first run falls back to the defaults"
	)

	# A malformed one *is* an error, and starting from defaults silently would throw away
	# everything a player had set with nothing on screen to say so.
	var broken_path := "user://hungry_settings_broken.json"
	DotPaths.write_text(broken_path, "{ this is not json")
	var broken := HungryConfig.load_saved(broken_path)
	_check(
		broken != null and is_equal_approx(
			broken.volume_db, HungryConfig.new().volume_db
		),
		"and a broken file falls back rather than failing to start"
	)

	DotPaths.remove_tree(saved_path)
	DotPaths.remove_tree(broken_path)

	# Being eaten means having nothing at all — no pieces, no position, nowhere for a
	# camera to be. A camera left where you died is a black rectangle for three seconds
	# while the fight that killed you carries on somewhere else.
	world.add_player(2, "Bo")
	world.spawn(2, Vector2(300.0, 0.0))

	var me := world.monster_for(1)
	var them := world.monster_for(2)
	var watching := [0]

	var source := func() -> HungryMonster:
		var mine := world.monster_for(1)

		if mine != null and mine.alive:
			return mine

		var killer := world.monster_for(watching[0])
		return killer if killer != null and killer.alive else null

	_check(source.call() == me, "a living player watches themselves")

	for piece in me.pieces.duplicate():
		world.forget_piece(piece.id)

	watching[0] = 2

	_check(not me.alive, "and once eaten has nothing to watch from")
	_check(source.call() == them, "so they watch whoever ate them")

	hud.watching_source = source
	hud._refresh_status()
	_check(
		hud.status_label.text.contains(them.display_name),
		"and the HUD says whose eyes they are behind (%s)" % hud.status_label.text
	)

	var picker := stack.screen(&"loadout") as HungryMenus.LoadoutScreen
	_check(picker != null, "the loadout screen registers")

	if picker != null:
		var offered := picker.current()
		_check(
			offered.item_in(HungryContent.SLOT_TRAIT) != &"",
			"and offers a trait to a player who owns nothing (%s)"
				% offered.item_in(HungryContent.SLOT_TRAIT)
		)
		_check(
			offered.item_in(HungryContent.SLOT_TRAIT) != HungryContent.TRAIT_GREEDY,
			"but not the one nobody has unlocked"
		)
		_check(
			DotLoadoutValidator.validate(
				offered, HungryContent.loadout_schema(), DotLoadoutEntitlements.none()
			).ok,
			"and what it produces is legal"
		)

		picker.allow(DotLoadoutEntitlements.of([HungryContent.TRAIT_GREEDY_UNLOCK]))
		var greedy_offered := false

		for index in range(
			(picker._pickers[HungryContent.SLOT_TRAIT] as OptionButton).item_count
		):
			if StringName(str(
				(picker._pickers[HungryContent.SLOT_TRAIT] as OptionButton)
					.get_item_metadata(index)
			)) == HungryContent.TRAIT_GREEDY:
				greedy_offered = true

		_check(greedy_offered, "which appears once it is unlocked")

		var sent: Array[DotLoadout] = []
		picker.chosen.connect(func(l: DotLoadout) -> void: sent.append(l))
		picker._apply()
		_check(sent.size() == 1, "and taking it in emits the choice")

	# The scoreboard must not block input: it is held down during a live game, so it must
	# not stop the player moving. The pause menu must, and must hide the HUD.
	_check(stack.push(&"scoreboard").ok, "the scoreboard opens")
	_check(not stack.screen(&"scoreboard").blocks_input, "without blocking input")
	stack.pop(&"scoreboard")

	_check(stack.push(&"pause").ok, "the pause menu opens")
	_check(pause.blocks_input and pause.hides_below, "and does block, and hides the HUD")
	stack.pop(&"pause")

	# [b]Chat is no longer a screen on this stack.[/b] It was a modal `DotScreen` on Enter
	# with one line edit in it — the only chat box of its kind in the family, with no log,
	# no channels and no way to know whether anything else was carrying the conversation.
	# It is `DotChatWindow` now, tested in `headless_presentation` where the rest of the
	# client's interface is.
	_check(
		stack.screen(&"chat") == null,
		"chat is not a screen on the stack any more",
		"two chat boxes in one game is the shape this tree pays most for"
	)

	var chat := DotChatWindow.new()
	chat.register_actions = false
	add_child(chat)

	var said := [""]
	chat.submitted.connect(func(text: String, _c: StringName) -> void: said[0] = text)

	chat.open()
	_check(chat.is_open(), "the chat line opens")
	chat.entry().text = "  well then  "
	chat.entry().text_submitted.emit(chat.entry().text)
	_check(said[0] == "well then", "and submits trimmed text (%s)" % said[0])
	_check(not chat.is_open(), "and closes itself")
	chat.queue_free()

	# The on-screen buttons. Forced on, because a headless run has no touchscreen and a
	# control nothing exercises is a control that breaks quietly.
	var touch := HungryTouch.make()
	add_child(touch)

	var sampler := HungryInput.measuring(
		func() -> Variant: return world.monster_for(1), null
	)
	sampler.touch = touch
	add_child(sampler)

	_check(
		not sampler.sample().is_pressed(Dot2DCommand.BUTTON_SPLIT),
		"nothing is pressed to start with"
	)

	touch.split_button.button_down.emit()
	_check(
		sampler.sample().is_pressed(Dot2DCommand.BUTTON_SPLIT),
		"the split button reaches the command"
	)
	touch.split_button.button_up.emit()
	_check(
		not sampler.sample().is_pressed(Dot2DCommand.BUTTON_SPLIT),
		"and lets go again"
	)

	# The throw button is disabled with nothing to throw, and names what it will throw
	# when there is — throwing a lure at somebody chasing you is a wasted charge.
	_check(touch.throw_button.disabled, "the throw button is disabled while empty")
	touch.show_carried(PackedStringArray(["pepper"]))
	_check(not touch.throw_button.disabled, "and enabled once something is carried")
	_check(
		touch.throw_button.text.to_lower().contains("pepper"),
		"naming it (%s)" % touch.throw_button.text
	)

	touch.throw_button.button_down.emit()
	_check(
		sampler.sample().is_pressed(Dot2DCommand.BUTTON_ACTION),
		"and it reaches the command too"
	)
	touch.throw_button.button_up.emit()

	remove_child(sampler)
	sampler.free()
	remove_child(touch)
	touch.free()
	remove_child(hud)
	hud.free()
	remove_child(stack)
	stack.free()
	_drop(world)


# --- Sound -----------------------------------------------------------------

## Every noise this game makes is arithmetic, so all of it is checkable without a speaker.
##
## [b]That is the point of baking rather than streaming.[/b] A generator filling buffers on
## the main thread can only be judged by listening to it; a bank of streams built by a pure
## function is bytes, and bytes are something a headless run can assert about.
	_done()
func _test_sound() -> void:
	_section("sound")

	var blip := HungrySound.bake(520.0, 760.0, 0.07, 0.35, 0.0)

	_check(blip != null, "a voice bakes")
	_check(
		blip.format == AudioStreamWAV.FORMAT_16_BITS and not blip.stereo,
		"as 16-bit mono"
	)
	_check(
		blip.mix_rate == HungrySound.RATE,
		"at %d Hz (%d)" % [HungrySound.RATE, blip.mix_rate]
	)

	var frames := blip.data.size() / 2
	_check(
		absi(frames - int(0.07 * float(HungrySound.RATE))) <= 1,
		"of the length it was asked for (%d frames)" % frames
	)

	# Silence is what a synthesiser that does nothing produces, and it is indistinguishable
	# from one that works until somebody puts headphones on.
	var peak := 0

	for index in range(frames):
		var low := blip.data[index * 2]
		var high := blip.data[index * 2 + 1]
		var value := low | (high << 8)

		if value >= 32768:
			value -= 65536

		peak = maxi(peak, absi(value))

	_check(peak > 2000, "and is not silence (peak %d of 32767)" % peak)

	# Deterministic, because the noise comes from a hash rather than from randf. Two
	# machines produce byte-identical banks, which is what makes this checkable at all.
	var again := HungrySound.bake(520.0, 760.0, 0.07, 0.35, 0.0)
	_check(again.data == blip.data, "and the same arguments bake the same bytes")

	var noisy := HungrySound.bake(150.0, 60.0, 0.42, 0.55, 0.85)
	_check(noisy.data != blip.data, "while different ones do not")

	# The envelope has to end at silence or every cue clicks when it stops.
	var tail := noisy.data.size()
	_check(
		noisy.data[tail - 1] == 0 and noisy.data[tail - 2] == 0,
		"a voice ends at silence rather than clicking"
	)

	# Bigger food is lower. It is the one mapping nobody has to be taught.
	_check(
		HungrySound.food_pitch(0) > HungrySound.food_pitch(3),
		"and a crumb is pitched above a haunch (%.2f vs %.2f)" % [
			HungrySound.food_pitch(0), HungrySound.food_pitch(3)
		]
	)

	var bank := HungrySound.make()
	add_child(bank)
	bank.build()

	_check(
		bank.baked() == HungrySound.Cue.size(),
		"every cue has a voice (%d of %d)" % [bank.baked(), HungrySound.Cue.size()]
	)
	_check(bank.voices() == HungrySound.VOICES, "and there is a pool to play them in")

	# Playing must be safe with no audio device at all, which is what a headless server,
	# a CI run and a muted browser tab all are.
	bank.play(HungrySound.Cue.EAT, 1.2)
	bank.muted = true
	bank.play(HungrySound.Cue.DIE)
	_check(true, "and playing one without a device does not fail")

	remove_child(bank)
	bank.free()


# --- Ejecting --------------------------------------------------------------

## Spitting mass out, which is how a monster gets deliberately smaller.
##
## What it leaves is ordinary planted food, so it replicates, indexes and is eaten through
## the paths everything else already uses. What has to be true is that it costs something,
## that a small monster cannot do it, and that the ejector does not immediately swallow
## its own blob — which would make the whole thing a very expensive way to do nothing.
	_done()
func _test_ejecting() -> void:
	_section("ejecting")

	var world := _make_world()
	world.add_player(1, "Ada")
	_settle(world)
	world.spawn(1, Vector2.ZERO)

	var monster := world.monster_for(1)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)

	var small := Dot2DCommand.new()
	small.aim = Vector2.RIGHT
	small.reach = 600.0
	small.set_button(Dot2DCommand.BUTTON_EJECT, true)

	var release := Dot2DCommand.new()
	release.aim = Vector2.RIGHT
	release.reach = 600.0

	var planted_before := world.field.planted_count()
	world.tick({1: small})

	_check(
		world.field.planted_count() == planted_before,
		"a monster too small to eject does not"
	)
	_check(monster.ejected == 0, "and is not charged for it")

	monster.rider_piece().set_mass(400.0, world.tunables.mass_rules)
	world.tick({1: release})

	var mass_before := monster.mass()
	world.tick({1: small})

	_check(
		world.field.planted_count() > planted_before,
		"a big one leaves a blob behind (%d)" % world.field.planted_count()
	)
	_check(
		monster.mass() < mass_before,
		"and pays for it (%.0f -> %.0f)" % [mass_before, monster.mass()]
	)
	_check(monster.ejected == 1, "and it is counted")

	# Held down must not spray. Edge-triggered plus a cooldown, the same as splitting.
	var after_one := world.field.planted_count()
	world.tick({1: small})
	_check(
		world.field.planted_count() == after_one,
		"a held key does not eject again"
	)

	# The blob has to survive the tick it was made on. It lands beyond the ejector's own
	# eat radius, so the ejector does not swallow it immediately.
	world.tick({1: release})
	_check(
		world.field.planted_count() >= after_one,
		"and the ejector does not eat its own blob back on the spot"
	)

	# Somebody else can. That is the whole point of it being ordinary food.
	var blob := 0

	for grid_id in world.field.alive_ids():
		if HungryField.kind_of(grid_id) == HungryField.Kind.PLANTED:
			blob = grid_id

	_check(blob != 0, "the blob is in the field")
	_check(
		world.arena.grid.has(blob),
		"and in the grid, where an eat check will find it"
	)
	_check(
		is_equal_approx(
			world.field.mass_of(blob),
			HungryContent.FOOD_TIER_MASS[HungryContent.EJECT_TIER]
		),
		"worth less than it cost (%.0f of %.0f)" % [
			world.field.mass_of(blob), HungryContent.EJECT_MASS
		]
	)

	_drop(world)


# --- The loadout -----------------------------------------------------------

## What a player brings in, and the checks the server makes on it.
##
## [b]Every one of these is something a hostile or buggy client does.[/b] dot-loadout's
## whole reason to exist is that a dedicated server has no content and still has to
## decide whether the thing a client just sent is legal — so all of this is answered from
## ids, and if any of it ever needs a `load()`, that is the thing to push back on.
	_done()
func _test_loadout() -> void:
	_section("what a player brings in")

	var schema := HungryContent.loadout_schema()
	var valid := schema.validate()

	_check(valid.ok, "the loadout schema is legal", str(valid.error))

	var default_loadout := schema.default_loadout()
	_check(
		default_loadout.item_in(HungryContent.SLOT_STARTER) == HungryContent.ITEM_PEPPER,
		"and its default is something you can actually spawn with"
	)
	_check(
		default_loadout.item_in(HungryContent.SLOT_TRAIT) == HungryContent.TRAIT_NIMBLE,
		"with a trait"
	)

	# A schema whose own defaults are not legal is refused at startup, because conform
	# never fails and a player would otherwise be unable to spawn at all.
	var owns_nothing := DotLoadoutEntitlements.none()
	var default_ok := DotLoadoutValidator.validate(default_loadout, schema, owns_nothing)
	_check(
		default_ok.ok,
		"which a player who owns nothing may still take",
		str(default_ok.error)
	)

	# The three things a slot refuses, each for a different reason and each with a
	# different right answer in a loadout screen.
	var wrong_slot := DotLoadout.empty(schema.id)
	wrong_slot.set_item(HungryContent.SLOT_STARTER, HungryContent.TRAIT_STURDY)
	wrong_slot.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_NIMBLE)
	_check(
		not DotLoadoutValidator.validate(wrong_slot, schema, owns_nothing).ok,
		"a trait in the throwable slot is refused"
	)

	var no_such := DotLoadout.empty(schema.id)
	no_such.set_item(HungryContent.SLOT_STARTER, &"trebuchet")
	no_such.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_NIMBLE)
	_check(
		not DotLoadoutValidator.validate(no_such, schema, owns_nothing).ok,
		"and so is an item the catalogue has never heard of"
	)

	var unowned := DotLoadout.empty(schema.id)
	unowned.set_item(HungryContent.SLOT_STARTER, HungryContent.ITEM_PEPPER)
	unowned.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_GREEDY)
	_check(
		not DotLoadoutValidator.validate(unowned, schema, owns_nothing).ok,
		"and so is a trait nobody has unlocked"
	)

	# Granting it is what an unlock *is*. Entitlements default to nothing so that an
	# unwired server is wrong within thirty seconds rather than shipping a game where
	# every unlock is free — which nobody reports as a bug.
	var owner := DotLoadoutEntitlements.of([HungryContent.TRAIT_GREEDY_UNLOCK])
	_check(
		DotLoadoutValidator.validate(unowned, schema, owner).ok,
		"until they unlock it"
	)

	# Conform on the way out of a store, validate on the way in from a client. Retiring an
	# item or revoking an unlock makes a saved loadout invalid, and refusing it is a player
	# who has not logged in for a month loading into an error rather than into a slightly
	# different monster.
	var stale := unowned.duplicate_loadout()
	# conform never fails — it returns what it changed, not whether it worked. That is the
	# whole distinction: refusing here would be a player who cannot spawn.
	var changes := DotLoadoutValidator.conform(stale, schema, owns_nothing)
	_check(
		changes.size() > 0,
		"conform repairs one nobody owns any more (%d changes)" % changes.size()
	)
	_check(
		stale.item_in(HungryContent.SLOT_TRAIT) == HungryContent.TRAIT_NIMBLE,
		"back to the default trait (%s)" % stale.item_in(HungryContent.SLOT_TRAIT)
	)
	_check(
		DotLoadoutValidator.validate(stale, schema, owns_nothing).ok,
		"and what it produced is legal"
	)

	# The store key is padded, because DotLoadoutKey has a minimum length and the check
	# exists so a malformed key can never reach a filesystem path.
	_check(
		DotLoadoutKey.is_usable(HungryContent.loadout_key(7)),
		"a player key is usable (%s)" % HungryContent.loadout_key(7)
	)
	_check(not DotLoadoutKey.is_usable("7"), "and a bare id is not")

	# And the mechanical half: three traits that are three different games.
	var world := _make_world()
	world.add_player(1, "Nimble")
	world.add_player(2, "Sturdy")
	_settle(world)

	var nimble := world.monster_for(1)
	var sturdy := world.monster_for(2)

	var chosen := DotLoadout.empty(schema.id)
	chosen.set_item(HungryContent.SLOT_STARTER, HungryContent.ITEM_FROST)
	chosen.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_STURDY)
	sturdy.wear_loadout(chosen)

	world.spawn(1)
	world.spawn(2)

	_check(
		sturdy.mass() > nimble.mass(),
		"sturdy spawns bigger than nimble (%.1f vs %.1f)" % [
			sturdy.mass(), nimble.mass()
		]
	)
	_check(
		sturdy.speed_multiplier() < nimble.speed_multiplier(),
		"and slower (%.2f vs %.2f)" % [
			sturdy.speed_multiplier(), nimble.speed_multiplier()
		]
	)
	_check(
		sturdy.carried.size() == 1 and sturdy.carried[0] == HungryContent.ITEM_FROST,
		"holding what they chose (%s)"
			% (String(sturdy.carried[0]) if not sturdy.carried.is_empty() else "-")
	)

	# Greedy is worth more food rather than more mass, so it compounds instead of being a
	# flat head start.
	_check(
		HungryContent.trait_food(HungryContent.TRAIT_GREEDY) > 1.0
			and HungryContent.trait_food(HungryContent.TRAIT_NIMBLE) == 1.0,
		"and greedy is paid in food rather than in mass"
	)

	_drop(world)
	_done()

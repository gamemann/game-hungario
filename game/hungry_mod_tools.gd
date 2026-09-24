extends RefCounted

const HungryWorld := preload("hungry_world.gd")
const HungryMonster := preload("hungry_monster.gd")

## What dot-moderation's live tools mean in a 2D eating arena.
##
## [b]The subset is the honest one, and every refusal says why.[/b] What this game can do
## to a monster on the server alone, with the client simply following the snapshot, it
## does: put somebody back at a safe spawn, remove them from the round, move them, hand
## them an item, rename them. What changes how a monster MOVES it does through the state
## the client predicts. What it refuses is refused for a reason about the wire or the
## design, and `modtools` prints each:
##
## - [b]noclip, freeze and speed[/b] are dot-2d's [Dot2DAdminModifiers], kept per monster
##   in [member HungryMonster.admin] and written into every piece's replicated state, so
##   the owning client predicts them — `headless_net` holds a forced noclip through a rock
##   for a whole window without a correction, and shows the same move made the naive way
##   (skipping the rocks on the server only) being corrected. Noclip is the rocks not being
##   there, not the arena's edge; a freeze also stops a split, a throw and an eject.
## - [b]blind and beacon[/b] are about a SCREEN rather than a body: one flag each on
##   [HungryMonster] that `HungryPieceNet` replicates — the blind to its owner alone, the
##   beacon to everybody — and that the client draws. `HungryHud` blacks the owner's screen
##   out; `HungryRenderer` rings the monster on every screen and pings. The server decides;
##   nothing about either is a client's to choose.
## - [b]gravity[/b], because there is none in a top-down arena.
## - [b]god and buddha[/b], because being eaten is the whole game: a monster nothing can
##   eat breaks every round it is in rather than protecting one player.
## - [b]health and slap[/b], because a monster has mass, not health, and there is nothing
##   for either to act on.
##
## `world_fn` rather than a world, because a game change builds a new [HungryWorld] under
## a running module and a handler holding the old one would act on a freed arena.

static func handlers(world_fn: Callable) -> Dictionary:
	return {
		DotModTools.ACTION_NOCLIP: func(id: StringName, args: Dictionary) -> DotResult:
			var monster := _monster(world_fn.call(), id)
			if monster == null:
				return _absent(id)
			var on := bool(args["on"])
			_set_admin(monster, Dot2DAdminModifiers.noclip_bits(monster.admin, on))
			return DotResult.success(on),

		DotModTools.ACTION_FREEZE: func(id: StringName, args: Dictionary) -> DotResult:
			var monster := _monster(world_fn.call(), id)
			if monster == null:
				return _absent(id)
			var on := bool(args["on"])
			_set_admin(monster, Dot2DAdminModifiers.frozen_bits(monster.admin, on))
			return DotResult.success(on),

		DotModTools.ACTION_SPEED: func(id: StringName, args: Dictionary) -> DotResult:
			var monster := _monster(world_fn.call(), id)
			if monster == null:
				return _absent(id)
			var scale := float(args["scale"])
			if scale <= 0.0:
				return DotResult.fail(DotError.CODE_INVALID, "A multiplier has to be above zero.")
			_set_admin(monster, Dot2DAdminModifiers.speed_bits(monster.admin, scale))
			# The step it landed on, which is what the admin is told: speeds are a ladder
			# because only an index travels.
			return DotResult.success(Dot2DAdminModifiers.bits_speed(monster.admin)),

		DotModTools.ACTION_SLAY: func(id: StringName, _args: Dictionary) -> DotResult:
			var world: HungryWorld = world_fn.call()
			var monster := _monster(world, id)
			if monster == null:
				return _absent(id)
			if not monster.alive or monster.piece_count() == 0:
				return DotResult.fail(DotError.CODE_STATE, "They have already been eaten.")
			# Every piece devoured, which is the world's own death: the same signal and the
			# same respawn queue as a hunter taking the last one.
			for piece in monster.pieces.duplicate():
				var _gone := world.devour_piece(piece.id)
			return DotResult.success(null),

		DotModTools.ACTION_RESPAWN: func(id: StringName, _args: Dictionary) -> DotResult:
			var world: HungryWorld = world_fn.call()
			var monster := _monster(world, id)
			if monster == null:
				return _absent(id)
			# The queue first, or a player an admin put back is put back a second time a
			# moment later by the respawn the death had already scheduled.
			if world.match_node != null and world.match_node.respawns != null:
				world.match_node.respawns.cancel(String(id))
			world.spawn(int(String(id)))
			monster.alive = true
			return DotResult.success(null),

		DotModTools.ACTION_GIVE: func(id: StringName, args: Dictionary) -> DotResult:
			var world: HungryWorld = world_fn.call()
			var monster := _monster(world, id)
			if monster == null:
				return _absent(id)
			var item := StringName(str(args["item"]).strip_edges().to_lower())
			if world.items == null or not world.items.has(item):
				return DotResult.fail(DotError.CODE_INVALID, "There is no item called %s." % String(item),
					", ".join(item_ids(world_fn)))
			if not monster.take_item(item):
				return DotResult.fail(DotError.CODE_STATE, "Their hands are full.")
			return DotResult.success(item),

		DotModTools.ACTION_STRIP: func(id: StringName, _args: Dictionary) -> DotResult:
			var monster := _monster(world_fn.call(), id)
			if monster == null:
				return _absent(id)
			monster.carried.clear()
			return DotResult.success(null),

		DotModTools.ACTION_RENAME: func(id: StringName, args: Dictionary) -> DotResult:
			var monster := _monster(world_fn.call(), id)
			if monster == null:
				return _absent(id)
			monster.display_name = str(args["name"]).strip_edges().substr(0, 32)
			return DotResult.success(monster.display_name),

		DotModTools.ACTION_BLIND: func(id: StringName, args: Dictionary) -> DotResult:
			var monster := _monster(world_fn.call(), id)
			if monster == null:
				return _absent(id)
			# The screen and nothing else. A blinded monster still moves, eats and is
			# eaten; an admin who wants it to stop as well has freeze, and one verb that did
			# both would be a verb nobody could use for only the first.
			monster.blinded = bool(args["on"])
			return DotResult.success(monster.blinded),

		DotModTools.ACTION_BEACON: func(id: StringName, args: Dictionary) -> DotResult:
			var monster := _monster(world_fn.call(), id)
			if monster == null:
				return _absent(id)
			monster.beacon = bool(args["on"])
			return DotResult.success(monster.beacon),
	}


static func unsupported() -> Dictionary:
	return {
		DotModTools.ACTION_GRAVITY: "there is no gravity in a top-down arena",
		DotModTools.ACTION_GOD: "being eaten is the game; a monster nothing can eat breaks the round",
		DotModTools.ACTION_BUDDHA: "being eaten is the game; a monster nothing can eat breaks the round",
		DotModTools.ACTION_HEALTH: "a monster has mass, not health",
		DotModTools.ACTION_SLAP: "a monster has mass, not health, and a shove is a split",
		DotModTools.ACTION_BURN: "nothing here burns",
	}


## Toggles that outlive a respawn here, beyond dot-moderation's own god and buddha.
##
## [b]Blind and beacon are about the person, not the body.[/b] Noclip and freeze end with
## the monster's pieces because arriving in a fresh life frozen is the respawn broken; a
## player an admin blinded, or wanted the arena to watch, is still that player after they
## are eaten — and being eaten is exactly what a player being punished would otherwise
## use to end it, in a game where being eaten takes no effort at all.
const PERSIST_ON_RESPAWN: Array[String] = ["blind", "beacon"]


static func item_ids(world_fn: Callable) -> PackedStringArray:
	var out := PackedStringArray()
	var world: HungryWorld = world_fn.call()

	if world != null and world.items != null:
		for item in world.items.ids():
			out.append(String(item))

	return out


static func position_of(world_fn: Callable, id: StringName) -> Variant:
	var monster := _monster(world_fn.call(), id)
	return monster.centre() if monster != null and monster.piece_count() > 0 else null


## Every piece moves by the same offset, so a split monster arrives in the same shape.
static func teleport(world_fn: Callable, id: StringName, to: Variant) -> void:
	var monster := _monster(world_fn.call(), id)

	if monster == null or monster.piece_count() == 0 or not (to is Vector2):
		return

	var offset := (to as Vector2) - monster.centre()

	for piece in monster.pieces:
		piece.state.position += offset
		piece.state.velocity = Vector2.ZERO


## The monster's value, and every piece it has now — not only at the next tick, so the
## snapshot that goes out before it already carries the change.
static func _set_admin(monster: HungryMonster, bits: int) -> void:
	monster.admin = bits

	for piece in monster.pieces:
		Dot2DAdminModifiers.adopt(piece.state, bits)


static func _monster(world: HungryWorld, id: StringName) -> HungryMonster:
	if world == null or not String(id).is_valid_int():
		return null

	return world.monster_for(String(id).to_int())


static func _absent(id: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_STATE, "Player %s is not in the arena." % String(id))

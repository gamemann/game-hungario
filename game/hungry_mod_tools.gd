extends RefCounted

const HungryWorld := preload("hungry_world.gd")
const HungryMonster := preload("hungry_monster.gd")

## What dot-moderation's live tools mean in a 2D eating arena.
##
## [b]The subset is the honest one, and every refusal says why.[/b] What this game can do
## to a monster on the server alone, with the client simply following the snapshot, it
## does: put somebody back at a safe spawn, remove them from the round, move them, hand
## them an item, rename them. What it refuses is refused for a reason about the wire or the
## design, and `modtools` prints each:
##
## - [b]noclip, freeze, speed and gravity[/b] would be server-only changes to a PREDICTED
##   2D motor. dot-player-controller's first-person motor carries admin modifiers in its
##   replicated state so its clients predict them; `Dot2DMotor` has no such field, and a
##   server that moved a monster the owning client does not know about would rubber-band
##   it. Adding them there is the way in, and is not done here.
## - [b]god and buddha[/b], because being eaten is the whole game: a monster nothing can
##   eat breaks every round it is in rather than protecting one player.
## - [b]health and slap[/b], because a monster has mass, not health, and there is nothing
##   for either to act on.
##
## `world_fn` rather than a world, because a game change builds a new [HungryWorld] under
## a running module and a handler holding the old one would act on a freed arena.

static func handlers(world_fn: Callable) -> Dictionary:
	return {
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
	}


static func unsupported() -> Dictionary:
	var prediction := "the 2D motor carries no admin modifiers a client could predict, so it would rubber-band"
	return {
		DotModTools.ACTION_NOCLIP: prediction,
		DotModTools.ACTION_FREEZE: prediction,
		DotModTools.ACTION_SPEED: prediction,
		DotModTools.ACTION_GRAVITY: "there is no gravity in a top-down arena",
		DotModTools.ACTION_GOD: "being eaten is the game; a monster nothing can eat breaks the round",
		DotModTools.ACTION_BUDDHA: "being eaten is the game; a monster nothing can eat breaks the round",
		DotModTools.ACTION_HEALTH: "a monster has mass, not health",
		DotModTools.ACTION_SLAP: "a monster has mass, not health, and a shove is a split",
		DotModTools.ACTION_BURN: "nothing here burns",
		DotModTools.ACTION_BLIND: "the client draws no overlay a server could turn on",
		DotModTools.ACTION_BEACON: "the client draws no marker a server could turn on",
	}


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


static func _monster(world: HungryWorld, id: StringName) -> HungryMonster:
	if world == null or not String(id).is_valid_int():
		return null

	return world.monster_for(String(id).to_int())


static func _absent(id: StringName) -> DotResult:
	return DotResult.fail(DotError.CODE_STATE, "Player %s is not in the arena." % String(id))

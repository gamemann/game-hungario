extends SceneTree

const HungryCamera := preload("../game/client/hungry_camera.gd")
const HungryHud := preload("../game/client/hungry_hud.gd")
const HungryPreset := preload("../game/hungry_preset.gd")
const HungryRenderer := preload("../game/client/hungry_renderer.gd")
const HungryWorld := preload("../game/hungry_world.gd")

## Renders one of this game's modes to `screenshots/` so a person can look at the level.
##
## [b]`tools/screenshot_menus.gd` renders the SCREENS and nothing rendered the world.[/b]
## Every check this project has over a mode asserts a simulated value — where a monster
## ended up, how much food is alive, how wide a gap is — and a level that is the wrong
## scale, drawn in the wrong place or not drawn at all passes every one of them. This
## family has shipped a 0 x 0 `Control` twice and a black screen once for exactly that
## reason.
##
##     tools/screenshot_map.sh warrens
##     tools/screenshot_map.sh warrens --admin   # also a beacon, and a blind
##
## [b]Not `--headless`[/b]: that gives a null renderer and a 64 x 64 viewport, and every
## frame it saves is empty — which is worse than no screenshot because it looks like one.

const OUT_DIR := "res://screenshots"
const SETTLE := 4

var _world: HungryWorld = null
var _renderer: HungryRenderer = null
var _camera: HungryCamera = null
var _hud: HungryHud = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _finished := false

## Where the player is put, and whether [method _boot] has run. See [method _process].
var _stand_at := Vector2.INF
var _booted := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var wanted := &"warrens"
	# [b]Where the player stands, and what the files are called.[/b] The default spot is
	# the one every level so far has been looked at from; `--at=x,y` puts the player
	# somewhere a level's own feature is — the reef's lagoon is 632 units east of the
	# default and invisible from it, which is how this option came to exist — and
	# `--name=` keeps those framings from overwriting the default ones.
	var at := Vector2.INF
	var tag := ""
	var admin := false

	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--at="):
			var parts := argument.trim_prefix("--at=").split(",")

			if parts.size() == 2:
				at = Vector2(float(parts[0]), float(parts[1]))
		elif argument.begins_with("--name="):
			tag = "_" + argument.trim_prefix("--name=")
		elif argument == "--admin":
			admin = true
		elif not argument.begins_with("-"):
			wanted = StringName(argument)

	var preset := HungryPreset.for_id(wanted)

	_world = HungryWorld.new()
	_world.name = "World"
	_world.preset = preset
	_world.register_service = false
	_world.world_seed = 20260913
	root.add_child(_world)

	var built := _world.setup()

	if not built.ok:
		push_error(str(built.error))
		quit(1)
		return

	_stand_at = at

	# [b]Everything past this point waits for the first frame.[/b] `setup()` adds the
	# world's `DotMatch` as a child, and a node added from `SceneTree._initialize` does not
	# get `_ready` until the tree's first iteration — the root is not inside the tree yet —
	# so the match has built no scoreboard, and starting it, adding a player and ticking
	# died on four "Nonexistent function ... in base 'Nil'" errors at every startup. They
	# read like missing methods rather than like a node that had not started, and the
	# frames still came out because the world limped on without a match.
	# `tools/screenshot_menus.gd` seeds its monsters on the first frame for the same reason.

	# [b]Three framings, because the level is three different claims.[/b] The whole arena
	# says the shape reads; a player's own view says the scale does — a gate is only a gate
	# if it looks like one from where a player sits — and the grown view is the one that
	# says the mode still draws when the camera has zoomed out, which is the framing
	# nothing in this project had ever rendered.
	_shots = [
		{"name": "%s%s_arena" % [wanted, tag], "mass": 0.0, "whole": true},
		{"name": "%s%s_gate" % [wanted, tag], "mass": 0.0, "whole": false},
		{"name": "%s%s_grown" % [wanted, tag], "mass": preset.win_mass * 0.55, "whole": false},
		# The countdown before a mode-vote ballot, under the round clock, with the chat line
		# that announced it in the feed beside it — the two have to read as one thing and
		# neither may sit on the other.
		{"name": "%s%s_vote" % [wanted, tag], "mass": 0.0, "whole": false, "vote": true},
	]

	# An administrator's two marks, which are drawn and not simulated, so nothing but a
	# frame can say whether they read. The beacon frame has one beaconed monster on screen
	# and one far off it, so the ring, the ripple, the edge pointer and the minimap's ring
	# are all in one picture; the blind frame is this player's own screen, blacked out
	# under the HUD, which is the one frame where "the blind covers the viewport" means
	# anything at all — a headless viewport is 64 x 64.
	if admin:
		_shots.append({"name": "%s%s_beacon" % [wanted, tag], "mass": 0.0, "whole": false, "beacon": true})
		_shots.append({"name": "%s%s_blind" % [wanted, tag], "mass": 0.0, "whole": false, "blind": true})


## The half of the setup that needs the world's nodes to have had `_ready`: see the note
## at the end of [method _initialize].
func _boot() -> void:
	var at := _stand_at

	_world.start(0)

	# A player in it, THEN live, then put where the frame wants them. A world that has not
	# reached LIVE throws the arrangement away at the transition — and dot-match stays in
	# warmup until somebody has joined, so the loop that used to run first, with nobody in
	# the world, ran out its five seconds still in warmup; the tick after the player was
	# added was the reset, and it respawned them at a safe spawn. Every `--at` and every
	# default player's-view frame until 2026-09-24 was wherever that spawn liked (found
	# framing the warrens' den: `--at=640,0` and the default came out identical).
	_world.add_player(1, "Screenshot")

	for _i in range(_world.tick_rate * 5):
		if _world.match_node.is_live():
			break

		_world.tick({})

	_world.spawn(1, at if at != Vector2.INF
		else Vector2(0.0, _world.arena.bounds.size.y * 0.36))
	_world.tick({})

	_camera = HungryCamera.framing(
		func() -> Object: return _world.monster_for(1), _world.arena
	)
	root.add_child(_camera)
	_camera.make_current()

	_renderer = HungryRenderer.new()
	_renderer.name = "Renderer"
	root.add_child(_renderer)
	_renderer.bind(_world, _camera, 1)

	# The HUD, for the last frame only: the level frames are about the level. On a canvas
	# layer, as the client has it, or the camera would carry it off the screen.
	var layer := CanvasLayer.new()
	layer.name = "HudLayer"
	root.add_child(layer)
	_hud = HungryHud.new()
	_hud.name = "Hud"
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_hud)
	_hud.build(_world, null, 1)
	_hud.visible = false


func _process(_delta: float) -> bool:
	if _finished:
		return false

	# The first frame is the first moment every node added in `_initialize` has had
	# `_ready`, so it is spent booting rather than on a shot.
	if not _booted:
		_booted = true
		_boot()
		return false

	if _at >= _shots.size():
		_finished = true
		quit(0)
		return false

	var shot: Dictionary = _shots[_at]

	if _wait == SETTLE:
		var monster := _world.monster_for(1)

		if float(shot["mass"]) > 0.0 and monster != null:
			_world.feed_player(1, float(shot["mass"]) - monster.mass())

		if bool(shot["whole"]):
			# The whole arena in one frame. The rig frames a monster, so it is turned off
			# rather than fought with: a camera being smoothed toward a target is a camera
			# that is somewhere else on the frame that gets saved.
			_camera.zoom_with_size = false
			_camera.clamp_to_arena = false
			_camera.follow_sec = 0.0
			_camera.monster_source = Callable()
			# And the rig's anchor pinned to the middle, through the spectating seam. Setting
			# the camera's position alone is undone on the next frame by the rig following
			# its anchor, which is still wherever the player stands — and this frame only
			# ever came out centred because the anchor used to be at the origin, where the
			# arena's centre also is, while the four startup errors (see `_initialize`)
			# kept the player from existing. With a live match the player is put at 0.36 of the height and the
			# whole-arena frame came out cropped by a third.
			var middle := _world.arena.bounds.get_center()
			_camera.position_source = func() -> Variant: return middle
			_camera.global_position = middle

			var fit := (
				root.get_visible_rect().size / (_world.arena.bounds.size * 1.04)
			)
			_camera.zoom = Vector2(minf(fit.x, fit.y), minf(fit.x, fit.y))
		else:
			_camera.zoom_with_size = true
			_camera.clamp_to_arena = true
			_camera.monster_source = func() -> Object: return _world.monster_for(1)
			_camera.position_source = Callable()
			# The zoom snapped rather than eased. At `zoom_sec` 0.45 against four frames
			# the gate and grown frames both came out at whatever zoom the ease had reached
			# from the whole-arena one — nearly the same zoom, so the grown frame did not
			# show the zoomed-out view it exists to show.
			_camera.zoom_sec = 0.0

		if shot.has("vote"):
			_hud.visible = true
			# The client refreshes the board on its own cadence (`HungryClient`), not the
			# HUD, so without this the frame drew a board with its header and no rows.
			_hud.refresh_leaderboard()
			_hud.say("A vote for what plays next starts in 5s.", Color(0.62, 0.78, 1.0))
			_hud.vote_countdown(4, false)

		if shot.has("beacon"):
			_beacon_two()

		if shot.has("blind"):
			_hud.visible = true
			_world.monster_for(1).blinded = true
			# Straight to fully down: four settle frames are a sixth of the fade, and a frame
			# of a blind a quarter of the way down says nothing about the finished one.
			_hud.present_blind(1.0)

		_world.tick({})

	_wait -= 1

	if _wait > 0:
		_renderer.queue_redraw()
		return false

	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, shot["name"]]
	image.save_png(ProjectSettings.globalize_path(path))
	print("wrote %s (%d x %d)" % [path, image.get_width(), image.get_height()])

	_at += 1
	_wait = SETTLE
	return false


## Two more monsters, both beaconed: one beside the player, one in the far corner of the
## arena, which is off any player's screen and so is found by its edge pointer.
func _beacon_two() -> void:
	var me := _world.monster_for(1)

	if _world.monster_for(2) == null:
		_world.add_player(2, "Beaconed")
		_world.spawn(2, me.centre() + Vector2(360.0, -40.0))
		_world.add_player(3, "Far Away")
		_world.spawn(3, _world.arena.bounds.position + Vector2(160.0, 160.0))

	_world.monster_for(2).beacon = true
	_world.monster_for(3).beacon = true
	_hud.visible = true
	_hud.refresh_leaderboard()

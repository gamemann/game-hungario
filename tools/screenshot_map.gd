extends SceneTree

const HungryCamera := preload("../game/client/hungry_camera.gd")
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
##
## [b]Not `--headless`[/b]: that gives a null renderer and a 64 x 64 viewport, and every
## frame it saves is empty — which is worse than no screenshot because it looks like one.

const OUT_DIR := "res://screenshots"
const SETTLE := 4

var _world: HungryWorld = null
var _renderer: HungryRenderer = null
var _camera: HungryCamera = null
var _shots: Array[Dictionary] = []
var _at := 0
var _wait := SETTLE
var _finished := false


func _initialize() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var wanted := &"warrens"

	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("-"):
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

	_world.start(0)

	# Live, then a player in it. A world that has not reached LIVE throws the arrangement
	# away at the transition — the same trap every test in this project learned.
	for _i in range(_world.tick_rate * 5):
		if _world.match_node.is_live():
			break

		_world.tick({})

	_world.add_player(1, "Screenshot")
	_world.spawn(1, Vector2(0.0, _world.arena.bounds.size.y * 0.36))
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

	# [b]Three framings, because the level is three different claims.[/b] The whole arena
	# says the shape reads; a player's own view says the scale does — a gate is only a gate
	# if it looks like one from where a player sits — and the grown view is the one that
	# says the mode still draws when the camera has zoomed out, which is the framing
	# nothing in this project had ever rendered.
	_shots = [
		{"name": "%s_arena" % wanted, "mass": 0.0, "whole": true},
		{"name": "%s_gate" % wanted, "mass": 0.0, "whole": false},
		{"name": "%s_grown" % wanted, "mass": preset.win_mass * 0.55, "whole": false},
	]


func _process(_delta: float) -> bool:
	if _finished:
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
			_camera.global_position = _world.arena.bounds.get_center()

			var fit := (
				root.get_visible_rect().size / (_world.arena.bounds.size * 1.04)
			)
			_camera.zoom = Vector2(minf(fit.x, fit.y), minf(fit.x, fit.y))
		else:
			_camera.zoom_with_size = true
			_camera.clamp_to_arena = true
			_camera.monster_source = func() -> Object: return _world.monster_for(1)

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

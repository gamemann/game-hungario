@tool
extends DotHud

const HungryBeacon := preload("hungry_beacon.gd")
const HungryContent := preload("../hungry_content.gd")
const HungryEvents := preload("../net/hungry_events.gd")
const HungryField := preload("../hungry_field.gd")
const HungryMonster := preload("../hungry_monster.gd")
const HungryNetBridge := preload("../net/hungry_net_bridge.gd")
const HungryTouch := preload("hungry_touch.gd")
const HungryWorld := preload("../hungry_world.gd")

## Mass, the leaderboard, the clock, what you are carrying, the feed and a minimap.
##
## Every widget is a dot-ui class bound to a game value. dot-ui does not know what a
## monster is; it knows how to draw a bar from a [Callable], a table from rows of
## dictionaries and a feed from coloured fragments, which is all any of this needs.
##
## The one exception is the minimap, and it is the same exception game-blob found: a
## minimap is world-specific, and a [Control] per monster would be a hundred nodes created
## and freed every time somebody split.


var world: HungryWorld = null
var bridge: HungryNetBridge = null

## Whose monster this is.
var player_id: int = 0

## `func() -> HungryMonster`. Who the camera is actually looking at, which is somebody
## else while this player is dead. Optional; without it the status line just says dead.
var watching_source: Callable = Callable()

var mass_bar: DotStatBar = null
var leaderboard: DotTableView = null
var feed: DotFeedView = null
var clock_label: Label = null

## The countdown before a mode-vote ballot, directly under the round clock.
##
## [b]Not the feed, although the feed is where this game's notices go.[/b] The feed holds
## five lines, and a countdown is one line a second: a five-second one would push out the
## chat line announcing the vote, and whatever anybody said, and leave a column of
## numbers. One label that changes in place says the same thing and costs nothing else.
var vote_label: Label = null
var carry_label: Label = null
var status_label: Label = null
var minimap: Minimap = null

## The on-screen split and throw buttons, on a device that wants them.
var touch: HungryTouch = null

## An administrator's `blind`, over the arena and under the rest of the HUD.
##
## [b]Under the widgets, on purpose.[/b] A blind takes the game away, not the player's
## bearings: the clock, the feed, their own mass and the chat box still say the round is
## going on and that they are in it, which is what makes it read as "an admin did this"
## rather than as a client that stopped drawing. [b]The minimap is the exception and goes
## under it[/b]: it is the arena in miniature, every monster's position on one square, and
## a blind that left it showing would be a blind a player could play straight through.
##
## Black rather than white. A white screen at full brightness is a thing a player can be
## hurt by in a dark room, and taking the picture away is the whole of the point.
var blind_overlay: ColorRect = null

## Seconds a blind takes to come down and to lift. Short, so it is unmistakably on, and
## not instant, so it reads as something done to the screen rather than a frame dropped.
const BLIND_FADE_SEC := 0.25

const BLIND_COLOUR := Color(0.01, 0.01, 0.015)

## When [member vote_label] stops showing its last second, in [method Time.get_ticks_msec].
var _vote_until_msec: int = 0

## How long a countdown second stays up without the next one. Over a second, so a tick
## arriving a little late over the wire does not blink the line off between numbers.
const VOTE_LINGER_MSEC := 1500


## Everybody's position on one small rectangle.
##
## Drawn rather than composed: a dot per monster is a `_draw` call, and the alternative is
## a node per monster created and freed as they split, burst and die.
##
## [b]Food is deliberately not on it.[/b] Eleven hundred crumbs on a 180-pixel square is a
## grey smear that tells nobody anything, and it is eleven hundred draw calls a frame.
class Minimap extends Control:
	var world: HungryWorld = null
	var player_id: int = 0

	var background := Color(0.038, 0.045, 0.082, 0.78)
	var border := Color(0.30, 0.44, 0.72, 0.60)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(180.0, 180.0)

	func _process(_delta: float) -> void:
		if not Engine.is_editor_hint():
			queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), background)
		draw_rect(Rect2(Vector2.ZERO, size), border, false, 1.0)

		if world == null or world.arena == null:
			return

		var bounds := world.arena.bounds

		# Fruit, and only fruit. There are ten of them in a world of eleven hundred pieces
		# of food, they are worth going out of your way for, and ten dots is ten dots.
		# Drawing the food as well is a grey smear that tells nobody anything and eleven
		# hundred draw calls a frame.
		for grid_id in world.field.alive_ids():
			if HungryField.kind_of(grid_id) != HungryField.Kind.FRUIT:
				continue

			var at := world.field.position_of(grid_id)
			var local := Vector2(
				(at.x - bounds.position.x) / bounds.size.x,
				(at.y - bounds.position.y) / bounds.size.y
			) * size

			draw_circle(
				local, 2.0,
				HungryContent.FRUIT_COLOURS[int(world.field.fruit_kind_of(grid_id))]
			)

		for monster in world.monsters():
			if not monster.alive:
				continue

			var at := monster.centre()
			var local := Vector2(
				(at.x - bounds.position.x) / bounds.size.x,
				(at.y - bounds.position.y) / bounds.size.y
			) * size

			var dot := maxf(2.0, sqrt(monster.mass()) * 0.11)
			var colour := monster.colour

			if monster.id == player_id:
				colour = Color.WHITE
				dot = maxf(dot, 3.5)

			draw_circle(local, dot, colour)

			# An administrator's beacon, on the minimap as well as in the arena: the map is
			# where a player looks to find somebody, which is the beacon's whole job. A
			# ring that grows once a second, in the beacon's own colour.
			if monster.beacon:
				var t := fmod(Time.get_ticks_msec() / 1000.0, HungryBeacon.PERIOD_SEC) \
					/ HungryBeacon.PERIOD_SEC
				draw_arc(local, dot + 3.0 + 6.0 * t, 0.0, TAU, 20,
					Color(HungryBeacon.COLOUR, 1.0 - 0.7 * t), 2.0)

			# A split monster is drawn as a ring around its centroid, so a player can see
			# at a glance that the thing chasing them is in pieces.
			if monster.piece_count() > 1:
				draw_arc(
					local,
					clampf(monster.spread_radius() / bounds.size.x * size.x, 3.0, 40.0),
					0.0, TAU, 20, Color(colour.r, colour.g, colour.b, 0.5), 1.0
				)


func build(p_world: HungryWorld, p_bridge: HungryNetBridge, p_player_id: int) -> void:
	world = p_world
	bridge = p_bridge
	player_id = p_player_id

	# First, so every widget added below draws over it. See [member blind_overlay].
	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	# Not anchored to this HUD's rect: `DotHud` insets itself by the safe area, and a
	# blind the size of the HUD leaves a frame of the arena showing round the edge — which
	# game-arena's first rendered blind did. Sized to the whole viewport in
	# [method present_blind] instead.
	blind_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	add_child(blind_overlay)

	mass_bar = DotStatBar.new()
	mass_bar.name = "Mass"
	mass_bar.format = "%d"
	mass_bar.suffix = " mass"
	mass_bar.show_bar = true
	mass_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	mass_bar.offset_left = 20.0
	mass_bar.offset_top = -74.0
	mass_bar.offset_right = 300.0
	mass_bar.offset_bottom = -40.0
	mass_bar.ease_sec = 0.25
	add_child(mass_bar)
	mass_bar.bind(func() -> Variant:
		var monster := _me()
		return monster.mass() if monster != null else 0.0
	)
	mass_bar.max_source = func() -> Variant:
		return world.preset.win_mass if world != null and world.preset != null \
			else HungryContent.WIN_MASS

	carry_label = Label.new()
	carry_label.name = "Carrying"
	carry_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	carry_label.offset_left = 20.0
	carry_label.offset_top = -36.0
	carry_label.offset_right = 400.0
	carry_label.offset_bottom = -12.0
	carry_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(carry_label)

	leaderboard = DotTableView.new()
	leaderboard.name = "Leaderboard"
	leaderboard.max_rows = 10
	leaderboard.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	leaderboard.offset_left = -280.0
	leaderboard.offset_top = 16.0
	leaderboard.offset_right = -16.0
	leaderboard.offset_bottom = 280.0
	add_child(leaderboard)
	leaderboard.set_columns([
		{"key": &"rank", "title": "#", "width": 0.4, "align": HORIZONTAL_ALIGNMENT_RIGHT},
		{"key": &"name", "title": "Monster", "width": 3.0},
		{"key": &"mass", "title": "Mass", "align": HORIZONTAL_ALIGNMENT_RIGHT},
	])

	feed = DotFeedView.new()
	feed.name = "Feed"
	feed.alignment = HORIZONTAL_ALIGNMENT_LEFT
	feed.newest_last = true
	feed.set_anchors_preset(Control.PRESET_TOP_LEFT)
	feed.offset_left = 16.0
	feed.offset_top = 16.0
	feed.offset_right = 520.0
	feed.offset_bottom = 240.0
	add_child(feed)

	minimap = Minimap.new()
	minimap.name = "Minimap"
	minimap.world = world
	minimap.player_id = player_id
	minimap.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	minimap.offset_left = -200.0
	minimap.offset_top = -200.0
	minimap.offset_right = -20.0
	minimap.offset_bottom = -20.0
	add_child(minimap)
	# Under the blind, which is the first child. See [member blind_overlay].
	move_child(minimap, 0)

	clock_label = Label.new()
	clock_label.name = "Clock"
	clock_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	clock_label.offset_top = 10.0
	clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(clock_label)

	vote_label = Label.new()
	vote_label.name = "VoteCountdown"
	vote_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	# Offsets, because `set_anchors_preset` does not set them, and a centred label with
	# none is a zero-width column the text overflows out of to the right. Wide enough for
	# "Runoff in 3…" at any font this HUD uses, and under the clock rather than over it.
	vote_label.offset_left = -200.0
	vote_label.offset_right = 200.0
	vote_label.offset_top = 38.0
	vote_label.offset_bottom = 62.0
	vote_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vote_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vote_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.40))
	add_child(vote_label)

	if HungryTouch.wanted():
		touch = HungryTouch.make()
		add_child(touch)
		touch.apply_safe_area()

	status_label = Label.new()
	status_label.name = "Status"
	status_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	status_label.offset_top = -22.0
	status_label.offset_bottom = -4.0
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(status_label)


## Shows or hides the minimap. A player's setting.
func set_minimap_visible(shown: bool) -> void:
	if minimap != null:
		minimap.visible = shown


func follow(p_player_id: int) -> void:
	player_id = p_player_id

	if minimap != null:
		minimap.player_id = p_player_id


func _me() -> HungryMonster:
	return world.monster_for(player_id) if world != null else null


func _watched() -> HungryMonster:
	if not watching_source.is_valid():
		return null

	var value: Variant = watching_source.call()
	return value as HungryMonster if value is HungryMonster else null


# --- The feed --------------------------------------------------------------

func say(text: String, colour: Color = Color(0.88, 0.90, 0.94)) -> void:
	if feed != null:
		feed.add_text(text, colour)


## A chat line as dot-server delivered it.
##
## The payload is dot-server's and its shape is the server's business; everything read out
## of it is defaulted, because a server that sends a field this does not expect should
## produce a slightly plain line rather than an error.
func chat(payload: Dictionary) -> void:
	var who := String(payload.get("name", ""))
	var text := String(payload.get("text", ""))

	if text == "":
		return

	if who == "":
		say(text, Color(0.62, 0.78, 1.0))
		return

	feed.add_line([
		{"text": "%s: " % who, "colour": Color(0.72, 0.84, 1.0)},
		{"text": text, "colour": Color(0.92, 0.93, 0.95)},
	])


## Something happened to somebody. Driven from [signal HungryNetBridge.cue].
func note(kind: int, data: Dictionary) -> void:
	match kind:
		HungryEvents.Kind.DIED:
			feed.add_line([
				{"text": _name_of(int(data.get("second", 0))), "colour": Color(1.0, 0.85, 0.4)},
				{"text": " devoured ", "colour": Color(0.7, 0.72, 0.76)},
				{"text": _name_of(int(data.get("first", 0))), "colour": Color(0.95, 0.55, 0.5)},
			])

		HungryEvents.Kind.BURST:
			feed.add_line([
				{"text": _name_of(int(data.get("second", 0))), "colour": Color(1.0, 0.85, 0.4)},
				{"text": " burst ", "colour": Color(0.7, 0.72, 0.76)},
				{"text": _name_of(int(data.get("first", 0))), "colour": Color(0.95, 0.55, 0.5)},
				{"text": " into %d" % int(data.get("extra", 0)), "colour": Color(0.7, 0.72, 0.76)},
			])


func _name_of(id: int) -> String:
	var monster := world.monster_for(id) if world != null else null

	if monster != null:
		return monster.display_name

	return "somebody" if id == 0 else "Player %d" % id


## One second of the countdown before a mode-vote ballot. Driven from
## [signal HungryNetBridge.vote_cue_received].
func vote_countdown(seconds_left: int, runoff: bool) -> void:
	if vote_label == null:
		return

	vote_label.text = "%s in %d…" % ["Runoff" if runoff else "Mode vote", seconds_left]
	_vote_until_msec = Time.get_ticks_msec() + VOTE_LINGER_MSEC


# --- Refreshing ------------------------------------------------------------

## Rebuilds the leaderboard rows.
##
## Called on a timer rather than every frame: it rebuilds a table of [Label]s, and doing
## that sixty times a second to show ten numbers that change slowly is most of a frame's
## layout budget for no benefit.
func refresh_leaderboard() -> void:
	if leaderboard == null or world == null:
		return

	var rows: Array[Dictionary] = []
	var rank := 1

	# The authority's ranking when there is one: a client only knows about the monsters
	# interest management has told it about, so ranking locally would put whoever happens
	# to be nearby at the top of the board.
	var authoritative: Array = bridge.board if bridge != null else []

	if not authoritative.is_empty():
		for row in authoritative:
			var id := int((row as Dictionary).get("id", 0))
			rows.append({
				&"rank": rank,
				&"name": _name_of(id),
				&"mass": int((row as Dictionary).get("mass", 0)),
				"highlight": id == player_id,
				"colour": HungryContent.colour_for(id),
			})
			rank += 1
	else:
		for monster in world.leaderboard(10):
			rows.append({
				&"rank": rank,
				&"name": monster.display_name,
				&"mass": int(monster.mass()),
				"highlight": monster.id == player_id,
				"colour": monster.colour,
			})
			rank += 1

	leaderboard.set_rows(rows)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or world == null:
		return

	present_blind(delta)
	_refresh_clock()
	_refresh_vote()
	_refresh_carry()
	_refresh_status()


## Fades [member blind_overlay] toward whether this player is blinded.
##
## Read off the local monster rather than pushed by anybody, because the flag arrives in a
## snapshot on a networked client and is set directly offline, and a HUD that had to be
## told would need telling from two places. Public so a check can step it.
##
## [b]This player's, not the watched one's, and dead or alive.[/b] A blinded player who is
## eaten spectates somebody else, and a blind that lifted for that would be a blind any
## player could end by feeding themselves to the nearest monster.
func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var me := _me()
	var want := 1.0 if me != null and me.blinded else 0.0
	blind_overlay.modulate.a = move_toward(
		blind_overlay.modulate.a, want, maxf(delta, 0.0) / BLIND_FADE_SEC
	)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0

	if blind_overlay.visible and is_inside_tree():
		# The whole viewport, in this HUD's own coordinates — whatever the safe area and
		# the interface scale did to where this HUD starts.
		var inverse := get_global_transform().affine_inverse()
		blind_overlay.position = inverse * Vector2.ZERO
		blind_overlay.size = inverse.basis_xform(get_viewport_rect().size)


func _refresh_clock() -> void:
	if clock_label == null:
		return

	var behaviour := bridge.match_behaviour() if bridge != null else null
	var remaining := -1.0
	var state := ""

	if behaviour != null:
		remaining = behaviour.seconds_remaining(
			world.current_tick(), world.tick_rate
		)
		state = behaviour.state_name()
	elif world.match_node != null:
		remaining = world.match_node.seconds_remaining()
		state = String(DotMatch.State.keys()[world.match_node.state])

	clock_label.text = (
		state if remaining < 0.0
		else "%d:%02d" % [int(remaining) / 60, int(remaining) % 60]
	)


func _refresh_vote() -> void:
	if vote_label != null and vote_label.text != "" and Time.get_ticks_msec() > _vote_until_msec:
		vote_label.text = ""


func _refresh_carry() -> void:
	if carry_label == null:
		return

	var monster := _me()

	if monster == null or monster.carried.is_empty():
		carry_label.text = "carrying nothing"

		if touch != null:
			touch.show_carried(PackedStringArray())

		return

	var names := monster.carried_names()
	carry_label.text = "carrying  " + "  ".join(names)

	if touch != null:
		touch.show_carried(names)


func _refresh_status() -> void:
	if status_label == null:
		return

	var monster := _me()

	if monster == null:
		status_label.text = "joining…"
		return

	if not monster.alive:
		# Who they are watching, because a dead player staring at somebody else's monster
		# with no explanation reasonably concludes the game has broken.
		var watched := _watched()

		status_label.text = (
			"eaten — watching %s" % watched.display_name
			if watched != null and watched != monster
			else "eaten — respawning"
		)
		return

	if monster.piece_count() > 1:
		status_label.text = "%d pieces — let go of the mouse to gather" \
			% monster.piece_count()
		return

	status_label.text = ""


func describe() -> Dictionary:
	return {
		"player": player_id,
		"rows": leaderboard.row_count() if leaderboard != null else 0,
		"feed": feed.line_count() if feed != null else 0,
		"vote": vote_label.text if vote_label != null else "",
		"blind": blind_overlay.modulate.a if blind_overlay != null else 0.0,
		"touch": touch.describe() if touch != null else null,
	}

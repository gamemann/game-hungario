extends Node

const HungryContent := preload("../game/hungry_content.gd")
const HungryHunters := preload("../game/hungry_hunters.gd")
const HungryEvents := preload("../game/net/hungry_events.gd")
const HungryInterest := preload("../game/net/hungry_interest.gd")
const HungryModule := preload("../game/hungry_module.gd")
const HungryMonster := preload("../game/hungry_monster.gd")
const HungryNetLink := preload("../game/net/hungry_net_link.gd")
const HungryServices := preload("../game/hungry_services.gd")
const HungryWorld := preload("../game/hungry_world.gd")

## A real [DotServer] with the game loaded into it, listening for browser clients.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn            # self-test
## godot --headless --path . res://examples/dedicated.tscn -- --serve # run one
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The WebSocket listener is the point.[/b] A browser has no UDP and Godot's web
## template does not ship `ENetMultiplayerPeer` at all, so a server that expects browser
## clients listens on WebSocket — and then, today, [i]all[/i] of its clients do.
## [member DotTransportAuto.require_web_clients] defaults to true for exactly this reason,
## and this is the deployment shape it describes.
##
## It does not connect a client: [code]examples/sandbox.tscn[/code] does that, over a real
## socket, and repeating it here would test dot-server rather than this game.

const PORT := 27081
const SERVER_DIR := "user://hungry_dedicated"

## The app's URL segment on the website, which is this game's code name.
##
## Unique and lowercase because the site already made it so. Display only — a listing
## prints it to say which game this is, and nothing treats it as proof.
const APP_URL := "hungario"

const CHECKS := 200

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server: DotServer = null


func _ready() -> void:
	# Quiet by default so the checks are readable; `-- --verbose` when one of them
	# fails and the reason is in a log line rather than in the assertion.
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	var serving := "--serve" in OS.get_cmdline_user_args()

	print("game-hungario dedicated server")
	print("")

	var probe: Array = [] if serving or _is_exit_probe() else _run_exit_probe()

	if not serving:
		DotPaths.remove_tree(SERVER_DIR)

	var built := await _build(serving)

	if serving:
		if built:
			print("")
			print("listening on ws://0.0.0.0:%d — ctrl-c to stop" % PORT)
			for line in _server.status_lines():
				print("  %s" % line)
		return

	if built:
		_test_world()
		_test_module()
		_test_commands()
		await _test_bots()
		# Awaited, because it now suspends: it lowers the bot population and waits for the
		# module to notice. A suspending section called without `await` runs as far as its
		# first suspension and everything after it — including its own `_done()` — is
		# silently dropped, which is what the completion count at the end exists to catch
		# and did.
		await _test_loadouts()
		_test_reporting()
		await _test_stats()
		_test_netcode()
		_test_services()
		await _test_moderation()
		await _test_live_tools()
		_test_combat()
		_test_hunters()
		_test_hazards()
		await _test_progress()
		_test_query()
		_test_vote()
		await _test_game_change()
		_test_transport()
		_test_unload()
		_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	_teardown()
	DotPaths.remove_tree(SERVER_DIR)

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
	# announced itself. See docs/testing.md. This suite had only the counter until
	# 2026-09-24.
	#
	# The copy of this suite that the exit probe runs does not run the probe itself.
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, checks
		])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


## Sections entered, and sections that ran to their last line.
##
## [b]A check count is not coverage.[/b] A runtime error inside a section aborts that
## function and nothing says so: the checks that already ran still print ok, the ones
## after it never happen, and the total at the bottom cannot reveal a check that never
## ran. dot-net's demo carries the same pair, reached from the other direction — there it
## was a suspending section called without `await`.
var _entered := 0
var _completed := 0


## Opens a section. Pair with [method _done] on every path out of it.
## The server half of this game's own server browser.
##
## [b]`HungryBrowser` has existed for as long as this client has, and until now nothing in
## this repository could answer it.[/b] dot-browser's own suite queries a server dot-browser
## built; this is the first time a real `DotServer` running this game is asked, which by
## this family's repeated lesson is where the bugs are rather than in either half.
func _test_query() -> void:
	_section("the server browser's half")

	var module := _module()

	if module == null:
		_done()
		return

	_check(_server.query_source != null, "the server has a query source to contribute to")

	var snapshot := DotQuerySnapshot.new()

	for provider in module._query_providers:
		provider.call("_contribute", snapshot)

	_check(snapshot.game.has("mode"), "the query says which mode is being played")
	_check(snapshot.game.has("map"), "and what a player would call the map")
	_check(snapshot.game.has("state"), "and how far through the round it is")
	_check(
		String(snapshot.game.get("mode", "")) == String(_world().preset.id),
		"and the mode it names is the one that is running",
		str(snapshot.game.get("mode", ""))
	)
	# The two cvars that make this a different server. A list that cannot show them sends
	# somebody into a game about being hunted when they wanted a game about eating.
	_check(snapshot.game.has("hunters"), "and whether hunters are on")
	_check(
		int(snapshot.game.get("players", -1)) == module._joined.size(),
		"the player count is the module's own rather than a second tally",
		str(snapshot.game.get("players", -1))
	)

	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


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


## Waits for a condition, or gives up. Returns whether it happened.
##
## A deadline rather than a fixed number of frames. The module fills its bot population
## and ticks the world from `_physics_process`, so how many frames that takes depends on
## what else the machine is doing — and a check written as "twenty frames is surely
## enough" is a check that passes on an idle box and fails on a busy one, which is the
## worst kind because it looks like a real regression.
func _until(condition: Callable, seconds: float = 8.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return false


func _module() -> HungryModule:
	return _server.modules.get_module("hungry") as HungryModule


func _world() -> HungryWorld:
	return DotRegistry.get_node_service(HungryWorld.SERVICE) as HungryWorld


# --- Boot ------------------------------------------------------------------

func _build(serving: bool) -> bool:
	print("booting")

	var config := DotServerConfig.new()
	config.hostname = "hungry dedicated"
	config.port = PORT
	config.bind_address = "127.0.0.1" if not serving else "0.0.0.0"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	# The addon ships a default `server.cfg` that the search path would find, which is
	# correct layering and would make this test assert against whatever that file says.
	config.startup_config = ""
	config.autoexec_config = ""
	# The query listeners. On by default on a real server and named here so a suite that
	# stopped exercising them fails rather than skipping -- which is what this game did for
	# as long as it has shipped a server browser: `HungryBrowser` asks, and nothing here
	# had anything listening to answer.
	config.query_enabled = true
	config.query_port = PORT + 1

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	# Answering a query is its own addon, and a server only answers if a host is plugged
	# in. Added before boot() so the listener opens with everything else.
	var query_host := DotQueryHost.new()
	query_host.name = "QueryHost"
	query_host.app_url = APP_URL
	query_host.server_ref = DotNodeRef.of_path(NodePath("../Server"))
	add_child(query_host)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens on %d" % PORT, str(booted.error)):
		return false

	# Both modes are registered before the first one is loaded, because
	# [DotGameManager.change_game] can only change to a game it already knows about and
	# the module cannot load until there is a world for it to bind to.
	for descriptor in HungryModule.game_descriptors():
		_server.games.add_game(descriptor)

	var loaded: DotResult = await _server.games.change_game(
		HungryModule.GAME_CLASSIC, "boot"
	)

	if not _check(loaded.ok, "the classic mode loads", str(loaded.error)):
		return false

	# Into this run's own directory, which is deleted on the way in and out. The default is
	# the store a `--serve` of this same scene enforces, and a self-test gag written there
	# is a real record against a real (if made-up) uid.
	if not serving:
		HungryModule.punishments_path = "%s/punishments.json" % SERVER_DIR

	var module: DotResult = await _server.modules.load_module(
		"res://game/hungry_module.gd"
	)
	return _check(module.ok, "and the module loads into it", str(module.error))


func _teardown() -> void:
	if _server == null or not is_instance_valid(_server):
		return

	_server.shutdown("test over")
	remove_child(_server)

	# Freed rather than queued. A queue_free on the last line before `quit()` is a free
	# that never happens: the deferred call is dropped with the tree, and every node under
	# it — the module, its netcode manager, the loadout manager, the game scene — is
	# reported as leaked at exit. Which is true, and says nothing about a cycle.
	_server.free()


# --- The world -------------------------------------------------------------

func _test_world() -> void:
	_section("the world")

	var world := _world()

	_check(world != null, "the mode scene registered one")

	if world == null:
		_done()
		return

	_check(world.is_authority, "and it is the authority")
	_check(
		world.field.food_count() > 0,
		"with food in it (%d)" % world.field.food_count()
	)
	_check(
		String(world.preset.id) == "classic",
		"under the classic preset (%s)" % world.preset.id
	)
	_done()


func _test_module() -> void:
	_section("the module")

	_check(_server.modules.has_module("hungry"), "is listed among the server's modules")

	var module := _module()
	_check(module != null and module.world == _world(), "and holds the world")

	for command in [
		"hungry_status", "hungry_top", "hungry_net", "hungry_restart",
		"hungry_give", "hungry_burst", "hungry_loadouts",
	]:
		_check(
			_server.console.find_command(command) != null, "registered %s" % command
		)

	for cvar in ["hungry_bots", "hungry_avatar_pack"]:
		_check(_server.console.find_cvar(cvar) != null, "and its %s cvar" % cvar)

	# The cosmetics manifest is a cvar rather than a constant because a community server
	# may ship its own parts, and it reaches joining clients through the hello — a client
	# that had to be told out of band is a client that will not be.
	_check(
		module.bridge.avatar_pack_url == "",
		"with no rider content configured by default"
	)
	_check(
		_server.console.execute(
			"hungry_avatar_pack https://cdn.example/hungry/manifest.json"
		).ok,
		"setting one is accepted"
	)
	_check(
		module.bridge.avatar_pack_url == "https://cdn.example/hungry/manifest.json",
		"and reaches the bridge, which is what tells a client (%s)"
			% module.bridge.avatar_pack_url
	)
	_server.console.execute("hungry_avatar_pack \"\"")

	for game_id in [HungryModule.GAME_CLASSIC, HungryModule.GAME_FRENZY]:
		_check(
			_server.games.find_game(game_id) != null,
			"and the %s descriptor is registered" % game_id
		)
	_done()


func _test_commands() -> void:
	_section("its commands")

	for command in [
		"hungry_status", "hungry_top", "hungry_net", "hungry_restart",
		"hungry_loadouts",
	]:
		_check(_server.console.execute(command).ok, "%s runs" % command)

	# The cheat commands are gated by a permission rather than by a flag on the handler,
	# and a console context is trusted — so what is checked here is that they run, and
	# that their argument handling refuses rather than crashes.
	_check(
		_server.console.execute("hungry_give nobody pepper").ok,
		"hungry_give runs and reports a missing target"
	)
	_check(
		_server.console.execute("hungry_give").ok,
		"and with no arguments prints its usage"
	)
	_check(
		_server.console.execute("hungry_burst nobody").ok,
		"hungry_burst runs and reports a missing target"
	)


	_done()


# --- Statistics --------------------------------------------------------------

## What the module counts, and who it counts it for.
##
## The wiring is the part worth testing rather than dot-stats itself, which has
## its own suite: that the world's signals reach a tracker, that a player is
## keyed by their SCOPED id, and — the one that matters — that an account id can
## never be what a stat is filed under. This server has no dot-platform module,
## so nothing here has a scoped key and nothing is counted, which is exactly the
## case a LAN server is in and the one a wiring bug would hide behind.
func _test_stats() -> void:
	_section("statistics")

	var module := _module()

	_check(module.stats != null, "the module built a tracker")

	if module.stats == null:
		_done()
		return

	var schema := module.stats.schema

	_check(schema != null and schema.validate().ok, "its schema validates")
	_check(
		schema.find(&"top_mass") != null
			and schema.find(&"top_mass").kind == DotStatsDef.Kind.BEST,
		"a biggest-ever is a BEST, so shrinking does not lose the record"
	)
	_check(
		schema.find(&"mass_eaten") != null
			and schema.find(&"mass_eaten").kind == DotStatsDef.Kind.COUNTER,
		"and mass eaten is a counter"
	)
	_check(
		schema.published().size() == schema.size(),
		"every stat is published; this game counts nothing privately"
	)

	# No integration token in a test, so nothing reports — and the tracker still
	# counts, because the session figures are the game's own.
	_check(
		not module.stats.report_to_backbone,
		"reporting is off without a backbone to report through"
	)

	# The bots from the previous section are eating right now. None of them has a
	# scoped key, so none of them is counted: a bot is not a player, and a stat
	# filed for one would be filed under nothing.
	_check(
		module.stats.players().is_empty(),
		"bots are counted for nobody (%d)" % module.stats.players().size()
	)

	# The wiring, driven directly. A world signal has to reach the tracker for a
	# player it knows, and the merge has to be the stat's own.
	# Ids well past any real player, and POSITIVE: the same signals drive
	# replication, and dot-net's varint writer refuses a negative id outright.
	const ME := 900001
	const THEM := 900002

	var key := &"AAAAAAAAAAAAAAAAAAAAAA"
	module.stats.begin(key, "Test")
	module._stat_keys[ME] = key

	module.world.food_eaten.emit(ME, 0, 4.0)
	module.world.food_eaten.emit(ME, 1, 6.0)
	module.world.piece_eaten.emit(ME, THEM, 10.0)
	module.world.player_died.emit(THEM, ME)
	module.world.monster_burst.emit(THEM, ME, 3)

	var values := module.stats.session_values(key)

	_check(values.get_value(&"food") == 2.0, "eating food counts it")
	_check(
		values.get_value(&"mass_eaten") == 20.0,
		"and its mass adds across food and pieces (%.1f)" % values.get_value(&"mass_eaten")
	)
	_check(values.get_value(&"pieces_eaten") == 1.0, "eating a piece counts it")
	_check(values.get_value(&"kills") == 1.0, "a kill is credited to the killer")
	_check(values.get_value(&"bursts") == 1.0, "and a burst to whoever caused it")

	# A player who kills themselves is not credited with a kill.
	module.world.player_died.emit(ME, ME)
	_check(
		values.get_value(&"kills") == 1.0 and values.get_value(&"deaths") == 1.0,
		"but a self-kill is only a death"
	)

	# THE check. `_begin_stats` asks dot-platform for a SCOPED key and files
	# nothing without one; the account id the identity carries must never be what
	# a figure is filed under, and the reporter refuses one as a second line.
	_check(
		not DotStatsReporter.is_player_id("backbone:clx8f2k0000"),
		"an account id is refused as a player key"
	)
	_check(
		DotStatsReporter.is_player_id(String(key)),
		"and a scoped key is not"
	)

	module.stats.end(key)
	module._stat_keys.erase(ME)

	_check(
		not module.stats.has_player(key),
		"a player who leaves is forgotten"
	)

	_done()


# --- Bots ------------------------------------------------------------------

func _test_bots() -> void:
	_section("bots")

	var module := _module()
	var world := _world()

	_check(module.bot_count() == 0, "there are none to start with")

	var set_result := _server.console.execute("hungry_bots 4")
	_check(set_result.ok, "hungry_bots 4 is accepted")

	# The module fills the population from `_physics_process`, so this needs real frames.
	var filled := await _until(func() -> bool: return module.bot_count() == 4)

	_check(filled, "four appear (%d)" % module.bot_count())
	_check(
		world.monsters().size() >= 4,
		"and they are in the world (%d)" % world.monsters().size()
	)

	var alive := 0

	for monster in world.monsters():
		if monster.alive:
			alive += 1

	_check(alive == 4, "and alive (%d)" % alive)

	# A bot with no peer must not be registered as one. A peer id of zero is the broadcast
	# address, so a bot registered as a peer would make the server build a snapshot
	# against the bot's interest rectangle and send it to every real client.
	_check(
		not module.bridge.net.peers().has(0),
		"and none of them is registered as a peer"
	)

	var before := 0.0

	for monster in world.monsters():
		before = maxf(before, monster.mass())

	var grown := await _until(func() -> bool:
		for monster in world.monsters():
			if monster.mass() > before:
				return true

		return false
	, 12.0)

	_check(grown, "they play the game and grow")

	# Lowered at the end of the loadout section instead, so that section runs with several
	# bots in the world and can see that they do not all bring the same thing.
	_check(module.bot_count() == 4, "and the population holds (%d)" % module.bot_count())


## What players may bring in, and who decides.
##
## The store is memory-backed, which is the right default for a dedicated server: a
## loadout that outlives a session is a profile, and a profile is dot-user's. What is
## being checked here is the trust boundary rather than the storage — that a server with
## nothing wired grants nothing, and that the schema's own defaults are still takeable,
## because a schema whose defaults are not legal is a player who cannot spawn.
	_done()
func _test_loadouts() -> void:
	_section("loadouts")

	var module := _module()

	_check(module.loadouts != null, "the module runs a loadout manager")

	if module.loadouts == null:
		_done()
		return

	_check(
		module.loadouts.schema != null and module.loadouts.schema.validate().ok,
		"with a legal schema"
	)
	_check(
		DotRegistry.get_service(DotLoadoutManager.SERVICE) == module.loadouts,
		"registered where a loadout screen would look for it"
	)

	# Nothing, and deliberately. A server that granted everything by default would work
	# perfectly in every test, ship, and quietly be a game where every unlock is free —
	# and nobody reports that as a bug.
	var owned := module.loadouts.entitlements_for(HungryContent.loadout_key(1))
	_check(owned.count() == 0, "and grants nothing until something says otherwise")

	var default_loadout := module.loadouts.schema.default_loadout()
	_check(
		DotLoadoutValidator.validate(default_loadout, module.loadouts.schema, owned).ok,
		"while its own default is still takeable"
	)

	# The bots are in the world with a loadout, which is the only reason `hungry_loadouts`
	# has anything to print.
	var with_traits := 0

	for monster in _world().monsters():
		if monster.trait_id != &"":
			with_traits += 1

	_check(
		with_traits == _world().monsters().size(),
		"and everybody in the world has a trait (%d of %d)"
			% [with_traits, _world().monsters().size()]
	)

	# The bots take turns through the traits and the throwables, so that a server nobody
	# has joined still exercises the paths a human's choice takes — and so an operator
	# watching one can see the loadout doing something.
	var traits := {}
	var starters := {}

	for monster in _world().monsters():
		traits[monster.trait_id] = true
		starters[monster.starter_item()] = true

	_check(
		traits.size() > 1 or _world().monsters().size() < 2,
		"the bots do not all bring the same one (%d traits)" % traits.size()
	)
	_check(
		not traits.has(HungryContent.TRAIT_GREEDY),
		"and none of them takes the trait nobody has unlocked"
	)
	_check(
		starters.size() > 1 or _world().monsters().size() < 2,
		"nor the same throwable (%d)" % starters.size()
	)

	_check(
		_server.console.execute("hungry_bots 1").ok, "the population can be lowered"
	)

	var lowered := await _until(func() -> bool: return _module().bot_count() == 1)
	_check(lowered, "and it is (%d)" % _module().bot_count())
	_done()


## What this server tells its site listing.
##
## [b]Nothing is sent from here and nothing can be.[/b] Reporting needs an integration
## token, the token comes from a config file that does not exist in a test, and there is
## no backbone in this repository to send to — so what is checked is the shape of the
## report and the fact that an unconfigured server stays silent. The transport is
## dot-auth's and is covered there; the numbers are this game's and are covered here.
func _test_reporting() -> void:
	_section("what the listing is told")

	var module := _module()

	_check(
		module.backbone == null,
		"a server with no integration token is not listed"
	)
	_check(
		_server.console.find_cvar("hungry_backbone_config") != null,
		"and the token comes from a config file, never a cvar"
	)

	var report := module.stats_report()

	_check(bool(report.get("online", false)), "the report says the server is up")
	_check(
		int(report.get("maxUsers", 0)) > 0,
		"with a slot count (%d)" % int(report.get("maxUsers", 0))
	)

	# dot-server's own report says bots: 0 unconditionally, because dot-server has no bots
	# and no way to know a game has any. A listing that shows eight players on a server
	# holding one human is a listing that stops being trusted.
	_check(
		int(report.get("bots", -1)) == module.bot_count(),
		"and the bots this game actually has (%d)" % int(report.get("bots", -1))
	)
	_check(
		int(report.get("curUsers", -1)) == 0,
		"counted apart from the humans (%d)" % int(report.get("curUsers", -1))
	)

	# The mode rather than the content id: `hungry_frenzy` means something to somebody
	# reading a server browser.
	_check(
		String(report.get("map", "")) == String(_world().preset.id),
		"and the mode as the map (%s)" % str(report.get("map", ""))
	)

	_check(module.roster_report().is_empty(), "the roster is empty with nobody on")

	_done()


func _test_netcode() -> void:
	_section("the netcode")

	var module := _module()

	_check(module.net != null and module.net.is_running(), "a manager is running")
	_check(module.net.is_server, "as the server")
	_check(module.bridge != null, "with a bridge")

	# The RPC node has to sit where a client's will look for it. Godot addresses an RPC by
	# the receiver's path relative to its MultiplayerAPI root, so the name and the parent
	# are the routing.
	var link := _server.get_node_or_null(NodePath(String(HungryNetLink.NODE_NAME)))
	_check(link != null, "and its link is a child of the server node")
	_check(
		link is HungryNetLink,
		"named %s, which is what a client's link is named" % HungryNetLink.NODE_NAME
	)

	_check(
		module.net.interest is HungryInterest,
		"and this game's interest rule is in place"
	)
	_check(
		module.net.messages.count() >= 2,
		"and both message types are registered (%d)" % module.net.messages.count()
	)


# --- Changing the game -----------------------------------------------------
	_done()

func _test_game_change() -> void:
	_section("changing the game")

	# The id, NOT the node. Changing the game FREES the old world, so a lambda that
	# captured the object was calling with a freed capture by its second iteration:
	# GDScript substitutes null, `_world() != before` degenerates into
	# `_world() != null`, and the wait returns the instant ANY world exists rather
	# than when this one has been replaced. It printed
	# "Lambda capture at index 0 was freed" on every run and passed anyway.
	#
	# An int cannot be freed, so the wait now means what it says. Nothing in this
	# function may hold the old world across the change -- see the check below.
	var before_id := _world().get_instance_id()

	var changed: DotResult = await _server.games.change_game(
		HungryModule.GAME_FRENZY, "test"
	)

	_check(changed.ok, "the server changes to frenzy", str(changed.error))

	var replaced := await _until(func() -> bool:
		var now := _world()
		return now != null and now.get_instance_id() != before_id
	)

	_check(replaced, "and the world is replaced rather than merely present")

	# This is the check that fails if somebody captures the world again. It asserts
	# the thing that made the capture wrong: the old world really is freed, not
	# unregistered and left alive. If that ever stops being true this fails, and
	# whoever is here reads the comment above before reaching for `before`.
	_check(
		instance_from_id(before_id) == null,
		"and the old one is freed, not left alive and unregistered"
	)

	var after := _world()

	_check(
		after != null and after.get_instance_id() != before_id,
		"a new world is registered"
	)
	_check(
		after != null and String(after.preset.id) == "frenzy",
		"under the frenzy preset"
	)
	_check(
		_module().world == after,
		"and the module rebound onto it"
	)
	_check(
		_module().bridge.world == after,
		"and so did the bridge"
	)

	# The manager survives on purpose: rebuilding it would reset the message ids, the peer
	# records and the clock, which is a disconnect for everybody — precisely what changing
	# the map is supposed to avoid.
	_check(
		_module().net != null and _module().net.is_running(),
		"and the netcode manager survived the change"
	)

	await _until(func() -> bool:
		return after != null and after.field.food_count() > 0
	)

	_check(
		after != null and after.field.food_count() > 0,
		"the new world has its own field (%d)"
			% (after.field.food_count() if after != null else 0)
	)


# --- The browser -----------------------------------------------------------

## A browser client needs a WebSocket listener, and dot-core has to be able to make one on
## this build.
##
## Checked through [DotTransportWebSocket] rather than by booting a second server: what
## can go wrong is that the engine build has no WebSocket peer, and that is a property of
## the binary rather than of the configuration.
	_done()
## Chat, voice and the join between them.
func _test_services() -> void:
	_section("chat and voice")

	var module := _module()
	var services := module.services

	_check(services != null, "the services are up")
	_check(
		services.chat != null and services.chat.channel_ids().size() == 4,
		"with four chat channels (%d)"
			% (services.chat.channel_ids().size() if services.chat != null else -1)
	)
	_check(
		services.chat.channel(HungryServices.CHANNEL_NEAR).scope
			== DotChatChannel.Scope.RADIUS,
		"one of which is a radius, because an arena is bigger than a screen"
	)

	# [b]THE join.[/b] dot-chat consults a `dot_mute_source` and dot-moderation publishes
	# one, and neither imports the other — so the only thing that makes a gag work is that
	# something is registered under that name.
	_check(
		DotRegistry.has(DotModerationManager.MUTE_SERVICE),
		"a mute source is registered, which is the only thing that makes a gag work"
	)
	_check(
		DotRegistry.has(DotModerationManager.BAN_SERVICE),
		"and a ban source, which dot-server's admission check consults"
	)

	# [b]Proximity voice, which is where this game and the lobby part company.[/b] Hearing
	# somebody creeping up on you is information in an arena and noise in a room.
	_check(
		services.voice != null
			and services.voice.default_channel == DotVoiceRouter.Channel.PROXIMITY,
		"voice is proximity here rather than the whole server"
	)
	_check(
		services.voice.config.format_fingerprint()
			== HungryServices.voice_config().format_fingerprint(),
		"and its format is the one a client builds from the same file"
	)

	# dot-server's own chat is cancelled rather than run beside the router.
	var legacy := _server.events.fire("player_chat", {
		"userid": 1, "name": "Nobody", "text": "hello", "team_only": false,
	})
	_check(
		legacy.cancelled,
		"dot-server's own chat broadcast is cancelled, so there is exactly one path"
	)
	_done()


## A gag, written and read back.
func _test_moderation() -> void:
	_section("moderation")

	var services := _module().services
	var subject := DotPunishmentSubject.for_uid("uid-hungry-test")

	# [b]The store, and that it is empty before this run writes to it.[/b] The second is
	# what says the first worked on THIS run: a path that is right and a directory that was
	# not wiped is a suite carrying the last run's gag into this one.
	_check(services.punishments_path.begins_with(SERVER_DIR),
		"punishments go to this run's own store, not the one a real server enforces",
		services.punishments_path)
	_check(services.moderation.count() == 0,
		"and it starts empty, so nothing a previous run did is in it",
		"%d records" % services.moderation.count())

	var gagged: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, subject, "testing", "console", 60
	)
	_check(gagged.ok, "a gag is issued and stored", str(gagged.error))

	# [b]Round-tripped through the store, because the two ends of a serialisation are
	# exactly as capable of never meeting as the two ends of a wire.[/b] dot-moderation
	# shipped a voice mute that loaded back as a WARN, which enforces nothing — and the
	# one thing the addon exists for is a punishment surviving a reconnect.
	var reloaded := DotModerationManager.new()
	reloaded.store = DotPunishmentStoreFile.new(services.punishments_path)
	reloaded.register_mute_source = false
	reloaded.register_ban_source = false
	add_child(reloaded)
	reloaded.load_all()

	var found := reloaded.active_of_kind(subject, DotPunishment.Kind.GAG)
	_check(
		found != null and found.kind == DotPunishment.Kind.GAG,
		"and comes back off disk as a GAG rather than as a WARN"
	)

	var muted: DotResult = await services.moderation.issue(
		DotPunishment.Kind.VOICE_MUTE, subject, "testing", "console", 60
	)
	_check(muted.ok, "a voice mute is issued", str(muted.error))
	_check(
		services.moderation.is_voice_muted_key(subject),
		"and reads back as a voice mute rather than as a warning"
	)
	reloaded.queue_free()
	_done()


## dot-moderation's live tools, as an operator types them, against a monster that joined
## the way a client's does. The subset this game supports acts on the world; the rest is
## refused with the reason `HungryModTools` gives.
func _test_live_tools() -> void:
	_section("the moderator's live tools")

	_check(
		_server.console.find_command("slay") != null and _server.console.find_command("noclip") != null,
		"the live tools' commands are on the console"
	)

	var session := DotClientSession.new()
	session.peer_id = 3131
	session.userid = 313
	session.display_name = "Chomp"
	var _adopted := _server.adopt_session(session)
	_server.events.fire("client_spawn", {"userid": 313, "name": "Chomp"})

	var world := _world()
	var monster := world.monster_for(313)
	_check(monster != null, "a player joins as a monster")

	if monster == null:
		for what in ["slay", "respawn", "give", "noclip", "freeze", "speed", "clean", "refusal", "rename",
				"blind", "blind entity", "blind spell", "beacon", "beacon entity", "beacon kept",
				"beacon off", "modtools"]:
			_check(false, what)
		_done()
		return

	if monster.piece_count() == 0:
		world.spawn(313)
		monster.alive = true

	var slain := await _live("slay Chomp")
	_check(monster.piece_count() == 0 and not monster.alive,
		"`slay Chomp` devours every piece, the world's own death", " | ".join(slain))

	var back := await _live("respawn Chomp")
	_check(monster.piece_count() > 0 and monster.alive,
		"`respawn Chomp` puts them back at a safe spawn", " | ".join(back))

	var item := String(world.items.ids()[0]) if world.items != null and not world.items.ids().is_empty() else "pepper"
	monster.carried.clear()
	var given := await _live("give Chomp %s" % item)
	_check(monster.carried.has(StringName(item)), "`give Chomp %s` puts it in their hands" % item,
		" | ".join(given))

	# Noclip, freeze and speed are dot-2d's admin modifiers now: on the monster, and in every
	# piece's replicated state, which is what the owning client predicts. `headless_net` is
	# where the prediction itself is measured; this is the console reaching it.
	var clipped := await _live("noclip Chomp")
	_check(
		Dot2DAdminModifiers.bits_noclip(monster.admin)
			and monster.pieces.all(func(p: Variant) -> bool: return Dot2DAdminModifiers.is_noclipped(p.state)),
		"`noclip Chomp` reaches the monster and every piece's state", " | ".join(clipped))

	var held := await _live("freeze Chomp")
	_check(
		Dot2DAdminModifiers.bits_frozen(monster.admin)
			and monster.pieces.all(func(p: Variant) -> bool: return Dot2DAdminModifiers.is_frozen(p.state)),
		"`freeze Chomp` holds every piece", " | ".join(held))

	var quick := await _live("speed Chomp 2.2")
	_check(
		is_equal_approx(Dot2DAdminModifiers.bits_speed(monster.admin), 2.0)
			and _said_any(quick, "2×") and not _said_any(quick, "2.2"),
		"`speed Chomp 2.2` lands on the 2x step, and says so", " | ".join(quick))

	# A respawn is a new body: dot-moderation switches noclip and freeze off through the
	# handlers, off HungryWorld.player_spawned. Without that hook the bits would ride the
	# monster — which outlives its pieces — into the next life.
	var _again := await _live("respawn Chomp")
	_check(
		not Dot2DAdminModifiers.bits_noclip(monster.admin)
			and not Dot2DAdminModifiers.bits_frozen(monster.admin)
			and monster.pieces.all(func(p: Variant) -> bool: return (p.state as Dot2DState).admin == 0),
		"and a respawn arrives clean: no noclip, no freeze, normal speed",
		str(Dot2DAdminModifiers.words(monster.admin)))

	# Blind and beacon: two flags on the monster, carried on every piece's entity — the
	# blind to its owner alone, the beacon to everybody. Who receives which is
	# `headless_net`'s; what they look like is `headless_presentation`'s and
	# `tools/screenshot_map.sh`'s. This is the console reaching the entity the netcode sends.
	var dark := await _live("blind Chomp")
	_check(monster.blinded, "`blind Chomp` blacks their screen out", " | ".join(dark))
	_check(
		await _until(func() -> bool: return _pieces_carry(monster, "net_blind", true)),
		"and it is on every piece's entity the netcode sends them"
	)

	# A blind is a spell. dot-moderation lifts it through the same handler when the time is
	# up, so what is checked is the flag, not the timer.
	var _lift := await _live("blind Chomp off")
	var spell := await _live("blind Chomp 0.2")
	var was_on := monster.blinded
	await get_tree().create_timer(0.4).timeout
	_check(was_on and not monster.blinded, "`blind Chomp 0.2` lifts on its own when the time is up",
		" | ".join(spell))

	var lit := await _live("beacon Chomp")
	_check(monster.beacon, "`beacon Chomp` marks them on every screen", " | ".join(lit))
	_check(
		await _until(func() -> bool: return _pieces_carry(monster, "net_beacon", true)),
		"and every piece of a beaconed monster is relevant to everybody, however far away"
	)

	# Both are about the person, not the body: being eaten is what a player being punished
	# would otherwise use to end one, and in this game that takes no effort at all.
	var _dark_again := await _live("blind Chomp")
	var _eaten := await _live("slay Chomp")
	var _reborn := await _live("respawn Chomp")
	_check(
		monster.alive and monster.blinded and monster.beacon,
		"a respawn keeps blind and beacon, where it ends a noclip and a freeze"
	)

	var _dark_off := await _live("blind Chomp off")
	var _unlit := await _live("beacon Chomp off")
	_check(
		await _until(func() -> bool: return _pieces_carry(monster, "net_beacon", false))
			and not monster.blinded and not monster.beacon,
		"`beacon Chomp off` puts them back under the ordinary interest rules"
	)

	var listed := await _live("modtools")
	_check(
		_said_any(listed, "blind") and _said_any(listed, "beacon")
			and not _said_any(listed, "draws no"),
		"`modtools` lists blind and beacon as supported, and no longer refuses them",
		" | ".join(listed)
	)

	var refused := await _live("god Chomp")
	_check(_said_any(refused, "being eaten"), "`god` is refused, and says being eaten is the game",
		" | ".join(refused))

	var _renamed := await _live("rename Chomp Nibbles")
	_check(monster.display_name == "Nibbles" and session.display_name == "Nibbles",
		"`rename` reaches the monster and the session")

	var _released := _server.release_session(session.peer_id)
	_done()


## Whether every piece of [param monster] has [param property] at [param want] on the
## entity the netcode sends — and, for the beacon, whether each is always relevant to match,
## because the two are one decision and a beacon without the relevance fails far away.
func _pieces_carry(monster: HungryMonster, property: String, want: bool) -> bool:
	if monster.piece_count() == 0:
		return false

	for piece in monster.pieces:
		if piece.net == null or bool(piece.net.get(property)) != want:
			return false

		if property == "net_beacon":
			var identity := piece.net.get("identity") as DotNetIdentity
			if identity == null or identity.always_relevant != want:
				return false

	return true


func _live(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server.console.execute(line, context)
	await get_tree().process_frame
	await get_tree().process_frame
	return PackedStringArray(captured)


func _said_any(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true
	return false


## What a throwable does, through dot-combat rather than through a constant.
func _test_combat() -> void:
	_section("combat")

	var combat := _module().combat

	_check(combat != null, "the combat rules are up")
	_check(
		_module().world.damage_gate.is_valid(),
		"and the world asks them before a throwable does anything"
	)

	# Point blank against maximum range. [b]The whole reason falloff is worth having[/b]:
	# a pepper thrown across the arena has to be worth less than one thrown in somebody's
	# face, or throwing is a button rather than a decision.
	var close := combat.resolve_throw(1, 2, HungryContent.ITEM_PEPPER, 10.0)
	var far := combat.resolve_throw(1, 2, HungryContent.ITEM_PEPPER, 5000.0)

	_check(close != null and not close.refused, "a point-blank hit lands")
	_check(
		close != null and far != null and far.amount < close.amount,
		"and one from across the arena does less (%.0f against %.0f)"
			% [far.amount if far != null else -1.0, close.amount if close != null else -1.0]
	)
	_check(
		combat.pieces_for(close) > combat.pieces_for(far),
		"which is fewer pieces (%d against %d)"
			% [combat.pieces_for(close), combat.pieces_for(far)]
	)

	# [b]Self damage is off, and a monster bursting itself is the world's own eject.[/b] A
	# scaled self hit would be a second, worse way to do a thing this game already has.
	var own := combat.resolve_throw(1, 1, HungryContent.ITEM_PEPPER, 10.0)
	_check(own != null and own.refused, "throwing at yourself is refused, not scaled")

	# An item the combat layer has no type for passes through untouched. Refusing it would
	# silently disable a throwable by installing an addon.
	var lure := combat.gate(1, 2, HungryContent.ITEM_LURE, 100.0)
	_check(
		bool(lure.get("allowed", false)),
		"a lure is not combat and is left alone"
	)
	_done()


## The NPC monsters, and the director that decides when they arrive.
func _test_hunters() -> void:
	_section("hunters")

	var hunters := _module().hunters

	_check(hunters != null, "the hunter layer is up")
	_check(
		hunters.spawner != null and hunters.spawner.two_dimensional,
		"and its spawner knows the world is 2D"
	)
	_check(
		not hunters.is_enabled(),
		"with the director off by default",
		"a mode about eating food and a mode about being hunted are different games"
	)

	# The wire order has to be stable and has to be sorted as String — `Array.sort()` on a
	# StringName compares interned pointers, and dot-net shipped exactly that bug.
	var ids := HungryHunters.wire_ids()
	var sorted := ids.duplicate()
	sorted.sort()
	_check(
		Array(ids) == Array(sorted),
		"the wire order is lexicographic, not interned-pointer order"
	)
	_check(
		HungryHunters.id_at(HungryHunters.index_of(&"stalker")) == &"stalker",
		"and an id round-trips through its index"
	)

	# [b]The plane, which is the whole of the 2D mapping.[/b] Get it wrong and a sight
	# range of 1400 is a sight range of nothing, silently.
	_check(
		DotNpcInstance.from_plane(DotNpcInstance.to_plane(Vector2(3.0, -7.0)))
			== Vector2(3.0, -7.0),
		"a 2D point round-trips through dot-npc's plane"
	)

	_server.console.execute("hungry_hunters on")
	_check(hunters.is_enabled(), "the console turns them on")

	# The director needs somebody to be stressed about before it releases anything.
	var world := _module().world
	world.add_player(4242, "Bait")
	world.spawn(4242)

	for _step in range(240):
		hunters.tick(1.0 / 60.0)

	_check(
		hunters.count() > 0,
		"and the director releases some (%d)" % hunters.count()
	)

	var kinds: Dictionary = {}

	for state in hunters.hunters().values():
		kinds[(state as Dictionary)["kind"]] = true

	_check(
		kinds.size() >= 1,
		"of the kinds in its population list (%s)" % str(kinds.keys())
	)

	# The candidate has to be a monster rather than a piece: a hunter chasing one fragment
	# of a split player walks past the other seven.
	_check(
		hunters.position_of(&"p4242") != Vector3.INF,
		"a player resolves as a candidate"
	)
	_check(
		hunters.position_of(&"p999999") == Vector3.INF,
		"and somebody who has gone resolves as INF rather than as the origin",
		"zero is the middle of the arena, so a hunter whose target left would sprint "
		+ "to the centre and mill about — which reads as a pathfinding bug"
	)

	_server.console.execute("hungry_hunters off")
	_check(hunters.count() == 0, "turning them off clears the arena")

	world.remove_player(4242)
	_done()


## Rocks, spikes and lures.
func _test_hazards() -> void:
	_section("hazards")

	var hazards := _module().hazards

	_check(hazards != null, "the hazard layer is up")

	var placed := hazards.place(0, &"rock", Vector2(200.0, 200.0))
	_check(placed.ok, "a rock goes down", str(placed.error))
	_check(hazards.count() == 1, "and the arena has one thing in it")
	_check(
		hazards.obstacles().size() == 1,
		"which is an obstacle both ends resolve against"
	)

	# A lure is a prop and is not an obstacle. The field is read rather than assumed:
	# dot-props' own sweep found two documented limits that limited nothing.
	var lure := hazards.place(0, &"lure", Vector2(-200.0, 0.0))
	_check(lure.ok, "a lure goes down too", str(lure.error))
	_check(
		hazards.obstacles().size() == 1,
		"and is NOT an obstacle (%d solid of %d placed)"
			% [hazards.obstacles().size(), hazards.count()]
	)
	_check(hazards.lures().size() == 1, "but it is a lure")

	# [b]Deterministic, because a round has to be reproducible.[/b] `randf()` here would
	# make two runs of the same seed lay out two different arenas, and the whole reason
	# `headless_round` can assert anything is that it does not.
	hazards.clear_all()
	var first := hazards.scatter(&"rock", 6, 4242)
	var layout: Array = []

	for entry in hazards.placements().values():
		layout.append((entry as Dictionary)["at"])

	hazards.clear_all()
	hazards.scatter(&"rock", 6, 4242)
	var again: Array = []

	for entry in hazards.placements().values():
		again.append((entry as Dictionary)["at"])

	layout.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	again.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)

	_check(first == 6, "a scatter places what it was asked for (%d)" % first)
	_check(
		layout == again,
		"and the same seed lays out the same arena twice"
	)

	hazards.clear_all()
	_check(hazards.count() == 0, "a clear empties it")
	_done()


## Boards and achievements over the numbers this game already counts.
func _test_progress() -> void:
	_section("boards and achievements")

	var progress := _module().progress

	_check(progress != null, "the progress layer is up")
	_check(
		progress.boards != null and progress.boards.definitions().size() == 3,
		"with three boards (%d)"
			% (progress.boards.definitions().size() if progress.boards != null else -1)
	)
	_check(
		progress.achievements != null and progress.achievements.catalogue.size() >= 8,
		"and a catalogue of achievements (%d)"
			% (progress.achievements.catalogue.size() if progress.achievements != null else -1)
	)

	# [b]Every stat an achievement watches has to be one the game reports.[/b] An
	# achievement watching a stat nothing records never unlocks, nothing errors, and the
	# only symptom is a player who did the thing and was not told — this family's most
	# repeated bug wearing a rosette.
	var schema := HungryModule.stats_schema()
	var missing := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not schema.has(stat) and stat != &"hunted":
			missing.append(String(stat))

	_check(
		missing.is_empty(),
		"every watched stat is one the game declares",
		"missing: %s" % str(missing)
	)

	var problems := progress.achievements.catalogue.validate()
	_check(problems.ok, "the catalogue validates", str(problems.error))

	# The link is the whole integration and it is a signal connection.
	_check(progress.link != null, "the stats link is wired")

	# **A key that is different every run, and it is not a nicety.**
	#
	# `DotAchievementStoreFile` writes to `user://`, which survives the process — so a
	# fixed key accumulates across every run of this suite, and the 120 bites below add
	# to the last run's total rather than starting from nothing. The first tier keeps
	# unlocking and the "and not the second" check passes for about eight runs and then
	# fails for ever, on a machine where nothing has changed. It is the family's
	# "a test that passes for the wrong reason" with the sign flipped: a test that
	# eventually fails for a reason that has nothing to do with the code.
	#
	# Clearing the directory instead would be a suite deleting a player's progress,
	# which is the one thing this system must never do by accident.
	var player := "test-player-%d" % Time.get_ticks_usec()

	progress.begin(player)

	for _bite in range(120):
		progress.achievements.record(player, &"food", 1.0)

	_check(
		progress.achievements.is_unlocked(player, &"eat_100"),
		"a hundred bites unlocks the first tier"
	)
	_check(
		not progress.achievements.is_unlocked(player, &"eat_1000"),
		"and not the second"
	)

	# A board, and the PENALTY ordering — the half of `beats()` a SCORE board never runs.
	var monster := HungryMonster.new()
	monster.id = 7
	monster.display_name = "Tester"
	monster.best_mass = 4200.0
	monster.players_eaten = 3

	progress.file_round(player, monster, 2)
	progress.file_round(player, monster, 5)

	var deaths := progress.page(&"fewest_deaths", 5)
	_check(deaths.size() == 1, "a board holds one entry per player (%d)" % deaths.size())
	_check(
		deaths.size() == 1 and is_equal_approx((deaths[0] as DotLeaderboardEntry).value, 2.0),
		"and keeps the BETTER of two rounds, which on a penalty board is the lower",
		"%.0f" % ((deaths[0] as DotLeaderboardEntry).value if deaths.size() == 1 else -1.0)
	)

	var progressed: DotResult = await progress.achievements.flush()
	_check(progressed.ok, "progress writes to disk", str(progressed.error))
	_done()


## What plays next, and who decides.
func _test_vote() -> void:
	_section("the vote")

	var maps := _module().maps

	_check(maps != null, "the map rotation is up")
	# [b]Counted against the descriptor list rather than against a literal.[/b] The
	# catalogue is BUILT from `HungryModule.game_descriptors` precisely so that adding a
	# mode does not mean editing a second list; a check that restated the number would be
	# the third copy, and it is the copy that goes stale — this one said "four" the night
	# `reef` became the fifth.
	var modes := HungryModule.game_descriptors().size()

	_check(
		maps.catalogue != null and maps.catalogue.size() == modes,
		"with every one of the game's modes in the catalogue (%d of %d)"
			% [maps.catalogue.size() if maps.catalogue != null else -1, modes]
	)
	_check(
		maps.director != null and maps.director.source != null
			and maps.director.source.is_usable(),
		"and a vote source over dot-server's own games",
		"what a vote applies has to be the thing that actually changes the game"
	)

	# [b]`gauntlet` is off the ballot below three players, and that is what a catalogue
	# buys over a hard-coded list.[/b] A corridor with two people in it is a chase; with
	# nobody in it, it is not a mode worth voting for.
	_check(
		not maps.available(&"hungry_gauntlet"),
		"a corridor is unavailable at this head count"
	)
	_check(maps.available(&"hungry_classic"), "and a square is not")

	var next := maps.next_in_rotation()
	_check(next != &"", "something is next in the rotation (%s)" % String(next))
	_check(
		next != StringName(_module().world.preset.id),
		"and it is not what is playing now",
		"a cooldown of one over four modes is what stops the same one twice running"
	)

	# Rocking the vote with one player. The threshold is a fraction of the head count and
	# `rtv_min_players` is 2, so this is refused — which is the check: a refusal that
	# arrives is a rule that ran, and dot-vote shipped a version where rocking the vote was
	# refused for ever on the deployment that depends on it.
	var rocked := maps.director.rock_the_vote(&"1")
	_check(
		rocked != null,
		"rocking the vote answers rather than doing nothing",
		str(rocked.error) if not rocked.ok else "accepted"
	)

	_check(
		not maps.director.begin_on_apply,
		"the director does not announce its own change",
		"the host announces it through `game_loaded`, which also fires for an operator "
		+ "typing `changegame` — both firing halves every cooldown"
	)

	# Once a tick. It self-advanced AND the module advanced it, so a fifteen-minute mode
	# was over in seven and a half.
	_check(
		not maps.director.self_advance and not maps.director.is_physics_processing(),
		"the vote's clock is advanced once a tick, by the module, and not also by itself"
	)

	# dot-vote's commands. None existed: a chat `!rtv` reached a console with no `rtv`.
	var absent := PackedStringArray()
	for name in [
		"rtv", "unrtv", "nominate", "vote", "timeleft", "nextmap",
		"setnextmap", "nominate_addmap", "forcertv", "votereload",
	]:
		if _server.console.find_command(name) == null:
			absent.append(name)
	_check(absent.is_empty(), "dot-vote's commands are on the console", ", ".join(absent))

	# The cues and the countdown leave the vote for the wire. The ids are the wire's own,
	# and nothing on the server had any to send before.
	var rules := maps.director.rules
	var cues: Array = []
	var on_cue := func(cue: StringName, seconds_left: int, _runoff: bool) -> void:
		cues.append([String(cue), seconds_left])
	maps.cue_due.connect(on_cue)
	var min_players := rules.min_players_to_vote
	rules.min_players_to_vote = 0
	var started := maps.director.start_vote()
	maps.cue_due.disconnect(on_cue)
	_check(
		started.ok and maps.director.is_counting_down()
			and cues.has([HungryEvents.CUE_VOTE_WARNING, 0]) and cues.has(["", int(rules.vote_warning_sec)]),
		"a ballot is counted down to, and its warning cue and first second go to the module (%s)"
			% str(cues),
		started.error.message if not started.ok else ""
	)
	maps.director.cancel_countdown()
	rules.min_players_to_vote = min_players

	# The leading score — the biggest monster's mass — reaches the director, and a score
	# limit opens the ballot off it. Nothing called note_score before.
	var saved := [rules.trigger, rules.duration_sec, rules.score_limit, rules.vote_lead_score, rules.min_players_to_vote, rules.vote_warning_sec]
	var top := int(maps.score_fn.call()) if maps.score_fn.is_valid() else 0
	# No countdown for this one: it asks whether the score opens a ballot, and a countdown
	# in front of the ballot is the check above.
	rules.vote_warning_sec = 0.0
	rules.trigger = DotVoteRules.Trigger.SCORE_LIMIT
	rules.duration_sec = 0.0
	rules.score_limit = top + 3
	rules.vote_lead_score = 3
	rules.min_players_to_vote = 0
	maps.director.begin(maps.director.current_id())
	maps.advance(0.0)

	_check(
		top > 0 and maps.director.clock.top_score == top,
		"the biggest monster's mass is the vote's leading score (%d)" % top
	)
	_check(
		maps.director.is_voting(),
		"and a score limit %d short of it opens the ballot" % rules.vote_lead_score,
		maps.director.describe_lines()[0]
	)
	if maps.director.is_voting():
		maps.director.close_vote()

	# And a round end reaches it, from the match the module is running.
	var played := maps.director.clock.rounds_played
	_module().world.match_node.round_ended.emit(99, 0, DotMatchRules.Outcome.SCORE)
	_check(
		maps.director.clock.rounds_played == played + 1,
		"and dot-match's round end reaches the director (%d -> %d)"
			% [played, maps.director.clock.rounds_played]
	)

	rules.trigger = saved[0]
	rules.duration_sec = saved[1]
	rules.score_limit = saved[2]
	rules.vote_lead_score = saved[3]
	rules.min_players_to_vote = saved[4]
	rules.vote_warning_sec = saved[5]
	maps.director.begin(maps.director.current_id())

	# [b]The `map time` line follows an extend.[/b] It was a `DotMapTimeLimit` built beside
	# the vote and advanced in step with it, which nothing extended: an operator reading
	# `hungry_vote status` after the players voted to extend saw the old limit.
	var before_line := _map_time_line(maps.describe_lines())
	var extended := maps.director.extend()
	var after_line := _map_time_line(maps.describe_lines())
	_check(
		extended.ok and after_line != before_line
			and after_line.ends_with(maps.director.clock.formatted_remaining()),
		"an extend moves the mode's time left where an operator reads it (%s -> %s)"
			% [before_line.strip_edges(), after_line.strip_edges()],
		"the descriptive clock would still say what it said before"
	)
	maps.director.begin(maps.director.current_id())
	_done()


func _map_time_line(lines: PackedStringArray) -> String:
	for line in lines:
		if line.begins_with("map time"):
			return line
	return ""


func _test_transport() -> void:
	_section("browser clients")

	var transport := DotTransportWebSocket.new()
	_check(transport != null, "dot-core can build a WebSocket transport")
	_check(
		transport.supports_web_clients(),
		"which is the one browser clients can reach"
	)

	var available := transport._is_available()
	_check(
		available.ok,
		"and this engine build has the peer it needs",
		"a build without it cannot serve browser clients at all: %s"
			% str(available.error)
	)

	# The constraint that shapes the whole deployment: a browser cannot listen, so the web
	# build is a client and the server is somewhere else.
	_check(
		not DotPlatform.is_web(),
		"and this process can listen, because it is not a browser"
	)
	_done()


func _test_unload() -> void:
	_section("unloading")

	_check(_server.modules.unload_module("hungry").ok, "the module unloads")
	_check(
		_server.console.find_command("hungry_status") == null,
		"and takes its commands with it"
	)

	var world := _world()
	_check(
		world != null and world.monsters().is_empty(),
		"and its players, so the world is not left holding sessions that are gone"
	)

	_check(
		(await _server.modules.load_module("res://game/hungry_module.gd")).ok,
		"and loads again cleanly"
	)
	_done()


## [b]The one line that leaked mg-buses-from-hell's whole script graph at exit.[/b]
##
## A script that `extends DotNetMessage` and preloads ITSELF, first loaded from a module a
## running [DotServer] loads — which is how every deployed server loads this game — leaves
## every loaded script alive at exit on Godot 4.7.2 (measured in mg-buses-from-hell,
## 8ed866c). This game's event and request both did it, for a typed `of()` factory.
##
## [b]Asserted on the source, because the symptom is where no check can reach.[/b] The
## leak is reported after `quit()`, by the engine, as warnings a CI filter already treats
## as noise; an assertion here runs before any of it exists. So this checks the cause
## instead: every message script in `game/`, read as text.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")

	var messages := PackedStringArray()
	var offenders := PackedStringArray()
	var pending: Array[String] = ["res://game"]

	while not pending.is_empty():
		var dir_path: String = pending.pop_back()

		for sub in DirAccess.get_directories_at(dir_path):
			pending.append(dir_path.path_join(sub))

		for file in DirAccess.get_files_at(dir_path):
			if not file.ends_with(".gd"):
				continue

			var path := dir_path.path_join(file)
			var source := FileAccess.get_file_as_string(path)

			if not _extends_message(source):
				continue

			messages.append(path)

			if source.contains('preload("%s")' % file) or source.contains('preload("%s")' % path):
				offenders.append(path)

	_check(
		messages.size() >= 2,
		"this game's message scripts are found, so the next check is about something",
		", ".join(messages)
	)
	_check(
		offenders.is_empty(),
		"and none of them preloads itself, which leaks every script at exit",
		", ".join(offenders)
	)

	_done()


func _extends_message(source: String) -> bool:
	for line in source.split("\n"):
		if line.begins_with("extends "):
			return line.contains("DotNetMessage") or line.contains("dot_net_message.gd")
	return false


# --- Exiting clean ----------------------------------------------------------------

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


## Runs this same suite in a fresh process: `[exit code, everything it printed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it.[/b] "N ObjectDB instances were leaked at exit" is printed once the
## scene tree is gone, so the only process that can check a run's exit is another one. On
## Godot 4.7.2 a script that names itself, loaded after its base, cuts the engine's exit
## teardown short and every script loaded before it is reported leaked — hundreds of lines
## a passing run printed for weeks, which is why this is a check now and not a warning.
##
## [b]First, before this run opens a port[/b], so the two never contend for a socket — and
## so this run is always the second one against the same `user://`, which is the other
## thing no single run can see.
func _run_exit_probe() -> Array:
	print("(running this suite once more in a fresh process, to read what it leaves at exit)")
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var out: Array = []
	var code := OS.execute(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	], out, true)
	var text := ""
	for chunk: Variant in out:
		text += str(chunk)
	return [code, text]


func _test_exits_clean(probe: Array) -> void:
	_section("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var text: String = probe[1]

	_check(code == 0, "this suite, run again in a fresh process, passes",
		"exit %d; its last lines:\n%s" % [code, _last_lines(text, 25)] if code != 0 else "")
	_check(not text.contains("leaked at exit"), "and leaves no object alive at exit",
		_line_with(text, "leaked at exit"))
	_check(not text.contains("still in use at exit"), "and no resource",
		_line_with(text, "still in use at exit"))
	_done()


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))

extends Node

const HungryContent := preload("../game/hungry_content.gd")
const HungryEvent := preload("../game/net/hungry_event.gd")
const HungryEvents := preload("../game/net/hungry_events.gd")
const HungryField := preload("../game/hungry_field.gd")
const HungryHazards := preload("../game/hungry_hazards.gd")
const HungryHunters := preload("../game/hungry_hunters.gd")
const HungryInterest := preload("../game/net/hungry_interest.gd")
const HungryLayout := preload("../game/hungry_layout.gd")
const HungryModTools := preload("../game/hungry_mod_tools.gd")
const HungryNetBridge := preload("../game/net/hungry_net_bridge.gd")
const HungryNetCommand := preload("../game/net/hungry_net_command.gd")
const HungryPieceNet := preload("../game/net/hungry_piece_net.gd")
const HungryPreset := preload("../game/hungry_preset.gd")
const HungryProjectile := preload("../game/hungry_projectile.gd")
const HungryServices := preload("../game/hungry_services.gd")
const HungryWorld := preload("../game/hungry_world.gd")

## Runs a server and a client in one process and checks the netcode works.
##
## [codeblock]
## godot --headless --path . res://examples/headless_net.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]Everything here is offline and reproducible.[/b] The two halves are wired to each
## other through a loopback that can delay and drop packets, which is the only way to test
## interpolation, loss recovery and reconciliation at all — a real socket does not
## reproduce the same conditions twice. The socket itself is what
## [code]examples/sandbox.tscn[/code] is for.

const TICK_RATE := 60
const SNAPSHOT_RATE := 20
const SEED := 20260828
const CLIENT_PEER := 2

const CHECKS := 158

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _server_world: HungryWorld = null
var _client_world: HungryWorld = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: HungryNetBridge = null
var _client_bridge: HungryNetBridge = null

## Payloads in flight, so loss and delay can be simulated.
var _to_client: Array[Dictionary] = []
var _to_server: Array[Dictionary] = []

## Drop one snapshot in this many. Zero drops nothing.
var _drop_every: int = 0
var _snapshot_count: int = 0

var _tick: int = 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-hungario: netcode")
	print("")

	_test_command_wire()
	_test_event_wire()
	_test_field_wire()

	if _build():
		_test_handshake()
		_test_replication()
		_test_prediction()
		_test_admin_is_predicted()
		_test_field_replication()
		_test_splitting_replicates()
		_test_throw_replicates()
		_test_interest()
		_test_blind_and_beacon()
		_test_avatar()
		_test_interpolation()
		_test_loadout()
		_test_direction_enforced()
		_test_vote_wire()
		_test_loss()
		_test_game_change()
		_test_warrens_rock_converges()

	_teardown()

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


# --- The wire, on its own --------------------------------------------------

func _test_command_wire() -> void:
	_section("commands on the wire")

	var original := HungryNetCommand.new()
	original.tick = 41
	original.delta = 1.0 / 60.0
	original.command.aim = Vector2(0.6, -0.8)
	original.command.reach = 640.0
	original.command.set_button(Dot2DCommand.BUTTON_SPLIT, true)

	var writer := DotNetWriter.new()
	original.write(writer)

	var back := HungryNetCommand.new()
	back.read(writer.to_reader())

	_check(back.tick == original.tick, "the tick survives")
	_check(
		back.command.aim.distance_to(original.command.aim) < 0.01,
		"the aim survives (%.4f off)"
			% back.command.aim.distance_to(original.command.aim)
	)
	_check(
		absf(back.command.reach - original.command.reach) < 2.0,
		"the reach survives (%.2f off)"
			% absf(back.command.reach - original.command.reach)
	)
	_check(
		back.command.is_pressed(Dot2DCommand.BUTTON_SPLIT), "and so do the buttons"
	)

	# Sanitising is not optional and it is not redundant with quantisation: quantisation
	# bounds each field on its own and cannot bound the relationship between them.
	var hostile := HungryNetCommand.new()
	hostile.command.aim = Vector2(40.0, 40.0)
	hostile.command.reach = 99999.0
	hostile.command.buttons = -1
	hostile.sanitise(TICK_RATE)

	_check(
		absf(hostile.command.aim.length() - 1.0) < 0.001,
		"a forty-times-too-long aim is normalised"
	)
	_check(
		hostile.command.reach <= HungryNetCommand.MAX_REACH,
		"an out-of-range reach is clamped (%.0f)" % hostile.command.reach
	)
	_check(
		hostile.command.buttons < (1 << Dot2DCommand.BUTTON_BITS),
		"and unknown buttons are masked off"
	)
	_done()


func _test_event_wire() -> void:
	_section("events on the wire")

	var schema := HungryContent.avatar_schema()

	var hello := HungryEvents.read_hello(
		DotNetReader.new(
			HungryEvents.write_hello(
				12345, 60, 7, 2, 900, Vector2(5200.0, 5200.0),
				"https://cdn.example/hungry/manifest.json"
			)
		)
	)
	_check(bool(hello["ok"]), "hello round-trips")
	_check(int(hello["seed"]) == 12345, "with the seed")
	_check(int(hello["player_id"]) == 7, "and who you are")
	_check(int(hello["tick"]) == 900, "and the tick")
	_check(
		String(hello["pack_url"]) == "https://cdn.example/hungry/manifest.json",
		"and where this server's rider content lives"
	)

	var avatar := HungryContent.default_avatar(3)
	avatar.set_part(&"hat", &"hat_cap")
	avatar.set_colour(&"hat", 0, Color(0.2, 0.4, 0.9))

	var join := HungryEvents.read_join(
		DotNetReader.new(HungryEvents.write_join(7, 2, "Ada", avatar, schema)), schema
	)
	_check(bool(join["ok"]), "a join round-trips")
	_check(String(join["name"]) == "Ada", "with the name")

	var carried: Variant = join["avatar"]
	_check(carried is DotAvatar, "and the avatar")
	_check(
		carried is DotAvatar and (carried as DotAvatar).digest() == avatar.digest(),
		"which is the same document",
		"%s vs %s" % [
			(carried as DotAvatar).digest() if carried is DotAvatar else "-",
			avatar.digest(),
		]
	)

	var spawn := HungryEvents.read_spawn(
		DotNetReader.new(
			HungryEvents.write_spawn(31, 2, 7, 4, Vector2(-1234.5, 678.9), 412.0)
		)
	)
	_check(bool(spawn["ok"]), "a spawn round-trips")
	_check(int(spawn["net_id"]) == 31 and int(spawn["piece_id"]) == 4, "with both ids")
	_check(
		(spawn["position"] as Vector2).distance_to(Vector2(-1234.5, 678.9)) < 0.1,
		"and the position"
	)
	_check(is_equal_approx(float(spawn["mass"]), 412.0), "and the mass")

	var shot := HungryProjectile.make(
		9, 7, HungryContent.ITEM_FROST, Vector2(100.0, -50.0), Vector2(0.6, 0.8), 512
	)
	var thrown := HungryEvents.read_throw(
		DotNetReader.new(HungryEvents.write_throw(shot))
	)
	_check(bool(thrown["ok"]), "a throw round-trips")
	_check(
		HungryContent.ITEM_IDS[int(thrown["item_index"])] == HungryContent.ITEM_FROST,
		"with the item"
	)
	_check(int(thrown["tick"]) == 512, "and the tick it left on")

	var carry := HungryEvents.read_carry(
		DotNetReader.new(
			HungryEvents.write_carry(
				[HungryContent.ITEM_PEPPER, HungryContent.ITEM_LURE]
			)
		)
	)
	_check(
		carry.size() == 2 and carry[0] == HungryContent.ITEM_PEPPER,
		"and a carry list round-trips"
	)

	# --- chat, and the one meta field this wire carries ---
	#
	# [b]Every encoder against its decoder, which is what this section is for.[/b] The two
	# have to be exact inverses and nothing can check that for you: dot-moderation shipped
	# a store whose writer and reader never met and every voice mute loaded back as a
	# warning, which enforces nothing.
	var line := DotChatMessage.make(
		DotChatMessage.Kind.SAY, HungryServices.CHANNEL_NEAR, "42", "Ada", "hello there"
	)
	line.seq = 9
	line.sent_at = 1700000000

	var wire := line.to_dictionary()
	wire["x"] = {"p": 42}

	var chat := HungryEvents.read_chat(DotNetReader.new(HungryEvents.write_chat(wire)))
	_check(bool(chat["ok"]), "a chat line round-trips")
	_check(String(chat["m"]) == "hello there", "with the text")
	_check(String(chat["c"]) == String(HungryServices.CHANNEL_NEAR), "and the channel")
	_check(String(chat["d"]) == "Ada", "and the name")
	_check(
		typeof(chat.get("x")) == TYPE_DICTIONARY
			and int((chat["x"] as Dictionary).get("p", 0)) == 42,
		"and the player it belongs to, which is what a bubble is drawn over"
	)

	# [b]The kind travels as an index into one table, used in both directions.[/b] Every
	# value of the enum, because dot-moderation's bug was exactly one value with no case.
	var kinds_ok := true

	for kind in DotChatMessage.Kind.values():
		var one := DotChatMessage.make(
			kind as DotChatMessage.Kind, HungryServices.CHANNEL_ALL, "1", "Ada", "x"
		)
		var back := HungryEvents.read_chat(
			DotNetReader.new(HungryEvents.write_chat(one.to_dictionary()))
		)

		if String(back["k"]) != one.kind_name():
			kinds_ok = false

	_check(kinds_ok, "every chat kind survives the wire, not just the common one")

	var said := HungryEvents.read_say(
		DotNetReader.new(HungryEvents.write_say(HungryServices.CHANNEL_NEAR, "anybody?"))
	)
	_check(
		bool(said["ok"]) and String(said["text"]) == "anybody?"
			and String(said["channel"]) == String(HungryServices.CHANNEL_NEAR),
		"and a client's own line round-trips with the channel it chose"
	)

	# --- hunters and hazards ---
	var hunter := HungryEvents.read_hunter(
		DotNetReader.new(
			HungryEvents.write_hunter(
				77, HungryHunters.index_of(&"stalker"), Vector2(120.0, -340.0), 26.5, true
			)
		)
	)
	_check(bool(hunter["ok"]), "a hunter round-trips")
	_check(int(hunter["hunter_id"]) == 77, "with its id")
	_check(
		HungryHunters.id_at(int(hunter["kind_index"])) == &"stalker",
		"and its kind, as an index rather than a name"
	)
	_check(
		(hunter["position"] as Vector2).distance_to(Vector2(120.0, -340.0)) < 1.0,
		"and its position, quantised over the same range a snapshot uses",
		str(hunter["position"])
	)

	var hazard := HungryEvents.read_hazard(
		DotNetReader.new(
			HungryEvents.write_hazard(
				5, HungryHazards.index_of(&"spike"), Vector2(-900.0, 20.0), true
			)
		)
	)
	_check(bool(hazard["ok"]), "a hazard round-trips")
	_check(
		HungryHazards.id_at(int(hazard["kind_index"])) == &"spike",
		"with its kind"
	)
	_check(bool(hazard["present"]), "and whether it is still there")

	# --- progress and votes ---
	var earned := HungryEvents.read_progress(
		DotNetReader.new(HungryEvents.write_progress(7, &"eat_100", "Peckish", 10))
	)
	_check(
		bool(earned["ok"]) and String(earned["id"]) == "eat_100"
			and int(earned["value"]) == 10,
		"an achievement round-trips"
	)

	_check(
		HungryEvents.read_vote(DotNetReader.new(HungryEvents.write_vote("nominate frenzy")))
			== "nominate frenzy",
		"and a vote token, which is a token because what an id MEANS is a source's business"
	)

	# The catalogue orders both ends index by. [b]Sorted as String, not as StringName[/b]:
	# `Array.sort()` on a StringName compares interned pointers, so two peers give one
	# thing two different indices — dot-net shipped that with message ids and only a
	# browser client, which is a separate program with its own intern table, could see it.
	for ids in [HungryHunters.wire_ids(), HungryHazards.wire_ids()]:
		var sorted: PackedStringArray = (ids as PackedStringArray).duplicate()
		sorted.sort()
		_check(
			Array(ids) == Array(sorted),
			"a wire catalogue is in lexicographic order (%s)" % str(ids)
		)

	# A body claiming a kind that does not exist has to be refused rather than
	# dispatched, because the handler's `match` would silently fall through.
	var bogus := HungryEvent.new(31, PackedByteArray())
	_check(not bogus.validate().ok, "an unknown event kind is refused")
	_done()


func _test_field_wire() -> void:
	_section("the field on the wire")

	var added: Array = [
		HungryField.FOOD_ID_BASE + 4,
		HungryField.FRUIT_ID_BASE + 1,
		HungryField.PLANTED_ID_BASE + 9,
	]
	var removed: Array = [HungryField.FOOD_ID_BASE + 5, HungryField.ITEM_ID_BASE + 2]
	var planted := {
		HungryField.PLANTED_ID_BASE + 9: {
			"position": Vector2(321.0, -654.0), "tier": 1
		}
	}

	var back := HungryEvents.read_field(
		DotNetReader.new(HungryEvents.write_field(added, removed, planted))
	)

	_check(bool(back["ok"]), "a field delta round-trips")
	_check((back["added"] as Array).size() == 3, "with everything added")
	_check((back["removed"] as Array).size() == 2, "and everything taken")

	var rows: Dictionary = back["planted"]
	var row: Dictionary = rows.get(HungryField.PLANTED_ID_BASE + 9, {})
	_check(
		row.has("position")
			and (row["position"] as Vector2).distance_to(Vector2(321.0, -654.0)) < 0.1,
		"and a planted crumb keeps the position it was put at"
	)

	# A hostile count must be refused before it is looped over. Four billion is one
	# varint and would otherwise be four billion iterations.
	var hostile := DotNetWriter.new()
	hostile.write_varint(4_000_000_000)
	var refused := HungryEvents.read_field(hostile.to_reader())
	_check(not bool(refused["ok"]), "an absurd count is refused, not iterated")


# --- Both halves -----------------------------------------------------------
	_done()

func _make_world(authority: bool, scope: StringName) -> HungryWorld:
	var world := HungryWorld.new()
	world.name = "World" if authority else "ClientWorld"
	world.preset = HungryPreset.classic()
	world.tick_rate = TICK_RATE
	world.world_seed = SEED
	world.is_authority = authority
	world.register_service = true
	world.service_scope = scope
	add_child(world)
	world.setup()

	if authority:
		world.start(0)

	return world


func _make_manager(server: bool, scope: StringName, peer_id: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = TICK_RATE
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 120
	config.world_extent = Dot2DNetSync.WORLD_EXTENT
	manager.config = config

	add_child(manager)
	manager.setup()
	return manager


func _build() -> bool:
	print("")
	print("bringing both halves up")

	# Two subtrees so the two link nodes are not siblings with the same name. Nothing here
	# touches the multiplayer API — the loopback stands in for it — but the tree still has
	# to be legal.
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)

	_server_world = _make_world(true, &"server")
	_client_world = _make_world(false, &"client")

	_server_net = _make_manager(true, &"server", 1)
	_client_net = _make_manager(false, &"client", CLIENT_PEER)

	_server_bridge = HungryNetBridge.new()
	_server_bridge.name = "ServerBridge"
	add_child(_server_bridge)

	_client_bridge = HungryNetBridge.new()
	_client_bridge.name = "ClientBridge"
	add_child(_client_bridge)

	var server_attached := _server_bridge.attach(_server_world, _server_net, server_side)
	var client_attached := _client_bridge.attach(_client_world, _client_net, client_side)

	if not _check(server_attached.ok, "the server bridge attaches", str(server_attached.error)):
		return false

	if not _check(client_attached.ok, "the client bridge attaches", str(client_attached.error)):
		return false

	# A world and a manager that disagree about who is authoritative would resolve
	# everybody's eating or nobody's, silently. The bridge refuses instead.
	var wrong := HungryNetBridge.new()
	add_child(wrong)
	var refused := wrong.attach(_client_world, _server_net, server_side)
	_check(not refused.ok, "and a mismatched pair is refused")
	remove_child(wrong)
	wrong.queue_free()

	_server_net.messages.seal()
	_client_net.messages.seal()

	_check(
		_server_net.messages.schema_hash() == _client_net.messages.schema_hash(),
		"the two ends agree on the message schema",
		"%s vs %s" % [
			_server_net.messages.schema_hash(), _client_net.messages.schema_hash()
		]
	)

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send

	_server_net.start()
	_client_net.start()

	return true


func _teardown() -> void:
	for node in [
		_server_bridge, _client_bridge, _server_net, _client_net,
		_server_world, _client_world,
	]:
		if node != null and is_instance_valid(node):
			remove_child(node)
			node.queue_free()


# --- The loopback ----------------------------------------------------------

func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if method == &"snapshot":
		_snapshot_count += 1

		# Dropped rather than delayed: a lost snapshot is the case the acked baselines
		# exist for, and the only way to know they work is to lose some.
		if _drop_every > 0 and _snapshot_count % _drop_every == 0:
			return

	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


## Delivers everything in flight, in order.
## The mode vote's cue and countdown, server to client.
##
## Before this nothing carried either: the ballot went out as chat and the vote's sounds
## and its count went nowhere, so a client heard a ballot open by reading about it.
func _test_vote_wire() -> void:
	_section("the mode vote's cues over the link")

	var round_trip := HungryEvents.read_vote_cue(
		DotNetReader.new(HungryEvents.write_vote_cue(HungryEvents.CUE_VOTE_COUNT, 4, true))
	)
	_check(
		bool(round_trip["ok"]) and String(round_trip["cue"]) == HungryEvents.CUE_VOTE_COUNT
			and int(round_trip["seconds_left"]) == 4 and bool(round_trip["runoff"]),
		"a VOTE round-trips, with the cue, the second and the runoff flag"
	)
	_check(
		HungryEvents.Kind.VOTE == HungryEvents.Kind.size() - 1,
		"and VOTE is the last kind, so every kind before it kept its number on the wire"
	)

	var arrived: Array[Dictionary] = []
	var on_vote := func(info: Dictionary) -> void: arrived.append(info)
	_client_bridge.vote_cue_received.connect(on_vote)
	_server_bridge.broadcast_vote_cue(StringName(HungryEvents.CUE_VOTE_WARNING), 0, false)
	_server_bridge.broadcast_vote_cue(&"", 5, false)
	_flush()
	_client_bridge.vote_cue_received.disconnect(on_vote)

	_check(
		arrived.size() == 2
			and String(arrived[0]["cue"]) == HungryEvents.CUE_VOTE_WARNING
			and int(arrived[1]["seconds_left"]) == 5,
		"a cue and a countdown second reach a ready client, in order (%s)" % str(arrived)
	)

	_done()


func _flush() -> void:
	# Copied and cleared first: delivering an event can cause a reply, and appending to
	# the array being walked would deliver it inside the same flush.
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


## How far ahead of the server the client stamps its inputs.
##
## [b]Not a fudge factor.[/b] A command for tick N has to be in the server's hands
## [i]before[/i] it simulates N, so a client running level with the server has every input
## arrive one tick late — for ever, silently, with the only symptom a player who cannot
## move. [DotNetClock] is what does this in a real deployment; here the harness does it by
## hand because there is no clock to synchronise against.
const INPUT_LEAD := 2

## One tick of both halves, with the wire drained in between.
func _step(command: Dot2DCommand = null) -> void:
	_tick += 1
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(
		_tick + INPUT_LEAD, command if command != null else Dot2DCommand.new()
	)
	_flush()


func _steps(count: int, command: Dot2DCommand = null) -> void:
	for _i in range(count):
		_step(command)


# --- The tests -------------------------------------------------------------

func _test_handshake() -> void:
	_section("a client joins")

	var added := _server_bridge.add_player(CLIENT_PEER, 7, "Ada")
	_check(added.ok, "the server adds them", str(added.error))

	_check(
		not _server_net.peers().has(CLIENT_PEER),
		"and sends them nothing until they ask"
	)

	# The client asking is what admits it. Between dot-server's signon finishing and the
	# client building its scene there is a window in which it has no node for an RPC to
	# land on, so everything sent in it is lost and logged as a missing node.
	_client_bridge.ask_for_world()
	_flush()
	_flush()

	_check(_server_net.peers().has(CLIENT_PEER), "asking admits them")

	_check(
		_client_bridge.local_player_id == 7,
		"and the client learns who it is (%d)" % _client_bridge.local_player_id
	)
	_check(
		_client_world.monster_for(7) != null,
		"and has a monster for itself"
	)
	_check(
		_client_world.field.seed_value() == _server_world.field.seed_value(),
		"and the same field seed"
	)
	_check(
		_client_bridge.avatar_pack_url == _server_bridge.avatar_pack_url,
		"and the same rider content, if there is any (%s)"
			% ("none" if _client_bridge.avatar_pack_url == ""
				else _client_bridge.avatar_pack_url)
	)
	_check(
		_client_world.field.alive_count() == _server_world.field.alive_count(),
		"and the same food (%d vs %d)" % [
			_client_world.field.alive_count(), _server_world.field.alive_count()
		]
	)

	# The whole point of a seed: a client that received eleven hundred positions would
	# have paid about 5 kB for what an integer bought.
	var mismatched := 0

	for grid_id in _server_world.field.alive_ids():
		if _client_world.field.position_of(grid_id).distance_to(
			_server_world.field.position_of(grid_id)
		) > 0.001:
			mismatched += 1

	_check(
		mismatched == 0,
		"and every crumb is in the same place without a position being sent"
	)

	_steps(4)

	_check(
		_client_bridge.piece_count() == _server_bridge.piece_count(),
		"the piece is mirrored (%d vs %d)" % [
			_client_bridge.piece_count(), _server_bridge.piece_count()
		]
	)

	var mine := _client_world.monster_for(7)
	_check(mine != null and mine.alive, "and the client's monster is alive")

	var predicted := _client_net.registry.predicted()
	_check(
		predicted.size() == mine.piece_count(),
		"and the client predicts every piece it owns (%d)" % predicted.size()
	)
	_done()


func _test_replication() -> void:
	_section("state")

	var command := Dot2DCommand.new()
	command.aim = Vector2.RIGHT
	command.reach = 800.0

	var before := _server_world.monster_for(7).centre()
	_steps(90, command)

	var server_at := _server_world.monster_for(7).centre()
	var client_at := _client_world.monster_for(7).centre()

	_check(
		server_at.distance_to(before) > 100.0,
		"the server simulated movement (%.0f units)" % server_at.distance_to(before)
	)
	_check(
		client_at.distance_to(server_at) < 6.0,
		"and the client agrees within six units (%.2f)"
			% client_at.distance_to(server_at)
	)

	# The radius is derived from the received mass, never replicated: two copies of one
	# number eventually disagree by a rounding error, and then a monster's eat radius and
	# its drawn radius are in different places.
	var server_piece := _server_world.monster_for(7).rider_piece()
	var client_piece := _client_world.monster_for(7).rider_piece()

	_check(
		client_piece != null
			and absf(client_piece.radius() - server_piece.radius()) < 0.5,
		"and the radius follows the mass on both ends"
	)
	_check(
		client_piece != null
			and (client_piece.state.flags & HungryContent.FLAG_RIDER) != 0,
		"and the rider flag arrived"
	)
	_done()


func _test_prediction() -> void:
	_section("prediction")

	# [b]Not near zero in this game, and that is correct.[/b] A client predicts where its
	# monster went; it does not predict what its monster ate, because eating is the
	# authority's and a client that resolved its own would be a client that decides what
	# it weighs. So every crumb swallowed is a mass the client did not have, a speed it
	# did not use, and a small correction on the next snapshot. What matters is that the
	# corrections stay small — the distance checks below — rather than that they stop.
	# [b]It is not zero in this game, and that is correct.[/b] A client predicts where its
	# monster went; it does not predict what its monster ate, because eating is the
	# authority's and a client that resolved its own would be a client that decides what
	# it weighs. Every crumb swallowed is therefore a mass the client did not have, a
	# speed it did not use, and a small correction on the next snapshot.
	#
	# What it must not be is [i]most[/i] snapshots. This read 0.500 while the bridge was
	# reconciling a second time on top of the reconciliation
	# [method DotNetManager.receive_snapshot] had already done — replaying the same inputs
	# twice against values that had already been rewound. Removing that pass took it to
	# 0.03, and neither number produced an error or a failed check anywhere else.
	var rate := _client_net.predictor.correction_rate()
	_check(
		rate < 0.25,
		"corrections stay rare (%.3f of snapshots)" % rate,
		"consistently high means the two simulations disagree, and no smoothing fixes that"
	)

	# The client's own monster must respond on the tick the input is given, not a round
	# trip later. Measured against the client's own previous position, because that is
	# what the player sees.
	var command := Dot2DCommand.new()
	command.aim = Vector2.UP
	command.reach = 900.0

	var before := _client_world.monster_for(7).centre()
	_client_bridge.client_tick(_tick + INPUT_LEAD + 1, command)
	var after := _client_world.monster_for(7).centre()

	_check(
		after.distance_to(before) > 0.5,
		"the client moves on the tick it presses (%.2f units)"
			% after.distance_to(before)
	)

	_steps(30, command)
	_check(
		_client_world.monster_for(7).centre().distance_to(
			_server_world.monster_for(7).centre()
		) < 8.0,
		"and stays with the server afterwards"
	)
	_done()


## An administrator noclips and freezes a monster on the server, and the monster's own
## client has to PREDICT both.
##
## [b]The symptom this exists for is rubber-banding, and no server-side check can see
## it.[/b] So each window records, tick by tick, where the client predicted its monster and
## where the server put it, and compares the two at the same tick — once the shipped way,
## through the moderator handlers and [Dot2DAdminModifiers], and once the naive way, a
## server-only change the client is never told about. The naive half has to DIVERGE: a
## window in which the client was never asked to disagree would pass the first half too.
## Game-arena's `headless_net` is the same shape for the first-person motor.
func _test_admin_is_predicted() -> void:
	_section("an admin's noclip and freeze, predicted by the client they happen to")

	var server_fn := func() -> HungryWorld: return _server_world
	var tools := HungryModTools.handlers(server_fn)
	var noclip: Callable = tools[DotModTools.ACTION_NOCLIP]
	var freeze: Callable = tools[DotModTools.ACTION_FREEZE]

	# A rock on the monster's path, in BOTH worlds — the client predicts around the level's
	# rocks, which is the whole reason a server-only noclip would disagree with it.
	var from := _server_world.monster_for(7).centre()
	var heading := (_server_world.arena.bounds.get_center() - from)
	heading = heading.normalized() if heading.length() > 400.0 else Vector2.RIGHT
	var rock := from + heading * 140.0
	_server_world.layout = _rock_at(rock)
	_client_world.layout = _rock_at(rock)

	var command := Dot2DCommand.new()
	command.aim = heading
	command.reach = 900.0

	var on: DotResult = noclip.call(&"7", {"on": true})
	_check(on.ok, "the moderator handler noclips player 7 on the server", str(on.error))

	var shipped := _admin_window(90, command)

	var client_piece := _client_world.monster_for(7).rider_piece()
	_check(
		client_piece != null and Dot2DAdminModifiers.is_noclipped(client_piece.state),
		"the client learned it from the snapshots"
	)
	# Past the rock's CENTRE, which a monster the rock stopped can never reach: it is held
	# the rock's radius plus its own short of it.
	var past := (_server_world.monster_for(7).centre() - rock).dot(heading)
	_check(past > 0.0, "the server's monster went through the rock", "%.1f units past its centre" % past)
	_check(
		float(shipped["worst"]) < 8.0,
		"and the client predicted it through, never more than eight units from the server",
		"worst %.2f" % float(shipped["worst"])
	)

	# The same move made the naive way: noclip off, and the rock taken out of the SERVER's
	# world only — a server that lets somebody through without telling the client why.
	var _off: DotResult = noclip.call(&"7", {"on": false})
	_back_to(from)
	_server_world.layout = HungryLayout.none()
	var naive := _admin_window(90, command)
	print("  measured: noclip shipped worst %.2f (%d ticks over 8); naive worst %.2f (%d ticks over 8)" % [
		float(shipped["worst"]), int(shipped["over"]), float(naive["worst"]), int(naive["over"])
	])
	_check(
		float(naive["worst"]) > 30.0,
		"a server-only noclip is one the client does not predict: the rubber band",
		"naive worst %.2f — if this passes quietly, the checks above prove nothing" % float(naive["worst"])
	)

	_server_world.layout = HungryLayout.none()
	_client_world.layout = HungryLayout.none()
	_back_to(from)

	# Freeze: held still with the pointer at full reach, on both ends.
	var frozen: DotResult = freeze.call(&"7", {"on": true})
	_check(frozen.ok, "the moderator handler freezes player 7", str(frozen.error))
	var held_at := _server_world.monster_for(7).centre()
	var still := _admin_window(60, command)
	_check(
		_server_world.monster_for(7).centre().distance_to(held_at) < 1.0,
		"the server holds the monster where it was",
		"%.2f units" % _server_world.monster_for(7).centre().distance_to(held_at)
	)
	_check(
		float(still["worst"]) < 1.0,
		"and the client never predicted it moving",
		"worst %.2f" % float(still["worst"])
	)

	# And naive: unfrozen, with the server alone refusing to move anybody.
	#
	# This used to be worse than a rubber band: the client walked away and was NEVER pulled
	# back (112.80 units over the window, and growing), because a snapshot that carried the
	# monster with nothing changed handed [DotNetPredictor] the client's own prediction as
	# the server's answer. dot-net now rewinds a predicted entity to the server's whole
	# state — what the snapshot left out is what the server last sent — so the naive
	# freeze is an ordinary rubber band: the client predicts its lead of movement the
	# server refuses, and every snapshot pulls it back. Both halves of that are asserted.
	# The first is still what makes the shipped freeze worth checking: a client that is
	# not told about the freeze is visibly wrong, every snapshot, for as long as it lasts.
	var _thaw: DotResult = freeze.call(&"7", {"on": false})
	var speed := _server_world.tunables.max_speed
	_server_world.tunables.max_speed = 0.0
	var naive_freeze := _admin_window(60, command)
	_server_world.tunables.max_speed = speed
	print("  measured: freeze shipped worst %.2f; naive worst %.2f (%d ticks over 8), pulled back to %.2f in the middle third and %.2f in the last" % [
		float(still["worst"]), float(naive_freeze["worst"]), int(naive_freeze["over"]),
		float(naive_freeze["early"]), float(naive_freeze["late"])
	])
	_check(
		float(naive_freeze["worst"]) > 2.0,
		"a server-only freeze is one the client predicts its way out of: the rubber band",
		"naive worst %.2f — if this passes quietly, the checks above prove nothing" % float(naive_freeze["worst"])
	)
	_check(
		float(naive_freeze["late"]) <= float(naive_freeze["early"]) + 1.0,
		"and one it is pulled back from, every snapshot, rather than walks away from",
		"pulled back to %.2f in the middle third, only to %.2f in the last" % [
			float(naive_freeze["early"]), float(naive_freeze["late"])
		]
	)

	_back_to(from)
	_done()


func _rock_at(at: Vector2) -> HungryLayout:
	var layout := HungryLayout.none()
	layout.blocks = PackedVector3Array([Vector3(at.x, at.y, 40.0)])
	return layout


## Puts monster 7 back at [param at] on the server and lets both ends settle, so the next
## window starts from agreement rather than from the last one's disagreement.
func _back_to(at: Vector2) -> void:
	for piece in _server_world.monster_for(7).pieces:
		piece.state.position = at
		piece.state.velocity = Vector2.ZERO
	_steps(20)


## [param ticks] more ticks holding [param command], comparing where the client predicted
## its monster at each tick with where the server had it at the SAME tick:
## `{worst, over}`, the second counting ticks more than eight units apart.
func _admin_window(ticks: int, command: Dot2DCommand) -> Dictionary:
	var client_at := {}
	var server_at := {}

	for _i in range(ticks):
		_tick += 1
		_server_bridge.server_tick(_tick)
		server_at[_tick] = _server_world.monster_for(7).centre()
		_flush()
		_client_bridge.client_tick(_tick + INPUT_LEAD, command)
		client_at[_tick + INPUT_LEAD] = _client_world.monster_for(7).centre()
		_flush()

	var worst := 0.0
	var over := 0
	# The SMALLEST gap in the middle and the last third of the window: the floor a client
	# comes back to. A client pulled back every snapshot saws between that floor and its
	# lead all window long, so the floor stays put; one that walks away has a floor that
	# climbs with it. The worst gap cannot tell the two apart — one late snapshot on a
	# healthy client raises it as far as a slow walk does — and the first third is left out
	# because it holds the ticks before the client has started moving at all.
	var early := INF
	var late := INF
	var ordered: Array = server_at.keys()
	ordered.sort()
	var third := ordered.size() / 3.0

	for index in range(ordered.size()):
		var tick: int = ordered[index]
		if not client_at.has(tick):
			continue
		var gap: float = (client_at[tick] as Vector2).distance_to(server_at[tick] as Vector2)
		worst = maxf(worst, gap)
		if index >= 2.0 * third:
			late = minf(late, gap)
		elif index >= third:
			early = minf(early, gap)
		if gap > 8.0:
			over += 1

	return {"worst": worst, "over": over, "early": early, "late": late}


func _test_field_replication() -> void:
	_section("food")

	# Put the monster on a crumb and let it eat. What has to arrive is not the crumb but
	# the fact that it is gone.
	var target := 0

	for grid_id in _server_world.field.alive_ids():
		if HungryField.kind_of(grid_id) == HungryField.Kind.FOOD:
			target = grid_id
			break

	_server_world.spawn(7, _server_world.field.position_of(target))
	_steps(4)

	_check(
		not _server_world.field.food.is_alive(HungryField.index_of(target)),
		"the server ate a crumb"
	)
	_check(
		not _client_world.field.food.is_alive(HungryField.index_of(target)),
		"and the client was told"
	)
	_check(
		absi(_client_world.field.alive_count() - _server_world.field.alive_count()) <= 8,
		"and the two fields stay in step (%d vs %d)" % [
			_client_world.field.alive_count(), _server_world.field.alive_count()
		]
	)

	# The refill also has to travel, or a client's world empties over a long round while
	# the server's stays full.
	var before := _client_world.field.alive_count()
	_steps(30)
	_check(
		_client_world.field.alive_count() >= before,
		"and the refill arrives too"
	)
	_done()


func _test_splitting_replicates() -> void:
	_section("splitting, over the wire")

	var monster := _server_world.monster_for(7)
	monster.rider_piece().set_mass(500.0, _server_world.tunables.mass_rules)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)

	var before := _client_bridge.piece_count()

	var split := Dot2DCommand.new()
	split.aim = Vector2.RIGHT
	split.reach = 700.0
	split.set_button(Dot2DCommand.BUTTON_SPLIT, true)

	_step(split)

	var release := Dot2DCommand.new()
	release.aim = Vector2.RIGHT
	release.reach = 700.0
	_steps(10, release)

	_check(
		_server_world.monster_for(7).piece_count() > 1,
		"the server split them (%d pieces)"
			% _server_world.monster_for(7).piece_count()
	)
	_check(
		_client_bridge.piece_count() > before,
		"and the client mirrored the new piece (%d -> %d)" % [
			before, _client_bridge.piece_count()
		]
	)
	_check(
		_client_world.monster_for(7).piece_count()
			== _server_world.monster_for(7).piece_count(),
		"and holds the same number of them"
	)

	# Both ends must agree which piece the rider is on, or the avatar is drawn on a
	# different fragment on every machine.
	var server_rider := _server_world.monster_for(7).rider_piece()
	var client_rider := _client_world.monster_for(7).rider_piece()
	_check(
		server_rider != null and client_rider != null
			and server_rider.id == client_rider.id,
		"and on the same piece the rider is on"
	)

	# And a merge has to take the entity away again, or a client accumulates ghosts.
	var pieces_before := _client_bridge.piece_count()
	_server_world.forget_piece(server_rider.id)
	_flush()
	_check(
		_client_bridge.piece_count() < pieces_before,
		"a piece that goes away is despawned everywhere"
	)
	_done()


func _test_throw_replicates() -> void:
	_section("throwing, over the wire")

	var monster := _server_world.monster_for(7)
	_server_world.spawn(7, Vector2.ZERO)
	monster.clear_effect(HungryContent.FLAG_PROTECTED)
	monster.carried.clear()
	monster.take_item(HungryContent.ITEM_PEPPER)
	monster.throw_ready_tick = _server_world.current_tick()

	var thrown: Array[int] = []
	_client_bridge.cue.connect(func(kind: int, _data: Dictionary) -> void:
		thrown.append(kind)
	)

	var throw_command := Dot2DCommand.new()
	throw_command.aim = Vector2.RIGHT
	throw_command.reach = 600.0
	throw_command.set_button(Dot2DCommand.BUTTON_ACTION, true)

	# Inputs are stamped ahead of the server, so the press lands a couple of ticks later.
	_steps(INPUT_LEAD + 2, throw_command)

	_check(
		_client_world.projectiles().size() == 1,
		"the client sees the pepper in flight (%d)"
			% _client_world.projectiles().size()
	)

	# The flight is a straight line from a start tick, so both ends draw it in the same
	# place without another byte.
	if _client_world.projectiles().size() == 1 \
			and _server_world.projectiles().size() == 1:
		var here := _client_world.projectiles()[0].position_at(_tick + 20, TICK_RATE)
		var there := _server_world.projectiles()[0].position_at(_tick + 20, TICK_RATE)
		_check(
			here.distance_to(there) < 2.0,
			"and in the same place twenty ticks on (%.2f apart)" % here.distance_to(there)
		)

	var release := Dot2DCommand.new()
	_steps(120, release)

	_check(
		_server_world.projectiles().is_empty(),
		"the server resolves it"
	)
	_check(
		_client_world.projectiles().is_empty(),
		"and the client stops drawing it"
	)
	_check(
		thrown.has(HungryEvents.Kind.THROW) and thrown.has(HungryEvents.Kind.IMPACT),
		"and both cues arrived"
	)

	# Owner-only: what you are carrying is not something an opponent should be told.
	_check(
		_client_world.monster_for(7).carried.size()
			== _server_world.monster_for(7).carried.size(),
		"and the carry list reached its owner"
	)
	_done()


func _test_interest() -> void:
	_section("interest")

	var interest := _server_net.interest as HungryInterest
	_check(interest != null, "the server uses this game's interest rule")

	if interest == null:
		_done()
		return

	var rect := interest.view_rect(CLIENT_PEER)
	_check(rect.size.x > 0.0, "which knows where the observer is")

	# A monster wide enough to fill the screen has to see further, or it can never find
	# anything worth eating.
	var small := interest.view_rect(CLIENT_PEER).size
	_server_world.monster_for(7).rider_piece().set_mass(
		9000.0, _server_world.tunables.mass_rules
	)
	var large := interest.view_rect(CLIENT_PEER).size

	_check(
		large.x > small.x,
		"and grows with the monster (%.0f -> %.0f)" % [small.x, large.x]
	)

	_server_world.monster_for(7).rider_piece().set_mass(
		HungryContent.START_MASS, _server_world.tunables.mass_rules
	)

	# Somebody on the far side of the world must not be in the snapshot at all. This is
	# the anti-cheat that works: data never sent cannot be drawn on a wallhack.
	_server_bridge.add_player(0, 99, "Far Away")
	_server_world.spawn(99, _server_world.arena.bounds.position + Vector2(60.0, 60.0))
	_server_world.spawn(7, _server_world.arena.bounds.end - Vector2(60.0, 60.0))
	_steps(20)

	var far_identity: DotNetIdentity = null

	for identity in _server_net.registry.all():
		for behaviour in identity.behaviours:
			var piece := behaviour as HungryPieceNet

			if piece != null and piece.piece != null and piece.piece.owner_id == 99:
				far_identity = identity

	_check(far_identity != null, "there is somebody on the far side of the world")

	if far_identity != null:
		_check(
			not interest._is_relevant(
				_server_net._observer_for(CLIENT_PEER), far_identity, {}
			),
			"and they are not relevant to a player at the other end"
		)
	_done()


## An administrator's blind and beacon, through the real handlers, over the link.
##
## [b]The audience is the whole point of both.[/b] The client is peer 2 and owns player 7;
## player 99 is a bot on the far side of the arena that `_test_interest` put there, owned
## by nobody on this link. A blind is its owner's screen and nobody else's, so the client
## must receive 7's and must NOT receive 99's — an opponent who could read it would know
## the moment somebody could not see them coming. A beacon is everybody's, and 99's has to
## arrive although 99 is outside the client's view: that is what making a beaconed monster
## always relevant is for, and the negative control is that before the beacon the client
## was told nothing about 99 at all. Asserted on the client's own copy of each monster,
## which is what its HUD and its renderer read.
func _test_blind_and_beacon() -> void:
	_section("an admin's blind and beacon: who is told")

	var server_fn := func() -> HungryWorld: return _server_world
	var tools := HungryModTools.handlers(server_fn)
	var blind: Callable = tools[DotModTools.ACTION_BLIND]
	var beacon: Callable = tools[DotModTools.ACTION_BEACON]

	var far_monster := _server_world.monster_for(99)
	var far_piece := far_monster.pieces[0].id if far_monster != null and far_monster.piece_count() > 0 else 0
	var mine := _client_bridge.behaviour_for(_server_world.monster_for(7).pieces[0].id)
	var far_on_client := _client_bridge.behaviour_for(far_piece)

	_check(
		mine != null and mine.find_var(&"net_blind").audience == DotNetVar.Audience.OWNER
			and mine.find_var(&"net_beacon").audience == DotNetVar.Audience.EVERYONE,
		"the blind is declared owner-only and the beacon for everybody"
	)
	_check(
		far_on_client != null and _client_world.monster_for(99) != null,
		"the client knows the far player exists, from their spawn"
	)

	if mine == null or far_on_client == null or _client_world.monster_for(99) == null:
		for what in ["control", "owner", "not told", "far beacon", "relevant", "own", "off", "irrelevant"]:
			_check(false, what)
		_done()
		return

	# The negative control first: out of view, the far player's state never arrives.
	var quiet_since := far_on_client.last_state_tick
	_steps(20)
	_check(
		far_on_client.last_state_tick == quiet_since,
		"before a beacon the far player's state never reaches the client",
		"last state tick %d -> %d" % [quiet_since, far_on_client.last_state_tick]
	)

	var on_mine: DotResult = blind.call(&"7", {"on": true, "actor": "1"})
	var on_far: DotResult = blind.call(&"99", {"on": true, "actor": "1"})
	var lit: DotResult = beacon.call(&"99", {"on": true, "actor": "1"})
	_steps(30)

	_check(
		on_mine.ok and _client_world.monster_for(7).blinded,
		"the owner's client blacks its own screen out"
	)
	_check(
		on_far.ok and _server_world.monster_for(99).blinded
			and not _client_world.monster_for(99).blinded and not far_on_client.net_blind,
		"and a blind on somebody else is never sent to it",
		"the client received net_blind = %s for player 99" % str(far_on_client.net_blind)
	)
	_check(
		lit.ok and _client_world.monster_for(99).beacon,
		"while a beacon on the far player reaches it, across the arena"
	)
	_check(
		_server_bridge.behaviour_for(far_piece).identity.always_relevant
			and far_on_client.last_state_tick > quiet_since,
		"because a beaconed monster is relevant to everybody, however far away",
		"last state tick %d" % far_on_client.last_state_tick
	)
	_check(
		not _client_world.monster_for(7).beacon,
		"and the beacon lands on nobody else"
	)

	var _off_mine: DotResult = blind.call(&"7", {"on": false, "actor": "1"})
	var _off_far: DotResult = blind.call(&"99", {"on": false, "actor": "1"})
	var _unlit: DotResult = beacon.call(&"99", {"on": false, "actor": "1"})
	_steps(30)

	_check(
		not _client_world.monster_for(7).blinded and not _client_world.monster_for(99).beacon,
		"turning both off reaches the client"
	)
	_check(
		not _server_bridge.behaviour_for(far_piece).identity.always_relevant,
		"and puts the far player back under the ordinary interest rules"
	)
	_done()


func _test_avatar() -> void:
	_section("avatars")

	var schema := _client_bridge.avatar_schema
	_check(schema != null and schema.validate_schema().ok, "the rider schema is legal")

	var mine := DotAvatar.make(schema.id)
	mine.set_part(&"body", &"rider_blob")
	mine.set_part(&"hat", &"hat_cap")
	mine.set_colour(&"body", 0, Color(0.9, 0.2, 0.3))

	_client_bridge.publish_avatar(mine)
	_flush()
	_flush()

	var stored := _server_world.monster_for(7).avatar
	_check(
		stored != null and stored.part_in(&"body") == &"rider_blob",
		"a client's avatar reaches the server"
	)
	_check(
		stored != null and stored.digest() == mine.digest(),
		"unchanged",
		"%s vs %s" % [stored.digest() if stored != null else "-", mine.digest()]
	)

	# The server validates against the schema and loads nothing to do it. A part that is
	# not in the schema is refused rather than clamped to whatever is at the boundary.
	var forged := DotAvatar.make(schema.id)
	forged.set_part(&"body", &"rider_pip")
	forged.parts[&"cheat"] = &"nonexistent"

	var refused := schema.validate(forged, DotAvatarEntitlements.everything())
	_check(not refused.ok, "and a slot the schema does not have is refused")
	_done()


## A monster somebody else is steering has to move smoothly.
##
## [b]The interpolated value has to reach the simulation, not just the property.[/b]
## Snapshots arrive 20 times a second; frames render far more often. dot-net computes the
## smoothed position every frame and writes it into `net_position` — and if the only thing
## that copies `net_position` into the piece is the snapshot handler, every remote monster
## moves in 50 ms steps while the smooth value sits in a property nothing reads. It looks
## exactly like an interpolator that does not work.
func _test_interpolation() -> void:
	_section("watching somebody else move")

	# A player with no peer: a bot, from the client's point of view an entity it does not
	# own and therefore does not predict — which is the only kind interpolation applies to.
	_server_bridge.add_player(0, 42, "Someone Else")

	# Both near the middle, with room to move. An earlier section parked the client's
	# monster against a wall, and a monster pushed into a wall does not move — which
	# produces a track of identical samples and an interpolation check that passes for
	# the wrong reason.
	_server_world.spawn(7, Vector2.ZERO)
	_server_world.spawn(42, Vector2(220.0, 0.0))

	var drift := Dot2DCommand.new()
	drift.aim = Vector2.RIGHT
	drift.reach = 900.0

	for _i in range(40):
		_server_bridge.note_command(42, drift)
		_step()

	var mirrored := _client_world.monster_for(42)

	if not _check(
		mirrored != null and mirrored.piece_count() > 0,
		"the client mirrors a monster it does not own"
	):
		_done()
		return

	var behaviour: HungryPieceNet = mirrored.pieces[0].net

	_check(
		behaviour != null and behaviour.identity != null
			and not behaviour.identity.is_predicted(),
		"and does not predict it"
	)

	# The value the last snapshot carried, before any interpolation runs.
	var snapshotted := behaviour.net_position

	_client_net.interpolate_frame()
	var first := mirrored.pieces[0].position()

	# [b]Behind the snapshot, not equal to it.[/b] Rendering happens in the past by one
	# buffer length so that both bracketing samples have arrived, so an interpolated
	# position that exactly equalled the newest snapshot would mean nothing had
	# interpolated at all — which is what a value written only by the snapshot handler
	# looks like.
	_check(
		first != snapshotted,
		"interpolation renders behind the newest snapshot (%.2f units)"
			% first.distance_to(snapshotted)
	)
	_check(
		first.distance_to(behaviour.net_position) < 0.01,
		"and reaches the piece, not just the property (%.3f apart)"
			% first.distance_to(behaviour.net_position)
	)

	# Advance the client's own clock without delivering anything, and the drawn position
	# has to keep moving. This is the whole difference between rendering at the snapshot
	# rate and rendering at the frame rate: `render_tick` is derived from the client's
	# estimate of the server tick, and an estimate that only moved when a packet arrived
	# would give the same answer on every frame in between.
	for _i in range(6):
		_client_net.clock.advance(1.0 / float(TICK_RATE))

	_client_net.interpolate_frame()
	var second := mirrored.pieces[0].position()

	_check(
		second != first,
		"and keeps moving between snapshots (%.2f units)" % second.distance_to(first)
	)
	_check(
		second.distance_to(first) < 60.0,
		"by a plausible amount rather than extrapolating away (%.2f)"
			% second.distance_to(first)
	)

	_server_bridge.remove_peer(0)
	_server_world.remove_player(42)
	_flush()
	_done()


func _test_loadout() -> void:
	_section("loadouts")

	var schema := _server_bridge.loadout_schema
	_check(schema != null and schema.validate().ok, "both ends hold the same schema")

	var mine := DotLoadout.empty(schema.id)
	mine.set_item(HungryContent.SLOT_STARTER, HungryContent.ITEM_LURE)
	mine.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_STURDY)

	_client_bridge.publish_loadout(mine)
	_flush()
	_flush()

	var server_monster := _server_world.monster_for(7)
	_check(
		server_monster.trait_id == HungryContent.TRAIT_STURDY,
		"a published loadout reaches the server (%s)" % server_monster.trait_id
	)
	_check(
		server_monster.starter_item() == HungryContent.ITEM_LURE,
		"with both slots (%s)" % server_monster.starter_item()
	)

	# It comes back in the join, because the trait changes how fast a monster moves and
	# the owning client predicts that movement. Two ends computing speed from different
	# loadouts is a permanent mispredict, not a rounding error.
	var client_monster := _client_world.monster_for(7)
	_check(
		client_monster.trait_id == HungryContent.TRAIT_STURDY,
		"and comes back to every client (%s)" % client_monster.trait_id
	)
	_check(
		is_equal_approx(
			client_monster.speed_multiplier(), server_monster.speed_multiplier()
		),
		"so both ends agree how fast they move (%.3f vs %.3f)" % [
			client_monster.speed_multiplier(), server_monster.speed_multiplier()
		]
	)

	# And the trade is real, on the next spawn rather than immediately: a player who could
	# change their trait mid-fight would change it the moment they were losing.
	_server_world.spawn(7)
	_check(
		_server_world.monster_for(7).mass()
			> HungryContent.START_MASS * HungryContent.trait_mass(
				HungryContent.TRAIT_NIMBLE
			),
		"and sturdy spawns bigger (%.1f)" % _server_world.monster_for(7).mass()
	)
	_check(
		_server_world.monster_for(7).carried.has(HungryContent.ITEM_LURE),
		"holding what they asked for"
	)

	# Nobody owns the greedy trait, so the server must refuse it — a client that could
	# make the server repair its way to a legal loadout can put anything in any slot.
	var cheating := DotLoadout.empty(schema.id)
	cheating.set_item(HungryContent.SLOT_STARTER, HungryContent.ITEM_PEPPER)
	cheating.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_GREEDY)

	_client_bridge.publish_loadout(cheating)
	_flush()
	_flush()

	_check(
		_server_world.monster_for(7).trait_id == HungryContent.TRAIT_STURDY,
		"an unowned trait is refused rather than repaired (%s)"
			% _server_world.monster_for(7).trait_id
	)

	# A trait in the throwable slot is a different refusal for a different reason, and a
	# loadout screen shows them differently.
	var muddled := DotLoadout.empty(schema.id)
	muddled.set_item(HungryContent.SLOT_STARTER, HungryContent.TRAIT_NIMBLE)
	muddled.set_item(HungryContent.SLOT_TRAIT, HungryContent.TRAIT_NIMBLE)

	_client_bridge.publish_loadout(muddled)
	_flush()
	_flush()

	_check(
		_server_world.monster_for(7).starter_item() == HungryContent.ITEM_LURE,
		"and so is an item in the wrong slot"
	)
	_done()


func _test_direction_enforced() -> void:
	_section("direction")

	# Without this any client could send every other client a spawn, a death or a
	# leaderboard. It is checked against the transport's view of the sender, never
	# against a peer id inside the payload.
	var writer := DotNetWriter.new()
	var event := HungryEvent.new(HungryEvents.Kind.DIED, HungryEvents.write_pair(7, 7))
	_server_net.messages.encode(event, writer)

	var before := _server_net.stats.direction_violations
	var refused := _server_net.receive(writer.to_bytes(), CLIENT_PEER)

	_check(not refused.ok, "a client may not send a server-to-client event")
	_check(
		_server_net.stats.direction_violations > before,
		"and it is counted as a violation"
	)
	_done()


func _test_loss() -> void:
	_section("packet loss")

	_server_world.spawn(7, Vector2.ZERO)
	_steps(10)

	# One snapshot in four on the floor. Position recovers on its own — a newer one
	# supersedes it — but anything that changes rarely would be stranded at a stale value
	# for ever without the acknowledgements the input packets carry.
	_drop_every = 4

	var command := Dot2DCommand.new()
	command.aim = Vector2(0.7, 0.7).normalized()
	command.reach = 900.0

	_steps(150, command)
	_drop_every = 0

	# Stopped, and standing on bare ground. Mass is authoritative and interpolated, so a
	# monster that is still eating is a monster whose two copies are always one crumb
	# apart — which says nothing about whether the loss was recovered from. Clearing the
	# ground under it is what makes the comparison mean "the value converged" rather than
	# "the value is moving".
	var head := _server_world.monster_for(7).rider_piece()

	for grid_id in _server_world.arena.grid.query_circle(
		head.position(), head.radius() * 6.0
	):
		if HungryField.is_edible(grid_id) and _server_world.field.take(grid_id):
			_server_world.arena.grid.remove(grid_id)

	_steps(40, Dot2DCommand.new())

	var apart := _client_world.monster_for(7).centre().distance_to(
		_server_world.monster_for(7).centre()
	)

	_check(
		_client_net.stats.snapshots_lost > 0,
		"loss was detected (%d snapshots)" % _client_net.stats.snapshots_lost
	)

	# Recovery above depends entirely on the ack header the input packets carry, and
	# the server degrades to a conservative view rather than failing when it never
	# arrives — so a bridge whose ACK_BYTES and encode_ack() disagree would still get
	# most of this section right. Ask the server whether the wiring took.
	_check(
		_server_net.peer_acks_wired(CLIENT_PEER),
		"because the client's acknowledgements are reaching the server",
		"without them the server keeps the conservative view and never re-sends"
	)
	_check(
		apart < 12.0,
		"and the client still tracks the server (%.2f units apart)" % apart
	)
	_check(
		_client_net.stats.decode_failures == 0,
		"with no decode failures"
	)

	var server_mass := _server_world.monster_for(7).mass()
	var client_mass := _client_world.monster_for(7).mass()

	_check(
		absf(server_mass - client_mass) < 1.0,
		"and the mass converged exactly once it stopped (%.1f vs %.1f)"
			% [server_mass, client_mass]
	)
	_done()


func _test_game_change() -> void:
	_section("changing the game underneath them")

	var before_pieces := _client_bridge.piece_count()
	_check(before_pieces > 0, "there is something to lose (%d pieces)" % before_pieces)

	var next := HungryWorld.new()
	next.name = "NextWorld"
	next.preset = HungryPreset.frenzy()
	next.tick_rate = TICK_RATE
	next.world_seed = SEED + 1
	next.is_authority = true
	next.register_service = false
	add_child(next)
	next.setup()
	next.start(_tick)

	var rebound := _server_bridge.rebind(next)
	_check(rebound.ok, "the bridge rebinds onto a new world", str(rebound.error))

	_flush()
	_steps(30)

	_check(
		_server_bridge.player_for_peer(CLIENT_PEER) == 7,
		"the peer is still here"
	)
	_check(
		next.monster_for(7) != null and next.monster_for(7).alive,
		"and has a monster in the new world"
	)
	_check(
		_client_world.field.seed_value() == next.field.seed_value(),
		"the client took the new field seed"
	)
	_check(
		absi(_client_world.field.alive_count() - next.field.alive_count()) <= 30,
		"and the new field (%d vs %d)" % [
			_client_world.field.alive_count(), next.field.alive_count()
		]
	)
	_check(
		_client_bridge.piece_count() == _server_bridge.piece_count(),
		"and the same pieces (%d vs %d)" % [
			_client_bridge.piece_count(), _server_bridge.piece_count()
		]
	)

	# The match entity survives a change on purpose: its net id is already known to every
	# client, and re-spawning it would make each of them mirror a second one.
	_check(
		_client_bridge.match_behaviour() != null,
		"and the match entity was not duplicated"
	)

	remove_child(next)
	next.queue_free()
	_done()


## [warren-net-1]: a round of `warrens`, and a client predicting itself against one of its
## rocks.
##
## [b]The half of the layout no single-world check can see.[/b] `headless_round` proves a
## client world pushes itself out of the same rocks (`simulate_piece` runs `block_piece`),
## and the admin section above proves a noclip is predicted through a stand-in rock. What
## neither does is the thing a player meets: the server changed to a level, the client
## built the level from the name in the hello, and the client's own monster pressed
## against a rock face for seconds, reconciled against every snapshot. A push-out that the
## replay did not repeat — or a client whose layout differed by one disc — reads as
## rubber-banding along the face, which sends the next person to the netcode.
##
## [b]And its negative control.[/b] The same window with the rock missing from the CLIENT
## only must come apart, or the first half passes because nothing was ever asked to
## disagree.
##
## [b]A split monster against the rock is measured and bounded, not held to the same
## number.[/b] `_separate` is applied live on both ends and not replayed, so while two
## pieces overlap the replay and the shown positions differ by a fraction of the overlap;
## that is the named cost in CLAUDE.md, and this is where its size is written down.
func _test_warrens_rock_converges() -> void:
	_section("a round of warrens: a client predicting itself against a rock")

	var warrens := HungryWorld.new()
	warrens.name = "WarrensWorld"
	warrens.preset = HungryPreset.warrens()
	warrens.tick_rate = TICK_RATE
	warrens.world_seed = SEED + 2
	warrens.is_authority = true
	warrens.register_service = false
	add_child(warrens)
	warrens.setup()
	warrens.start(_tick)

	var rebound := _server_bridge.rebind(warrens)

	if not _check(rebound.ok, "the bridge rebinds onto a warrens world", str(rebound.error)):
		remove_child(warrens)
		warrens.queue_free()
		_done()
		return

	_flush()

	for _i in range(TICK_RATE * 10):
		if warrens.match_node.is_live():
			break
		_step()

	_steps(20)

	_check(
		_client_world.layout.id == HungryLayout.WARRENS
			and _client_world.layout.count() == warrens.layout.count(),
		"the client built the warrens from the name in the hello",
		"%s, %d rocks against %d" % [
			_client_world.layout.id, _client_world.layout.count(), warrens.layout.count()
		]
	)

	var monster := warrens.monster_for(7)

	if not _check(monster != null and monster.alive, "and player 7 is alive in it"):
		_server_bridge.rebind(_server_world)
		remove_child(warrens)
		warrens.queue_free()
		_done()
		return

	# Outside ring rock 0, driven dead at its centre: pressed against the face for the whole
	# window. Four degrees off, which the round suite uses to prove a monster slides in,
	# leaves the face after 41 ticks here, and a window mostly spent in the open measures
	# the open.
	var rock: Vector3 = warrens.layout.blocks[0]
	var rock_at := Vector2(rock.x, rock.y)
	var centre := warrens.arena.bounds.get_center()
	# Sixty units off the face, so the window is spent pressed rather than approaching.
	var start := rock_at + (rock_at - centre).normalized() * (rock.z + 60.0)
	var command := Dot2DCommand.new()
	command.aim = (rock_at - start).normalized()
	command.reach = 900.0

	_put(warrens, start)
	var pressed := _rock_window(warrens, 150, command, rock)
	print("  measured: against a rock, worst %.2f over %d ticks; %d in contact, worst %.2f and mean %.2f there; deepest %.2f" % [
		float(pressed["worst"]), int(pressed["ticks"]), int(pressed["contact"]),
		float(pressed["contact_worst"]), float(pressed["contact_mean"]), float(pressed["deepest"])
	])
	_check(
		int(pressed["contact"]) > 100,
		"the monster spent the window pressed against the rock",
		"%d ticks in contact" % int(pressed["contact"])
	)
	_check(
		float(pressed["deepest"]) > -2.0,
		"the server never let it into the rock",
		"deepest %.2f" % float(pressed["deepest"])
	)
	# [b]On the ticks in contact, because that is where a push-out that was not replayed
	# would show.[/b] Over the whole window both this and the control below are bounded by
	# the snapshot corrections — 3.6 and 7.5 units when this was first measured, too close
	# to call — while pressed against the face the replay either agrees with the server to
	# a rounding error or is corrected on every snapshot.
	_check(
		float(pressed["contact_mean"]) < 1.0,
		"and while it was pressed there the client agreed with the server to within a unit",
		"worst %.2f, mean %.2f in contact; %.2f over the whole window"
			% [float(pressed["contact_worst"]), float(pressed["contact_mean"]), float(pressed["worst"])]
	)

	# The negative control: the rock gone from the client's world only.
	_put(warrens, start)
	_client_world.layout = HungryLayout.none()
	var naive := _rock_window(warrens, 150, command, rock)
	_client_world.adopt_layout(HungryLayout.WARRENS)
	print("  measured: the rock missing from the client, %d in contact, worst %.2f and mean %.2f there" % [
		int(naive["contact"]), float(naive["contact_worst"]), float(naive["contact_mean"])
	])
	_check(
		float(naive["contact_mean"]) > 2.0
			and float(naive["contact_mean"]) > float(pressed["contact_mean"]) * 4.0 + 0.5,
		"a client that does not know the rock is corrected all along its face",
		"naive mean %.2f in contact against %.2f — if this passes quietly, the check above proves nothing"
			% [float(naive["contact_mean"]), float(pressed["contact_mean"])]
	)

	# Split against the face: the pieces overlap, and `_separate` is not replayed.
	_put(warrens, start)
	warrens.feed_player(7, 200.0)
	_steps(10)
	var split := Dot2DCommand.new()
	split.aim = command.aim
	split.reach = command.reach
	split.buttons = Dot2DCommand.BUTTON_SPLIT
	_step(split)
	var halves := _rock_window(warrens, 120, command, rock)
	print("  measured: split against the rock, %d pieces, worst %.2f (%d ticks over 8), last %.2f" % [
		warrens.monster_for(7).piece_count(), float(halves["worst"]), int(halves["over"]),
		float(halves["final"])
	])
	_check(
		warrens.monster_for(7).piece_count() >= 2,
		"a monster that splits against the rock is in pieces",
		"%d" % warrens.monster_for(7).piece_count()
	)
	_check(
		float(halves["final"]) < 8.0,
		"and its client comes back to the server once the pieces are apart",
		"worst %.2f on the way, %.2f at the end" % [float(halves["worst"]), float(halves["final"])]
	)

	# Back onto the world every later line of this file expects.
	_server_bridge.rebind(_server_world)
	_flush()
	remove_child(warrens)
	warrens.queue_free()
	_done()


## Puts monster 7 at [param at] in [param world], still, and lets both ends agree.
func _put(world: HungryWorld, at: Vector2) -> void:
	for piece in world.monster_for(7).pieces:
		piece.state.position = at
		piece.state.velocity = Vector2.ZERO
	_steps(30)


## [method _admin_window] against a named world and a rock: where the client predicted
## monster 7 at each tick against where [param world] had it at the SAME tick, and how many
## ticks the server's monster spent touching [param rock].
func _rock_window(world: HungryWorld, ticks: int, command: Dot2DCommand, rock: Vector3) -> Dictionary:
	var client_at := {}
	var server_at := {}
	var contact := 0
	var deepest := INF
	var at := Vector2(rock.x, rock.y)
	var touching := {}

	for _i in range(ticks):
		_tick += 1
		_server_bridge.server_tick(_tick)
		server_at[_tick] = world.monster_for(7).centre()

		for piece in world.monster_for(7).pieces:
			var gap := piece.position().distance_to(at) - rock.z - piece.radius()
			deepest = minf(deepest, gap)

			if gap < 1.0:
				contact += 1
				touching[_tick] = true
				break

		_flush()
		_client_bridge.client_tick(_tick + INPUT_LEAD, command)
		client_at[_tick + INPUT_LEAD] = _client_world.monster_for(7).centre()
		_flush()

	var worst := 0.0
	var over := 0
	var final := 0.0
	var measured := 0
	var contact_worst := 0.0
	var contact_sum := 0.0
	var contact_measured := 0

	for tick in server_at:
		if not client_at.has(tick):
			continue
		var gap: float = (client_at[tick] as Vector2).distance_to(server_at[tick] as Vector2)
		worst = maxf(worst, gap)
		final = gap
		measured += 1
		if gap > 8.0:
			over += 1
		if touching.has(tick):
			contact_worst = maxf(contact_worst, gap)
			contact_sum += gap
			contact_measured += 1

	return {
		"worst": worst, "over": over, "final": final, "ticks": measured,
		"contact": contact, "deepest": deepest, "contact_worst": contact_worst,
		"contact_mean": contact_sum / float(maxi(1, contact_measured)),
	}

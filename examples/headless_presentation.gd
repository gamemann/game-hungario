extends Node

const HungryConfig := preload("../game/hungry_config.gd")
const HungryParty := preload("../game/hungry_party.gd")
const HungryPresentation := preload("../game/client/hungry_presentation.gd")
const HungryServices := preload("../game/hungry_services.gd")
const HungrySound := preload("../game/client/hungry_sound.gd")
const HungrySoundSink := preload("../game/client/hungry_sound_sink.gd")
const HungryEvents := preload("../game/net/hungry_events.gd")
const HungryHud := preload("../game/client/hungry_hud.gd")
const HungryPreset := preload("../game/hungry_preset.gd")
const HungryRenderer := preload("../game/client/hungry_renderer.gd")
const HungryWorld := preload("../game/hungry_world.gd")

## Settings, audio, effects, the console and the private arena.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]The point of this game's integration is what it does NOT duplicate[/b], so that is
## what most of these checks are about: the settings schema is read out of `HungryConfig`
## rather than written beside it, and dot-audio's sink is `HungrySound` rather than a
## second bank. Both are the same decision twice — two copies of one list is this family's
## most repeated bug.
##
## Exits non-zero on any failure.

const CHECKS := 83

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-hungario: the presentation layer")

	# First, before this run opens anything — the party section binds a rendezvous — so
	# the copy and this run never contend for a port. See [method _run_exit_probe].
	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

	_test_schema_is_the_config()
	_test_sound_is_still_the_bank()
	_test_limits_the_bank_never_had()
	_test_effects()
	_test_console()
	_test_party()
	await _test_party_over_http()
	_test_chat_box()
	_test_the_vote_is_heard()
	_test_blind_and_beacon()

	if not probe.is_empty():
		_test_exits_clean(probe)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  %s" % f)
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
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


func _make() -> HungryPresentation:
	var p := HungryPresentation.new()
	p.name = "P%d" % _entered
	p.config = HungryConfig.new()
	p.sound = HungrySound.make()
	add_child(p.sound)
	add_child(p)
	p.setup()
	# A memory store, replacing the file one this game ships with.
	#
	# [b]A suite that writes to `user://` is a suite whose result depends on what the last
	# run left there.[/b] This game already shipped that bug once: `dedicated` recorded
	# bites against a fixed player key, the totals accumulated across runs, and it began
	# failing on its ninth run for a reason that had nothing to do with the code. Here it
	# was subtler -- a value stored by the previous run made `set_value` a no-op, the
	# signal never fired, and the check failed for a setting that was already correct.
	p.settings.local_store = DotSettingsStoreMemory.new()
	p.settings.load_now()
	p.apply_all()
	return p


# --- 1 ----------------------------------------------------------------------

func _test_schema_is_the_config() -> void:
	_section("The schema is HungryConfig, read rather than repeated")

	var config := HungryConfig.new()
	var schema := DotSettingsSchema.from_config(config, HungryPresentation.SCOPES)

	_check(schema.validate().ok, "a schema derived from the config validates")
	_check(
		schema.keys().size() == config.config_keys().size(),
		"with one entry per config key (%d against %d)"
		% [schema.keys().size(), config.config_keys().size()]
	)
	_check(schema.has(&"volume_db"), "including the volume")

	var vol := schema.find(&"volume_db")
	_check(
		vol.min_value < vol.max_value,
		"and its bounds come from the @export_range, so tightening the config tightens "
		+ "the slider and the console at once"
	)

	_check(
		schema.find(&"show_names").scope == DotSettingsDef.Scope.ACCOUNT,
		"the scope is the one thing a config cannot say, so it is passed in"
	)
	_check(
		schema.find(&"follow_sec").scope == DotSettingsDef.Scope.DEVICE,
		"and a camera follow time stays with the machine, because it is about this screen"
	)

	var p := _make()
	p.settings.set_value(&"volume_db", -20.0)
	_check(
		is_equal_approx(p.config.volume_db, -20.0),
		"a setting written through dot-settings reaches the config the game actually reads"
	)
	_check(
		is_equal_approx(p.sound.volume_db, -20.0),
		"and the bank, which is the value a player can hear"
	)
	p.queue_free()
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_sound_is_still_the_bank() -> void:
	_section("dot-audio's sink is the bank this game already had")

	var p := _make()
	var sink := p.audio.sink as HungrySoundSink
	_check(sink != null, "the sink is this game's, not dot-audio's own")
	if sink == null:
		p.queue_free()
		_done()
		return

	_check(sink.sound == p.sound, "with the generated bank behind it")
	_check(
		sink.sink_name() == "hungry",
		"and it says so, because a sink that lies about what it is makes a log useless"
	)

	# Every id in the catalogue has to have a cue, or it is a sound dot-audio decided
	# should be heard and nothing can make.
	var missing := PackedStringArray()
	for id in p.audio.catalogue.ids():
		if not HungrySoundSink.CUES.has(String(id)):
			missing.append(String(id))
	_check(
		missing.is_empty(),
		"every catalogue id maps to a cue (%s)" % ", ".join(missing)
	)

	_check(
		p.sound.baked() > 0,
		"the bank is baked arithmetically, so this ships no audio files at all"
	)
	p.queue_free()
	_done()


# --- 3 ----------------------------------------------------------------------

func _test_limits_the_bank_never_had() -> void:
	_section("A monster in a dense field eats several times a second")

	var p := _make()
	var sink := p.audio.sink as HungrySoundSink
	p.audio.listener_position = Vector3.ZERO

	sink.forget()
	for _i in range(20):
		p.on_food_eaten(Vector2(5, 5), 2)
	_check(
		sink.count_of(&"eat") <= 4,
		"twenty bites in one tick make at most four sounds (%d), because nine blips in "
		% sink.count_of(&"eat")
		+ "one frame is a click rather than eating"
	)

	# The pitch is information -- bigger is lower -- and it has to survive the trip
	# through dot-audio rather than being played around it.
	# Past the cooldown the burst above just used. A check that measures a pitch while the
	# sound is being refused for a cooldown measures nothing, and reads as the pitch
	# mapping being broken.
	OS.delay_msec(60)
	sink.forget()
	p.on_food_eaten(Vector2(5, 5), 0)
	var small := sink.last_pitch(&"eat")
	OS.delay_msec(60)
	sink.forget()
	p.on_food_eaten(Vector2(5, 5), 5)
	var big := sink.last_pitch(&"eat")
	_check(small > 0.0 and big > 0.0, "both bites were heard")
	_check(
		big < small,
		"and a bigger mouthful is lower (%.2f against %.2f), which is the one mapping "
		% [big, small] + "nobody has to be taught"
	)

	sink.forget()
	p.on_food_eaten(Vector2(9000, 9000), 2)
	_check(
		sink.count_of(&"eat") == 0,
		"a bite on the far side of the arena costs nothing, because it is not information"
	)

	# The three that must never lose a voice to a crumb.
	var die := p.audio.catalogue.find(&"die")
	var eat := p.audio.catalogue.find(&"eat")
	_check(
		die.priority > eat.priority,
		"dying outranks eating, so a burst of crumbs cannot silence it"
	)

	p.queue_free()
	_done()


# --- 4 ----------------------------------------------------------------------

func _test_effects() -> void:
	_section("Only your own burst shakes your camera")

	var p := _make()
	p.fx.viewer_position = Vector3.ZERO

	p.fx.flash_colour.a = 0.0
	p.on_burst(Vector2(10, 10), false)
	p.present(0.016, Vector2.ZERO)
	_check(
		p.camera_shake() == Vector2.ZERO,
		"somebody else bursting across the arena is a picture and not a shake"
	)
	_check(
		is_equal_approx(p.fx.flash_colour.a, 0.0),
		"and does not tint the screen either"
	)

	p.on_burst(Vector2(10, 10), true)
	p.present(0.016, Vector2.ZERO)
	_check(p.camera_shake() != Vector2.ZERO, "while your own does both")
	_check(p.fx.flash_colour.a > 0.0, "including the tint")

	p.on_round_reset()
	_check(p.fx.live_count() == 0, "a round reset takes every effect with it")

	p.queue_free()
	_done()


# --- 5 ----------------------------------------------------------------------

func _test_console() -> void:
	_section("Every config key is a console variable")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")

	var missing := PackedStringArray()
	for key in p.settings.schema.keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(
		missing.is_empty(),
		"every setting is reachable from a keyboard (%s)" % ", ".join(missing)
	)

	p.console.submit("volume_db -30")
	_check(
		is_equal_approx(p.config.volume_db, -30.0),
		"a console line writes the config, not a second copy of the value"
	)
	_check(
		is_equal_approx(p.sound.volume_db, -30.0),
		"and the bank, because there is one path"
	)

	p.queue_free()
	_done()


# --- 6 ----------------------------------------------------------------------

func _test_party() -> void:
	_section("A private arena whose host may leave")

	DotP2PSignallerLoopback.reset_all()

	var party := HungryParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	# The axis where this game disagrees with game-arena, and it follows from what kind of
	# game it is: there is no round to be in the middle of.
	_check(
		party.session.config.migrate_host,
		"a continuous arena migrates its host, where a round-based deathmatch does not"
	)
	_check(
		party.session.config.trust == DotP2PConfig.Trust.SANDBOXED,
		"and files nothing anywhere, because this game unlocks achievements and a "
		+ "peer-to-peer host can lie about how much they ate"
	)

	_check(party.reporting_allowed(), "an ordinary session files what it likes")
	party.session._state = &"hosting"
	_check(not party.reporting_allowed(), "and a live private one files nothing")

	party.queue_free()
	_done()


# --- 6b ---------------------------------------------------------------------

## A stand-in rendezvous: the four routes `DotP2PSignallerHttp` speaks, on a real socket,
## answering each request [member delay] frames after it arrives.
##
## [b]The delay is the point.[/b] Every other party check here uses the loopback
## signaller, which answers inside the call — and a coroutine that never suspends is
## indistinguishable from a function, so a caller that forgot `await` passes against it.
## A rendezvous that answers frames later is the shape the real one has.
class RendezvousStub:
	extends Node

	var port := 0
	var delay := 4
	## An HTTP status to answer everything with instead of 200, to see a refusal arrive.
	var refuse := 0
	## What arrived, in order: `{route, body}`.
	var seen: Array[Dictionary] = []
	## Per route, the ids that announced themselves, so a join answers with who is here.
	var present: Array[String] = []

	var _server := TCPServer.new()
	var _open: Array[Dictionary] = []

	func start() -> bool:
		for candidate in range(38900, 38960):
			if _server.listen(candidate, "127.0.0.1") == OK:
				port = candidate
				return true
		return false

	func _exit_tree() -> void:
		_server.stop()

	func _process(_delta: float) -> void:
		while _server.is_connection_available():
			_open.append({"peer": _server.take_connection(), "bytes": PackedByteArray(), "wait": -1})

		for c in _open.duplicate():
			var peer: StreamPeerTCP = c["peer"]
			peer.poll()
			var available := peer.get_available_bytes()
			if available > 0:
				var got := peer.get_data(available)
				if int(got[0]) == OK:
					# Written back: a packed array is a value, so appending to the one read
					# out of the dictionary appends to a copy and the bytes are lost.
					var buffer: PackedByteArray = c["bytes"]
					buffer.append_array(got[1] as PackedByteArray)
					c["bytes"] = buffer

			if int(c["wait"]) < 0:
				var text := (c["bytes"] as PackedByteArray).get_string_from_utf8()
				var split := text.find("\r\n\r\n")
				if split < 0:
					continue
				var length := 0
				for line in text.substr(0, split).split("\r\n"):
					if line.to_lower().begins_with("content-length:"):
						length = line.get_slice(":", 1).strip_edges().to_int()
				if (c["bytes"] as PackedByteArray).size() < split + 4 + length:
					continue
				var first := text.get_slice("\r\n", 0)
				var target := first.get_slice(" ", 1)
				var route := target.get_slice("?", 0).get_file()
				var body: Variant = JSON.parse_string(text.substr(split + 4)) if length > 0 else {}
				c["route"] = route
				c["body"] = body if body is Dictionary else {}
				seen.append({"route": route, "body": c["body"]})
				c["wait"] = delay
				continue

			if int(c["wait"]) > 0:
				c["wait"] = int(c["wait"]) - 1
				continue

			var answer := _answer(str(c["route"]), c["body"] as Dictionary)
			var status := "200 OK" if refuse == 0 else "%d Refused" % refuse
			var payload := JSON.stringify(answer).to_utf8_buffer()
			var head := "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [status, payload.size()]
			peer.put_data(head.to_utf8_buffer())
			peer.put_data(payload)
			peer.disconnect_from_host()
			_open.erase(c)

	func _answer(route: String, body: Dictionary) -> Dictionary:
		match route:
			"host":
				present.append(str(body.get("id", "")))
				return {}
			"join":
				var here := present.duplicate()
				present.append(str(body.get("id", "")))
				return {"peers": here}
			"poll":
				return {"messages": [], "cursor": 0}
		return {}


## `[p2p-await-games]`: a party over the HTTP rendezvous, host and join, each awaited
## end to end — through `HungryParty`, `DotP2PSession` and `DotP2PSignallerHttp` to a
## socket and back.
##
## [b]What "awaited" is asserted as.[/b] The answer the caller gets back is the one the
## stub sent, and it arrives at least [member RendezvousStub.delay] frames after the call:
## a link in the chain that dropped its `await` hands its caller null (GDScript refuses a
## coroutine called as a function at runtime) or returns before the stub has answered,
## and either fails here. Ported from game-playground (d4ff040), where it was armed by
## taking the `await` off `DotP2PSession.join`'s call to its signaller. Here it was armed
## without touching dot-peer-to-peer, 2026-09-26, twice: a stub whose join answer lists
## nobody fired one check (Bob alone in his lobby, electing himself), and a stub that
## answers every request with a 500 fired six (no code, nothing open, and a join of the
## empty code refused on its shape).
func _test_party_over_http() -> void:
	_section("A party that meets over HTTP waits for the answer")

	var stub := RendezvousStub.new()
	stub.name = "Rendezvous"
	add_child(stub)
	var listening := stub.start()
	_check(listening, "a stand-in rendezvous listens on a local port", str(stub.port))

	if not listening:
		stub.queue_free()
		_done()
		return

	var url := "http://127.0.0.1:%d/p2p" % stub.port
	var ada := HungryParty.new()
	ada.name = "PartyAda"
	ada.signalling_url = url
	add_child(ada)
	var bob := HungryParty.new()
	bob.name = "PartyBob"
	bob.signalling_url = url
	add_child(bob)

	_check(
		ada.setup().ok and bob.setup().ok
			and ada.session.signaller is DotP2PSignallerHttp
			and bob.session.signaller is DotP2PSignallerHttp,
		"two parties set up with a URL, and both meet over HTTP rather than the loopback"
	)

	var opened: Array[String] = []
	ada.open.connect(func(code: String) -> void: opened.append(code))

	var before := Engine.get_process_frames()
	var hosted: DotResult = await ada.host("Ada")
	var took := Engine.get_process_frames() - before
	var code := str(hosted.value) if hosted != null and hosted.ok else ""

	_check(
		hosted != null and hosted.ok and DotP2PLobby.is_code_shaped(code, ada.session.config.code_length),
		"host() hands back a join code",
		str(hosted.error.message) if hosted != null and not hosted.ok else "null"
	)
	_check(took >= stub.delay,
		"only once the rendezvous has answered: %d frames, the stub waits %d" % [took, stub.delay])
	_check(
		stub.seen.size() >= 1 and stub.seen[0]["route"] == "host"
			and str((stub.seen[0]["body"] as Dictionary).get("code", "")) == code
			and str(((stub.seen[0]["body"] as Dictionary).get("info", {}) as Dictionary).get("name", "")) == "Ada",
		"and it is the code the rendezvous was told, under the host's name",
		str(stub.seen)
	)
	_check(ada.active() and ada.session.is_host() and opened == [code],
		"the party is open, hosted, and says so once",
		"state %s, opened %s" % [ada.session.state(), str(opened)])

	before = Engine.get_process_frames()
	var joined: DotResult = await bob.join(code.to_lower(), "Bob")
	took = Engine.get_process_frames() - before

	_check(joined != null and joined.ok and took >= stub.delay,
		"join() waits for the rendezvous too (%d frames) and succeeds" % took,
		str(joined.error.message) if joined != null and not joined.ok else "null")
	_check(
		stub.seen.size() >= 2 and stub.seen[1]["route"] == "join"
			and str((stub.seen[1]["body"] as Dictionary).get("code", "")) == code,
		"under the code as the host has it, not as it was typed",
		str(stub.seen)
	)
	# Asserted immediately after join(), and that matters here in a way it does not in the
	# playground: this party has `migrate_host` on, and the stub relays no heartbeats, so
	# after `host_timeout_sec` of silence Bob's session would decide Ada had gone and elect
	# itself. That is migration working, not a joiner electing itself on arrival -- which
	# is all this check is about, and the election on join runs the same with migration on
	# or off.
	_check(
		bob.session.lobby.has(ada.session.local_id) and not bob.session.is_host(),
		"and the joiner learns who is already there from the answer, and does not elect itself",
		str(bob.session.lobby.member_ids())
	)

	# A refusal arrives as a failure the caller can read, not as null and not as success.
	bob.leave()
	var carol := HungryParty.new()
	carol.name = "PartyCarol"
	carol.signalling_url = url
	add_child(carol)
	var _set := carol.setup()
	stub.refuse = 403
	var refused: DotResult = await carol.host("Carol")
	_check(refused != null and not refused.ok and not carol.active(),
		"and a rendezvous that refuses leaves the party closed with a reason",
		"null" if refused == null else ("ok" if refused.ok else refused.error.message))

	ada.leave()
	for node: Node in [ada, bob, carol, stub]:
		node.queue_free()
	_done()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
	return condition


func _test_chat_box() -> void:
	_section("A chat box that is not a screen, and the three answers to whether it is drawn")

	var p := _make()
	var window := p.chat_window

	_check(window != null, "the client builds a chat box at all")

	if window == null:
		_done()
		return

	_check(
		DotInputBinding.describe_action(window.open_action) == "Y",
		"opened by Y, which is where this genre has put it for twenty-five years"
	)

	# The channels are the server's own definitions rather than a second list.
	var ids := PackedStringArray()
	for entry in window.channels:
		ids.append(String(entry.get("id", "")))
	_check(
		Array(ids).has(String(HungryServices.CHANNEL_ALL))
			and Array(ids).has(String(HungryServices.CHANNEL_NEAR)),
		"offering the channels the server actually routes (%s)" % [ids]
	)

	_check(window.enabled, "drawn by default, on a server that said nothing")

	p.set_chat_relayed(true)
	_check(not window.enabled, "auto takes it away when a relay is carrying chat")

	window.add_said("someone", "but you can still hear this")
	_check(
		window.line_count() > 0,
		"and the log still draws what other people said",
		"off means you type somewhere else, never that you are out of the conversation"
	)

	p.settings.set_value(&"chat_window", &"on")
	_check(window.enabled, "on keeps the box even with a relay running: both, if you want")

	p.settings.set_value(&"chat_window", &"off")
	_check(not window.enabled, "off never draws it")

	p.settings.set_value(&"chat_window", &"auto")
	p.set_chat_relayed(false)
	_check(window.enabled, "and auto gives it back")

	# [b]The binding is stored beside the config, never in it.[/b] A `DotConfig` is layered
	# from a file, the environment and argv, and a chat key arriving from a server's
	# command line would rebind every player on it.
	_check(
		not p.config.has_key("chat_open_key"),
		"the chat key is NOT a config value a server could set"
	)

	p.settings.set_value(&"chat_open_key", "T")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"rebinding through the settings document moves the key"
	)
	_check(
		InputMap.action_get_events(window.open_action).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	# Split, throw, boost and eject are all keys here: "gg boost" splits you twice.
	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does, so a typed key is not a split")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	_done()


# --- The mode vote ----------------------------------------------------------

## The vote's cues, played through this game's own generated bank, and its countdown drawn.
##
## The server has named these ids in the vote's rules since the vote was wired, and no
## client had a noise for any of them: the ballot was something a player read about.
func _test_the_vote_is_heard() -> void:
	_section("The mode vote is heard, through the bank, and counted on the HUD")

	var p := _make()
	var sink := p.audio.sink as HungrySoundSink

	# The wire's constants are the one copy: the server's rules name them, this catalogue
	# defines them and the sink maps them, so a cue the server sends and the client lacks
	# cannot be a typo in one of three places.
	var missing := PackedStringArray()
	for id in HungryEvents.VOTE_CUES:
		var d := p.audio.catalogue.find(StringName(id))
		if d == null or d.priority >= 100 or d.kind != DotAudioDef.Kind.FLAT:
			missing.append(id)
	_check(
		missing.is_empty(),
		"every vote cue is in the catalogue, flat, and under the three that change everything (%s)"
			% ", ".join(missing)
	)
	_check(
		p.sound.baked() == HungrySound.Cue.size(),
		"and every cue the bank names is baked, the vote's four included (%d of %d)"
			% [p.sound.baked(), HungrySound.Cue.size()]
	)

	sink.forget()
	_check(
		p.on_vote_cue(StringName(HungryEvents.CUE_VOTE_START)) != 0,
		"a ballot opening plays"
	)
	p.on_vote_cue(&"")
	p.on_vote_cue(&"not_in_this_build")
	_check(
		sink.count_of(StringName(HungryEvents.CUE_VOTE_START)) == 1
			and sink.count_of(&"not_in_this_build") == 0,
		"once, through the sink, and an empty or unknown cue is silence"
	)
	_check(
		sink.played_ids().size() == 1,
		"and nothing else was played for them (%s)" % str(sink.played_ids())
	)
	p.queue_free()

	# The countdown, where a player is already looking: under the round clock.
	var hud := HungryHud.new()
	hud.name = "VoteHud"
	add_child(hud)
	hud.build(null, null, 0)
	hud.vote_countdown(4, false)
	_check(
		hud.vote_label != null and hud.vote_label.text == "Mode vote in 4…",
		"a countdown second is drawn under the clock (%s)"
			% (hud.vote_label.text if hud.vote_label != null else "no label")
	)
	hud.vote_countdown(2, true)
	_check(
		str(hud.describe()["vote"]) == "Runoff in 2…",
		"in place, and a runoff says so (%s)" % str(hud.describe()["vote"])
	)
	_check(
		hud.feed.line_count() == 0,
		"and not in the feed, whose five lines the count would push the ballot out of"
	)
	hud.queue_free()
	_done()


## An administrator's blind and beacon, on the client: what the HUD and the renderer do
## with the two flags a snapshot sets. Who receives which flag is `headless_net`'s; what it
## LOOKS like is `tools/screenshot_map.sh <mode> --admin`'s, because a headless viewport is
## 64 x 64 and nothing here can say anything about a picture.
func _test_blind_and_beacon() -> void:
	_section("An admin's blind covers the screen, and a beacon rings and pings once a second")

	var world := HungryWorld.new()
	world.name = "AdminWorld"
	world.preset = HungryPreset.classic()
	world.tick_rate = 60
	world.world_seed = 20260924
	world.register_service = false
	add_child(world)
	var _set := world.setup()
	world.start(0)
	var _me := world.add_player(1, "You")
	var _other := world.add_player(2, "Them")
	world.spawn(1)
	world.spawn(2)
	var me := world.monster_for(1)
	var them := world.monster_for(2)
	me.alive = true
	them.alive = true

	# --- The blind.
	var hud := HungryHud.new()
	hud.name = "AdminHud"
	add_child(hud)
	hud.build(world, null, 1)

	_check(
		hud.blind_overlay != null and hud.blind_overlay.get_index() == 1
			and hud.minimap.get_index() == 0,
		"the blind sits over the minimap and under every other widget",
		"blind %d, minimap %d" % [hud.blind_overlay.get_index(), hud.minimap.get_index()]
	)

	them.blinded = true
	hud.present_blind(1.0)
	_check(
		not hud.blind_overlay.visible,
		"somebody else's blind does not touch this screen"
	)

	me.blinded = true
	hud.present_blind(HungryHud.BLIND_FADE_SEC * 0.5)
	var halfway := hud.blind_overlay.modulate.a
	hud.present_blind(1.0)
	_check(
		halfway > 0.3 and halfway < 0.7 and is_equal_approx(hud.blind_overlay.modulate.a, 1.0),
		"this player's own comes down over a quarter of a second, not in a frame (%.2f, then %.2f)"
			% [halfway, hud.blind_overlay.modulate.a]
	)

	# The whole viewport, not the HUD's rect: `DotHud` insets itself by the safe area, and
	# game-arena's first rendered blind left a frame of the world showing round the edge.
	var covered := hud.blind_overlay.get_global_rect()
	var screen := get_viewport().get_visible_rect()
	_check(
		covered.encloses(screen),
		"and it covers the whole viewport (%s over %s)" % [covered, screen]
	)

	# Dead is still blind: otherwise feeding yourself to the nearest monster lifts it.
	me.alive = false
	hud.present_blind(1.0)
	_check(hud.blind_overlay.visible, "and being eaten does not lift it")
	me.alive = true

	me.blinded = false
	hud.present_blind(1.0)
	_check(not hud.blind_overlay.visible, "and it lifts when the flag does")
	hud.queue_free()

	# --- The beacon.
	var p := _make()
	var sink := p.audio.sink as HungrySoundSink
	var ping := p.audio.catalogue.find(HungryPresentation.BEACON_SOUND)
	_check(
		ping != null and ping.kind == DotAudioDef.Kind.POSITIONAL_2D and ping.priority < 100
			and HungrySoundSink.CUES.has(String(HungryPresentation.BEACON_SOUND)),
		"the ping is catalogued, positional, under the three that change everything, and mapped to a voice"
	)

	var renderer := HungryRenderer.new()
	renderer.name = "AdminRenderer"
	add_child(renderer)
	renderer.bind(world, null, 1)
	var pulses: Array[int] = []
	renderer.beacon_pulsed.connect(func(id: int, at: Vector2) -> void:
		pulses.append(id)
		var _handle := p.on_beacon(at)
	)

	_check(renderer.present_beacons(0.016) == 0 and renderer.beacon_count() == 0,
		"nothing is beaconed, nothing is drawn")

	them.beacon = true
	sink.forget()
	p.present(0.0, them.centre())
	var first := renderer.present_beacons(0.016)
	var rest := 0
	for _frame in range(58):
		rest += renderer.present_beacons(1.0 / 60.0)
	_check(
		first == 1 and rest == 0 and renderer.beacon_count() == 1,
		"a beacon pings the moment it comes on, then not again inside a second (%d, %d)" % [first, rest]
	)
	for _frame in range(4):
		rest += renderer.present_beacons(1.0 / 60.0)
	_check(rest == 1, "and once when the second is up: once a second, not once a frame (%d)" % rest)
	_check(
		pulses == [2, 2] and sink.count_of(HungryPresentation.BEACON_SOUND) == 2,
		"every ripple is heard through the bank, for the beaconed player (%s, %d)"
			% [str(pulses), sink.count_of(HungryPresentation.BEACON_SOUND)]
	)

	# Positional: dot-audio culls a ping past its distance, which is what makes the edge
	# pointer — not the sound — the way a beacon two screens away is found.
	p.present(0.0, them.centre() + Vector2(ping.max_distance * 2.0, 0.0) if ping != null else Vector2.ZERO)
	_check(
		p.on_beacon(them.centre()) == 0,
		"and a beacon far outside earshot is culled rather than heard across the arena"
	)

	them.alive = false
	var _gone := renderer.present_beacons(0.016)
	_check(renderer.beacon_count() == 0, "a beacon goes when its monster is eaten")
	them.alive = true
	var _back := renderer.present_beacons(0.016)
	them.beacon = false
	var _off := renderer.present_beacons(0.016)
	_check(renderer.beacon_count() == 0, "and when the flag does")

	renderer.queue_free()
	p.queue_free()
	world.queue_free()
	_done()


# --- Exiting clean ----------------------------------------------------------------
#
# Ported from `dedicated` ([hunter-nav-1], 2026-09-27). This suite is the one that plays
# sound, and the eight objects `[hungario-pres-leak]` chased were `HungrySound`'s voices,
# found by reading stderr by hand: a returning leak here printed a line after `quit()`
# that no assertion in this process can reach. Duplicated rather than shared, because a
# suite is a scene with nothing above it to share through.

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3

## How long the copy may run before it is killed and this probe fails. A scene whose script
## failed to parse never reaches `quit()` and prints nothing, so a hang is the likeliest
## way for the copy to fail. `-- --exit-probe-seconds N` lowers it.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it[/b], so the only process that can check a run's exit is another one.
## Everything below is `dedicated`'s reasoning, unchanged: started rather than
## `OS.execute`d so a hung copy cannot hold this run for ever, wrapped in coreutils
## `timeout` so a copy orphaned by an outer kill still dies on time, and drained on every
## pass because a full 64 KiB pipe blocks the copy's next print.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/headless_presentation.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	_section("Exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Both streams are searched, so "the engine writes leak lines to stderr" stays a fact
	# about the engine rather than an assumption here.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so passing the last two on an absence
	# of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	_done()


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))

extends Node

const HungryModule := preload("hungry_module.gd")
const HungryEvents := preload("net/hungry_events.gd")

## What plays next, and who decides.
##
## [b]The modes are the maps.[/b] `classic`, `frenzy`, `gauntlet` and `warrens` are already
## `DotGameDescriptor`s that dot-server switches between with `changegame`; dot-map's
## catalogue says what they *are* — a kind, a player range, a description a ballot can show
## — and its rotation says which one comes round next with a cooldown so the same one does
## not play twice in a row. dot-vote is what lets the players override it.
##
## [b]The swap itself stays dot-server's, and this file does not do it.[/b] That is the
## same refusal game-simple-lobby makes about chat and for exactly the same reason: dot-map
## ships `DotMapSyncHost`, which announces a change, waits for every peer to have the
## content and then swaps — and dot-server's `change_game` already announces, waits and
## swaps, with a content sync this family spent nine bugs getting right. Running both would
## be two protocols doing one job, and the one that was wrong would be the one nobody was
## watching. `DotVoteGameSource` applies through the game manager, which is the path that
## already works.
##
## [b]What is genuinely new here is the time limit and rock-the-vote.[/b] Neither existed
## in this game: a round ended on a mass target or a clock inside `DotMatch`, and there was
## no way at all for the players to say "we have had enough of this one".

const CHANNEL := "hungry.maps"

## Where a server owner configures this game's vote. Empty skips the file.
##
## [b][method vote_rules] is this game's DEFAULTS, not its configuration.[/b] They layer
## the way every [DotConfig] in the family does, so an owner changes a number without
## touching code:
##
## [codeblock]
## vote_rules()  <  game.yml metadata: map_vote:  <  this file  <  DOT_VOTE_*  <  --vote-*
## [/codeblock]
##
## The file is JSON, keyed exactly as [DotVoteRules] is, enums by name, and sits beside
## [code]user://cfg/hungry.json[/code]. The end-of-mode vote and its extend option,
## which is what an owner usually wants to change:
##
## [codeblock]
## {
##     "end_vote": true,          "vote_lead_sec": 90,
##     "include_extend": true,    "extend_seconds": 300,    "max_extends": 2
## }
## [/codeblock]
##
## [code]DOT_VOTE_EXTEND_SECONDS=300[/code] or [code]--vote-include-extend=false[/code]
## do the same for one run. [code]timeleft[/code] and [method describe_lines] both read
## the vote's own clock, so an owner's [code]duration_sec[/code] and every extend reach
## them as well as the ballot. A result that does not validate is refused whole and the
## defaults stand, with the reason in the log.
const CONFIG_PATH := "user://cfg/hungry_vote.json"

## The key in the running game's descriptor metadata an operator's overrides are read
## from — [code]metadata: map_vote:[/code] in a delivered game's [code]game.yml[/code].
const METADATA_KEY := "map_vote"


## The vote picked something and the server should change to it.
signal change_due(game_id: StringName)

## Something a player should be told: the ballot, the tally, a warning.
signal announced(line: String)

## Something for every client to hear or count: a [code]cue_*[/code] id, or a second of
## the countdown before a ballot. One of the two is empty or zero. The module puts it on
## the wire as [constant HungryEvents.Kind].VOTE.
signal cue_due(cue: StringName, seconds_left: int, runoff: bool)


var catalogue: DotMapCatalogue = null
var rotation: DotMapRotation = null
var director: DotVoteDirector = null

## dot-server's game manager, which is what a vote actually applies through.
var games: Object = null

## How many people are playing. Set by [HungryModule]; a vote's every threshold needs it.
var player_count_fn: Callable = Callable()

## Whether a voter is an admin.
var is_admin_fn: Callable = Callable()

## `func() -> DotMatch`. The match being played now, for its round ends. A callable because
## a mode change builds a new world, and a new world a new match.
var match_fn: Callable = Callable()

## `func() -> int`. The leading score: the biggest monster's mass, which is what a round
## here is won on. Reported to the director for `trigger: score_limit`.
var score_fn: Callable = Callable()

var commands: DotVoteCommands = null

## What dot-vote's commands are called here. `vote` rather than `votefor`, so the command
## is the token this game's own wire already sends.
const COMMAND_NAMES := {"vote": "vote"}

var _match: DotMatch = null

## The file [method setup] layers over the defaults. A test sets it empty.
var config_path: String = CONFIG_PATH


# --- The catalogue ---------------------------------------------------------

## The modes, as maps.
##
## [b]`min_players` is the field that matters and it is the one a ballot uses.[/b]
## `gauntlet` is a corridor: two people in it is a chase and eight is a scrum, so it is off
## the ballot below three — which is `available_for`, and is why a catalogue is worth
## having over a hard-coded list.
static func map_catalogue() -> DotMapCatalogue:
	var out := DotMapCatalogue.new()

	# [b]Built FROM the game descriptors rather than beside them.[/b] The scene path, the
	# display name and the id are already declared once, in
	# [method HungryModule.game_descriptors] — which is what dot-server instantiates. A map
	# catalogue that restated them would be a second copy, and the copy that goes stale is
	# always the one nothing reads: this tree's most repeated bug is two copies of one
	# list, and it has now happened to `setup.sh`, `tools/check.sh`,
	# `tools/package_check.sh` and `bootstrap`.
	#
	# What is genuinely new here is `min_players`, which nothing else records — a
	# `DotGameDescriptor` has a maximum and not a minimum, and "this mode needs three
	# people" is exactly what a ballot has to know.
	for descriptor in HungryModule.game_descriptors():
		var added := out.add(_map(descriptor, int(MINIMUMS.get(descriptor.game_id, 1))))

		if not added.ok:
			# [b]Loud, because a catalogue that silently holds nothing is the exact shape
			# this family keeps finding.[/b] `DotMapCatalogue.add` validates and refuses,
			# and the first version of this function produced an empty catalogue with no
			# error anywhere — every map refused for having no scene path, and a vote with
			# nothing on the ballot that looked like a vote nobody wanted to use.
			DotLog.error(CHANNEL, "a mode was refused by the map catalogue", {
				"game": descriptor.game_id, "why": added.error.message,
			})

	return out


## How many people a mode needs before it is worth offering.
##
## [b]`gauntlet` is a corridor and two people in it is a chase.[/b] It is off the ballot
## below three, which is `available_for`, and is the one thing this catalogue knows that
## dot-server's descriptors do not.
const MINIMUMS := {
	"hungry_gauntlet": 3,
}


static func _map(descriptor: DotGameDescriptor, min_players: int) -> DotMapDef:
	var out := DotMapDef.new()
	out.id = StringName(descriptor.game_id)
	out.display_name = descriptor.display_name
	# [b]A semantic version or a default, because `validate()` refuses anything else.[/b]
	# A `DotGameDescriptor`'s version is a free string — dot-server never parses it — and
	# handing an unparseable one straight through is a map refused for a field nobody
	# meant to fill in.
	out.version = descriptor.version if DotSemVer.parse(descriptor.version).valid \
		else "1.0.0"
	out.kind = DotMapDef.KIND_ARENA
	out.min_players = min_players
	out.max_players = descriptor.max_players
	# The same scene dot-server loads, read from the same declaration.
	#
	# [b]Nothing here ever loads it, and it is set anyway.[/b] `DotMapDef.validate()`
	# refuses a map with no scene — correctly, because a map nothing can load is not a map
	# — and a catalogue whose entries are all refused is a catalogue that silently holds
	# nothing. That is precisely the shape this family keeps finding: a list that is empty
	# for a good reason, and nothing saying so.
	out.scene_path = descriptor.scene
	out.meta = {"vote": {"display": descriptor.display_name}}
	return out


## The vote's policy. Fifty-five settings and these are the ones this game changes.
static func vote_rules() -> DotVoteRules:
	var rules := DotVoteRules.new()
	rules.enabled = true
	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	# A mode is fifteen minutes rather than half an hour. A round here is a few minutes;
	# a map limit that outlasted five of them would be a limit nobody ever saw fire.
	rules.duration_sec = 900.0
	rules.vote_lead_sec = 90.0
	rules.vote_cooldown_sec = 60.0
	rules.vote_duration_sec = 25.0
	# Four modes with `include_current` off, so three others and an extend is exactly a
	# full ballot. A ballot of six would be a ballot of four and two blanks.
	rules.max_options = 4
	rules.include_extend = true
	rules.include_current = false
	rules.method = DotVoteRules.Method.PLURALITY
	rules.tie_break = DotVoteRules.TieBreak.BALLOT_ORDER
	# [b]Off, and this is the setting dot-vote found a bug in.[/b] With it on, "extend" is
	# erased from a tie and the tie goes to the new thing; with it off the ordinary
	# tie-break runs — and every pseudo-option sorts last in ballot order, so
	# `BALLOT_ORDER` hands the tie to the new thing as well. Two documented policies, one
	# behaviour. It is set explicitly here so somebody changing it is changing something.
	rules.extend_needs_majority = false
	rules.rtv_enabled = true
	rules.rtv_fraction = 0.6
	rules.rtv_min_players = 2
	# [b]Measured against elapsed time, which is the other bug dot-vote found.[/b]
	# `DotVoteClock.running` used to mean "has a limit" rather than "has started", so a
	# server with no time limit never accumulated elapsed time and rocking the vote was
	# refused for ever — on exactly the deployment whose only way to change anything is
	# the vote. Two minutes here is short enough that a mode nobody likes can be left.
	rules.rtv_delay_sec = 120.0
	rules.nominations_enabled = true
	rules.nominations_per_player = 1
	# [b]On, and it is the setting that makes `MOST_NOMINATED` mean anything.[/b] dot-vote
	# refused a second player nominating what somebody had already nominated, so every
	# count was exactly 1 and there was nothing to sort by. It is allowed now and is
	# itself a setting; with four modes it is also the only way a ballot can show which
	# one people actually want.
	rules.nomination_seconding = true
	rules.cooldown = 1
	rules.cooldown_mode = DotVoteRules.Cooldown.PLAYS
	rules.apply = DotVoteRules.Apply.END_OF_ROUND
	rules.apply_delay_sec = 5.0

	# Five seconds' warning, counted down on every client, before a ballot opens over a
	# chase. Shorter than a shooter's ten: a round here is a few minutes and the ballot
	# changes nothing until it ends, so the warning is for finishing a bite, not a fight.
	rules.vote_warning_sec = 5.0
	rules.runoff_warning_sec = 3.0

	# The ids the client's catalogue plays, from the wire's one copy of them. dot-vote
	# ships every cue empty and names no audio class.
	rules.cue_vote_start = HungryEvents.CUE_VOTE_START
	rules.cue_vote_end = HungryEvents.CUE_VOTE_END
	rules.cue_warning = HungryEvents.CUE_VOTE_WARNING
	rules.cue_runoff_warning = HungryEvents.CUE_VOTE_WARNING
	rules.cue_countdown = HungryEvents.CUE_VOTE_COUNT
	return rules


# --- Lifecycle -------------------------------------------------------------

func setup(p_games: Object) -> DotResult:
	games = p_games

	catalogue = map_catalogue()
	rotation = DotMapRotation.of(catalogue)
	rotation.mode = DotMapRotation.Mode.SEQUENTIAL
	# One play of cooldown over four maps: enough that the same mode never plays twice in
	# a row, and not so much that a two-mode server runs out of things to pick.
	rotation.cooldown = 1

	var rules := vote_rules()
	var problem := rules.validate()

	if not problem.ok:
		return problem.wrap("The vote rules are not usable")

	# The owner's layers over the defaults that just validated, BEFORE the mode timer
	# below is built from them — so what an owner sets reaches `timeleft` too. Refused
	# whole, loudly and not fatally, when the result does not validate.
	var layered := rules.layer_over_defaults(
		config_path, DotVoteGameSource.running_game_metadata(METADATA_KEY)
	)

	if not layered.ok:
		DotLog.error(CHANNEL, "the vote configuration is not usable; using the defaults", {
			"path": config_path,
			"why": layered.error.message,
			"detail": layered.error.detail,
		})

	director = DotVoteDirector.new()
	director.name = "Vote"
	director.rules = rules
	# [b]The source is dot-server's games, not dot-map's catalogue.[/b] What a vote applies
	# has to be the thing that actually changes the game, and `DotVoteGameSource.apply`
	# calls `change_game`. The map catalogue is what says a mode needs three players; the
	# game source is what makes a decision happen.
	director.source = DotVoteGameSource.of(games)
	director.auto_apply = true
	# [b]Off, and this is dot-vote's fifth bug.[/b] With it on the director announces the
	# change it just made *and* the host announces the same change through its own
	# `game_loaded` — which fires for an operator typing `changegame` too, and is therefore
	# the signal that has to be connected. Both firing is two entries in the play history
	# for one play, and a "played in the last N" cooldown that is quietly half what it says.
	director.begin_on_apply = false
	# [b]Off: the module advances it, once per world tick.[/b] It was on, AND the module
	# called `advance` every tick, so every clock in the vote counted twice — a fifteen-
	# minute mode was over in seven and a half, and the descriptive map clock that stood
	# beside it, advanced once, said otherwise the whole time.
	director.self_advance = false
	director.register_service = false
	director.player_count_fn = _player_count
	director.is_admin_fn = _is_admin
	director.announce_fn = func(line: String) -> void: announced.emit(line)
	add_child(director)

	director.change_due.connect(func(id: StringName, _choice: DotVoteChoice) -> void:
		change_due.emit(id)
	)

	# Two signals, two messages: dot-vote emits a countdown second and that second's cue
	# separately, and merging them here would be this file deciding which is which.
	director.cue.connect(func(id: StringName) -> void: cue_due.emit(id, 0, false))
	director.countdown_tick.connect(func(seconds_left: int, runoff: bool) -> void:
		cue_due.emit(&"", seconds_left, runoff)
	)

	# [b]No second clock.[/b] A `DotMapTimeLimit` stood here, built from the same rules
	# and advanced beside the director, "for `timeleft`" — and nothing but `describe_lines`
	# ever read it. It never heard an extend, a ballot that kept the mode, or a clock the
	# vote stopped, so the one line an operator reads said fifteen minutes on a mode the
	# players had just voted to extend. The vote's own clock answers all of that, and
	# dot-vote's `timeleft` command already reads it.

	return DotResult.success(null)


## Somebody is playing something. Both the rotation and the vote are told.
##
## [b]One call, from the one signal that fires for every change however it happened.[/b]
## An operator typing `changegame`, a vote applying and a rotation advancing all end here,
## which is what stops the play history counting one play twice — dot-vote's own fifth bug.
func note_playing(game_id: StringName) -> void:
	if rotation != null:
		rotation.note_played(game_id)

	if director != null:
		director.begin(game_id)

	_bind_match()


func advance(delta: float) -> void:
	if director != null:
		director.advance(delta)
		_report_score()


## The leading score, once a tick and only when it moved.
##
## [b]Mass, not kills[/b], because mass is what a round here is won on — HungryRules
## replaces dot-match's kill limit with it — so a vote `score_limit` is a mass: the ballot
## opens when the biggest monster is `vote_lead_score` short of it. It was reported by
## nothing, so `trigger: score_limit` validated here and decided nothing.
func _report_score() -> void:
	if not score_fn.is_valid():
		return

	var top := int(score_fn.call())

	# Against the clock's own memory rather than a copy here: the clock zeroes it on every
	# restart — a new map, an extend, a ballot that kept the map — and a cached copy would
	# then hold back a score that had not moved but that the clock had forgotten.
	if top == director.clock.top_score:
		return

	director.note_score(top)


## Follows the match a round ends in. Rebound on every mode change, because a new mode is
## a new world with a new match, and a connection to the freed one would never fire.
func _bind_match() -> void:
	var node: DotMatch = match_fn.call() if match_fn.is_valid() else null

	if node == _match:
		return

	if (
		_match != null and is_instance_valid(_match)
		and _match.round_ended.is_connected(_on_round_ended)
	):
		_match.round_ended.disconnect(_on_round_ended)

	_match = node

	if _match != null:
		_match.round_ended.connect(_on_round_ended)


## A round ended. This game's rules apply a vote's winner at the end of a round, and until
## this was connected nothing told the director one had — so the winner waited for the
## clock, and a round-limit or round-end trigger could never fire at all.
func _on_round_ended(_round: int, _winner: int, _outcome: DotMatchRules.Outcome) -> void:
	if director != null:
		director.note_round_end()


## dot-vote's commands, on [param host] — the module, so they go when it does.
##
## [b]None existed here.[/b] A chat `!rtv` is routed to the console in this game, and the
## console had no `rtv`, so it was dropped as an unknown command; the only way to vote was
## the client's own wire. Voters are the bare player id — `str(userid)` — which is what the
## wire's votes use and what a disconnect forgets; dot-vote's default is `u<userid>`, and
## two spellings of one voter is a player who rocks the vote twice.
func install_commands(host: Object) -> DotResult:
	if director == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no vote to command.")

	commands = DotVoteCommands.new()
	commands.director = director
	commands.names = COMMAND_NAMES
	commands.voter_fn = func(ctx: Object) -> StringName:
		var session: Variant = ctx.get("session")

		if session is Object and (session as Object).get("userid") != null:
			return StringName(str((session as Object).get("userid")))

		return &"console"

	return commands.bind(host)


## What would play next with nobody voting.
func next_in_rotation() -> StringName:
	if director != null:
		var voted := director.next_in_rotation()

		if voted != &"":
			return voted

	var chosen := rotation.choose(_player_count()) if rotation != null else null
	return chosen.id if chosen != null else &""


## Whether a mode may be offered at the current head count.
func available(game_id: StringName) -> bool:
	var map := catalogue.get_map(game_id) if catalogue != null else null
	return map == null or map.available_for(_player_count())


func _player_count() -> int:
	return int(player_count_fn.call()) if player_count_fn.is_valid() else 0


func _is_admin(voter: StringName) -> bool:
	return bool(is_admin_fn.call(voter)) if is_admin_fn.is_valid() else false


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	# The vote's clock: the one that ends a mode, and the one an extend moves.
	if director != null:
		out.append("map time     %s" % director.clock.formatted_remaining())
		out.append_array(director.describe_lines())

	return out

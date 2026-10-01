# game-hungario

An agar.io-shaped 2D game where the thing you steer is a monster and the thing riding it
is your avatar. Read `../../CLAUDE.md` first for the family-wide rules; this file is what
is specific to this game.

*(The repository was `dot-2d-hungry` while the game had a working title. **The identifiers
inside it deliberately did not follow the rename**: the class prefix is still `Hungry`, the
module is `hungry`, the content id is `hungry` and the two game ids are `hungry_classic`
and `hungry_frenzy`. Those are not cosmetic — `content_id` is what a client keys its table
of built-in games on, `game_id` is what an operator types at the console, and the RPC node
is named `Hungry` because in Godot the name **is** the routing. Renaming any of them
breaks a wire contract to make a directory listing tidier, which is the trade this family
already documented when it explained why `content_id` exists separately from `game_id` at
all.)*


## The moderator's live tools: the honest subset

dot-moderation's live tools are here (`HungryModTools`, built in the module because a game change replaces the world under it), and **only what a server can do to a monster on its own is supported**: slay (every piece devoured — the world's own death), respawn (the queue cancelled first), give and strip an item, rename, and bring, goto, send and return, which move every piece by one offset so a split monster arrives in its own shape.

**Noclip, freeze and speed change how a monster moves, so they go through the state the client predicts**: dot-2d's `Dot2DAdminModifiers`, kept per monster in `HungryMonster.admin` (authority-only, like `effects`) and written into every piece's `Dot2DState.admin` each tick, which `HungryPieceNet` replicates as `net_admin`. A server that changed how a monster moves without the owning client knowing would have that client predict something else and be corrected on every snapshot — rubber-banding — and `headless_net` keeps that as a negative control: a forced noclip through a rock stays within 2 units of the server for 90 ticks, and the same move with the rock removed from the server's world only is 82 units out. Noclip is the rocks not being there (`block_piece` skips them, inside the function a client's replay runs) and not the arena's edge; a freeze also refuses a split, a throw and an eject, which are movement by another route. `sandbox` repeats both over a real socket.

**A spawn tells dot-moderation**, off `HungryWorld.player_spawned` (`_watch_spawns`, re-wired on a game change), so a respawn switches noclip and freeze off through the handlers. The bits live on the monster, which outlives its pieces; without the hook they would ride it into the next life. **A game change clears the return history, for everybody** (`_module_game_changed`, 2026-09-24, nightly): `respawned` keeps it on purpose, and after a change every position in it is a point in the arena that was freed, so `return <player>` put them where they had stood in the previous mode — the lobby's bug (cb822cd), in this game too. `sandbox`'s game change moves the player before changing to the reef and asserts `return` has nowhere to put them after; armed by removing the clear, it reported them returned to (-1846, -1928) in the previous mode.

**Found on the way, and fixed in dot-net since (f99fde3, 2026-09-24):** a predicted piece the server held still was never pulled back. The mechanism was not the one first written here — a snapshot did carry the entity, with an empty body, and the client filled the reconcile values from its own prediction, so "nothing new" was adopted as "you are right" and the lead replayed twice (113 units away in the naive freeze control, and climbing). dot-net rewinds to the server's whole state now, and the control (c968108) asserts the rubber band a server-only freeze should produce: a 1.9 to 9.4 unit sawtooth whose floor does not climb. The shipped freeze never met the bug, because the admin bit changing is what reaches the client.

**Blind and beacon were refused as "no client overlay" until 2026-09-24, and are two flags now**, following game-arena's (0e818b3). `HungryMonster.blinded` and `HungryMonster.beacon` are set by the handlers on the server and replicated on **every piece** by `HungryPieceNet` — on every piece rather than one because which of a monster's pieces a client is told about is interest management's decision — `net_blind` **owner-only**, because nobody else's screen changes and an opponent who could read it would know the moment somebody could not see them coming, and `net_beacon` to everybody. State rather than an event, so a joiner, a lost snapshot and a game change are a baseline the next snapshot corrects. A beaconed monster's pieces are `always_relevant`, so the beacon reaches a client whose view rectangle had cut them. The client draws both: `HungryHud.blind_overlay` fades a near-black rect in over a quarter of a second, sized to the whole viewport rather than the HUD's safe-area-inset rect, **under** the HUD's widgets so the clock, the feed and the mass still say the round is going on — except the **minimap, which goes under the blind**, because it is every monster's position on one square and a blind that left it showing could be played straight through. It is this player's blind, dead or alive: a blind that lifted while spectating would end the moment its owner fed themselves to somebody. `HungryBeacon` (drawn by `HungryRenderer`) is a ring round the whole monster — its spread, not one piece — with a ripple once a second, and **a pointer at the screen's edge when the monster is off screen**, which is this game's version of arena's column through walls: a top-down arena has no walls to see through, only a screen edge. The minimap rings it too. Each ripple is `HungryRenderer.beacon_pulsed`, played as `HungryPresentation.BEACON_SOUND`, a fifteenth voice in the bank (`HungrySound.Cue.BEACON`, appended last), positional so dot-audio culls it past 3200 units — the pointer, not the ping, is how a beacon two screens away is found. Both persist on a respawn (`HungryModTools.PERSIST_ON_RESPAWN`); `blind <player> <seconds>` is dot-moderation's `TIMED_TOGGLES`.

`headless_net` asserts the audience over the loopback — the client's own monster blinded, a bot's blind never sent, the bot's beacon arriving from across the arena where its state had not arrived before (armed twice: dropping `to_owner_only()` fired two checks, dropping the `always_relevant` line fired two); `sandbox` asserts it with two real clients, down to the blinded client's overlay and neither client's renderer (armed the same way: one fired); `dedicated` drives both through the console, the timed lift, the relevance and the respawn (armed by emptying `PERSIST_ON_RESPAWN`: one fired); `headless_presentation` asserts the overlay's order, fade and coverage, and a ping once a second rather than once a frame (armed both: one and three fired). `tools/screenshot_map.sh <mode> --admin` renders a beacon on screen with another's edge pointer, and a blind.

The rest is refused with a reason `modtools` prints. Gravity, because a top-down arena has none. God and buddha because being eaten is the game, and health and slap because a monster has mass, not health.

## Why this project exists

Three reasons, and the third is the one that shaped it.

**It is the first thing in the family that is actually played.** game-arena and game-blob
each run their addons together and prove the seams; neither has a client a person can sit
down at. This one has a launcher, a camera, a renderer, a HUD, chat, menus, sound and a
touch path, and the whole of it runs against a real `DotServer` over a real socket.

**It joins the two halves of the platform.** dot-player-controller, dot-combat, dot-loadout
and dot-match are the gameplay half; dot-auth, dot-user, dot-user-avatar and dot-platform
are the identity half. Before this they were exercised separately. Here a guest signs on
through dot-platform, gets a profile and an avatar, chooses a loadout the server validates
against an entitlement set, and that avatar is drawn on top of the monster they steer —
from a signed pack dot-cloud fetched, or from the build if there is no pack.

**It is where the netcode became a game rather than a demonstration.** game-arena's bridge
proved dot-net works; this one has to survive an entity count that changes every second —
a monster splits into sixteen and merges back — a field of eleven hundred things that is
never replicated, and a game change with players still connected. Four of the bugs below
are in other projects and none of them was reachable from that project's own suite.

## A player is a set, and the pointer is a point

`HungryMonster` owns an array of `HungryPiece`. Almost every question about a player is a
property of the set: mass is the sum, position is the **mass-weighted** centroid, the
camera frames the spread, the rider sits on the biggest piece, and you are dead when the
last one is eaten. That much is game-blob's design and it is right.

What game-blob did not have, and what a multi-piece game cannot work without:

> **Every piece steers toward the cursor's *point*, not along one shared direction.**

`Dot2DCommand` carries `aim` (a unit vector) and `reach` (a distance) because a *screen*
position is meaningless on a server. A *world* position is not, and it is recoverable: the
sampler measures the pointer from the monster's centroid, so the server adds the same
offset to the same centroid and gets it back — `HungryWorld.pointer_of`. Every piece then
computes its own direction to that point.

Steering every piece along one shared direction instead makes a split monster a rigid
formation. The pieces move in parallel, at the same speed, for ever; they never come back
within merging distance; splitting is permanent and merging is unreachable. **Nothing
errors** — each piece did exactly what it was told — and it is invisible until you try to
merge. It cost a failing check in `headless_round` to find, and the fix is four lines and
a method name. game-blob had it too and now has both the fix and the check.

The pleasant consequence: releasing the mouse puts the pointer at your own centroid, so
your pieces gather. That is not a special case, it is the same rule.

## Four fields, one id space, and only membership travels

`HungryField` owns four things in one object because a monster's eat check has to consider
all of them on the same tick against the same `Dot2DGrid`:

| | |
| --- | --- |
| **food** | Four sizes. Which size is a hash of the slot index, so it is never sent. |
| **fruit** | Rare, worth a lot, and each of the three does something for eight seconds. |
| **item drops** | A charge of a throwable. |
| **planted** | What a lure leaves behind, and what ejecting spits out. |

The ids are one space split by constants (`FOOD_ID_BASE`, `FRUIT_ID_BASE`, …) rather than
four grids, for game-blob's reason: two grids means two queries and a merge of the
results, per piece, per tick, and four means four.

**Three of the four are positionless on the wire.** `Dot2DScatter` places a slot from a
hash of (seed, index), so a client that knows the seed knows where every crumb is, how big
it is, and which fruit it is, from an integer. What actually travels is which slots
*exist*: a list of indices added and a list taken, which at a steady state is a few dozen
varints a snapshot and on a join is about 3 kB once.

**The fourth is the exception that shows why.** A lure drops food where a player chose, and
a chosen position cannot be derived from anything. Planted slots carry their position, and
they are a separate field precisely so that the cheap case stays cheap. Ejecting reuses it:
a spat-out blob is ordinary planted food, so it replicates, indexes and is eaten through
paths that already existed rather than being a fifth kind of thing.

Two things follow that are easy to get wrong:

- **The bounds are part of the position.** A slot is hashed *into the arena rectangle*, so
  a client holding a different rectangle derives every crumb somewhere else — from the
  right seed, which is what makes the failure confusing: the ids match, the counts match,
  and nothing is where anybody says it is. `adopt_world_size` runs before
  `adopt_field_seed` for that reason, and the hello carries the size.
- **A slot index is never reused**, which is `Dot2DScatter`'s rule and this class
  inherits it. A new round's ids therefore sit *beside* the old round's rather than
  overwriting them, and whatever indexed the old field into a grid must remove it first.
  game-blob found that the hard way; here it is three fields wide.

## Effects are replicated as flags, and that is what makes them predictable

A monster's effects (`rush`, `maw`, `rind`, `frosted`, spawn protection) live on the
authority as expiry ticks. Speed depends on two of them.

If the client had to know the expiry ticks to compute its own speed, every fruit would be
an eight-second mispredict. So the effects are written into the *replicated piece flags*
once a tick, and `HungryMonster.speed_multiplier` reads the flags rather than the effects
— both ends compute speed from the same number, one tick apart. `HungryMonster.flags` is
that number; `adopt_flags` is where a receiving peer takes it off any of a monster's
pieces.

The trait from a player's loadout does the same thing for the same reason, by a different
route: it changes speed too, so it travels in the join and both ends read it off
`HungryMonster.trait_id`.

## What a player brings in

Two slots, one decision each, and every option is a trade rather than an upgrade:

| | |
| --- | --- |
| **starter** | Which throwable you spawn holding. |
| **trait** | `nimble` (+8% speed, −10% mass), `sturdy` (−5% speed, +15% mass), `greedy` (+15% from food, −10% mass). |

**Everything about it is ids.** `HungryContent.loadout_schema()` is a `DotLoadoutSchema`
over a `DotItemCatalogue`, and a dedicated server decides whether a published loadout is
legal from the schema and an entitlement set without touching an asset. If a change here
ever needs a `load()`, that is the thing to push back on.

`greedy` is the one item that is not `free`, so that an unwired server has a working
example of something nobody may take. **Entitlements default to nothing**, and that
default is the important one: a server that granted everything would work perfectly in
every test, ship, and quietly be a game where every unlock is free — and nobody reports
that as a bug.

Three separations worth keeping:

- **Validate on the way in, conform on the way out.** `HungryNetBridge._apply_loadout`
  validates a published document and refuses it. A client that can make the server repair
  its way to a legal loadout can put anything in any slot and have the server pick the
  nearest legal thing. `DotLoadoutConfig.conform_on_load` is on for the other direction,
  where refusing means a player who has not played for a month cannot spawn.
- **The screen never decides what is legal.** It offers `choices_for(slot, entitlements)`
  and the server validates the result anyway. A screen that filtered on its own would
  drift the first time an unlock changed; one the server trusted would be a client
  choosing its own stats.
- **The store is a `Callable`, not a manager reference.** `HungryNetBridge.loadout_sink`
  takes a published loadout somewhere, and where is a deployment decision. `HungryModule`
  points it at a memory-backed `DotLoadoutManager`; a community server points it at its
  own service. The sink is awaited, because a store may be slow and the cache must not be
  updated before the write succeeds.

A loadout takes effect on the **next spawn**. A player who could change their trait
mid-fight would change it the moment they were losing.

## The rider comes from the cloud, and from the build when it does not

`DotAvatarBuilder.plan` works out which part goes in which slot, in what order, with which
colours, and which have fallen back — pure logic over ids, no scene touched, the same
answer on a headless server as in a browser. `DotAvatarBuilder.apply` builds a `Node3D`
rig, so a 2D game cannot use it: `HungryRider` uses the plan and does its own attaching.

`HungryContentSource` is `DotAvatarCatalogue.resolver`, and the order is the design:

```
1. a mounted dot-cloud pack   <- signed, hash-verified, version-namespaced
2. res://content/avatars/     <- what shipped in the build
3. ""                         <- drawn by HungryRider instead
```

That order is what makes downloadable cosmetics an **upgrade rather than a requirement**.
A player you cannot see is a competitive advantage, so step 3 is not optional.

**The pack is data. The code that draws it ships in the build.** A `.tscn` names its script
by an *absolute* `res://` path and a pack's own path carries its version
(`res://dot_cloud/hungry_avatars/1.0.0/`), so a scene inside a pack cannot reference a
script inside the same pack without being re-authored per version. So the parts are scenes
with exported properties and `part.gd` stays in the build — which also means a pack
published against a newer game degrades rather than breaks: an unknown `shape` falls
through to the default one. The whole contract is a `Node2D` that answers `hungry_dress`.

Signing is still not optional. Not because this pack contains code — it deliberately does
not — but because the manifest is the entire trust boundary: its hashes decide what counts
as a valid download and its paths decide what gets mounted, and a Godot pack *can* contain
scripts.

The server names the pack in the hello (`hungry_avatar_pack`), so one client build works
against a server that ships its own cosmetics and one that ships none. Nothing waits for
it: the rider is drawn until the parts land.

`examples/content.tscn` runs the whole path — publish, sign, fetch, verify, mount, dress —
and four refusals: a tampered manifest, a valid signature from the wrong key, an unsigned
pack, and a version that climbs out of the mount.

## Sound is arithmetic

`HungrySound` bakes fifteen voices at startup: a sine sweep with a hash-derived noise
component under an attack-decay envelope. It ships no audio files, the same way dot-ui
ships no art and dot-2d draws nothing.

Two consequences worth keeping:

- **Deterministic, so it is testable.** The noise comes from `Dot2DScatter._hash` rather
  than `randf()`, so the bank is byte-identical everywhere and `headless_round` can assert
  that a voice is the right length, is not silence, and ends at zero rather than clicking.
  A generator pushing buffers could only be judged by listening to it.
- **Eating is *watched*, not listened for.** `HungryWorld.food_eaten` fires on the
  authority, which on a netted client is somewhere else — a client that hooked it would be
  silent all game and perfectly noisy offline, which is the kind of difference nothing
  catches. What a player perceives is their own mass going up, and that arrives either
  way, so `HungryClient._watch_mass` turns the difference into a blip pitched by its size.

## Settings are a `DotConfig`, and that is why the screen has no layout code

`HungryConfig` is nine `@export`s. `DotSettingsPanel` reads the annotations — type, range,
group, hint — and builds the editors, so adding a setting adds a row and nothing else
changes, and the screen cannot drift from the settings it is meant to show because it
never restates one.

Two rules the wiring follows:

- **Applied, then announced.** The panel holds edits until Apply because a config is
  legitimately invalid on its way to being valid, and `validate()` runs on the whole
  thing. `SettingsScreen.applied` fires only after `apply()` succeeded, so nothing ever
  reads a config that failed.
- **Pushed, not polled.** The camera, the sound and the renderer hold the value they were
  given. Asking a config every frame would put a dictionary lookup in the draw path for
  something that changes when somebody opens a menu.

A missing settings file is a first run, which is not an error. A *malformed* one is, and
it falls back to the defaults with a warning rather than refusing to start — losing what
a player set is bad, and not starting is worse.

## Being eaten means having nothing at all

No pieces, no position, nowhere for a camera to be. So a dead player watches whoever ate
them, and if that player has since been eaten too, the leader — `HungryClient._watched`,
which is what both the camera and the *input* are measured from. The input matters: a dead
player's pointer measured from a monster that does not exist means the mouse is silently
pointing at nothing when they respawn.

The HUD says whose eyes they are behind, because a player staring at somebody else's
monster with no explanation reasonably concludes the game has broken.

## The rings are the rule, drawn

Eating needs a **ratio** — a quarter more mass — and a quarter more area is about twelve
percent more width. Nobody judges that by eye, and certainly not while being chased. So
every monster is ringed green if you could eat it and red if it could eat you, and
**neither when the two are inside the ratio of each other** — that gap is the interesting
case and the one a colour would lie about. A piece that is merely smaller is not food.

## Touch

`HungryTouch` is two buttons and nothing else, because this game is nearly playable on a
phone by accident: there is nothing to aim and nothing to select, a drag is the pointer,
and near is slow. What a touchscreen cannot express is the two edge-triggered actions.

They are `Control`s rather than `TouchScreenButton`s on purpose — a `Control` consumes the
touch before `_unhandled_input` sees it, so pressing one does not also drag the monster
across the screen, which is exactly what a `Node2D` button would let through.
`--touch` forces them on so the layout can be looked at on a desktop and so a headless run
can drive them.

## The netcode

### Ordering: the first behaviour through drives the world

dot-net simulates per entity. This game's tick order is a whole-world property: everybody
moves, then eating is resolved against the world as it is *afterwards*, then merges, then
projectiles, then the match. Those two facts meet in `HungryNetBridge.ensure_world_ticked`
— the first `_net_simulate` on a given tick runs the entire world and the rest find it
done. That is game-arena's pattern and it is the right one.

`HungryModule.server_tick` calls it again afterwards, which is not redundant: it covers the
tick before the match entity is registered, and it costs one integer comparison.

### One entity per piece, and one always-relevant entity for the match

A player is not one entity. After a burst their pieces can be a screen apart, and an
entity per *player* would have to be relevant everywhere any of its pieces was. So each
piece is a `DotNetIdentity` + `HungryPieceNet`, replicating exactly what `Dot2DNetSync`
describes.

The match clock is its own entity, `always_relevant`, because every client needs the round
state whether or not it can see anybody — a dead player has no pieces at all. It is also
what keeps an empty server ticking: with no players it is the only entity, so it is what
calls `ensure_world_ticked`, and without it a freshly booted server's warmup would never
end.

### Nothing is sent to a peer before it asks

dot-server's signon finishes and *then* the client builds its scene. Between those two
moments the client has no node for an RPC to land on: Godot answers each one with "Node
not found", once per call, and the events are simply lost. So `HungryEvents.Ask.READY` is
the client saying it has somewhere to put them, and `_admit` is where a peer joins the
manager, gets the hello, the roster and the field.

For the same reason `_broadcast` sends peer by peer rather than through dot-net's
broadcast: a broadcast reaches every connected peer, including the ones that cannot
receive yet.

### A bot has no peer, and peer 0 is not "everybody"

Bots are players with no connection, and this game gives them peer 0. Two things follow,
and both were found by a failing check rather than by reading:

- **`net.add_peer(0)` makes the server build a snapshot against the bot's interest
  rectangle and send it to the broadcast address**, so every real client receives a second
  snapshot computed for somebody else. The symptom is a monster that jumps between two
  positions.
- **`net.send(msg, 0)` is a broadcast**, so a `_tell` that fell through to it would send
  every bot's private carry list to every client.

Both are guarded on `peer_id > 0`, and `_tell` says so.

### Prediction is the motor, and deliberately not the set

`_net_simulate` on a predicted piece runs the motor for that piece and nothing else, so it
is a pure function of (state, command, delta) — the only shape a reconciliation replay
converges for. `DotNetPredictor` reconciles one entity at a time, so anything a replay does
that couples two entities is computed against whatever the other one happened to be
holding.

What that costs is `_separate`. It is applied live on both ends and not replayed, so for
the second or so after a split — while the pieces still overlap — the shown positions and
the replayed ones differ by a fraction of the overlap, and the correction is eased out.
Once the pieces are apart, separation does nothing at all and the two agree exactly, which
is every other moment of the game.

**And against a rock, measured over the wire (`[warren-net-1]`, 2026-09-24).** `headless_net`'s **a round of warrens** rebinds the server onto a real `warrens` world, has the client build it from the name in the hello, and presses the client's own monster dead against a ring rock for 150 ticks, comparing where the client predicted it with where the server had it at the same tick: on the 138 ticks in contact the mean gap is **0.20** units. With the rock taken out of the client's world only, the same window is **3.72** — corrected on every snapshot — which is the control that says the first number means something (over the whole window the two read 3.6 and 7.5, too close to call, which is why the check is on the ticks in contact). A monster that splits against the face is the `_separate` cost above, measured: up to **14.4** units for 5 ticks while the halves overlap, 0.5 once they are apart.

**`receive_snapshot` must not reconcile.** `DotNetManager.receive_snapshot` already routes
a predicted entity's state to the predictor and acknowledges the inputs it covers; a
second pass replays the same inputs against values that were already rewound.
`correction_rate()` read **0.500** with the extra pass and **0.032** without.

### Interest is measured from the centroid

`DotNetManager._observer_for` hands a strategy the first entity a peer owns, which after a
burst is an arbitrary fragment. `HungryInterest` measures from the monster's centroid
instead, grows the rectangle linearly in *radius* (a monster wide enough to fill the screen
cannot otherwise see anything it might eat), and scores big-and-near above small-and-far.

## Chat is dot-chat's, and there is still exactly one path

It used to be dot-server's, whole. **`DotChatRouter` has the rules now** — four channels,
one of them a **radius**, a backlog for whoever just joined, a `/me`, and a gag that
survives a reconnect — and `HungryModule` hooks `player_chat` with `hook_pre` and
**cancels** it, so dot-server's own broadcast never happens. dot-server's join and leave
announcements are turned off in the same place, because dot-chat makes them now.

There is still one path. Two would be two sets of rules to keep in step, and the one that
skipped the filter would be the one that leaked admin chat. `sandbox` asserts that
**nothing at all** arrives through dot-server's own signal, and that a line sent the legacy
way — the browser shell's chat box, which has no way to name a channel — is *forwarded*
onto this game's wire rather than dropped.

**The chat key is the player id, not the account uid.** dot-chat's `key_fn` and
dot-moderation's `key_for_peer` are separate seams because they answer different questions:
a punishment is against a person who will come back, so it is keyed by something that
survives a reconnect; a chat line is attributed to somebody in this arena right now. Two
guests behind one device id share a uid, so keying both by it puts the second person's
words under the first person's name — game-simple-lobby found that with two clients in one
process, and every count matched throughout.

## Voice is proximity here, and that is where this game and the lobby part company

An arena is bigger than a screen. Hearing somebody creeping up on you is information;
hearing the whole server is noise. So `DotVoiceRouter.default_channel` is `PROXIMITY` and
the range is the same number `HungryInterest` grows a view rectangle by — **being audible
from outside your own screen is the same bug as being visible without being audible**.
game-simple-lobby chose the opposite for a room you can see all of, and both are right for
what they are.

Everything else is the lobby's reasoning: one `unreliable` RPC on its own channel serves a
UDP desktop client and a TCP browser one, push-to-talk closes when a screen takes the
keyboard, and playback goes into a **buffer** when there is no audio device — which is what
makes the receiving half checkable at all, because a wire that decoded to nothing would
look exactly like one that worked.

**The position is the mass-weighted centroid**, the same point `HungryInterest` measures
from. A split player is several places at once and any single piece is an arbitrary
fragment; a dead player has no position at all and can hear the room channel and nothing
else, which is right.

## Hunters: dot-npc, dot-npc-ai and the director

NPC monsters that roam, eat what they can and run from what they cannot. Three addons, each
here for the half this game would otherwise get wrong.

- **dot-npc** is the catalogue, the budget, the per-kind cap and the **perception**. A
  hunter that called "who is nearest" every tick is the classic broken NPC and both of its
  failures are reachable in ten seconds. `DotNpcSenses` acquires at one threshold, drops at
  a weaker one, and keeps chasing for a grace measured from the *last sighting*.
- **dot-npc-ai** is the decision: a state machine (three states, so a tree would be three
  leaves under a selector pretending to be a hierarchy), a wander that wanders rather than
  re-rolling, separation so a pack at one player does not become a tower, and a **reaction
  time** so a hunter cannot commit on the tick it first sees you. There is no difficulty
  setting; the character is the difficulty, per hunter.
- **dot-npc-ai-director** decides *when*. Hunters do not arrive on a timer: it builds up,
  sustains, fades and relaxes against an estimate of what the players are experiencing —
  which in this game is **how close the nearest hunter that could actually eat them is**,
  reported as the "health" the director understands. A lurker a player is about to swallow
  is not pressure, and counting it would make the director back off when the player is
  winning.

**A 2D world is dot-npc's XZ plane.** `DotNpcSpawner.spawn_2d` and `two_dimensional` were
added for this deployment; the mapping is one line — `(x, y)` becomes `Vector3(x, 0, y)` —
and it is what lets the senses, the steering and the director run unchanged, because every
one of them measures a 3D distance and a 3D distance on a plane where one component never
moves *is* the 2D one.

**Hunters are not dot-net entities, deliberately.** A piece is: it is predicted, reconciled
and interest-managed, all of which a player's own input needs. A hunter is
server-authoritative and unpredicted — dot-props' argument about a rigid body, from the
other side — and there are a handful, so one reliable event a few times a second is cheaper
than an entity's declarations and adds no second id space beside the piece ids.

**Off by default, and that is an operator's decision.** A mode about eating food and a mode
about being hunted are different games; `hungry_hunters_on` is the cvar, because turning
one into the other silently because an addon was installed is exactly what a cvar prevents.

## Hazards: dot-props in an arena

Rocks, spikes and lures, through `DotPropSpawner.spawn_2d`. dot-props supplies the
catalogue, the budget, the world cap, the undo stack and the cleanup; **what a hazard does
is this game's** — `HungryHazards.resolve` runs inside the world's tick, after movement and
before eating, for the same ordering reason `HungryWorld.tick` already gives about merges
and projectiles.

Everything is **frozen the moment it lands**, because rigid-body simulation is not
reproducible across machines. A frozen body is a fixed obstacle and both ends derive it
from the same replicated position and the same catalogue radius.

**The spawn interval is zero here and is not in a sandbox.** dot-props' interval exists
because a *player* can hold a spawn key; nothing here is placed by a player. What still
matters is the budget and the world cap.

## dot-combat, for the half that is actually damage

**Eating is still not here, and that has not changed.** Being devoured is a mass ratio, not
a hit-point total, and forcing it through `DotDamageResolver` would be a worse version of
both. What *is* damage is a **throwable**: somebody aimed something at somebody else from a
distance, and every question that raises is one dot-combat already answers — self damage,
falloff, a floor, and a hook.

**The bridge is one function.** dot-combat's output is hit points and this game has none;
what it has is "how far this scatters you". `HungryCombat.pieces_for` maps the first onto
the second, so a pepper thrown across the arena scatters somebody less than one thrown at
point blank — which turns a throwable from a hitscan into something with a range worth
judging.

**`HungryWorld.damage_gate` is unset by default and that is the whole game.** A deployment
with no dot-combat gets the constants this file has always used; one with `HungryCombat`
gets the rules. A world that named the combat layer would be a world that could not run
without it, and this project's own suites run it both ways.

## Boards, achievements, and the numbers they are made of

**Neither addon is given a new source of truth.** `HungryModule` already declares a
`DotStatsSchema` and records against it; `DotAchievementStatsLink` is a signal connection
over that, and dot-leaderboard takes the readings worth ordering people by. A second count
of how much food somebody ate would be a second number that can disagree with the first,
and the one that is wrong is always the one nobody is looking at.

`dedicated` checks that **every stat an achievement watches is one the game declares** — an
achievement watching a stat nothing reports never unlocks, nothing errors, and the only
symptom is a player who did the thing and was not told.

Boards are **scoped by mode**: a top mass in Frenzy and a top mass in Classic are not the
same number, and one board over both would be a board of who played Frenzy. One of the
three is a `PENALTY` board so the "lower is better" half of `beats()` is exercised rather
than only described.

## The vote, and what dot-map is here for

**The three modes are the maps.** dot-map's catalogue says what they *are* — a kind, a
player range, a description a ballot can show — and it is built **from** the game
descriptors rather than beside them, because the scene path and the display name are
already declared once. What the catalogue knows that they do not is `min_players`:
`gauntlet` is a corridor and two people in it is a chase, so it is off the ballot below
three.

**The swap stays dot-server's.** `DotMapSyncHost` announces a change, waits for every peer
and swaps — and `change_game` already announces, waits and swaps, with a content sync this
family spent nine bugs getting right. Running both would be two protocols doing one job,
and the one that was wrong would be the one nobody was watching. `DotVoteGameSource` applies
through the game manager, which is the path that already works.

Three of dot-vote's own five bugs are settings this game sets **explicitly** rather than
leaving: `extend_needs_majority` (two documented policies, one behaviour),
`nomination_seconding` (without it every nomination count is exactly 1 and `MOST_NOMINATED`
can never do anything), and `begin_on_apply` (both the director and the host announcing one
play halves every cooldown).

**Four joins that were missing, found finishing the map-chooser work (2026-09-23).** The director self-advanced *and* the module advanced it every tick, so every vote clock ran at double speed — a fifteen-minute mode ended in seven and a half while the descriptive `DotMapTimeLimit` beside it, advanced once, said otherwise. No command existed: a chat `!rtv` goes to the console here and the console had no `rtv`, so the client's wire was the only way to vote; `HungryMaps.install_commands` puts `DotVoteCommands` on the module, voters keyed as the bare player id the wire already uses. Nothing called `note_score` or `note_round_end`: the leading score is now the biggest monster's mass (what a round here is won on, so a vote `score_limit` is a mass), polled once a tick against the clock's own memory, and dot-match's `round_ended` reaches the director — which is what makes `apply: end_of_round` mean the end of a round rather than the clock. And the wire's `extend` let any player extend the mode as often as the rules allowed; it is an admin's now, as in game-playground. `dedicated` arms the score half: without the poll, two checks fire.

**The vote is heard, and counted (2026-09-24).** The rules name four cue ids, `HungryEvents.CUE_VOTE_*` — on the wire file because it is the one both ends load, so the server's rules, the presentation's catalogue and `HungrySoundSink.CUES` read one copy — and `HungryMaps.cue_due` carries each cue and each countdown second to the module, which sends them as `HungryEvents.Kind.VOTE` (appended last, so every kind keeps its number). The client plays a cue through dot-audio into `HungrySound`, which bakes four new voices for them: pure tones with no grit, because everything else in the bank is about a monster and a ballot is about the server. A ballot is now counted down to for five seconds (three for a runoff), and the count is drawn in **one label under the round clock**, not in the feed where this game's notices go: the feed holds five lines, and a count of one line a second would push out the chat line that announced the vote. `headless_presentation` asserts every cue is catalogued, flat, below the three that must never be refused, and baked; `headless_net` sends a cue and a second across the link; `dedicated` asserts a ballot is counted down to and its warning and first second reach the module. `tools/screenshot_map.sh` renders a fifth frame, `<mode>_vote`.

**The descriptive clock is gone, because it never followed an extend.** `HungryMaps.limit` was a `DotMapTimeLimit` built from the same rules and advanced beside the director, and only `describe_lines` read it: after the players voted to extend, `hungry_vote status` still said the old limit. The `map time` line reads the vote's own clock now, and dot-vote's `timeleft` already did. `dedicated` extends the mode and asserts the line moves by the extension (armed by printing the rules' duration instead: it fired). `dedicated` also has a CHECKS total now; it had only the section counter.

## Six modes, and the last four are shapes rather than dials

`classic` and `frenzy` are the same square at two sizes: bigger and slower, smaller and
faster, with `merge_delay_sec` deciding whether splitting is a commitment or a move.

**`gauntlet` is a five-to-one corridor, and that is a different game rather than a third
set of dials.** A square is reachable in every direction, so being caught is a failure of
speed; a corridor removes the third and fourth directions — there is nowhere sideways to
run, being chased means being chased *along* something, and splitting to get past somebody
becomes the move rather than an alternative to it. It has the **same floor area and the
same food count as Frenzy**, deliberately: otherwise it would be a starvation mode as well
and there would be no telling which half was doing the work.

**It is also the first non-square world this game has ever run, and that is worth more
than the mode is.** A square hides every place that reads `world_size.x` where it meant
`.y`, or derives one bound from one component: the value is the same, so the bug is
invisible. `headless_round`'s **the gauntlet** section walks a monster into all four walls
— and the pair on the short axis is the pair a square can never test — then across the
length of the corridor, then measures the span of the food that actually exists rather
than its count.

Nothing was wrong. Twelve checks that would have passed on a square whether or not the code were right now pass on a shape where they mean something.

**And the corridor has things in it now, which is the half that had been missing since the day it was written.** A bare corridor removes two directions from being chased; it does not make getting away from somebody a decision, because along an empty lane the faster monster still arrives. `HungryLayout.SLALOM` puts five rocks down it, alternately near one wall and the other, and the level is the difference between the two lanes each one leaves: the near lane is about a third of the width of the far one, so a monster at a third of the winning mass takes the shortcut and one that has grown takes the long way round every rock. The shortcut changes sides at every rock, so taking it is paid for by the crossing that follows — five rocks with the same offset would be a wall with a corridor beside it.

**The far lane is deliberately open to a monster that has already won**, and the suite asserts it. That is where the corridor and the ring part company: a ring is escapable by construction — the middle is the part you are shut out of — and a corridor is not, so a rock whose wide lane is also too narrow is a cork and the mode ends with the leader parked against it. `widest_way_past` is the check that says the slalom is a level rather than a cage.

**The corridor's ends are harbours now (2026-09-25).** In a corridor the end is where a chase finishes: a square has no dead end, and the slalom made the middle a choice of lanes, but a small monster driven down the corridor was still eaten against an end wall. `HungryLayout._append_harbours` stands a fence of three posts (`HARBOUR_POSTS`) across each end, 386 from the end wall (`HARBOUR_AT`, 0.575 of the half-width), leaving four doors of 201 (`HARBOUR_DOOR`, 0.3) — two against the side walls and two between posts, the middle post on the centre line. A door admits a radius of 100, about 158 mass, a sixth of the winning mass and a tier below the slalom's near lane (268, about 280); the harbour behind is 296 deep, and the water in front of the fence is 402 from the end slalom rock to the middle post, wider than the near lane so it is not a hidden gate. **Four doors rather than one because one door is a cork**: a monster waiting outside a single central gap traps whoever is inside; with four across 1342 units the next door is 450 away. It is the den's rule at the corridor's ends — a room a monster can outgrow, open to the players furthest behind — and it cost the slalom nothing: the posts are appended after the five rocks (blocks 5-10, two `chains`), so every check about lanes asks `layout.part(0, SLALOM_COUNT)`. Food is 609 for Frenzy's density on the 7.83 million square units left (620 before). `headless_round`'s **the harbours** measures the doors off the discs, sweeps a monster 16 over the door limit (it reaches everything but the two harbours — `HungryLayout.harbour_of`), drives a starting monster from the middle of the corridor along `route_to` through a door to stand behind the west fence without overlapping a rock or post on any tick, and holds one at 1.6 times the door limit outside a door driven straight at it. Armed twice: doors at 0.1 fired 9 checks (including the reach sweep's starting monster, 732 points stranded), the fence at 1.2 — into the end slalom rock — fired 6. **A leader cannot stand in a harbour at all** (480 across, 296 deep), so the reach sweep's leader line is unchanged in kind; its floor is 2431 sample points where it was 3691, because the ends in front of the fences are mostly too tight for it too. `tools/screenshot_map.sh gauntlet --at=-3200,190 --name=harbour` is a player behind the west fence, with the wall to one side and a door between two posts to the other.

#### A gate is a gap between two things, and until the slalom both of them were rocks

`HungryLayout.narrowest_gap` measures rock against rock, and that is the whole question for the warrens because a ring's gates are between two ring rocks. A slalom rock stands off one *wall*: its narrow lane is against that wall and its wide one against the other, and neither is a gap between two rocks at all. **Asked the old question the slalom answers 646 units** — the distance between two rocks a thousand apart, which is not a gate, is not the level, and is not a number anybody would have noticed was wrong.

`narrowest_gate(bounds)` is the question every layout should be asked, and it reduces to the old one where the old one was right: the warrens' corner rocks stand further off the wall than its ring rocks stand from each other, so its answer is unchanged and its section now asks the new one. `HungryLayout.ids()` exists for the same reason — the gate section named `warrens` because `warrens` was the only layout there was, and a check named after one level proves nothing about the next.

**A level also changes the food, and that arrives as a side effect nobody attributes to the level.** The field scatters over the whole rectangle and `_cull_blocked` takes back what lands in a rock — and then **the scatter refills to its target on open floor**, so the target is the food standing on the floor and a level with the same count on less floor is *richer* per unit of it, not hungrier. The slalom was argued the other way round: the cull treated as a permanent loss, the target raised from 700 to 790 to cover it, and a check written with the same backwards arithmetic (multiplying by the walkable fraction rather than dividing by the walkable area) that agreed with the preset exactly. The corridor ran **27% richer than Frenzy** from 2026-09-17, and the reef, which copied the arithmetic, 4.5% richer than Classic. Warrens alone had it right from its first night. The targets are 620 (609 since the harbours) and 820 now, and `headless_round`'s **food on the floor that is left** counts the food actually alive in a settled world of every mode with a layout and divides by the floor — the only version of the number a player eats — and asserts every layout id is measured against the square it claims to match.

**`reef` is a wall across the world with four channels through it, and it asks a question the other two levels cannot.** Warrens' eight gates are eight copies of one gate, because a ring of identical rocks has to be, and every rock in the slalom leaves the same near lane and the same far one. So in both of those a monster learns its own answer once and then knows the whole map. The reef's channels are **248, 442, 635 and 828 units**, so size does not decide whether you can cross — it decides *how far along the barrier you have to travel first*, in the open, with everybody able to see which end you are heading for. The interesting property is a list rather than a number, which is what `HungryLayout.channel_widths` exists to be asked for.

**The ends close as you grow, and that is where it parts company with the warrens.** The chain stops 361 units short of each wall: wider than the tight channel and narrower than the two open ones, so a run-round is a small monster's route, a detour a middling one would rather not take, and shut to a leader. The warrens' perimeter lane is open to everybody its ring shuts out (up to 903 mass — past that its corner rocks quarter it, see the warrens below), which is why its ring is escapable; this one is not, and that is what makes the open end of the reef worth standing on. It is still not a cage, and the margin is in the numbers rather than in an intention: the widest channel admits a radius of 414, a mass of 2680 against a `win_mass` of 1500. *(It said 2140 until the lagoon was sized against the real curve: `base_radius` is 8, and the mass had been worked from a different one.)*

**Its section drives the crossing rather than comparing radii**, at both ends of the size range, because every arithmetic check over a barrier passes just as happily on one built with its rocks in the wrong order, overlapping, or laid out entirely outside the world. A starting monster is driven at the tight channel and has to come out the far side; one at the winning mass is driven at the same channel with the same commands and twice the ticks and has to still be on the near side. And the four gaps between the discs the world actually built are compared against the four `channel_widths` describes — one description, two representations, which is the rule the 3D maps in this family follow and the first time a 2D layout here has followed it.

**The reef has a second half now: a lagoon, and a door.** A second barrier stands 1265 units behind the first (`HungryLayout.LAGOON_AT`, 0.55 of the short half-extent) with one door the width of the fore reef's widest channel and three gates the width of its second — `HungryLayout.back_reef_widths`, which is the fore reef's list redistributed rather than a second set of constants: the gates are the mean of the fore reef's three narrower channels, so the chain is exactly as long, its ends leave the same 361-unit run-round, and the two barriers let the same total width through. The fore reef sorts monsters by size *along* its length; the back reef sorts them in one step. And **the door is behind the fore reef's TIGHT end**, while the two fore channels a grown monster fits are both at the other end. A starting monster crosses both barriers 290 units apart; one of 1000 mass comes through the fore reef's third channel and walks 1284 units up the lagoon to the door; a leader comes through the widest and walks 2360 — in a strip 920 across between two walls of rock, which is room for a 620-wide leader to travel and turn and not room for two of them to pass. The first half made crossing cost distance; the second makes it cost distance in the one place a leader cannot turn aside.

**It was sized by a measurement that threw out the first design.** The obvious second half is the fore reef mirrored — its open end behind the tight one — and on paper a leader walks the whole lagoon. On this curve it does not: a monster at `reef`'s winning mass is 620 across and fits the 635 third channel of *both* barriers, which a mirror leaves 207 units apart in the middle. The mirrored lagoon taxed only monsters over 1575 mass, past the mass that ends the round. The gates are sized so the band that pays is everybody over 763 — the leader and whoever is big enough to be chasing them.

**One description, three representations, and the third is a route.** `HungryLayout.chains` says which runs of `blocks` are one barrier, because the last rock of the fore reef and the first of the back are neighbours in the array and 1500 units apart on the map — the reef's section walked the array pairwise while there was one chain, and would have reported a fifth channel running along the lagoon. `channels(chain)` measures mouths and widths off the discs; `route_across(from, radius)` answers "where do I steer to get across" with three waypoints per barrier — in front of the nearest channel that admits the radius, its mouth, and behind it — each standing the rock's radius plus the monster's plus a margin off the line, so no waypoint is ever inside a rock. `headless_round`'s **the lagoon** drives a leader along that route: never overlapping a rock on any tick, out behind the back reef, having covered more than 2000 units of lagoon to get there. Then the same start and the same straight-line commands at two sizes: a starting monster goes through both barriers and a leader is held in the lagoon. `sandbox`'s game change goes to the reef now rather than to Frenzy, and asserts a connected client builds all ten rocks disc for disc from the name in the hello — the first live change that ever carried geometry to a client.

**The reef's open sea has an atoll now (2026-09-26).** The lagoon made crossing cost a grown monster distance; the 2128 units of water in front of the fore reef were still empty, a chase decided by speed. `HungryLayout._append_atoll` stands four rocks of 57.5 (`ATOLL_RADIUS`, 0.025) as an isosceles trapezoid centred 1368 in front of the fore reef (`ATOLL_AT`, 0.595), appended after both barriers (blocks 10-13, one `rings` entry) so nothing about the reef moved. Its gates are the fore reef's list again (`atoll_widths`): **248 facing the wall** (the tight channel, about 240 mass), **345 on each flank** (the mean, about 465) and **442 facing the reef** (the second channel, which is also every back reef gate, about 760), so the atoll shuts out exactly the band the back reef shuts out everywhere but its door, and sorts everybody under it by *side*: the reef's rule turned from "how far along me will you walk" into "which side of me will you walk round". Inside is 232 clear of every rock from the centre, room for a monster at the reef-side limit. **It was placed by two measurements.** With rocks of 115 standing 430 off the wall, the bulge behind the tight gate was a pocket for radii of about 215-250: a monster that grew there was corked. And in the middle of the sea it stood on the leg a leader walks from the tight end to the open end, which the lagoon section drives. So the rocks are small and both waters are wider than a leader (918 to the fore reef, 649 to the wall, a leader 620); the only pocket left is for radius 330, past the mass that ends the round. `headless_round`'s **the atoll** (16 checks) measures the gates off the discs, their order and sides, the band, the room, both waters and the leader's leg; sweeps a monster 16 over the reef-side limit (it reaches everything but the atoll's inside); drives one too wide for the flanks (fed to 476, it swallows its new disc's food and arrives at 574 mass, radius 192) from behind the atoll along `route_to` round to the reef-side gate and in, without overlapping a rock on any tick; and drives straight at the centre from the wall side at three sizes: a starting monster gets in, one of 344 mass is held at the tight gate, one of 1219 is held at the reef-side gate. `route_to` plans that drive on a 12-unit grid, because 24 steps over a 16-unit band either side of the throat. The reach sweep's reef line is 35 gates (29), narrowest still 248, a leader still reaching all of its floor (14575 points, 16758 before). Armed three ways: without the atoll the section's guard fired and the CHECKS total caught the 32 missing; turned round (wide gate to the wall), 4 fired; moved to mid-sea (0.45), 6 fired, including three of the lagoon's own leader-drive checks and the leader reach sweep (175 points stranded). Food stays at 820: the four rocks are 0.2% of the floor. `tools/screenshot_map.sh reef --at=-1368,0 --name=atoll` is a player inside it.

**The reef's open sea has spits now (2026-09-27).** The atoll made the middle of the sea a room; north and south of it the sea was still one water a leader crossed in any direction. `HungryLayout._append_spits` runs a spit of two rocks of 92 (`SPIT_RADIUS`, 0.04) from the sea wall toward the fore reef on each side of the atoll, 1150 off its line (`SPIT_AT`, 0.5), appended after the atoll (blocks 14-17) so nothing about the reef moved. Its gaps are the fore reef's list once more (`spit_widths`): **248 against the wall** (the tight channel, about 240 mass) and **442 between the rocks** (the second channel, every back reef gate and the atoll's reef-side gate, about 760), and it ends 1070 short of the fore reef. So the sea is one water for anybody under the back reef's band and **three for a leader**: the sea in front of the tight end, the atoll's water and the sea in front of the open end are joined for it only round the spits' reef ends, in the lane along the fore reef. A middling monster chased across the sea goes through a spit; the leader chasing it goes round, a thousand units further, where everybody can see it. The reef's rule again — size decides where you cross — turned onto the sea's axis. **Placed by the lagoon's leader leg**, as the atoll was: that leg passes 852 from the centre line at the northern spit, so the rock is sized to leave 74 clear of a leader on it (0.045 leaves 4; 0.05 stands on it). **They enclose nothing**: every gap has open water on both sides, so there is no refuge a hunter must be refused the way the harbours are; the section asserts a lurker's `main_region` and a monster's flood 16 under the rock gap are each the whole floor, which is what `HungryHunters.spawnable` relies on. **Spits are not `chains`**: `route_across` crosses every chain nearest first, and handed a spit it would plan the lagoon's leader through a gap it does not fit; they are their own `spits` list with `spit_gaps(spit, bounds)` measured off the discs. `headless_round`'s **the spits** (18 checks) measures both spits' gaps against the description, their order and placement, the water round the end and to the atoll (1070 and 743, a leader 620), the leader's leg, that nothing got tighter than 248, and that nothing is enclosed; plans a leader from the sea in front of the tight end to the atoll's water with `route_to` (2039 against 1100 straight, round the end); drives one fed just past the wall gap's limit (arriving at 329 mass, radius 145) through the rock gap (1061 of 1100, at 1.00 of its ground speed of 144) and a leader round the end (1987 of 2051, 105.6 against 105.7), neither overlapping a rock on any tick, and asserts both covered 90% of their route at 95% of ground speed; then straight at each gap: a starting monster through the wall gap, one of 465 mass held at it, one of 1219 held at the rock gap. The reef's own section measured its run-round over every block and read the spit's wall gap as the run-round; it asks the fore reef's rocks now. The reach sweep's reef line is 49 gates (35), narrowest still 248, a leader reaching all of its floor (12067 points, 14575 before). Armed four ways: turned round (442 at the wall), 3 fired; reaching the reef (`SPIT_RADIUS` 0.09, 610 of water left), 7 fired, including the lagoon's own leader drive and the reach sweep's leader line (558 of 9941 points); the rock gap as tight as the wall gap, 3 fired; the drives steered at 40 units of reach, the pace check alone fired (0.34 of ground speed, with 96% of both routes still covered — which is why the pace is asserted and not only the distance). Food is 817 for Classic's density on 20.08 million square units (820 before). `tools/screenshot_map.sh reef --at=-1647,-1150 --name=spit` is a player in the gap between a spit's rocks.

**The reef's open sea has a cove now (2026-09-29).** At the tight end a small monster has the tight channel; at the open end every crossing — the two wide channels, the run-round, the lane past the spits — admits whoever is chasing it, so a small monster caught there had nowhere to go its chaser could not follow. `HungryLayout._append_cove` stands two posts of 59.8 (`COVE_RADIUS`, 0.026) off the open-end wall, 1150 in front of the fore reef (`COVE_AT`, 0.5), appended after the spits (blocks 18-19, its own `coves` list, because it is neither a barrier nor a ring) so nothing about the reef moved. It has **three doors, each exactly the fore reef's tight channel** (`cove_door`, 248, about 240 mass): one between the posts and one between each post and the wall — the harbours' reason, one door is a cork, and the next door is 368 away. Behind the posts is a room that holds a radius of 154 (about 370 mass) and lets out 124, so a monster that eats past the limit inside has to split or eject, the den's price. **Placed by the leader who goes past it**: its sea-side post stands straight over the northern spit's reef-end rock, 690 from it, and its reef-side post is 760 from the fore reef's end rock, a leader 620 across (at 0.45 the reef-side water is 648). **It encloses floor, so hunters are refused it as they are the harbours** (`HungryLayout.in_cove`, asked by `HungryHunters.spawnable`) — a lurker, 135 across, fits its doors, which is the lurker paragraph below's open question once more. `headless_round`'s **the cove** (18 checks) measures the three doors off the discs against the tight channel, its placement on the open-end wall, both leader waters, that nothing on the map got tighter than 248, and that the room holds more than a door lets out and nothing a leader's size; sweeps a monster 16 over the door limit (it reaches everything but the cove) and has `route_to` refuse it and find a way in for one 16 under; asserts a lurker's `main_region` includes the cove and a hunter still may not appear in it; drives a starting monster from the open end's sea into the cove along `route_to` (1075 of 1116, at 1.00 of its ground speed of 124) and a leader of radius 313 from the bay behind the northern spit past it to the reef side (1430 of 1475, 131.8 against 132.1, planned 12 wide on a 12-unit grid because the spit-side water leaves a leader 70), neither overlapping a rock on any tick, both asserted at 90% of the route and 95% of ground speed; then straight at the door between the posts: a starting monster comes in, one of 386 mass is held, and the held one's front stops 187 short of a starting monster tucked against the wall at the back. The reach sweep's reef line is 53 gates (49), narrowest still 248, a leader reaching all of its floor (11460 points, 12067 before). Armed three ways: posts at 0.045, 5 fired (the leader water at 604, the leader's route gone, and the reach sweep's leader line, 10931 of 11185); doors at 0.8 of the tight channel, 5 fired, including three of the reef's and the atoll's "nothing tighter" checks; `spawnable` without the cove clause, the hunter check alone fired. Food is 816 for Classic's density on 20.06 million square units (817 before). `tools/screenshot_map.sh reef --at=-1150,2146 --name=cove` is a player inside it, the two posts between them and the sea. **Why the reef again, a fourth night running:** the gauntlet and the warrens were measured full. a brute-force search over centres every 20 by 10 units and radii of 40-150 found no disc in the corridor that makes one gate of 200-460 and leaves every other gap wider than a leader's 500, and the warrens' only open floor is behind its corner rocks, which `[warren-corners-1]` holds; the lane past them has 137 units of slack over a leader. Growing either needs a change to existing geometry, which is a design decision rather than a nightly one.

**`shallows` is a sixth mode (2026-09-30), because the other three levels were measured full.** Gauntlet and warrens have no room without moving existing geometry (the cove's paragraph above), and the reef has now had a lagoon, an atoll, spits and a cove; the one stretch of it left empty, the 862-deep strip behind the back reef, is only a corridor to anybody the back reef's gates shut out, so anything standing in it is a gate across a leader's floor. Every level so far asks a question with a place in it — whether you fit the middle, which lane past a rock, where along the barrier to cross — and a monster learns its answer once. `HungryLayout._shallows` asks **how far in**, and the answer moves as you eat: five lines of posts across a 4600 square (`SHALLOWS_LINES`, each a `chains` entry, 38 posts), every gap in a line the same width with the walls counting as gaps, **248 / 359 / 469 / 580 / 690** from the west wall out (`shallows_widths`, `SHALLOWS_TIGHT` 0.108 — the reef's tight channel — to `SHALLOWS_OPEN` 0.3), so the floor a monster reaches recedes from the shallow wall as it grows: the lines admit up to about 240, 503, 860, 1312 and 1860 mass, and at the winning mass (620 across) the open water and the band inside the last line, 2142 of 4600 units. A line is a fence you cross anywhere, so crossing costs no journey — the band behind is the prize, and the chase has a direction: prey runs for the shallows and the chaser stops at its own tree line. The water between two lines is `SHALLOWS_BAND` (1.2) times the outer line's gap, so no band is narrower than the gap into it, and the deepest (298) holds a radius of 149 behind a line that lets out 124 — the den's price. Posts are what the gaps leave (`shallows_post_radius`, about `SHALLOWS_POST` 0.03). Hunters may not appear behind the tightest line (`HungryLayout.shallows_band`, asked by `HungryHunters.spawnable`); a lurker fits every line. Reef's preset otherwise (1500 to win, 445 speed, 12 s merge); food 843, Classic's density on the 20.73 million square units the posts leave (2.0% under rock). `headless_round`'s **the shallows** (13 checks) measures every gap of every line, walls included, off the discs against the description; their order, and that a leader fits only the last; every band against the gap into it; sweeps the floor from the open wall at 16 over each line's limit (it reaches everything in front of that line and less at every line: 23875, 18061, 12387, 7673 and 3941 points) and 16 under the tightest (all 33384); refuses hunters the deepest band; drives a starting monster along `route_to` through all five lines to the shallow wall (4157 of 4208, 105.7 u/s against a ground speed of 105.7) and one of 537 mass from the leader's band through two more lines to the band its size allows (1736 of 1799 at 1.00), neither overlapping a post on any tick, both asserted at 90% of the route and 95% of ground speed; drives that one straight on and it is held at the second line; and a leader straight in from the open wall goes through the last line and is held at its tree line. The generic sections sweep it too (113 gates, narrowest 248, every one passing 16 under and refusing 16 over; a leader reaches everything in front of its tree line and nothing behind it, 7546 of 8951; 35 of 36 hunter ring points kept), and `dedicated` reaches it with `changelevel hungry_shallows` at the console and changes back. Armed twice: bands at 0.9 of their gaps, 4 fired (the band check, both drives, the pace); the lines reversed, open at the wall, 7 fired. `tools/screenshot_map.sh shallows` is the arena, five lines thinning toward the open water; `--at=-2150,0 --name=deep` is a player against the shallow wall. **A starting monster driven there ate its way from radius 38 to 131 when a route clipped a post and it stood against it for a minute** — the drives are planned wide (48 for the starting monster, 36 for the middling) because a waypoint counts as reached 40 short of it, and the middling starts in the leader's band because from the open wall it swept up 36 units of radius before it arrived.

**The shallows' open water has rock pools now (2026-10-01).** The lines make the west wall a refuge for everybody small enough to reach it, and a starting monster that spawns against the open wall had five lines and about 4000 units of leader's water between it and there — the one place on the map its size bought it nothing. `HungryLayout._append_pools` stands one post of 103.5 (`POOL_RADIUS`, 0.045) in each corner of the open wall, exactly the tightest line's gap (`pool_door`, 248, about 240 mass) off both walls, appended after the lines (blocks 38-39, their own `pools` list) so every line and chain index is unchanged. Each pool has two doors — the harbours' reason, one door is a cork — and a room in the corner behind the post holding a radius of 163 (about 415 mass) against the doors' 124, the den's price; 766 of water stands between a pool and the last line, a leader 620 across. Hunters are refused it (`HungryLayout.in_pool`, asked by `HungryHunters.spawnable`); a lurker fits its doors. `headless_round`'s **the rock pools** (14 checks) measures the four doors off the discs, the placement and the leader's water, that nothing got tighter than 248, and the room; sweeps a monster 16 over the door limit (it reaches everything but the pools and the deepest band) and has `route_to` refuse it and find a way in for one 16 under; refuses hunters; drives a starting monster from the open water into the south pool (2104 of 2144 at 1.00 of its ground speed) and a leader along the open water to the south wall beside it (1982 of 2020 at 1.00), neither overlapping a post on any tick; then straight along the south wall at the west door: a starting monster comes in, one of 386 mass is held with its front 287 short of a starting monster in the corner. The shallows section's tier sweep excuses the pools' points for the line it asks (they are the pools section's question). Armed four ways: without the pools, the guard fired and the CHECKS total caught the 13 missing; doors at 0.8, 7 fired (including the shallows section's own reach-everything check); `spawnable` without the pool clause, the hunter check alone fired; posts at 0.2, 5 fired (the leader's water at 53, the leader's route gone, the food density). Food is 840 for Classic's density on 20.66 million square units (843 before). `tools/screenshot_map.sh shallows --at=2137,2137 --name=pool` is a player in the south pool. **Its grown frame overlaps the post, and that is the game, not the tool:** a monster fed to 825 mass inside a room that holds 163 is pushed out of the post into the walls every tick, and the walls win. Seen here only; the den, the harbours, the cove and the deepest band have the same shape (a room bigger than its doors, walls or rocks on every side) and were not measured. Whether an outgrown monster should overlap its rock until it splits or ejects is in the queue (`[refuge-outgrown-1]`).

**Building it found that no level section had ever driven what it arranged.** `_settle` ticks until the round is live, and dot-match stays in warmup until somebody has joined — so every level section, which settled *before* adding its player, got a world still in warmup, arranged a monster in front of a rock or a gate, ticked twice, and the first of those ticks was the transition that resets the world and respawns everybody at a safe spawn. Every drive after that drove a monster the reset had put somewhere else. Three checks were passing only because of it: **the reef's** "a starting monster comes out the far side of the tight channel" was measuring a monster respawned past it; **the warrens'** "slides round the face of it and in through a gate" had been rewritten once to match the teleported result — driven for real and dead on a rock's centre a monster stays against the face for ever, which is what the first version of that check said, and four degrees off it slides in; and **the slalom's** "gets past the rock" drove with `command.move` alone, which this game's motor ignores — it steers by `aim` and `reach` — so the monster never moved at all. The gauntlet's "can cross the length of it" had twenty seconds for a 6708-unit corridor at 130 units a second. `_settle` now records a failure when it gives up (a client world is exempt: its round state is the authority's), every level section adds its player first, and each drive has an honest budget. The lagoon's own drive found it: the leader came out of a 2-tick settle standing 1700 units from where it had been put.

**`warrens` is the first world with anything standing in it, and the mechanic is that mass IS radius.** The other three are empty boxes: the only thing between two monsters is distance, so being caught is a failure of speed and the leader catches everybody eventually. Warrens puts a ring of eight rocks around the middle with 360-unit gates between them, and a gate is a *mass limit* — it admits a radius under 180, which on this curve is about 500 mass against a winning mass of 1600. The good middle of the map is open to the players who are behind and shut to the player who is ahead, which is a catch-up mechanic made out of geometry rather than out of a rule, and no dial in `HungryPreset` could have produced it.

The leader is not locked out, and that is the other half. Half the mass is `1/sqrt(2)` of the radius, so splitting fits — at the cost of `merge_delay_sec`, in the one part of the map where being in two halves is most dangerous. A pepper does the same thing to somebody else against their will, which makes a throwable a way through a wall as well as a way into a fight.

**The warrens' middle has a middle now: the den (2026-09-24).** Four rocks of 137 at 336 from the centre (`HungryLayout.DEN_*`, appended after the corners so blocks 0-11 did not move), with gates of 202 — a mass of about 160, a tenth of the winning mass. The ring made the middle a catch-up mechanic for whoever is behind, and a monster of 480 in the middle eats a monster of 30 there as readily as anywhere; the den is the one place nobody can follow a newly spawned or just-eaten player into, and getting there means crossing the middle first. Three tiers, one rule. The den's rocks sit on the diagonals, so its gates are on the axes — and so are four of the ring's (the ring's rocks sit half a step off the axes, which puts its gates ON them; the comment in `_warrens` said the opposite until now), so from each wall's midpoint there is one straight line through both to the centre, and a diagonal ring gate opens onto a den rock's face. The moat between the den and the ring is 418, wider than the ring's 361 gate, so it is not a hidden second gate. A monster that eats past the den limit inside it has to split or eject to leave, which is the warrens' own price one tier down. `HungryLayout.rings` names the two closed rings and `ring_gates(ring)` measures one, because the map's narrowest gate is the den's now and the warrens section asks the ring's. The food target is 609 (Classic's density on the 14.98 million square units left). `headless_round`'s **the den** drives a starting monster from off-axis at the west wall along `HungryLayout.route_to` through both rings to the centre, never overlapping a rock on any tick, and holds one at 1.6 times the den limit outside a den gate driven straight at it. `tools/screenshot_map.sh warrens --at=640,0 --name=den` is a player in the moat with the den's gate to one side and the ring's to the other.

**`headless_round`'s *the reach of every level* is `[reach-1]`: every mode, swept off its geometry.** `HungryLayout.gates(bounds)` lists every gap on the map — rock to rock and rock to wall, kept when nothing else touches the circle across it (no third rock, no other wall) — and `gate_passes` floods each one inside its own box, so the only way from before the throat to after it is through it: every gate must pass a monster 16 under its width and refuse one 16 over. `reach(bounds, from, radius)` floods the whole floor on a 24-unit grid, eight-connected (four-connected stranded one point in each of the warrens' diagonal gate funnels). The numbers on 2026-09-24: a starting monster reaches every sampled point of all five modes (classic 45369, frenzy 14641, gauntlet 12019, warrens 22997, reef 32940); gauntlet has 16 gates (narrowest 268 — since the harbours, 2026-09-25: 11494 points and 32 gates, narrowest 201, a door), warrens 46 (202, the den), reef 29 (248), all passing and refusing as they should; a leader reaches all of classic, frenzy, gauntlet and reef.

**The warrens' perimeter lane is NOT open to everybody for ever, and this file said it was.** The corner rocks stand 481 off each wall and 491 off the nearest ring rock, so past a radius of 240 — 903 mass, 56% of the winning mass — the lane is four lanes and a monster is held in one quarter of it unless it splits (at the winning radius 640 of 2580 sampled points). What the mode rests on still holds and is what is asserted: everybody the ring shuts out (over 506) has the whole lane up to 903. Whether the corners should quarter a leader is a design question, and it is in the Queue rather than decided by a nightly run.

**The geometry is derived on both ends and never replicated.** `HungryLayout.for_id(id, bounds)` is a pure function, the hello carries the *name*, and a client builds the same discs the server pushes it out of — the same trick `Dot2DScatter` plays with the food and for the same reason. `HungryHazards` is deliberately not this: a hazard is placed at runtime by an operator or the director, so it travels, it is owned and it can be cleared. A layout is the map.

Three things a layout makes true that an empty box never did, all of which are in `HungryWorld`:

- **The push-out is on the prediction path.** `block_piece` runs inside `simulate_piece`, immediately after the motor, because a reconciliation replays that call — a push the authority applied outside it would make every tick spent against a rock a misprediction, and the correction would ease the player back into the rock they are standing against. It reads as packet loss, which sends the next person to the netcode.
- **The field is culled against it.** A crumb inside a rock cannot be eaten and never expires, so it holds its slot against the field's budget for ever and the mode quietly runs at seven eighths of the food it claims. `_cull_blocked` takes them back on the tick they are placed, which costs nothing on the wire because the field's delta already cancels an id added and taken between two snapshots.
- **A spawn is moved rather than refused.** Every producer of a spawn point here knows about monsters and nothing about rocks, and a rock covers an eighth of a warren.

**The hunters get a path now, and they had not been chasing at all (`[warren-nav-1]`, 2026-09-25).** dot-npc steered straight at a target because every world here was an empty box, and `_keep_out_of_the_level` only pushed a hunter out of a rock. `HungryHunters.nav_for(layout, bounds)` builds dot-npc navigation from the layout — a 64-unit grid on the XZ plane, a point wherever 40 units of clearance fits (the smallest hunter's, one graph for all three kinds), an edge to each of eight neighbours whose line keeps it — and `_keep_nav_current` hands it to the spawner on the first tick of every layout, so a game change is noticed without a hook; an empty box gets null, which is dot-npc's straight line. The chase already called `steer_with_spacing`, which asks the spawner's `path_toward`, so nothing in the brain changed for that. The snap radius and the repath drift are set in world units (dot-npc's defaults are metres: a 4-unit snap never finds a point and a 2.5-unit drift repaths every tick). A search across a whole map costs 15-40 ms in GDScript; a chase inside sight is shorter, and a hunter repaths at most once a second or when its target has moved three grid steps. **Writing the check found the bigger bug: no hunter had ever chased anybody.** `HungryHunterBrain` read its link to `HungryHunters` from `npc.meta` in `_build`, and dot-npc builds the brain inside the spawn and emits `spawned` — where the link is put in `meta` — after it, so every hunter held a null, could not weigh anybody as prey or predator, and wandered for its whole life. `dedicated` counted hunters and never watched one hunt. The brain reads the link on first use now (`_link`). `headless_round`'s **a hunter goes round a rock** puts a stalker outside a warrens ring rock with a starting monster behind it, hunter, rock centre and prey on one line: along the path it eats it in 252 ticks; with the navigation taken away it still gets there — a disc is convex, and pressed dead-centre the push-out eventually slips — but in 624, six seconds against the rock's face, so the check's budget is six seconds. Armed both ways: no navigation fired 3 checks, the old `_build`-time link fired 1. The push-out stays, for the overshoot on a turn and for the bigger hunters a 40-clearance path leads along a face. *(This paragraph said a lurker is 480 across and is held at gates it cannot fit. It is not, and is not: see the next paragraph but one.)*

**`dedicated` watches a hunter hunt now (`[hunter-nav-1]`, 2026-09-26).** Its **hunters hunt** section places a stalker 600 from a starting monster on the running server — as far from every leftover bot as the arena allows, because a hunter targets the nearest thing it perceives and the exit probe's copy, with its bots elsewhere, had one chase a bot — with the director off and the world not ticked, runs 1.5 s of `HungryHunters.tick`, and asserts the gap shrinks (600 -> 245); then feeds the monster past the eat ratio, puts the stalker back, and asserts the gap grows (600 -> 996). Armed by setting the brain's `speed` to 0 before each measurement: both checks fired (600 -> 600). It also prints, as information, a whole-map `find_smooth_path` as a hunter repaths (snap 100, partial allowed) over 50 random pairs of nav points: warrens (3339 points) average 11 ms, worst 74; reef (4695 points) average 21 ms, worst 68 — the worst case is the dot-npc nearest-point scan plus a long A*, and is what a spatial index would be for.

**Where a hunter may appear, and what size a hunter is (`[hunter-nav-1]`, 2026-09-27).** The director's spawn points were three rings seeded ONCE, in `setup`, from the world the server booted in, and knew nothing about a level but its rocks. So after a game change the director placed hunters on the last map's rings — frenzy's rings handed to the gauntlet left 12 of 36 points outside the corridor, which the push-out then clamped onto the wall — and nothing refused a point behind a harbour's fence. `HungryHunters.spawn_points_for(layout, bounds)` is the rings walked out of the rocks at the *biggest* hunter's radius (`largest_radius`, the director's points serve every kind) and then two refusals, `spawnable`: not behind a harbour's fence (`harbour_of`), and on the biggest floor that radius can move about in (`HungryLayout.main_region` — a flood of every free cell, keeping the largest region; `in_region` asks it). `_keep_nav_current` re-seeds them with the navigation on the first tick of every layout, so they follow a game change. It costs 22 ms (gauntlet), 50 (warrens) and 69 (reef) once per layout. `headless_round`'s **where a hunter may appear** checks every mode's points against an independent `reach` flood, refuses a reachable point behind the west fence, refuses the den's middle to a radius 8 over its gate's half-width and allows it to a lurker, and hands a frenzy hunter layer a gauntlet world. Armed: without the harbour clause, without the region clause, and seeded once as before — each fired its own check (the last with 12 points off the corridor).

**A lurker is 135 across, not 480, and fits every gate on every map.** A hunter's radius is `HungryHunters.radius_of`, `4 √(mass / π)` — 15 for a swarmling, 34 for a stalker, 68 for a lurker — and is the radius it is drawn at, pushed out at and eats at. 480 is a MONSTER of 900 mass on the players' curve (`8 √mass`), which is how `[hunter-nav-1]` came to say the shared 40-clearance graph routes a lurker through gates it cannot fit. The narrowest gates are 201 (a harbour door) and 202 (the den). `headless_round`'s **a lurker on the shared graph** drives a stalker and a lurker at a starting monster through both: through the den from the moat behind a den rock, stalker 168-180 ticks and lurker 372-396; through the harbour from in front of the middle post, 192-204 and 396 — the lurker's half speed, and **0 ticks held against a rock** in either. Per-kind graphs would buy nothing on these maps, so there are none. Armed with the lurker at 12000 mass (494 across): both drives fail, 809 and 823 of 900 ticks held. **Which means every hunter fits through every refuge's door.** The den promises a starting player that nobody can follow them in, and the harbours promise the same at the corridor's ends; both are true of monsters and false of hunters, because a lurker of 900 mass eats anything under 720 and is 135 across. Whether hunters should be on the players' curve, or refuges should be refused to them some other way, is a design decision and is not taken here.

**The hunt check had a race in it, and it failed on an unchanged tree.** `dedicated`'s *hunters hunt* timed 1.5 s from the spawn, but how long a stalker wanders before its senses settle on the monster depends on the instance id, which seeds the wander heading and differs between processes: one run closed 600 to 245 and the exit probe's copy closed only to 445, under the 200 the check asks for (2026-09-27, before any change). The chase is now timed from the tick the brain enters `chase`, with the stalker put back where it started, and the label prints how long that took (7-31 ticks seen). Re-armed with the brain's speed at 0: both checks fail at 600 -> 600.

**What a bot actually travels at (`[bot-drive-1]`, 2026-09-27): its ground speed, near enough.** In the 3D games every bot held forward and jump and crawled at the air cap. This game has no jump; the motor is agar.io's. The speed a monster is *given* is `max_speed × speed_scale(mass) × trait and effects` (its ground speed, worked per piece per tick); what it *gets* is that times the pointer's push, which ramps from nothing at `dead_reach` (7) to full at `full_speed_reach` (105). `HungryBot` points at what it wants, so it slows as it arrives at every crumb — as a person with a mouse does — and most of its travel is toward things further away than 105. `headless_round`'s **what a bot actually travels at** prints both numbers beside its assertions: a monster held at full reach, 149.9 u/s against 149.9 (1.000); eight bots over 28 s of classic, 102.5 u/s against 109.4 (**0.937**), 65% of piece-ticks at 95% or more of ground speed and 3% under half. The floor is 0.85 and half the ticks at full. Armed: the bot's reach capped at 40 gave 0.42 and 1%; the control driven at 60 units of reach gave 0.541. Every level section that drives a route steers with `_full_reach` (full wish whatever the distance), and each now prints what it covered against the route it was given: lagoon 6876 of 7085 (97%), atoll 1803 of 1876, den 2217 of 2263, harbours 1868 of 1917, every one at exactly its ground speed. The 2-4% short is the arrival radius (40-60 units per waypoint), not a crawl.

## Game switching: the world is the scene, the manager is not

`changegame frenzy` — or `gauntlet` — frees the running mode scene and instantiates the next one, with the
players still connected. So the world lives *inside* the scene (`HungryMode`), and the
`DotNetManager`, the bridge and the loadout manager do not — rebuilding a manager resets
the message ids, the peer records and the clock, which is a disconnect for everybody and
precisely what changing the map is supposed to avoid. `HungryNetBridge.rebind` moves the
bridge onto the new world, keeping every connection, and the match entity survives because
its net id is already known to every client.

dot-server's own `votemap`, `vote` and `vote_status` work against both descriptors with no
code here: registering them is all a game has to do.

A game shipped inside its build cannot be handed a client scene by the server — see the
dot-server note below — so `HungryClient` is loaded by the application (`examples/play.gd`)
and the signon takes the no-scene path.

## A check count is not coverage

Every suite here counts **sections entered against sections that ran to their last line**,
and fails when they differ.

That is not defensive programming. A runtime error inside a section — asking a dead
monster where it is — aborts that function and nothing says so: the checks that already
ran still print ok, the ones after it never happen, and the total at the bottom cannot
reveal a check that never ran. It happened here: `_test_devouring` lost eight checks and
the reported total went *up*, because other sections had been added in the same change.
dot-net's demo carries the same pair, reached from the other direction — there it was a
suspending section called without `await`.

Anything that returns early has to call `_done()` before returning.

**The leak report at exit was not a leak in this code** *(and neither `dedicated` nor `sandbox` prints one any more as of 2026-09-24 — see "No message preloads itself")*. `dedicated` and `sandbox` printed
"ObjectDB instances leaked" with a list of `GDScriptNativeClass` and `GDScript` entries.
Those are the engine's script cache with several hundred scripts loaded, and dot-platform's
sandbox prints the same. A real cycle would name a node or a `RefCounted` of this project's
own; one was chased in dot-net once and turned out to be a suspended coroutine's locals.

## Bugs this project found

Every one of these parsed cleanly and none produced an error.

**In this project:**

- **Split pieces could never rejoin.** One shared aim direction moves every piece in
  parallel. Described above; it is the biggest one, and it is a design bug rather than a
  coding one.
- **`reset_world` cleared the piece dictionary instead of destroying the pieces**, so
  `piece_destroyed` never fired, the netcode's entities stayed registered, and every
  client kept the previous round's pieces on screen for ever.
- **The round announced itself before it reset.** Every client was sent the field that was
  about to be thrown away and then the new one as a delta on top of it, ending a round
  holding exactly twice as much food as existed, half of it phantoms.
- **A part that was its own fallback** made the whole rider schema invalid, which
  `headless_round` never noticed because it never validated a schema.
- **A bot registered as peer 0.** Two separate failure modes from one line.
- **A section that aborted took eight checks with it.** See above.
- **A disconnect never left the netcode.** `_on_client_disconnected` takes the peer off the ready set first, so nothing is announced to a socket that has gone — and `HungryNetBridge.remove_peer` then gated `net.remove_peer` on that same ready set, so it never ran. The manager kept the peer and sent it a snapshot every interval for the life of the server, each one an "Attempt to call RPC with unknown peer ID". `remove_peer` asks the manager now, and `sandbox` asserts the peer is gone from it.
- **Nobody was ever welcomed.** `HungryModule._welcome` — the chat backlog, dot-chat's join notice, and the hunters and hazards already in the arena — was called from `client_spawn` and returned on its first line unless the peer was ready, which at `client_spawn` it never is. With dot-server's own join line switched off in favour of dot-chat's, nobody's arrival was announced at all. It runs from `HungryNetBridge.peer_admitted` now, and `sandbox` asserts both the notice and the backlog.
- **Every rider built from content was drawn under its own monster.** `HungryRider` set a part's `z_index` to `layer - 50`, relative to a renderer that draws the discs on its own canvas, so the body sat at -20 beneath the disc it rides. The drawn fallback was unaffected, which made real content the one version nobody could see. Found by a rendered frame; `content` asserts the order now.
- **No level section had ever driven what it arranged.** `_settle` returned with the round still in warmup whenever nobody had joined, and the first tick after a player did was the reset that respawned them. Three level checks passed only because of it — one had been rewritten to match the teleport, and one drove with a field the motor ignores. Found by the lagoon; described above.
- **The food arithmetic for every level was backwards, and the check agreed with it.** The field refills what the cull takes, so a target is what stands on the floor; the slalom and the reef raised theirs as though the cull were a loss, and ran 27% and 4.5% richer than the squares they were built to match. Found by the lagoon, whose extra barrier doubled the reef's rock and made the number worth recomputing; described above.
- **Split and eject were silent.** Both voices were baked and catalogued from the first commit and nothing played either; a netted split also played an eating blip, because the new piece's mass arrived before its parent's halving did. `HungryClient._watch_mass` hears both now, only after the player pressed the key, and `sandbox` drives them over the socket. A netted client also heard every throw on the map as its own, which offline never did.

**In other projects, none of them reachable from that project's own suite:**

- **`ArenaNetBridge` reconciled twice** — correction rate 0.500 against 0.032. Fixed in
  game-arena.
- **`client_spawn` carries `userid`, not `peer_id`.** A module looking a session up by
  `peer_id` gets null every time and adds nobody, silently. game-blob's module had the
  same line and had never connected a client. Fixed in game-blob.
- **`Dot2DScatter` could not be mirrored.** A receiving peer has to adopt the index it was
  given; allocating its own gives the same crumb two names on two machines. Added as
  `adopt`, in dot-2d.
- **dot-server could not serve a game that ships inside its own build.**
  `client_scene_or_scene()` fell back to the server's absolute path, which `DotClientLink`
  refuses — correctly — so the client failed signon and timed out. Fixed in dot-server.
- **`DotCloudClient` never registered itself.** Four call sites across dot-server and
  dot-user-avatar look for it in `DotRegistry` and all four found null, so content
  delivery could not work end to end and a cloud-delivered cosmetic was unreachable — and
  none of them errored, because every one treats an absent cloud as a legitimate
  configuration. Fixed in dot-cloud.
- **A cached interest answer dropped what the observer owned.** `relevant_for` caches per
  peer, and an entity spawned since is in nobody's cached set — so a client did not receive
  its own newly spawned entity until the cache expired, and on a host ticking faster than
  the wall clock it never received it at all. The position looked right the whole time,
  because the owner was predicting it; the mass was frozen at the value the spawn message
  carried. Fixed in dot-net.

## Validating changes

```bash
cd godot/game-hungario
for pair in dot_core:dot-core dot_2d:dot-2d dot_net:dot-net dot_server:dot-server \
            dot_match:dot-match dot_ui:dot-ui dot_user:dot-user \
            dot_user_avatar:dot-user-avatar dot_auth:dot-auth \
            dot_platform:dot-platform dot_cloud:dot-cloud dot_loadout:dot-loadout \
            dot_stats:dot-stats; do
  ln -s "../../${pair##*:}/addons/${pair%%:*}" "addons/${pair%%:*}"
done

godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

godot --headless --path . res://examples/headless_round.tscn   # 436 — the game
godot --headless --path . res://examples/headless_stack.tscn   #  24 checks
godot --headless --path . res://examples/headless_net.tscn     # 158 — the netcode
godot --headless --path . res://examples/dedicated.tscn        # 208 — a real DotServer
godot --headless --path . res://examples/sandbox.tscn          #  99 — two real clients
godot --headless --path . res://examples/content.tscn          #  46 — the cloud path
godot --headless --path . res://examples/headless_presentation.tscn  # 90 — the client half
```

1061 checks across seven suites. Every one of them has a section counter and a CHECKS total; `sandbox` and `content` were the last two with only the counter, and got theirs on 2026-09-24 (each armed: CHECKS raised by one, exit 1). Add `-- --verbose` to `dedicated`, `sandbox` or `content` when one fails and
the reason is in a log line rather than in the assertion.

**Run `headless_round` after any change to dot-2d** and **`headless_net` after any change
to dot-net.** Between them they cover the two properties nothing else can see: that two
worlds replaying the same commands are bit-identical, and that a client and a server
running the same motor stay within a few units of each other under 25% packet loss.

**Re-run `--import` after adding any script with a new `class_name`.** Without it the
identifier does not resolve, the scene fails to load, and the process *hangs* rather than
exiting.

**`sandbox` is the one that matters most and the slowest to write.** It is the only place
the RPC node paths, dot-platform's admission, dot-server's chat and a game change with a
player attached all run at once, and three of the bugs above were found by it alone.

It runs **two** clients, each in its own subtree with its own `MultiplayerAPI`, because
everything that decides what one player is told about another — interest, the roster, the
join broadcast, the spawn events — is per-observer, and every one of them is trivially
correct with one observer. Two people seeing each other is the thing a multiplayer game
must do and the thing nothing in this family had ever checked.

## Looking at a level

```bash
tools/screenshot_map.sh warrens        # the whole arena, a player's view, and a grown one
tools/screenshot_map.sh warrens --at=640,0 --name=den   # in the moat, the den's gate and the ring's
tools/screenshot_map.sh gauntlet       # the corridor, its slalom and a harbour at each end
tools/screenshot_map.sh gauntlet --at=-3200,190 --name=harbour   # behind the west fence
tools/screenshot_map.sh reef           # both barriers, the lagoon between them, the atoll, the spits and the cove in front
tools/screenshot_map.sh reef --at=632,1180 --name=lagoon   # a player standing in the lagoon
tools/screenshot_map.sh reef --at=-1368,0 --name=atoll   # a player inside the atoll, its tight gate to the wall side
tools/screenshot_map.sh reef --at=-1647,-1150 --name=spit   # a player in the gap between a spit's two rocks
tools/screenshot_map.sh reef --at=-1150,2146 --name=cove   # a player inside the cove, its two posts between them and the sea
tools/screenshot_map.sh shallows       # five lines of posts, thick at the west wall and thinning toward the open water
tools/screenshot_map.sh shallows --at=-2150,0 --name=deep   # a player against the shallow wall, behind the tightest line
tools/screenshot_map.sh shallows --at=2137,2137 --name=pool   # a player in the south rock pool, the post between them and the open water
tools/screenshot_map.sh warrens --admin  # also <mode>_beacon and <mode>_blind: an admin's marks
tools/screenshot_map.sh warrens --fx     # also <mode>_fx: a burst and four mouthfuls, through the real presentation
tools/screenshot_menus.sh              # the screens
```

**Every check this project has over a mode asserts a simulated value**, and a level that is the wrong scale, drawn in the wrong place or not drawn at all passes every one of them. `tools/screenshot_map.sh` renders three framings of a mode because a level is three different claims: the whole arena says the shape reads, a player's own view says the scale does, and the grown view says it still draws once the camera has zoomed out.

**It printed four SCRIPT ERRORs at every startup for as long as the vote frame has existed, and the frames came out anyway (fixed 2026-09-24).** The menus tool's trap, one tool over: `HungryWorld.setup()` adds its `DotMatch` as a child from `SceneTree._initialize`, where the root is not yet inside the tree, so the match had no `_ready`, no scoreboard, and `start`, `add_player` and `tick` each died on a `Nil`. The world limped on without a match — the vote frame's clock said `IDLE` — and fixing it uncovered two framings that had only been right by accident: the whole-arena frame is pinned through the rig's anchor (`position_source`) because a camera position alone is undone by the rig following its anchor, which used to sit at the origin only because the player never existed; and the zoom now snaps per shot (`zoom_sec = 0`), because four frames of a 0.45 s ease left the gate and grown frames at nearly the same zoom. The vote frame refreshes the board, which the client does on its own cadence and the tool never did. The world is driven from `_boot()` on the first frame now. **And its player's-view frames were never where they said (fixed 2026-09-24):** `_boot` ticked until live before adding the player, which is `headless_round`'s old `_settle` trap exactly — dot-match waits in warmup for somebody, so the next tick after the player was added was the reset, and it respawned them at a safe spawn. `--at=640,0` and the default came out as the same frame. The player is added first now.

**The grown frame used to be taken one tick too early (`[hungario-grown-1]`, fixed 2026-10-01).** A tick pushes a piece out of the rocks and THEN resolves eating, so a monster the tool had just fed 805 mass swallowed the food under its new disc on the next tick and was photographed overlapping a post by exactly that growth (12.7 units in `shallows_grown`; 825 -> 919 mass). The game pushes it out on the tick after; the tool now ticks until the player stands clear, up to 30 ticks. A monster grown past a refuge's room stays overlapping, and that is the game (see the rock pools).

**The third one found a bug the first night it existed.** `HungryRenderer._view` and dot-2d's `Dot2DCameraRig` both computed the visible rectangle as the viewport *multiplied* by the zoom. Godot's `Camera2D.zoom` is a magnification — a zoom of 2 covers half the world, not twice it — so both were wrong by the square of the zoom in area, and the zoom here only leaves 1.0 once the player has grown. A monster at half the winning mass sees 2100 units across and had everything past 400 of them culled: most of the screen simply stopped being drawn, on a black background, which reads as an empty arena rather than as a rendering fault. 705 checks across seven suites passed before and after.

## Playing it

```bash
godot --path .                                       # the launcher
godot --path . -- --offline                          # bots, no server
godot --path . -- --connect 127.0.0.1:27081          # straight in
godot --path . -- --offline --touch                  # the phone layout, on a desktop

godot --headless --path . res://examples/dedicated.tscn -- --serve
godot --headless --path . res://tools/publish_avatars.tscn
```

Mouse steers — near is slow, far is full speed. Space splits, W ejects, Q throws, Tab is
the board, Enter is chat, Escape is the menu and the loadout. In the server console,
`hungry_bots 6` fills it.

## Where a dead monster's owner looks

**Until `HungrySpectate` existed the camera stayed exactly where the monster died.**
`HungryCamera` follows an anchor at the mass-weighted centroid and, with nothing to
follow, leaves the camera where it is — so the seconds between being eaten and coming
back were spent looking at the patch of arena that ate you, while the game happened
somewhere else.

**A 2D world is the XZ plane, which is what makes this four lines rather than a second
addon.** dot-npc settled that convention and everything downstream inherited it;
`DotSpectatorManager.camera_2d_of` gives a position back and nothing here needs a 3D
camera or a second code path. The suite asserts the position is where the watched
monster's centroid actually is, which is the check that would fail if the plane
convention were ever quietly changed.

**The policy is this game's own, and the important line is not the obvious one.**
`force_camera` is 0, because a free-for-all has no sides and restricting the camera to
one restricts it to a team of one. What matters is `allow_while_alive = false`: knowing
where the biggest monster is standing is the entire skill of this game, and a living
player with a camera on somebody else has it for free. Roaming is off for the same
reason — a free camera over a 2D arena is the whole map.

`HungrySpectate.camera_position` returns a `Variant` rather than a `Vector2` deliberately:
"not spectating" and "spectating a point at the origin" are different answers, and this
arena is centred on the origin.

## A suite that fails on its ninth run

`examples/dedicated.tscn`'s achievements section recorded 120 bites against a **fixed**
player key and then asserted the second tier had *not* unlocked.

`DotAchievementStoreFile` writes to `user://`, which survives the process. So every run
added 120 bites to the last run's total, the 1000-bite tier unlocked somewhere around the
ninth run, and the check failed from then on — on a machine where nothing had changed and
in a repository nobody had touched.

It is this family's "a test that passes for the wrong reason" with the sign flipped: a
test that eventually **fails** for a reason that has nothing to do with the code, and
whose failure points at the achievements system rather than at the suite. The key is
now unique per run; clearing the directory instead would be a suite deleting a player's
progress, which is the one thing that system must never do by accident.

## The presentation layer, and what it deliberately does not duplicate

`HungryPresentation` holds dot-settings, dot-audio, dot-fx and dot-console — and the
interesting part of this game's integration is what it **refuses to replace**.

**dot-audio does not replace `HungrySound`.** This game bakes its whole bank
arithmetically at boot: fifteen cues, 22 kHz, no files, byte-identical everywhere. That is the
best thing about its audio and throwing it away for an addon that names files would be a
strict downgrade. So `HungrySoundSink` is dot-audio's sink and the generation stays, and
what the addon adds is the half that was never there: a catalogue, per-id concurrency caps,
cooldowns, a distance cull, priorities, a proper `linear_to_db` volume curve, and a manager
that says **why** a sound was refused.

That is the first thing in the family to use `DotAudioSink` for what the seam is actually
for — and it found a real gap in the addon on the first run: **a def with no file was
refused**, because the addon assumed every sound is a path. `DotAudioDef.generated` exists
because of this game.

**dot-settings does not replace `HungryConfig`.** `DotSettingsSchema.from_config` reads it,
so there is still one list: the ranges come from the `@export_range` hints, and the only
thing added is the part a config genuinely cannot say, which is **the scope** — which keys
follow a person between games and which stay with the machine. `apply_to_config` is the way
back, because the config is what the rest of the client reads.

Both are the same decision twice: **two copies of one list is this family's most repeated
bug**, and an addon that makes you write a second one has cost you something.

### The effect scenes, which did not exist until 2026-09-27

`fx_catalogue()` named `eat_pop` and `burst` under `scenes/fx/`, a directory this repository never had, and dot-fx refuses a missing scene at DEBUG — so no mouthful ever popped and no monster ever burst on screen, while `headless_presentation`'s effects section passed on the shake and the tint, which need no scene. `FX_DIR` was also a `const` naming `res://scenes/fx` outright, which a delivered pack resolves against the host's root; it is `HungryPaths.rebase` now. The two scenes are script-free `CPUParticles2D` with a generated soft round texture — a pop of eight crumbs, a burst of twenty-eight fragments — at `z_index` 5, over the renderer's -1. `_build_fx` warns when a scene is missing, as mg-buses-from-hell's `BfhFx.setup` does. The section now asserts `missing_scenes()` is empty, that a burst and a mouthful and a fruit each put particles where they happened and over the world, and that a round reset takes something rather than nothing (7 checks; armed: `eat_pop.tscn` removed fired 3 and the exit probe's copy, the burst's `z_index` removed fired 1). Rendered with `tools/screenshot_map.sh warrens --fx` and looked at: the first burst was a clump the size of the monster, and it throws its fragments now.

### The bug it found, which is the family's own shape again

**A saved volume never reached the sound bank.** Everything in the layer reacts to
`changed`, and a value loaded from disk **has not changed** — so a player who set the
volume to -30, quit and came back got -8, with the config correct the whole time. It is "a
value produced correctly and consumed by nothing" with the symptom pointing at the
consumer. `apply_all()` pushes every current value once after the layer is built, and the
same call was added to the lobby's, the arena's, g2gfast's and the playground's before any
of them could grow it.

## A private arena whose host may leave

`HungryParty` disagrees with `game-arena` on one axis and agrees on the other, and both
halves follow from what kind of game this is.

**Migration is on**, where a round-based deathmatch's is off: hungario is a *continuous*
arena — people join, grow, burst and come back, and there is no round boundary to be in the
middle of — so a host leaving should cost a moment rather than the session.

**Reporting is refused**, exactly as the arena refuses it. This game files to dot-stats and
unlocks dot-achievements, and a peer-to-peer host can lie about how much they ate. A host
who can cheat and a persistent number are one exploit rather than two features, and
`reporting_allowed()` is the one place that is asked.

**It meets over a real HTTP rendezvous, awaited end to end (`[p2p-await-games]`, 2026-09-26).** Every other party check uses the loopback signaller, which answers inside the call, so a caller that forgot `await` passed against it; `headless_presentation` now stands up game-playground's four-route `RendezvousStub` on a local port (38900-38960) that answers four frames late, hosts with one `HungryParty` and joins with another through `DotP2PSignallerHttp`, and asserts the answer is the stub's and arrives after it answered, the rendezvous was told the host's code and name, the joiner learns who is there and does not elect itself, and a 403 leaves the party closed with a reason. With migration on, "does not elect itself" holds only on arrival: the stub relays no heartbeats, so after `host_timeout_sec` the joiner would migrate the host to itself, and the check is asserted before that. Armed by breaking the stub (an empty join answer fired one check, a 500 on everything fired six), not dot-peer-to-peer.

## Two of the five screens are dot-ui's now, and both had been copies

dot-ui grew `DotPauseScreen` and `DotSettingsScreen` because four clients here had independently written the same shapes — a centred `PanelContainer`, a heading, a column of `Button`s, a focus path; and a panel, a title and Apply / Revert / Back. **Three of the four never moved onto them, and this game was one of the three.** What is this game's own is `HungryMenus.PAUSE_BUTTONS` and what happens when a button is pressed; the ids are derived from the labels, and for the three that open a screen **the button id IS the screen id**, so the match in `install` is a lookup rather than a second table of which button opens what.

The settings screen brought something the copy did not have: a `ScrollContainer`. A `DotSettingsPanel` is as tall as the document it was handed, and a document is as long as somebody's `@export` list — without one the column grows past the bottom of the window and takes Apply, Revert and Back with it, which every structural assertion passes through happily and only a picture shows. It is in `screenshot_menus.sh` now for exactly that reason; it was not before.

`ControlsScreen`, `ScoreboardScreen` and `LoadoutScreen` stay this game's own, because each is about something dot-ui has no opinion about: a key map, a match's scoreboard, and a loadout schema.

## The menus, rendered and looked at

`tools/screenshot_menus.sh` renders the pause menu, the loadout picker, the scoreboard, the rebinder and the settings screen. This game has the most screens of any in the family and had no screenshot tool at all.

What it found was in dot-ui rather than here, and it applied to this game's browser and HUD leaderboard as well as its scoreboard: **a column declared with no `width` collapsed to nothing**, so the mass, the pieces, the rank and the ping had never been drawn — one column, with the data correct and `describe()` agreeing. And underneath that, **`DotTableView` honoured no width at all**: it used a `GridContainer`, which gives every column the same width whatever ratio a cell asks for, so the `3.0` on the Monster column was inert and long names were clipped in a table with empty space in it.

The rank column is `0.4` here now. An omitted width is an equal share — which is the right default and the fix for the collapse — so a single-digit `#` would otherwise be given as much room as the mass, and the table opens with a sixth of itself blank. Only a picture says so.

**The tool seeds its monsters on the first frame, not in `_initialize`.** `HungryWorld.setup()` adds its `DotMatch` as a child and a node added from `SceneTree._initialize` does not get `_ready` until the first frame, so the scoreboard does not exist yet and `add_player` dies on it with "Nonexistent function 'join' in base 'Nil'" — which reads like a missing method rather than like a node that has not started. game-simple-lobby's tool carries the same warning and this hit it anyway.

## The chat screen became a chat box, and five games stopped having five of them

This game already had somewhere to type: `HungryMenus.ChatScreen`, a modal `DotScreen` on Enter with one `LineEdit` in it. It worked. It was also the only one of its kind in the family — no log, no channels, and no way to tell whether anything else was carrying the conversation — while four other games here had nothing at all. Five games with five chat boxes is this tree's most expensive shape, so the screen is gone and `HungryPresentation` builds dot-ui's `DotChatWindow` instead. The stack registers **five** screens now, not six, and `headless_round` asserts it.

What a player loses is the Enter key, and it is one setting away.

**Two lines moved rather than went.** The old handler released the voice gate before opening the box, because otherwise the key-up for the talk key lands in the chat box, the gate is never closed, and the player broadcasts whatever they say while typing. That is on `opened` now, where it fires however the box was opened rather than only from the key that used to open it. And `HungryInput.suspended` is set beside it: steering here is the mouse, so typing walks nobody anywhere — but split, throw, boost and eject are all keys, and a player typing "gg boost" splits twice and ejects their mass.

**The three chat settings are added BESIDE the config rather than read out of it**, which is the one place this game departs from its own rule. Everything else in `HungryPresentation.settings` comes from `HungryConfig` through `DotSettingsSchema.from_config`, so tightening a range there tightens the slider, the console and the stored document at once. A `DotConfig` is also layered from a JSON file, the environment and the command line — and a keyboard binding has no business arriving from a server's argv. `HUNGRY_CHAT_OPEN_KEY=Q` in a container would rebind every player on it. `headless_presentation` asserts the key is *not* a config value.

| | |
| --- | --- |
| `chat_window` | `auto` / `on` / `off`. `auto` hides the box on a server already carrying chat somewhere the player can see it; `on` draws it regardless; `off` never does. |
| `chat_open_key` | `Y` by default. |
| `chat_near_key` | `U` by default, and it opens the proximity channel. |

`sandbox` is where the server's side of this is checked over a real socket: a joining client is told what is carrying chat before it has any line to draw, and the suite keeps that payload apart from the lines it asserts must never arrive twice.

## No message preloads itself

`hungry_event.gd` and `hungry_request.gd` each began by preloading themselves, for a typed `of()` factory. mg-buses-from-hell measured that line (8ed866c) as enough to leak the whole script graph at exit on Godot 4.7.2: a script that `extends DotNetMessage` and preloads ITSELF, first loaded by a module inside a running `DotServer` — which is how every deployed server loads a game. Both are built with `new(kind, body)` now, an `_init` whose arguments default because dot-net's registry decodes with a bare `new()`.

`dedicated`'s last section, **exiting clean**, reads every `DotNetMessage` script under `game/` as text and fails on a self-preload. It is on the source deliberately: the leak is printed by the engine after `quit()`, where no assertion can reach.

**Here it was not the cause; `[leak-1]` is closed all the same.** Exactly the same exit warnings before the change as after (2026-09-23): `dedicated` 69 ObjectDB instances and 10 resources; `sandbox` 379 and 295 plus a VariantPools page. By 2026-09-24 both exit with no leak warning at all (11c1fa6 and the commits around it), and `dedicated`'s **exiting clean, as a second process saw it** asserts it by running the suite again in a fresh process and reading its exit. `sandbox` has no such probe; it is clean by observation. `headless_presentation` still prints 8 ObjectDB instances at exit, unchanged by anything on 2026-09-24.

**`[hungario-pres-leak]`, closed 2026-09-25: the presentation leak was the sound bank, and the `--check-only` one is the engine's load order.** A `--verbose` run named the eight: five `AudioStreamPlaybackWAV` and three `AudioStreamWAV` — `HungrySound`'s voices, whose playbacks the audio server still held at exit. Under the dummy driver every headless run gets, a started playback is never mixed and never retired. Taking `player.play()` out removed all eight; stopping and emptying every voice in `_exit_tree`, and waiting 0.3 s before quitting, removed none — the first fix committed tonight (793b358) was the `_exit_tree` one, and it looked right for two runs that happened to come out clean, then leaked four runs in a row. `HungrySound.play` now chooses and loads the voice as before but does not start it when `AudioServer.get_driver_name()` is `Dummy`, which nobody can hear; three runs in a row exit clean. `headless_presentation` had no exit probe of its own then, so this was clean by observation; since 2026-09-27 it runs `dedicated`'s, ported (**exiting clean, as a second process saw it**, 3 checks; armed with one `Node.new()` never freed: "1 ObjectDB instance was leaked at exit", 82 passed, 1 failed). No scripts were involved and nothing in dot-peer-to-peer was. **`godot --check-only --script res://game/hungry_party.gd` still prints 11 ObjectDB instances and 6 resources**, and it is not a leak in any script: the six are dot-core's `DotError`, `DotResult`, `DotLog`, `DotPlatform`, `DotPaths` and `DotHttp`, and it is the Godot 4.7.2 exit-walk bug in [gdscript-hazards.md](../../docs/gdscript-hazards.md#a-script-that-names-itself-can-leak-every-script-at-exit-godot-472) reached by load order alone. Bisected to three lines: a script with `var _h: DotHttp`, a method typed `-> DotP2PSignaller`, and a `DotP2PSignallerLoopback.new(...)` in it prints the same 11/6; drop the `DotHttp` or the loopback, or change the return type to `Object`, and it prints nothing. Every script of dot-peer-to-peer checked on its own is clean, `DotP2PSession` names itself only in a doc comment, and removing the loopback's `as DotP2PSignaller` casts changed nothing. It is a parse-only process: `dedicated`'s exit probe and `sandbox`, which load the same scripts in a running game, exit clean. game-playground's `playground_party.gd` has the same shape and the same 11/6. Upstream's fix to the walk (546e46d3b6) is after 4.7.2; nothing here to change until the engine moves.

## Things deliberately not here

- **Teams.** dot-match does teams properly and `HungryRules` would need about ten lines.
  Free-for-all is what the genre is.
- **dot-combat over eating.** Being devoured is a mass ratio, not a hit-point total, and
  forcing *that* through `DotDamageResolver` would be a worse version of both. Throwables
  do go through it — see above — which is the half that genuinely is damage.
- **dot-map's sync protocol.** The catalogue and the rotation are used; `DotMapSyncHost` is
  not, because dot-server's game change already announces, waits and swaps. Two protocols
  doing one job is the failure this whole file is about.
- **A hunter a client predicts.** They are server-authoritative and unpredicted, for
  dot-props' reason: a corrected NPC reads worse than a slightly late one, and there are
  never enough of them for the traffic to matter.
- **A game delivered through dot-cloud.** The *cosmetics* are, end to end, including the
  refusals. The game itself ships in the build, so `changegame` never exercises
  dot-server's content sync and no client has ever downloaded a map.
- **A real backbone.** `HungryModule` builds the report — with the bot count dot-server
  cannot know, and the mode as the map — and wires it into `DotBackboneClient` when an
  operator has configured a token. Nothing here has ever sent one: there is no backbone in
  this repository, and the checks cover the shape of the report and the fact that an
  unconfigured server stays silent.
- **Lag compensation.** `DotNetConfig.enable_lag_compensation` is off. Nothing in this game
  is a hitscan shot: a thrown item is a moving body both ends already agree about, and
  eating is a proximity test resolved a tick after everyone has moved. Rewinding the world
  would change an outcome nobody disputes.
- **Persistence.** Mass is per round and loadouts are per session — the store is memory,
  because a loadout that outlives a session is a profile and a profile is dot-user's. The
  profile is already resolved; nothing writes to it yet.
- **A master server.** `HungryBrowser` is a real dot-browser list — DQP, DQP over a
  WebSocket, A2S, favourites, history and a mode filter — and the half still missing is in
  the middle: a tracker has to be *told* an address, and nothing announces one.
  `DotBrowserSourceBackbone` reads a listing website-city does not publish yet.

  **The other half was missing at this end and is not any more.** This game shipped that
  browser against a server that answered nothing: `config.query_enabled` was never set,
  no `DotQueryHost` was ever attached, and `HungryModule` contributed no query provider —
  so a hungario server somebody typed the address of straight into the box could not be
  asked what it was running. dot-browser's own suite queries a server dot-browser built,
  which is why neither side had noticed. `HungryQueryProvider` is the game's half of it,
  and what goes in is what a person filtering a list filters on: the mode (which is the
  map here), the occupancy, the round state, the leader's mass, and **whether hunters and
  hazards are on** — the two cvars that make this a different game.

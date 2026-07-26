# Tzeentch Rich Presence

Shows what you're actually doing in Darktide on your Discord profile — the map,
the difficulty, the modifiers, your character, your squad size and how long
you've been in the mission. Friends can join your party straight from Discord.

```
Havoc 40 · Archivum Sycorax · Rotten Armour · Heinous Rituals
Calvin - Zealot 30
(3 of 4)
27:15 elapsed
```

## Features

**Mission line** — the map name, led by the difficulty:

- `Uprising`, `Malice`, `Heresy`, `Damnation`, `Auric`
- `Havoc 40` on Havoc missions, showing the actual rank
- `Maelstrom D-I-IV-IX-G` on Maelstrom missions, at any difficulty
- Active circumstances follow the map — *Heinous Rituals*, *Inferno*,
  *Hunting Grounds*, and the rest, localized in your game's language

**Character line** — your name, class and level. If you run the `true_level`
mod it shows your true level instead of the capped one.

**Party** — the real squad size as `(3 of 4)`, counting every player in your
party whether or not they run this mod.

**Timer** — elapsed time, reset when you drop into a mission rather than when
you launched the game.

**Artwork** — the mission's own loading art as the large image, and your class
icon as the small one.

**Outside missions** — the Mourningstar, the Psykhanium and menus all show
sensibly instead of stale mission data.

**Discord invites** — friends can join your party by clicking Join on your
Discord profile. See [Invites](#invites) below for what that needs.

## Requirements

**The Discord desktop app must be running.** Discord in a browser cannot
receive rich presence — there's no way for the game to talk to it.

**Activity privacy must allow sharing.** In Discord:

> User Settings → Activity Privacy → **Share your detected activities with others**

If this is off, Discord accepts the presence and shows it to nobody. Everything
looks fine from the game's side, so this is the first thing to check if your
status stays blank.

**Do not run Discord as administrator.** More precisely, Darktide and Discord
must run at the *same* elevation — a mismatch means the game cannot open
Discord's connection, and your presence silently never appears. Since Darktide
normally runs unelevated, the practical rule is: don't run either as
administrator.

Also needed:

- Darktide Mod Framework (DMF)
- Windows. The mod ships a native component (`bin/tzrp.dll`) built for Windows;
  it has not been tested under Proton or Steam Deck.

## Installing

Extract into your Darktide `mods/` folder so it looks like:

```
mods/TzeentchRichPresence/
    TzeentchRichPresence.mod
    scripts/
    bin/
```

Then add `TzeentchRichPresence` to `mods/mod_load_order.txt`. If you use Vortex
it will handle this for you.

The `bin/` folder contains two DLLs — the mod's own and Discord's official
Social SDK. Both are required; the mod will load without them but will not
connect to Discord.

## Invites

Clicking **Join** on someone's Discord profile puts you into their Darktide
party.

**Both players need this mod.** The invite is delivered to the game, so someone
without the mod has nothing listening. Nothing breaks — the click simply does
nothing for them.

A Join button is only offered when the party can actually take someone:

- not during loading screens or cinematics
- not when the party is already full
- **not during a private session** — those only admit Fatshark friends, and
  Discord has no way to know whether a given viewer is one, so offering Join
  would leave the invite spinning forever in their chat

If a join is refused by the game anyway (party filled in the meantime,
cross-play restrictions), you'll get a message in chat explaining it.

## Troubleshooting

**Nothing appears on my profile.** Work down the [Requirements](#requirements):
desktop app running, activity sharing on, matching elevation.

**It works for me but a friend sees nothing.** Check *their* activity privacy
setting — it's per-user and controls whether Discord shows their status to
anyone.

**No Join button on my profile.** Expected during loading, in a full party, or
in a private session. Enable *Debug logging* in the mod options and the reason
is written to the console log each time it changes.

**Digging deeper.** Turn on **Debug logging** in the mod's options page. The
game console log (`%APPDATA%/Fatshark/Darktide/console_logs/`) then records the
presence lines as they change, why a Join is or isn't offered, and the full
path of any incoming invite. Lines are tagged `[tzrp]` for the mod's own
decisions and `[discord]` for the SDK's.

If the log repeats `RPC Connect error` or `presence failed: ErrorType: 9`, the
game cannot reach the Discord client at all — that's the desktop-app,
elevation, or activity-privacy checks above, not a problem with the mod.

## Credits

Inspired by the original DiscordRichPresence mod. Built on Discord's Social SDK.
Mission and class artwork are Fatshark's, extracted from the game's own files.

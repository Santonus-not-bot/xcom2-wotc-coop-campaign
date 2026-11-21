# WOTC Co-op Campaign

A shared campaign for up to four players in **XCOM 2: War of the Chosen**. Everyone is on
one Avenger. The host has control of the Avenger by default and gives soldiers to the
guests; guests manage their own soldiers and can ask the host for control. In missions each player moves their own soldiers in
turn: the host first, then each guest in slot order, then the aliens. Everyone else watches.

**Status: not released, early testing.** A full campaign loop has run in automated tests
with two to four copies of the game on one PC over direct IP. Between two PCs on a home
network (direct IP, one Steam account with the guest PC offline) joining, missions and
mission end work, and people have played it by hand; Steam invites, two Steam accounts
and more than two PCs are untested. Built with the [Co-op Anything](https://github.com/cranebeaker/coop-anything)
playbook. Its write-up there (`games/xcom-2/`) holds the design, every test run and the
latest results.

Tested on: Steam, XCOM 2 buildid 8270065 (changelist 699444), War of the Chosen + all DLC,
Windows x64.

## How to play (once released)

1. Every player installs the same mods. The guest's game compares its mod list with the
   host's and refuses to join on a mismatch.
2. The host starts or loads a campaign and clicks **Host co-op** on the Avenger. That
   turns a single-player campaign into a co-op one.
3. Each guest clicks **Join co-op** on the main menu and enters the host's address. The
   default port is 7778 (UDP); the host may have to open it.
4. On the Armory soldier screen the host gives soldiers to players (**Owner** button). In
   squad select the host sets which player gets each slot.
5. Only the host saves (Ironman too). After loading, the host's game opens the server by
   itself, and guests that drop reconnect on their own.

Map pings and text chat work in missions and on the Avenger. Owner tags next to the unit
flags show whose soldier is whose (HOST gold, P2 green, P3 pink, P4 orange). A banner
shows whose turn it is.

## What works (each item has an automated test)

**Avenger and Geoscape**

- **Join:** the host sends its whole campaign history; the guest opens the Avenger from
  it through the load-game path (`CoopHeadquartersGame`).
- **Control of the Avenger** (`CoopSession` baton, `CoopEditGate`, `CoopGuestRights`,
  `CoopBatonPrompt`): the host has it from the start. A guest that asks (button, or by
  opening an edit screen) gets it when the holder answers Yes; the host can always take
  it back. Guests edit their own soldiers without asking. With control a guest may do
  everything the host can except launch missions. The Barracks, the memorial and a
  soldier's overview are open to everyone.
- **Watching the host:** guests follow the Geoscape clock of the player with control
  (`CoopGeoWatch`) and see the squad the host is picking, with the mission name
  (`CoopSquadView`).
- **One editor at a time:** a machine without the baton cannot create game state objects
  (`CoopStrategyRuleset`), otherwise two machines would hand out the same ObjectID.
- **Soldier ownership** (`CoopOwnership`, `CoopHostActions`, `CoopSquadRules`): the host
  gives or takes back any soldier at any time; squad slots are assigned per mission.

**Missions**

- **Turns per player** (`CoopTactical`, `CoopTacticalRuleset`, `CoopTacticalController`):
  one XCom initiative group per player, a selection gate so you can only select your own
  soldiers, and handover between machines through the host (guests connect only to the
  host, which relays frames to the other guests).
- **Single-player rules put back** (`CoopRules`, `CoopToHitCalc_StandardAim`,
  `CoopEffect_Suppression`, `CoopEffect_SpawnShadowbindUnit`): an open connection makes
  the game treat a campaign mission as multiplayer in several places (flank crits,
  suppression, Shadowbind, pausing).
- **Soldiers who join mid-mission** (Avenger defense reinforcements, rescued soldiers)
  move into their owner's group at the next XCom turn.
- **Game content covered by tests:** mind control of and by guests' soldiers, the Lost,
  Chosen kidnapping a guest's soldier, retaliation, a story mission, Avenger defense.

**What players see**

- **Player panel** (`CoopHUDScreen`, `CoopRoster`): every player's Steam name in their
  colour, slot, connection state (connected, loading, reconnecting, left) and what they are
  doing on the Avenger (`CoopActivity`); toasts for joins, leaves and reconnects.
- **Barracks tags** (`CoopBarracksTags`): each soldier's owner next to the name, other
  players' rows tinted in their colour.
- **Mission loading screen for guests** (`CoopMissionLoading`, `CoopLoadingScreen`): "the
  host is launching <mission>" with the steps, from the launch until the guest is in the
  mission, and the same on the way back to the Avenger.
- **In missions** (`CoopPresence`, `CoopActionWatch`, `CoopTurnBanner`): a turn banner,
  the active player's cursor marker and selected soldier, a short feed of their actions,
  and map pings (Alt + left click) on every machine.

**Connections and saves**

- **Disconnects:** the host takes over a dropped guest's soldiers. The guest reconnects
  by itself, joins the running mission and gets them back. A guest that restarts its game
  asks for its old slot again (`CoopGuestMemory`).
- **Mission start and end:** the connection closes while a map loads and reopens when
  everyone is back (`CoopLink`).
- **Saves:** host only, mid-mission and Ironman included (`CoopAutosaveMgr`,
  `CoopSaveGate`).
- **Crash fixes:** the game's PvP lost-connection handling is skipped in co-op missions,
  and a guest leaving the Avenger pauses the world for a second first. Without that, the
  game's sound callback could run after the map was gone (`CoopHeadquartersController`).

## Settings

`Config/XComCoopCampaign.ini`, main keys:

| Key | Default | What it does |
|---|---|---|
| `CoopLink.DefaultPort` | 7778 | Port the host listens on |
| `CoopLink.ReconnectSeconds` | 600 | How long a guest keeps trying to reconnect |
| `CoopLink.WaitForGuestsSeconds` | 120 | How long the host waits for guests after a map load |
| `CoopLink.bAutoHostOnLoad` | true | Loading a co-op save opens the server |
| `CoopTactical.bSplitXComGroupAtStart` | true | One initiative group per player |
| `CoopTacticalController.bGateSelection` | true | Players select only their own soldiers |
| `CoopGuestRights.bHostDecidesCampaign` | true | Guests manage only their soldiers |
| `CoopSteamJoin.bSteamInvites` | false | Steam invites (untested) |
| `CoopEditGate.EditScreens` | list | Screens that need the baton |

## Known issues

- Untested with two Steam accounts, over Steam (invites and Steam sockets) and with more
  than two PCs.
- Very long campaigns: a whole-history send above about 670 KB never arrives (around
  mission 14 of a test campaign). `CoopLink.bPartialResend=true` sends deltas
  instead; it passed 16 missions on one PC but is off by default.
- A guest goes through the main menu during a mission launch (covered by the loading
  screen); only the host launches missions.
- A guest that joins mid-mission can lose its first turn.
- A guest who drops mid-turn loses that turn's actions; the host plays on from there.
- Mods that replace `UIUnitFlag` conflict with the owner tags. Mods that replace
  `XComHeadquartersController` conflict with the guest's Avenger exit.
- A guest's visualization that times out while it waits for its turn is finished by the
  mod so the turn can start. The cause (an AI reveal timing out on the guest) is unknown.
- Popups (research done, new missions) show only on the machine on the Geoscape, which is
  the host's (found in the strategy prototype, not rechecked since).

## Build

Needs the XCOM 2 War of the Chosen SDK (Steam) and a **copy** of the game used only for
tests (never build into the install you play):

```powershell
$env:XCOM2_SDK = "<SDK dir>"          # ...\XCOM 2 War of the Chosen SDK
$env:COOP_WORKSPACE = "<workspace>"   # holds the test copies of the game
tools\build_mod.ps1
```

Build scripts: [X2ModBuildCommon](https://github.com/X2CommunityCore/X2ModBuildCommon)
(MIT, in `.scripts/`).

## QA: several game copies on one PC

- Each copy is a hard-link clone of a test install with its own `XComGame/Config`
  (`tools/hardlink_clone.py`). All run with `-nohomedir`, so saves, config and logs stay
  inside the copies.
- XCOM 2 refuses a second instance while the first holds the mutex `UnrealEngine3_<n>`;
  `tools/launch_pair.ps1` closes that handle inside the first copy (same user, no admin)
  with Sysinternals `handle64.exe` (download it yourself, set `SYSINTERNALS_HANDLE`) and
  `tools/close_remote_handle.py`.
- The mod contains a test bot (`CoopHarness`, `CoopExperiments`, `CoopContentTests`). A
  runner writes a list of steps per copy (console commands and `@` commands such as
  `@connect`, `@squad`, `@launch`, `@waitmyturn`, `@endturn`, `@useability`, `@save`),
  starts the copies, and asserts on every copy's log (expected lines, no crash, no
  desync, equal campaign fingerprints). The bot does nothing when its step list is empty
  (normal play).
- Some crashes leave no game crash report. With Windows' `LocalDumps` setting on, Windows
  writes a minidump for them, and `tools/minidump_info.py` reads it without a debugger.

Last results: see the Co-op Anything write-up (`games/xcom-2/README.md`).

## Credits and license

Strategy-layer prototype by EvilMask587; campaign and mission co-op built on it. See
`LICENSE` (MIT).

//---------------------------------------------------------------------------------------
//  FILE:    CoopLink.uc
//  PURPOSE: Owns the co-op connection: the host's server, a guest's connection to it, and
//           the hand-over around building a mission.
//
//           Why the host closes the connection while a mission is built: the engine's
//           IsSinglePlayerGame() is false whenever XComGameStateNetworkManager has a server or
//           connection open (test "netprobe", 2026-11-12: NetMode stays NM_Standalone; opening a
//           server flips single=false, closing it flips it back). Mission setup branches on it:
//           X2TacticalGameRuleset.SetupUnits spawns aliens only in single player, the parcel
//           manager spawns mission objectives only in single player, and the drop-ship intro and
//           mission intro are single-player only. With the server open the test mission had
//           "alien=0"; with it closed before launch, the same kind of mission had "alien=6".
//
//           Host:  OnPreMission (strategy, just before the map travel) -> remember which guests
//                  were connected, close the server -> the mission is built as single player ->
//                  first unit actions (CoopTacticalRuleset) -> reopen the server on the same port ->
//                  guests reconnect -> once every guest that was connected at launch is back (or
//                  after WaitForGuestsSeconds) the mission history goes out (CoopTacticalNet).
//                  A guest that joins later during the mission gets the mission history then.
//           Guest: when the connection to the host closes, keep trying to reconnect to the same
//                  address for ReconnectSeconds. The guest goes back to the main menu (the game's
//                  ReturnToMPMainMenu, after a quiet second with the world paused: StartQuietLeave); it
//                  reconnects from there and loads the mission from there.
//                  Its hello names its old slot; the host gives it back if it is free (CoopJoin).
//                  (The join request URL carries only the player's name, so the slot cannot ride on it.)
//
//           Back to the Avenger (the same in reverse): when the host's ruleset enters EndTacticalGame
//                  the host closes the connection (the mission summary, the after action and the
//                  strategy transfer run as single player); OnPostMission (strategy load) schedules the
//                  server to reopen ReturnReopenDelay later; once the mission's guests are back the
//                  campaign history goes out, each guest acknowledges it and the host answers
//                  "CoopEnterAvenger": the guest opens the Avenger with that history (as a guest
//                  entering the campaign, CoopSession.bEnterAsMirror).
//
//           A plain Object; its timers run on CoopLinkTimer (an Actor, one per map).
//---------------------------------------------------------------------------------------
class CoopLink extends Object config(CoopCampaign);

var config int DefaultPort;                 // used when the server was opened some other way (console MPCreateServer)
var config float ReconnectSeconds;          // guest: how long to keep trying after losing the host
var config float ReconnectInterval;         // guest: seconds between attempts
var config float JoinRetrySeconds;          // guest: how long a first join keeps trying
var config float JoinNoHistorySeconds;      // guest: slot given but no history this long: reconnect
var config bool bPartialResend;              // host: after the first whole history, send later ones as a delta (experiment)
var config int WholeSendCount;              // host: whole histories sent this session (runtime)
var config bool bArchiveBeforeCampaignSend;   // host: compact the history (ArchiveHistory) before each campaign send (experiment)
var config int TestHoldJoinSends;           // test hook (host): skip the campaign send for this many joins on the Avenger
var config float WaitForGuestsSeconds;      // host: how long the mission waits for guests before sending the history anyway
var config bool bCloseForMissionBuild;      // host: close the connection while a mission is built (see above)
var config bool bAutoHostOnLoad;            // host: loading a co-op campaign's save opens the server again by itself

// runtime state (config only so the default may be written)
var config int HostPort;                    // host: port of the server we opened (0 = unknown)
var config bool bHostSteam;
var config bool bReopenPending;             // host: server closed for the mission build
var config bool bMissionRunning;            // host: the mission reached unit actions; joining guests get its history
var config bool bMissionHistorySent;
var config array<int> MissionSlots;         // host: guest slots connected when the mission launched
var config float WaitUntil;                 // host: give up waiting for MissionSlots at this time
var config string GuestHost;                // guest: address of the host we joined ("" = none)
var config int GuestPort;
var config bool bGuestSteam;
var config int WantSlot;                    // guest: slot to ask for when reconnecting (0 = any)
var config bool bReconnecting;
var config bool bForcePending;              // guest: CreateClient done, ForceConnectionAttempt on the next tick
var config bool bTearDownPending;           // guest: drop the dead client connection on the next tick
var config float ReconnectUntil;
var config bool bJoinRetry;                 // guest: first join not answered yet, try again until JoinRetryUntil
var config float JoinRetryUntil;
var config float JoinedAt;                  // guest: when the host gave us a slot (0 = not waiting for a history)
var config bool bHistorySinceJoin;
var config float ReturnReopenDelay;         // host: seconds after OnPostMission before the server reopens on the Avenger
var config bool bReturnPending;             // host: closed at the mission's end, the Avenger is loading
var config bool bReopenAfterReturn;         // host: back on the Avenger, reopen at ReopenAt
var config float ReopenAt;
var config bool bCampaignWait;              // host: reopened on the Avenger, waiting for the mission's guests
var config bool bCampaignSent;
var config float JoinCoalesceSeconds;       // host: a guest joining on the Avenger gets the campaign this long after its slot
var config bool bJoinSendPending;
var config float JoinSendAt;
var config float QuietLeaveSeconds;         // guest: world paused this long before leaving for the main menu
var config float LeaveAt;                   // guest: leave for the main menu at this time (0 = not leaving)

static function float Now()
{
	return class'WorldInfo'.static.GetWorldInfo().RealTimeSeconds;
}

// ---------------------------------------------------------------- host

static function bool HostOpen(int Port, optional bool bSteam)
{
	local URL ServerURL;
	local string Error;

	class'CoopTacticalNet'.static.PrimeBase("server opens on port" @ Port);    // chunked whole sends need a base
	ServerURL.Port = Port;
	if (bSteam)
	{
		ServerURL.Op.AddItem("steamsockets");
	}
	`XCOMNETMANAGER.CreateServer(ServerURL, Error);
	default.HostPort = Port;
	default.bHostSteam = bSteam;
	`log("host: server opened on port" @ Port @ (bSteam ? "(steam)" : "") @ (Error != "" ? "error=" $ Error : ""),, 'CoopLink');
	class'CoopJoin'.static.Init();
	class'CoopLinkTimer'.static.Ensure();    // SweepNotices from now on
	// the host has the say on the Avenger from the start; guests ask for it (two-PC play test 2026-11-19: with
	// nobody holding it, both sides showed "Control: partner" and asking did nothing)
	if (!class'CoopSession'.default.bHasBaton && class'CoopSession'.default.BatonEpoch == 0)
	{
		`log("host: the host holds the baton from the start",, 'CoopLink');
		class'CoopSession'.static.SetBaton(true);
	}
	return Error == "";
}

// A save of a co-op campaign was loaded on this machine (Where: "the Avenger" from the HUD listener, "a mission"
// from CoopTacticalRuleset's first unit actions after a load). Only the host saves, so this machine hosts:
// open the server the way the "Host co-op" button does. Inside a mission there is no such button, and without
// this the guests could never come back after the host loaded a mid-mission save. Not after a mission's own
// close/reopen (those reopen by themselves) and not while a server is open.
static function HostLoadedGame(string Where)
{
	local int Slot;

	// A save loaded from the co-op lobby ("Load" there): the lobby's server stays open through the load and its friends
	// stay connected on the main menu, without the campaign (lobbyload 2026-11-25: they waited in the lobby until the
	// host quit). On the Avenger they get it the way a join does. Not handled: a mid-mission save loaded from the lobby.
	if (class'CoopLobby'.default.bHosting && !class'CoopRole'.static.IsGuest() && `XCOMNETMANAGER.HasServerConnection())
	{
		class'CoopLobby'.default.bHosting = false;
		class'CoopLobby'.default.Mode = class'CoopLobby'.const.MODE_NONE;
		`log("host: co-op campaign loaded on" @ Where @ "from the lobby, players" @ SlotList(class'CoopRole'.default.ConnectedSlots)
			@ "connected: the campaign goes to them",, 'CoopLink');
		if (!class'CoopRole'.static.CoopActive())
		{
			`log("host: the loaded save is not a co-op campaign: use Host co-op on the Avenger",, 'CoopLink');
			return;
		}
		foreach class'CoopRole'.default.ConnectedSlots(Slot)
		{
			HostJoinedOnAvenger(Slot);
		}
		return;
	}
	if (!default.bAutoHostOnLoad || !class'CoopRole'.static.CoopActive() || class'CoopRole'.static.IsGuest()
		|| `XCOMNETMANAGER.HasServerConnection() || default.bReopenPending || default.bReturnPending || default.bReopenAfterReturn)
	{
		return;
	}
	`log("host: co-op campaign loaded on" @ Where $ ": hosting again",, 'CoopLink');
	class'CoopMenu'.static.HostFromAvenger();
}

// X2DownloadableContentInfo.OnPreMission: the start state is built, the map travel follows.
static function HostCloseForMission(optional string MissionName)
{
	local int Slot;
	local array<byte> Params;

	default.bMissionRunning = false;
	default.bMissionHistorySent = false;
	default.MissionSlots.Length = 0;
	if (!default.bCloseForMissionBuild || !class'CoopRole'.static.CoopActive() || class'CoopRole'.static.IsGuest()
		|| !`XCOMNETMANAGER.HasServerConnection())
	{
		return;
	}
	default.MissionSlots.Length = 0;
	foreach class'CoopRole'.default.ConnectedSlots(Slot)
	{
		default.MissionSlots.AddItem(Slot);
	}
	if (default.HostPort <= 0)
	{
		default.HostPort = default.DefaultPort;
	}
	// the guests' loading screen (CoopMissionLoading); it arrived before the close in every test run
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(MissionName, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopMissionBuilding", Params);
	class'CoopRole'.default.ConnectedSlots.Length = 0;    // first: a deliberate close needs no roll call
	class'CoopRole'.default.ConnectionSlots.Length = 0;
	`XCOMNETMANAGER.Disconnect();
	`XCOMNETMANAGER.ResetConnectionData();
	default.bReopenPending = true;
	`log("host: connection closed while the mission is built (single player); guests at launch:" @ SlotList(default.MissionSlots)
		@ "single=" $ class'CoopHarness'.static.BoolStr(class'Engine'.static.GetEngine().IsSinglePlayerGame()),, 'CoopLink');
}

// CoopTacticalRuleset, host's first unit actions of the mission.
static function HostMissionReady()
{
	default.bMissionRunning = true;
	if (default.bReopenPending)
	{
		default.bReopenPending = false;
		HostOpen(default.HostPort, default.bHostSteam);
		default.WaitUntil = Now() + default.WaitForGuestsSeconds;
		`log("host: mission built, server reopened; waiting for guests" @ SlotList(default.MissionSlots),, 'CoopLink');
		class'CoopLinkTimer'.static.Ensure();
		return;
	}
	if (class'CoopRole'.default.ConnectedSlots.Length > 0)
	{
		HostSendMissionOnce();
	}
}

// CoopTacticalRuleset, host: the mission is over (EndTacticalGame).
static function HostCloseForReturn()
{
	local int Slot;

	default.bMissionRunning = false;
	if (!class'CoopRole'.static.CoopActive() || class'CoopRole'.static.IsGuest() || !`XCOMNETMANAGER.HasServerConnection())
	{
		return;
	}
	default.MissionSlots.Length = 0;
	foreach class'CoopRole'.default.ConnectedSlots(Slot)
	{
		default.MissionSlots.AddItem(Slot);
	}
	if (default.HostPort <= 0)
	{
		default.HostPort = default.DefaultPort;
	}
	class'CoopTacticalNet'.static.Send("CoopMissionReturning");    // the guests' loading screen (CoopMissionLoading)
	class'CoopRole'.default.ConnectedSlots.Length = 0;    // first: a deliberate close needs no roll call
	class'CoopRole'.default.ConnectionSlots.Length = 0;
	`XCOMNETMANAGER.Disconnect();
	`XCOMNETMANAGER.ResetConnectionData();
	default.bReturnPending = true;
	`log("host: mission over: connection closed for the return to the Avenger; guests in the mission:" @ SlotList(default.MissionSlots),, 'CoopLink');
}

// X2DownloadableContentInfo.OnPostMission: called while the Avenger loads after a mission.
static function HostBackOnAvenger()
{
	if (!default.bReturnPending)
	{
		return;
	}
	default.bReturnPending = false;
	default.bReopenAfterReturn = true;
	default.ReopenAt = Now() + default.ReturnReopenDelay;
	`log("host: back on the Avenger; the server reopens in" @ int(default.ReturnReopenDelay) @ "s",, 'CoopLink');
	class'CoopLinkTimer'.static.Ensure();
}

static function HostSendCampaignOnce()
{
	if (default.bCampaignSent)
	{
		return;
	}
	default.bCampaignSent = true;
	default.bCampaignWait = false;
	`log("host: guests back" @ SlotList(class'CoopRole'.default.ConnectedSlots) @ "of" @ SlotList(default.MissionSlots) @ ": sending the campaign",, 'CoopLink');
	class'CoopTacticalNet'.static.HostSendCampaign();
}

// CoopJoin, host: a guest got its slot.
static function HostGuestJoined(int Slot)
{
	if (default.bCampaignWait && !class'CoopSession'.static.InTactical())
	{
		if (AllMissionSlotsBack())
		{
			HostSendCampaignOnce();
		}
		return;
	}
	if (!class'CoopSession'.static.InTactical())
	{
		HostJoinedOnAvenger(Slot);
		return;
	}
	if (!default.bMissionRunning)
	{
		return;
	}
	if (default.bMissionHistorySent)
	{
		// a guest joining a running mission (late, or after losing its connection)
		`log("host: player" @ Slot @ "joined the running mission: sending the mission history",, 'CoopLink');
		class'CoopTacticalNet'.static.HostSendMission();
		return;
	}
	if (AllMissionSlotsBack())
	{
		HostSendMissionOnce();
	}
}

// A guest joined while the host is on the Avenger: send it the campaign and bring it in ("CoopEnterAvenger"),
// a little later so that guests joining together share one send. (The test runner used to do this with the
// console command MPSendHistory and the bot's @mirror.) With the mod check on, CoopJoin.OnModsResult sends
// the campaign once the mods match instead.
static function HostJoinedOnAvenger(int Slot)
{
	if (XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game) == none || class'CoopJoin'.default.bGateJoinOnMods)
	{
		return;
	}
	if (default.TestHoldJoinSends > 0)
	{
		// for the test of the guest's no-history watchdog (scenario joinwatchdog); 0 in normal play
		default.TestHoldJoinSends--;
		`log("host: test: holding the campaign for player" @ Slot @ "(TestHoldJoinSends)",, 'CoopLink');
		return;
	}
	default.bJoinSendPending = true;
	default.JoinSendAt = Now() + default.JoinCoalesceSeconds;
	`log("host: player" @ Slot @ "joined on the Avenger: the campaign goes out in" @ int(default.JoinCoalesceSeconds) @ "s",, 'CoopLink');
	class'CoopLinkTimer'.static.Ensure();
}

// CoopRole.FreeGuestSlot: a guest slot the host is waiting for (it was in the mission and has not come back yet).
static function bool SlotAwaited(int Slot)
{
	return default.MissionSlots.Find(Slot) != INDEX_NONE && class'CoopRole'.default.ConnectedSlots.Find(Slot) == INDEX_NONE
		&& (default.bReopenPending || default.bReturnPending || default.bReopenAfterReturn || default.bCampaignWait
			|| (default.bMissionRunning && !default.bMissionHistorySent));
}

static function bool AllMissionSlotsBack()
{
	local int Slot;

	foreach default.MissionSlots(Slot)
	{
		if (class'CoopRole'.default.ConnectedSlots.Find(Slot) == INDEX_NONE)
		{
			return false;
		}
	}
	return true;
}

static function HostSendMissionOnce()
{
	if (default.bMissionHistorySent)
	{
		return;
	}
	default.bMissionHistorySent = true;
	`log("host: guests back" @ SlotList(class'CoopRole'.default.ConnectedSlots) @ "of" @ SlotList(default.MissionSlots) @ ": sending the mission",, 'CoopLink');
	class'CoopTacticalNet'.static.HostSendMission();
}

// ---------------------------------------------------------------- guest

static function bool GuestConnect(string Host, int Port, optional bool bSteam)
{
	default.GuestHost = Host;
	default.GuestPort = Port;
	default.bGuestSteam = bSteam;
	if (default.WantSlot <= 0)
	{
		// a new game process joining a host it played with before: ask for the same player slot (its soldiers)
		default.WantSlot = class'CoopGuestMemory'.static.SlotFor(Host, Port);
	}
	class'CoopJoin'.static.Init();
	// a first join retries like a reconnect (the host's server may not be open yet; before 2026-11-15 a failed
	// first attempt left the guest on the main menu for good)
	if (!default.bReconnecting)
	{
		default.bJoinRetry = true;
		default.JoinRetryUntil = Now() + default.JoinRetrySeconds;
	}
	return TryConnect();
}

// "a.b.c.d" as one unsigned decimal number (192.168.1.20 -> "3232235796"), the form CreateClient needs.
// UnrealScript ints are signed 32-bit: packing the octets into one int made every address from 128.0.0.0 up
// negative ("-1062731500"), which the driver then tried to resolve as a host name and failed (error 11001,
// two-PC rehearsal 2026-11-15; only 127.0.0.1 had worked). So the number is built in base 10000.
static function string DecimalIPv4(string Dotted)
{
	local array<string> Octets;
	local int Hi, Lo;
	local string LoText;

	Octets = SplitString(Dotted, ".", true);
	if (Octets.Length != 4)
	{
		return Dotted;
	}
	// a*16777216 = a*1677*10000 + a*7216; the other three octets are below 16777216
	Hi = int(Octets[0]) * 1677;
	Lo = int(Octets[0]) * 7216 + int(Octets[1]) * 65536 + int(Octets[2]) * 256 + int(Octets[3]);
	Hi += Lo / 10000;
	Lo = Lo % 10000;
	if (Hi == 0)
	{
		return string(Lo);
	}
	LoText = string(Lo);
	while (Len(LoText) < 4)
	{
		LoText = "0" $ LoText;
	}
	return string(Hi) $ LoText;
}

// Host is a dotted IPv4 address (converted to the decimal form CreateClient needs) or a Steam id.
static function bool TryConnect()
{
	local URL ClientURL;
	local string Error;

	if (default.bGuestSteam)
	{
		ClientURL.Host = default.GuestHost;
		ClientURL.Op.AddItem("steamsockets");
	}
	else
	{
		ClientURL.Host = DecimalIPv4(default.GuestHost);
	}
	ClientURL.Port = default.GuestPort;
	// A connection attempt that fails sends the game back to the main menu ("Failed; returning to Entry"). From
	// the main menu with the Firaxis Live login screen open, that reload asserted (UnGame.cpp:3107, run
	// missionend-20261112-204239, where the host had hung at start-up). Clear its delegates first.
	class'CoopTacticalNet'.static.ClearShellLiveDelegates();
	`XCOMNETMANAGER.CreateClient(ClientURL, Error);
	class'CoopMissionLoading'.static.NoteAttempt();
	default.bForcePending = true;    // the connection attempt goes out on the next tick (as the harness did after 0.25 s)
	class'CoopLinkTimer'.static.Ensure();
	`log("guest: connecting to" @ default.GuestHost $ ":" $ default.GuestPort @ "slot wanted=" $ default.WantSlot @ (Error != "" ? "error=" $ Error : ""),, 'CoopLink');
	return Error == "";
}

// CoopJoin, guest: the connection to the host closed. Slot is the one we had.
static function GuestLostHost(int Slot)
{
	// a guest in the main menu's lobby has no campaign yet; the host left to start the game (CoopLobby)
	if (default.GuestHost == "" || (!class'CoopRole'.static.CoopActive() && !class'CoopLobby'.default.bGuestInLobby))
	{
		return;
	}
	if (Slot > 0)
	{
		default.WantSlot = Slot;
	}
	default.bReconnecting = true;
	default.bTearDownPending = true;
	default.ReconnectUntil = Now() + default.ReconnectSeconds;
	if (!class'CoopMissionLoading'.default.bActive)
	{
		class'CoopRoster'.static.GuestLink(false);    // not the planned close for a mission build: tell the player
	}
	`log("guest: lost the host (a mission is built without connection, or it left); reconnecting for" @ int(default.ReconnectSeconds) @ "s as player" @ default.WantSlot,, 'CoopLink');
	class'CoopLinkTimer'.static.Ensure();
}

// CoopShellController, guest on the main menu (in a lobby or reconnecting): CoopLink handles the lost connection.
static function bool GuestLostHostOnMenu()
{
	return default.GuestHost != "" && default.bReconnecting
		&& (class'CoopLobby'.default.bGuestInLobby || class'CoopRole'.static.CoopActive())
		&& XComShell(class'WorldInfo'.static.GetWorldInfo().Game) != none;
}

// CoopHeadquartersController, guest on the Avenger: the game reports the lost connection after CoopJoin's
// ConnectionClosed handler ran GuestLostHost. True when CoopLink takes over the way to the main menu.
static function bool GuestLostHostOnAvenger()
{
	return default.GuestHost != "" && default.HostPort == 0 && default.bReconnecting
		&& class'CoopRole'.static.CoopActive()
		&& XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game) != none;
}

// Guest: leave the Avenger or the mission map for the main menu without racing the audio thread. A matinee
// sound (InterpTrackAkEvent) posted in the last frames before a map unload calls back from Wwise's thread
// (callback type 8, probably AK_Duration), and the game's handler for it reads the world, which is null while the map unloads:
// the guest died silently (XCom2.exe+0x6d0695, thread AK::EventManager). Pausing the world stops Kismet and
// matinee updates, so nothing new is posted; after QuietLeaveSeconds the callbacks already queued are done.
static function StartQuietLeave(string Where)
{
	local WorldInfo WI;
	local PlayerController PC;

	WI = class'WorldInfo'.static.GetWorldInfo();
	PC = WI.GetALocalPlayerController();
	if (WI.Pauser == none && PC != none && PC.PlayerReplicationInfo != none)
	{
		WI.Pauser = PC.PlayerReplicationInfo;
	}
	default.LeaveAt = Now() + default.QuietLeaveSeconds;
	`log("guest: leaving the" @ Where @ "for the main menu in" @ default.QuietLeaveSeconds @ "s, world paused=" $ (WI.Pauser != none),, 'CoopLink');
	class'CoopLinkTimer'.static.Ensure();
}

static function FinishQuietLeave()
{
	local WorldInfo WI;

	default.LeaveAt = 0;
	WI = class'WorldInfo'.static.GetWorldInfo();
	if (XComHeadquartersGame(WI.Game) != none)
	{
		`log("guest: leaving the Avenger now",, 'CoopLink');
		// what the game's own lost-connection handling does (XComPlayerController.OnDestroyedOnlineGame)
		`ONLINEEVENTMGR.ReturnToMPMainMenu(QuitReason_OpponentDisconnected);
	}
	else
	{
		`log("guest: leaving the mission map now",, 'CoopLink');
		WI.GetALocalPlayerController().ConsoleCommand("disconnect");
	}
}

// CoopJoin, guest: the host gave us a slot (the wanted one if it was free).
static function GuestJoined(int Slot)
{
	default.bJoinRetry = false;
	default.JoinedAt = Now();
	default.bHistorySinceJoin = false;
	if (default.bReconnecting)
	{
		default.bReconnecting = false;
		if (!class'CoopMissionLoading'.default.bActive)
		{
			class'CoopRoster'.static.GuestLink(true);
		}
		`log("guest: reconnected, given player" @ Slot,, 'CoopLink');
	}
	default.WantSlot = Slot;
	class'CoopMissionLoading'.static.Advance(class'CoopMissionLoading'.const.STEP_JOINING, "the host took us back");
	`log("guest: playing as player" @ Slot,, 'CoopLink');
	class'CoopGuestMemory'.static.Remember(default.GuestHost, default.GuestPort, Slot);
}

// ---------------------------------------------------------------- timer (CoopLinkTimer, every second)

static function Tick()
{
	class'CoopTacticalNet'.static.KeepBase();
	class'CoopChunks'.static.Init();    // chunked history sends (experiment; idle unless a send runs)
	class'CoopLobby'.static.Init();     // the main menu's lobby: guests hear "CoopLobby"
	class'CoopLobby'.static.Tick();
	class'CoopChunks'.static.Tick();
	class'CoopActivity'.static.Tick();
	class'CoopRoster'.static.Tick();
	class'CoopGeoWatch'.static.HostTick();
	if (class'CoopSession'.static.IsConnected())
	{
		class'CoopSquadView'.static.Init();
	}
	class'CoopSquadView'.static.HostTick();
	// the co-op layers on this map, once its presentation layer is ready (the screen listeners can come too early)
	if (class'CoopRole'.static.CoopActive())
	{
		class'CoopHUDScreen'.static.Ensure();
	}
	class'CoopMissionLoading'.static.Show();
	class'CoopMissionLoading'.static.CheckLoadOverdue();
	if (default.LeaveAt > 0)
	{
		if (Now() >= default.LeaveAt)
		{
			FinishQuietLeave();
		}
		return;
	}
	if (default.bJoinSendPending && Now() >= default.JoinSendAt)
	{
		default.bJoinSendPending = false;
		class'CoopTacticalNet'.static.HostSendCampaign();
	}
	if (class'CoopTacticalNet'.default.bRelayPending)
	{
		class'CoopTacticalNet'.static.SendRelay();
	}
	if (class'CoopRole'.default.RollToken > 0 && Now() >= class'CoopRole'.default.RollUntil)
	{
		class'CoopRole'.static.RollCallDone();
	}
	if (default.bReopenAfterReturn && Now() >= default.ReopenAt)
	{
		default.bReopenAfterReturn = false;
		default.bCampaignSent = false;
		default.bCampaignWait = true;
		HostOpen(default.HostPort, default.bHostSteam);
		default.WaitUntil = Now() + default.WaitForGuestsSeconds;
		`log("host: back on the Avenger: server reopened; waiting for guests" @ SlotList(default.MissionSlots),, 'CoopLink');
	}
	if (default.bCampaignWait && Now() > default.WaitUntil)
	{
		`log("host: stopped waiting for guests on the Avenger after" @ int(default.WaitForGuestsSeconds) @ "s",, 'CoopLink');
		default.bCampaignWait = false;
		if (class'CoopRole'.default.ConnectedSlots.Length > 0)
		{
			HostSendCampaignOnce();
		}
	}
	// A guest inside a mission keeps its client net driver when the host closes (on the Avenger the engine
	// shuts it down and returns to the main menu): HasClientConnection() stayed true, so it never tried to
	// reconnect (run missionend-20261112-173212). Tear it down here, outside the network callback.
	if (default.bTearDownPending)
	{
		default.bTearDownPending = false;
		if (`XCOMNETMANAGER.HasClientConnection())
		{
			`XCOMNETMANAGER.Disconnect();
			`XCOMNETMANAGER.ResetConnectionData();
			`log("guest: dropped the dead connection to the host",, 'CoopLink');
		}
		// main menu: CoopShellController ignored network messages until the dead connection was gone
		if (CoopShellController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()) != none)
		{
			CoopShellController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).bIgnoreNetworkMessages = false;
		}
		// Leave the mission map before the next history arrives: a guest that reconnected on the mission map
		// and received the campaign there crashed ("GettingNameData", run missionend-20261112-174209). From
		// the main menu it reconnects and enters the Avenger or the next mission like any joining guest.
		if (class'CoopSession'.static.InTactical())
		{
			StartQuietLeave("mission map");
		}
		// on the Avenger, CoopHeadquartersController skipped the game's own way out
		else if (XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game) != none)
		{
			StartQuietLeave("Avenger");
		}
		return;
	}
	if (default.bForcePending)
	{
		default.bForcePending = false;
		`XCOMNETMANAGER.ForceConnectionAttempt();
		return;
	}
	if (default.bReconnecting && !`XCOMNETMANAGER.HasClientConnection())
	{
		if (Now() > default.ReconnectUntil)
		{
			default.bReconnecting = false;
			class'CoopMissionLoading'.static.End("gave up reconnecting");
			`log("guest: gave up reconnecting to" @ default.GuestHost,, 'CoopLink');
		}
		else if (int(Now()) % Max(1, int(default.ReconnectInterval)) == 0)
		{
			TryConnect();
		}
	}
	// A guest that rejoined on the main menu seconds before the host closed the connection to build a mission got
	// its slot, never saw the close, and sat there "connected" without a history until the host quit (chosenassault
	// 2026-11-16: slot at 188 s, the host's close at 193 s, the guest's connection stayed up for 190 s). With no
	// history within JoinNoHistorySeconds of the slot, treat the host as lost and reconnect.
	if (default.JoinedAt > 0 && !default.bHistorySinceJoin && !default.bReconnecting && class'CoopRole'.static.IsGuest()
		&& !class'CoopSession'.static.InTactical() && `XCOMNETMANAGER.HasClientConnection()
		&& Now() - default.JoinedAt > default.JoinNoHistorySeconds)
	{
		`log("guest: no history" @ int(Now() - default.JoinedAt) @ "s after the host gave us a slot: reconnecting",, 'CoopLink');
		default.JoinedAt = 0;
		// not GuestLostHost: it does nothing before a co-op campaign is active, which a guest on the main menu
		// waiting for its first campaign does not have yet (joinwatchdog 2026-11-17: no reconnect followed)
		default.bReconnecting = true;
		default.bTearDownPending = true;
		default.ReconnectUntil = Now() + default.ReconnectSeconds;
		return;
	}
	if (default.bJoinRetry && !default.bReconnecting && !`XCOMNETMANAGER.HasClientConnection())
	{
		if (Now() > default.JoinRetryUntil)
		{
			default.bJoinRetry = false;
			`log("guest: gave up joining" @ default.GuestHost $ ":" $ default.GuestPort @ "after" @ int(default.JoinRetrySeconds) @ "s",, 'CoopLink');
		}
		else if (int(Now()) % Max(1, int(default.ReconnectInterval)) == 0)
		{
			`log("guest: the host did not answer yet; trying again",, 'CoopLink');
			TryConnect();
		}
	}
	if (default.bMissionRunning && !default.bMissionHistorySent && default.MissionSlots.Length > 0 && Now() > default.WaitUntil)
	{
		`log("host: stopped waiting for guests after" @ int(default.WaitForGuestsSeconds) @ "s",, 'CoopLink');
		if (class'CoopRole'.default.ConnectedSlots.Length > 0)
		{
			HostSendMissionOnce();
		}
		else
		{
			default.bMissionHistorySent = true;    // nobody came back: the host plays on; later joiners get the history
		}
	}
}

// The game's PvP code queues an "Opponent left - connection to the session has been lost" notice whenever a
// multiplayer connection drops, and shows it at the next chance (seen on the guest's screen during its own
// turn, run mission-20261113-085645: queued when the host closed the connection to build the mission). In co-op
// those drops are planned and the guest reconnects by itself, so the notice is dropped from the queue, and
// closed if it is already up. Runs every second once this game has hosted or joined.
static function SweepNotices()
{
	local XComOnlineEventMgr EventMgr;
	local XComPresentationLayerBase Pres;
	local TDialogueBoxData Data;

	EventMgr = `ONLINEEVENTMGR;
	if (EventMgr == none)
	{
		return;
	}
	EventMgr.RemoveAllSystemMessagesOfType(SystemMessage_QuitReasonOpponentDisconnected);
	Pres = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres;
	if (Pres == none || Pres.Get2DMovie() == none || Pres.Get2DMovie().DialogBox == none
		|| !Pres.Get2DMovie().DialogBox.GetTopDialogBoxData(Data))
	{
		return;
	}
	if (UICallbackData_SystemMessage(Data.xUserData) != none
		&& Data.strTitle == EventMgr.GetSystemMessageTitle(SystemMessage_QuitReasonOpponentDisconnected))
	{
		Pres.Get2DMovie().DialogBox.RemoveDialog();
		`log("closed the game's \"opponent left\" notice (co-op reconnects by itself)",, 'CoopLink');
	}
}

static function bool NeedsTimer()
{
	// once this game has hosted or joined: SweepNotices
	return default.LeaveAt > 0 || default.GuestHost != "" || default.HostPort > 0 || default.bJoinSendPending || class'CoopTacticalNet'.default.bRelayPending || class'CoopRole'.default.RollToken > 0 || default.bReconnecting || default.bForcePending || default.bTearDownPending || default.bReopenAfterReturn || default.bCampaignWait || (default.bMissionRunning && !default.bMissionHistorySent && default.MissionSlots.Length > 0);
}

static function string SlotList(array<int> Slots)
{
	local string S;
	local int Slot;

	foreach Slots(Slot)
	{
		S $= (S == "" ? "" : ",") $ Slot;
	}
	return "[" $ S $ "]";
}

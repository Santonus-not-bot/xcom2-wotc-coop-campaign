//---------------------------------------------------------------------------------------
//  FILE:    CoopLobby.uc
//  PURPOSE: The co-op lobby on the main menu (CoopLobbyScreen shows it). The host opens it for a mode (co-op
//           campaign, balanced co-op campaign, scenario), its server opens right away, friends join with "Join a
//           friend" and land in the same lobby. Everyone sees the players (CoopRoster: names, states, by slot);
//           the host decides who is Player 2, 3 and 4, then starts. The guests follow on their own: the host
//           closes the connection for the map travel and reopens it at the first unit actions (or on the Avenger),
//           and each guest reconnects asking for the slot it had in the lobby.
//           Messages:
//             "CoopLobby"(mode)       host -> guests, on open and every few seconds: the guest shows the lobby and
//                                     keeps its no-history watchdog quiet (CoopLink.JoinedAt)
//             "CoopSlotFor"(nonce, slot)  the existing join handshake (CoopJoin), also to move a guest to another
//                                     slot: the guest takes the new slot, its reconnect slot and memory follow
//             "CoopLobbyClosed"       host -> guests: the host left the lobby without starting
//           A plain Object; the state lives in class defaults.
//---------------------------------------------------------------------------------------
class CoopLobby extends Object config(CoopCampaign);

const MODE_NONE = 0;
const MODE_CAMPAIGN = 1;
const MODE_BALANCED = 2;
const MODE_SCENARIO = 3;
const PING_SECONDS = 3;

// runtime (config only so the default may be written)
var config bool bInited;
var config int Mode;                 // the lobby's mode (host: chosen; guest: from the host)
var config bool bHosting;            // host: this machine hosts a lobby
var config bool bGuestInLobby;       // guest: the host we joined is in a lobby
var config int PingAt;               // host: clock seconds of the last "CoopLobby"

static function Init()
{
	local CoopLobby Listener;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	Listener = new class'CoopLobby';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Listener.OnRemoteCommand);
}

static function string ModeName(int M)
{
	switch (M)
	{
	case MODE_CAMPAIGN: return "CO-OP CAMPAIGN";
	case MODE_BALANCED: return "BALANCED CO-OP CAMPAIGN";
	case MODE_SCENARIO: return "SCENARIO MODE";
	}
	return "CO-OP";
}

static function bool InShell()
{
	return XComShell(class'WorldInfo'.static.GetWorldInfo().Game) != none;
}

// ---------------------------------------------------------------- host

static function bool HostLobby(int NewMode)
{
	Init();
	class'CoopRoster'.static.Init();
	default.Mode = NewMode;
	default.bHosting = true;
	default.bGuestInLobby = false;
	if (!`XCOMNETMANAGER.HasServerConnection())
	{
		if (!class'CoopLink'.static.HostOpen(class'CoopLink'.default.DefaultPort))
		{
			`log("lobby: the server did not open",, 'CoopLobby');
			return false;
		}
	}
	class'CoopLinkTimer'.static.Ensure();
	default.PingAt = 0;
	`log("lobby: hosting" @ ModeName(NewMode) @ "on port" @ class'CoopLink'.default.HostPort,, 'CoopLobby');
	return true;
}

static function bool IsHostingLobby()
{
	return default.bHosting && InShell() && !class'CoopRole'.static.IsGuest();
}

// CoopLink.Tick: the host tells its guests it is in a lobby (they show it, and do not wait for a campaign).
static function Tick()
{
	local array<byte> Params;
	local int Now;

	if (!IsHostingLobby() || class'CoopRole'.default.ConnectedSlots.Length == 0)
	{
		return;
	}
	Now = class'CoopMissionLoading'.static.ClockSeconds();
	if (default.PingAt > 0 && Now - default.PingAt < PING_SECONDS && Now >= default.PingAt)
	{
		return;
	}
	default.PingAt = Now;
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.Mode, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopLobby", Params);
}

// Host: the guest in Slot becomes NewSlot; a guest already there takes Slot (a swap). Guest slots only (1..3).
static function bool HostAssign(int Slot, int NewSlot)
{
	local int i, A, B;
	local string NameA, NameB;

	if (!IsHostingLobby() || Slot == NewSlot || Slot < 1 || NewSlot < 1 || NewSlot >= class'XComGameState_CoopCampaign'.const.MAX_PLAYERS
		|| class'CoopRole'.default.ConnectedSlots.Find(Slot) == INDEX_NONE)
	{
		`log("lobby: cannot move player" @ (Slot + 1) @ "to player" @ (NewSlot + 1),, 'CoopLobby');
		return false;
	}
	A = INDEX_NONE;
	B = INDEX_NONE;
	for (i = 0; i < class'CoopJoin'.default.HelloSlots.Length; i++)
	{
		if (class'CoopJoin'.default.HelloSlots[i] == Slot && A == INDEX_NONE)
		{
			A = i;
		}
		else if (class'CoopJoin'.default.HelloSlots[i] == NewSlot && B == INDEX_NONE && class'CoopRole'.default.ConnectedSlots.Find(NewSlot) != INDEX_NONE)
		{
			B = i;
		}
	}
	if (A == INDEX_NONE)
	{
		`log("lobby: no join record for player" @ (Slot + 1),, 'CoopLobby');
		return false;
	}
	class'CoopJoin'.default.HelloSlots[A] = NewSlot;
	if (B != INDEX_NONE)
	{
		class'CoopJoin'.default.HelloSlots[B] = Slot;
	}
	else
	{
		class'CoopRole'.default.ConnectedSlots.RemoveItem(Slot);
		class'CoopRole'.default.ConnectedSlots.AddItem(NewSlot);
	}
	// the names move with the players
	NameA = class'CoopRoster'.default.PlayerNames[Slot];
	NameB = class'CoopRoster'.default.PlayerNames[NewSlot];
	class'CoopRoster'.default.PlayerNames[NewSlot] = NameA;
	class'CoopRoster'.default.PlayerNames[Slot] = (B != INDEX_NONE) ? NameB : "";
	SendSlot(class'CoopJoin'.default.HelloNonces[A], NewSlot);
	if (B != INDEX_NONE)
	{
		SendSlot(class'CoopJoin'.default.HelloNonces[B], Slot);
	}
	`log("lobby: player" @ (Slot + 1) @ "is now player" @ (NewSlot + 1) $ ((B != INDEX_NONE) ? " (swapped)" : "")
		@ "connected=" $ class'CoopLink'.static.SlotList(class'CoopRole'.default.ConnectedSlots),, 'CoopLobby');
	return true;
}

static function SendSlot(int Nonce, int Slot)
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Nonce, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Slot, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopSlotFor", Params);
}

// Host: the next free-or-taken guest slot for the lobby's "Player N" button (cycles 2 -> 3 -> 4 -> 2 among the
// slots that hold a guest, plus the next empty one).
static function int NextSlot(int Slot)
{
	local int Count, Next;

	Count = Max(class'CoopRole'.default.ConnectedSlots.Length, 1);
	Next = Slot + 1;
	if (Next > Min(Count + 1, class'XComGameState_CoopCampaign'.const.MAX_PLAYERS - 1) || Next > class'XComGameState_CoopCampaign'.const.MAX_PLAYERS - 1)
	{
		Next = 1;
	}
	return Next;
}

// Host: the lobby closes without a start: the guests are told, the server closes.
static function HostCloseLobby()
{
	if (!default.bHosting)
	{
		return;
	}
	if (`XCOMNETMANAGER.HasServerConnection())
	{
		class'CoopTacticalNet'.static.Send("CoopLobbyClosed");
		class'CoopRole'.default.ConnectedSlots.Length = 0;
		class'CoopRole'.default.ConnectionSlots.Length = 0;
		`XCOMNETMANAGER.Disconnect();
		`XCOMNETMANAGER.ResetConnectionData();
	}
	default.bHosting = false;
	default.Mode = MODE_NONE;
	`log("lobby: closed by the host",, 'CoopLobby');
}

// Host: start the lobby's game. Arg: "new" / "load" (campaigns), "early" / "mid" / "late" (scenario).
static function bool HostStart(string Arg)
{
	local XComShellPresentationLayer Pres;

	if (!IsHostingLobby())
	{
		return false;
	}
	Pres = XComShellPresentationLayer(XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres);
	`log("lobby: start" @ Arg @ "mode=" $ ModeName(default.Mode) @ "players=" $ PlayerCount()
		@ "guests=" $ class'CoopLink'.static.SlotList(class'CoopRole'.default.ConnectedSlots),, 'CoopLobby');
	if (default.Mode == MODE_SCENARIO)
	{
		switch (Arg)
		{
		case "mid": return class'CoopScenario'.static.Start(class'CoopScenario'.const.STAGE_MID, PlayerCount());
		case "late": return class'CoopScenario'.static.Start(class'CoopScenario'.const.STAGE_LATE, PlayerCount());
		default: return class'CoopScenario'.static.Start(class'CoopScenario'.const.STAGE_EARLY, PlayerCount());
		}
	}
	if (Arg == "load")
	{
		// a co-op save opens the server by itself (CoopLink.HostLoadedGame); the guests reconnect to it
		`XCOMHISTORY.ResetHistory();
		Pres.UILoadScreen();
		return true;
	}
	class'CoopNewCampaign'.static.Choose(default.Mode == MODE_BALANCED);
	if (Pres != none)
	{
		Pres.UIDifficulty();
	}
	return true;
}

// The players of the game the host starts: the host plus the highest guest slot in the lobby.
static function int PlayerCount()
{
	local int Slot, Highest;

	foreach class'CoopRole'.default.ConnectedSlots(Slot)
	{
		Highest = Max(Highest, Slot);
	}
	return Highest + 1;
}

// Host, the game starts and the map travel follows: tell the guests (their loading screen) and close the connection;
// it reopens at the first unit actions (CoopTacticalRuleset -> CoopLink.HostMissionReady), the guests reconnect.
static function HostLeaveForGame(string What)
{
	local array<byte> Params;
	local int Slot;

	class'CoopLink'.default.bMissionRunning = false;
	class'CoopLink'.default.bMissionHistorySent = false;
	class'CoopLink'.default.MissionSlots.Length = 0;
	foreach class'CoopRole'.default.ConnectedSlots(Slot)
	{
		class'CoopLink'.default.MissionSlots.AddItem(Slot);
	}
	if (class'CoopLink'.default.HostPort <= 0)
	{
		class'CoopLink'.default.HostPort = class'CoopLink'.default.DefaultPort;
	}
	class'CoopLink'.default.bReopenPending = true;
	if (`XCOMNETMANAGER.HasServerConnection())
	{
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(What, Params);
		`XCOMNETMANAGER.SendRemoteCommand("CoopMissionBuilding", Params);
		class'CoopRole'.default.ConnectedSlots.Length = 0;
		class'CoopRole'.default.ConnectionSlots.Length = 0;
		`XCOMNETMANAGER.Disconnect();
		`XCOMNETMANAGER.ResetConnectionData();
	}
	default.bHosting = false;
	`log("lobby: leaving for" @ What $ "; guests" @ class'CoopLink'.static.SlotList(class'CoopLink'.default.MissionSlots)
		@ "rejoin at the first unit actions",, 'CoopLobby');
}

// ---------------------------------------------------------------- guest

static function GuestLeave()
{
	`log("lobby: left",, 'CoopLobby');
	default.bGuestInLobby = false;
	default.Mode = MODE_NONE;
	class'CoopLink'.default.bReconnecting = false;
	class'CoopLink'.default.bJoinRetry = false;
	class'CoopLink'.default.GuestHost = "";
	class'CoopRole'.default.AssignedSlot = 0;
	`XCOMNETMANAGER.Disconnect();
	`XCOMNETMANAGER.ResetConnectionData();
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local UIScreenStack Stack;
	local int M;

	if (Command == "CoopLobby")
	{
		M = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		if (!class'CoopRole'.static.IsGuest())
		{
			return;
		}
		if (!default.bGuestInLobby || default.Mode != M)
		{
			`log("lobby: the host is in the" @ ModeName(M) @ "lobby",, 'CoopLobby');
		}
		default.bGuestInLobby = true;
		default.Mode = M;
		class'CoopLink'.default.JoinedAt = class'CoopLink'.static.Now();    // no campaign expected: keep the watchdog quiet
		Stack = `SCREENSTACK;
		if (InShell() && Stack != none && !Stack.IsInStack(class'CoopLobbyScreen'))
		{
			Stack.Push(`PRESBASE.Spawn(class'CoopLobbyScreen', `PRESBASE));
		}
	}
	else if (Command == "CoopLobbyClosed" && class'CoopRole'.static.IsGuest())
	{
		`log("lobby: the host closed the lobby",, 'CoopLobby');
		class'CoopRoster'.static.Toast("The host closed the lobby");
		GuestLeave();
	}
}

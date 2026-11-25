//---------------------------------------------------------------------------------------
//  FILE:    CoopRoster.uc
//  PURPOSE: Who is in the co-op game, by name, and in what state, for the player panel (CoopHUDScreen) and the
//           join / leave / reconnect toasts.
//           Names: every machine sends "CoopName"(slot, name) once it has a slot and every 10 s; the name is the
//           player's own (PlayerReplicationInfo.PlayerName: the Steam name when Steam runs).
//           States: the host works them out every second (CoopLink.Tick): connected (in CoopRole.ConnectedSlots),
//           reconnecting (not connected, but expected back: the connection is closed while a mission is built or
//           on the way back to the Avenger), left (known, not connected, not expected). It sends the roster
//           ("CoopRoster") when it changes and every 10 s. Every machine compares each roster with the last one
//           and shows a toast for what changed.
//           A plain Object; the state lives in class defaults (they survive map changes).
//---------------------------------------------------------------------------------------
class CoopRoster extends Object config(CoopCampaign);

const MAX_PLAYERS = 4;
const RESEND_SECONDS = 10;

// PS_, not STATE_: inside this class the bare names STATE_CONNECTED... meant another value (connected rows were
// stored as 4 while CoopHUDScreen compared with class'CoopRoster'.const.STATE_CONNECTED, 1: avengerfeed 2026-11-18)
const PS_NONE = 0;
const PS_CONNECTED = 1;
const PS_RECONNECTING = 2;
const PS_LEFT = 3;
const PS_LOADING = 4;      // connected, loading a map (a mission, the Avenger): "CoopLoading" .. "CoopLoaded"

var config bool bInited;
var config array<string> PlayerNames;      // by slot
var config array<int> PlayerStates;        // by slot (host: worked out; guest: from the host's roster)
var config int SentAt;               // clock seconds of the last roster or name send
var config string LastSent;          // the roster as last sent (host)
var config array<string> Toasts;     // waiting to be shown (CoopHUDScreen takes them)
var config array<int> JoinSeenAt;
var config array<int> LoadingFlags;  // host, by slot: 1 while that guest loads a map
var config int HoldSince;            // host: clock seconds since merges are held for a loading guest (0 = not holding)    // host, by slot: when a new player first showed as connected (its toast waits for the name)

static function Init()
{
	local CoopRoster Listener;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	default.PlayerNames.Length = MAX_PLAYERS;
	default.PlayerStates.Length = MAX_PLAYERS;
	Listener = new class'CoopRoster';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Listener.OnRemoteCommand);
}

// This machine joined a host (and is a guest even while it reconnects). CoopRole.IsGuest() is false while the
// connection is down, which turned a reconnecting guest into "the host" on its own panel (loadshow 2026-11-18).
static function bool GuestSide()
{
	return class'CoopLink'.default.GuestHost != "";
}

// Our own slot, also while a guest reconnects (CoopLink.WantSlot keeps it).
static function int MySlot()
{
	if (GuestSide())
	{
		if (class'CoopRole'.default.AssignedSlot > 0)
		{
			return class'CoopRole'.default.AssignedSlot;
		}
		if (class'CoopLink'.default.WantSlot > 0)
		{
			return class'CoopLink'.default.WantSlot;
		}
	}
	return class'CoopRole'.static.LocalSlot();
}

static function string LocalName()
{
	local PlayerController PC;

	PC = class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController();
	if (PC != none && PC.PlayerReplicationInfo != none && PC.PlayerReplicationInfo.PlayerName != "")
	{
		return PC.PlayerReplicationInfo.PlayerName;
	}
	return "";
}

// "Host" / "Player 2" (the turn banner's words).
static function string SlotLabel(int Slot)
{
	if (Slot == class'XComGameState_CoopCampaign'.const.SLOT_HOST)
	{
		return "Host";
	}
	return "Player" @ (Slot + 1);
}

// The player's name, or the slot label when the name is not known yet.
static function string DisplayName(int Slot)
{
	if (Slot >= 0 && Slot < default.PlayerNames.Length && default.PlayerNames[Slot] != "")
	{
		return default.PlayerNames[Slot];
	}
	return SlotLabel(Slot);
}

static function string StateText(int PState)
{
	switch (PState)
	{
	case PS_CONNECTED:    return "connected";
	case PS_RECONNECTING: return "reconnecting";
	case PS_LEFT:         return "left";
	case PS_LOADING:      return "loading";
	}
	return "";
}

static function int StateOf(int Slot)
{
	if (Slot >= 0 && Slot < default.PlayerStates.Length)
	{
		return default.PlayerStates[Slot];
	}
	return PS_NONE;
}

static function Toast(string Text)
{
	default.Toasts.AddItem(Text);
	`log("toast:" @ Text,, 'CoopRoster');
}

// CoopLink.Tick, every second, on every machine once a session is on.
static function Tick()
{
	local int Slot, Now;
	local array<int> NewStates;

	// a guest sends its name as soon as it has a slot, also on the main menu before the campaign arrives (it is not
	// "co-op active" there): the host's join toast waits for it (avengerfeed 2026-11-19: "Player 2 joined as Player 2")
	if (!class'CoopRole'.static.CoopActive() && !(GuestSide() && class'CoopRole'.default.AssignedSlot > 0)
		&& !class'CoopLobby'.static.IsHostingLobby())    // the lobby on the main menu shows the roster too
	{
		return;
	}
	Init();
	Now = class'CoopMissionLoading'.static.ClockSeconds();
	SetName(MySlot(), LocalName(), false);
	if (GuestSide())
	{
		if (class'CoopSession'.static.IsConnected() && class'CoopRole'.default.AssignedSlot > 0
			&& (Now - default.SentAt >= RESEND_SECONDS || Now < default.SentAt))
		{
			default.SentAt = Now;
			SendName(class'CoopRole'.default.AssignedSlot, LocalName());
		}
		return;
	}
	// host
	NewStates.Length = MAX_PLAYERS;
	NewStates[0] = PS_CONNECTED;
	for (Slot = 1; Slot < MAX_PLAYERS; Slot++)
	{
		if (class'CoopRole'.default.ConnectedSlots.Find(Slot) != INDEX_NONE)
		{
			NewStates[Slot] = PS_CONNECTED;
			if (Slot < default.LoadingFlags.Length && default.LoadingFlags[Slot] != 0)
			{
				NewStates[Slot] = PS_LOADING;
			}
		}
		else if (ExpectedBack(Slot))
		{
			NewStates[Slot] = PS_RECONNECTING;
		}
		else if (default.PlayerNames[Slot] != "" || StateOf(Slot) != PS_NONE)
		{
			NewStates[Slot] = PS_LEFT;
		}
	}
	Apply(NewStates);
	if (class'CoopSession'.static.IsConnected() && (Encode() != default.LastSent || Now - default.SentAt >= RESEND_SECONDS || Now < default.SentAt))
	{
		default.SentAt = Now;
		default.LastSent = Encode();
		SendRoster();
	}
}

// Host: a guest that was connected when the connection closed for a mission build or the way back to the
// Avenger, while the host still waits for it.
static function bool ExpectedBack(int Slot)
{
	if (class'CoopLink'.default.MissionSlots.Find(Slot) == INDEX_NONE)
	{
		return false;
	}
	return class'CoopLink'.default.bReopenPending || class'CoopLink'.default.bReturnPending || class'CoopLink'.default.bReopenAfterReturn
		|| class'CoopLink'.default.bCampaignWait
		|| (class'CoopLink'.default.bMissionRunning && !class'CoopLink'.default.bMissionHistorySent);
}

// New states for every slot: toasts for the changes, then keep them.
static function Apply(array<int> NewStates)
{
	local int Slot, OldState, NewState, Now;

	Now = class'CoopMissionLoading'.static.ClockSeconds();
	if (default.JoinSeenAt.Length < MAX_PLAYERS)
	{
		default.JoinSeenAt.Length = MAX_PLAYERS;
	}
	for (Slot = 0; Slot < MAX_PLAYERS; Slot++)
	{
		OldState = StateOf(Slot);
		NewState = NewStates[Slot];
		if (OldState == NewState || Slot == MySlot())
		{
			continue;
		}
		// a new player: wait up to 5 s for its name, so the toast can say who it is
		if (NewState == PS_CONNECTED && OldState == PS_NONE && default.PlayerNames[Slot] == "")
		{
			if (default.JoinSeenAt[Slot] == 0)
			{
				default.JoinSeenAt[Slot] = Now;
			}
			if (Now - default.JoinSeenAt[Slot] < 10 && Now >= default.JoinSeenAt[Slot])
			{
				continue;
			}
		}
		default.JoinSeenAt[Slot] = 0;
		if (NewState == PS_LOADING || (NewState == PS_CONNECTED && OldState == PS_LOADING))
		{
			default.PlayerStates[Slot] = NewState;    // no toast for loading a map
			continue;
		}
		if (NewState == PS_CONNECTED)
		{
			if (OldState == PS_RECONNECTING || OldState == PS_LEFT)
			{
				Toast(DisplayName(Slot) @ "is back");
			}
			else if (Slot == class'XComGameState_CoopCampaign'.const.SLOT_HOST)
			{
				Toast("Connected to" @ DisplayName(Slot) $ "'s game");
			}
			else if (default.PlayerNames[Slot] == "")
			{
				Toast("A player joined as" @ SlotLabel(Slot));
			}
			else
			{
				Toast(DisplayName(Slot) @ "joined as" @ SlotLabel(Slot));
			}
		}
		else if (NewState == PS_RECONNECTING)
		{
			Toast(DisplayName(Slot) @ "is reconnecting...");
		}
		else if (NewState == PS_LEFT && OldState != PS_NONE)
		{
			Toast(DisplayName(Slot) @ "left the game");
		}
		default.PlayerStates[Slot] = NewState;
	}
	default.PlayerStates[MySlot()] = PS_CONNECTED;
}

static function SetName(int Slot, string PlayerText, bool bLog)
{
	if (Slot < 0 || Slot >= MAX_PLAYERS || PlayerText == "" || default.PlayerNames[Slot] == PlayerText)
	{
		return;
	}
	default.PlayerNames[Slot] = PlayerText;
	if (bLog)
	{
		`log("name of player" @ Slot $ ":" @ PlayerText,, 'CoopRoster');
	}
}

static function SendName(int Slot, string PlayerText)
{
	local array<byte> Params;

	if (PlayerText == "")
	{
		return;
	}
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Slot, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(PlayerText, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopName", Params);
}

// "state:name" per slot, joined with '|' (names cannot hold '|': it is replaced).
static function string Encode()
{
	local string S;
	local int Slot;

	for (Slot = 0; Slot < MAX_PLAYERS; Slot++)
	{
		S $= (Slot == 0 ? "" : "|") $ StateOf(Slot) $ ":" $ Repl(default.PlayerNames[Slot], "|", "/");
	}
	return S;
}

static function SendRoster()
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_String(Encode(), Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopRoster", Params);
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local array<string> Entries;
	local array<int> NewStates;
	local int Slot, Colon;
	local string PlayerText;

	if (Command == "CoopLoading" || Command == "CoopLoaded")
	{
		Slot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		if (!GuestSide() && Slot > 0 && Slot < MAX_PLAYERS)
		{
			if (default.LoadingFlags.Length < MAX_PLAYERS)
			{
				default.LoadingFlags.Length = MAX_PLAYERS;
			}
			default.LoadingFlags[Slot] = 0;
			if (Command == "CoopLoading")
			{
				default.LoadingFlags[Slot] = 1;    // not a ternary into an array element (they went wrong in this mod)
			}
			`log("player" @ Slot @ (Command == "CoopLoading" ? "is loading a map" : "finished loading"),, 'CoopRoster');
		}
		return;
	}
	if (Command == "CoopName")
	{
		Slot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		PlayerText = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
		SetName(Slot, PlayerText, true);
		return;
	}
	if (Command != "CoopRoster" || !GuestSide())
	{
		return;
	}
	ParseStringIntoArray(class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams), Entries, "|", false);
	NewStates.Length = MAX_PLAYERS;
	for (Slot = 0; Slot < MAX_PLAYERS && Slot < Entries.Length; Slot++)
	{
		Colon = InStr(Entries[Slot], ":");
		if (Colon < 0)
		{
			continue;
		}
		NewStates[Slot] = int(Left(Entries[Slot], Colon));
		SetName(Slot, Mid(Entries[Slot], Colon + 1), true);
	}
	Apply(NewStates);
}

// Host: a guest is about to load the Avenger with the campaign just sent (CoopTacticalNet, "CoopEnterAvenger").
static function MarkLoading(int Slot)
{
	if (Slot <= 0 || Slot >= MAX_PLAYERS)
	{
		return;
	}
	if (default.LoadingFlags.Length < MAX_PLAYERS)
	{
		default.LoadingFlags.Length = MAX_PLAYERS;
	}
	default.LoadingFlags[Slot] = 1;
}

// Host: hold merge batches while a guest loads the map after a campaign send (CoopSession.FlushBatch), or while the
// campaign itself waits for its ack; at most 60 s.
static function bool HoldMerges()
{
	local int Slot, Now;
	local bool bLoading;

	if (GuestSide() || class'CoopSession'.static.InTactical())
	{
		default.HoldSince = 0;
		return false;
	}
	bLoading = class'CoopTacticalNet'.default.CampaignAckSlots.Length > 0;
	for (Slot = 1; Slot < default.LoadingFlags.Length; Slot++)
	{
		if (default.LoadingFlags[Slot] != 0 && class'CoopRole'.default.ConnectedSlots.Find(Slot) != INDEX_NONE)
		{
			bLoading = true;
		}
	}
	if (!bLoading)
	{
		if (default.HoldSince != 0)
		{
			`log("merges: guests are on the Avenger, sending again",, 'CoopRoster');
		}
		default.HoldSince = 0;
		return false;
	}
	Now = class'CoopMissionLoading'.static.ClockSeconds();
	if (default.HoldSince == 0)
	{
		default.HoldSince = Now;
		`log("merges: held while a guest loads the Avenger",, 'CoopRoster');
	}
	if (Now - default.HoldSince > 60 || Now < default.HoldSince)
	{
		`log("merges: held 60 s, sending anyway",, 'CoopRoster');
		default.HoldSince = 0;
		for (Slot = 1; Slot < default.LoadingFlags.Length; Slot++)
		{
			default.LoadingFlags[Slot] = 0;
		}
		return false;
	}
	return true;
}

// Guest: about to load a map (bLoading) or done loading one, for the host's panel ("loading").
static function GuestLoading(bool bLoading)
{
	local array<byte> Params;

	if (!GuestSide() || !class'CoopSession'.static.IsConnected())
	{
		return;
	}
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(MySlot(), Params);
	`XCOMNETMANAGER.SendRemoteCommand(bLoading ? "CoopLoading" : "CoopLoaded", Params);
	`log("told the host:" @ (bLoading ? "loading a map" : "map loaded"),, 'CoopRoster');
}

// The guest itself lost or found the host (CoopLink), for its own toasts.
static function GuestLink(bool bUp)
{
	Toast(bUp ? "Connected to the host" : "Lost the host - reconnecting...");
}

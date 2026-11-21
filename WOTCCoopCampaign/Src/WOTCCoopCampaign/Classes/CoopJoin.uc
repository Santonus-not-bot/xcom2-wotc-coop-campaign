//---------------------------------------------------------------------------------------
//  FILE:    CoopJoin.uc
//  PURPOSE: Join flow.
//           Always: the host greets a new connection with "CoopWelcome"; a guest without a slot
//             answers "CoopHello"(nonce, wanted slot); the host picks the wanted slot if free, else
//             the lowest free one (1-3), and answers "CoopSlotFor"(nonce, slot). Remote commands
//             reach every connection, so only the guest with that nonce takes it.
//           With bGateJoinOnMods (XComCoopCampaign.ini), the mod check comes first:
//             host: partner joined -> send our mod list (CoopModCheck)
//             guest: compare -> "CoopModsResult"(match, diff)
//             host: match -> SendHistory (what the MPSendHistory console command does);
//                   no match -> "CoopJoinRefused"(diff), the history is NOT sent: a history
//                   holding objects of a mod class the guest lacks may not load at all.
//           A plain Object (delegates on the network manager must not point at Actors).
//---------------------------------------------------------------------------------------
class CoopJoin extends Object config(CoopCampaign);

var config bool bGateJoinOnMods;
var config bool bInited;            // config only so the default may be written
var config bool bHistorySent;       // set when this host sent the history after a matching check
var config bool bRefused;           // set on both sides when a join was refused
var config int PendingConnectionIdx;    // host: last accepted connection (kept for logs)
var config int JoinNonce;                 // guest: this process's join nonce (0 = not made yet)
var config array<int> HelloNonces;      // host: guests by nonce ...
var config array<int> HelloSlots;       // ... and the slot each got
var config array<int> HelloClosed;      // ... and ClosedCount at that hello
var config int ClosedCount;             // host: connections closed so far

static function Init()
{
	local CoopJoin Join;
	local XComGameStateNetworkManager NetMgr;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	default.PendingConnectionIdx = -1;
	class'CoopModCheck'.static.Init();
	class'CoopTacticalNet'.static.Init();    // guests must hear "CoopLoadMission" while still on the Avenger
	class'CoopPing'.static.Init();
	class'CoopChat'.static.Init();
	class'CoopTurnBanner'.static.Init();
	class'CoopSteamJoin'.static.Init();    // only when bSteamInvites
	Join = new class'CoopJoin';
	NetMgr = `XCOMNETMANAGER;
	NetMgr.AddNotifyAcceptedConnectionDelegate(Join.OnAcceptedConnection);
	NetMgr.AddPlayerJoinedDelegate(Join.OnPlayerJoined);
	NetMgr.AddNotifyConnectionClosedDelegate(Join.OnConnectionClosed);
	NetMgr.AddReceiveRemoteCommandDelegate(Join.OnRemoteCommand);
}

function OnAcceptedConnection(int ConnectionIdx)
{
	default.PendingConnectionIdx = ConnectionIdx;
}

function OnPlayerJoined(string RequestURL, string Address, const UniqueNetId UniqueId, bool bSupportsAuth)
{
	local array<byte> Params;

	if (class'CoopRole'.static.IsGuest())
	{
		return;
	}
	// Remote commands reach every connection and the host cannot tell which connection sent one, so the
	// slot is agreed by a nonce: the new guest answers "CoopWelcome" with "CoopHello"(nonce, wanted slot)
	// and takes only a "CoopSlotFor" naming its own nonce. (A broadcast "CoopAssignSlot"(slot) gave two
	// guests reconnecting at the same moment the same slot, run mission3-20261112-182510.)
	`XCOMNETMANAGER.SendRemoteCommand("CoopWelcome", Params);
	`log("partner joined: waiting for its hello",, 'CoopJoin');

	if (default.bGateJoinOnMods)
	{
		default.bHistorySent = false;
		default.bRefused = false;
		`log("checking mods before sending the campaign",, 'CoopJoin');
		class'CoopModCheck'.static.SendList();
	}
}

// Host: "CoopHello"(nonce, wanted slot).
static function HostOnHello(array<byte> RawParams)
{
	local array<byte> Params;
	local int Nonce, Want, Slot, Idx;
	local XComGameState_CoopCampaign Coop;

	Nonce = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Want = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	if (class'CoopRole'.static.IsGuest())
	{
		return;
	}
	// a slot remembered from another campaign may not exist in this one
	Coop = class'XComGameState_CoopCampaign'.static.Get();
	if (Coop != none && Want >= Coop.PlayerCount)
	{
		Want = 0;
	}
	Idx = default.HelloNonces.Find(Nonce);
	if (Idx != INDEX_NONE && class'CoopRole'.default.ConnectedSlots.Find(default.HelloSlots[Idx]) != INDEX_NONE
		&& default.HelloClosed[Idx] == default.ClosedCount)
	{
		Slot = default.HelloSlots[Idx];    // the same guest said hello twice (two welcomes): same answer
	}
	else
	{
		if (Idx != INDEX_NONE && class'CoopRole'.default.ConnectedSlots.Find(default.HelloSlots[Idx]) != INDEX_NONE)
		{
			// The same game process again after a connection closed: it lost its connection and reconnected
			// before the roll call for the old one ended (soak-20261114: the host's 98 s movie after the first
			// mission sent nothing, the guest timed out and came back). Same slot; it counts as present.
			Slot = default.HelloSlots[Idx];
			`log("partner reconnected: player slot" @ Slot,, 'CoopJoin');
		}
		else
		{
			Slot = (Want > 0 && Want < class'XComGameState_CoopCampaign'.const.MAX_PLAYERS && class'CoopRole'.default.ConnectedSlots.Find(Want) == INDEX_NONE)
				? Want : class'CoopRole'.static.FreeGuestSlot();
		}
		if (Slot < 0)
		{
			`log("partner said hello but all guest slots are taken",, 'CoopJoin');
			return;
		}
		if (Idx == INDEX_NONE)
		{
			default.HelloNonces.AddItem(Nonce);
			default.HelloSlots.AddItem(Slot);
			default.HelloClosed.AddItem(default.ClosedCount);
		}
		else
		{
			default.HelloSlots[Idx] = Slot;
			default.HelloClosed[Idx] = default.ClosedCount;
		}
		class'CoopRole'.static.SlotConnected(Slot, -1);
		class'CoopRole'.static.MarkPresent(Slot);
		`log("partner joined: player slot" @ Slot @ "(wanted" @ Want $ ")",, 'CoopJoin');
		class'CoopLink'.static.HostGuestJoined(Slot);
	}
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Nonce, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Slot, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopSlotFor", Params);
}

// Guest: a nonce for this game process, so the host can address our slot.
static function int MyNonce()
{
	local int Y, Mo, Dw, D, H, Mi, S, Ms;

	if (default.JoinNonce == 0)
	{
		class'WorldInfo'.static.GetWorldInfo().GetSystemTime(Y, Mo, Dw, D, H, Mi, S, Ms);
		default.JoinNonce = 1 + Rand(20000) * 100000 + ((Mi * 60 + S) * 1000 + Ms) % 100000;
	}
	return default.JoinNonce;
}

function OnConnectionClosed(int ConnectionIdx)
{
	local int OldSlot;

	if (class'CoopRole'.static.IsGuest() || class'CoopRole'.default.AssignedSlot > 0)
	{
		// the guest lost the host: it reconnects asking for the same slot (CoopLink)
		OldSlot = class'CoopRole'.default.AssignedSlot;
		class'CoopRole'.default.AssignedSlot = 0;
		class'CoopLink'.static.GuestLostHost(OldSlot);
		return;
	}
	default.ClosedCount++;
	class'CoopRole'.static.ConnectionClosed(ConnectionIdx);
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local array<byte> Params;
	local string Diff;
	local int Slot, Nonce;

	if (Command == "CoopWelcome")
	{
		if (class'CoopRole'.static.IsGuest() && class'CoopRole'.default.AssignedSlot == 0)
		{
			class'XComGameStateNetworkManager'.static.AddCommandParam_Int(MyNonce(), Params);
			class'XComGameStateNetworkManager'.static.AddCommandParam_Int(class'CoopLink'.default.WantSlot, Params);
			`XCOMNETMANAGER.SendRemoteCommand("CoopHello", Params);
		}
		return;
	}
	if (Command == "CoopHello")
	{
		HostOnHello(RawParams);
		return;
	}
	if (Command == "CoopSlotFor")
	{
		Nonce = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		Slot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		if (class'CoopRole'.static.IsGuest() && Nonce == MyNonce() && Slot > 0 && class'CoopRole'.default.AssignedSlot != Slot)
		{
			class'CoopRole'.default.AssignedSlot = Slot;
			`log("the host gave us player slot" @ Slot,, 'CoopJoin');
			class'CoopLink'.static.GuestJoined(Slot);
		}
		return;
	}
	if (Command == "CoopRollCall")
	{
		class'CoopRole'.static.OnRollCall(RawParams);
		return;
	}
	if (Command == "CoopHere")
	{
		class'CoopRole'.static.OnHere(RawParams);
		return;
	}
	if (!default.bGateJoinOnMods)
	{
		return;
	}
	if (Command == "CoopJoinRefused" && class'CoopRole'.static.IsGuest())
	{
		default.bRefused = true;
		class'CoopLink'.default.bJoinRetry = false;    // a refusal is an answer: stop knocking
		Diff = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
		`log("the host refused the join: mods differ:" @ Diff,, 'CoopJoin');
		ShowRefusal(Diff);
	}
}

// Host: the partner's answer to our mod list (parsed by CoopModCheck, the only reader of "CoopModsResult").
static function OnModsResult(bool bMatch, string Diff)
{
	local array<byte> Params;

	if (!default.bGateJoinOnMods || class'CoopRole'.static.IsGuest())
	{
		return;
	}
	if (bMatch && class'CoopSession'.static.InTactical())
	{
		// a guest rejoining a mission (after the mission build, or after a drop): CoopLink already sends it the
		// mission. Sending the campaign here replaced the pending mission ack, so the guest's ack matched nothing
		// and it never got "CoopLoadMission" (two-PC play test 2026-11-19: stuck on "receiving the mission").
		`log("mods match: in a mission, the mission history goes out (not the campaign)",, 'CoopJoin');
		return;
	}
	if (bMatch)
	{
		`log("mods match: sending the campaign history",, 'CoopJoin');
		class'CoopTacticalNet'.static.HostSendCampaign();    // the guest then enters the Avenger ("CoopEnterAvenger")
		default.bHistorySent = true;
	}
	else
	{
		default.bRefused = true;
		`log("join refused, partner's mods differ (from the partner's side: - = they lack it, + = only they have it):" @ Diff,, 'CoopJoin');
		class'CoopSyncData'.static.SendHostList();    // the guest saves it for CoopSync, before the refusal arrives
		class'XComGameStateNetworkManager'.static.AddCommandParam_String(Diff, Params);
		`XCOMNETMANAGER.SendRemoteCommand("CoopJoinRefused", Params);
	}
}

static function ShowRefusal(string Diff)
{
	local TDialogueBoxData Dialog;
	local XComPresentationLayerBase Pres;

	Pres = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres;
	if (Pres == none)
	{
		return;
	}
	Dialog.eType = eDialog_Warning;
	Dialog.strTitle = "Co-op: mods do not match";
	Dialog.strText = "Install and enable the same mods as the host, then restart the game and join again. "
		$ "CoopSync can do it for you: close the game and run it; it has the host's list now.\n\n"
		$ "Missing here (-) / only here (+):\n" $ Repl(Diff, " ", "\n");
	Dialog.strAccept = class'UIUtilities_Text'.default.m_strGenericOK;
	Pres.UIRaiseDialog(Dialog);
}

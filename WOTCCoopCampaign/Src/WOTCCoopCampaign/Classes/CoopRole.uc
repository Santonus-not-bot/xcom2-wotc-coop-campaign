//---------------------------------------------------------------------------------------
//  FILE:    CoopRole.uc
//  PURPOSE: Which player slot this machine plays, and which guests are connected.
//           The host (no client connection) is slot 0. A guest learns its slot from the
//           host ("CoopSlotFor", CoopJoin's hello handshake); until then it counts as slot 1.
//           LocalSlotOverride (XComCoopCampaign.ini, or @asslot) forces a slot for tests.
//           Host side: ConnectedSlots lists the guests currently connected; the soldiers of a
//           guest who is not connected are controlled by the host (ControllerOf).
//---------------------------------------------------------------------------------------
class CoopRole extends Object config(CoopCampaign);

var config int LocalSlotOverride;   // -1 = from the connection
var config int AssignedSlot;        // guest: slot the host gave us (0 = none yet); config only so the default may be written
var config array<int> ConnectedSlots;    // host: guest slots connected now
var config array<int> ConnectionSlots;   // host: guest slot per network connection index (-1 = none; unused since the roll call)
var config float RollCallSeconds;        // host: how long guests have to answer a roll call
var config int RollToken;                // host: the roll call running (0 = none)
var config array<int> RollReplies;
var config float RollUntil;

static function int LocalSlot()
{
	if (default.LocalSlotOverride >= 0)
	{
		return default.LocalSlotOverride;
	}
	if (!IsGuest())
	{
		return class'XComGameState_CoopCampaign'.const.SLOT_HOST;
	}
	return (default.AssignedSlot > 0) ? default.AssignedSlot : class'XComGameState_CoopCampaign'.const.SLOT_GUEST;
}

static function bool IsGuest()
{
	return `XCOMNETMANAGER.HasClientConnection();
}

static function bool IsHost()
{
	return LocalSlot() == class'XComGameState_CoopCampaign'.const.SLOT_HOST;
}

// Co-op rules apply once the campaign has a co-op object (created when co-op is set up).
static function bool CoopActive()
{
	return class'XComGameState_CoopCampaign'.static.Get() != none;
}

// Host: the lowest guest slot not connected now (1..3), or -1 when all are taken.
static function int FreeGuestSlot()
{
	local int Slot;

	for (Slot = 1; Slot < class'XComGameState_CoopCampaign'.const.MAX_PLAYERS; Slot++)
	{
		if (default.ConnectedSlots.Find(Slot) == INDEX_NONE)
		{
			return Slot;
		}
	}
	return -1;
}

static function SlotConnected(int Slot, int ConnectionIdx)
{
	if (default.ConnectedSlots.Find(Slot) == INDEX_NONE)
	{
		default.ConnectedSlots.AddItem(Slot);
	}
	if (ConnectionIdx >= 0)
	{
		while (default.ConnectionSlots.Length <= ConnectionIdx)
		{
			default.ConnectionSlots.AddItem(-1);
		}
		default.ConnectionSlots[ConnectionIdx] = Slot;
	}
}

// Host: a connection closed. The host cannot tell which guest it was (commands carry no connection), so
// it asks the others: "CoopRollCall"(token); each guest answers "CoopHere"(token, slot); a slot that did not
// answer within RollCallSeconds is gone (CoopLink.Tick -> RollCallDone).
static function ConnectionClosed(int ConnectionIdx)
{
	local array<byte> Params;

	if (default.ConnectedSlots.Length == 0)
	{
		return;
	}
	default.RollToken = 1 + Rand(1000000);
	default.RollReplies.Length = 0;
	default.RollUntil = class'CoopLink'.static.Now() + default.RollCallSeconds;
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.RollToken, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopRollCall", Params);
	`log("a connection closed: roll call" @ default.RollToken,, 'CoopRole');
	class'CoopLinkTimer'.static.Ensure();
}

static function OnRollCall(array<byte> RawParams)
{
	local array<byte> Params;
	local int Token;

	Token = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	if (IsGuest() && default.AssignedSlot > 0)
	{
		class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Token, Params);
		class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.AssignedSlot, Params);
		`XCOMNETMANAGER.SendRemoteCommand("CoopHere", Params);
	}
}

static function OnHere(array<byte> RawParams)
{
	local int Token, Slot;

	Token = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Slot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	if (!IsGuest() && Token == default.RollToken && default.RollReplies.Find(Slot) == INDEX_NONE)
	{
		default.RollReplies.AddItem(Slot);
	}
}

// Host: a guest that said hello during a running roll call is there (it may have reconnected after the roll
// call went out, and then never heard it).
static function MarkPresent(int Slot)
{
	if (default.RollToken != 0 && default.RollReplies.Find(Slot) == INDEX_NONE)
	{
		default.RollReplies.AddItem(Slot);
	}
}

// CoopLink.Tick, host: the roll call's time is up.
static function RollCallDone()
{
	local array<int> Gone;
	local int Slot;

	default.RollToken = 0;
	foreach default.ConnectedSlots(Slot)
	{
		if (default.RollReplies.Find(Slot) == INDEX_NONE)
		{
			Gone.AddItem(Slot);
		}
	}
	foreach Gone(Slot)
	{
		default.ConnectedSlots.RemoveItem(Slot);
		`log("guest slot" @ Slot @ "disconnected; the host controls its soldiers",, 'CoopRole');
		class'CoopTacticalNet'.static.OnGuestGone(Slot);
		if (class'CoopSession'.static.InTactical() && CoopTacticalRuleset(`TACTICALRULES) != none)
		{
			CoopTacticalRuleset(`TACTICALRULES).OnGuestDisconnected(Slot);
		}
	}
}

// (before the roll call, kept for reference: mapping by connection index)
static function ConnectionClosedByIndex(int ConnectionIdx)
{
	local int Slot;

	if (ConnectionIdx >= 0 && ConnectionIdx < default.ConnectionSlots.Length && default.ConnectionSlots[ConnectionIdx] > 0)
	{
		Slot = default.ConnectionSlots[ConnectionIdx];
		default.ConnectionSlots[ConnectionIdx] = -1;
		default.ConnectedSlots.RemoveItem(Slot);
		`log("guest slot" @ Slot @ "disconnected; the host controls its soldiers",, 'CoopRole');
		class'CoopTacticalNet'.static.OnGuestGone(Slot);
		if (class'CoopSession'.static.InTactical() && CoopTacticalRuleset(`TACTICALRULES) != none)
		{
			CoopTacticalRuleset(`TACTICALRULES).OnGuestDisconnected(Slot);
		}
	}
	if (!`XCOMNETMANAGER.HasConnections())
	{
		default.ConnectedSlots.Length = 0;
		default.ConnectionSlots.Length = 0;
	}
}

// Host view: is this player slot played by someone right now?
static function bool IsSlotPlayed(int Slot)
{
	return Slot == class'XComGameState_CoopCampaign'.const.SLOT_HOST || default.ConnectedSlots.Find(Slot) != INDEX_NONE;
}

// Who gives orders to a soldier owned by Owner: the owner, or the host while that guest is away.
// On a guest machine the host's connection list is unknown, so a guest controls exactly its own slot.
static function int ControllerOf(int UnitOwner)
{
	if (UnitOwner < 0)
	{
		return class'XComGameState_CoopCampaign'.const.SLOT_HOST;
	}
	if (IsHost() && !IsSlotPlayed(UnitOwner))
	{
		return class'XComGameState_CoopCampaign'.const.SLOT_HOST;
	}
	return UnitOwner;
}

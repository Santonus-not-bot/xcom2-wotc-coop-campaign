//---------------------------------------------------------------------------------------
//  FILE:    CoopPing.uc
//  PURPOSE: Map pings in missions: "CoopMapPing"(slot, x, y, z) marks a spot for the other
//           players with a floating world message (the game's QueueWorldMessage, as used for
//           the "suppressed" label). Sent from CoopTacticalController's console command
//           CoopPing (bindable to a key) at the 3D cursor. With 3-4 players the host forwards
//           a guest's ping to the other guests (guests connect only to the host).
//           A plain Object (delegates on the network manager must not point at Actors).
//---------------------------------------------------------------------------------------
class CoopPing extends Object config(CoopCampaign);

var config bool bInited;   // config only so the default may be written
var config int PingCount;  // numbers each shown ping: every ping is its own world message
var config array<string> LastPingId;    // per player slot: the id of that player's ping on screen

const PING_SECONDS = 6.0;

static function Init()
{
	local CoopPing Ping;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	Ping = new class'CoopPing';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Ping.OnRemoteCommand);
}

static function SendPing(vector Location)
{
	Init();
	Send(class'CoopRole'.static.LocalSlot(), Location);
	Show(class'CoopRole'.static.LocalSlot(), Location);    // the sender sees its own mark too
}

static function Send(int Slot, vector Location)
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Slot, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(int(Location.X), Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(int(Location.Y), Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(int(Location.Z), Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopMapPing", Params);
}

// Two PCs 2026-11-18: with the game's message queue (QueueWorldMessage) and one id per player, the player whose turn it
// was saw only their first ping (a message whose id is on screen is not drawn again elsewhere) and a watching player
// saw none (the queue waits while the watcher's game replays). So: straight to the world message manager, one id per
// ping, and the player's previous ping taken down.
static function Show(int Slot, vector Location)
{
	local XComPresentationLayerBase Pres;
	local UIWorldMessageMgr Mgr;
	local string Id, Text;
	local int i;

	Pres = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres;
	Mgr = (Pres != none) ? Pres.GetWorldMessenger() : none;
	default.PingCount++;
	Id = "CoopPing" $ Slot $ "_" $ default.PingCount;
	Text = "Ping: " $ PlayerName(Slot);
	if (Mgr == none)
	{
		`log("ping from player" @ Slot @ "at" @ Location @ "(no world message manager: queued)",, 'CoopPing');
		class'XComPresentationLayerBase'.static.QueueWorldMessage(Text, Location, , eColor_Attention,
			class'UIWorldMessageMgr'.const.FXS_MSG_BEHAVIOR_STEADY, Id, , , , PING_SECONDS);
		return;
	}
	if (Slot >= 0 && Slot < default.LastPingId.Length && default.LastPingId[Slot] != "")
	{
		Mgr.RemoveMessage(default.LastPingId[Slot]);
	}
	if (Slot >= 0)
	{
		if (default.LastPingId.Length <= Slot)
		{
			default.LastPingId.Length = Slot + 1;
		}
		default.LastPingId[Slot] = Id;
	}
	Mgr.Message(Text, Location, , eColor_Attention, class'UIWorldMessageMgr'.const.FXS_MSG_BEHAVIOR_STEADY,
		Id, , , , PING_SECONDS);
	i = Mgr.m_arrMsgs.Find('m_sId', Id);
	`log("ping from player" @ Slot @ "at" @ Location @ "shown=" $ (i != INDEX_NONE) @ "managerVisible=" $ Mgr.bIsVisible
		@ "active=" $ (i != INDEX_NONE && Mgr.m_arrActiveMessages.Find(i) != INDEX_NONE),, 'CoopPing');
}

// The names the turn banner uses: "Host", "Player 2"...
static function string PlayerName(int Slot)
{
	if (Slot == class'XComGameState_CoopCampaign'.const.SLOT_HOST)
	{
		return "Host";
	}
	return "Player" @ (Slot + 1);
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local vector Location;
	local int Slot;

	if (Command != "CoopMapPing")
	{
		return;
	}
	Slot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Location.X = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Location.Y = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Location.Z = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Show(Slot, Location);
	if (!class'CoopRole'.static.IsGuest() && class'CoopRole'.default.ConnectedSlots.Length > 1)
	{
		Send(Slot, Location);   // forward to the other guests; the sender shows its own mark again under the same id
	}
}

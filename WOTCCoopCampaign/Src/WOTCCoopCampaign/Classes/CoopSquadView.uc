//---------------------------------------------------------------------------------------
//  FILE:    CoopSquadView.uc
//  PURPOSE: Guests watch the host pick the squad. Squad Select stays the host's screen (the mission launch is built
//           around the host); while it is open the host sends, every 2 s and on each change, the mission's name and
//           the soldiers in the squad with their owners ("CoopSquadView"). CoopHUDScreen shows it on the guests'
//           Avenger as a panel until the host leaves Squad Select.
//           A plain Object; the state lives in class defaults.
//---------------------------------------------------------------------------------------
class CoopSquadView extends Object config(CoopCampaign);

const RESEND_SECONDS = 2;
const STALE_SECONDS = 6;

var config bool bInited;
var config string LastSent;
var config int SentAt;
var config string Received;     // "mission|line|line..." from the host
var config int ReceivedAt;

static function Init()
{
	local CoopSquadView Listener;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	Listener = new class'CoopSquadView';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Listener.OnRemoteCommand);
}

static function string MissionName(XComGameState_HeadquartersXCom XComHQ)
{
	local XComGameState_MissionSite Mission;
	local string Name;

	Mission = XComGameState_MissionSite(`XCOMHISTORY.GetGameStateForObjectID(XComHQ.MissionRef.ObjectID));
	if (Mission == none)
	{
		return "";
	}
	Name = Mission.GeneratedMission.BattleOpName;
	if (Mission.GetMissionDescription() != "")
	{
		Name $= (Name == "" ? "" : " - ") $ Mission.GetMissionDescription();
	}
	return Name;
}

// CoopLink.Tick, every second: the host in Squad Select sends the squad.
static function HostTick()
{
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_Unit Unit;
	local array<byte> Params;
	local string S, Owner;
	local int i, Slot, Now;

	if (!class'CoopRole'.static.IsHost() || !class'CoopSession'.static.IsConnected() || `HQPRES == none
		|| `HQPRES.ScreenStack == none || `HQPRES.ScreenStack.GetFirstInstanceOf(class'UISquadSelect') == none)
	{
		return;
	}
	Init();
	XComHQ = XComGameState_HeadquartersXCom(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom'));
	if (XComHQ == none)
	{
		return;
	}
	S = Repl(MissionName(XComHQ), "|", "/");
	for (i = 0; i < XComHQ.Squad.Length; i++)
	{
		Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(XComHQ.Squad[i].ObjectID));
		if (Unit == none)
		{
			S $= "|" $ (i + 1) $ ". (empty)";
			continue;
		}
		Slot = class'CoopOwnership'.static.OwnerOf(Unit);
		Owner = "";
		if (Slot >= 0)
		{
			Owner = "  [" $ class'CoopRoster'.static.SlotLabel(Slot) $ "]";
		}
		S $= "|" $ (i + 1) $ ". " $ Repl(Unit.GetName(eNameType_RankFull), "|", "/") $ Owner;
	}
	Now = class'CoopMissionLoading'.static.ClockSeconds();
	if (S == default.LastSent && Now - default.SentAt < RESEND_SECONDS && Now >= default.SentAt)
	{
		return;
	}
	if (S != default.LastSent)
	{
		`log("squad view sent:" @ Repl(S, "|", " / "),, 'CoopSquad');
	}
	default.LastSent = S;
	default.SentAt = Now;
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(S, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopSquadView", Params);
}

// The squad the host is picking, or "" when the host is not in Squad Select (nothing for 6 s).
static function string Current()
{
	local int Age;

	if (default.Received == "")
	{
		return "";
	}
	Age = class'CoopMissionLoading'.static.ClockSeconds() - default.ReceivedAt;
	if (Age < 0 || Age > STALE_SECONDS)
	{
		return "";
	}
	return default.Received;
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local string S;

	if (Command != "CoopSquadView")
	{
		return;
	}
	S = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
	if (S != default.Received)
	{
		`log("squad view received:" @ Repl(S, "|", " / "),, 'CoopSquad');
	}
	default.Received = S;
	default.ReceivedAt = class'CoopMissionLoading'.static.ClockSeconds();
}

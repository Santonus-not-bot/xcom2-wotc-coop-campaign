//---------------------------------------------------------------------------------------
//  FILE:    CoopSteamJoin.uc
//  PURPOSE: DRAFT, NEVER RUN (needs two Steam accounts). Joining by Steam invite (bSteamInvites, XComCoopCampaign.ini).
//           Host (HostSteam): create an online session marked as co-op (squad cost and turn
//             time set to marker values, as Team Dragonpunk did), then a game server over Steam
//             sockets (URL option "steamsockets", like XComShellPresentationLayer does for
//             non-LAN games), then open the Steam invite overlay.
//           Guest: the game's own invite handler (XComOnlineEventMgr.OnGameInviteAccepted) sends
//             the player to the multiplayer lobby, so while enabled ours replaces it: a co-op
//             invite joins the session, resolves the host's address and connects over Steam
//             sockets; any other invite is passed on to the game's handler.
//           Direct IP (MPCreateServer / @connect) keeps working without any of this.
//           A plain Object (delegates on online interfaces must not point at Actors).
//---------------------------------------------------------------------------------------
class CoopSteamJoin extends Object config(CoopCampaign);

const COOP_MARKER_SQUAD_COST = 7777777;
const COOP_MARKER_TURN_TIME = 7777;
const SESSION_NAME = 'Game';

var config bool bSteamInvites;
var config int SteamPort;
var config bool bInited;   // config only so the default may be written

static function OnlineSubsystem OSS()
{
	return class'GameEngine'.static.GetOnlineSubsystem();
}

static function Init()
{
	local CoopSteamJoin Join;

	if (default.bInited || !default.bSteamInvites || OSS() == none || OSS().GameInterface == none)
	{
		return;
	}
	default.bInited = true;
	Join = new class'CoopSteamJoin';
	OSS().GameInterface.ClearGameInviteAcceptedDelegate(0, `ONLINEEVENTMGR.OnGameInviteAccepted);
	OSS().GameInterface.AddGameInviteAcceptedDelegate(0, Join.OnGameInviteAccepted);
	`log("Steam invites handled by co-op",, 'CoopSteam');
}

//---------------------------------------------------------------------------------------
// Host

static function bool HostSteam()
{
	local XComOnlineGameSettings Settings;
	local CoopSteamJoin Join;

	if (OSS() == none || OSS().GameInterface == none)
	{
		`log("host: no online subsystem",, 'CoopSteam');
		return false;
	}
	Init();
	Settings = new class'XComOnlineGameSettings';
	Settings.NumPublicConnections = class'XComGameState_CoopCampaign'.const.MAX_PLAYERS - 1;
	Settings.bAllowInvites = true;
	Settings.bUsesPresence = true;
	Settings.bAllowJoinViaPresence = true;
	Settings.bShouldAdvertise = false;      // invite only
	Settings.bIsLanMatch = false;
	Settings.SetMaxSquadCost(COOP_MARKER_SQUAD_COST);
	Settings.SetTurnTimeSeconds(COOP_MARKER_TURN_TIME);
	Join = new class'CoopSteamJoin';
	OSS().GameInterface.AddCreateOnlineGameCompleteDelegate(Join.OnCreateOnlineGameComplete);
	if (!OSS().GameInterface.CreateOnlineGame(0, SESSION_NAME, Settings))
	{
		OSS().GameInterface.ClearCreateOnlineGameCompleteDelegate(Join.OnCreateOnlineGameComplete);
		`log("host: CreateOnlineGame failed to start",, 'CoopSteam');
		return false;
	}
	return true;
}

function OnCreateOnlineGameComplete(name SessionName, bool bWasSuccessful)
{
	local string Error;

	OSS().GameInterface.ClearCreateOnlineGameCompleteDelegate(OnCreateOnlineGameComplete);
	`log("host: session" @ SessionName @ "created=" $ class'CoopHarness'.static.BoolStr(bWasSuccessful),, 'CoopSteam');
	if (!bWasSuccessful)
	{
		return;
	}
	// through CoopLink, so the server is reopened over Steam sockets after a mission is built
	if (!class'CoopLink'.static.HostOpen(default.SteamPort, true))
	{
		Error = "CreateServer failed";
	}
	`log("host: server over Steam sockets port=" $ default.SteamPort @ "error=" $ Error,, 'CoopSteam');
	if (Error == "" && OSS().PlayerInterfaceEx != none)
	{
		OSS().PlayerInterfaceEx.ShowInviteUI(0, "XCOM 2 co-op campaign");
	}
}

//---------------------------------------------------------------------------------------
// Guest

static function bool IsCoopInvite(const out OnlineGameSearchResult InviteResult)
{
	local XComOnlineGameSettings Settings;

	Settings = XComOnlineGameSettings(InviteResult.GameSettings);
	return Settings != none && Settings.GetMaxSquadCost() == COOP_MARKER_SQUAD_COST && Settings.GetTurnTimeSeconds() == COOP_MARKER_TURN_TIME;
}

function OnGameInviteAccepted(const out OnlineGameSearchResult InviteResult, bool bWasSuccessful)
{
	if (!bWasSuccessful || !IsCoopInvite(InviteResult))
	{
		`ONLINEEVENTMGR.OnGameInviteAccepted(InviteResult, bWasSuccessful);    // not ours: the game's own handling
		return;
	}
	`log("guest: co-op invite accepted, joining the session",, 'CoopSteam');
	OSS().GameInterface.AddJoinOnlineGameCompleteDelegate(OnJoinOnlineGameComplete);
	if (!OSS().GameInterface.JoinOnlineGame(0, SESSION_NAME, InviteResult))
	{
		OSS().GameInterface.ClearJoinOnlineGameCompleteDelegate(OnJoinOnlineGameComplete);
		`log("guest: JoinOnlineGame failed to start",, 'CoopSteam');
	}
}

function OnJoinOnlineGameComplete(name SessionName, bool bWasSuccessful)
{
	local string Resolved, Host, Port, Error;
	local int i;

	OSS().GameInterface.ClearJoinOnlineGameCompleteDelegate(OnJoinOnlineGameComplete);
	if (!bWasSuccessful || !OSS().GameInterface.GetResolvedConnectString(SessionName, Resolved))
	{
		`log("guest: join failed or no host address",, 'CoopSteam');
		return;
	}
	// "host:port?options" as XComShellPresentationLayer parses it
	i = InStr(Resolved, ":");
	Host = (i != -1) ? Left(Resolved, i) : Resolved;
	Port = (i != -1) ? Mid(Resolved, i + 1) : "0";
	i = InStr(Host, "?");
	if (i != -1)
	{
		Host = Left(Host, i);
	}
	// through CoopLink, which remembers the host for reconnecting (the host closes the connection while it
	// builds each mission)
	if (!class'CoopLink'.static.GuestConnect(Host, int(Port), true))
	{
		Error = "CreateClient failed";
	}
	`log("guest: connecting over Steam sockets to the host, port" @ Port @ "error=" $ Error,, 'CoopSteam');
}

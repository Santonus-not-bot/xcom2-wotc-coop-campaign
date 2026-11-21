//---------------------------------------------------------------------------------------
//  FILE:    CoopMenu.uc
//  PURPOSE: What the co-op buttons do (UIScreenListener_CoopMenu) and the status line.
//           Host (Avenger HUD "Host co-op"): give the campaign its co-op object if it has none
//             (two players, default squad split), then open the server: over Steam sockets with
//             an invite overlay when bSteamInvites (CoopSteamJoin), else on CoopLink.DefaultPort
//             for direct IP. Guests that join get the campaign and enter the Avenger by themselves.
//           Join (main menu "Join co-op"): a text dialog for the host's address ("1.2.3.4" or
//             "1.2.3.4:7778"), then CoopLink.GuestConnect.
//---------------------------------------------------------------------------------------
class CoopMenu extends Object;

static function bool IsHosting()
{
	return `XCOMNETMANAGER.HasServerConnection();
}

static function HostFromAvenger()
{
	local XComGameState NewGameState;
	local XComGameState_CoopCampaign Coop;

	if (class'CoopRole'.static.IsGuest() || IsHosting())
	{
		return;
	}
	if (!class'CoopRole'.static.CoopActive())
	{
		NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop: start hosting");
		Coop = class'XComGameState_CoopCampaign'.static.GetForChange(NewGameState);
		Coop.SetDefaultSquadSplit(class'X2StrategyGameRulesetDataStructures'.static.GetMaxSoldiersAllowedOnMission());
		`GAMERULES.SubmitGameState(NewGameState);
		`log("host: this campaign is now a co-op campaign:" @ Coop.Describe(),, 'CoopMenu');
	}
	if (class'CoopSteamJoin'.default.bSteamInvites)
	{
		`log("host: hosting over Steam (invites)",, 'CoopMenu');
		class'CoopSteamJoin'.static.HostSteam();
	}
	else
	{
		`log("host: hosting for direct IP on port" @ class'CoopLink'.default.DefaultPort,, 'CoopMenu');
		class'CoopLink'.static.HostOpen(class'CoopLink'.default.DefaultPort);
	}
}

static function OpenJoinDialog()
{
	local TInputDialogData Data;
	local XComPresentationLayerBase Pres;

	Pres = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres;
	if (Pres == none)
	{
		return;
	}
	Data.strTitle = "Join co-op: the host's address (IP, or IP:port)";
	Data.iMaxChars = 40;
	Data.strInputBoxText = class'CoopLink'.default.GuestHost;
	Data.DialogType = eDialogType_SingleLine;
	Data.fnCallbackAccepted = OnJoinAddress;
	Pres.UIInputDialog(Data);
}

// "1.2.3.4" or "1.2.3.4:7778"
static function OnJoinAddress(string Text)
{
	local array<string> Parts, Octets;
	local int Port;

	Text = Repl(Text, " ", "");
	Parts = SplitString(Text, ":", true);
	if (Parts.Length > 0)
	{
		Octets = SplitString(Parts[0], ".", true);    // into a local first: ".Length" of a call's result read wrong (0)
	}
	if (Parts.Length == 0 || Octets.Length != 4)
	{
		`log("join: not an IPv4 address:" @ Text,, 'CoopMenu');
		return;
	}
	Port = (Parts.Length > 1 && int(Parts[1]) > 0) ? int(Parts[1]) : class'CoopLink'.default.DefaultPort;
	`log("join: connecting to" @ Parts[0] $ ":" $ Port,, 'CoopMenu');
	class'CoopLink'.static.GuestConnect(Parts[0], Port);
}

// One line for the status panel; "" hides it.
static function string StatusText()
{
	local int Slot;
	local string S;

	if (class'CoopRole'.static.IsGuest())
	{
		return class'CoopRole'.default.AssignedSlot > 0
			? "Co-op: player" @ (class'CoopRole'.default.AssignedSlot + 1) $ ", connected to the host"
			: "Co-op: joining the host...";
	}
	if (class'CoopLink'.default.bReconnecting)
	{
		return "Co-op: the host is busy (building a mission or loading) - reconnecting...";
	}
	if (IsHosting())
	{
		foreach class'CoopRole'.default.ConnectedSlots(Slot)
		{
			S $= (S == "" ? "" : ", ") $ (Slot + 1);
		}
		return "Co-op: hosting on port" @ class'CoopLink'.default.HostPort $ (S == "" ? " - waiting for players" : " - players " $ S);
	}
	if (class'CoopLink'.default.bReopenPending || class'CoopLink'.default.bReopenAfterReturn)
	{
		return "Co-op: the other players rejoin after loading";
	}
	return "";
}

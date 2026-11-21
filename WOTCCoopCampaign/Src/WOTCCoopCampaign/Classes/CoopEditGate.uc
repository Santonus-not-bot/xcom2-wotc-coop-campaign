//---------------------------------------------------------------------------------------
//  FILE:    CoopEditGate.uc
//  PURPOSE: Ties the baton to the screens where a player changes the campaign
//           (EditScreens in XComCoopCampaign.ini: research, building, armory, Geoscape...).
//           Opening such a screen without the baton requests it and covers the screen with
//           a "waiting for partner" dialog until the grant arrives; Cancel closes the
//           screen. The holder does not hand the baton over while one of its own edit
//           screens is open: the request waits until the last one closes.
//---------------------------------------------------------------------------------------
class CoopEditGate extends UIScreenListener config(CoopCampaign);

var config array<name> EditScreens;
var config array<name> ViewScreens;   // exact classes a player may open to look without the baton (the barracks)

var localized string m_strWaitTitle;
var localized string m_strWaitText;
var localized string m_strCancel;

static function bool IsEditScreen(UIScreen Screen)
{
	local name ClassName;

	// looking is free: the barracks list, the memorial, a soldier's Armory overview (two-PC play test 2026-11-19:
	// "players should be able to view the barracks without being the one in control")
	if (default.ViewScreens.Find(Screen.Class.Name) != INDEX_NONE)
	{
		return false;
	}
	// the Geoscape is open to everyone: only the holder's clock runs, the others watch it (CoopGeoWatch). As an edit
	// screen it held the baton back: a host on the Geoscape that answered "hand it over" never handed it over
	// (controltest 2026-11-19), and a host sits on the Geoscape most of the time.
	if (Screen.IsA('UIStrategyMap'))
	{
		return false;
	}
	foreach default.EditScreens(ClassName)
	{
		if (Screen.IsA(ClassName))
		{
			return true;
		}
	}
	return false;
}

// True while an edit screen other than Ignore is on the local screen stack.
static function bool IsEditing(optional UIScreen Ignore)
{
	local UIScreen Screen;

	if (`SCREENSTACK == none)
	{
		return false;
	}
	foreach `SCREENSTACK.Screens(Screen)
	{
		if (Screen != Ignore && IsEditScreen(Screen))
		{
			return true;
		}
	}
	return false;
}

event OnInit(UIScreen Screen)
{
	local bool bForce;

	if (Screen.IsA('UIAvengerHUD'))
	{
		Screen.Spawn(class'CoopBatonPanel', Screen).InitBatonPanel();
		return;
	}
	if (!IsEditScreen(Screen) || !class'CoopSession'.static.IsConnected() || class'CoopSession'.default.bHasBaton)
	{
		return;
	}
	// a guest may not use this screen at all (CoopGuestRights closes it): do not ask for the baton
	if (class'CoopGuestRights'.static.Refusal(Screen) != "")
	{
		return;
	}
	`log("edit screen" @ Screen.Class.Name @ "opened without baton",, 'CoopCampaign');
	class'CoopSession'.default.WaitingScreenClass = Screen.Class.Name;
	// the host takes it back; a guest takes it for its own soldiers (CoopGuestRights closed the others' already);
	// for anything else a guest asks and the holder answers
	bForce = class'CoopRole'.static.IsHost() || UIArmory(Screen) != none;
	class'CoopSession'.static.RequestBaton(bForce);
	ShowWaitDialog(Screen, bForce);
}

event OnRemoved(UIScreen Screen)
{
	if (!IsEditScreen(Screen))
	{
		return;
	}
	if (class'CoopSession'.default.WaitingScreenClass == Screen.Class.Name)
	{
		class'CoopSession'.default.WaitingScreenClass = '';
	}
	if (class'CoopSession'.default.bGrantRequested && class'CoopSession'.default.bHasBaton && !IsEditing(Screen))
	{
		`log("last edit screen closed, handing over the requested baton",, 'CoopCampaign');
		class'CoopSession'.static.GrantBaton();
	}
}

function ShowWaitDialog(UIScreen Screen, optional bool bForce)
{
	local TProgressDialogData Data;

	Data.strTitle = default.m_strWaitTitle;
	Data.strDescription = default.m_strWaitText;
	if (!bForce)
	{
		Data.strDescription = "Asked" @ class'CoopRoster'.static.DisplayName(class'XComGameState_CoopCampaign'.const.SLOT_HOST)
			@ "for control. Waiting for an answer...";
	}
	Data.strAbortButtonText = default.m_strCancel;
	Data.fnCallback = OnWaitCancelled;
	Screen.Movie.Pres.UIProgressDialog(Data);
}

// Called by CoopSession once the baton arrives.
static function CloseWaitDialog()
{
	if (`PRESBASE != none && `PRESBASE.IsInState('State_ProgressDialog'))
	{
		`PRESBASE.UICloseProgressDialog();
	}
}

// CoopSession: the holder said no. Close the waiting dialog and the screen that asked.
static function RequestDenied()
{
	local UIScreen Screen;

	CloseWaitDialog();
	class'CoopRoster'.static.Toast(class'CoopRoster'.static.DisplayName(class'XComGameState_CoopCampaign'.const.SLOT_HOST) @ "kept control");
	if (`SCREENSTACK == none)
	{
		return;
	}
	foreach `SCREENSTACK.Screens(Screen)
	{
		if (Screen.Class.Name == class'CoopSession'.default.WaitingScreenClass)
		{
			Screen.CloseScreen();
			return;
		}
	}
}

// The dialog pops itself before this runs; leave the edit screen too.
function OnWaitCancelled()
{
	local UIScreen Screen;

	`log("waiting for baton cancelled, closing" @ class'CoopSession'.default.WaitingScreenClass,, 'CoopCampaign');
	foreach `SCREENSTACK.Screens(Screen)
	{
		if (Screen.Class.Name == class'CoopSession'.default.WaitingScreenClass)
		{
			Screen.CloseScreen();
			return;
		}
	}
}

defaultproperties
{
	ScreenClass = none;
}

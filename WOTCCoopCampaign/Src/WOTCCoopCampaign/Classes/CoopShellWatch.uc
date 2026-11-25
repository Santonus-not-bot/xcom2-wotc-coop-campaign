//---------------------------------------------------------------------------------------
//  FILE:    CoopShellWatch.uc
//  PURPOSE: Main menu (UIShell / UIFinalShell): adds "Co-op Campaign", "Balanced Co-op Campaign" and "Scenario Mode"
//           (each opens the co-op lobby, CoopLobbyScreen) to the game's own menu row, right after "New Campaign", and keeps them there. The shell rebuilds its row at times of its own
//           choosing (UIFinalShell.UpdateMenu: when the save list is read, on a login change), which removes them,
//           so this checks twice a second. Also starts the menu scene (CoopShellScene).
//           One per shell screen; spawned by UIScreenListener_CoopMenu.
//---------------------------------------------------------------------------------------
class CoopShellWatch extends Actor;

var UIShell Shell;
var CoopShellScene Scene;
var bool bLogged;

var localized string m_strCoopCampaign;
var localized string m_strScenarioMode;
var localized string m_strBalanced;
var localized string m_strScenarioSoon;

function Init(UIShell InShell)
{
	Shell = InShell;
	SetTimer(0.5, true, nameof(Check));
	Check();
}

function Check()
{
	if (Shell == none || Shell.bDeleteMe)
	{
		ClearTimer(nameof(Check));
		Destroy();
		return;
	}
	EnsureButtons();
	if (Scene == none && class'CoopShellScene'.default.bMenuSoldiers)
	{
		Scene = Spawn(class'CoopShellScene', self);
		Scene.Init(Shell);
	}
}

function int FindButton(name ButtonName)
{
	local int i;

	for (i = 0; i < Shell.MainMenu.Length; i++)
	{
		if (Shell.MainMenu[i] != none && Shell.MainMenu[i].MCName == ButtonName)
		{
			return i;
		}
	}
	return INDEX_NONE;
}

function EnsureButtons()
{
	local int At;

	if (Shell.MainMenuContainer == none || Shell.MainMenu.Length == 0 || FindButton('CoopCampaign') != INDEX_NONE)
	{
		return;
	}
	// right after "New Campaign" ('SP' in War of the Chosen, 'Strategy' in the base game's debug shell)
	At = FindButton('SP');
	if (At == INDEX_NONE)
	{
		At = FindButton('Strategy');
	}
	At = (At == INDEX_NONE) ? 0 : At + 1;
	AddButton('CoopCampaign', (m_strCoopCampaign != "") ? m_strCoopCampaign : "Co-op Campaign", At, false, "");
	AddButton('CoopBalanced', (m_strBalanced != "") ? m_strBalanced : "Balanced Co-op Campaign", At + 1, false, "");
	AddButton('CoopScenario', (m_strScenarioMode != "") ? m_strScenarioMode : "Scenario Mode", At + 2, false, "");
	Shell.MainMenuContainer.Navigator.SelectFirstAvailable();
	if (!bLogged)
	{
		bLogged = true;
		LogMenu();
	}
}

function AddButton(name ButtonName, string Label, int At, bool bDisabled, string Tooltip)
{
	local UIX2MenuButton Button;

	Button = Spawn(class'UIX2MenuButton', Shell.MainMenuContainer);
	Button.InitMenuButton(false, ButtonName, Label, OnButtonClicked);
	Button.OnSizeRealized = Shell.OnButtonSizeRealized;
	if (bDisabled)
	{
		Button.SetDisabled(true, Tooltip);
		Shell.UpdateButtonDisableTooltip(Button, Tooltip);
	}
	Shell.MainMenu.InsertItem(Min(At, Shell.MainMenu.Length), Button);
}

function OnButtonClicked(UIButton Button)
{
	switch (Button.MCName)
	{
	case 'CoopCampaign':
		OpenLobby(class'CoopLobby'.const.MODE_CAMPAIGN);
		break;
	case 'CoopBalanced':
		OpenLobby(class'CoopLobby'.const.MODE_BALANCED);
		break;
	case 'CoopScenario':
		OpenLobby(class'CoopLobby'.const.MODE_SCENARIO);
		break;
	}
}

// Also the bot step @lobby.
static function CoopLobbyScreen OpenLobby(int Mode)
{
	local CoopLobbyScreen Lobby;
	local XComPresentationLayerBase Pres;

	`log("main menu:" @ class'CoopLobby'.static.ModeName(Mode),, 'CoopMenu');
	Pres = `PRESBASE;
	Lobby = Pres.Spawn(class'CoopLobbyScreen', Pres);
	Lobby.InitMode = Mode;
	Pres.ScreenStack.Push(Lobby);
	return Lobby;
}

function LogMenu()
{
	local string Line;
	local int i;

	for (i = 0; i < Shell.MainMenu.Length; i++)
	{
		Line $= (Line == "" ? "" : " | ") $ string(Shell.MainMenu[i].MCName);
	}
	`log("main menu row:" @ Line,, 'CoopMenu');
}

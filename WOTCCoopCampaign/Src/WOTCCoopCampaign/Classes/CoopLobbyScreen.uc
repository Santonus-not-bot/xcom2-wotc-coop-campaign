//---------------------------------------------------------------------------------------
//  FILE:    CoopLobbyScreen.uc
//  PURPOSE: The co-op lobby screen (CoopLobby does the work). Opened from the main menu's "Co-op Campaign",
//           "Balanced Co-op Campaign" and "Scenario Mode" (InitMode), and on a guest when its host is in a lobby.
//             Before a role: "Host this game" or "Join a friend".
//             Everyone: Player 1-4 with name and state (CoopRoster).
//             Host: a "Make player N" button on each guest's row (the guest there swaps places), then the mode's
//                   starts: new campaign / load (campaigns), early / mid / late game (scenario); "Close lobby".
//             Guest: "Leave lobby"; the host starts, the guest follows (CoopLobby).
//---------------------------------------------------------------------------------------
class CoopLobbyScreen extends UIScreen;

const ROWS = 4;

var int InitMode;                 // the mode the main menu opened it for (host); a guest takes the host's
var UIPanel Container;
var UIBGBox BG;
var UIX2PanelHeader Title;
var UIText Status;
var array<UIText> RowTexts;
var array<UIButton> RowButtons;   // by row: the host's "Make player N" for a guest's row (row 0, the host, has none)
var UIButton HostButton, JoinButton, StartA, StartB, StartC, CloseButton;

simulated function InitScreen(XComPlayerController InitController, UIMovie InitMovie, optional name InitName)
{
	local int i;
	local UIText RowText;
	local UIButton Button;

	super.InitScreen(InitController, InitMovie, InitName);
	if (InitMode == class'CoopLobby'.const.MODE_NONE)
	{
		InitMode = class'CoopLobby'.default.Mode;
	}
	Container = Spawn(class'UIPanel', self).InitPanel('CoopLobbyContainer');
	Container.SetSize(620, 560);
	Container.AnchorCenter();
	Container.SetPosition(-310, -280);
	BG = Spawn(class'UIBGBox', Container).InitBG('CoopLobbyBG', 0, 0, 620, 560, eUIState_Normal);
	Title = Spawn(class'UIX2PanelHeader', Container).InitPanelHeader('CoopLobbyTitle', class'CoopLobby'.static.ModeName(InitMode), "");
	Title.SetHeaderWidth(580);
	Title.SetPosition(20, 14);
	Status = Spawn(class'UIText', Container).InitText('CoopLobbyStatus', "");
	Status.SetPosition(20, 66);
	Status.SetSize(580, 60);

	for (i = 0; i < ROWS; i++)
	{
		RowText = Spawn(class'UIText', Container).InitText(name("CoopLobbyRow" $ i), "");
		RowText.SetPosition(30, 132 + i * 50);
		RowText.SetSize(360, 40);
		RowTexts.AddItem(RowText);
		Button = none;
		if (i > 0)
		{
			Button = Spawn(class'UIButton', Container);
			Button.InitButton(name("CoopLobbyMove" $ i), "", OnRowButton, eUIButtonStyle_HOTLINK_BUTTON);
			Button.SetPosition(400, 130 + i * 50);
			Button.SetWidth(190);
			Button.Hide();
		}
		RowButtons.AddItem(Button);
	}

	HostButton = AddButton('CoopLobbyHost', "Host this game", 30, 350, 270);
	JoinButton = AddButton('CoopLobbyJoin', "Join a friend", 320, 350, 270);
	StartA = AddButton('CoopLobbyStartA', "", 30, 410, 270);
	StartB = AddButton('CoopLobbyStartB', "", 320, 410, 270);
	StartC = AddButton('CoopLobbyStartC', "", 30, 460, 270);
	CloseButton = AddButton('CoopLobbyClose', "Back", 320, 460, 270);
	Refresh();
	SetTimer(0.5, true, nameof(Refresh));
	`log("lobby screen open:" @ class'CoopLobby'.static.ModeName(InitMode),, 'CoopLobby');
}

function UIButton AddButton(name ButtonName, string Label, int X, int Y, int W)
{
	local UIButton Button;

	Button = Spawn(class'UIButton', Container);
	Button.InitButton(ButtonName, Label, OnButtonClicked, eUIButtonStyle_HOTLINK_BUTTON);
	Button.SetPosition(X, Y);
	Button.SetWidth(W);
	return Button;
}

function int Role()
{
	if (class'CoopLobby'.static.IsHostingLobby())
	{
		return 1;    // host
	}
	if (class'CoopLink'.default.GuestHost != "")
	{
		return 2;    // guest (or joining)
	}
	return 0;
}

function string RowLine(int Slot)
{
	local string PlayerName, StateText;
	local int PState;

	PlayerName = (class'CoopRoster'.default.PlayerNames.Length > Slot) ? class'CoopRoster'.default.PlayerNames[Slot] : "";
	PState = class'CoopRoster'.static.StateOf(Slot);
	if (Slot == 0 && Role() == 1)
	{
		PlayerName = class'CoopRoster'.static.LocalName();
		PState = class'CoopRoster'.const.PS_CONNECTED;
	}
	StateText = class'CoopRoster'.static.StateText(PState);
	if (PlayerName == "" && PState != class'CoopRoster'.const.PS_CONNECTED)
	{
		return ((Slot == 0) ? "HOST" : "PLAYER" @ (Slot + 1)) $ ":  (open)";
	}
	return ((Slot == 0) ? "HOST" : "PLAYER" @ (Slot + 1)) $ ":  " $ PlayerName
		$ ((StateText != "") ? "  - " $ StateText : "")
		$ ((Slot == class'CoopRole'.static.LocalSlot() && Role() != 0) ? "  (you)" : "");
}

function Refresh()
{
	local int i, R;

	R = Role();
	// a guest's lobby shows the host's mode (it opens before the host's first "CoopLobby" arrives)
	if (R == 2 && class'CoopLobby'.default.Mode != class'CoopLobby'.const.MODE_NONE && class'CoopLobby'.default.Mode != InitMode)
	{
		InitMode = class'CoopLobby'.default.Mode;
		`log("lobby screen: the host's mode is" @ class'CoopLobby'.static.ModeName(InitMode),, 'CoopLobby');
		// the header's Flash clip keeps the first title it got: a new header with the host's mode
		Title.Remove();
		Title = Spawn(class'UIX2PanelHeader', Container).InitPanelHeader(name("CoopLobbyTitle" $ InitMode), class'CoopLobby'.static.ModeName(InitMode), "");
		Title.SetHeaderWidth(580);
		Title.SetPosition(20, 14);
	}
	switch (R)
	{
	case 1:
		Status.SetText("Hosting on port" @ class'CoopLink'.default.HostPort $ ". Friends pick Join a friend and enter your address. Make player sets who plays which player.");
		break;
	case 2:
		Status.SetText(class'CoopLobby'.default.bGuestInLobby
			? "You are player" @ (class'CoopRole'.static.LocalSlot() + 1) $ " in the host's lobby. When the host starts, you follow by yourself."
			: "Joining" @ class'CoopLink'.default.GuestHost $ "...");
		break;
	default:
		Status.SetText("Host a game for your friends, or join a friend's game.");
	}
	for (i = 0; i < ROWS; i++)
	{
		RowTexts[i].SetText((R == 0) ? "" : RowLine(i));
		if (RowButtons[i] != none)
		{
			if (R == 1 && class'CoopRole'.default.ConnectedSlots.Find(i) != INDEX_NONE)
			{
				RowButtons[i].SetText("Make player" @ (class'CoopLobby'.static.NextSlot(i) + 1));
				RowButtons[i].Show();
			}
			else
			{
				RowButtons[i].Hide();
			}
		}
	}
	ShowButton(HostButton, R == 0);
	ShowButton(JoinButton, R == 0);
	if (R == 1 && InitMode == class'CoopLobby'.const.MODE_SCENARIO)
	{
		StartA.SetText("Start: early game");
		StartB.SetText("Start: mid game");
		StartC.SetText("Start: late game");
		ShowButton(StartA, true);
		ShowButton(StartB, true);
		ShowButton(StartC, true);
	}
	else if (R == 1)
	{
		StartA.SetText((InitMode == class'CoopLobby'.const.MODE_BALANCED) ? "New balanced campaign" : "New co-op campaign");
		StartB.SetText("Load a co-op campaign");
		ShowButton(StartA, true);
		ShowButton(StartB, true);
		ShowButton(StartC, false);
	}
	else
	{
		ShowButton(StartA, false);
		ShowButton(StartB, false);
		ShowButton(StartC, false);
	}
	CloseButton.SetText((R == 1) ? "Close lobby" : ((R == 2) ? "Leave lobby" : "Back"));
}

function ShowButton(UIButton Button, bool bShow)
{
	if (bShow)
	{
		Button.Show();
	}
	else
	{
		Button.Hide();
	}
}

function OnRowButton(UIButton Button)
{
	local int Row;

	Row = RowButtons.Find(Button);
	if (Row > 0)
	{
		class'CoopLobby'.static.HostAssign(Row, class'CoopLobby'.static.NextSlot(Row));
		Refresh();
	}
}

function OnButtonClicked(UIButton Button)
{
	local bool bScenario;

	bScenario = (InitMode == class'CoopLobby'.const.MODE_SCENARIO);
	switch (Button.MCName)
	{
	case 'CoopLobbyHost':
		class'CoopLobby'.static.HostLobby(InitMode);
		break;
	case 'CoopLobbyJoin':
		class'CoopMenu'.static.OpenJoinDialog();
		break;
	case 'CoopLobbyStartA':
		Start(bScenario ? "early" : "new");
		return;
	case 'CoopLobbyStartB':
		Start(bScenario ? "mid" : "load");
		return;
	case 'CoopLobbyStartC':
		Start("late");
		return;
	case 'CoopLobbyClose':
		Leave();
		return;
	}
	Refresh();
}

// A scenario travels at once; a campaign goes through the game's difficulty or load screen, opened on top of the
// lobby, so backing out of it comes back here (and the lobby's friends stay connected meanwhile).
function Start(string Arg)
{
	if (InitMode == class'CoopLobby'.const.MODE_SCENARIO)
	{
		ClearTimer(nameof(Refresh));
		CloseScreen();
	}
	class'CoopLobby'.static.HostStart(Arg);
}

function Leave()
{
	if (Role() == 1)
	{
		class'CoopLobby'.static.HostCloseLobby();
	}
	else if (Role() == 2)
	{
		class'CoopLobby'.static.GuestLeave();
	}
	ClearTimer(nameof(Refresh));
	CloseScreen();
}

// the bot's "@lobbylog": the rows as the player sees them
function LogRows()
{
	local int i;

	for (i = 0; i < ROWS; i++)
	{
		`log("lobby row" @ i $ ":" @ RowLine(i),, 'CoopLobby');
	}
}

simulated function bool OnUnrealCommand(int cmd, int arg)
{
	if (!CheckInputIsReleaseOrDirectionRepeat(cmd, arg))
	{
		return false;
	}
	switch (cmd)
	{
	case class'UIUtilities_Input'.const.FXS_BUTTON_B:
	case class'UIUtilities_Input'.const.FXS_KEY_ESCAPE:
	case class'UIUtilities_Input'.const.FXS_R_MOUSE_DOWN:
		Leave();
		return true;
	}
	return super.OnUnrealCommand(cmd, arg);
}

defaultproperties
{
	InputState = eInputState_Consume;
	bConsumeMouseEvents = true;
}

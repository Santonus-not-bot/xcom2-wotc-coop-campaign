//---------------------------------------------------------------------------------------
//  FILE:    CoopStatusPanel.uc
//  PURPOSE: One line of co-op status (CoopMenu.StatusText) on the main menu and the Avenger,
//           refreshed every second; empty when there is nothing to say.
//           On the Avenger HUD it also adds the "Chat" button once a connection is open: the HUD
//           is built before the host presses "Host co-op", so a button added only when the HUD
//           opens never appeared on the host.
//---------------------------------------------------------------------------------------
class CoopStatusPanel extends UIPanel;

var UIText Line;
var string Shown;

simulated function CoopStatusPanel InitStatus()
{
	InitPanel('CoopStatusPanel');
	Line = Spawn(class'UIText', self);
	Line.InitText('CoopStatusText', "");
	Line.SetWidth(700);
	Refresh();
	SetTimer(1.0f, true, nameof(Refresh));
	return self;
}

function Refresh()
{
	local string S;

	// on the Avenger the co-op player panel (CoopHUDScreen) says it all; the line stays on the main menu
	S = UIAvengerHUD(Screen) != none ? "" : class'CoopMenu'.static.StatusText();
	if (S != Shown)
	{
		Shown = S;
		Line.SetText(S);
		`log("status:" @ (S == "" ? "(none)" : S),, 'CoopMenu');
	}
	EnsureChatButton();
	// "Host co-op" did nothing once hosting (two-PC play test 2026-11-19: hosted from the console, the button stayed)
	if (class'CoopMenu'.static.IsHosting() && Screen.GetChildByName('CoopHostButton', false) != none
		&& Screen.GetChildByName('CoopHostButton', false).bIsVisible)
	{
		Screen.GetChildByName('CoopHostButton', false).Hide();
		`log("host button hidden: already hosting",, 'CoopMenu');
	}
}

function EnsureChatButton()
{
	local UIButton Button;

	if (UIAvengerHUD(Screen) == none || !class'CoopSession'.static.IsConnected() || Screen.GetChildByName('CoopChatButton', false) != none)
	{
		return;
	}
	class'CoopChat'.static.Init();
	Button = Screen.Spawn(class'UIButton', Screen);
	Button.InitButton('CoopChatButton', "Chat", OnChatClicked);
	Button.AnchorTopRight();
	Button.SetPosition(-120, 130);
	`log("chat button added",, 'CoopMenu');
}

function OnChatClicked(UIButton Button)
{
	class'CoopChat'.static.OpenInput();
}

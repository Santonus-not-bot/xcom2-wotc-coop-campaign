//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopMenu.uc
//  PURPOSE: The player-facing co-op buttons (CoopMenu does the work):
//             main menu (UIShell and subclasses): "Join co-op" and the status line;
//             Avenger HUD: "Host co-op" while not hosting and not a guest, and the status line.
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopMenu extends UIScreenListener;

event OnInit(UIScreen Screen)
{
	local UIButton Button;

	if (UIShell(Screen) != none)
	{
		Button = Screen.Spawn(class'UIButton', Screen);
		Button.InitButton('CoopJoinButton', "Join co-op", OnJoinClicked);
		Button.AnchorBottomLeft();
		Button.SetPosition(40, -110);
		AddStatus(Screen, 40, -70, true);
	}
	else if (UIAvengerHUD(Screen) != none)
	{
		class'CoopLink'.static.HostLoadedGame("the Avenger");    // a co-op campaign's save: host again
		if (!class'CoopRole'.static.IsGuest() && !class'CoopMenu'.static.IsHosting())
		{
			Button = Screen.Spawn(class'UIButton', Screen);
			Button.InitButton('CoopHostButton', "Host co-op", OnHostClicked);
			Button.AnchorTopRight();
			Button.SetPosition(-160, 170);
		}
		AddStatus(Screen, -720, 210, false);
	}
}

function AddStatus(UIScreen Screen, float X, float Y, bool bBottomLeft)
{
	local CoopStatusPanel Status;

	Status = Screen.Spawn(class'CoopStatusPanel', Screen).InitStatus();
	if (bBottomLeft)
	{
		Status.AnchorBottomLeft();
	}
	else
	{
		Status.AnchorTopRight();
	}
	Status.SetPosition(X, Y);
}

function OnJoinClicked(UIButton Button)
{
	class'CoopMenu'.static.OpenJoinDialog();
}

function OnHostClicked(UIButton Button)
{
	class'CoopMenu'.static.HostFromAvenger();
	Button.Hide();
}

defaultproperties
{
	ScreenClass = none;
}

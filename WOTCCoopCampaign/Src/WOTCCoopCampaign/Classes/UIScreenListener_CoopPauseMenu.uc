//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopPauseMenu.uc
//  PURPOSE: The pause menu pauses only when not IsMultiplayerGame() (UIPauseMenu.InitScreen);
//           in a co-op campaign it pauses as in single player (CoopRules). Closing it unpauses
//           in the base code either way. A paused copy keeps receiving network data.
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopPauseMenu extends UIScreenListener;

event OnInit(UIScreen Screen)
{
	if (UIShellStrategy(Screen) == none && class'CoopRules'.static.CoopMP())
	{
		Screen.PC.SetPause(true);
		`log("pause menu: paused (co-op campaign)",, 'CoopRules');
	}
}

defaultproperties
{
	ScreenClass = class'UIPauseMenu';
}

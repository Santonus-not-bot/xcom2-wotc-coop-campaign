//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopHUD.uc
//  PURPOSE: Adds the co-op HUD layer (CoopHUDScreen) on each map once a co-op session is on.
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopHUD extends UIScreenListener;

event OnInit(UIScreen Screen)
{
	if (class'CoopHUDScreen'.default.bHideDebugRedScreens)
	{
		`XENGINE.TemporarilyDisableRedscreens();
	}
	if (CoopHUDScreen(Screen) == none && class'CoopRole'.static.CoopActive())
	{
		class'CoopHUDScreen'.static.Ensure();
	}
}

defaultproperties
{
	ScreenClass = none;
}

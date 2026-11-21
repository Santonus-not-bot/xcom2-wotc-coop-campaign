//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopLink.uc
//  PURPOSE: A map change destroys CoopLinkTimer; restart it on the next map's first screen while
//           CoopLink still needs it (a guest the engine sent back to the main menu keeps reconnecting).
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopLink extends UIScreenListener;

event OnInit(UIScreen Screen)
{
	if (class'CoopLink'.static.NeedsTimer())
	{
		class'CoopLinkTimer'.static.Ensure();
	}
}

defaultproperties
{
	ScreenClass = none;
}

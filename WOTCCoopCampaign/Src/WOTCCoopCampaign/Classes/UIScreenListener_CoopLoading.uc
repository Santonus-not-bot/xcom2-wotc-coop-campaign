//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopLoading.uc
//  PURPOSE: Keeps the guest's mission loading screen (CoopMissionLoading) on top: on each new map and whenever
//           another screen opens while a mission launch is under way.
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopLoading extends UIScreenListener;

event OnInit(UIScreen Screen)
{
	if (CoopLoadingScreen(Screen) == none && class'CoopMissionLoading'.default.bActive)
	{
		class'CoopMissionLoading'.static.Show();
	}
}

defaultproperties
{
	ScreenClass = none;
}

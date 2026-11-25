//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopBalanced.uc
//  PURPOSE: Balanced co-op campaign: when the host opens a mission (the screen before squad select) and again when
//           squad select opens, the mission's squad size and enemies are set for the number of players
//           (CoopBalanced.ApplyToMission). Again on squad select because the mission screen re-picks the enemies
//           whenever their alert level is not the normal one (UIMission.UpdateSelectedMissionData).
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopBalanced extends UIScreenListener;

event OnInit(UIScreen Screen)
{
	local XComGameState_MissionSite Mission;

	if (!class'CoopBalanced'.static.IsBalanced() || class'CoopRole'.static.IsGuest())
	{
		return;
	}
	if (UIMission(Screen) != none)
	{
		Mission = XComGameState_MissionSite(`XCOMHISTORY.GetGameStateForObjectID(UIMission(Screen).MissionRef.ObjectID));
		class'CoopBalanced'.static.ApplyToMission(Mission, "mission screen");
	}
	else if (UISquadSelect(Screen) != none)
	{
		Mission = XComGameState_MissionSite(`XCOMHISTORY.GetGameStateForObjectID(`XCOMHQ.MissionRef.ObjectID));
		class'CoopBalanced'.static.ApplyToMission(Mission, "squad select");
	}
}

defaultproperties
{
	ScreenClass = none
}

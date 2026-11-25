//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopDifficulty.uc
//  PURPOSE: The game's difficulty screen opened for a new co-op campaign (CoopNewCampaign.Choose, from the lobby): the
//           tutorial is switched off and its checkbox locked. With the tutorial on, the screen loads the tutorial's
//           own save and builds the campaign only after that mission, so the campaign never became co-op and the
//           lobby's friends were left behind (lobbynewreal 2026-11-25: a fresh profile has the tutorial ticked).
//           The "play without the tutorial?" notice is marked as shown too: accepting it would turn the tutorial on.
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopDifficulty extends UIScreenListener;

event OnInit(UIScreen Screen)
{
	local UIShellDifficulty Difficulty;

	Difficulty = UIShellDifficulty(Screen);
	if (Difficulty == none || Difficulty.m_bIsPlayingGame || !class'CoopNewCampaign'.static.IsChosen())
	{
		return;
	}
	Difficulty.m_bControlledStart = false;
	Difficulty.m_bShowedFirstTimeTutorialNotice = true;
	if (Difficulty.m_TutorialMechaItem != none && Difficulty.m_TutorialMechaItem.Checkbox != none)
	{
		Difficulty.m_TutorialMechaItem.Checkbox.SetChecked(false, false);
		Difficulty.m_TutorialMechaItem.Checkbox.SetReadOnly(true);
	}
	`log("difficulty screen: co-op campaign: tutorial off",, 'CoopMenu');
}

defaultproperties
{
	ScreenClass = class'UIShellDifficulty'
}

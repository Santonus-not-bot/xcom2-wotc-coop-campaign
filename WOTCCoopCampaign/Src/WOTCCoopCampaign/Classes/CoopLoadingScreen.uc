//---------------------------------------------------------------------------------------
//  FILE:    CoopLoadingScreen.uc
//  PURPOSE: The guest's "the host is launching a mission" screen (CoopMissionLoading has the state): the whole
//           screen dimmed, the mission's name, the three steps with the current one marked, and the time waited.
//           Its dimmed backdrop takes the mouse, so the menu under it is not clicked by mistake; a click hides it
//           (the guest still reconnects and loads the mission by itself). Closes itself when the loading is done.
//           Loaded into the 2D movie (CoopMissionLoading.Show), not on the screen stack.
//---------------------------------------------------------------------------------------
class CoopLoadingScreen extends UIScreen;

const BOX_X = 420;
const BOX_Y = 300;
const BOX_W = 1080;
const BOX_H = 470;

var UIPanel Fill;
var UIBGBox BG;
var UIText Title, Mission, Steps, Waited, Hint;
var int Tick;
var int ShotStep;   // the step of the last test screenshot (bLoadingTestShots)
var int StepSeenAt; // Tick when the current step was first drawn
var int LastStep;
var bool bReplaced; // taken down to be pushed again on top (CoopMissionLoading.Show)

simulated function InitScreen(XComPlayerController InitController, UIMovie InitMovie, optional name InitName)
{
	super.InitScreen(InitController, InitMovie, InitName);

	Fill = Spawn(class'UIPanel', self).InitPanel('CoopLoadingFill', class'UIUtilities_Controls'.const.MC_GenericPixel);
	Fill.SetPosition(0, 0);
	Fill.SetSize(class'UIMovie'.default.UI_RES_X, class'UIMovie'.default.UI_RES_Y);
	Fill.SetColor("000000");
	Fill.SetAlpha(88);
	Fill.ProcessMouseEvents(OnFillMouse);    // takes the clicks (the menu under it is not for now); does not hide

	BG = Spawn(class'UIBGBox', self);
	BG.InitBG('CoopLoadingBox', BOX_X, BOX_Y, BOX_W, BOX_H, eUIState_Normal);

	Title = AddText('CoopLoadingTitle', 30);
	Mission = AddText('CoopLoadingMission', 92);
	Steps = AddText('CoopLoadingSteps', 170);
	Waited = AddText('CoopLoadingWaited', 330);
	Hint = AddText('CoopLoadingHint', 390);

	Title.SetHTMLText(Centered(class'CoopMissionLoading'.static.Title(), 34, "9ACBCB", true));
	Hint.SetHTMLText(Centered(class'CoopMissionLoading'.default.bReturn ? "You rejoin the Avenger automatically."
		: "You join the mission automatically.", 18, "828282", false));
	Refresh();
	SetTimer(0.5f, true, nameof(Refresh));
	`log("loading screen up: step" @ class'CoopMissionLoading'.default.Step,, 'CoopLoading');
}

simulated function UIText AddText(name TextName, float Y)
{
	local UIText T;

	T = Spawn(class'UIText', self);
	T.InitText(TextName, "");
	T.SetPosition(BOX_X, BOX_Y + Y);
	T.SetWidth(BOX_W);
	return T;
}

static function string Centered(string Text, int Size, string HexColor, bool bBold)
{
	return "<p align='CENTER'><font size='" $ Size $ "' color='#" $ HexColor $ "'>" $ (bBold ? "<b>" : "") $ Text
		$ (bBold ? "</b>" : "") $ "</font></p>";
}

simulated function Refresh()
{
	local string S, Line, Dots;
	local int i, Step, Seconds;

	if (bReplaced)
	{
		ClearTimer(nameof(Refresh));
		return;
	}
	if (!class'CoopMissionLoading'.default.bActive)
	{
		ClearTimer(nameof(Refresh));
		`log("loading screen closed: the guest is in the mission or stopped waiting",, 'CoopLoading');
		Remove();
		return;
	}
	Tick++;
	if (Tick % 10 == 1)
	{
		`log("loading screen: visible=" $ bIsVisible @ "inited=" $ bIsInited @ "movieVisible=" $ Movie.bIsVisible
			@ "cinematic=" $ (Movie.Stack != none && Movie.Stack.bCinematicMode) @ "alpha=" $ Alpha @ "map=" $ WorldInfo.GetMapName(),, 'CoopLoading');
	}
	Dots = Left("...", Tick % 4);
	Mission.SetHTMLText(Centered(class'CoopMissionLoading'.default.MissionName != "" ? class'CoopMissionLoading'.default.MissionName
		: (class'CoopMissionLoading'.default.bReturn ? "Mission complete" : "Mission"),
		28, "FFFFFF", true));
	Step = class'CoopMissionLoading'.default.Step;
	for (i = 1; i <= 3; i++)
	{
		Line = class'CoopMissionLoading'.static.StepText(i);
		if (i < Step)
		{
			Line = "<font color='#53B45E'>DONE  " $ Line $ "</font>";
		}
		else if (i == Step)
		{
			if (i == class'CoopMissionLoading'.const.STEP_BUILDING && class'CoopMissionLoading'.default.Attempts > 1)
			{
				Line $= " (reconnect attempt" @ class'CoopMissionLoading'.default.Attempts $ ")";
			}
			Line = "<font color='#9ACBCB'><b>&gt;  " $ Line $ Dots $ "</b></font>";
		}
		else
		{
			Line = "<font color='#828282'>" $ Line $ "</font>";
		}
		S $= (S == "" ? "" : "<br/>") $ Line;
	}
	Steps.SetHTMLText("<p align='CENTER'><font size='22'>" $ S $ "</font></p>");
	if (Step != LastStep)
	{
		LastStep = Step;
		StepSeenAt = Tick;
	}
	// after the screen's fade-in (3 s) and a second on the step
	if (class'CoopMissionLoading'.default.bLoadingTestShots && Step != ShotStep && Tick >= 6 && Tick - StepSeenAt >= 2)
	{
		ShotStep = Step;
		`log("loading screen test shot: step" @ Step @ "map" @ WorldInfo.GetMapName(),, 'CoopLoading');
		PC.ConsoleCommand("shot");
	}
	Seconds = class'CoopMissionLoading'.static.ElapsedSeconds();
	Waited.SetHTMLText(Centered("Waiting " $ (Seconds / 60) $ ":" $ (Seconds % 60 < 10 ? "0" : "") $ (Seconds % 60), 20, "BFBFBF", false));
}

// Clicks are swallowed, not used to hide it: hidden on the main menu a guest returns to, nothing was left on screen
// (that menu shows no UI of its own then) and the game looked frozen (two-PC play test 2026-11-19).
simulated function OnFillMouse(UIPanel Panel, int Cmd)
{
}

defaultproperties
{
	InputState = eInputState_None;
	bHideOnLoseFocus = false;
	// the main menu after a guest leaves the Avenger plays the shell's intro cinematic: the stack is in cinematic
	// mode and every screen without this hides (UIScreen.Show); the game's red screens set it too
	bShowDuringCinematic = true;
}

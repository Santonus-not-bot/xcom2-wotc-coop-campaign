//---------------------------------------------------------------------------------------
//  FILE:    CoopMissionLoading.uc
//  PURPOSE: Guest side of a mission launch, as something the player can see. When the host launches a mission it
//           closes the connection while the mission is built (CoopLink explains why), the guest leaves the Avenger
//           for the main menu, reconnects and loads the mission from there: half a minute to a few minutes in
//           which the guest used to see the main menu with one line of text. From the host's "CoopMissionBuilding"
//           until the guest watches the mission, CoopLoadingScreen covers every screen with the mission's name and
//           the step the guest is at. The state lives in class defaults, which survive the map changes.
//           A plain Object.
//---------------------------------------------------------------------------------------
class CoopMissionLoading extends Object config(CoopCampaign);

const STEP_BUILDING = 1;   // the host builds the mission; the guest waits and reconnects
const STEP_JOINING = 2;    // the host took the guest back; the mission's data is on its way
const STEP_LOADING = 3;    // the guest loads the mission map
const GIVE_UP_SECONDS = 1200;

var config bool bActive;
var config bool bReturn;    // the way back to the Avenger after a mission ("CoopMissionReturning"), not a launch
var config string MissionName;
var config int Step;
var config int StartedAt;   // seconds of the day (wall clock: map changes reset the game's own clocks)
var config int Attempts;    // connection attempts while the host builds
var config int AckedAt;     // the guest acknowledged the mission history (clock seconds; 0 = not yet)
var config bool bLoadingTestShots;
var config bool bPushing;          // runtime: Show is pushing the overlay   // test hook: CoopLoadingScreen takes a screenshot on each step and map

static function int ClockSeconds()
{
	local int Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec;

	class'WorldInfo'.static.GetWorldInfo().GetSystemTime(Year, Month, DayOfWeek, Day, Hour, Min, Sec, MSec);
	return Hour * 3600 + Min * 60 + Sec;
}

static function int ElapsedSeconds()
{
	local int Seconds;

	Seconds = ClockSeconds() - default.StartedAt;
	return Seconds < 0 ? Seconds + 86400 : Seconds;    // past midnight
}

// Guest: the host announced the launch ("CoopMissionBuilding", with the mission's name since 2026-11-18).
static function Begin(string Name, optional bool bBackToAvenger)
{
	if (!class'CoopRole'.static.IsGuest())
	{
		return;
	}
	default.bActive = true;
	default.bReturn = bBackToAvenger;
	default.MissionName = Name;
	default.Step = STEP_BUILDING;
	default.Attempts = 0;
	default.AckedAt = 0;
	default.StartedAt = ClockSeconds();
	if (bBackToAvenger)
	{
		`log("mission loading: begin (back to the Avenger)",, 'CoopLoading');
	}
	else
	{
		`log("mission loading: begin" @ (Name == "" ? "(no name)" : Name),, 'CoopLoading');
	}
	Show();
}

// Test hook (@loadtest): the screen on this map without a launch, on any machine.
static function TestBegin()
{
	default.bActive = true;
	default.bReturn = false;
	default.MissionName = "Operation Test - Loading Screen";
	default.Step = STEP_BUILDING;
	default.Attempts = 3;
	default.StartedAt = ClockSeconds();
	`log("mission loading: test begin on" @ class'WorldInfo'.static.GetWorldInfo().GetMapName(),, 'CoopLoading');
	Show();
}

// CoopLink.Tick: the mission history arrived and was acknowledged, but the host's "load the map" did not follow.
static function CheckLoadOverdue()
{
	local int Waited;

	if (!default.bActive || default.bReturn || default.AckedAt == 0 || class'CoopSession'.static.InTactical())
	{
		return;
	}
	Waited = ClockSeconds() - default.AckedAt;
	if (Waited < 0)
	{
		Waited += 86400;
	}
	if (Waited >= 20)
	{
		default.AckedAt = 0;
		`log("mission loading: no load command" @ Waited @ "s after the mission arrived: loading it",, 'CoopLoading');
		class'CoopTacticalNet'.static.LoadMissionAsWatcher();
	}
}

static function bool MapSettled()
{
	return !class'XComEngine'.static.IsLoadingMoviePlaying() && class'WorldInfo'.static.GetWorldInfo().RealTimeSeconds >= 3;
}

static function Advance(int NewStep, string Why)
{
	if (!default.bActive || NewStep <= default.Step)
	{
		return;
	}
	default.Step = NewStep;
	`log("mission loading: step" @ NewStep @ "(" $ Why $ ") after" @ ElapsedSeconds() @ "s",, 'CoopLoading');
}

static function NoteAttempt()
{
	if (default.bActive && default.Step == STEP_BUILDING)
	{
		default.Attempts++;
	}
}

static function End(string Why)
{
	if (!default.bActive)
	{
		return;
	}
	default.bActive = false;
	`log("mission loading: end (" $ Why $ ") after" @ ElapsedSeconds() @ "s",, 'CoopLoading');
}

// The overlay on this map (UIScreenListener_CoopLoading calls this for every new screen): loaded once per map
// into the 2D movie, as CoopHUDScreen is, not pushed on the screen stack. Pushed on the stack it never showed in
// the screenshots (loadshow 2026-11-18: neither on the Avenger nor on the main menu, while CoopHUDScreen, loaded
// this way, did), and a screen of ours on the stack kept a mission map's loading screen up for minutes. Not on a
// mission map: the game's own loading screen covers the map load there.
static function Show()
{
	local XComPresentationLayerBase Pres;
	local CoopLoadingScreen Overlay;
	local UIMovie Movie;

	if (!default.bActive || class'CoopSession'.static.InTactical())
	{
		return;
	}
	if (ElapsedSeconds() > GIVE_UP_SECONDS)
	{
		End("gave up after" @ GIVE_UP_SECONDS @ "s");
		return;
	}
	Pres = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres;
	// not before the presentation layer is ready: a screen loaded earlier never shows (the game's own red screens
	// wait for this too, XComPresentationLayerBase.UIRedScreen); CoopLink's timer calls again every second
	if (Pres == none || Pres.Get2DMovie() == none || !Pres.Get2DMovie().bIsInited || !Pres.IsPresentationLayerReady())
	{
		return;
	}
	// nor while the map's loading movie still plays, nor in its first seconds: loaded within a second of the main
	// menu's load (the movie "1080_LoadingScreen_XCOM_3" still on), it never showed; loaded later on the same main
	// menu (overlaytest 2026-11-19) it did
	if (!MapSettled())
	{
		return;
	}
	foreach class'WorldInfo'.static.GetWorldInfo().AllActors(class'CoopLoadingScreen', Overlay)
	{
		return;
	}
	// the modal movie (the game's system dialogs; drawn above the rest) when there is one: on the main menu a guest
	// returns to after leaving the Avenger the overlay never showed in the 2D movie (loadshow 2026-11-19)
	Movie = Pres.GetModalMovie();
	if (Movie == none || !Movie.bIsInited)
	{
		Movie = Pres.Get2DMovie();
	}
	Overlay = Pres.Spawn(class'CoopLoadingScreen', Pres);
	Overlay.InitScreen(XComPlayerController(Pres.Owner), Movie);
	Movie.LoadScreen(Overlay);
	`log("mission loading: overlay shown on" @ class'WorldInfo'.static.GetWorldInfo().GetMapName() @ "step" @ default.Step
		@ (Movie == Pres.Get2DMovie() ? "(2D movie)" : "(modal movie)"),, 'CoopLoading');
}

// The top screen, not counting mouse guards and the game's debug red screens (they come and go on their own).
static function UIScreen TopScreen(UIScreenStack Stack)
{
	local int i;

	for (i = 0; i < Stack.Screens.Length; i++)
	{
		if (Stack.Screens[i] != none && UIMouseGuard(Stack.Screens[i]) == none && UIRedScreen(Stack.Screens[i]) == none)
		{
			return Stack.Screens[i];
		}
	}
	return none;
}

static function string Title()
{
	return default.bReturn ? "THE HOST IS RETURNING TO THE AVENGER" : "THE HOST IS LAUNCHING A MISSION";
}

static function string StepText(int Which)
{
	if (default.bReturn)
	{
		switch (Which)
		{
		case STEP_BUILDING:
			return "The host is loading the Avenger";
		case STEP_JOINING:
			return "Rejoining the host and receiving the campaign";
		case STEP_LOADING:
			return "Loading the Avenger";
		}
		return "";
	}
	switch (Which)
	{
	case STEP_BUILDING:
		return "The host is building the mission";
	case STEP_JOINING:
		return "Rejoining the host and receiving the mission";
	case STEP_LOADING:
		return "Loading the mission map";
	}
	return "";
}

//---------------------------------------------------------------------------------------
//  FILE:    CoopLinkTimer.uc
//  PURPOSE: Runs CoopLink.Tick and SweepNotices every second while CoopLink needs it (from the
//           first host or join on). One per map; a map change destroys it, Ensure spawns a new one.
//---------------------------------------------------------------------------------------
class CoopLinkTimer extends Actor;

static function Ensure()
{
	local WorldInfo WI;
	local CoopLinkTimer Timer;

	// the chunk listener at once, not on the first tick a second later: a guest that connects from an idle main menu
	// can get a chunked send's start before that tick (soakfresh16-20261127-032327: a fresh guest joining a running
	// mission got "CoopChunkBegin" 0.5 s before its first tick, ignored the whole send, and the host waited 90 s)
	class'CoopChunks'.static.Init();
	WI = class'WorldInfo'.static.GetWorldInfo();
	foreach WI.AllActors(class'CoopLinkTimer', Timer)
	{
		return;
	}
	Timer = WI.Spawn(class'CoopLinkTimer');
	Timer.SetTimer(1.0f, true, nameof(Fire));
}

function Fire()
{
	class'CoopLink'.static.Tick();
	class'CoopLink'.static.SweepNotices();
	if (!class'CoopLink'.static.NeedsTimer())
	{
		Destroy();
	}
}

defaultproperties
{
	bAlwaysTick=true    // keeps firing while CoopLink.StartQuietLeave has the world paused
}

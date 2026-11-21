//---------------------------------------------------------------------------------------
//  FILE:    CoopPauseProbe.uc
//  PURPOSE: Test helper: an actor whose timers run while the game is paused (the bot's @tacpause).
//---------------------------------------------------------------------------------------
class CoopPauseProbe extends Actor;

defaultproperties
{
	bAlwaysTick = true
}

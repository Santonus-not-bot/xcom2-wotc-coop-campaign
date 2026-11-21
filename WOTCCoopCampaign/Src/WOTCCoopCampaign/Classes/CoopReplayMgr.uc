//---------------------------------------------------------------------------------------
//  FILE:    CoopReplayMgr.uc
//  PURPOSE: The PvP replay manager (watch the active machine's frames) plus one setter:
//           bInReplay is protectedwrite, and a guest must be "in replay" before the mission's
//           LoadTacticalGame picks its next phase (CoopTacticalRuleset).
//---------------------------------------------------------------------------------------
class CoopReplayMgr extends XComMPReplayMgr;

// The base registers an (empty) ReceiveHistory delegate on the network manager, which outlives maps, and
// clears it only in Destroyed(), which does not run when a map is unloaded. A guest leaving a mission map kept
// the whole mission World alive and the next map load asserted ("World ... not cleaned up by garbage
// collection", UnGame.cpp:3107, chain CoopReplayMgr -> ReceiveHistoryDelegates; run missionend-20261112-175102).
simulated event PostBeginPlay()
{
	super.PostBeginPlay();
	Cleanup();
}

function SetInReplay(bool bValue)
{
	bInReplay = bValue;
}

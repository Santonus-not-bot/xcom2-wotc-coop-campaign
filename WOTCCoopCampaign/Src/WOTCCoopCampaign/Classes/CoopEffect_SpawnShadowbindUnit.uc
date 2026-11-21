//---------------------------------------------------------------------------------------
//  FILE:    CoopEffect_SpawnShadowbindUnit.uc
//  PURPOSE: ModClassOverrides for X2Effect_SpawnShadowbindUnit (CoopRules): the base removes the
//           new shadow's action points in a multiplayer game; in a co-op campaign it keeps them,
//           as in single player.
//---------------------------------------------------------------------------------------
class CoopEffect_SpawnShadowbindUnit extends X2Effect_SpawnShadowbindUnit;

function OnSpawnComplete(const out EffectAppliedData ApplyEffectParameters, StateObjectReference NewUnitRef, XComGameState NewGameState, XComGameState_Effect NewEffectState)
{
	local XComGameState_Unit Shadow;
	local array<name> Points;

	Shadow = XComGameState_Unit(NewGameState.GetGameStateForObjectID(NewUnitRef.ObjectID));
	if (Shadow == none)
	{
		Shadow = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(NewUnitRef.ObjectID));
	}
	if (Shadow != none)
	{
		Points = Shadow.ActionPoints;
	}
	super.OnSpawnComplete(ApplyEffectParameters, NewUnitRef, NewGameState, NewEffectState);
	if (class'CoopRules'.static.CoopMP() && Points.Length > 0)
	{
		Shadow = XComGameState_Unit(NewGameState.GetGameStateForObjectID(NewUnitRef.ObjectID));
		if (Shadow != none)
		{
			Shadow.ActionPoints = Points;
		}
	}
}

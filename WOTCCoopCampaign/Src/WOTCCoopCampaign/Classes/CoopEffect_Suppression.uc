//---------------------------------------------------------------------------------------
//  FILE:    CoopEffect_Suppression.uc
//  PURPOSE: ModClassOverrides for X2Effect_Suppression (CoopRules): in a co-op campaign the
//           single-player aim penalty by side, not MultiplayerTargetAimPenalty.
//---------------------------------------------------------------------------------------
class CoopEffect_Suppression extends X2Effect_Suppression;

function GetToHitModifiers(XComGameState_Effect EffectState, XComGameState_Unit Attacker, XComGameState_Unit Target, XComGameState_Ability AbilityState, class<X2AbilityToHitCalc> ToHitType, bool bMelee, bool bFlanking, bool bIndirectFire, out array<ShotModifierInfo> ShotModifiers)
{
	local ShotModifierInfo ShotMod;

	if (!class'CoopRules'.static.CoopMP())
	{
		super.GetToHitModifiers(EffectState, Attacker, Target, AbilityState, ToHitType, bMelee, bFlanking, bIndirectFire, ShotModifiers);
		return;
	}
	// the single-player branch of the base function
	if (!bIndirectFire)
	{
		ShotMod.ModType = eHit_Success;
		ShotMod.Value = (Attacker.GetTeam() != eTeam_XCom) ? default.SoldierTargetAimPenalty : default.AlienTargetAimPenalty;
		ShotMod.Reason = FriendlyName;
		ShotModifiers.AddItem(ShotMod);
	}
}

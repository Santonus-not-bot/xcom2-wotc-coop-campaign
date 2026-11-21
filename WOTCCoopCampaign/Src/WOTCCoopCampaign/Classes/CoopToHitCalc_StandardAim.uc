//---------------------------------------------------------------------------------------
//  FILE:    CoopToHitCalc_StandardAim.uc
//  PURPOSE: ModClassOverrides for X2AbilityToHitCalc_StandardAim (CoopRules). GetHitChance adds
//           default.MP_FLANKING_CRIT_BONUS for a flanking shot in a multiplayer game and the
//           shooter's eStat_FlankingCritChance otherwise; for the duration of the call the
//           multiplayer value is set to that stat, so the base code gives the single-player result.
//---------------------------------------------------------------------------------------
class CoopToHitCalc_StandardAim extends X2AbilityToHitCalc_StandardAim;

protected function int GetHitChance(XComGameState_Ability kAbility, AvailableTarget kTarget, optional out ShotBreakdown m_ShotBreakdown, optional bool bDebugLog = false)
{
	local XComGameState_Unit Shooter;
	local int Saved, SavedBase, Result;

	if (!class'CoopRules'.static.CoopMP() || kAbility == none)
	{
		return super.GetHitChance(kAbility, kTarget, m_ShotBreakdown, bDebugLog);
	}
	Shooter = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(kAbility.OwnerStateObject.ObjectID));
	if (Shooter == none)
	{
		return super.GetHitChance(kAbility, kTarget, m_ShotBreakdown, bDebugLog);
	}
	Saved = default.MP_FLANKING_CRIT_BONUS;
	SavedBase = class'X2AbilityToHitCalc_StandardAim'.default.MP_FLANKING_CRIT_BONUS;
	default.MP_FLANKING_CRIT_BONUS = int(Shooter.GetCurrentStat(eStat_FlankingCritChance));
	class'X2AbilityToHitCalc_StandardAim'.default.MP_FLANKING_CRIT_BONUS = default.MP_FLANKING_CRIT_BONUS;
	if (!class'CoopRules'.default.bFlankLogged)
	{
		class'CoopRules'.default.bFlankLogged = true;
		`log("co-op hit chance: flank crit from the shooter's stat (" $ default.MP_FLANKING_CRIT_BONUS $ ") instead of" @ Saved,, 'CoopRules');
	}
	Result = super.GetHitChance(kAbility, kTarget, m_ShotBreakdown, bDebugLog);
	default.MP_FLANKING_CRIT_BONUS = Saved;
	class'X2AbilityToHitCalc_StandardAim'.default.MP_FLANKING_CRIT_BONUS = SavedBase;
	return Result;
}

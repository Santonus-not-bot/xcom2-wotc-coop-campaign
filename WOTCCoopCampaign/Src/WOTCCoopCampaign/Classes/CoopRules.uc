//---------------------------------------------------------------------------------------
//  FILE:    CoopRules.uc
//  PURPOSE: While a co-op campaign has its connection open, XComEngine.IsMultiPlayerGame() is
//           true (CoopLink explains why) and some game rules switch to their PvP values. The
//           classes registered in XComEngine.ini put the single-player values back, only then:
//             CoopToHitCalc_StandardAim        flank crit: the shooter's own stat, not MP_FLANKING_CRIT_BONUS
//             CoopEffect_Suppression           suppression aim penalty by side, not the PvP one
//             CoopEffect_SpawnShadowbindUnit   a shadow keeps its action points on the turn it appears
//             UIScreenListener_CoopPauseMenu   the pause menu pauses
//           Quickload stays blocked on purpose: it would rewind the host under the guests' feet.
//---------------------------------------------------------------------------------------
class CoopRules extends Object config(CoopCampaign);

var config bool bFlankLogged;   // config only so the default may be written

// The class override reaches aim objects created with "new", but most abilities share objects that X2Ability
// builds in its defaultproperties (e.g. default.SimpleStandardAim, which StandardShot uses: run
// mission-20261112-232..., "StandardShot=X2AbilityToHitCalc_StandardAim"). After the templates are created, every
// ability's plain X2AbilityToHitCalc_StandardAim is replaced by a CoopToHitCalc_StandardAim with the same
// settings (one replacement per shared object). Subclasses (melee, etc.) are left alone.
static function SwapAimCalcs()
{
	local X2AbilityTemplateManager Mgr;
	local X2DataTemplate DataTemplate;
	local X2AbilityTemplate Template;
	local array<X2AbilityToHitCalc> Originals;
	local array<CoopToHitCalc_StandardAim> Copies;
	local X2AbilityToHitCalc_StandardAim Old;
	local CoopToHitCalc_StandardAim NewCalc;
	local int Idx, Swapped;

	Mgr = class'X2AbilityTemplateManager'.static.GetAbilityTemplateManager();
	foreach Mgr.IterateTemplates(DataTemplate, none)
	{
		Template = X2AbilityTemplate(DataTemplate);
		if (Template == none || Template.AbilityToHitCalc == none || Template.AbilityToHitCalc.Class != class'X2AbilityToHitCalc_StandardAim')
		{
			continue;
		}
		Idx = Originals.Find(Template.AbilityToHitCalc);
		if (Idx == INDEX_NONE)
		{
			Old = X2AbilityToHitCalc_StandardAim(Template.AbilityToHitCalc);
			NewCalc = new class'CoopToHitCalc_StandardAim';
			NewCalc.bIndirectFire = Old.bIndirectFire;
			NewCalc.bMeleeAttack = Old.bMeleeAttack;
			NewCalc.bReactionFire = Old.bReactionFire;
			NewCalc.bAllowCrit = Old.bAllowCrit;
			NewCalc.bHitsAreCrits = Old.bHitsAreCrits;
			NewCalc.bMultiTargetOnly = Old.bMultiTargetOnly;
			NewCalc.bOnlyMultiHitWithSuccess = Old.bOnlyMultiHitWithSuccess;
			NewCalc.bGuaranteedHit = Old.bGuaranteedHit;
			NewCalc.bIgnoreCoverBonus = Old.bIgnoreCoverBonus;
			NewCalc.FinalMultiplier = Old.FinalMultiplier;
			NewCalc.BuiltInHitMod = Old.BuiltInHitMod;
			NewCalc.BuiltInCritMod = Old.BuiltInCritMod;
			NewCalc.HitModifiers = Old.HitModifiers;
			Originals.AddItem(Old);
			Copies.AddItem(NewCalc);
			Idx = Copies.Length - 1;
		}
		Template.AbilityToHitCalc = Copies[Idx];
		Swapped++;
	}
	`log("aim calculations: " $ Swapped @ "abilities now use the co-op version (" $ Copies.Length @ "distinct)",, 'CoopRules');
}

static function bool CoopMP()
{
	return class'Engine'.static.GetEngine().IsMultiPlayerGame() && class'CoopRole'.static.CoopActive();
}

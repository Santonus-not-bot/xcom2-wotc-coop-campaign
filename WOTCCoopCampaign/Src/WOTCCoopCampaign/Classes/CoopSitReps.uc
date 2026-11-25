//---------------------------------------------------------------------------------------
//  FILE:    CoopSitReps.uc
//  PURPOSE: Hidden sitreps for the balanced co-op campaign (CoopBalanced), one per amount:
//             CoopSquadN    adds N squad slots              (effect CoopSquadPlusN)
//             CoopPodsP_A   bigger pods (+P units each) and a higher alert level (+A: more pods)
//           bExcludeFromStrategy keeps them out of the random sitrep rolls and out of the sitrep lists on the
//           mission screen, squad select and the tactical HUD; their effects still apply (the game iterates every
//           name in GeneratedMission.SitReps).
//---------------------------------------------------------------------------------------
class CoopSitReps extends X2SitRep;

static function array<X2DataTemplate> CreateTemplates()
{
	local array<X2DataTemplate> Templates;
	local X2SitRepTemplate Template;
	local int N, P, A;

	for (N = 1; N <= class'CoopSitRepEffects'.const.MAX_SQUAD_PLUS; N++)
	{
		`CREATE_X2TEMPLATE(class'X2SitRepTemplate', Template, name("CoopSquad" $ N));
		Template.PositiveEffects.AddItem(name("CoopSquadPlus" $ N));
		Hide(Template);
		Templates.AddItem(Template);
	}
	for (P = 0; P <= class'CoopSitRepEffects'.const.MAX_ENEMY_PLUS; P++)
	{
		for (A = 0; A <= class'CoopSitRepEffects'.const.MAX_ENEMY_PLUS; A++)
		{
			if (P == 0 && A == 0)
			{
				continue;
			}
			`CREATE_X2TEMPLATE(class'X2SitRepTemplate', Template, name("CoopPods" $ P $ "_" $ A));
			if (P > 0)
			{
				Template.NegativeEffects.AddItem(name("CoopPodPlus" $ P));
			}
			if (A > 0)
			{
				Template.NegativeEffects.AddItem(name("CoopAlertPlus" $ A));
			}
			Template.bNegativeEffect = true;
			Hide(Template);
			Templates.AddItem(Template);
		}
	}
	return Templates;
}

static function Hide(X2SitRepTemplate Template)
{
	Template.bExcludeFromStrategy = true;
	Template.bExcludeFromChallengeMode = true;
}

static function bool IsCoopSitRep(name SitRep)
{
	return Left(string(SitRep), 9) ~= "CoopSquad" || Left(string(SitRep), 8) ~= "CoopPods";
}

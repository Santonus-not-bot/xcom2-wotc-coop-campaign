//---------------------------------------------------------------------------------------
//  FILE:    CoopSitRepEffects.uc
//  PURPOSE: Sitrep effects for the balanced co-op campaign (CoopBalanced). One template per amount, since a
//           template's numbers are fixed once created:
//             CoopSquadPlusN   N = 1..MAX_SQUAD_PLUS  squad slots added (X2SitRepEffect_SquadSize)
//             CoopPodPlusN     N = 1..MAX_ENEMY_PLUS  units added to every alien pod (X2SitRepEffect_ModifyPodSize)
//             CoopAlertPlusN   N = 1..MAX_ENEMY_PLUS  mission alert level raised (X2SitRepEffect_ModifyAlertLevel):
//                                                     a higher alert picks a mission schedule with more pods
//---------------------------------------------------------------------------------------
class CoopSitRepEffects extends X2SitRepEffect;

const MAX_SQUAD_PLUS = 18;    // 4 players x 6 soldiers = 24 = 6 + 18
const MAX_ENEMY_PLUS = 9;

static function array<X2DataTemplate> CreateTemplates()
{
	local array<X2DataTemplate> Templates;
	local X2SitRepEffect_SquadSize Squad;
	local X2SitRepEffect_ModifyPodSize Pod;
	local X2SitRepEffect_ModifyAlertLevel Alert;
	local int N;

	for (N = 1; N <= MAX_SQUAD_PLUS; N++)
	{
		`CREATE_X2TEMPLATE(class'X2SitRepEffect_SquadSize', Squad, name("CoopSquadPlus" $ N));
		Squad.SquadSizeAdjustment = N;
		Templates.AddItem(Squad);
	}
	for (N = 1; N <= MAX_ENEMY_PLUS; N++)
	{
		`CREATE_X2TEMPLATE(class'X2SitRepEffect_ModifyPodSize', Pod, name("CoopPodPlus" $ N));
		Pod.PodSizeDelta = N;
		Templates.AddItem(Pod);

		`CREATE_X2TEMPLATE(class'X2SitRepEffect_ModifyAlertLevel', Alert, name("CoopAlertPlus" $ N));
		Alert.AlertLevelModification = N;
		Templates.AddItem(Alert);
	}
	return Templates;
}

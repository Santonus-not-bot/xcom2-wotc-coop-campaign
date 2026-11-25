//---------------------------------------------------------------------------------------
//  FILE:    CoopBalanced.uc
//  PURPOSE: The balanced co-op campaign (decided by the owner 2026-11-24): a campaign tuned for co-op, chosen when
//           a new campaign starts (XComGameState_CoopCampaign.bBalanced).
//             Squad: every player brings the base game's squad size (4, 5 and 6 with the two squad size
//                    unlocks), so the mission allows that times the number of players. Squad select needs
//                    robojumper's squad select above 6 slots (the vanilla screen draws at most 6).
//             Enemies: per player beyond the first, a higher alert level (AlertPerPlayer: the mission schedules
//                    for higher alert levels have more pods) and bigger pods (PodsPerPlayer more followers in
//                    every regular pod); one follower becomes a unit type new to the mission, rolled
//                    LaterEnemyForceLevel force levels higher. Set in the cached enemy list, which tactical spawns.
//           The host applies it on the mission screen and on squad select (UIScreenListener_CoopBalanced; the bot
//           step @balanceapply): a hidden sitrep for the squad size (CoopSitReps), the enemies in script.
//           The numbers per player are placeholders until the owner tunes them.
//           A plain Object.
//---------------------------------------------------------------------------------------
class CoopBalanced extends Object config(CoopCampaign);

var config int PodsPerPlayer;           // units added to every pod per player beyond the first
var config int AlertPerPlayer;          // alert levels added per player beyond the first (more pods)
var config int LaterEnemyForceLevel;    // the one stronger enemy is rolled this many force levels higher (0 = off)

static function bool IsBalanced()
{
	local XComGameState_CoopCampaign Coop;

	Coop = class'XComGameState_CoopCampaign'.static.Get();
	return Coop != none && Coop.bBalanced;
}

static function int Players()
{
	local XComGameState_CoopCampaign Coop;

	Coop = class'XComGameState_CoopCampaign'.static.Get();
	return (Coop == none) ? 1 : Clamp(Coop.PlayerCount, 1, class'XComGameState_CoopCampaign'.const.MAX_PLAYERS);
}

// Host: mark the campaign as balanced (or not). Only before the first mission: a campaign keeps its rules.
static function bool SetBalanced(bool bOn)
{
	local XComGameState NewGameState;
	local XComGameState_CoopCampaign Coop;

	if (class'CoopRole'.static.IsGuest())
	{
		`log("balanced: only the host decides",, 'CoopBalanced');
		return false;
	}
	if (MissionsPlayed() > 0)
	{
		`log("balanced: refused, the campaign has played" @ MissionsPlayed() @ "missions (chosen at the start only)",, 'CoopBalanced');
		return false;
	}
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop: balanced campaign");
	Coop = class'XComGameState_CoopCampaign'.static.GetForChange(NewGameState);
	Coop.bBalanced = bOn;
	`GAMERULES.SubmitGameState(NewGameState);
	`log("balanced campaign:" @ class'CoopHarness'.static.BoolStr(bOn) @ "players=" $ Coop.PlayerCount,, 'CoopBalanced');
	return true;
}

// Squad slots of the mission without our sitreps (the base game's rules: 4, +1 per squad size unlock, the
// mission's own limits and sitreps).
static function int MissionsPlayed()
{
	local XComGameState_Analytics Analytics;

	Analytics = XComGameState_Analytics(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_Analytics', true));
	return (Analytics == none) ? 0 : int(Analytics.GetFloatValue("BATTLES_WON") + Analytics.GetFloatValue("BATTLES_LOST"));
}

static function int BaseSquad(XComGameState_MissionSite Mission)
{
	return class'X2StrategyGameRulesetDataStructures'.static.GetMaxSoldiersAllowedOnMission(Mission);
}

// The mission's normal alert level (what UIMission.UpdateSelectedMissionData picks enemies with) and force level.
static function int NormalAlert(XComGameState_MissionSite Mission)
{
	return Mission.GetMissionDifficulty();
}

static function int CurrentForceLevel()
{
	local XComGameState_HeadquartersAlien AlienHQ;

	AlienHQ = XComGameState_HeadquartersAlien(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersAlien'));
	return AlienHQ.GetForceLevel();
}

// Host: put the balanced squad size on Mission and pick its enemies for the player count. True if it changed.
// The enemies are set in script, not through sitrep effects: the alert sitrep never reaches enemy picking
// (GetMissionDifficulty ignores sitrep modifiers) and the pod size effect changed nothing (balanced, 2026-11-24).
// Tactical spawns exactly the cached SelectedMissionData; only the mission screen re-picks it, and only when its
// alert or force level differs from the normal one, so this runs again on the mission screen and on squad select.
static function bool ApplyToMission(XComGameState_MissionSite Mission, string Why)
{
	local XComGameState NewGameState;
	local array<name> Wanted, Old;
	local name SitRep;
	local int P, Base, Extra, Pods, Alert, ForceLevel, WantAlert, Added;

	if (Mission == none || !IsBalanced() || class'CoopRole'.static.IsGuest())
	{
		return false;
	}
	P = Players();
	ForceLevel = CurrentForceLevel();
	foreach Mission.GeneratedMission.SitReps(SitRep)
	{
		if (class'CoopSitReps'.static.IsCoopSitRep(SitRep))
		{
			Old.AddItem(SitRep);
		}
	}
	Pods = Clamp(default.PodsPerPlayer * (P - 1), 0, class'CoopSitRepEffects'.const.MAX_ENEMY_PLUS);
	Alert = Clamp(default.AlertPerPlayer * (P - 1), 0, class'CoopSitRepEffects'.const.MAX_ENEMY_PLUS);
	WantAlert = Clamp(NormalAlert(Mission) + Alert, 1, class'X2StrategyGameRulesetDataStructures'.default.MaxMissionDifficulty);

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop: balanced mission");
	Mission = XComGameState_MissionSite(NewGameState.ModifyStateObject(class'XComGameState_MissionSite', Mission.ObjectID));
	foreach Old(SitRep)
	{
		Mission.GeneratedMission.SitReps.RemoveItem(SitRep);
	}
	Base = BaseSquad(Mission);
	Extra = Min(Base * (P - 1), class'CoopSitRepEffects'.const.MAX_SQUAD_PLUS);
	if (Extra > 0)
	{
		Wanted.AddItem(name("CoopSquad" $ Extra));
	}
	// the alert sitrep still raises the battle's alert level in tactical (ModifyPreMissionBattleDataState), which
	// reinforcements read; the pod size effect is left out (GrowPods does it)
	if (Alert > 0)
	{
		Wanted.AddItem(name("CoopPods0_" $ Alert));
	}
	if (SameNames(Old, Wanted) && Mission.SelectedMissionData.SelectedMissionScheduleName != ''
		&& Mission.SelectedMissionData.AlertLevel == WantAlert && Mission.SelectedMissionData.ForceLevel == ForceLevel)
	{
		`XCOMHISTORY.CleanupPendingGameState(NewGameState);
		`log("balanced (" $ Why $ "): mission" @ Mission.ObjectID @ "already set:" @ Join(Wanted) @ "alert=" $ WantAlert,, 'CoopBalanced');
		return false;
	}
	foreach Wanted(SitRep)
	{
		Mission.GeneratedMission.SitReps.AddItem(SitRep);
	}
	// for the log: the enemies at the normal alert level
	Mission.SelectedMissionData.SelectedMissionScheduleName = '';
	Mission.CacheSelectedMissionData(ForceLevel, NormalAlert(Mission));
	LogEncounters(Mission, "before (alert=" $ Mission.SelectedMissionData.AlertLevel $ ")");
	// more pods: pick at a higher alert level (the mission schedules for higher alert levels have more pods)
	Mission.SelectedMissionData.SelectedMissionScheduleName = '';
	Mission.CacheSelectedMissionData(ForceLevel, WantAlert);
	// bigger pods
	Added = (Pods > 0) ? GrowPods(Mission, Pods) : 0;
	if (default.LaterEnemyForceLevel > 0)
	{
		OneLaterEnemy(Mission);
	}
	`GAMERULES.SubmitGameState(NewGameState);
	`log("balanced (" $ Why $ "): mission" @ Mission.ObjectID @ "players=" $ P @ "base squad=" $ Base @ "max squad="
		$ BaseSquad(Mission) @ "sitreps=" $ Join(Wanted) @ "alert=" $ Mission.SelectedMissionData.AlertLevel
		@ "(normal" @ NormalAlert(Mission) $ ") force=" $ Mission.SelectedMissionData.ForceLevel @ "units added=" $ Added,, 'CoopBalanced');
	LogEncounters(Mission, "after");
	return true;
}

// The alien pods the mod may change: regular enemy groups, not the mission's special units (a reward unit, a
// single-unit group such as the Field Commander's).
static function bool IsRegularPod(XComGameState_MissionSite Mission, int i)
{
	return Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.Team == eTeam_Alien
		&& Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.StrategyUnitTag == ''
		&& Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.SelectedCharacterTemplateNames.Length >= 2;
}

// Bigger pods: every regular pod gets Count more of its own last unit (a follower). Returns the units added.
static function int GrowPods(XComGameState_MissionSite Mission, int Count)
{
	local int i, n, Added;
	local name Follower;

	for (i = 0; i < Mission.SelectedMissionData.SelectedEncounters.Length; i++)
	{
		if (!IsRegularPod(Mission, i))
		{
			continue;
		}
		n = Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.SelectedCharacterTemplateNames.Length;
		Follower = Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.SelectedCharacterTemplateNames[n - 1];
		for (n = 0; n < Count; n++)
		{
			Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.SelectedCharacterTemplateNames.AddItem(Follower);
			Added++;
		}
		if (Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.MaxGroupSize > 0)
		{
			Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.MaxGroupSize += Count;
		}
	}
	return Added;
}

// One enemy from a slightly later game stage: roll regular pods again LaterEnemyForceLevel force levels higher and
// take the first unit type the mission does not have yet; it replaces a follower (leaders stay).
static function OneLaterEnemy(XComGameState_MissionSite Mission)
{
	local XComTacticalMissionManager MissionMgr;
	local XComAISpawnManager SpawnMgr;
	local MissionSchedule Schedule;
	local ConfigurableEncounter Encounter;
	local PodSpawnInfo Rolled;
	local array<X2CharacterTemplate> Picked;
	local array<int> Candidates;
	local array<name> Present;
	local float LeaderWeight, FollowerWeight;
	local int i, j, Try, Pick, ForceLevel, LeaderMod, Last;
	local name Before, Unit;

	for (i = 0; i < Mission.SelectedMissionData.SelectedEncounters.Length; i++)
	{
		for (j = 0; j < Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.SelectedCharacterTemplateNames.Length; j++)
		{
			Present.AddItem(Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.SelectedCharacterTemplateNames[j]);
		}
		if (IsRegularPod(Mission, i))
		{
			Candidates.AddItem(i);
		}
	}
	if (Candidates.Length == 0)
	{
		`log("balanced: no regular pod for the later enemy",, 'CoopBalanced');
		return;
	}
	ForceLevel = Min(Mission.SelectedMissionData.ForceLevel + default.LaterEnemyForceLevel, 20);
	MissionMgr = `TACTICALMISSIONMGR;
	SpawnMgr = `SPAWNMGR;
	MissionMgr.GetMissionSchedule(Mission.SelectedMissionData.SelectedMissionScheduleName, Schedule);
	for (Try = 0; Try < 12; Try++)
	{
		Pick = Candidates[`SYNC_RAND_STATIC(Candidates.Length)];
		Encounter.EncounterID = '';
		MissionMgr.GetConfigurableEncounter(Mission.SelectedMissionData.SelectedEncounters[Pick].SelectedEncounterName, Encounter,
			ForceLevel, Mission.SelectedMissionData.AlertLevel, `XCOMHQ);
		if (Encounter.EncounterID == '')
		{
			continue;
		}
		Rolled.SelectedCharacterTemplateNames.Length = 0;
		Picked.Length = 0;
		LeaderWeight = 0;
		FollowerWeight = 0;
		LeaderMod = SpawnMgr.GetLeaderForceLevelMod();
		SpawnMgr.SelectSpawnGroup(Rolled, Mission.GeneratedMission.Mission, Schedule, Mission.GeneratedMission.SitReps, Encounter,
			ForceLevel, Mission.SelectedMissionData.AlertLevel, Picked, LeaderWeight, FollowerWeight, LeaderMod);
		foreach Rolled.SelectedCharacterTemplateNames(Unit)
		{
			if (Present.Find(Unit) != INDEX_NONE)
			{
				continue;
			}
			Last = Mission.SelectedMissionData.SelectedEncounters[Pick].EncounterSpawnInfo.SelectedCharacterTemplateNames.Length - 1;
			Before = Mission.SelectedMissionData.SelectedEncounters[Pick].EncounterSpawnInfo.SelectedCharacterTemplateNames[Last];
			Mission.SelectedMissionData.SelectedEncounters[Pick].EncounterSpawnInfo.SelectedCharacterTemplateNames[Last] = Unit;
			`log("balanced: later enemy in pod" @ Pick @ "(" $ Mission.SelectedMissionData.SelectedEncounters[Pick].SelectedEncounterName $ "):"
				@ Before @ "->" @ Unit @ "(force level" @ ForceLevel $ ", try" @ (Try + 1) $ ")",, 'CoopBalanced');
			return;
		}
	}
	`log("balanced: no unit type new to this mission at force level" @ ForceLevel @ "in 12 rolls",, 'CoopBalanced');
}

static function LogEncounters(XComGameState_MissionSite Mission, string When)
{
	local int i, Units, Pods;
	local string Line;

	for (i = 0; i < Mission.SelectedMissionData.SelectedEncounters.Length; i++)
	{
		if (Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.Team != eTeam_Alien)
		{
			continue;
		}
		Pods++;
		Units += Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.SelectedCharacterTemplateNames.Length;
		Line $= (Line == "" ? "" : " | ") $ JoinNames(Mission.SelectedMissionData.SelectedEncounters[i].EncounterSpawnInfo.SelectedCharacterTemplateNames);
	}
	`log("balanced: mission" @ Mission.ObjectID @ When $ ": alien pods=" $ Pods @ "units=" $ Units @ "schedule="
		$ Mission.SelectedMissionData.SelectedMissionScheduleName @ "[" $ Line $ "]",, 'CoopBalanced');
}

// The mission the bot's @launch would pick (CoopExperiments.LaunchFirstMission).
static function XComGameState_MissionSite LaunchableMission(optional name Source)
{
	local XComGameState_MissionSite Mission;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_MissionSite', Mission)
	{
		if (Source != '' && Mission.Source != Source)
		{
			continue;
		}
		if (Mission.Available && (Source != '' || Mission.Source != 'MissionSource_Final')
			&& (Mission.GetMissionSource().bRequiresSkyrangerTravel || Source != ''))
		{
			return Mission;
		}
	}
	`log("balanced: no launchable mission",, 'CoopBalanced');
	return none;
}

// Tactical: the alien units on the map now (the bot step @aliens).
static function LogAliens()
{
	local XComGameState_Unit Unit;
	local int Count;
	local string Line;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (Unit.GetTeam() == eTeam_Alien && Unit.IsAlive() && !Unit.bRemovedFromPlay)
		{
			Count++;
			Line $= (Line == "" ? "" : ",") $ string(Unit.GetMyTemplateName());
		}
	}
	`log("balanced: aliens on the map=" $ Count @ "[" $ Line $ "]",, 'CoopBalanced');
}

static function bool SameNames(array<name> A, array<name> B)
{
	local name N;

	if (A.Length != B.Length)
	{
		return false;
	}
	foreach A(N)
	{
		if (B.Find(N) == INDEX_NONE)
		{
			return false;
		}
	}
	return true;
}

static function string Join(array<name> Names)
{
	return (Names.Length == 0) ? "none" : JoinNames(Names);
}

static function string JoinNames(array<name> Names)
{
	local string Out;
	local name N;

	foreach Names(N)
	{
		Out $= (Out == "" ? "" : ",") $ string(N);
	}
	return Out;
}

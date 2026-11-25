//---------------------------------------------------------------------------------------
//  FILE:    CoopScenario.uc
//  PURPOSE: Scenario mode, first version: one co-op mission without a campaign (design: DESIGN-campaign-coop.md,
//           "Scenario mode"). The host picks a game stage and the number of players in the main menu; this builds
//           the mission the way War of the Chosen's Skirmish mode does (UITLE_SkirmishModeMenu: a tactical-only
//           history with a mission site in a random region, enemies from the challenge templates) and starts it.
//             Squad: 12 operators, XCOM soldiers of the base classes (ChallengeSoldiers_RandomVanilla), split
//                    evenly among the players in blocks (owner tags, as the campaign's ownership).
//             Stage: early / mid / late sets the force level, the alert level, the operators' rank (abilities picked
//                    as the challenge modes do) and the gear tier (conventional + Kevlar / magnetic + Predator /
//                    beam + Warden, the challenge modes' selectors), utility items by the standard selector.
//             Co-op: the start state carries the co-op data (XComGameState_CoopCampaign with bScenario), so the
//                    co-op rules and turns run; the server opens at the host's first unit actions
//                    (CoopLink.HostMissionReady) and players join from the main menu's "Join a friend".
//             End:   the host tells the guests the scenario is over ("CoopScenarioOver"); everyone goes back to
//                    the main menu (the game's own path for a skirmish).
//           Not in this version: the point budget and operator shop, objective sets, saved operators, difficulty
//           modifiers (all in the design, numbers not decided yet).
//---------------------------------------------------------------------------------------
class CoopScenario extends Object config(CoopCampaign);

const STAGE_EARLY = 0;
const STAGE_MID = 1;
const STAGE_LATE = 2;
const OPERATORS = 12;

var config array<int> StageForceLevel;      // by stage
var config array<int> StageAlertLevel;      // by stage
var config array<int> StageRanks;           // ranks above rookie, by stage
var config array<name> StagePrimary;        // challenge selector names by stage
var config array<name> StageSecondary;
var config array<name> StageArmor;
var config name ClassSelector;
var config name UtilitySelector;
var config name EnemySelector;
var config float WaitForPlayersSeconds;    // host: the first turn waits this long at most for the players to load in

// runtime (config only so the default may be written)
var config array<int> SeenLoading;         // host, waiting for players: slots seen loading the mission map

static function string StageName(int Stage)
{
	switch (Stage)
	{
	case STAGE_EARLY: return "early";
	case STAGE_MID: return "mid";
	case STAGE_LATE: return "late";
	}
	return "stage" @ Stage;
}

static function int Pick(array<int> Values, int Stage, int Fallback)
{
	return (Stage >= 0 && Stage < Values.Length) ? Values[Stage] : Fallback;
}

static function name PickName(array<name> Values, int Stage)
{
	return (Stage >= 0 && Stage < Values.Length) ? Values[Stage] : '';
}

static function X2ChallengeTemplate Challenge(name TemplateName)
{
	if (TemplateName == '')
	{
		return none;
	}
	return class'X2ChallengeTemplateManager'.static.GetChallengeTemplateManager().FindChallengeTemplate(TemplateName);
}

// Build the scenario's start state and travel to its map. Host only (the machine that starts it hosts it).
static function bool Start(int Stage, int Players)
{
	local XComGameStateHistory History;
	local XComTacticalMissionManager MissionMgr;
	local XComParcelManager ParcelMgr;
	local XComGameStateContext_TacticalGameRule StartContext;
	local XComGameState StartState;
	local XComGameState_BattleData Battle;
	local XComGameState_Player XComPlayer, Player;
	local XComGameState_CampaignSettings Settings;
	local XComGameState_HeadquartersXCom HQ;
	local XComGameState_Analytics Analytics;
	local XComGameState_MissionSite Site;
	local XComGameState_CoopCampaign Coop;
	local X2ChallengeEnemyForces Enemies;
	local MissionDefinition MissionDef;
	local PlotDefinition Plot;
	local PlotTypeDefinition PlotType;
	local array<string> Biomes;
	local array<PlotDefinition> Plots;
	local array<name> MissionNames;
	local array<XComGameState_Unit> Squad;
	local array<name> Classes;
	local XComOnlineEventMgr EventMgr;
	local int i, ForceLevel, AlertLevel;
	local string MissionType;

	Players = Clamp(Players, 1, class'XComGameState_CoopCampaign'.const.MAX_PLAYERS);
	Stage = Clamp(Stage, STAGE_EARLY, STAGE_LATE);
	ForceLevel = Pick(default.StageForceLevel, Stage, 3);
	AlertLevel = Pick(default.StageAlertLevel, Stage, 2);
	MissionMgr = `TACTICALMISSIONMGR;
	ParcelMgr = `PARCELMGR;
	History = `XCOMHISTORY;
	History.ResetHistory(, false);

	StartContext = XComGameStateContext_TacticalGameRule(class'XComGameStateContext_TacticalGameRule'.static.CreateXComGameStateContext());
	StartContext.GameRuleType = eGameRule_TacticalGameStart;
	StartState = History.CreateNewGameState(false, StartContext);
	History.AddGameStateToHistory(StartState);

	Battle = XComGameState_BattleData(StartState.CreateNewStateObject(class'XComGameState_BattleData'));
	Battle.iLevelSeed = class'Engine'.static.GetEngine().GetSyncSeed();
	Battle.bIsTacticalQuickLaunch = true;
	Battle.LostSpawningLevel = Battle.SelectLostActivationCount();
	Battle.BizAnalyticsMissionID = `FXSLIVE.GetGUID();

	// a mission type from Skirmish mode's list (its config filters out the ones that need a campaign)
	class'X2MissionTemplateManager'.static.GetMissionTemplateManager().GetTemplateNames(MissionNames);
	for (i = 0; i < class'UITLE_SkirmishModeMenu'.default.m_FilteredMissions.Length; i++)
	{
		MissionNames.RemoveItem(class'UITLE_SkirmishModeMenu'.default.m_FilteredMissions[i]);
	}
	for (i = 0; i < 20 && Plots.Length == 0; i++)
	{
		MissionType = MissionMgr.arrMissions[MissionMgr.arrMissions.Find('MissionName', MissionNames[`SYNC_RAND_STATIC(MissionNames.Length)])].sType;
		if (MissionMgr.GetMissionDefinitionForType(MissionType, MissionDef))
		{
			ParcelMgr.GetValidPlotsForMission(Plots, MissionDef);
		}
	}
	if (Plots.Length == 0)
	{
		`log("scenario: no mission type with a valid map",, 'CoopScenario');
		return false;
	}
	Battle.m_iMissionType = MissionMgr.arrMissions.Find('sType', MissionType);
	Battle.m_nQuestItem = class'XComGameState_LadderProgress'.static.SelectQuestItem(MissionType);
	Battle.MapData.ActiveMission = MissionDef;
	MissionMgr.ForceMission = MissionDef;
	Plot = Plots[`SYNC_RAND_STATIC(Plots.Length)];
	Battle.MapData.PlotMapName = Plot.MapName;
	// Skirmish mode's SelectRandomBiome: no Xenoform outside wilderness maps
	for (i = 0; i < Plot.ValidBiomes.Length; i++)
	{
		if (Plot.strType == "Wilderness" || Plot.ValidBiomes[i] != "Xenoform")
		{
			Biomes.AddItem(Plot.ValidBiomes[i]);
		}
	}
	if (Biomes.Length > 0)
	{
		Battle.MapData.Biome = Biomes[`SYNC_RAND_STATIC(Biomes.Length)];
	}
	PlotType = ParcelMgr.GetPlotTypeDefinition(Plot.strType);
	Battle.ActiveSitReps = MissionDef.ForcedSitreps;
	class'XComGameState_LadderProgress'.static.AppendNames(Battle.ActiveSitReps, PlotType.ForcedSitReps);
	Battle.SetPopularSupport(0);
	Battle.SetMaxPopularSupport(1);
	Battle.m_strDesc = "Skirmish Mode";    // the game's tactical-only path (TacticalOnlyGameMode: back to the main menu)
	Battle.m_strOpName = class'XGMission'.static.GenerateOpName(false);
	Battle.m_strMapCommand = "open" @ Battle.MapData.PlotMapName $ "?game=XComGame.XComTacticalGame";

	XComPlayer = class'XComGameState_Player'.static.CreatePlayer(StartState, eTeam_XCom);
	XComPlayer.bPlayerReady = true;
	Battle.PlayerTurnOrder.AddItem(XComPlayer.GetReference());
	Player = class'XComGameState_Player'.static.CreatePlayer(StartState, eTeam_Alien);
	Player.bPlayerReady = true;
	Battle.PlayerTurnOrder.AddItem(Player.GetReference());
	Player = class'XComGameState_Player'.static.CreatePlayer(StartState, eTeam_Neutral);
	Player.bPlayerReady = true;
	Battle.CivilianPlayerRef = Player.GetReference();
	Player = class'XComGameState_Player'.static.CreatePlayer(StartState, eTeam_TheLost);
	Player.bPlayerReady = true;
	Battle.PlayerTurnOrder.AddItem(Player.GetReference());
	Player = class'XComGameState_Player'.static.CreatePlayer(StartState, eTeam_Resistance);
	Player.bPlayerReady = true;
	Battle.PlayerTurnOrder.AddItem(Player.GetReference());

	StartState.CreateNewStateObject(class'XComGameState_Cheats');
	Analytics = XComGameState_Analytics(StartState.CreateNewStateObject(class'XComGameState_Analytics'));
	Analytics.SubmitToFiraxisLive = false;
	Settings = XComGameState_CampaignSettings(StartState.CreateNewStateObject(class'XComGameState_CampaignSettings'));
	Settings.SetDifficulty(1);
	Settings.SetSuppressFirstTimeNarrativeEnabled(true);
	Settings.SetTutorialEnabled(false);
	Settings.SetGameIndexFromProfile();
	Settings.BizAnalyticsCampaignID = `FXSLIVE.GetGUID();
	Settings.SetStartTime(class'XComCheatManager'.static.GetCampaignStartTime());
	EventMgr = `ONLINEEVENTMGR;
	for (i = EventMgr.GetNumDLC() - 1; i >= 0; i--)
	{
		Settings.AddRequiredDLC(EventMgr.GetDLCNames(i));
	}

	HQ = XComGameState_HeadquartersXCom(StartState.CreateNewStateObject(class'XComGameState_HeadquartersXCom'));
	HQ.AdventLootWeight = class'XComGameState_HeadquartersXCom'.default.StartingAdventLootWeight;
	HQ.AlienLootWeight = class'XComGameState_HeadquartersXCom'.default.StartingAlienLootWeight;
	HQ.bHasPlayedAmbushTutorial = true;
	HQ.bHasPlayedMeleeTutorial = true;
	HQ.bHasPlayedNeutralizeTargetTutorial = true;
	HQ.SetGenericKeyValue("NeutralizeTargetTutorial", 1);
	StartState.CreateNewStateObject(class'XComGameState_ObjectivesList');
	class'XComGameState_HeadquartersResistance'.static.SetUpHeadquarters(StartState, false);
	class'XComGameState_HeadquartersAlien'.static.SetUpHeadquarters(StartState);
	class'XComGameState_GameTime'.static.CreateGameStartTime(StartState);

	// the operators
	Classes = class'X2ChallengeSoldierClass'.static.SelectSoldierClasses(X2ChallengeSoldierClass(Challenge(default.ClassSelector)), OPERATORS);
	for (i = 0; i < OPERATORS && i < Classes.Length; i++)
	{
		Squad.AddItem(CreateOperator(StartState, HQ, XComPlayer, Classes[i]));
	}
	for (i = 0; i < Squad.Length; i++)
	{
		class'X2ChallengeSoldierRankSelectors'.static.RankUpSoldier(StartState, Squad[i], Pick(default.StageRanks, Stage, 1));
		// the squaddie rank-up equips the class's starting loadout (Kevlar); the challenge armor selectors only add
		// armor, so the old one goes first, as Skirmish mode's armor change does (late game showed Kevlar before)
		Squad[i].RemoveItemFromInventory(Squad[i].GetItemInSlot(eInvSlot_Armor, StartState, true), StartState);
	}
	class'X2ChallengeArmor'.static.SelectSoldierArmor(X2ChallengeArmor(Challenge(PickName(default.StageArmor, Stage))), Squad, StartState);
	class'X2ChallengePrimaryWeapon'.static.SelectSoldierPrimaryWeapon(X2ChallengePrimaryWeapon(Challenge(PickName(default.StagePrimary, Stage))), Squad, StartState);
	class'X2ChallengeSecondaryWeapon'.static.SelectSoldierSecondaryWeapon(X2ChallengeSecondaryWeapon(Challenge(PickName(default.StageSecondary, Stage))), Squad, StartState);
	class'X2ChallengeUtility'.static.SelectSoldierUtilityItems(X2ChallengeUtility(Challenge(default.UtilitySelector)), Squad, StartState);

	// co-op: the players and who owns which operator (blocks: 2 players 6 + 6, 3 players 4 + 4 + 4, 4 players 3 each)
	Coop = XComGameState_CoopCampaign(StartState.CreateNewStateObject(class'XComGameState_CoopCampaign'));
	Coop.PlayerCount = Players;
	Coop.bScenario = true;
	Coop.ScenarioStage = Stage;
	Coop.SlotNames.AddItem("Host");
	Coop.SlotNames.AddItem("Guest 1");
	Coop.SlotNames.AddItem("Guest 2");
	Coop.SlotNames.AddItem("Guest 3");
	Coop.SetDefaultSquadSplit(Squad.Length);
	for (i = 0; i < Squad.Length; i++)
	{
		class'CoopOwnership'.static.SetOwner(Squad[i], Coop.OwnerOfSquadSlot(i));
	}

	// the mission site (Skirmish mode's SetupChallengeMissionSite) and its enemies
	Battle.ActiveSitReps.AddItem('ChallengeNoReinforcements');
	Site = CreateMissionSite(StartState, Battle);
	Battle.SetAlertLevel(AlertLevel);
	Battle.SetForceLevel(ForceLevel);
	Site.SelectedMissionData.AlertLevel = AlertLevel;
	Site.SelectedMissionData.ForceLevel = ForceLevel;
	Battle.TQLEnemyForcesSelection = string(default.EnemySelector);
	Enemies = X2ChallengeEnemyForces(Challenge(default.EnemySelector));
	if (Enemies != none)
	{
		Site.SelectedMissionData.SelectedEncounters.Length = 0;
		for (i = 0; i < Enemies.AdditionalTacticalGameplayTags.Length; i++)
		{
			HQ.TacticalGameplayTags.AddItem(Enemies.AdditionalTacticalGameplayTags[i]);
		}
		HQ.CleanUpTacticalTags();
		class'X2ChallengeEnemyForces'.static.SelectEnemyForces(Enemies, Site, Battle, StartState);
	}
	Site.UpdateSitrepTags();
	HQ.AddMissionTacticalTags(Site);
	class'X2SitRepTemplate'.static.ModifyPreMissionBattleDataState(Battle, Battle.ActiveSitReps);

	// host: open the server at the first unit actions, as after a campaign mission's build (CoopLink)
	class'CoopLink'.default.bReopenPending = true;
	class'CoopLink'.default.bMissionRunning = false;
	class'CoopLink'.default.bMissionHistorySent = false;
	// the players expected: the guests' groups are split from the start, the mission goes out once they are all in
	// (or after CoopLink.WaitForGuestsSeconds), and the first turn waits for them (CoopTacticalRuleset). From the
	// lobby: the guests connected there, in the slots the host gave them; else (the bot's @scenario) slots 1..P-1.
	default.SeenLoading.Length = 0;
	if (`XCOMNETMANAGER.HasServerConnection() && class'CoopRole'.default.ConnectedSlots.Length > 0)
	{
		class'CoopLobby'.static.HostLeaveForGame("Scenario:" @ Battle.m_strOpName);
	}
	else
	{
		class'CoopLink'.default.MissionSlots.Length = 0;
		for (i = 1; i < Players; i++)
		{
			class'CoopLink'.default.MissionSlots.AddItem(i);
		}
		class'CoopLink'.default.HostPort = class'CoopLink'.default.DefaultPort;
	}

	`log("scenario: stage=" $ StageName(Stage) @ "players=" $ Players @ "mission=" $ MissionType @ "map=" $ Battle.MapData.PlotMapName
		@ "force=" $ ForceLevel @ "alert=" $ AlertLevel @ "operators=" $ Squad.Length @ "owners=" $ Coop.Describe(),, 'CoopScenario');
	for (i = 0; i < Squad.Length; i++)
	{
		`log("scenario: operator" @ i @ Squad[i].GetSoldierClassTemplateName() @ "rank=" $ Squad[i].GetRank()
			@ "primary=" $ Squad[i].GetItemInSlot(eInvSlot_PrimaryWeapon, StartState).GetMyTemplateName()
			@ "armor=" $ Squad[i].GetItemInSlot(eInvSlot_Armor, StartState).GetMyTemplateName()
			@ "owner=" $ class'CoopOwnership'.static.OwnerOf(Squad[i]),, 'CoopScenario');
	}
	`ONLINEEVENTMGR.bGenerateMapForSkirmish = true;
	class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController().ConsoleCommand(Battle.m_strMapCommand);
	return true;
}

// Skirmish mode's CreateUnit: a random soldier of the class, in the squad and the crew.
static function XComGameState_Unit CreateOperator(XComGameState StartState, XComGameState_HeadquartersXCom HQ, XComGameState_Player XComPlayer, name ClassName)
{
	local X2SoldierClassTemplate ClassTemplate;
	local X2CharacterTemplate CharTemplate;
	local XGCharacterGenerator Generator;
	local XComGameState_Unit Unit;
	local TSoldier Soldier;

	ClassTemplate = class'X2SoldierClassTemplateManager'.static.GetSoldierClassTemplateManager().FindSoldierClassTemplate(ClassName);
	CharTemplate = class'X2CharacterTemplateManager'.static.GetCharacterTemplateManager().FindCharacterTemplate(
		(ClassTemplate.RequiredCharacterClass != '') ? ClassTemplate.RequiredCharacterClass : 'Soldier');
	Generator = class'WorldInfo'.static.GetWorldInfo().Spawn(CharTemplate.CharacterGeneratorClass);
	Unit = CharTemplate.CreateInstanceFromTemplate(StartState);
	Unit.bRolledForAWCAbility = true;
	Unit.SetSoldierClassTemplate(ClassTemplate.DataName);
	Unit.SetControllingPlayer(XComPlayer.GetReference());
	Soldier = Generator.CreateTSoldier();
	Unit.SetTAppearance(Soldier.kAppearance);
	Unit.SetCharacterName(Soldier.strFirstName, Soldier.strLastName, Soldier.strNickName);
	Unit.SetCountry(Soldier.nmCountry);
	if (!Unit.HasBackground())
	{
		Unit.GenerateBackground(, Generator.BioCountryName);
	}
	HQ.Squad.AddItem(Unit.GetReference());
	HQ.AddToCrewNoStrategy(Unit);
	if (CharTemplate.RequiredLoadout != '')
	{
		Unit.ApplyInventoryLoadout(StartState, CharTemplate.RequiredLoadout);
	}
	Generator.Destroy();
	return Unit;
}

// Skirmish mode's SetupChallengeMissionSite: a mission site in a random region of a random continent.
static function XComGameState_MissionSite CreateMissionSite(XComGameState StartState, XComGameState_BattleData Battle)
{
	local X2StrategyElementTemplateManager StratMgr;
	local array<X2StrategyElementTemplate> Continents;
	local X2ContinentTemplate ContinentTemplate;
	local X2WorldRegionTemplate RegionTemplate;
	local XComGameState_Continent Continent;
	local XComGameState_WorldRegion Region;
	local XComGameState_MissionSite Site;
	local Vector Center, Extents;

	StratMgr = class'X2StrategyElementTemplateManager'.static.GetStrategyElementTemplateManager();
	Continents = StratMgr.GetAllTemplatesOfClass(class'X2ContinentTemplate');
	ContinentTemplate = X2ContinentTemplate(Continents[`SYNC_RAND_STATIC(Continents.Length)]);
	RegionTemplate = X2WorldRegionTemplate(StratMgr.FindStrategyElementTemplate(ContinentTemplate.Regions[`SYNC_RAND_STATIC(ContinentTemplate.Regions.Length)]));
	Continent = XComGameState_Continent(StartState.CreateNewStateObject(class'XComGameState_Continent', ContinentTemplate));
	Region = XComGameState_WorldRegion(StartState.CreateNewStateObject(class'XComGameState_WorldRegion', RegionTemplate));
	Continent.AssignRegions(StartState);
	Extents.X = (RegionTemplate.Bounds[0].fRight - RegionTemplate.Bounds[0].fLeft) / 2.0f;
	Extents.Y = (RegionTemplate.Bounds[0].fBottom - RegionTemplate.Bounds[0].fTop) / 2.0f;
	Center.X = RegionTemplate.Bounds[0].fLeft + Extents.X;
	Center.Y = RegionTemplate.Bounds[0].fTop + Extents.Y;

	Site = XComGameState_MissionSite(StartState.CreateNewStateObject(class'XComGameState_MissionSite'));
	Site.Location = Center + (`SYNC_VRAND_STATIC() * Extents);
	Site.Continent.ObjectID = Continent.ObjectID;
	Site.Region.ObjectID = Region.ObjectID;
	Site.GeneratedMission.MissionID = Site.ObjectID;
	Site.GeneratedMission.Mission = `TACTICALMISSIONMGR.arrMissions[Battle.m_iMissionType];
	Site.GeneratedMission.LevelSeed = Battle.iLevelSeed;
	Site.GeneratedMission.BattleOpName = Battle.m_strOpName;
	Site.GeneratedMission.BattleDesc = "Co-op Scenario";
	Site.GeneratedMission.MissionQuestItemTemplate = Battle.m_nQuestItem;
	Site.GeneratedMission.SitReps = Battle.ActiveSitReps;
	Battle.m_iMissionID = Site.ObjectID;
	return Site;
}

static function bool IsScenario()
{
	local XComGameState_CoopCampaign Coop;

	Coop = class'XComGameState_CoopCampaign'.static.Get();
	return Coop != none && Coop.bScenario;
}

// Host, before the first turn of a scenario (CoopTacticalRuleset.TurnPhase_CoopWaitPlayers, polled): true once every
// expected player has the mission and has finished loading its map (the roster showed it loading, now connected).
static function bool PlayersReady()
{
	local int Slot, Ready;

	foreach class'CoopLink'.default.MissionSlots(Slot)
	{
		if (class'CoopRoster'.static.StateOf(Slot) == class'CoopRoster'.const.PS_LOADING && default.SeenLoading.Find(Slot) == INDEX_NONE)
		{
			default.SeenLoading.AddItem(Slot);
		}
		if (class'CoopRole'.default.ConnectedSlots.Find(Slot) != INDEX_NONE && default.SeenLoading.Find(Slot) != INDEX_NONE
			&& class'CoopRoster'.static.StateOf(Slot) == class'CoopRoster'.const.PS_CONNECTED)
		{
			Ready++;
		}
	}
	return class'CoopLink'.default.bMissionHistorySent && class'CoopTacticalNet'.default.MissionAckSlots.Length == 0
		&& Ready == class'CoopLink'.default.MissionSlots.Length;
}

static function string WaitText()
{
	local int Slot, Joined;

	foreach class'CoopLink'.default.MissionSlots(Slot)
	{
		if (class'CoopRole'.default.ConnectedSlots.Find(Slot) != INDEX_NONE)
		{
			Joined++;
		}
	}
	return "Waiting for players:" @ Joined @ "of" @ class'CoopLink'.default.MissionSlots.Length @ "joined";
}

// Host, mission over (CoopTacticalRuleset.EndTacticalGame): the guests go back to the main menu instead of
// waiting for a campaign.
static function HostScenarioOver()
{
	if (!IsScenario() || class'CoopRole'.static.IsGuest())
	{
		return;
	}
	class'CoopTacticalNet'.static.Send("CoopScenarioOver");
	`log("scenario over: told the guests",, 'CoopScenario');
}

// Guest: "CoopScenarioOver".
static function GuestScenarioOver()
{
	`log("scenario over: back to the main menu",, 'CoopScenario');
	class'CoopLink'.default.bReconnecting = false;
	class'CoopLink'.default.GuestHost = "";
	class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController().ConsoleCommand("disconnect");
}

//---------------------------------------------------------------------------------------
//  FILE:    CoopExperiments.uc
//  PURPOSE: Harness commands for the full-campaign experiments (single instance):
//           1. owner tag on soldiers survives a mission round trip;
//           2. splitting the XCom initiative group by owner gives one turn per player.
//           Every result line is logged with the 'CoopExp' tag.
//---------------------------------------------------------------------------------------
class CoopExperiments extends Actor;

// @watchturns: last initiative entry seen, and how long to keep watching
var int LastInitiativeID;
var float WatchLeft;
var float MissionStartLeft;   // @missionstart: seconds left to wait for the mission map
var float RulesLocLeft;       // @rulesloc: seconds left to keep logging
var Vector CamTestStart;      // @camtest: view point before panning
var int CamTestTicks;         // @camtest: key presses left
var int PendingLaunchID;      // @launch: the mission launched after the one-second pause

static function CoopExperiments EnsureSpawned(Actor Spawner)
{
	local CoopExperiments Exp;

	foreach Spawner.AllActors(class'CoopExperiments', Exp)
	{
		return Exp;
	}
	return Spawner.Spawn(class'CoopExperiments');
}

// Returns false for commands this class does not know.
function bool Run(string Cmd)
{
	local array<string> Args;
	local array<XComGameState_Unit> Soldiers;

	if (Left(Cmd, 6) ~= "squad ")
	{
		FillSquad(int(Mid(Cmd, 6)));
	}
	else if (Cmd ~= "tagsquad")
	{
		TagSquad();
	}
	else if (Left(Cmd, 10) ~= "tagowners ")
	{
		TagOwners(Mid(Cmd, 10));
	}
	else if (Cmd ~= "tags")
	{
		LogTags();
	}
	else if (Cmd ~= "missions")
	{
		LogMissions();
	}
	else if (Cmd ~= "spawnmission")
	{
		SpawnTestMission();
	}
	else if (Left(Cmd, 13) ~= "spawnmission ")
	{
		// "@spawnmission SOURCE [REWARD]": one mission of that source (HQ cheat SpawnMission)
		Args = SplitString(Mid(Cmd, 13), " ", true);
		if (Args.Length > 1)
		{
			SpawnMissionOf(name(Args[0]), name(Args[1]));
		}
		else
		{
			SpawnMissionOf(name(Args[0]), 'Reward_Supplies');
		}
	}
	else if (Left(Cmd, 12) ~= "tagbarracks ")
	{
		// "@tagbarracks P": every soldier not in the squad belongs to player P (reinforcement tests)
		TagBarracks(int(Mid(Cmd, 12)));
	}
	else if (Cmd ~= "avengerdefense")
	{
		// "@avengerdefense": a UFO and its Avenger defense mission, as XComGameState_UFO does when it catches the Avenger
		SpawnAvengerDefense();
	}
	else if (Cmd ~= "stronghold" || Left(Cmd, 11) ~= "stronghold ")
	{
		// "@stronghold [CHOSEN]": that Chosen's stronghold mission (HQ cheat SpawnChosenStrongholdMission); default: the first Chosen
		ChosenCheat(Mid(Cmd, 11), false);
	}
	else if (Cmd ~= "chosenassault" || Left(Cmd, 14) ~= "chosenassault ")
	{
		// "@chosenassault [CHOSEN]": that Chosen attacks the Avenger (HQ cheat TriggerChosenAvengerAssault)
		ChosenCheat(Mid(Cmd, 14), true);
	}
	else if (Left(Cmd, 7) ~= "launch ")
	{
		// "@launch SOURCE": launch the first available mission of that source
		LaunchFirstMission(name(Mid(Cmd, 7)));
	}
	else if (Cmd ~= "launch")
	{
		LaunchFirstMission();
	}
	else if (Cmd ~= "groups")
	{
		LogGroups();
	}
	else if (Cmd ~= "mprules")
	{
		LogMPRules();
	}
	else if (Cmd ~= "tacpause")
	{
		// open the tactical pause menu, check the world is paused a second later, close it
		XComPresentationLayer(XComPlayerController(GetALocalPlayerController()).Pres).UIPauseMenu();
		// a paused world stops this actor's timers too: the check runs on an actor that ticks while paused
		Spawn(class'CoopPauseProbe').SetTimer(1.0f, false, nameof(CheckPauseAndClose), self);
	}
	else if (Cmd ~= "netmode")
	{
		LogNetMode();
	}
	else if (Cmd ~= "netclose")
	{
		`XCOMNETMANAGER.Disconnect();
		`XCOMNETMANAGER.ResetConnectionData();
		`log("netclose done",, 'CoopExp');
		LogNetMode();
	}
	else if (Cmd ~= "split")
	{
		SplitXComGroup();
	}
	else if (Cmd ~= "actors")
	{
		LogActors();
	}
	else if (Cmd ~= "endturn")
	{
		`log("endturn result=" $ class'CoopHarness'.static.BoolStr(XComTacticalController(GetALocalPlayerController()).PerformEndTurn(ePlayerEndTurnType_PlayerInput)),, 'CoopExp');
	}
	else if (Left(Cmd, 11) ~= "watchturns ")
	{
		WatchLeft = float(Mid(Cmd, 11));
		LastInitiativeID = -1;
		SetTimer(0.25f, true, nameof(WatchTurns));
	}
	else if (Cmd ~= "afteraction")
	{
		AfterAction();
	}
	else if (Left(Cmd, 9) ~= "rulesloc ")
	{
		// "@rulesloc S": log where the tactical ruleset is, now and every 5 s for S seconds
		RulesLocLeft = float(Mid(Cmd, 9));
		LogRulesLoc();
		SetTimer(5.0f, true, nameof(LogRulesLocTick));
	}
	else if (Cmd ~= "movies")
	{
		`log("movies any=" $ class'CoopHarness'.static.BoolStr(class'XComEngine'.static.IsAnyMoviePlaying())
			@ "loading=" $ class'CoopHarness'.static.BoolStr(class'XComEngine'.static.IsLoadingMoviePlaying())
			@ "waiting=" $ class'CoopHarness'.static.BoolStr(class'XComEngine'.static.IsWaitingForMovie())
			@ "LogoSpin=" $ class'CoopHarness'.static.BoolStr(class'XComEngine'.static.IsMoviePlaying("CIN_XP_UI_LogoSpin.bk2"))
			@ "LogoSpinNoExt=" $ class'CoopHarness'.static.BoolStr(class'XComEngine'.static.IsMoviePlaying("CIN_XP_UI_LogoSpin"))
			@ "Black=" $ class'CoopHarness'.static.BoolStr(class'XComEngine'.static.IsMoviePlaying("1080_Black"))
			@ "Reaper=" $ class'CoopHarness'.static.BoolStr(class'XComEngine'.static.IsMoviePlaying("1080_XP_LoadingScreen_Reaper")),, 'CoopExp');
	}
	else if (Cmd ~= "stopmovie")
	{
		`log("stopmovie",, 'CoopExp');
		class'XComEngine'.static.StopCurrentMovie();
	}
	else if (Cmd ~= "missionstart")
	{
		// the drop-ship briefing waits for a key once the mission map has loaded; poll, then press it
		MissionStartLeft = 120.0f;
		SetTimer(0.5f, true, nameof(PollMissionStart));
	}
	else if (Cmd ~= "modinit")
	{
		class'CoopModCheck'.static.Init();
	}
	else if (Cmd ~= "mods")
	{
		class'CoopModCheck'.static.LogLocal();
	}
	else if (Cmd ~= "modsend")
	{
		class'CoopModCheck'.static.SendList();
	}
	else if (Cmd ~= "audit")
	{
		class'CoopModCheck'.static.AuditContent();
	}
	else if (Cmd ~= "roster")
	{
		MakeRoster();
	}
	else if (Left(Cmd, 9) ~= "putsquad ")
	{
		PutSquad(Mid(Cmd, 9));
	}
	else if (Cmd ~= "squadinfo")
	{
		LogSquad();
	}
	else if (Left(Cmd, 5) ~= "gate ")
	{
		class'CoopTacticalController'.default.bGateSelection = int(Mid(Cmd, 5)) != 0;
		`log("gate" @ class'CoopHarness'.static.BoolStr(class'CoopTacticalController'.default.bGateSelection)
			@ "controller=" $ GetALocalPlayerController().Class.Name,, 'CoopExp');
	}
	else if (Left(Cmd, 11) ~= "assignslot ")
	{
		Args = SplitString(Mid(Cmd, 11), " ", true);
		class'CoopHostActions'.static.AssignSquadSlot(int(Args[0]), int(Args[1]));
	}
	else if (Left(Cmd, 5) ~= "give ")
	{
		// "@give N P": the N-th soldier (GetSoldiers order) to player P (-1 = take back)
		Args = SplitString(Mid(Cmd, 5), " ", true);
		Soldiers = `XCOMHQ.GetSoldiers();
		if (int(Args[0]) < Soldiers.Length)
		{
			class'CoopHostActions'.static.GiveSoldier(Soldiers[int(Args[0])].ObjectID, int(Args[1]));
		}
	}
	else if (Left(Cmd, 8) ~= "players ")
	{
		class'CoopHostActions'.static.SetPlayerCount(int(Mid(Cmd, 8)));
	}
	else if (Left(Cmd, 10) ~= "connected ")
	{
		// host-side test aid: pretend the guest in this slot is connected
		class'CoopRole'.static.SlotConnected(int(Mid(Cmd, 10)), -1);
		`log("connected slots=" $ class'CoopRole'.default.ConnectedSlots.Length,, 'CoopExp');
	}
	else if (Left(Cmd, 10) ~= "hostrules ")
	{
		class'CoopGuestRights'.default.bHostDecidesCampaign = int(Mid(Cmd, 10)) != 0;
		`log("hostrules" @ class'CoopHarness'.static.BoolStr(class'CoopGuestRights'.default.bHostDecidesCampaign),, 'CoopExp');
	}
	else if (Left(Cmd, 7) ~= "armory ")
	{
		// "@armory N": open the Armory for the N-th soldier (GetSoldiers order), as clicking it does
		Soldiers = `XCOMHQ.GetSoldiers();
		if (int(Mid(Cmd, 7)) < Soldiers.Length)
		{
			`HQPRES.UIArmory_MainMenu(Soldiers[int(Mid(Cmd, 7))].GetReference());
		}
	}
	else if (Left(Cmd, 8) ~= "loadout ")
	{
		// "@loadout N": the N-th soldier's loadout screen (an edit screen: needs the baton)
		Soldiers = `XCOMHQ.GetSoldiers();
		if (int(Mid(Cmd, 8)) < Soldiers.Length)
		{
			`HQPRES.UIArmory_Loadout(Soldiers[int(Mid(Cmd, 8))].GetReference());
		}
	}
	else if (Cmd ~= "barracks")
	{
		// "@barracks": the Armory's soldier list, as the Armory room opens it
		`HQPRES.UIPersonnel_Armory();
	}
	else if (Cmd ~= "hoststeam")
	{
		class'CoopSteamJoin'.default.bSteamInvites = true;
		class'CoopSteamJoin'.static.HostSteam();
	}
	else if (Left(Cmd, 4) ~= "say ")
	{
		class'CoopChat'.static.Say(Mid(Cmd, 4));
	}
	else if (Left(Cmd, 9) ~= "joingate ")
	{
		class'CoopJoin'.default.bGateJoinOnMods = int(Mid(Cmd, 9)) != 0;
		`log("joingate" @ class'CoopHarness'.static.BoolStr(class'CoopJoin'.default.bGateJoinOnMods),, 'CoopExp');
	}
	else if (Cmd ~= "trysel")
	{
		TrySelectAll();
	}
	else if (Left(Cmd, 8) ~= "ownerof ")
	{
		// "@ownerof N": owner tag of the N-th soldier (GetSoldiers order), as this copy sees it
		Soldiers = `XCOMHQ.GetSoldiers();
		if (int(Mid(Cmd, 8)) < Soldiers.Length)
		{
			`log("ownerof" @ int(Mid(Cmd, 8)) @ "id=" $ Soldiers[int(Mid(Cmd, 8))].ObjectID @ "owner=" $ OwnerOf(Soldiers[int(Mid(Cmd, 8))]),, 'CoopExp');
		}
	}
	else if (Cmd ~= "squadselect")
	{
		OpenSquadSelect();
	}
	else if (Cmd ~= "camtest")
	{
		CamTest();
	}
	else if (Cmd ~= "ironman")
	{
		SetIronman();
	}
	else if (Left(Cmd, 7) ~= "asslot ")
	{
		// play as this player slot from now on (single-instance tests)
		class'CoopRole'.default.LocalSlotOverride = int(Mid(Cmd, 7));
		`log("asslot" @ class'CoopRole'.static.LocalSlot(),, 'CoopExp');
	}
	else
	{
		return false;
	}
	return true;
}

//---------------------------------------------------------------------------------------
// Strategy

static function int OwnerOf(XComGameState_Unit Unit)
{
	return class'CoopOwnership'.static.OwnerOf(Unit);
}

// "@putsquad <slot> <n>": put the n-th soldier (GetSoldiers order) into squad slot <slot> with an
// ordinary frame, as the squad screen's ChangeSlot does. CoopSquadRules may undo it.
function PutSquad(string Args)
{
	local array<string> Parts;
	local XComGameState NewGameState;
	local XComGameState_HeadquartersXCom XComHQ;
	local array<XComGameState_Unit> Soldiers;
	local int Slot, N;

	ParseStringIntoArray(Args, Parts, " ", true);
	Slot = int(Parts[0]);
	N = int(Parts[1]);
	Soldiers = `XCOMHQ.GetSoldiers();
	if (N < 0 || N >= Soldiers.Length)
	{
		`log("putsquad: no soldier" @ N,, 'CoopExp');
		return;
	}
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop experiment: put soldier in squad slot");
	XComHQ = XComGameState_HeadquartersXCom(NewGameState.ModifyStateObject(class'XComGameState_HeadquartersXCom', `XCOMHQ.ObjectID));
	if (XComHQ.Squad.Length <= Slot)
	{
		XComHQ.Squad.Length = Slot + 1;
	}
	XComHQ.Squad[Slot] = Soldiers[N].GetReference();
	`log("putsquad slot=" $ Slot @ "unit=" $ Soldiers[N].ObjectID @ "localSlot=" $ class'CoopRole'.static.LocalSlot(),, 'CoopExp');
	`GAMERULES.SubmitGameState(NewGameState);
	LogSquad();
}

function LogSquad()
{
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_CoopCampaign Coop;
	local string Line;
	local int i;

	XComHQ = `XCOMHQ;
	Coop = class'XComGameState_CoopCampaign'.static.Get();
	for (i = 0; i < XComHQ.Squad.Length; i++)
	{
		Line @= i $ ":" $ XComHQ.Squad[i].ObjectID $ "/slotOwner=" $ ((Coop != none) ? string(Coop.OwnerOfSquadSlot(i)) : "-")
			$ "/unitOwner=" $ OwnerOf(XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(XComHQ.Squad[i].ObjectID)));
	}
	`log("squad" @ Line,, 'CoopExp');
}

// Create (or update) the campaign's co-op object with the default split for the current max squad size.
function MakeRoster()
{
	local XComGameState NewGameState;
	local XComGameState_CoopCampaign Coop;
	local int Size;

	Size = 4;   // fixed for tests: the debug campaign's max squad size is not known in advance
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop: roster");
	Coop = class'XComGameState_CoopCampaign'.static.GetForChange(NewGameState);
	Coop.SetDefaultSquadSplit(Size);
	`GAMERULES.SubmitGameState(NewGameState);
	`log("roster maxSquad=" $ Size @ Coop.Describe(),, 'CoopExp');
}

function FillSquad(int Count)
{
	local XComGameState NewGameState;
	local XComGameState_HeadquartersXCom XComHQ;
	local array<XComGameState_Unit> Soldiers;
	local XComGameState_Unit Unit;

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop experiment: fill squad");
	XComHQ = XComGameState_HeadquartersXCom(NewGameState.ModifyStateObject(class'XComGameState_HeadquartersXCom', `XCOMHQ.ObjectID));
	XComHQ.Squad.Length = 0;
	Soldiers = XComHQ.GetSoldiers();
	foreach Soldiers(Unit)
	{
		if (XComHQ.Squad.Length < Count && Unit.CanGoOnMission())
		{
			XComHQ.Squad.AddItem(Unit.GetReference());
		}
	}
	`GAMERULES.SubmitGameState(NewGameState);
	`log("squad size=" $ XComHQ.Squad.Length @ "asked=" $ Count,, 'CoopExp');
}

// First half of the squad -> slot 0 (host), the rest -> slot 1 (guest).
function TagSquad()
{
	local XComGameState NewGameState;
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_Unit Unit;
	local int i, Half;

	XComHQ = `XCOMHQ;
	Half = (XComHQ.Squad.Length + 1) / 2;
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop experiment: tag squad owners");
	for (i = 0; i < XComHQ.Squad.Length; i++)
	{
		Unit = XComGameState_Unit(NewGameState.ModifyStateObject(class'XComGameState_Unit', XComHQ.Squad[i].ObjectID));
		class'CoopOwnership'.static.SetOwner(Unit, (i < Half) ? 0 : 1);
	}
	`GAMERULES.SubmitGameState(NewGameState);
	`log("tagged" @ XComHQ.Squad.Length @ "half=" $ Half,, 'CoopExp');
	LogTags();
}

function TagBarracks(int Slot)
{
	local XComGameState NewGameState;
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_Unit Unit;
	local StateObjectReference Ref;
	local int Count;

	XComHQ = `XCOMHQ;
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop experiment: tag barracks owners");
	foreach XComHQ.Crew(Ref)
	{
		Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Ref.ObjectID));
		if (Unit == none || !Unit.IsSoldier() || XComHQ.Squad.Find('ObjectID', Ref.ObjectID) != INDEX_NONE)
		{
			continue;
		}
		Unit = XComGameState_Unit(NewGameState.ModifyStateObject(class'XComGameState_Unit', Ref.ObjectID));
		class'CoopOwnership'.static.SetOwner(Unit, Slot);
		Count++;
	}
	`GAMERULES.SubmitGameState(NewGameState);
	`log("tagbarracks owner=" $ Slot @ "count=" $ Count,, 'CoopExp');
}

// "@tagowners 0 0 1 2": owner of each squad soldier in order (3-4 player tests).
function TagOwners(string Args)
{
	local XComGameState NewGameState;
	local XComGameState_HeadquartersXCom XComHQ;
	local XComGameState_Unit Unit;
	local array<string> Owners;
	local int i;

	XComHQ = `XCOMHQ;
	Owners = SplitString(Args, " ", true);
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop experiment: tag squad owners");
	for (i = 0; i < XComHQ.Squad.Length && i < Owners.Length; i++)
	{
		Unit = XComGameState_Unit(NewGameState.ModifyStateObject(class'XComGameState_Unit', XComHQ.Squad[i].ObjectID));
		class'CoopOwnership'.static.SetOwner(Unit, int(Owners[i]));
	}
	`GAMERULES.SubmitGameState(NewGameState);
	`log("tagowners" @ Args,, 'CoopExp');
	LogTags();
}

// Strategy: every soldier with a tag or in the squad. Tactical: every XCom unit.
function LogTags()
{
	local XComGameStateHistory History;
	local XComGameState_Unit Unit;
	local XComGameState_HeadquartersXCom XComHQ;
	local string Line;
	local int Count;

	History = `XCOMHISTORY;
	XComHQ = XComGameState_HeadquartersXCom(History.GetSingleGameStateObjectForClass(class'XComGameState_HeadquartersXCom', true));
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (!Unit.IsSoldier())
		{
			continue;
		}
		if (OwnerOf(Unit) < 0 && (XComHQ == none || XComHQ.Squad.Find('ObjectID', Unit.ObjectID) == INDEX_NONE))
		{
			continue;
		}
		Line @= Unit.ObjectID $ "=" $ OwnerOf(Unit);
		Count++;
	}
	`log("tags count=" $ Count @ "map=" $ WorldInfo.GetMapName() @ "units=" $ Line,, 'CoopExp');
}

function LogMissions()
{
	local XComGameState_MissionSite Mission;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_MissionSite', Mission)
	{
		`log("mission id=" $ Mission.ObjectID @ "source=" $ Mission.Source @ "available=" $ class'CoopHarness'.static.BoolStr(Mission.Available)
			@ "type=" $ Mission.GeneratedMission.Mission.sType,, 'CoopExp');
	}
}

static function int CountLaunchableMissions()
{
	local XComGameState_MissionSite Mission;
	local int Count;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_MissionSite', Mission)
	{
		if (Mission.Available && Mission.GetMissionSource().bRequiresSkyrangerTravel && Mission.Source != 'MissionSource_Final')
		{
			Count++;
		}
	}
	return Count;
}

// The HQ cheat SpawnMission, called directly, with a check and a second mission source if nothing appeared
// (the console line "SpawnMission ..." silently added nothing in one run).
function SpawnTestMission()
{
	local XComHeadquartersCheatManager Cheats;
	local int Before;

	Cheats = XComHeadquartersCheatManager(GetALocalPlayerController().CheatManager);
	Before = CountLaunchableMissions();
	if (Cheats == none)
	{
		`log("spawnmission: no HQ cheat manager (" $ GetALocalPlayerController().CheatManager $ ")",, 'CoopExp');
		return;
	}
	Cheats.SpawnMission('MissionSource_GuerillaOp', 'Reward_Supplies');
	if (CountLaunchableMissions() <= Before)
	{
		Cheats.SpawnMission('MissionSource_Council', 'Reward_Supplies');
	}
	`log("spawnmission launchable before=" $ Before @ "after=" $ CountLaunchableMissions(),, 'CoopExp');
}

function SpawnMissionOf(name Source, name Reward)
{
	local XComHeadquartersCheatManager Cheats;
	local XComGameState_MissionSite Mission;
	local int Before, After;

	Cheats = XComHeadquartersCheatManager(GetALocalPlayerController().CheatManager);
	if (Cheats == none)
	{
		`log("spawnmission: no HQ cheat manager",, 'CoopExp');
		return;
	}
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_MissionSite', Mission)
	{
		if (Mission.Source == Source && Mission.Available)
		{
			Before++;
		}
	}
	Cheats.SpawnMission(Source, Reward);
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_MissionSite', Mission)
	{
		if (Mission.Source == Source && Mission.Available)
		{
			After++;
			`log("spawnmission source=" $ Source @ "id=" $ Mission.ObjectID @ "type=" $ Mission.GeneratedMission.Mission.sType
				@ "skyranger=" $ class'CoopHarness'.static.BoolStr(Mission.GetMissionSource().bRequiresSkyrangerTravel),, 'CoopExp');
		}
	}
	`log("spawnmission" @ Source @ "reward=" $ Reward @ "before=" $ Before @ "after=" $ After,, 'CoopExp');
}

// The path a player takes: PrepareTacticalBattle (as MissionSite.SelectSquad does), then
// ConfirmMission (as reaching the mission with the Skyranger does). Squad must be filled first.
function LaunchFirstMission(optional name Source)
{
	local XComGameState_MissionSite Mission, Pick;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_MissionSite', Mission)
	{
		if (Source != '' && Mission.Source != Source)
		{
			continue;
		}
		// missions without a Skyranger flight (an Avenger attack, the final mission: the Avenger flies there) and
		// the final mission (it ends the campaign) are only picked when asked for by source
		if (Mission.Available && (Source != '' || Mission.Source != 'MissionSource_Final')
			&& (Mission.GetMissionSource().bRequiresSkyrangerTravel || Source != ''))
		{
			Pick = Mission;
			break;
		}
	}
	if (Pick == none)
	{
		`log("launch: no available mission",, 'CoopExp');
		return;
	}
	`log("launch id=" $ Pick.ObjectID @ "source=" $ Pick.Source @ "squad=" $ `XCOMHQ.Squad.Length,, 'CoopExp');
	// The bot launches from the Avenger while its matinees play; a player launches after the Skyranger flight
	// from the Geoscape. One host crashed in that unload (mission3-20261115: XCom2.exe+0x6d0695, the Wwise
	// matinee sound callback after the map unload, as the guest's Avenger exit before its fix). As that fix
	// does: the world paused (no new sounds posted), the launch one second later (bAlwaysTick).
	if (WorldInfo.Pauser == none && GetALocalPlayerController() != none && GetALocalPlayerController().PlayerReplicationInfo != none)
	{
		WorldInfo.Pauser = GetALocalPlayerController().PlayerReplicationInfo;
	}
	PendingLaunchID = Pick.ObjectID;
	SetTimer(1.0, false, nameof(FinishLaunch));
}

function FinishLaunch()
{
	local XComGameState_MissionSite Pick;

	Pick = XComGameState_MissionSite(`XCOMHISTORY.GetGameStateForObjectID(PendingLaunchID));
	`log("launch now id=" $ PendingLaunchID @ "paused=" $ class'CoopHarness'.static.BoolStr(WorldInfo.Pauser != none),, 'CoopExp');
	if (Pick == none)
	{
		return;
	}
	`GAME.PrepareTacticalBattle(Pick.ObjectID);
	if (XComGameState_MissionSiteAvengerAttack(Pick) != none)
	{
		// what the defense's squad screen does when it closes: squad on board, then ConfirmMission
		XComGameState_MissionSiteAvengerAttack(Pick).SquadSelectionCompleted();
	}
	else
	{
		Pick.ConfirmMission();
	}
}

// "@stronghold [CHOSEN]" / "@chosenassault [CHOSEN]": the HQ cheats for a Chosen's stronghold mission and for a
// Chosen's attack on the Avenger. CHOSEN is a Chosen template name; empty picks the first Chosen of the campaign.
function ChosenCheat(string ChosenArg, bool bAssault)
{
	local XComHeadquartersCheatManager Cheats;
	local XComGameState_AdventChosen Chosen;
	local XComGameState_MissionSite Mission;
	local name ChosenName, Source;
	local string All;

	Cheats = XComHeadquartersCheatManager(GetALocalPlayerController().CheatManager);
	if (Cheats == none)
	{
		`log("chosen cheat: no HQ cheat manager",, 'CoopExp');
		return;
	}
	ChosenName = name(ChosenArg);
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_AdventChosen', Chosen)
	{
		All @= string(Chosen.GetMyTemplateName());
		if (ChosenArg == "" && ChosenName == '')
		{
			ChosenName = Chosen.GetMyTemplateName();
		}
	}
	`log("chosen cheat: chosen in campaign:" $ All $ "; using" @ ChosenName,, 'CoopExp');
	if (bAssault)
	{
		Source = 'MissionSource_ChosenAvengerAssault';
		Cheats.TriggerChosenAvengerAssault(ChosenName);
	}
	else
	{
		Source = 'MissionSource_ChosenStronghold';
		Cheats.SpawnChosenStrongholdMission(ChosenName);
	}
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_MissionSite', Mission)
	{
		if (Mission.Source == Source)
		{
			`log("chosen cheat: mission id=" $ Mission.ObjectID @ "source=" $ Source @ "available=" $ class'CoopHarness'.static.BoolStr(Mission.Available)
				@ "type=" $ Mission.GeneratedMission.Mission.sType,, 'CoopExp');
		}
	}
}

// "@avengerdefense": the SpawnUFO cheat's UFO, then its CreateAvengerDefenseMission in the Avenger's region
// (what XComGameState_UFO.Update does when the interception succeeds, without the chase on the map).
function SpawnAvengerDefense()
{
	local XComGameState NewGameState;
	local XComGameState_UFO UFOState;
	local XComGameState_MissionSiteAvengerDefense Mission;

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop test: spawn UFO");
	UFOState = XComGameState_UFO(NewGameState.CreateNewStateObject(class'XComGameState_UFO'));
	UFOState.PostCreateInit(NewGameState, false);
	`GAMERULES.SubmitGameState(NewGameState);
	Mission = UFOState.CreateAvengerDefenseMission(`XCOMHQ.Region);
	if (Mission == none)
	{
		`log("avengerdefense: no mission created",, 'CoopExp');
		return;
	}
	Mission = XComGameState_MissionSiteAvengerDefense(`XCOMHISTORY.GetGameStateForObjectID(Mission.ObjectID));
	`log("avengerdefense ufo=" $ UFOState.ObjectID @ "mission=" $ Mission.ObjectID @ "source=" $ Mission.Source
		@ "type=" $ Mission.GeneratedMission.Mission.sType @ "available=" $ class'CoopHarness'.static.BoolStr(Mission.Available),, 'CoopExp');
}

// "@ironman": turn Ironman on for this campaign (as the new-campaign screen's toggle does), one ordinary frame.
function SetIronman()
{
	local XComGameState NewGameState;
	local XComGameState_CampaignSettings Settings;

	Settings = XComGameState_CampaignSettings(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_CampaignSettings'));
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop test: ironman");
	Settings = XComGameState_CampaignSettings(NewGameState.ModifyStateObject(class'XComGameState_CampaignSettings', Settings.ObjectID));
	Settings.SetIronmanEnabled(true);
	`GAMERULES.SubmitGameState(NewGameState);
	`log("ironman on=" $ class'CoopHarness'.static.BoolStr(Settings.bIronmanEnabled),, 'CoopExp');
}

// "@squadselect": the squad screen for the first available mission, as MissionSite.SelectSquad opens it.
function OpenSquadSelect()
{
	local XComGameState_MissionSite Mission, Pick;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_MissionSite', Mission)
	{
		if (Mission.Available && Mission.GetMissionSource().bRequiresSkyrangerTravel && Mission.Source != 'MissionSource_Final')
		{
			Pick = Mission;
			break;
		}
	}
	if (Pick == none)
	{
		`log("squadselect: no available mission",, 'CoopExp');
		return;
	}
	`GAME.PrepareTacticalBattle(Pick.ObjectID);
	`HQPRES.UISquadSelect();
	`log("squadselect mission=" $ Pick.ObjectID,, 'CoopExp');
}

//---------------------------------------------------------------------------------------
// "@camtest": pan the camera with the keyboard (D held for 2 s, through the input object's current state, as a
// key press would arrive) and log how far the view moved. While watching another player's turn the input is in
// the multiplayer "inactive" state, which still lets the camera move.

function Vector ViewLocation()
{
	local Vector Loc;
	local Rotator Rot;

	GetALocalPlayerController().GetPlayerViewPoint(Loc, Rot);
	return Loc;
}

function string InputStateName()
{
	local PlayerController PC;

	PC = GetALocalPlayerController();
	return (PC.PlayerInput != none) ? string(PC.PlayerInput.GetStateName()) : "none";
}

function CamTest()
{
	CamTestStart = ViewLocation();
	CamTestTicks = 20;
	`log("camtest start input=" $ InputStateName() @ "watching=" $ class'CoopHarness'.static.BoolStr(`REPLAY != none && `REPLAY.bInReplay)
		@ "at=" $ CamTestStart,, 'CoopExp');
	SetTimer(0.1f, true, nameof(CamTestTick));
}

function CamTestTick()
{
	local XComTacticalInput TacInput;

	TacInput = XComTacticalInput(GetALocalPlayerController().PlayerInput);
	if (TacInput != none)
	{
		TacInput.Key_D(class'UIUtilities_Input'.const.FXS_ACTION_PRESS);
	}
	if (--CamTestTicks > 0)
	{
		return;
	}
	ClearTimer(nameof(CamTestTick));
	`log("camtest done input=" $ InputStateName() @ "watching=" $ class'CoopHarness'.static.BoolStr(`REPLAY != none && `REPLAY.bInReplay)
		@ "moved=" $ int(VSize(ViewLocation() - CamTestStart)),, 'CoopExp');
}

function LogRulesLocTick()
{
	RulesLocLeft -= 5.0f;
	LogRulesLoc();
	if (RulesLocLeft <= 0)
	{
		ClearTimer(nameof(LogRulesLocTick));
	}
}

// Ruleset class and state, where its state code waits (CoopTacticalRuleset only), visualizer and movies.
function LogRulesLoc()
{
	local X2GameRuleset Rules;
	local XComPlayerController PC;
	local string Where;

	Rules = `XCOMGAME.GameRuleset;
	PC = XComPlayerController(GetALocalPlayerController());
	if (CoopTacticalRuleset(Rules) != none)
	{
		Where = CoopTacticalRuleset(Rules).WhereWaiting();
	}
	`log("rulesloc class=" $ ((Rules != none) ? string(Rules.Class.Name) : "none") @ "state=" $ ((Rules != none) ? string(Rules.GetStateName()) : "-")
		@ "where=" $ Where
		@ "visBusy=" $ class'CoopHarness'.static.BoolStr(class'XComGameStateVisualizationMgr'.static.VisualizerBusy())
		@ "visTree=" $ class'CoopHarness'.static.BoolStr(`XCOMVISUALIZATIONMGR != none && `XCOMVISUALIZATIONMGR.VisualizationTree != none)
		@ "movie=" $ class'CoopHarness'.static.BoolStr(class'XComEngine'.static.IsAnyMoviePlaying())
		@ "loadingMovie=" $ class'CoopHarness'.static.BoolStr(class'XComEngine'.static.IsLoadingMoviePlaying())
		@ "travelProcessed=" $ class'CoopHarness'.static.BoolStr(PC != none && PC.bProcessedTravelDestinationLoaded)
		@ "screen=" $ ((`SCREENSTACK != none && `SCREENSTACK.GetCurrentScreen() != none) ? string(`SCREENSTACK.GetCurrentScreen().Class.Name) : "none"),, 'CoopExp');
}

// What any key does on the loaded drop-ship briefing (XComInputBase): CleanupDropshipStart.
function PollMissionStart()
{
	local XComPlayerController PC;

	PC = XComPlayerController(GetALocalPlayerController());
	MissionStartLeft -= 0.5f;
	if (PC != none && PC.bSeamlessTravelDestinationLoaded && !PC.bProcessedTravelDestinationLoaded)
	{
		ClearTimer(nameof(PollMissionStart));
		`log("missionstart: map loaded, leaving the drop-ship briefing",, 'CoopExp');
		PC.CleanupDropshipStart();
	}
	else if (MissionStartLeft <= 0)
	{
		ClearTimer(nameof(PollMissionStart));
		`log("missionstart: TIMEOUT (loaded=" $ class'CoopHarness'.static.BoolStr(PC != none && PC.bSeamlessTravelDestinationLoaded)
			@ "processed=" $ class'CoopHarness'.static.BoolStr(PC != none && PC.bProcessedTravelDestinationLoaded) $ ")",, 'CoopExp');
	}
}

// Mission summary -> after action -> loot screen, one stage per call.
function AfterAction()
{
	local UIScreen Screen;

	// script warnings (UIRedScreen, the game is started without -noRedScreens) cover the screens below
	Screen = `SCREENSTACK.GetCurrentScreen();
	while (UIRedScreen(Screen) != none)
	{
		Screen.CloseScreen();
		Screen = `SCREENSTACK.GetCurrentScreen();
	}
	`log("afteraction screen=" $ Screen.Class.Name,, 'CoopExp');
	if (UIChosenMissionSummary(Screen) != none)
	{
		// after a mission with a Chosen; closing it opens the regular UIMissionSummary
		UIChosenMissionSummary(Screen).CloseScreen();
	}
	else if (UIMissionSummary(Screen) != none)
	{
		UIMissionSummary(Screen).CloseScreen();
	}
	else if (UIAfterAction(Screen) != none)
	{
		UIAfterAction(Screen).OnContinue();
	}
	else if (UIInventory_LootRecovered(Screen) != none)
	{
		UIInventory_LootRecovered(Screen).CloseScreen();
	}
	else if (UIDropShipBriefing_MissionEnd(Screen) != none && XComPlayerController(GetALocalPlayerController()).bSeamlessTravelDestinationLoaded)
	{
		// "press a key to continue" (what UIDropShipHUD does on a key press)
		WorldInfo.bContinueToSeamlessTravelDestination = true;
		`log("afteraction: continue from the mission-end drop-ship",, 'CoopExp');
	}
}

//---------------------------------------------------------------------------------------
// Tactical

function LogGroups()
{
	local XComGameStateHistory History;
	local XComGameState_BattleData BattleData;
	local X2TacticalGameRuleset Rules;
	local XComGameState_Player PlayerState;
	local XComGameState_AIGroup Group;
	local XComGameState_Unit Unit;
	local StateObjectReference Ref;
	local string Line, Members;
	local int i;
	local int NXCom, NAlien, NLost, NResistance, NOther;

	History = `XCOMHISTORY;
	Rules = `TACTICALRULES;
	BattleData = XComGameState_BattleData(History.GetSingleGameStateObjectForClass(class'XComGameState_BattleData'));
	for (i = 0; i < BattleData.PlayerTurnOrder.Length; i++)
	{
		PlayerState = XComGameState_Player(History.GetGameStateForObjectID(BattleData.PlayerTurnOrder[i].ObjectID));
		Group = XComGameState_AIGroup(History.GetGameStateForObjectID(BattleData.PlayerTurnOrder[i].ObjectID));
		if (PlayerState != none)
		{
			Line = "player team=" $ PlayerState.GetTeam() @ "turns=" $ PlayerState.PlayerTurnCount;
		}
		else if (Group != none)
		{
			Members = "";
			foreach Group.m_arrMembers(Ref)
			{
				Unit = XComGameState_Unit(History.GetGameStateForObjectID(Ref.ObjectID));
				Members @= Ref.ObjectID $ "/" $ ((Unit != none) ? string(OwnerOf(Unit)) : "?");
				// an XCom unit nobody owns (not a soldier given to a player): say what it is
				if (Unit != none && Group.TeamName == eTeam_XCom && OwnerOf(Unit) < 0)
				{
					Members $= "(" $ Unit.GetMyTemplateName() $ ")";
				}
			}
			Line = "group team=" $ Group.TeamName @ "prio=" $ Group.InitiativePriority @ "members=" $ Members
				@ "runBy=" $ class'CoopTactical'.static.ControllerOfInitiative(Group) @ "remote=" $ class'CoopHarness'.static.BoolStr(class'CoopTactical'.static.IsInitiativeRemote(Group));
		}
		else
		{
			Line = "other";
		}
		`log("order" @ i @ "id=" $ BattleData.PlayerTurnOrder[i].ObjectID @ Line
			@ ((Rules != none && Rules.CachedUnitActionInitiativeRef.ObjectID == BattleData.PlayerTurnOrder[i].ObjectID) ? "<- ACTIVE" : ""),, 'CoopExp');
	}
	// living units per team (a mission whose kismet finds no aliens ends at the first alien turn)
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (Unit.IsAlive() && !Unit.bRemovedFromPlay && Unit.GetMyTemplate() != none && !Unit.GetMyTemplate().bIsCosmetic)
		{
			switch (Unit.GetTeam())
			{
				case eTeam_XCom: NXCom++; break;
				case eTeam_Alien: NAlien++; break;
				case eTeam_TheLost: NLost++; break;
				case eTeam_Resistance: NResistance++; break;
				default: NOther++; break;
			}
		}
	}
	`log("units xcom=" $ NXCom @ "alien=" $ NAlien @ "lost=" $ NLost @ "resistance=" $ NResistance @ "other=" $ NOther,, 'CoopExp');
}

function CheckPauseAndClose()
{
	local UIScreen Screen;

	Screen = `SCREENSTACK.GetScreen(class'UIPauseMenu');
	// save= : the menu offers "Save" (the host saves the shared campaign, also inside a mission)
	`log("tacpause paused=" $ class'CoopHarness'.static.BoolStr(WorldInfo.Pauser != none)
		@ "save=" $ class'CoopHarness'.static.BoolStr(UIPauseMenu(Screen) != none && UIPauseMenu(Screen).m_optSave >= 0),, 'CoopExp');
	if (Screen != none)
	{
		Screen.CloseScreen();
	}
	SetTimer(1.0f, false, nameof(CheckUnpaused));
}

function CheckUnpaused()
{
	`log("tacpause closed paused=" $ class'CoopHarness'.static.BoolStr(WorldInfo.Pauser != none),, 'CoopExp');
}

// Which classes the co-op rule overrides put in place (CoopRules), and whether they apply now.
function LogMPRules()
{
	local X2AbilityTemplateManager Mgr;
	local X2AbilityTemplate Template;
	local X2AbilityToHitCalc NewCalc;
	local X2Effect Effect;
	local string Suppress, ShotCalc;
	local int i;

	Mgr = class'X2AbilityTemplateManager'.static.GetAbilityTemplateManager();
	NewCalc = new class'X2AbilityToHitCalc_StandardAim';
	ShotCalc = "none";
	Template = Mgr.FindAbilityTemplate('StandardShot');
	if (Template != none && Template.AbilityToHitCalc != none)
	{
		ShotCalc = string(Template.AbilityToHitCalc.Class.Name);
	}
	Template = Mgr.FindAbilityTemplate('Suppression');
	if (Template != none)
	{
		for (i = 0; i < Template.AbilityTargetEffects.Length; i++)
		{
			Effect = Template.AbilityTargetEffects[i];
			Suppress = Suppress @ string(Effect.Class.Name);
		}
	}
	`log("mprules coopMP=" $ class'CoopHarness'.static.BoolStr(class'CoopRules'.static.CoopMP())
		@ "newAim=" $ string(NewCalc.Class.Name)
		@ "StandardShot=" $ ShotCalc
		@ "SuppressionEffects=" $ Suppress
		@ "MP_FLANKING_CRIT_BONUS=" $ class'X2AbilityToHitCalc_StandardAim'.default.MP_FLANKING_CRIT_BONUS
		@ "LOW_COVER_BONUS base=" $ class'X2AbilityToHitCalc_StandardAim'.default.LOW_COVER_BONUS @ "coop=" $ class'CoopToHitCalc_StandardAim'.default.LOW_COVER_BONUS,, 'CoopExp');
}

// What the engine's single/multiplayer checks say right now (alien spawning, mission objectives, drop-ship,
// autosave and flank crits all branch on them).
function LogNetMode()
{
	local WorldInfo WI;

	WI = class'WorldInfo'.static.GetWorldInfo();
	`log("netmode NetMode=" $ WI.NetMode @ "single=" $ class'CoopHarness'.static.BoolStr(class'Engine'.static.GetEngine().IsSinglePlayerGame())
		@ "multi=" $ class'CoopHarness'.static.BoolStr(class'Engine'.static.GetEngine().IsMultiPlayerGame())
		@ "griMulti=" $ class'CoopHarness'.static.BoolStr(WI.GRI != none && WI.GRI.IsMultiPlayerGame())
		@ "server=" $ class'CoopHarness'.static.BoolStr(`XCOMNETMANAGER.HasServerConnection())
		@ "client=" $ class'CoopHarness'.static.BoolStr(`XCOMNETMANAGER.HasClientConnection())
		@ "conns=" $ class'CoopHarness'.static.BoolStr(`XCOMNETMANAGER.HasConnections())
		@ "game=" $ WI.Game,, 'CoopExp');
}

// Experiment 2: move slot-1 soldiers into a second XCom group that acts after the first.
function SplitXComGroup()
{
	local XComGameState NewGameState;
	local int Moved;

	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop experiment: split XCom group");
	Moved = class'CoopTactical'.static.SplitXComGroup(NewGameState);
	if (Moved == 0)
	{
		`XCOMHISTORY.CleanupPendingGameState(NewGameState);
		`log("split: no slot-1 units in a group",, 'CoopExp');
		return;
	}
	`TACTICALRULES.SubmitGameState(NewGameState);
	`log("split moved=" $ Moved,, 'CoopExp');
	LogGroups();
}

// Which XCom units the rules let act now, and whether the controller lets them be selected.
function LogActors()
{
	local X2TacticalGameRuleset Rules;
	local XComGameState_Unit Unit;
	local XComGameState_AIGroup Group;

	Rules = `TACTICALRULES;
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (Unit.GetTeam() != eTeam_XCom || !Unit.IsSoldier())
		{
			continue;
		}
		Group = Unit.GetGroupMembership();
		`log("actor unit=" $ Unit.ObjectID @ "owner=" $ OwnerOf(Unit) @ "group=" $ ((Group != none) ? Group.ObjectID : 0)
			@ "groupActive=" $ class'CoopHarness'.static.BoolStr(Group != none && Group.ObjectID == Rules.CachedUnitActionInitiativeRef.ObjectID)
			@ "hasActions=" $ class'CoopHarness'.static.BoolStr(Rules.UnitHasActionsAvailable(Unit)),, 'CoopExp');
	}
}

// Try to select every XCom soldier; logs which selections the controller allowed.
function TrySelectAll()
{
	local XComTacticalController TC;
	local XComGameState_Unit Unit;

	TC = XComTacticalController(GetALocalPlayerController());
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (Unit.GetTeam() == eTeam_XCom && Unit.IsSoldier())
		{
			`log("trysel unit=" $ Unit.ObjectID @ "owner=" $ OwnerOf(Unit) @ "local=" $ class'CoopRole'.static.LocalSlot()
				@ "selected=" $ class'CoopHarness'.static.BoolStr(TC.Visualizer_SelectUnit(Unit)),, 'CoopExp');
		}
	}
}

// Log every change of the entry that has initiative (player or group), with the turn number.
function WatchTurns()
{
	local X2TacticalGameRuleset Rules;
	local XComGameState_BattleData BattleData;

	Rules = `TACTICALRULES;
	WatchLeft -= 0.25f;
	if (Rules != none && Rules.CachedUnitActionInitiativeRef.ObjectID != LastInitiativeID)
	{
		LastInitiativeID = Rules.CachedUnitActionInitiativeRef.ObjectID;
		BattleData = XComGameState_BattleData(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_BattleData'));
		`log("turn initiative=" $ LastInitiativeID @ "player=" $ Rules.GetCachedUnitActionPlayerRef().ObjectID
			@ "turn=" $ BattleData.TacticalTurnCount,, 'CoopExp');
	}
	if (WatchLeft <= 0)
	{
		ClearTimer(nameof(WatchTurns));
		`log("watchturns done",, 'CoopExp');
	}
}

defaultproperties
{
	bAlwaysTick=true    // @launch's timer fires while the world is paused
}

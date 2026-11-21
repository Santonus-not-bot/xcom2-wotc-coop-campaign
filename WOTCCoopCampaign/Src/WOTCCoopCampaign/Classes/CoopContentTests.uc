//---------------------------------------------------------------------------------------
//  FILE:    CoopContentTests.uc
//  PURPOSE: Harness commands for game content that changes who controls a unit (mind control,
//           enemies of other teams). Run on the machine whose turn it is, like a player's action.
//           Unit specs: alien | lost | xcom | template:NAME | mc / mcxcom / mcalien (a mind-controlled unit, on any or
//           that side) | owner:N (a soldier of slot N on the XCom side) | ownerany:N (any side) | unit:ID. Result lines use the 'CoopContent' tag.
//---------------------------------------------------------------------------------------
class CoopContentTests extends Object;

// Returns false for commands this class does not know.
static function bool Run(string Cmd)
{
	local array<string> Args;

	if (Left(Cmd, 11) ~= "useability ")
	{
		// "@useability SRC ABILITY TGT [contest:N]": SRC uses ABILITY on TGT, as the X2UseAbility cheat does
		// (ability granted if missing, no validation, forced hit; contest:N sets the stat contest result,
		// which picks the effect of a stat-contest ability such as StunImpairingAbility: 3-4 = stunned)
		Args = SplitString(Mid(Cmd, 11), " ", true);
		if (Args.Length < 3)
		{
			`log("useability: needs SRC ABILITY TGT",, 'CoopContent');
		}
		else
		{
			UseAbility(Args[0], name(Args[1]), Args[2], (Args.Length > 3 && Left(Args[3], 8) ~= "contest:") ? int(Mid(Args[3], 8)) : -1);
		}
	}
	else if (Left(Cmd, 9) ~= "dropunit ")
	{
		// "@dropunit TEMPLATE TEAM [TILES]": a unit of TEAM (alien | lost | resistance) about TILES (default 6)
		// tiles from the first host soldier, as the DropUnit cheat does
		Args = SplitString(Mid(Cmd, 9), " ", true);
		if (Args.Length < 2)
		{
			`log("dropunit: needs TEMPLATE TEAM",, 'CoopContent');
		}
		else
		{
			DropUnitNearSquad(name(Args[0]), Args[1], (Args.Length > 2) ? int(Args[2]) : 6);
		}
	}
	else if (Left(Cmd, 5) ~= "mark ")
	{
		// a fixed line for the runner to find at a point in the step list
		`log("mark" @ Mid(Cmd, 5),, 'CoopContent');
	}
	else if (Cmd ~= "captured")
	{
		LogCaptured();
	}
	else if (Cmd ~= "mcstate")
	{
		LogUnitControl();
	}
	else if (Left(Cmd, 9) ~= "shotinfo ")
	{
		// "@shotinfo P": the game's shot breakdown for a standard shot by one of slot P's soldiers on an alien it flanks
		LogFlankShot(int(Mid(Cmd, 9)));
	}
	else if (Left(Cmd, 6) ~= "owned ")
	{
		// "@owned P": how many living soldiers of slot P in this mission are on each side
		LogOwnedCount(int(Mid(Cmd, 6)));
	}
	else if (Left(Cmd, 8) ~= "stunned ")
	{
		// "@stunned P": how many living soldiers of slot P are stunned (the Stunned effect is on them)
		LogStunnedCount(int(Mid(Cmd, 8)));
	}
	else if (Left(Cmd, 5) ~= "move ")
	{
		// "@move SPEC TILES": that unit walks to a reachable tile about TILES away, through the controller's
		// move, as a click on a tile does (the game's own path and validation)
		Args = SplitString(Mid(Cmd, 5), " ", true);
		MoveUnit(Args[0], Args.Length > 1 ? int(Args[1]) : 4);
	}
	else if (Left(Cmd, 7) ~= "moveto ")
	{
		// "@moveto SPEC TARGET": that unit walks to the reachable tile nearest the TARGET unit (at least 2 tiles
		// from it), as a click there does; e.g. into the view of an enemy on overwatch
		Args = SplitString(Mid(Cmd, 7), " ", true);
		MoveUnitToward(Args[0], Args[1]);
	}
	else if (Left(Cmd, 9) ~= "interact ")
	{
		// "@interact ABILITY SPEC": a unit matching SPEC uses ABILITY (e.g. Interact_TakeVial) on the mission's
		// objective object, as the game does after its hacking screen (no validation; the unit need not stand next to it)
		Args = SplitString(Mid(Cmd, 9), " ", true);
		InteractWithObjective(name(Args[0]), Args.Length > 1 ? Args[1] : "xcom");
	}
	else if (Cmd ~= "loadtest")
	{
		// "@loadtest": put up the guest's mission loading screen here (any map), to see it in a screenshot
		class'CoopMissionLoading'.static.TestBegin();
	}
	else if (Cmd ~= "loadtestend")
	{
		class'CoopMissionLoading'.static.End("test over");
	}
	else if (Cmd ~= "pingbind")
	{
		// "@pingbind": which key the tactical input binds to CoopPing on this machine, and what Alt + left click runs
		LogPingBinding();
	}
	else if (Cmd ~= "pawns")
	{
		// "@pawns": compare each XCOM unit's model (pawn) position on this machine with its game-state tile
		LogPawns();
	}
	else if (Left(Cmd, 12) ~= "actionwatch ")
	{
		// "@actionwatch SECONDS": log each visualization action / cinematic actor class that appears here
		class'CoopActionWatch'.static.Start(float(Mid(Cmd, 12)));
	}
	else if (Left(Cmd, 6) ~= "goobj ")
	{
		// "@goobj SPEC": if a unit matching SPEC is offered an ability on the mission's (unhacked) objective
		// object, use it through the HUD's call (normal validation); otherwise the matching unit nearest the
		// object walks toward it. Repeat each turn until it logs "goobj use"
		GoToObjective(Mid(Cmd, 6));
	}
	else if (Cmd ~= "hackscreen")
	{
		// "@hackscreen": on an open hacking screen, start the hack with the selected reward (as Enter does), or,
		// once it has started, close it (as the key press after the result does)
		DriveHackScreen();
	}
	else if (Cmd ~= "evacstate")
	{
		// "@evacstate": evac zones in the history and whether the mission's objective object has been hacked
		LogEvacState();
	}
	else if (Cmd ~= "objectives")
	{
		// "@objectives": every objective of the active mission and whether it is complete, on this machine
		LogObjectives();
	}
	else if (Left(Cmd, 10) ~= "unitcount ")
	{
		// "@unitcount TEMPLATE": living units of that template on this machine, per team
		LogUnitCount(name(Mid(Cmd, 10)));
	}
	else if (Left(Cmd, 10) ~= "listeners ")
	{
		// "@listeners SPEC": for each of that unit's abilities with an event-listener trigger (OverwatchShot listens
		// on ObjectMoved), is the listener registered on THIS machine; and the unit's reserved (overwatch) points
		LogUnitListeners(Mid(Cmd, 10));
	}
	else if (Left(Cmd, 6) ~= "shoot ")
	{
		// "@shoot SPEC": the first unit matching SPEC that can take a standard shot fires at the first target the
		// game offers, through the call the HUD's fire button makes (normal validation and hit roll)
		Shoot(Mid(Cmd, 6));
	}
	else if (Left(Cmd, 7) ~= "ustate ")
	{
		// "@ustate ABILITY WHO": every unit as of the last frame in which WHO used ABILITY; the runner compares
		// these lines between machines (sameustate). ABILITY "*" = any; WHO = a player slot, "alien" or "any"
		Args = SplitString(Mid(Cmd, 7), " ", true);
		LogUnitStatesAfter(Args[0], Args[1]);
	}
	else if (Cmd ~= "winmission")
	{
		// "@winmission": host only. Mark every objective of this mission complete, then win (the EndBattle
		// cheat alone wins without them, so a story mission stays on the Geoscape)
		WinMission();
	}
	else if (Left(Cmd, 9) ~= "removemc ")
	{
		// "@removemc SPEC": end the mind control on that unit, as a cleanse would
		RemoveMindControl(Mid(Cmd, 9));
	}
	else if (Left(Cmd, 7) ~= "trysel ")
	{
		TrySelect(Mid(Cmd, 7));
	}
	else
	{
		return false;
	}
	return true;
}

// "eTeam_XCom" rather than the enum's number
static function string TeamStr(ETeam Team)
{
	return string(GetEnum(Enum'ETeam', Team));
}

static function bool UnitMatches(XComGameState_Unit Unit, string Spec)
{
	if (!Unit.IsAlive() || Unit.bRemovedFromPlay || Unit.GetMyTemplate() == none || Unit.GetMyTemplate().bIsCosmetic)
	{
		return false;
	}
	if (Left(Spec, 5) ~= "unit:")
	{
		return Unit.ObjectID == int(Mid(Spec, 5));
	}
	if (Left(Spec, 9) ~= "template:")
	{
		return Unit.GetMyTemplateName() == name(Mid(Spec, 9));
	}
	if (Left(Spec, 9) ~= "ownerany:")
	{
		return Unit.IsSoldier() && class'CoopOwnership'.static.OwnerOf(Unit) == int(Mid(Spec, 9));
	}
	if (Left(Spec, 6) ~= "owner:")
	{
		// a soldier of that player still on the XCom side
		return Unit.IsSoldier() && Unit.GetTeam() == eTeam_XCom && !Unit.IsMindControlled()
			&& class'CoopOwnership'.static.OwnerOf(Unit) == int(Mid(Spec, 6));
	}
	if (Spec ~= "mc")
	{
		return Unit.IsMindControlled();
	}
	// a mind-controlled unit now on that side
	if (Spec ~= "mcxcom")
	{
		return Unit.IsMindControlled() && Unit.GetTeam() == eTeam_XCom;
	}
	if (Spec ~= "mcalien")
	{
		return Unit.IsMindControlled() && Unit.GetTeam() == eTeam_Alien;
	}
	if (Spec ~= "alien")
	{
		return Unit.GetTeam() == eTeam_Alien && !Unit.IsMindControlled() && !Unit.GetMyTemplate().bIsTurret;
	}
	if (Spec ~= "lost")
	{
		return Unit.GetTeam() == eTeam_TheLost;
	}
	if (Spec ~= "xcom")
	{
		return Unit.GetTeam() == eTeam_XCom && Unit.IsSoldier();
	}
	return false;
}

static function XComGameState_Unit FindUnit(string Spec)
{
	local XComGameState_Unit Unit, Newest;

	// "newest:TEMPLATE": the living unit of that template with the highest ObjectID, i.e. the one dropped last
	// (the same unit on every machine; "template:" finds the first, which may be a pod's far away)
	if (Left(Spec, 7) ~= "newest:")
	{
		foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
		{
			if (UnitMatches(Unit, "template:" $ Mid(Spec, 7)) && (Newest == none || Unit.ObjectID > Newest.ObjectID))
			{
				Newest = Unit;
			}
		}
		return Newest;
	}
	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (UnitMatches(Unit, Spec))
		{
			return Unit;
		}
	}
	return none;
}

// "@trysel SPEC": can this machine select that unit now (the selection gate plus the game's own rules)?
static function TrySelect(string Spec)
{
	local XComGameState_Unit Unit;
	local XComTacticalController TC;

	Unit = FindUnit(Spec);
	TC = XComTacticalController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController());
	if (Unit == none || TC == none)
	{
		`log("trysel" @ Spec @ "failed: unit=" $ (Unit != none) @ "controller=" $ (TC != none),, 'CoopContent');
		return;
	}
	`log("trysel" @ Spec @ "unit=" $ Unit.ObjectID @ "team=" $ TeamStr(Unit.GetTeam()) @ "owner=" $ class'CoopOwnership'.static.OwnerOf(Unit)
		@ "selected=" $ class'CoopHarness'.static.BoolStr(TC.Visualizer_SelectUnit(Unit)),, 'CoopContent');
}

static function UseAbility(string SourceSpec, name AbilityName, string TargetSpec, optional int Contest = -1)
{
	local XComGameStateHistory History;
	local X2TacticalGameRuleset Rules;
	local X2AbilityTemplate Template;
	local XComGameState NewGameState;
	local XComGameState_Unit Source, Target;
	local XComGameState_Ability Ability;
	local XComGameStateContext_Ability Context;
	local array<int> NoTargets;
	local array<vector> Locations;
	local bool bSubmitted;

	History = `XCOMHISTORY;
	Rules = `TACTICALRULES;
	Source = FindUnit(SourceSpec);
	Target = FindUnit(TargetSpec);
	Template = class'X2AbilityTemplateManager'.static.GetAbilityTemplateManager().FindAbilityTemplate(AbilityName);
	if (Source == none || Target == none || Template == none || Rules == none)
	{
		`log("useability failed: source=" $ SourceSpec $ "/" $ (Source != none) @ "target=" $ TargetSpec $ "/" $ (Target != none)
			@ "ability=" $ AbilityName $ "/" $ (Template != none),, 'CoopContent');
		return;
	}
	if (Source.FindAbility(AbilityName).ObjectID <= 0)
	{
		NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop test: grant ability" @ AbilityName);
		Rules.InitAbilityForUnit(Template, XComGameState_Unit(NewGameState.ModifyStateObject(class'XComGameState_Unit', Source.ObjectID)), NewGameState);
		Rules.SubmitGameState(NewGameState);
		Source = XComGameState_Unit(History.GetGameStateForObjectID(Source.ObjectID));
	}
	Ability = XComGameState_Ability(History.GetGameStateForObjectID(Source.FindAbility(AbilityName).ObjectID));
	if (Ability == none)
	{
		`log("useability failed: unit" @ Source.ObjectID @ "has no" @ AbilityName,, 'CoopContent');
		return;
	}
	NoTargets.Length = 0;
	Locations.AddItem(`XWORLD.GetPositionFromTileCoordinates(Target.TileLocation));
	Context = class'XComGameStateContext_Ability'.static.BuildContextFromAbility(Ability, Target.ObjectID, NoTargets, Locations);
	Context.bSkipValidation = true;
	Context.ResultContext.HitResult = eHit_Success;
	if (Contest >= 0)
	{
		Context.ResultContext.StatContestResult = Contest;
	}
	bSubmitted = Rules.SubmitGameStateContext(Context);
	`log("useability" @ AbilityName @ "source=" $ Source.ObjectID @ "(" $ TeamStr(Source.GetTeam()) $ ") target=" $ Target.ObjectID
		@ "(" $ TeamStr(Target.GetTeam()) @ "owner=" $ class'CoopOwnership'.static.OwnerOf(Target) $ ") submitted=" $ class'CoopHarness'.static.BoolStr(bSubmitted),, 'CoopContent');
}

static function DropUnitNearSquad(name Template, string TeamSpec, int Tiles)
{
	local XComGameStateHistory History;
	local XComGameState_BattleData BattleData;
	local XComGameState_Player PlayerState;
	local XComTacticalCheatManager Cheats;
	local XComGameState_Unit Anchor, Dropped;
	local StateObjectReference Ref, NewUnit;
	local ETeam Team;
	local TTile Tile;
	local vector Position;
	local int PlayerIndex, TeamIndex, Try;

	History = `XCOMHISTORY;
	Team = eTeam_Alien;
	if (TeamSpec ~= "lost")
	{
		Team = eTeam_TheLost;
	}
	else if (TeamSpec ~= "resistance")
	{
		Team = eTeam_Resistance;
	}
	else if (TeamSpec ~= "xcom")
	{
		Team = eTeam_XCom;    // a unit joining XCOM mid-mission, as a rescued soldier or VIP does
	}
	// DropUnitAt takes the index among the players in the turn order
	BattleData = XComGameState_BattleData(History.GetSingleGameStateObjectForClass(class'XComGameState_BattleData'));
	PlayerIndex = -1;
	TeamIndex = -1;
	foreach BattleData.PlayerTurnOrder(Ref)
	{
		PlayerState = XComGameState_Player(History.GetGameStateForObjectID(Ref.ObjectID));
		if (PlayerState != none)
		{
			PlayerIndex++;
			if (PlayerState.TeamFlag == Team)
			{
				TeamIndex = PlayerIndex;
				break;
			}
		}
	}
	Cheats = XComTacticalCheatManager(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController().CheatManager);
	Anchor = FindUnit("owner:0");
	if (Anchor == none)
	{
		Anchor = FindUnit("xcom");
	}
	if (TeamIndex < 0 || Cheats == none || Anchor == none)
	{
		`log("dropunit failed: team=" $ TeamSpec @ "index=" $ TeamIndex @ "cheats=" $ (Cheats != none) @ "anchor=" $ (Anchor != none),, 'CoopContent');
		return;
	}
	for (Try = 0; Try < 8 && NewUnit.ObjectID <= 0; Try++)
	{
		Tile = Anchor.TileLocation;
		Tile.X += (Try % 2 == 0) ? Tiles + Try : -(Tiles + Try);
		Tile.Y += (Try % 4 < 2) ? Try : -Try;
		Position = `XWORLD.GetPositionFromTileCoordinates(Tile);
		Position = `XWORLD.GetValidSpawnLocation(Position);
		NewUnit = Cheats.DropUnitAt(Position, Template, TeamIndex);
	}
	Dropped = XComGameState_Unit(History.GetGameStateForObjectID(NewUnit.ObjectID));
	`log("dropunit" @ Template @ "team=" $ ((Dropped != none) ? TeamStr(Dropped.GetTeam()) : "none") @ "unit=" $ NewUnit.ObjectID
		@ "group=" $ ((Dropped != none && Dropped.GetGroupMembership() != none) ? string(Dropped.GetGroupMembership().ObjectID) : "none"),, 'CoopContent');
}

// Every unit whose control matters: soldiers with an owner, and mind-controlled units.
static function LogUnitControl()
{
	local XComGameState_Unit Unit;
	local XComGameState_AIGroup Group;
	local int UnitOwner;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (!Unit.IsAlive())
		{
			continue;
		}
		UnitOwner = class'CoopOwnership'.static.OwnerOf(Unit);
		if (UnitOwner == class'CoopOwnership'.const.NO_OWNER && !Unit.IsMindControlled())
		{
			continue;
		}
		Group = Unit.GetGroupMembership();
		`log("control unit=" $ Unit.ObjectID @ "team=" $ TeamStr(Unit.GetTeam()) @ "owner=" $ UnitOwner
			@ "mc=" $ class'CoopHarness'.static.BoolStr(Unit.IsMindControlled())
			@ "group=" $ ((Group != none) ? string(Group.ObjectID) : "none")
			@ "groupTeam=" $ ((Group != none) ? string(Group.TeamName) : "none")
			@ "runBy=" $ ((Group != none) ? string(class'CoopTactical'.static.ControllerOfInitiative(Group)) : "none")
			@ "ap=" $ Unit.ActionPoints.Length @ "removed=" $ class'CoopHarness'.static.BoolStr(Unit.bRemovedFromPlay)
			@ "stunned=" $ class'CoopHarness'.static.BoolStr(Unit.IsStunned()) @ "stunAP=" $ Unit.StunnedActionPoints
			@ "dazed=" $ class'CoopHarness'.static.BoolStr(Unit.IsDazed())
			$ MindControlTicks(Unit),, 'CoopContent');
	}
}

// How many listeners of EventID belong to the object ObjectID, counted in the event manager's debug text
// (one line per listener; the text names the delegate object as "<Class>_<n>" and its ObjectID).
static function int CountListeners(name EventID, int ObjectID)
{
	local string Text, Needle;
	local int Count, At;

	Text = `XEVENTMGR.AllEventListenersToString(EventID, "XComGameState_Effect");
	Needle = "ObjectID=" $ ObjectID;
	At = InStr(Text, Needle);
	while (At != INDEX_NONE)
	{
		Count++;
		Text = Mid(Text, At + Len(Needle));
		At = InStr(Text, Needle);
	}
	if (Count == 0 && Len(Text) > 0)
	{
		`log("listeners" @ EventID @ "for" @ ObjectID @ "none found; debug text starts:" @ Left(Text, 300),, 'CoopContent');
	}
	return Count;
}

// A mind control's countdown: turns left, and the player whose turn begins tick it (X2Effect_MindControl:
// WatchRule = eGameRule_PlayerTurnBegin, for ApplyEffectParameters.PlayerStateObjectRef).
static function string MindControlTicks(XComGameState_Unit Unit)
{
	local XComGameState_Effect Effect;
	local XComGameState_Player TickPlayer;
	local Object EffectObj;

	Effect = Unit.GetUnitAffectedByEffectState(class'X2Effect_MindControl'.default.EffectName);
	if (Effect == none)
	{
		return "";
	}
	EffectObj = Effect;
	TickPlayer = XComGameState_Player(`XCOMHISTORY.GetGameStateForObjectID(Effect.ApplyEffectParameters.PlayerStateObjectRef.ObjectID));
	return " mcleft=" $ Effect.iTurnsRemaining @ "infinite=" $ class'CoopHarness'.static.BoolStr(Effect.GetX2Effect().bInfiniteDuration)
		@ "tickTeam=" $ ((TickPlayer != none) ? TeamStr(TickPlayer.GetTeam()) : "none")
		@ "tickTurns=" $ ((TickPlayer != none) ? TickPlayer.PlayerTurnCount : -1)
		@ "listening=" $ class'CoopHarness'.static.BoolStr(`XEVENTMGR.IsRegistered(EffectObj, 'PlayerTurnBegun', ELD_OnStateSubmitted, Effect.OnPlayerTurnTicked))
		@ "listeners=" $ CountListeners('PlayerTurnBegun', Effect.ObjectID);
}

// The single-player rule says a flanking shot gets the shooter's eStat_FlankingCritChance as crit bonus; with a
// co-op connection open the game would use MP_FLANKING_CRIT_BONUS instead (CoopToHitCalc_StandardAim puts the
// stat back). Finds a soldier of slot P and a visible alien in no cover (the base code's flank test), asks the
// ability's own to-hit calculation for the breakdown and logs the flank crit modifier next to the stat.
static function LogFlankShot(int Slot)
{
	local XComGameStateHistory History;
	local XComGameState_Unit Shooter, Target;
	local XComGameState_Ability Ability;
	local StateObjectReference AbilityRef;
	local GameRulesCache_VisibilityInfo VisInfo;
	local AvailableTarget Avail;
	local ShotBreakdown Breakdown;
	local X2AbilityToHitCalc HitCalc;
	local int i, Pairs, FlankCrit;
	local bool bHasFlankMod;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_Unit', Shooter)
	{
		if (!Shooter.IsAlive() || Shooter.bRemovedFromPlay || Shooter.GetTeam() != eTeam_XCom
			|| class'CoopOwnership'.static.OwnerOf(Shooter) != Slot || !Shooter.CanFlank())
		{
			continue;
		}
		AbilityRef = Shooter.FindAbility('StandardShot');
		Ability = XComGameState_Ability(History.GetGameStateForObjectID(AbilityRef.ObjectID));
		if (Ability == none)
		{
			continue;
		}
		foreach History.IterateByClassType(class'XComGameState_Unit', Target)
		{
			if (!Target.IsAlive() || Target.bRemovedFromPlay || Target.GetTeam() != eTeam_Alien || !Target.GetMyTemplate().bCanTakeCover)
			{
				continue;
			}
			if (!`TACTICALRULES.VisibilityMgr.GetVisibilityInfo(Shooter.ObjectID, Target.ObjectID, VisInfo) || !VisInfo.bVisibleGameplay)
			{
				continue;
			}
			Pairs++;
			if (VisInfo.TargetCover != CT_None)
			{
				continue;
			}
			Avail.PrimaryTarget = Target.GetReference();
			HitCalc = Ability.GetMyTemplate().AbilityToHitCalc;
			HitCalc.GetShotBreakdown(Ability, Avail, Breakdown);
			bHasFlankMod = false;
			FlankCrit = 0;
			for (i = 0; i < Breakdown.Modifiers.Length; i++)
			{
				if (Breakdown.Modifiers[i].ModType == eHit_Crit && Breakdown.Modifiers[i].Reason == class'XLocalizedData'.default.FlankingCritBonus)
				{
					bHasFlankMod = true;
					FlankCrit += Breakdown.Modifiers[i].Value;
				}
			}
			`log("shotinfo shooter=" $ Shooter.ObjectID @ "target=" $ Target.ObjectID @ "calc=" $ HitCalc.Class.Name
				@ "coopmp=" $ class'CoopHarness'.static.BoolStr(class'CoopRules'.static.CoopMP())
				@ "mpgame=" $ class'CoopHarness'.static.BoolStr(`XENGINE.IsMultiplayerGame())
				@ "hit=" $ Breakdown.FinalHitChance @ "crit=" $ Breakdown.ResultTable[eHit_Crit]
				@ "flankmod=" $ class'CoopHarness'.static.BoolStr(bHasFlankMod)
				@ "flankcrit=" $ FlankCrit @ "stat=" $ int(Shooter.GetCurrentStat(eStat_FlankingCritChance))
				@ "mpconst=" $ class'X2AbilityToHitCalc_StandardAim'.default.MP_FLANKING_CRIT_BONUS,, 'CoopContent');
			return;
		}
	}
	`log("shotinfo: no flanked target for slot" @ Slot @ "among" @ Pairs @ "visible pairs",, 'CoopContent');
}

// "owned P xcom=N alien=N": slot P's soldiers in play on the XCom side and on the alien side (mind-controlled).
// Lets a test see a timed mind control end without knowing which soldier was taken.
static function LogOwnedCount(int Slot)
{
	local XComGameState_Unit Unit;
	local int XCom, Alien;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (!Unit.IsAlive() || Unit.bRemovedFromPlay || Unit.GetGroupMembership() == none
			|| class'CoopOwnership'.static.OwnerOf(Unit) != Slot)
		{
			continue;
		}
		if (Unit.GetTeam() == eTeam_XCom)
		{
			XCom++;
		}
		else if (Unit.GetTeam() == eTeam_Alien)
		{
			Alien++;
		}
	}
	`log("owned" @ Slot @ "xcom=" $ XCom @ "alien=" $ Alien,, 'CoopContent');
}

static function LogStunnedCount(int Slot)
{
	local XComGameState_Unit Unit;
	local int Stunned, StunAP, Dazed;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (Unit.IsAlive() && !Unit.bRemovedFromPlay && class'CoopOwnership'.static.OwnerOf(Unit) == Slot)
		{
			if (Unit.IsStunned())
			{
				Stunned++;
			}
			if (Unit.IsDazed())
			{
				Dazed++;
			}
			if (Unit.IsStunned() || Unit.IsDazed())
			{
				StunAP += Unit.StunnedActionPoints;
			}
		}
	}
	`log("stunned" @ Slot @ "count=" $ Stunned @ "stunAP=" $ StunAP @ "dazed=" $ Dazed,, 'CoopContent');
}

static function MoveUnitToward(string Spec, string TargetSpec)
{
	local XComGameState_Unit Unit, Target;
	local XGUnit Vis;
	local array<TTile> All, Path;
	local TTile Best, T;
	local int Score, BestScore, Gap;
	local bool bFound;

	Unit = FindUnit(Spec);
	Target = FindUnit(TargetSpec);
	Vis = (Unit != none) ? XGUnit(Unit.GetVisualizer()) : none;
	if (Vis == none || Target == none)
	{
		`log("moveto failed: unit=" $ Spec $ "/" $ (Unit != none) @ "target=" $ TargetSpec $ "/" $ (Target != none),, 'CoopContent');
		return;
	}
	Vis.m_kReachableTilesCache.UpdateTileCacheIfNeeded();
	Vis.m_kReachableTilesCache.GetAllPathableTiles(All);
	BestScore = 1000000;
	foreach All(T)
	{
		Gap = Max(Abs(T.X - Target.TileLocation.X), Abs(T.Y - Target.TileLocation.Y));
		Score = Gap * 10 + Abs(T.Z - Target.TileLocation.Z);
		if (Gap >= 2 && Score < BestScore)
		{
			Best = T;
			BestScore = Score;
			bFound = true;
		}
	}
	if (bFound)
	{
		Vis.m_kReachableTilesCache.BuildPathToTile(Best, Path);
	}
	SubmitMove(Unit, Vis, Path, All.Length);
}

static function SubmitMove(XComGameState_Unit Unit, XGUnit Vis, array<TTile> Path, int Pathable)
{
	local XComTacticalController TC;
	local bool bSubmitted;

	TC = XComTacticalController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController());
	if (Path.Length < 2 || TC == none)
	{
		`log("move failed: unit=" $ Unit.ObjectID @ "no path (" $ Pathable @ "pathable tiles)",, 'CoopContent');
		return;
	}
	bSubmitted = TC.GameStateMoveUnitSingle(Vis, Path, true);
	`log("move unit=" $ Unit.ObjectID @ "owner=" $ class'CoopOwnership'.static.OwnerOf(Unit)
		@ "from=" $ TileStr(Unit.TileLocation) @ "to=" $ TileStr(Path[Path.Length - 1]) @ "steps=" $ Path.Length
		@ "submitted=" $ class'CoopHarness'.static.BoolStr(bSubmitted),, 'CoopContent');
}

static function MoveUnit(string Spec, int Tiles)
{
	local XComGameState_Unit Unit;
	local XGUnit Vis;
	local array<TTile> All, Path;
	local TTile From, Best, T;
	local int Score, BestScore;
	local bool bFound;

	Unit = FindUnit(Spec);
	Vis = (Unit != none) ? XGUnit(Unit.GetVisualizer()) : none;
	if (Vis == none)
	{
		`log("move failed: unit=" $ Spec $ "/" $ (Unit != none) @ "visualizer=" $ (Vis != none),, 'CoopContent');
		return;
	}
	From = Unit.TileLocation;
	Vis.m_kReachableTilesCache.UpdateTileCacheIfNeeded();
	Vis.m_kReachableTilesCache.GetAllPathableTiles(All);
	BestScore = 1000000;
	foreach All(T)
	{
		Score = Abs(Max(Abs(T.X - From.X), Abs(T.Y - From.Y)) - Tiles) * 10 + Abs(T.Z - From.Z);
		if (Score < BestScore && !(T.X == From.X && T.Y == From.Y && T.Z == From.Z))
		{
			Best = T;
			BestScore = Score;
			bFound = true;
		}
	}
	if (bFound)
	{
		Vis.m_kReachableTilesCache.BuildPathToTile(Best, Path);
	}
	SubmitMove(Unit, Vis, Path, All.Length);
}

static function Shoot(string Spec)
{
	local XComGameStateHistory History;
	local XComGameState_Unit Unit, Target;
	local XComGameState_Ability Ability;
	local GameRulesCache_Unit Cache;
	local AvailableAction Action;
	local string Seen;
	local bool bSubmitted;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (!UnitMatches(Unit, Spec) || !`TACTICALRULES.GetGameRulesCache_Unit(Unit.GetReference(), Cache))
		{
			continue;
		}
		foreach Cache.AvailableActions(Action)
		{
			Ability = XComGameState_Ability(History.GetGameStateForObjectID(Action.AbilityObjectRef.ObjectID));
			if (Ability == none || Ability.GetMyTemplateName() != 'StandardShot')
			{
				continue;
			}
			Seen $= " " $ Unit.ObjectID $ ":" $ Action.AvailableCode $ "/" $ Action.AvailableTargets.Length;
			if (Action.AvailableCode != 'AA_Success' || Action.AvailableTargets.Length == 0)
			{
				continue;
			}
			Target = XComGameState_Unit(History.GetGameStateForObjectID(Action.AvailableTargets[0].PrimaryTarget.ObjectID));
			bSubmitted = class'XComGameStateContext_Ability'.static.ActivateAbility(Action, 0);
			`log("shoot unit=" $ Unit.ObjectID @ "owner=" $ class'CoopOwnership'.static.OwnerOf(Unit)
				@ "target=" $ Action.AvailableTargets[0].PrimaryTarget.ObjectID
				@ "(" $ ((Target != none) ? TeamStr(Target.GetTeam()) @ "hp=" $ Target.GetCurrentStat(eStat_HP) : "?") $ ")"
				@ "submitted=" $ class'CoopHarness'.static.BoolStr(bSubmitted),, 'CoopContent');
			return;
		}
	}
	`log("shoot failed: no unit matching" @ Spec @ "can take a standard shot (unit:code/targets" $ Seen $ ")",, 'CoopContent');
}

static function InteractWithObjective(name AbilityName, string Spec)
{
	local XComGameStateHistory History;
	local XComGameState_ObjectiveInfo Info;
	local XComGameState_InteractiveObject Target;
	local XComGameState_Unit Unit;
	local XComGameState_Ability Ability;
	local XComGameStateContext_Ability Context;
	local array<int> NoTargets;
	local array<vector> Locations;
	local bool bSubmitted;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_ObjectiveInfo', Info)
	{
		Target = XComGameState_InteractiveObject(Info.FindComponentObject(class'XComGameState_InteractiveObject', true));
		if (Target != none)
		{
			break;
		}
	}
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (UnitMatches(Unit, Spec) && Unit.FindAbility(AbilityName).ObjectID > 0)
		{
			Ability = XComGameState_Ability(History.GetGameStateForObjectID(Unit.FindAbility(AbilityName).ObjectID));
			break;
		}
	}
	if (Target == none || Ability == none)
	{
		`log("interact failed: objective object=" $ (Target != none) @ "unit with" @ AbilityName @ "matching" @ Spec $ "=" $ (Ability != none),, 'CoopContent');
		return;
	}
	Locations.AddItem(`XWORLD.GetPositionFromTileCoordinates(Target.TileLocation));
	Context = class'XComGameStateContext_Ability'.static.BuildContextFromAbility(Ability, Target.ObjectID, NoTargets, Locations);
	Context.bSkipValidation = true;
	Context.ResultContext.HitResult = eHit_Success;
	bSubmitted = `TACTICALRULES.SubmitGameStateContext(Context);
	`log("interact" @ AbilityName @ "unit=" $ Ability.OwnerStateObject.ObjectID @ "owner=" $ class'CoopOwnership'.static.OwnerOf(XComGameState_Unit(History.GetGameStateForObjectID(Ability.OwnerStateObject.ObjectID)))
		@ "object=" $ Target.ObjectID @ "submitted=" $ class'CoopHarness'.static.BoolStr(bSubmitted),, 'CoopContent');
}

static function GoToObjective(string Spec)
{
	local XComGameStateHistory History;
	local XComGameState_ObjectiveInfo Info;
	local XComGameState_InteractiveObject Obj, Goal;
	local XComGameState_Unit Unit, Mover;
	local XComGameState_Ability Ability;
	local GameRulesCache_Unit Cache;
	local AvailableAction Action;
	local XGUnit Vis;
	local array<int> ObjIDs;
	local array<TTile> All, Path, Sides;
	local TTile Best, T;
	local int i, Score, BestScore, Gap, MoverGap;
	local bool bFound, bSubmitted;
	local string Seen;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_ObjectiveInfo', Info)
	{
		Obj = XComGameState_InteractiveObject(Info.FindComponentObject(class'XComGameState_InteractiveObject', true));
		if (Obj != none)
		{
			// the component lookup can return an older state of the object; use the newest
			Obj = XComGameState_InteractiveObject(History.GetGameStateForObjectID(Obj.ObjectID));
		}
		if (Obj != none && !Obj.bHasBeenHacked && !(Obj.MaxInteractionCount >= 0 && Obj.InteractionCount >= Obj.MaxInteractionCount)
			&& ObjIDs.Find(Obj.ObjectID) == INDEX_NONE)
		{
			ObjIDs.AddItem(Obj.ObjectID);
			if (Goal == none)
			{
				Goal = Obj;
			}
		}
	}
	if (Goal == none)
	{
		`log("goobj: no unhacked or unused objective object",, 'CoopContent');
		return;
	}
	MoverGap = 1000000;
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (!UnitMatches(Unit, Spec) || !`TACTICALRULES.GetGameRulesCache_Unit(Unit.GetReference(), Cache))
		{
			continue;
		}
		foreach Cache.AvailableActions(Action)
		{
			for (i = 0; i < Action.AvailableTargets.Length; i++)
			{
				if (ObjIDs.Find(Action.AvailableTargets[i].PrimaryTarget.ObjectID) == INDEX_NONE)
				{
					continue;
				}
				Ability = XComGameState_Ability(History.GetGameStateForObjectID(Action.AbilityObjectRef.ObjectID));
				Seen $= " " $ Unit.ObjectID $ ":" $ ((Ability != none) ? string(Ability.GetMyTemplateName()) : "?") $ ":" $ Action.AvailableCode;
				// skip what the HUD never shows (FinalizeHack/CancelHack: the hacking screen fires those)
				if (Ability == none || Action.AvailableCode != 'AA_Success' || Ability.GetMyTemplate() == none
					|| Ability.GetMyTemplate().eAbilityIconBehaviorHUD == eAbilityIconBehavior_NeverShow)
				{
					continue;
				}
				bSubmitted = class'XComGameStateContext_Ability'.static.ActivateAbility(Action, i);
				`log("goobj use" @ Ability.GetMyTemplateName() @ "unit=" $ Unit.ObjectID @ "owner=" $ class'CoopOwnership'.static.OwnerOf(Unit)
					@ "object=" $ Action.AvailableTargets[i].PrimaryTarget.ObjectID @ "submitted=" $ class'CoopHarness'.static.BoolStr(bSubmitted),, 'CoopContent');
				return;
			}
		}
		Gap = Max(Abs(Unit.TileLocation.X - Goal.TileLocation.X), Abs(Unit.TileLocation.Y - Goal.TileLocation.Y));
		if (Unit.NumActionPoints() > 0 && Gap < MoverGap)
		{
			Mover = Unit;
			MoverGap = Gap;
		}
	}
	Vis = (Mover != none) ? XGUnit(Mover.GetVisualizer()) : none;
	if (Vis == none)
	{
		`log("goobj: no unit matching" @ Spec @ "with action points (object=" $ Goal.ObjectID @ "offered:" $ Seen $ ")",, 'CoopContent');
		return;
	}
	Vis.m_kReachableTilesCache.UpdateTileCacheIfNeeded();
	Vis.m_kReachableTilesCache.GetAllPathableTiles(All);
	BestScore = (MoverGap + Abs(Mover.TileLocation.Z - Goal.TileLocation.Z)) * 10;
	if (MoverGap <= 1)
	{
		// next to it but not offered the interaction: it works only from some sides; try another side
		foreach All(T)
		{
			if (Max(Abs(T.X - Goal.TileLocation.X), Abs(T.Y - Goal.TileLocation.Y)) == 1 && Abs(T.Z - Goal.TileLocation.Z) <= 1
				&& !(T.X == Mover.TileLocation.X && T.Y == Mover.TileLocation.Y && T.Z == Mover.TileLocation.Z))
			{
				Sides.AddItem(T);
			}
		}
		if (Sides.Length > 0)
		{
			Best = Sides[Rand(Sides.Length)];
			bFound = true;
		}
	}
	else
	{
		foreach All(T)
		{
			Gap = Max(Abs(T.X - Goal.TileLocation.X), Abs(T.Y - Goal.TileLocation.Y));
			Score = (Gap + Abs(T.Z - Goal.TileLocation.Z)) * 10 + Abs(T.Z - Goal.TileLocation.Z);
			if (Gap >= 1 && Score < BestScore)
			{
				Best = T;
				BestScore = Score;
				bFound = true;
			}
		}
	}
	`log("goobj walk unit=" $ Mover.ObjectID @ "object=" $ Goal.ObjectID @ "at=" $ TileStr(Goal.TileLocation) @ "gap=" $ MoverGap
		@ "best=" $ (bFound ? TileStr(Best) : "none") @ "offered:" $ Seen,, 'CoopContent');
	if (bFound)
	{
		Vis.m_kReachableTilesCache.BuildPathToTile(Best, Path);
		SubmitMove(Mover, Vis, Path, All.Length);
	}
}

static function DriveHackScreen()
{
	local UIScreen Screen;
	local UIHackingScreen Hack;

	foreach `SCREENSTACK.Screens(Screen)
	{
		Hack = UIHackingScreen(Screen);
		if (Hack != none)
		{
			break;
		}
	}
	if (Hack == none)
	{
		`log("hackscreen: not open",, 'CoopContent');
	}
	else if (!Hack.m_hackStarted)
	{
		`log("hackscreen: starting the hack, reward option=" $ Hack.SelectedHackRewardOption,, 'CoopContent');
		Hack.InitiateHack();
	}
	else
	{
		`log("hackscreen: hack done, closing (waiting for input=" $ class'CoopHarness'.static.BoolStr(Hack.bWaitingForInput) $ ")",, 'CoopContent');
		Hack.HackEnded();
	}
}

static function LogEvacState()
{
	local XComGameStateHistory History;
	local XComGameState_EvacZone Zone;
	local XComGameState_ObjectiveInfo Info;
	local XComGameState_InteractiveObject Obj;
	local int Zones;
	local string Hacked;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_EvacZone', Zone)
	{
		Zones++;
	}
	foreach History.IterateByClassType(class'XComGameState_ObjectiveInfo', Info)
	{
		Obj = XComGameState_InteractiveObject(Info.FindComponentObject(class'XComGameState_InteractiveObject', true));
		if (Obj != none)
		{
			Obj = XComGameState_InteractiveObject(History.GetGameStateForObjectID(Obj.ObjectID));
			Hacked @= Obj.ObjectID $ "=" $ class'CoopHarness'.static.BoolStr(Obj.bHasBeenHacked) $ "/used=" $ Obj.InteractionCount $ "/max=" $ Obj.MaxInteractionCount;
		}
	}
	Hacked $= " used objects:";
	foreach History.IterateByClassType(class'XComGameState_InteractiveObject', Obj)
	{
		if (Obj.InteractionCount > 0 || Obj.LastInteractedSocket != '')
		{
			Hacked @= Obj.ObjectID $ ":" $ Obj.InteractionCount $ ":" $ Obj.LastInteractedSocket;
		}
	}
	`log("evacstate zones=" $ Zones @ "objectiveObjects hacked:" $ Hacked,, 'CoopContent');
}

static function LogObjectives()
{
	local XComGameState_BattleData BattleData;
	local int i;

	BattleData = XComGameState_BattleData(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_BattleData', true));
	if (BattleData == none)
	{
		`log("objectives: no battle",, 'CoopContent');
		return;
	}
	for (i = 0; i < BattleData.MapData.ActiveMission.MissionObjectives.Length; i++)
	{
		`log("objectives mission=" $ BattleData.MapData.ActiveMission.sType @ "name=" $ BattleData.MapData.ActiveMission.MissionObjectives[i].ObjectiveName
			@ "strategy=" $ class'CoopHarness'.static.BoolStr(BattleData.MapData.ActiveMission.MissionObjectives[i].bIsStrategyObjective)
			@ "completed=" $ class'CoopHarness'.static.BoolStr(BattleData.MapData.ActiveMission.MissionObjectives[i].bCompleted),, 'CoopContent');
	}
}

static function LogUnitCount(name Template)
{
	local XComGameState_Unit Unit;
	local int XCom, Alien, Other;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (Unit.GetMyTemplateName() != Template || !Unit.IsAlive() || Unit.bRemovedFromPlay)
		{
			continue;
		}
		if (Unit.GetTeam() == eTeam_XCom)
		{
			XCom++;
		}
		else if (Unit.GetTeam() == eTeam_Alien)
		{
			Alien++;
		}
		else
		{
			Other++;
		}
	}
	`log("unitcount" @ Template @ "xcom=" $ XCom @ "alien=" $ Alien @ "other=" $ Other,, 'CoopContent');
}

static function LogUnitListeners(string Spec)
{
	local XComGameStateHistory History;
	local X2EventManager EventManager;
	local XComGameState_Unit Unit;
	local XComGameState_Ability AbilityState;
	local X2AbilityTemplate Template;
	local X2AbilityTrigger Trigger;
	local X2AbilityTrigger_EventListener TriggerListener;
	local StateObjectReference Ref;
	local Object TriggerObj;
	local int Total, Missing;

	History = `XCOMHISTORY;
	EventManager = `XEVENTMGR;
	Unit = FindUnit(Spec);
	if (Unit == none)
	{
		`log("listeners failed: no unit" @ Spec,, 'CoopContent');
		return;
	}
	foreach Unit.Abilities(Ref)
	{
		AbilityState = XComGameState_Ability(History.GetGameStateForObjectID(Ref.ObjectID));
		Template = (AbilityState != none) ? AbilityState.GetMyTemplate() : none;
		if (Template == none)
		{
			continue;
		}
		foreach Template.AbilityTriggers(Trigger)
		{
			TriggerListener = X2AbilityTrigger_EventListener(Trigger);
			if (TriggerListener == none)
			{
				continue;
			}
			TriggerObj = (TriggerListener.ListenerData.OverrideListenerSource != none) ? TriggerListener.ListenerData.OverrideListenerSource : AbilityState;
			Total++;
			if (!EventManager.IsRegistered(TriggerObj, TriggerListener.ListenerData.EventID, TriggerListener.ListenerData.Deferral, TriggerListener.ListenerData.EventFn))
			{
				Missing++;
				`log("listeners unit=" $ Unit.ObjectID @ "ability=" $ Template.DataName @ "event=" $ TriggerListener.ListenerData.EventID @ "registered=false",, 'CoopContent');
			}
			else if (Template.DataName == 'OverwatchShot')
			{
				`log("listeners unit=" $ Unit.ObjectID @ "ability=" $ Template.DataName @ "event=" $ TriggerListener.ListenerData.EventID @ "registered=true",, 'CoopContent');
			}
		}
	}
	`log("listeners unit=" $ Unit.ObjectID @ "template=" $ Unit.GetMyTemplateName() @ "triggers=" $ Total @ "missing=" $ Missing
		@ "reserveAP=" $ Unit.ReserveActionPoints.Length @ "tile=" $ TileStr(Unit.TileLocation),, 'CoopContent');
}

static function LogPingBinding()
{
	local PlayerInput PlayerIn;
	local KeyBind Bind;
	local string Found;
	local int i, PingAt, PlainAt;

	PlayerIn = class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController().PlayerInput;
	if (PlayerIn == none)
	{
		`log("pingbind: no player input",, 'CoopContent');
		return;
	}
	PingAt = -1;
	PlainAt = -1;
	for (i = 0; i < PlayerIn.Bindings.Length; i++)
	{
		Bind = PlayerIn.Bindings[i];
		if (Bind.Command ~= "CoopPing")
		{
			PingAt = i;
			Found $= " " $ Bind.Name $ (Bind.Alt ? "+Alt" : "") $ (Bind.Control ? "+Ctrl" : "") $ (Bind.Shift ? "+Shift" : "") $ "@" $ i;
		}
		else if (Bind.Name == 'LeftMouseButton' && !Bind.Alt)
		{
			PlainAt = i;
		}
	}
	// GetBind searches from the last binding, so the Alt binding must come after the plain left click
	`log("pingbind input=" $ PlayerIn.Class.Name @ "bindings=" $ PlayerIn.Bindings.Length @ "coopPing:" $ (Found == "" ? " none" : Found)
		@ "plainLeftClick@" $ PlainAt @ "altWins=" $ class'CoopHarness'.static.BoolStr(PingAt > PlainAt),, 'CoopContent');
}

// "@pawns": a unit whose model stands more than one tile from its game-state tile was moved in the game state but
// not shown moving on this machine
static function LogPawns()
{
	local XComGameState_Unit Unit;
	local XGUnit Vis;
	local TTile PawnTile;
	local int Checked, Off, Gap;
	local string Detail;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (Unit.GetTeam() != eTeam_XCom || !Unit.IsAlive() || Unit.bRemovedFromPlay)
		{
			continue;
		}
		Vis = XGUnit(Unit.GetVisualizer());
		if (Vis == none || Vis.GetPawn() == none)
		{
			continue;
		}
		Checked++;
		PawnTile = `XWORLD.GetTileCoordinatesFromPosition(Vis.GetPawn().Location);
		Gap = Max(Abs(PawnTile.X - Unit.TileLocation.X), Abs(PawnTile.Y - Unit.TileLocation.Y));
		if (Gap > 1)
		{
			Off++;
			Detail $= " " $ Unit.ObjectID $ ":owner" $ class'CoopOwnership'.static.OwnerOf(Unit) $ ":state=" $ TileStr(Unit.TileLocation) $ ":pawn=" $ TileStr(PawnTile);
		}
	}
	`log("pawns checked=" $ Checked @ "off=" $ Off $ Detail,, 'CoopContent');
	`log("pawns visualization: canEvaluate=" $ class'CoopHarness'.static.BoolStr(`XCOMVISUALIZATIONMGR.CanEvaluateNewGameStates())
		@ "inReplay=" $ class'CoopHarness'.static.BoolStr(`XCOMVISUALIZATIONMGR.InReplay())
		@ "latent=" $ class'CoopHarness'.static.BoolStr(`XCOMGAME.GameRuleset.BuildingLatentGameState)
		@ "visState=" $ `XCOMVISUALIZATIONMGR.GetStateName() @ "rules=" $ `XCOMGAME.GameRuleset.GetStateName()
		@ "input=" $ XComTacticalController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).GetStateName(),, 'CoopContent');
}

static function string TileStr(TTile T)
{
	return T.X $ "," $ T.Y $ "," $ T.Z;
}

// WHO: a player slot ("1"), "alien" (a unit on the alien team then) or "any"
static function bool SourceMatches(XComGameState_Unit Source, string Who)
{
	if (Source == none)
	{
		return false;
	}
	if (Who ~= "any")
	{
		return true;
	}
	if (Who ~= "alien")
	{
		return Source.GetTeam() == eTeam_Alien;
	}
	return class'CoopOwnership'.static.OwnerOf(Source) == int(Who);
}

static function LogUnitStatesAfter(string AbilityName, string Slot)
{
	local XComGameStateHistory History;
	local XComGameState Frame;
	local XComGameStateContext_Ability Context, Found;
	local XComGameState_Unit Unit, Source;
	local int i, FrameIndex;

	History = `XCOMHISTORY;
	FrameIndex = -1;
	for (i = History.GetCurrentHistoryIndex(); i >= 0 && FrameIndex < 0; i--)
	{
		Frame = History.GetGameStateFromHistory(i, eReturnType_Reference);
		Context = (Frame != none) ? XComGameStateContext_Ability(Frame.GetContext()) : none;
		if (Context == none || (AbilityName != "*" && !(string(Context.InputContext.AbilityTemplateName) ~= AbilityName)))
		{
			continue;
		}
		Source = XComGameState_Unit(History.GetGameStateForObjectID(Context.InputContext.SourceObject.ObjectID, eReturnType_Reference, i));
		if (SourceMatches(Source, Slot))
		{
			FrameIndex = i;
			Found = Context;
		}
	}
	if (FrameIndex < 0)
	{
		`log("ustate" @ AbilityName @ Slot @ "none: no such frame",, 'CoopContent');
		return;
	}
	`log("ustate-frame" @ AbilityName @ Slot @ "index=" $ FrameIndex,, 'CoopContent');
	`log("ustate" @ AbilityName @ Slot @ "context ability=" $ Found.InputContext.AbilityTemplateName @ "source=" $ Found.InputContext.SourceObject.ObjectID
		@ "target=" $ Found.InputContext.PrimaryTarget.ObjectID
		@ "result=" $ GetEnum(Enum'EAbilityHitResult', Found.ResultContext.HitResult),, 'CoopContent');
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit, eReturnType_Reference, , FrameIndex)
	{
		if (Unit.GetMyTemplate() == none || Unit.GetMyTemplate().bIsCosmetic || (Unit.GetTeam() != eTeam_XCom && Unit.GetTeam() != eTeam_Alien))
		{
			continue;
		}
		`log("ustate" @ AbilityName @ Slot @ "unit=" $ Unit.ObjectID @ "team=" $ TeamStr(Unit.GetTeam())
			@ "tile=" $ TileStr(Unit.TileLocation) @ "hp=" $ int(Unit.GetCurrentStat(eStat_HP)) $ "/" $ int(Unit.GetMaxStat(eStat_HP))
			@ "alive=" $ class'CoopHarness'.static.BoolStr(Unit.IsAlive()) @ "ap=" $ Unit.ActionPoints.Length
			@ "removed=" $ class'CoopHarness'.static.BoolStr(Unit.bRemovedFromPlay),, 'CoopContent');
	}
}

static function WinMission()
{
	local XComGameState_BattleData BattleData;
	local XComGameState NewGameState;
	local XGBattle_SP Battle;
	local int i, Total, Strategy;

	BattleData = XComGameState_BattleData(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_BattleData', true));
	Battle = XGBattle_SP(`BATTLE);
	if (BattleData == none || Battle == none || `TACTICALRULES == none || !class'CoopRole'.static.IsHost())
	{
		`log("winmission failed: battle=" $ (BattleData != none) @ "host=" $ class'CoopRole'.static.IsHost(),, 'CoopContent');
		return;
	}
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop test: complete mission objectives");
	BattleData = XComGameState_BattleData(NewGameState.ModifyStateObject(class'XComGameState_BattleData', BattleData.ObjectID));
	for (i = 0; i < BattleData.MapData.ActiveMission.MissionObjectives.Length; i++)
	{
		Total++;
		if (BattleData.MapData.ActiveMission.MissionObjectives[i].bIsStrategyObjective)
		{
			Strategy++;
		}
		BattleData.CompleteObjective(BattleData.MapData.ActiveMission.MissionObjectives[i].ObjectiveName);
	}
	`TACTICALRULES.SubmitGameState(NewGameState);
	`log("winmission mission=" $ BattleData.MapData.ActiveMission.sType @ "objectives=" $ Total @ "strategy=" $ Strategy
		@ "allDone=" $ class'CoopHarness'.static.BoolStr(BattleData.AllStrategyObjectivesCompleted()),, 'CoopContent');
	`TACTICALRULES.EndBattle(Battle.GetHumanPlayer());
}

// Strategy or tactical: the soldiers each Chosen holds, with their owner tag.
static function LogCaptured()
{
	local XComGameState_AdventChosen Chosen;
	local XComGameState_Unit Unit;
	local StateObjectReference Ref;
	local int Count;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_AdventChosen', Chosen)
	{
		foreach Chosen.CapturedSoldiers(Ref)
		{
			Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Ref.ObjectID));
			`log("captured unit=" $ Ref.ObjectID @ "by=" $ Chosen.GetMyTemplateName()
				@ "owner=" $ ((Unit != none) ? string(class'CoopOwnership'.static.OwnerOf(Unit)) : "?"),, 'CoopContent');
			Count++;
		}
	}
	`log("captured total=" $ Count,, 'CoopContent');
}

// Ends the mind control effects on units matching Spec, as a cleanse would.
static function RemoveMindControl(string Spec)
{
	local XComGameStateHistory History;
	local XComGameState_Effect Effect;
	local array<XComGameState_Effect> Found;
	local XComGameStateContext_EffectRemoved Context;
	local XComGameState NewGameState;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_Effect', Effect)
	{
		if (!Effect.bRemoved && X2Effect_MindControl(Effect.GetX2Effect()) != none
			&& UnitMatches(XComGameState_Unit(History.GetGameStateForObjectID(Effect.ApplyEffectParameters.TargetStateObjectRef.ObjectID)), Spec))
		{
			Found.AddItem(Effect);
		}
	}
	foreach Found(Effect)
	{
		Context = class'XComGameStateContext_EffectRemoved'.static.CreateEffectRemovedContext(Effect);
		NewGameState = History.CreateNewGameState(true, Context);
		Effect.RemoveEffect(NewGameState, NewGameState, true);
		`TACTICALRULES.SubmitGameState(NewGameState);
		`log("removemc effect=" $ Effect.ObjectID @ "target=" $ Effect.ApplyEffectParameters.TargetStateObjectRef.ObjectID,, 'CoopContent');
	}
	`log("removemc done count=" $ Found.Length,, 'CoopContent');
}

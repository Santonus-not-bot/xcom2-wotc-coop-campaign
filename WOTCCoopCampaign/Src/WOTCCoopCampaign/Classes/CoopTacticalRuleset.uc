//---------------------------------------------------------------------------------------
//  FILE:    CoopTacticalRuleset.uc
//  PURPOSE: DRAFT, NOT REGISTERED, NEVER RUN. Mission handoff between machines at initiative
//           group boundaries, ported from the PvP ruleset (X2TacticalMPGameRuleset:
//           TurnPhase_MPUnitActions, TurnPhase_PlayerSync, PerformingReplay, CoopReplayMgr):
//           one machine runs the rules at a time, the others watch a replay of its frames.
//
//           Active machine, in TurnPhase_UnitActions: when initiative passes to a group run by
//           another machine (CoopTactical.IsInitiativeRemote: a guest's XCom group, or anything
//           of the host's), go to TurnPhase_CoopHandoff: record that phase in the history, send a
//           partial history, wait for "CoopHistoryAck", send "CoopSwitchTurn", start watching
//           (CoopReplayMgr.ResumeReplay -> PerformingReplay).
//           Watching machine: "CoopSwitchTurn" -> RequestPauseReplay -> StopReplay -> EndReplay ->
//           TurnPhase_UnitActions, begins the initiative the switch names (the sender skipped its
//           BeginInitiativeTurn); a guest that joined runs the base load path once first, which
//           clears bLoadingSavedGame (privatewrite).
//
//           To try it: register it with
//             +ModClassOverrides=(BaseGameClass="X2TacticalGameRuleset", ModClass="WOTCCoopCampaign.CoopTacticalRuleset")
//           and set CoopTactical.bHandoff=true. Without bHandoff (or without a connection) it
//           behaves like the base ruleset.
//           Mission entry: the host sends the mission history at its first unit actions; the
//           guest loads the map with its replay manager in replay (CoopTacticalNet), so
//           LoadTacticalGame goes to PerformingReplay and it watches from the start.
//           Interrupt at the handoff moment: the resume picks the interrupted group's index as the base
//           load path does, and notifies the player when the interrupted group resumes. Other gaps:
//           remote commands may overtake history (the switch is sent only after the ack).
//           3-4 players: the switch names the target slot and the host counts one ack per guest, but
//           guests connect only to the host, so a guest's frames and commands do not reach the other
//           guests (the host would have to relay them): not handled yet.
//---------------------------------------------------------------------------------------
class CoopTacticalRuleset extends X2TacticalGameRuleset;

var float WaitPlayersUntil;      // scenario mode, host: the first turn's wait for the players ends here (TurnPhase_CoopWaitPlayers)
var int AcksNeeded;        // partial history sent: acknowledgements still missing (host: one per connected guest)
var bool bResumeAfterHandoff;
var bool bMissionSent;     // host: the mission history went to the guests on this map
var bool bHandingOver;     // inside CoopReplayMgr.ResumeReplay: it starts playback itself
// The machine that runs an initiative begins it (BeginInitiativeTurn submits its turn-begin frames and
// starts the AI or the player's group). The machine handing over skips it and names it in "CoopSwitchTurn".
var int HandoverIndex;                 // sender: initiative index of the skipped begin
var int HandoverFlags;                 // sender: 1 = bBeginInterruptedInitiative, 2 = bResumeFromInterruptedInitiative
var int ResumeInitiativeID, ResumeIndex, ResumeFlags;   // receiver: what the switch named
var int WatchingSlot;                  // the player whose turn this machine is watching (-1 = none)
var int HandedInitiativeID;            // the initiative this machine handed over last
var int StallSeconds;                  // taking over: seconds the replay has waited on a busy visualizer

// This machine plays an XCom initiative right now (its player's turn): for CoopPresence.
function bool LocalPlaysXComTurn()
{
	local XComGameState_BaseObject Entry;
	local XComGameState_AIGroup Group;
	local XComGameState_Player Player;

	if (!IsInState('TurnPhase_UnitActions') || CachedUnitActionInitiativeRef.ObjectID <= 0)
	{
		return false;
	}
	Entry = CachedHistory.GetGameStateForObjectID(CachedUnitActionInitiativeRef.ObjectID);
	Group = XComGameState_AIGroup(Entry);
	Player = XComGameState_Player(Entry);
	if (!((Group != none && Group.TeamName == eTeam_XCom) || (Player != none && Player.TeamFlag == eTeam_XCom)))
	{
		return false;
	}
	return class'CoopTactical'.static.ControllerOfInitiative(Entry) == class'CoopRole'.static.LocalSlot();
}

static function bool HandoffActive()
{
	return class'CoopTactical'.default.bHandoff && class'CoopRole'.static.CoopActive() && `XCOMNETMANAGER.HasConnections();
}

function CoopReplayMgr CoopReplay()
{
	local XComTacticalGRI GRI;

	GRI = XComTacticalGRI(WorldInfo.GRI);
	if (CoopReplayMgr(GRI.ReplayMgr) == none)
	{
		GRI.ReplayMgr = Spawn(class'CoopReplayMgr', GRI);
		`log("replay manager replaced by CoopReplayMgr",, 'CoopHandoff');
	}
	return CoopReplayMgr(GRI.ReplayMgr);
}

simulated event PostBeginPlay()
{
	super.PostBeginPlay();
	if (HandoffActive() || class'CoopTactical'.default.bEnterMissionWatching)
	{
		class'CoopTacticalNet'.static.Init();
		CoopReplay();
	}
	if (class'CoopTactical'.default.bEnterMissionWatching)
	{
		// LoadTacticalGame goes to PerformingReplay while the replay manager is in replay
		CoopReplay().SetInReplay(true);
		`log("entering the mission as a watcher",, 'CoopHandoff');
	}
}

// With a co-op connection open the engine counts as multiplayer, and the base skips every ability not
// flagged for multiplayer: units created during a co-op mission (reinforcements, units from the Avenger,
// possessed units) would miss abilities. A co-op campaign mission is single-player content, so the
// multiplayer filter is not applied. (Units of the start state are set up while the host has no connection,
// CoopLink.) Same as the base otherwise.
static simulated function InitializeUnitAbilities(XComGameState NewGameState, XComGameState_Unit NewUnit)
{
	local XComGameState_Player kPlayer;
	local int i;
	local array<AbilitySetupData> AbilityData;
	local X2AbilityTemplate AbilityTemplate;

	if (!class'CoopRole'.static.CoopActive())
	{
		super.InitializeUnitAbilities(NewGameState, NewUnit);
		return;
	}
	kPlayer = XComGameState_Player(`XCOMHISTORY.GetGameStateForObjectID(NewUnit.ControllingPlayer.ObjectID));
	AbilityData = NewUnit.GatherUnitAbilitiesForInit(NewGameState, kPlayer);
	for (i = 0; i < AbilityData.Length; ++i)
	{
		AbilityTemplate = AbilityData[i].Template;
		if (!AbilityTemplate.IsTemplateAvailableToAnyArea(AbilityTemplate.BITFIELD_GAMEAREA_Tactical))
		{
			`log("InitializeUnitAbilities: ability" @ AbilityTemplate.DataName @ "is not available in tactical",, 'CoopTactical');
		}
		else
		{
			InitAbilityForUnit(AbilityTemplate, NewUnit, NewGameState, AbilityData[i].SourceWeaponRef, AbilityData[i].SourceAmmoRef);
		}
	}
}

// Debug: the current state and where its state code waits (BeginBlockWaitingLocation is protected).
function string WhereWaiting()
{
	return GetStateName() $ ":" @ BeginBlockWaitingLocation;
}

function OnHistoryAck()
{
	AcksNeeded = Max(0, AcksNeeded - 1);
}

// Host: a guest's connection closed (CoopRole). If it was that guest's turn, nobody would ever send the turn
// back: the host takes the guest's group over (the "disconnect: host takes over" rule). The guest's actions of
// this turn never arrived (frames travel at the end of a turn), so the group starts its turn again here.
function OnGuestDisconnected(int Slot)
{
	if (IsInState('TurnPhase_CoopHandoff'))
	{
		AcksNeeded = Max(0, AcksNeeded - 1);    // its acknowledgement will not come; the target is re-checked
		`log("player" @ Slot @ "left while a turn was being handed over",, 'CoopHandoff');
		return;
	}
	if (IsInState('PerformingReplay') && WatchingSlot == Slot && class'CoopRole'.static.IsHost())
	{
		`log("player" @ Slot @ "left during its turn: the host takes over initiative" @ HandedInitiativeID,, 'CoopHandoff');
		WatchingSlot = -1;
		ResumeInitiativeID = HandedInitiativeID;
		ResumeIndex = HandoverIndex;
		ResumeFlags = HandoverFlags;
		CoopReplay().RequestPauseReplay();    // -> EndReplay -> TurnPhase_UnitActions (resume)
		WatchTakeover();
	}
}

// "CoopSwitchTurn"(slot, initiative, index, flags): only the machine playing that slot takes over and
// begins that initiative; the others keep watching.
function OnSwitchTurn(int TargetSlot, int InitiativeID, int Index, int Flags)
{
	if (TargetSlot != class'CoopRole'.static.LocalSlot())
	{
		`log("switch turn for player" @ TargetSlot @ "(not us): still watching",, 'CoopHandoff');
		return;
	}
	ResumeInitiativeID = InitiativeID;
	ResumeIndex = Index;
	ResumeFlags = Flags;
	WatchingSlot = -1;
	`log("switch turn received: taking over initiative" @ InitiativeID @ "index" @ Index @ "flags" @ Flags,, 'CoopHandoff');
	CoopReplay().RequestPauseReplay();
	WatchTakeover();
}

// The replay stops for a takeover only once the visualizer is idle (XComMPReplayMgr.PlayingReplay.Tick).
// An X2Action that never finishes keeps it busy for good: an AI reveal timed out on a watching guest after
// its soldiers had been mind-controlled into the alien group and freed, and the guest never got its turn
// (run mcall-20261113-201051; the game's redscreen: "detected a time out, which will likely result in a
// hang"). Once the game itself marks an action as timed out, finish it as its debug command does
// (XComGameStateVisualizationMgr.DebugClearHangs), so the turn can start.
function WatchTakeover()
{
	StallSeconds = 0;
	SetTimer(1.0f, true, nameof(CheckTakeoverStall));
}

function CheckTakeoverStall()
{
	local X2Action Action;
	local int TimedOut;

	if (!IsInState('PerformingReplay'))
	{
		ClearTimer(nameof(CheckTakeoverStall));
		return;
	}
	if (!class'XComGameStateVisualizationMgr'.static.VisualizerBusy())
	{
		StallSeconds = 0;
		return;
	}
	StallSeconds++;
	foreach AllActors(class'X2Action', Action)
	{
		if (Action.IsTimedOut() && Action.IsInState('Executing'))
		{
			TimedOut++;
			`log("takeover waits on a timed-out visualization action:" @ Action.Class.Name @ "after" @ StallSeconds @ "s",, 'CoopHandoff');
		}
	}
	if (TimedOut > 0)
	{
		`XCOMVISUALIZATIONMGR.DebugClearHangs();
		`log("takeover: finished" @ TimedOut @ "timed-out visualization action(s) so the turn can start",, 'CoopHandoff');
	}
}

simulated function name GetNextTurnPhase(name CurrentState, optional name DefaultPhaseName='TurnPhase_End')
{
	if (CurrentState == 'TurnPhase_CoopHandoff')
	{
		return 'TurnPhase_UnitActions';
	}
	return super.GetNextTurnPhase(CurrentState, DefaultPhaseName);
}

simulated state TurnPhase_UnitActions
{
	simulated event BeginState(name PreviousStateName)
	{
		if (!bResumeAfterHandoff)
		{
			// host: the first unit actions of the mission bring the guests in. The mission was built
			// without a connection (CoopLink.HostCloseForMission); reopen it before the base advances
			// initiative, so a guest's group is handed over once its player is back.
			if (!bMissionSent && class'CoopTactical'.default.bHandoff && class'CoopRole'.static.CoopActive() && class'CoopRole'.static.IsHost())
			{
				bMissionSent = true;
				class'CoopLink'.static.HostMissionReady();
				// a save made inside the mission was loaded (not a guest: guests watch, they never get here first)
				if (bLoadingSavedGame)
				{
					class'CoopLink'.static.HostLoadedGame("a mission");
				}
				// scenario mode: the players join after the host started; the first turn waits for them, else they
				// lose it (their groups are played by the host until they are in)
				else if (class'CoopScenario'.static.IsScenario() && class'CoopLink'.default.MissionSlots.Length > 0
					&& !class'CoopScenario'.static.PlayersReady())
				{
					GotoState('TurnPhase_CoopWaitPlayers');
					return;
				}
			}
			super.BeginState(PreviousStateName);
			return;
		}
		bResumeAfterHandoff = false;
		// A guest that joined the mission came in through LoadTacticalGame, which sets the base's
		// bLoadingSavedGame (privatewrite); while it is set, BeginInitiativeTurn, EndInitiativeTurn and
		// NextInitiativeGroup submit no turn frames. The base load path clears it: run it once.
		// (Test 2026-11-12: without this the guest's turn end never reached BattleData and the host resumed
		// at the guest's group instead of the aliens.)
		if (bLoadingSavedGame)
		{
			super.BeginState(PreviousStateName);
			`log("first turn after joining: base load path ran, bLoadingSavedGame=" $ bLoadingSavedGame,, 'CoopHandoff');
		}
		// begin the initiative the other machine handed over (it skipped BeginInitiativeTurn for it)
		UnitActionInitiativeIndex = ResumeIndex;
		RefreshInitiativeReferences();
		if (CachedUnitActionInitiativeRef.ObjectID != ResumeInitiativeID)
		{
			`log("WARNING resume: index" @ ResumeIndex @ "gives initiative" @ CachedUnitActionInitiativeRef.ObjectID @ "but the switch named" @ ResumeInitiativeID,, 'CoopHandoff');
		}
		class'CoopListenerRepair'.static.RepairAll("taking over");
		BeginInitiativeTurn((ResumeFlags & 1) != 0, (ResumeFlags & 2) != 0);
		bSkipRemainingTurnActivty = false;
		`log("resumed unit actions at initiative" @ CachedUnitActionInitiativeRef.ObjectID @ "index" @ UnitActionInitiativeIndex,, 'CoopHandoff');
	}

	// An initiative another machine runs is begun there, not here (see HandoverIndex).
	simulated function bool BeginInitiativeTurn(bool bBeginInterruptedInitiative, bool bResumeFromInterruptedInitiative)
	{
		local bool bBegun;

		if (!bLoadingSavedGame && CachedUnitActionInitiativeRef.ObjectID >= 0 && HandoffActive()
			&& class'CoopTactical'.static.IsInitiativeRemote(CachedHistory.GetGameStateForObjectID(CachedUnitActionInitiativeRef.ObjectID)))
		{
			HandoverIndex = UnitActionInitiativeIndex;
			HandoverFlags = (bBeginInterruptedInitiative ? 1 : 0) + (bResumeFromInterruptedInitiative ? 2 : 0);
			return true;    // NextInitiativeGroup below hands over
		}
		bBegun = super.BeginInitiativeTurn(bBeginInterruptedInitiative, bResumeFromInterruptedInitiative);
		// whose turn it is, for every player (not while a loaded game replays its first begin)
		if (!bLoadingSavedGame && CachedUnitActionInitiativeRef.ObjectID > 0)
		{
			class'CoopTurnBanner'.static.OnLocalInitiativeBegun(CachedHistory.GetGameStateForObjectID(CachedUnitActionInitiativeRef.ObjectID));
		}
		return bBegun;
	}

	// After the base advances initiative: if the new entry runs on another machine, hand over.
	simulated function bool NextInitiativeGroup()
	{
		local bool bMore;

		bMore = super.NextInitiativeGroup();
		if (bMore && HandoffActive() && class'CoopTactical'.static.IsInitiativeRemote(CachedHistory.GetGameStateForObjectID(CachedUnitActionInitiativeRef.ObjectID)))
		{
			`log("initiative" @ CachedUnitActionInitiativeRef.ObjectID @ "runs on another machine: handing over",, 'CoopHandoff');
			GotoState('TurnPhase_CoopHandoff');
		}
		return bMore;
	}
}

// Host: the mission is over; close the connection so the summary, after action and return run as
// single player (CoopLink.HostCloseForReturn).
simulated state EndTacticalGame
{
	simulated event BeginState(name PreviousStateName)
	{
		class'CoopScenario'.static.HostScenarioOver();    // scenario mode: the guests go to the main menu
		class'CoopLink'.static.HostCloseForReturn();
		super.BeginState(PreviousStateName);
	}
}

// Scenario mode, host: before the first turn, until every expected player has loaded the mission (or the time is up).
simulated state TurnPhase_CoopWaitPlayers
{
Begin:
	WaitPlayersUntil = WorldInfo.RealTimeSeconds + class'CoopScenario'.default.WaitForPlayersSeconds;
	`log("scenario: first turn waits for the players (up to" @ int(class'CoopScenario'.default.WaitForPlayersSeconds) @ "s)",, 'CoopScenario');
	class'CoopRoster'.static.Toast(class'CoopScenario'.static.WaitText());
	while (!class'CoopScenario'.static.PlayersReady() && WorldInfo.RealTimeSeconds < WaitPlayersUntil)
	{
		sleep(0.5);
	}
	`log("scenario: first turn starts: players ready=" $ class'CoopHarness'.static.BoolStr(class'CoopScenario'.static.PlayersReady())
		@ "connected=" $ class'CoopLink'.static.SlotList(class'CoopRole'.default.ConnectedSlots),, 'CoopScenario');
	GotoState('TurnPhase_UnitActions');
}

simulated state TurnPhase_CoopHandoff
{
	simulated event BeginState(name PreviousStateName)
	{
		BeginState_RulesAuthority(none);    // the receiver continues after this phase (GetNextTurnPhase)
	}

Begin:
	while (WaitingForVisualizer())
	{
		sleep(0.0);
	}
	XComTacticalController(GetALocalPlayerController()).SetInputState('Multiplayer_Inactive');
	AcksNeeded = class'CoopRole'.static.IsHost() ? Max(1, class'CoopRole'.default.ConnectedSlots.Length) : 1;
	`XCOMNETMANAGER.SendPartialHistory(`XCOMHISTORY, `XEVENTMGR);
	`log("handoff: partial history sent, waiting for ack",, 'CoopHandoff');
	while (AcksNeeded > 0)
	{
		sleep(0.0);
	}
	HandedInitiativeID = CachedUnitActionInitiativeRef.ObjectID;
	class'CoopTurnBanner'.static.OnHandedOver();
	WatchingSlot =class'CoopTactical'.static.ControllerOfInitiative(CachedHistory.GetGameStateForObjectID(HandedInitiativeID));
	if (WatchingSlot == class'CoopRole'.static.LocalSlot())
	{
		// the player we were handing to left meanwhile: its group is ours now
		`log("handoff: target left, keeping initiative" @ HandedInitiativeID,, 'CoopHandoff');
		WatchingSlot = -1;
		ResumeInitiativeID = HandedInitiativeID;
		ResumeIndex = HandoverIndex;
		ResumeFlags = HandoverFlags;
		bResumeAfterHandoff = true;
		GotoState('TurnPhase_UnitActions');
	}
	else
	{
		class'CoopTacticalNet'.static.SendSwitchTurn(WatchingSlot, HandedInitiativeID, HandoverIndex, HandoverFlags);
		`log("handoff: switch sent, watching player" @ WatchingSlot,, 'CoopHandoff');
		bHandingOver = true;            // ResumeReplay enters PerformingReplay before it starts playback itself
		CoopReplay().ResumeReplay();    // -> ResumeReplay() -> PerformingReplay, then playback
		bHandingOver = false;
	}
}

simulated state PerformingReplay
{
	simulated event BeginState(name PreviousStateName)
	{
		local CoopReplayMgr Replay;

		super.BeginState(PreviousStateName);
		class'CoopTactical'.default.bEnterMissionWatching = false;
		if (!HandoffActive())
		{
			return;
		}
		// watch the frames the active machine sends (ResumeReplay already started playback after a handoff)
		Replay = CoopReplay();
		if (!bHandingOver && !Replay.IsInState('PlayingReplay'))
		{
			Replay.StartReplay(CachedHistory.GetNumGameStates() - 1);
			Replay.GotoState('PlayingReplay');
			`log("watching from frame" @ (CachedHistory.GetNumGameStates() - 1),, 'CoopHandoff');
			class'CoopMissionLoading'.static.End("watching the mission");
		}
	}

	function EndReplay()
	{
		if (HandoffActive())
		{
			// A guest loads the mission already "in replay", so LoadTacticalGame never enables the visualization
			// manager, and XComMPReplayMgr.StopReplay (unlike XComReplayMgr's) does not enable it either: the guest
			// built no visuals for its own actions, its soldiers' models stayed put while their states moved
			// (@pawns, run guestvis 2026-11-18). Enable it for the turn this machine now plays; while watching,
			// the manager's own InReplay() check keeps it idle.
			VisualizationMgr.SetCurrentHistoryFrame(CachedHistory.GetNumGameStates() - 1);
			VisualizationMgr.EnableBuildVisualization();
			`log("taking over: visualization of new states enabled at frame" @ (CachedHistory.GetNumGameStates() - 1),, 'CoopHandoff');
			bResumeAfterHandoff = true;
			GotoState('TurnPhase_UnitActions');
			return;
		}
		super.EndReplay();
	}
}

defaultproperties
{
	WatchingSlot=-1
}

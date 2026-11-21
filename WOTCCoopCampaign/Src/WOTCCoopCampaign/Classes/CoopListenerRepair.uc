//---------------------------------------------------------------------------------------
//  FILE:    CoopListenerRepair.uc
//  PURPOSE: Event listeners that state objects register during a mission are missing after a handoff.
//           Found with the Avatar's mind control (avatarmc, 2026-11-14): the effect registers its
//           countdown on 'PlayerTurnBegun' when it is applied on the host. After the host received the
//           guest's partial history at the next handoff, the listener was gone (IsRegistered false), and
//           the countdown never ran again. The guest never had it. Listeners registered at mission start
//           (the XCom player's own turn counter) kept working.
//           What the native partial-history receive does to the event manager is not known; this
//           restores, after each received history, what the game itself registers:
//           - every active effect's tick and removal listeners, see below;
//           - ability listeners and event triggers are only counted (missing ones logged), not re-registered:
//             some abilities unregister their own listener after it fires, and a missing ability listener
//             has not been seen yet. The game's challenge-mode cheat (XComCheatManager) shows how to repair them.
//           Each machine repairs only effects that tick where it runs the turn: the host those that tick on a
//           player's turn (player turns begin and end on the host), every machine those that tick on the turn of
//           a group it runs (stun and daze on a guest's own soldiers run on that guest; stunguest, 2026-11-15:
//           a guest's stunned soldier stayed stunned for good). See RepairAll and RepairEffects.
//           Effects: tick and removal listeners as XComGameState_Effect.PostCreateInit
//             registers them, plus the effect template's own RegisterForEvents. An effect counts as lost
//             only when its first core listener is missing, so nothing is registered twice.
//---------------------------------------------------------------------------------------
class CoopListenerRepair extends Object;

static function RepairAll(string Why)
{
	local int Abilities, Effects;

	// On a guest, only effects ticking on its own groups' turns. Repairing every effect there (all 17 of an
	// avatarmc run, most of them ticking on the host) was followed by a native crash as the guest's first
	// turn began (XCom2.exe+0xb158a7, 1 run of 3).
	if (!class'CoopSession'.static.InTactical())
	{
		return;
	}
	Abilities = RepairAbilityListeners();
	Effects = RepairEffects();
	CheckEffectRefs(Why);
	CheckVisibilityCache(Why);
	`log("listener repair after" @ Why $ ": effects repaired=" $ Effects @ "ability listeners repaired=" $ Abilities,, 'CoopHandoff');
}

// Ability listeners and triggers (X2TacticalGameRuleset.InitAbilityForUnit registers them) that are missing on THIS
// machine are registered again, the way the game's own fixup cheat does (XComCheatManager, FixupRegisterListener;
// loading a save registers them all the same way). Every machine. A unit created mid-mission on another machine
// (a reinforcement, a dropped unit) reached this one as data only: on a guest its OverwatchShot trigger
// (ObjectMoved) was not registered, so its overwatch never fired at the guest's soldiers (overwatchguest,
// 2026-11-15; the host had it). Abilities that unregister their own listener after firing get it back, as on a load.
static function int RepairAbilityListeners()
{
	local XComGameStateHistory History;
	local X2EventManager EventManager;
	local XComGameState_Unit Unit;
	local XComGameState_Player PlayerState;
	local XComGameState_Ability AbilityState;
	local X2AbilityTemplate Template;
	local AbilityEventListener Listener;
	local X2AbilityTrigger Trigger;
	local X2AbilityTrigger_EventListener TriggerListener;
	local StateObjectReference Ref;
	local Object SourceObj;
	local int Repaired;

	History = `XCOMHISTORY;
	EventManager = `XEVENTMGR;
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (Unit.bRemovedFromPlay || !Unit.IsAlive())
		{
			continue;
		}
		PlayerState = XComGameState_Player(History.GetGameStateForObjectID(Unit.ControllingPlayer.ObjectID));
		foreach Unit.Abilities(Ref)
		{
			AbilityState = XComGameState_Ability(History.GetGameStateForObjectID(Ref.ObjectID));
			Template = (AbilityState != none) ? AbilityState.GetMyTemplate() : none;
			if (Template == none)
			{
				continue;
			}
			SourceObj = AbilityState;
			foreach Template.AbilityEventListeners(Listener)
			{
				if (!EventManager.IsRegistered(SourceObj, Listener.EventID, Listener.Deferral, Listener.EventFn))
				{
					EventManager.RegisterForEvent(SourceObj, Listener.EventID, Listener.EventFn, Listener.Deferral, , FilterFor(Listener.Filter, Unit, PlayerState));
					Repaired++;
				}
			}
			foreach Template.AbilityTriggers(Trigger)
			{
				TriggerListener = X2AbilityTrigger_EventListener(Trigger);
				if (TriggerListener != none && TriggerListener.FixupRegisterListener(AbilityState, FilterFor(TriggerListener.ListenerData.Filter, Unit, PlayerState)))
				{
					Repaired++;
				}
			}
		}
	}
	return Repaired;
}

// Diagnostic for the rare guest crash as its turn begins (XCom2.exe+0xb158a7, 2026-11-14 and 2026-11-15): both stacks
// pass through the game's stat code for effects ("No StatChange found on effect state object %d"), and it read a
// null pointer. Guess: a unit refers to an effect state this machine does not have. Logs every unit reference
// (AffectedByEffects, AppliedEffects) to an effect state that is missing from the history; changes nothing.
static function CheckEffectRefs(string Why)
{
	local XComGameStateHistory History;
	local XComGameState_Unit Unit;
	local StateObjectReference Ref;
	local int Missing, Checked;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		foreach Unit.AffectedByEffects(Ref)
		{
			Checked++;
			if (XComGameState_Effect(History.GetGameStateForObjectID(Ref.ObjectID)) == none)
			{
				Missing++;
				`log("effect check: unit" @ Unit.ObjectID @ "(" $ Unit.GetMyTemplateName() $ ") is affected by effect" @ Ref.ObjectID @ "which this machine does not have",, 'CoopHandoff');
			}
		}
		foreach Unit.AppliedEffects(Ref)
		{
			Checked++;
			if (XComGameState_Effect(History.GetGameStateForObjectID(Ref.ObjectID)) == none)
			{
				Missing++;
				`log("effect check: unit" @ Unit.ObjectID @ "(" $ Unit.GetMyTemplateName() $ ") applied effect" @ Ref.ObjectID @ "which this machine does not have",, 'CoopHandoff');
			}
		}
	}
	if (Missing > 0)
	{
		`log("effect check after" @ Why $ ":" @ Missing @ "missing of" @ Checked @ "effect references",, 'CoopHandoff');
	}
}

// Diagnostic for the same crash, after disassembly (2026-11-18): the fault is in the visibility manager's update of
// one viewer/target pair (+0xb15870, fires ObjectVisibilityChanged), called with a null object: the caller read the
// object's cached XComGameState_BaseObject.VisibilityInterface and found it empty. Logs every object whose cache
// does not match its class (has the X2GameRulesetVisibilityInterface but an empty cache, or the reverse), and
// every object a unit sees or is seen by whose cache is empty; changes nothing.
static function CheckVisibilityCache(string Why)
{
	local XComGameStateHistory History;
	local XComGameState_BaseObject Obj, Other;
	local XComGameState_Unit Unit;
	local X2GameRulesetVisibilityManager VisMgr;
	local array<StateObjectReference> Refs;
	local StateObjectReference Ref;
	local array<int> Logged;
	local bool bHasIface, bCached;
	local int Bad, Checked;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_BaseObject', Obj)
	{
		bHasIface = X2GameRulesetVisibilityInterface(Obj) != none;
		bCached = Obj.VisibilityInterface != none;
		if (!bHasIface && !bCached)
		{
			continue;
		}
		Checked++;
		if (bHasIface != bCached)
		{
			Bad++;
			Logged.AddItem(Obj.ObjectID);
			`log("visibility check: object" @ Obj.ObjectID @ "(" $ Obj.Class.Name $ ") iface=" $ bHasIface @ "cached=" $ bCached
				@ "removed=" $ Obj.bRemoved @ "inPlay=" $ Obj.bInPlay,, 'CoopHandoff');
		}
	}
	VisMgr = `TACTICALRULES != none ? `TACTICALRULES.VisibilityMgr : none;
	if (VisMgr != none)
	{
		foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
		{
			Refs.Length = 0;
			VisMgr.GetAllVisibleToSource(Unit.ObjectID, Refs);
			VisMgr.GetAllViewersOfTarget(Unit.ObjectID, Refs);
			foreach Refs(Ref)
			{
				Other = History.GetGameStateForObjectID(Ref.ObjectID);
				if (Logged.Find(Ref.ObjectID) != INDEX_NONE)
				{
					continue;
				}
				if (Other == none || Other.VisibilityInterface == none)
				{
					Bad++;
					Logged.AddItem(Ref.ObjectID);
					`log("visibility check: unit" @ Unit.ObjectID @ "has a visibility record with object" @ Ref.ObjectID
						@ ((Other == none) ? "which this machine does not have" : "(" $ Other.Class.Name $ ") whose cache is empty"),, 'CoopHandoff');
				}
			}
		}
	}
	if (Bad > 0)
	{
		`log("visibility check after" @ Why $ ":" @ Bad @ "problems among" @ Checked @ "visible objects",, 'CoopHandoff');
	}
}

// as X2TacticalGameRuleset.GetEventFilterObject (private there)
static function Object FilterFor(AbilityEventFilter EventFilter, XComGameState_Unit FilterUnit, XComGameState_Player FilterPlayer)
{
	switch (EventFilter)
	{
	case eFilter_Unit:
		return FilterUnit;
	case eFilter_Player:
		return FilterPlayer;
	}
	return none;
}

// Ability listeners and triggers that X2TacticalGameRuleset.InitAbilityForUnit registered and that are not
// registered now. Counted only.
static function int CountMissingAbilityListeners()
{
	local XComGameStateHistory History;
	local X2EventManager EventManager;
	local XComGameState_Unit Unit;
	local XComGameState_Ability AbilityState;
	local X2AbilityTemplate Template;
	local AbilityEventListener Listener;
	local X2AbilityTrigger Trigger;
	local X2AbilityTrigger_EventListener TriggerListener;
	local StateObjectReference Ref;
	local Object SourceObj, TriggerObj;
	local int Missing;

	History = `XCOMHISTORY;
	EventManager = `XEVENTMGR;
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (Unit.bRemovedFromPlay)
		{
			continue;
		}
		foreach Unit.Abilities(Ref)
		{
			AbilityState = XComGameState_Ability(History.GetGameStateForObjectID(Ref.ObjectID));
			Template = (AbilityState != none) ? AbilityState.GetMyTemplate() : none;
			if (Template == none)
			{
				continue;
			}
			SourceObj = AbilityState;
			foreach Template.AbilityEventListeners(Listener)
			{
				if (!EventManager.IsRegistered(SourceObj, Listener.EventID, Listener.Deferral, Listener.EventFn))
				{
					Missing++;
				}
			}
			foreach Template.AbilityTriggers(Trigger)
			{
				TriggerListener = X2AbilityTrigger_EventListener(Trigger);
				if (TriggerListener == none)
				{
					continue;
				}
				TriggerObj = (TriggerListener.ListenerData.OverrideListenerSource != none) ? TriggerListener.ListenerData.OverrideListenerSource : AbilityState;
				if (!EventManager.IsRegistered(TriggerObj, TriggerListener.ListenerData.EventID, TriggerListener.ListenerData.Deferral, TriggerListener.ListenerData.EventFn))
				{
					Missing++;
				}
			}
		}
	}
	return Missing;
}

// Active effects: the listeners of XComGameState_Effect.PostCreateInit.
static function int RepairEffects()
{
	local XComGameStateHistory History;
	local XComGameState_Effect Effect;
	local X2Effect_Persistent Template;
	local bool bPlayerRule, bGroupRule;
	local int Repaired;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_Effect', Effect)
	{
		if (Effect.bRemoved)
		{
			continue;
		}
		Template = Effect.GetX2Effect();
		if (TargetOf(Effect) != none && TargetOf(Effect).bRemovedFromPlay)
		{
			continue;
		}
		if (Template == none || (TargetOf(Effect) != none && Template.IsTickEveryAction(TargetOf(Effect))))
		{
			continue;
		}
		// only effects that tick where this machine runs the turn: player turns on the host, a group's turn
		// on the machine that runs that group
		bPlayerRule = Template.WatchRule == eGameRule_PlayerTurnBegin || Template.WatchRule == eGameRule_PlayerTurnEnd;
		bGroupRule = Template.WatchRule == eGameRule_UnitGroupTurnBegin || Template.WatchRule == eGameRule_UnitGroupTurnEnd;
		if (!(bPlayerRule && class'CoopRole'.static.IsHost()) && !(bGroupRule && GroupRunsHere(TargetOf(Effect))))
		{
			continue;
		}
		if (Template == none || !CoreListenerMissing(Effect, Template))
		{
			continue;
		}
		RegisterCore(Effect, Template);
		Template.RegisterForEvents(Effect);
		Repaired++;
		`log("listener repair: effect" @ Effect.ObjectID @ Template.EffectName @ "turnsLeft=" $ Effect.iTurnsRemaining,, 'CoopHandoff');
	}
	return Repaired;
}

// The target's group takes its turn on this machine.
static function bool GroupRunsHere(XComGameState_Unit Target)
{
	local XComGameState_AIGroup Group;

	Group = (Target != none) ? Target.GetGroupMembership() : none;
	return Group != none && class'CoopTactical'.static.ControllerOfInitiative(Group) == class'CoopRole'.static.LocalSlot();
}

static function XComGameState_Unit TargetOf(XComGameState_Effect Effect)
{
	return XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Effect.ApplyEffectParameters.TargetStateObjectRef.ObjectID));
}

// The first listener PostCreateInit registers for this effect; true when the effect has one and it is missing.
static function bool CoreListenerMissing(XComGameState_Effect Effect, X2Effect_Persistent Template)
{
	local X2EventManager EventManager;
	local XComGameState_Unit Target;
	local Object ThisObj;

	EventManager = `XEVENTMGR;
	ThisObj = Effect;
	Target = TargetOf(Effect);
	if (Target != none && Template.IsTickEveryAction(Target))
	{
		return !EventManager.IsRegistered(ThisObj, 'AbilityActivated', ELD_OnStateSubmitted, Effect.OnAbilityActivated);
	}
	switch (Template.WatchRule)
	{
	case eGameRule_PlayerTurnBegin:
		return !EventManager.IsRegistered(ThisObj, 'PlayerTurnBegun', ELD_OnStateSubmitted, Effect.OnPlayerTurnTicked);
	case eGameRule_PlayerTurnEnd:
		return !EventManager.IsRegistered(ThisObj, 'PlayerTurnEnded', ELD_OnStateSubmitted, Effect.OnPlayerTurnTicked);
	case eGameRule_UnitGroupTurnBegin:
		return !EventManager.IsRegistered(ThisObj, 'UnitGroupTurnBegun', ELD_OnStateSubmitted, Effect.OnGroupTurnTicked);
	case eGameRule_UnitGroupTurnEnd:
		return !EventManager.IsRegistered(ThisObj, 'UnitGroupTurnEnded', ELD_OnStateSubmitted, Effect.OnGroupTurnTicked);
	}
	if (Template.bRemoveWhenSourceDies || Template.bRemoveWhenTargetDies)
	{
		return !EventManager.IsRegistered(ThisObj, 'UnitDied', ELD_OnStateSubmitted, Effect.OnUnitDiedOrBleedingOut);
	}
	if (!Template.bPersistThroughTacticalGameEnd)
	{
		return !EventManager.IsRegistered(ThisObj, 'UnitRemovedFromPlay', ELD_OnStateSubmitted, Effect.OnUnitRemovedFromPlay);
	}
	return false;     // nothing to probe: leave it alone
}

// The registrations of XComGameState_Effect.PostCreateInit, same order and filters.
static function RegisterCore(XComGameState_Effect Effect, X2Effect_Persistent Template)
{
	local XComGameStateHistory History;
	local X2EventManager EventMgr;
	local XComGameState_Player PlayerState;
	local XComGameState_Unit TargetUnitState, SourceUnitState;
	local XComGameState_AIGroup GroupState;
	local Object ThisObj;

	History = `XCOMHISTORY;
	EventMgr = `XEVENTMGR;
	ThisObj = Effect;

	PlayerState = XComGameState_Player(History.GetGameStateForObjectID(Effect.ApplyEffectParameters.PlayerStateObjectRef.ObjectID));
	if (PlayerState != none && PlayerState.GetTeam() == eTeam_Neutral)
	{
		// as the game does: a civilian's effect ticks on the alien turn
		foreach History.IterateByClassType(class'XComGameState_Player', PlayerState)
		{
			if (PlayerState.GetTeam() == eTeam_Alien)
			{
				break;
			}
		}
	}
	TargetUnitState = TargetOf(Effect);
	if (TargetUnitState != none)
	{
		GroupState = TargetUnitState.GetGroupMembership();
	}
	if (TargetUnitState != none && Template.IsTickEveryAction(TargetUnitState))
	{
		EventMgr.RegisterForEvent(ThisObj, 'AbilityActivated', Effect.OnAbilityActivated, ELD_OnStateSubmitted, 0, TargetUnitState);
	}
	else if (Template.WatchRule == eGameRule_PlayerTurnBegin)
	{
		EventMgr.RegisterForEvent(ThisObj, 'PlayerTurnBegun', Effect.OnPlayerTurnTicked, ELD_OnStateSubmitted, , Template.bIgnorePlayerCheckOnTick ? none : PlayerState);
	}
	else if (Template.WatchRule == eGameRule_PlayerTurnEnd)
	{
		EventMgr.RegisterForEvent(ThisObj, 'PlayerTurnEnded', Effect.OnPlayerTurnTicked, ELD_OnStateSubmitted, , Template.bIgnorePlayerCheckOnTick ? none : PlayerState);
	}
	else if (Template.WatchRule == eGameRule_UnitGroupTurnBegin)
	{
		EventMgr.RegisterForEvent(ThisObj, 'UnitGroupTurnBegun', Effect.OnGroupTurnTicked, ELD_OnStateSubmitted, , GroupState);
	}
	else if (Template.WatchRule == eGameRule_UnitGroupTurnEnd)
	{
		EventMgr.RegisterForEvent(ThisObj, 'UnitGroupTurnEnded', Effect.OnGroupTurnTicked, ELD_OnStateSubmitted, , GroupState);
	}

	if (Template.bRemoveWhenSourceDies && Template.bRemoveWhenTargetDies)
	{
		EventMgr.RegisterForEvent(ThisObj, 'UnitDied', Effect.OnUnitDiedOrBleedingOut, ELD_OnStateSubmitted);
		EventMgr.RegisterForEvent(ThisObj, 'UnitBleedingOut', Effect.OnUnitDiedOrBleedingOut, ELD_OnStateSubmitted);
	}
	else if (Template.bRemoveWhenSourceDies || Template.bRemoveWhenTargetDies)
	{
		SourceUnitState = XComGameState_Unit(History.GetGameStateForObjectID(Template.bRemoveWhenSourceDies
			? Effect.ApplyEffectParameters.SourceStateObjectRef.ObjectID : Effect.ApplyEffectParameters.TargetStateObjectRef.ObjectID));
		EventMgr.RegisterForEvent(ThisObj, 'UnitDied', Effect.OnUnitDiedOrBleedingOut, ELD_OnStateSubmitted, , SourceUnitState);
		EventMgr.RegisterForEvent(ThisObj, 'UnitBleedingOut', Effect.OnUnitDiedOrBleedingOut, ELD_OnStateSubmitted, , SourceUnitState);
	}
	if (Template.bRemoveWhenSourceDamaged)
	{
		SourceUnitState = XComGameState_Unit(History.GetGameStateForObjectID(Effect.ApplyEffectParameters.SourceStateObjectRef.ObjectID));
		EventMgr.RegisterForEvent(ThisObj, 'UnitTakeEffectDamage', Effect.OnSourceUnitTookEffectDamage, ELD_OnStateSubmitted, , SourceUnitState);
	}
	if (Template.bRemoveWhenTargetConcealmentBroken)
	{
		EventMgr.RegisterForEvent(ThisObj, 'UnitConcealmentBroken', Effect.OnTargetConcealmentBroken, ELD_OnStateSubmitted, , TargetUnitState);
	}
	if (Template.bRemoveWhenSourceDies)
	{
		EventMgr.RegisterForEvent(ThisObj, 'UnitRemovedFromPlay', Effect.OnUnitRemovedFromPlay, ELD_OnStateSubmitted);
	}
	else if (!Template.bPersistThroughTacticalGameEnd)
	{
		EventMgr.RegisterForEvent(ThisObj, 'UnitRemovedFromPlay', Effect.OnUnitRemovedFromPlay, ELD_OnStateSubmitted, , TargetUnitState);
	}
}

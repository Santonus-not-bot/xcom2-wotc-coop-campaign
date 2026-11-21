//---------------------------------------------------------------------------------------
//  FILE:    CoopTactical.uc
//  PURPOSE: Per-player turns in missions with WOTC's own initiative code: all XCom units
//           start in one XComGameState_AIGroup. Each guest's soldiers move into a group of
//           their own with InitiativePriority = host group + guest slot, so the game runs
//           host -> guest 1 -> guest 2 -> guest 3 -> aliens (only the group with initiative
//           may act). Unowned soldiers stay with the host.
//           Not proven yet: see the design doc, experiment 2. Off by default
//           (XComCoopCampaign.ini, bSplitXComGroupAtStart).
//---------------------------------------------------------------------------------------
class CoopTactical extends Object config(CoopCampaign);

var config bool bSplitXComGroupAtStart;
var config bool bHandoff;
var config bool bEnterMissionWatching;   // guest: the next mission map loads in replay (set by CoopTacticalNet, cleared on entry)      // CoopTacticalRuleset hands missions between machines (draft, needs the ruleset registered)

// The player slot whose machine runs an initiative entry: an XCom group belongs to the owner of
// its members (the host while that guest is away); players, alien and other groups to the host.
static function int ControllerOfInitiative(XComGameState_BaseObject Entry)
{
	local XComGameState_AIGroup Group;
	local XComGameState_Unit Unit;
	local StateObjectReference Ref;

	Group = XComGameState_AIGroup(Entry);
	if (Group == none || Group.TeamName != eTeam_XCom)
	{
		return class'XComGameState_CoopCampaign'.const.SLOT_HOST;
	}
	foreach Group.m_arrMembers(Ref)
	{
		Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Ref.ObjectID));
		if (Unit != none && class'CoopOwnership'.static.OwnerOf(Unit) > class'XComGameState_CoopCampaign'.const.SLOT_HOST)
		{
			return class'CoopRole'.static.ControllerOf(class'CoopOwnership'.static.OwnerOf(Unit));
		}
	}
	return class'XComGameState_CoopCampaign'.const.SLOT_HOST;
}

// Co-op version of X2TacticalMPGameRuleset.GameStatePlayerOrGroupIsRemote: PvP compares the
// group's team player with the local network id, which makes every XCom group "local" in co-op.
static function bool IsInitiativeRemote(XComGameState_BaseObject Entry)
{
	return ControllerOfInitiative(Entry) != class'CoopRole'.static.LocalSlot();
}

// Splits inside NewGameState (pending, not submitted). Returns the number of units moved.
static function int SplitXComGroup(XComGameState NewGameState)
{
	local XComGameStateHistory History;
	local XComGameState_AIGroup HostGroup, GuestGroup;
	local array<XComGameState_AIGroup> GuestGroups;     // index = player slot
	local XComGameState_Unit Unit;
	local array<int> MovedUnits, MovedSlots;
	local int i, Slot;

	History = `XCOMHISTORY;
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (NewGameState.GetGameStateForObjectID(Unit.ObjectID) != none)
		{
			Unit = XComGameState_Unit(NewGameState.GetGameStateForObjectID(Unit.ObjectID));
		}
		Slot = class'CoopOwnership'.static.OwnerOf(Unit);
		if (Unit.GetTeam() != eTeam_XCom || Slot <= class'XComGameState_CoopCampaign'.const.SLOT_HOST
			|| Slot >= class'XComGameState_CoopCampaign'.const.MAX_PLAYERS || Unit.GetGroupMembership(NewGameState) == none)
		{
			continue;
		}
		if (HostGroup == none)
		{
			HostGroup = Unit.GetGroupMembership(NewGameState);
		}
		if (Unit.GetGroupMembership(NewGameState).ObjectID == HostGroup.ObjectID)
		{
			MovedUnits.AddItem(Unit.ObjectID);
			MovedSlots.AddItem(Slot);
		}
	}
	if (MovedUnits.Length == 0)
	{
		return 0;
	}
	HostGroup = XComGameState_AIGroup(NewGameState.ModifyStateObject(class'XComGameState_AIGroup', HostGroup.ObjectID));
	GuestGroups.Length = class'XComGameState_CoopCampaign'.const.MAX_PLAYERS;
	for (i = 0; i < MovedUnits.Length; i++)
	{
		Slot = MovedSlots[i];
		if (GuestGroups[Slot] == none)
		{
			GuestGroup = XComGameState_AIGroup(NewGameState.CreateNewStateObject(class'XComGameState_AIGroup'));
			GuestGroup.bProcessedScamper = true;     // as StartStateInitializeSquads does for the XCom group
			GuestGroup.TeamName = eTeam_XCom;
			GuestGroup.InitiativePriority = HostGroup.InitiativePriority + Slot;
			GuestGroups[Slot] = GuestGroup;
			`log("group for player" @ Slot @ "id=" $ GuestGroup.ObjectID @ "prio=" $ GuestGroup.InitiativePriority,, 'CoopTactical');
		}
		HostGroup.RemoveUnitFromGroup(MovedUnits[i], NewGameState);
		GuestGroups[Slot].AddUnitToGroup(MovedUnits[i], NewGameState);
	}
	`TACTICALRULES.BuildInitiativeOrder(NewGameState);
	`log("split moved=" $ MovedUnits.Length @ "hostGroup=" $ HostGroup.ObjectID,, 'CoopTactical');
	return MovedUnits.Length;
}

// Mid-mission (each XCom player turn begin, host): a soldier a guest owns that entered play after the
// split, such as an Avenger defense reinforcement (SeqAct_SpawnUnitFromAvenger picks any free soldier in
// the barracks) or a rescued soldier, sits in the group the game gave it, usually the host's. There it
// would also hand the whole host group to that guest (ControllerOfInitiative takes the first guest-owned
// member). Moves each such soldier into its owner's group: the XCom group with priority = lowest XCom
// group priority + slot, as SplitXComGroup makes it, or a new one. Mind-controlled soldiers are on the
// alien team and skipped; the game puts them back itself (m_arrDisplaced). Returns the number moved.
static function int RegroupOwnedUnits(XComGameState NewGameState)
{
	local XComGameStateHistory History;
	local XComGameState_AIGroup Group, Current;
	local array<XComGameState_AIGroup> SlotGroups;   // index = player slot
	local XComGameState_Unit Unit;
	local int Slot, Moved, BasePrio, Created;

	History = `XCOMHISTORY;
	BasePrio = MaxInt;
	foreach History.IterateByClassType(class'XComGameState_AIGroup', Group)
	{
		if (Group.TeamName == eTeam_XCom && Group.InitiativePriority < BasePrio)
		{
			BasePrio = Group.InitiativePriority;
		}
	}
	if (BasePrio == MaxInt)
	{
		return 0;
	}
	SlotGroups.Length = class'XComGameState_CoopCampaign'.const.MAX_PLAYERS;
	foreach History.IterateByClassType(class'XComGameState_AIGroup', Group)
	{
		Slot = Group.InitiativePriority - BasePrio;
		if (Group.TeamName == eTeam_XCom && Slot > class'XComGameState_CoopCampaign'.const.SLOT_HOST
			&& Slot < class'XComGameState_CoopCampaign'.const.MAX_PLAYERS && SlotGroups[Slot] == none)
		{
			SlotGroups[Slot] = Group;
		}
	}
	foreach History.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		Slot = class'CoopOwnership'.static.OwnerOf(Unit);
		Current = Unit.GetGroupMembership(NewGameState);
		if (Unit.GetTeam() != eTeam_XCom || Slot <= class'XComGameState_CoopCampaign'.const.SLOT_HOST
			|| Slot >= class'XComGameState_CoopCampaign'.const.MAX_PLAYERS || Current == none
			|| !Unit.IsAlive() || Unit.bRemovedFromPlay)
		{
			continue;
		}
		if (SlotGroups[Slot] != none && Current.ObjectID == SlotGroups[Slot].ObjectID)
		{
			continue;
		}
		if (SlotGroups[Slot] == none)
		{
			SlotGroups[Slot] = XComGameState_AIGroup(NewGameState.CreateNewStateObject(class'XComGameState_AIGroup'));
			SlotGroups[Slot].bProcessedScamper = true;
			SlotGroups[Slot].TeamName = eTeam_XCom;
			SlotGroups[Slot].InitiativePriority = BasePrio + Slot;
			Created++;
		}
		else
		{
			SlotGroups[Slot] = XComGameState_AIGroup(NewGameState.ModifyStateObject(class'XComGameState_AIGroup', SlotGroups[Slot].ObjectID));
		}
		Current = XComGameState_AIGroup(NewGameState.ModifyStateObject(class'XComGameState_AIGroup', Current.ObjectID));
		Current.RemoveUnitFromGroup(Unit.ObjectID, NewGameState);
		SlotGroups[Slot].AddUnitToGroup(Unit.ObjectID, NewGameState);
		Moved++;
		`log("regroup unit=" $ Unit.ObjectID @ "owner=" $ Slot @ "from=" $ Current.ObjectID @ "to=" $ SlotGroups[Slot].ObjectID,, 'CoopTactical');
	}
	Created += MergeHostSideGroups(NewGameState, BasePrio, Moved);
	if (Created > 0)
	{
		`TACTICALRULES.BuildInitiativeOrder(NewGameState);
	}
	return Moved;
}

// A unit with no owner (or the host's) that joins XCOM mid-mission can come in its own XCom group with the host's
// priority (seen with the DropUnit cheat, joinxcom 2026-11-17): the host then had a second turn step for it, and in
// its first step the unit had no action points. As in single player all of the host's units act in one turn: move
// them into the host's main group (the host-priority XCom group with the most members). Returns the groups emptied.
static function int MergeHostSideGroups(XComGameState NewGameState, int BasePrio, out int Moved)
{
	local XComGameState_AIGroup Group, Main, Other;
	local XComGameState_Unit Unit;
	local array<XComGameState_AIGroup> Others;
	local StateObjectReference Ref;
	local array<StateObjectReference> Members;
	local int Emptied, Slot;
	local bool bAllHostSide;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_AIGroup', Group)
	{
		if (NewGameState.GetGameStateForObjectID(Group.ObjectID) != none)
		{
			Group = XComGameState_AIGroup(NewGameState.GetGameStateForObjectID(Group.ObjectID));
		}
		if (Group.TeamName != eTeam_XCom || Group.InitiativePriority != BasePrio)
		{
			continue;
		}
		if (Main == none || Group.m_arrMembers.Length > Main.m_arrMembers.Length)
		{
			if (Main != none)
			{
				Others.AddItem(Main);
			}
			Main = Group;
		}
		else
		{
			Others.AddItem(Group);
		}
	}
	foreach Others(Other)
	{
		if (Other.m_arrMembers.Length == 0)
		{
			continue;
		}
		bAllHostSide = true;
		foreach Other.m_arrMembers(Ref)
		{
			Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Ref.ObjectID));
			Slot = (Unit != none) ? class'CoopOwnership'.static.OwnerOf(Unit) : class'CoopOwnership'.const.NO_OWNER;
			if (Slot != class'CoopOwnership'.const.NO_OWNER && Slot != class'XComGameState_CoopCampaign'.const.SLOT_HOST)
			{
				bAllHostSide = false;
			}
		}
		if (!bAllHostSide)
		{
			continue;
		}
		Main = XComGameState_AIGroup(NewGameState.ModifyStateObject(class'XComGameState_AIGroup', Main.ObjectID));
		Other = XComGameState_AIGroup(NewGameState.ModifyStateObject(class'XComGameState_AIGroup', Other.ObjectID));
		Members = Other.m_arrMembers;
		foreach Members(Ref)
		{
			Other.RemoveUnitFromGroup(Ref.ObjectID, NewGameState);
			Main.AddUnitToGroup(Ref.ObjectID, NewGameState);
			Moved++;
			`log("regroup unit=" $ Ref.ObjectID @ "into the host's group: from=" $ Other.ObjectID @ "to=" $ Main.ObjectID,, 'CoopTactical');
		}
		Emptied++;
	}
	return Emptied;
}

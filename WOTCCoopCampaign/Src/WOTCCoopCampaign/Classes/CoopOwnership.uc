//---------------------------------------------------------------------------------------
//  FILE:    CoopOwnership.uc
//  PURPOSE: Which player slot owns a soldier. Stored on the unit as the unit value
//           'CoopOwnerSlot' (cleanup never), so it travels into and out of missions with the
//           unit and is saved with it. No value = nobody owns the soldier yet.
//           Writes must happen on the baton holder (strategy) or the host (tactical).
//---------------------------------------------------------------------------------------
class CoopOwnership extends Object;

const OWNER_VALUE = 'CoopOwnerSlot';
const NO_OWNER = -1;

static function int OwnerOf(XComGameState_Unit Unit)
{
	local UnitValue Value;

	if (Unit != none && Unit.GetUnitValue(OWNER_VALUE, Value))
	{
		return int(Value.fValue);
	}
	return NO_OWNER;
}

// Unit must already be in NewGameState (ModifyStateObject); Slot NO_OWNER clears the tag.
static function SetOwner(XComGameState_Unit Unit, int Slot)
{
	if (Slot == NO_OWNER)
	{
		Unit.ClearUnitValue(OWNER_VALUE);
	}
	else
	{
		Unit.SetUnitFloatValue(OWNER_VALUE, float(Slot), eCleanup_Never);
	}
}

// May the player in Slot put this soldier into one of their squad slots?
static function bool CanUse(XComGameState_Unit Unit, int Slot)
{
	local int Owner;

	Owner = OwnerOf(Unit);
	return Owner == NO_OWNER || Owner == Slot;
}

// Ownership policy when a soldier goes on a mission from a squad slot: unowned soldiers
// become the slot owner's; owned soldiers keep their owner. Returns the owner after the call.
static function int ClaimForSquadSlot(XComGameState NewGameState, XComGameState_Unit Unit, int SlotOwner)
{
	if (OwnerOf(Unit) == NO_OWNER)
	{
		Unit = XComGameState_Unit(NewGameState.ModifyStateObject(class'XComGameState_Unit', Unit.ObjectID));
		SetOwner(Unit, SlotOwner);
	}
	return OwnerOf(Unit);
}

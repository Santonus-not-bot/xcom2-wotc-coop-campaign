//---------------------------------------------------------------------------------------
//  FILE:    CoopSquadRules.uc
//  PURPOSE: Squad slot ownership, enforced on every submitted strategy frame (so it holds
//           for the vanilla squad screen, robojumper's Squad Select and anything else that
//           writes XComHQ.Squad):
//           - the host may fill any slot; a guest only the slots the host gave them;
//           - into a slot only soldiers of that slot's player, or unowned ones;
//           - an unowned soldier placed into a slot becomes the slot owner's (same frame).
//           Illegal placements are undone in the pending frame instead of rejecting it: the
//           game itself rewrites the squad (auto-fill on entering squad select, removing dead
//           or wounded soldiers), and those frames must still go through. Removals (slot -> empty)
//           are always allowed for that reason.
//           Inactive until the campaign has an XComGameState_CoopCampaign.
//---------------------------------------------------------------------------------------
class CoopSquadRules extends Object;

// Fixes NewStates in place. Returns the number of slot changes that were undone.
static function int CheckAndClaim(array<XComGameState> NewStates)
{
	local XComGameState NewState;
	local XComGameState_HeadquartersXCom NewHQ, OldHQ;
	local XComGameState_CoopCampaign Coop;
	local XComGameState_Unit Unit;
	local StateObjectReference OldRef;
	local int i, MySlot, SlotOwner, OldID, NewID, Undone;

	Coop = class'XComGameState_CoopCampaign'.static.Get();
	if (Coop == none)
	{
		return 0;
	}
	MySlot = class'CoopRole'.static.LocalSlot();
	foreach NewStates(NewState)
	{
		foreach NewState.IterateByClassType(class'XComGameState_HeadquartersXCom', NewHQ)
		{
			OldHQ = XComGameState_HeadquartersXCom(NewHQ.GetPreviousVersion());
			for (i = 0; i < NewHQ.Squad.Length; i++)
			{
				NewID = NewHQ.Squad[i].ObjectID;
				OldID = (OldHQ != none && i < OldHQ.Squad.Length) ? OldHQ.Squad[i].ObjectID : 0;
				if (NewID == OldID || NewID == 0)
				{
					continue;
				}
				SlotOwner = Coop.OwnerOfSquadSlot(i);
				Unit = XComGameState_Unit(NewState.GetGameStateForObjectID(NewID));
				if (Unit == none)
				{
					Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(NewID));
				}
				if ((MySlot != class'XComGameState_CoopCampaign'.const.SLOT_HOST && SlotOwner != MySlot) || !class'CoopOwnership'.static.CanUse(Unit, SlotOwner))
				{
					OldRef.ObjectID = OldID;
					NewHQ.Squad[i] = OldRef;
					Undone++;
					`log("undone: slot" @ i @ "(owner" @ SlotOwner $ ", local" @ MySlot $ ") unit" @ NewID @ "(owner" @ class'CoopOwnership'.static.OwnerOf(Unit) $ ") back to" @ OldID
						@ ":" @ NewState.GetContext().SummaryString(),, 'CoopSquad');
					continue;
				}
				class'CoopOwnership'.static.ClaimForSquadSlot(NewState, Unit, SlotOwner);
				`log("slot" @ i @ "unit" @ NewID @ "owner" @ SlotOwner,, 'CoopSquad');
			}
		}
	}
	return Undone;
}

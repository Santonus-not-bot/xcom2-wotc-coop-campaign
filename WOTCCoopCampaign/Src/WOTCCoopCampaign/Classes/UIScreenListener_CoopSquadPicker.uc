//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopSquadPicker.uc
//  PURPOSE: The soldier picker of squad select (vanilla and robojumper's Squad Select both
//           open UIPersonnel_SquadSelect after setting UISquadSelect.m_iSelectedSlot).
//           Closes it when a guest opens another player's slot; greys out soldiers that
//           belong to someone other than the slot's player. The host may open every slot.
//           CoopSquadRules enforces the same rules on the submitted frame.
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopSquadPicker extends UIScreenListener;

event OnInit(UIScreen Screen)
{
	Apply(UIPersonnel_SquadSelect(Screen));
}

event OnReceiveFocus(UIScreen Screen)
{
	Apply(UIPersonnel_SquadSelect(Screen));
}

static function Apply(UIPersonnel_SquadSelect Picker)
{
	local XComGameState_CoopCampaign Coop;
	local UISquadSelect SquadScreen;
	local UIPersonnel_ListItem Item;
	local XComGameState_Unit Unit;
	local int i, MySlot, SlotOwner, Greyed;

	Coop = class'XComGameState_CoopCampaign'.static.Get();
	if (Picker == none || Coop == none)
	{
		return;
	}
	SquadScreen = UISquadSelect(Picker.Movie.Pres.ScreenStack.GetFirstInstanceOf(class'UISquadSelect'));
	if (SquadScreen == none)
	{
		return;
	}
	MySlot = class'CoopRole'.static.LocalSlot();
	SlotOwner = Coop.OwnerOfSquadSlot(SquadScreen.m_iSelectedSlot);
	if (MySlot != class'XComGameState_CoopCampaign'.const.SLOT_HOST && SlotOwner != MySlot)
	{
		`log("picker closed: slot" @ SquadScreen.m_iSelectedSlot @ "belongs to player" @ SlotOwner,, 'CoopSquad');
		Picker.CloseScreen();
		return;
	}
	for (i = 0; i < Picker.m_kList.itemCount; i++)
	{
		Item = UIPersonnel_ListItem(Picker.m_kList.GetItem(i));
		Unit = (Item != none) ? XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Item.UnitRef.ObjectID)) : none;
		if (Unit != none && !class'CoopOwnership'.static.CanUse(Unit, SlotOwner))
		{
			Item.SetDisabled(true);
			Greyed++;
		}
	}
	`log("picker slot=" $ SquadScreen.m_iSelectedSlot @ "owner=" $ SlotOwner @ "greyed=" $ Greyed,, 'CoopSquad');
}

defaultproperties
{
	ScreenClass = class'UIPersonnel_SquadSelect';
}

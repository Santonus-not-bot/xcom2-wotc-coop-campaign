//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopSquadAssign.uc
//  PURPOSE: Squad select (vanilla and robojumper's, both are UISquadSelect): the host assigns
//           squad slots to players for this mission. Two buttons: "Slot N" picks the slot,
//           "Player: X" gives that slot to the next player of the campaign
//           (CoopHostActions.AssignSquadSlot, one ordinary frame). Guests see the assignment of
//           the chosen slot but cannot change it. Only once the campaign has a co-op object.
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopSquadAssign extends UIScreenListener;

var int SelectedSquadSlot;

event OnInit(UIScreen Screen)
{
	local UIButton SlotButton, OwnerButton;

	if (!class'CoopRole'.static.CoopActive() || UISquadSelect(Screen) == none)
	{
		return;
	}
	SelectedSquadSlot = 0;
	SlotButton = Screen.Spawn(class'UIButton', Screen);
	SlotButton.InitButton('CoopAssignSlot', SlotLabel(), OnSlotClicked);
	SlotButton.AnchorTopLeft();
	SlotButton.SetPosition(20, 110);
	OwnerButton = Screen.Spawn(class'UIButton', Screen);
	OwnerButton.InitButton('CoopAssignOwner', OwnerLabel(), OnOwnerClicked);
	OwnerButton.AnchorTopLeft();
	OwnerButton.SetPosition(140, 110);
	if (!class'CoopRole'.static.IsHost())
	{
		OwnerButton.SetDisabled(true);
	}
}

function int SquadSize()
{
	local XComGameState_CoopCampaign Coop;

	Coop = class'XComGameState_CoopCampaign'.static.Get();
	return Max(1, Max((Coop != none) ? Coop.SquadSlotOwner.Length : 0, `XCOMHQ.Squad.Length));
}

function string SlotLabel()
{
	return "Slot" @ (SelectedSquadSlot + 1);
}

function string OwnerLabel()
{
	local XComGameState_CoopCampaign Coop;

	Coop = class'XComGameState_CoopCampaign'.static.Get();
	return "Player:" @ class'UIScreenListener_CoopOwnerButton'.static.SlotName((Coop != none) ? Coop.OwnerOfSquadSlot(SelectedSquadSlot) : 0);
}

function Refresh(UIScreen Screen)
{
	local UIButton Button;

	Button = UIButton(Screen.GetChildByName('CoopAssignSlot', false));
	if (Button != none)
	{
		Button.SetText(SlotLabel());
	}
	Button = UIButton(Screen.GetChildByName('CoopAssignOwner', false));
	if (Button != none)
	{
		Button.SetText(OwnerLabel());
	}
}

function OnSlotClicked(UIButton Button)
{
	SelectedSquadSlot = (SelectedSquadSlot + 1) % SquadSize();
	Refresh(Button.Screen);
}

function OnOwnerClicked(UIButton Button)
{
	local XComGameState_CoopCampaign Coop;
	local int Next;

	Coop = class'XComGameState_CoopCampaign'.static.Get();
	if (Coop == none)
	{
		return;
	}
	Next = (Coop.OwnerOfSquadSlot(SelectedSquadSlot) + 1) % Clamp(Coop.PlayerCount, 1, class'XComGameState_CoopCampaign'.const.MAX_PLAYERS);
	if (class'CoopHostActions'.static.AssignSquadSlot(SelectedSquadSlot, Next))
	{
		Refresh(Button.Screen);
	}
}

defaultproperties
{
	ScreenClass = class'UISquadSelect';
}

//---------------------------------------------------------------------------------------
//  FILE:    UIScreenListener_CoopOwnerButton.uc
//  PURPOSE: Armory soldier screen (UIArmory_MainMenu): an "Owner: ..." button for the host.
//           Each click gives the soldier to the next player slot of the campaign, then to
//           nobody, then to the host again (CoopHostActions.GiveSoldier, one ordinary frame).
//           Guests see who owns the soldier but cannot change it. Only once the campaign has
//           a co-op object.
//---------------------------------------------------------------------------------------
class UIScreenListener_CoopOwnerButton extends UIScreenListener;

event OnInit(UIScreen Screen)
{
	local UIButton Button;

	if (!class'CoopRole'.static.CoopActive() || UIArmory(Screen) == none)
	{
		return;
	}
	Button = Screen.Spawn(class'UIButton', Screen);
	Button.InitButton('CoopOwnerButton', Label(UIArmory(Screen)), OnClicked);
	Button.AnchorTopRight();
	Button.SetPosition(-330, 110);
	if (!class'CoopRole'.static.IsHost())
	{
		Button.SetDisabled(true);
	}
}

event OnReceiveFocus(UIScreen Screen)
{
	local UIButton Button;

	Button = UIButton(Screen.GetChildByName('CoopOwnerButton', false));
	if (Button != none && UIArmory(Screen) != none)
	{
		Button.SetText(Label(UIArmory(Screen)));
	}
}

static function string SlotName(int Slot)
{
	if (Slot == class'CoopOwnership'.const.NO_OWNER)
	{
		return "nobody";
	}
	return (Slot == class'XComGameState_CoopCampaign'.const.SLOT_HOST) ? "Host" : ("Player " $ (Slot + 1));
}

static function string Label(UIArmory Armory)
{
	return "Owner:" @ SlotName(class'CoopOwnership'.static.OwnerOf(Armory.GetUnit()));
}

// Host -> Player 2 -> ... -> last player -> nobody -> Host.
static function int NextOwner(int Current, int PlayerCount)
{
	if (Current == class'CoopOwnership'.const.NO_OWNER)
	{
		return class'XComGameState_CoopCampaign'.const.SLOT_HOST;
	}
	return (Current + 1 < PlayerCount) ? Current + 1 : class'CoopOwnership'.const.NO_OWNER;
}

function OnClicked(UIButton Button)
{
	local UIArmory Armory;
	local XComGameState_CoopCampaign Coop;
	local XComGameState_Unit Unit;

	Armory = UIArmory(Button.Screen);
	Coop = class'XComGameState_CoopCampaign'.static.Get();
	Unit = (Armory != none) ? Armory.GetUnit() : none;
	if (Unit == none || Coop == none)
	{
		return;
	}
	if (class'CoopHostActions'.static.GiveSoldier(Unit.ObjectID, NextOwner(class'CoopOwnership'.static.OwnerOf(Unit), Coop.PlayerCount)))
	{
		Button.SetText(Label(Armory));
	}
}

defaultproperties
{
	ScreenClass = class'UIArmory_MainMenu';
}

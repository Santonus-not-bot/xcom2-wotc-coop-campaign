//---------------------------------------------------------------------------------------
//  FILE:    CoopGuestRights.uc
//  PURPOSE: Target design: the host makes every campaign decision; guests manage only their
//           own soldiers. When a guest opens one of CoopEditGate's edit screens:
//             - a soldier screen (UIArmory and its sub-screens: loadout, promotion, customise...)
//               for a soldier this guest owns: allowed (CoopEditGate still takes the baton, since
//               equipping can create item objects);
//             - anything else: closed.
//           The Armory's soldier list (UIPersonnel_Armory) is allowed, to reach own soldiers.
//           On by default (bHostDecidesCampaign, XComCoopCampaign.ini); the prototype's own
//           baton tests, where the guest changes the campaign, need it off.
//---------------------------------------------------------------------------------------
class CoopGuestRights extends UIScreenListener config(CoopCampaign);

var config bool bHostDecidesCampaign;

// Why a guest may not use this screen, or "" when it may.
static function string Refusal(UIScreen Screen)
{
	local UIArmory Armory;
	local XComGameState_Unit Unit;
	local int MySlot;

	if (!default.bHostDecidesCampaign || !class'CoopRole'.static.CoopActive() || class'CoopRole'.static.IsHost()
		|| !class'CoopEditGate'.static.IsEditScreen(Screen))
	{
		return "";
	}
	MySlot = class'CoopRole'.static.LocalSlot();
	// the Armory's soldier list is how a guest reaches its own soldiers; choosing one opens a UIArmory screen,
	// which is checked below (other personnel lists staff facilities or pick squads: host only)
	if (Screen.Class == class'UIPersonnel_Armory')
	{
		return "";
	}
	Armory = UIArmory(Screen);
	if (Armory == none)
	{
		// with control a guest may do what the host does, except launch missions: the
		// mission build and the guests' way in are built around the host launching (CoopLink)
		if (Screen.IsA('UISquadSelect'))
		{
			return "only the host launches missions";
		}
		return "";
	}
	Unit = Armory.GetUnit();
	if (Unit == none || class'CoopOwnership'.static.OwnerOf(Unit) != MySlot)
	{
		return "soldier " $ ((Unit != none) ? string(Unit.ObjectID) : "?") $ " is not yours";
	}
	return "";
}

event OnInit(UIScreen Screen)
{
	local string Why;

	Why = Refusal(Screen);
	if (Why != "")
	{
		`log("guest closed" @ Screen.Class.Name $ ":" @ Why,, 'CoopRights');
		Screen.CloseScreen();
	}
}

defaultproperties
{
	ScreenClass = none;
}

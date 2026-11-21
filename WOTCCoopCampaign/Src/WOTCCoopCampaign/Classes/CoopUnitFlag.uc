//---------------------------------------------------------------------------------------
//  FILE:    CoopUnitFlag.uc
//  PURPOSE: Unit flags (the name and health bar over each unit) show which player a soldier
//           belongs to in a co-op campaign: a short tag in that player's color next to the flag
//           ("HOST", "P2", "P3", "P4"). Replaces UIUnitFlag (ModClassOverrides); the flag manager
//           spawns one per unit. Updated whenever the flag updates from the unit's state, so a
//           soldier given to another player shows the new owner.
//---------------------------------------------------------------------------------------
class CoopUnitFlag extends UIUnitFlag;

var UIText CoopOwnerText;
var int CoopShownOwner;

static function string OwnerLabel(int Slot)
{
	return (Slot == class'XComGameState_CoopCampaign'.const.SLOT_HOST) ? "HOST" : ("P" $ (Slot + 1));
}

// One color per player slot, readable on the flag's dark background.
static function string OwnerColor(int Slot)
{
	switch (Slot)
	{
		case 0: return "FDCE2B";    // host: gold
		case 1: return "53B45E";    // player 2: green
		case 2: return "E07CE8";    // player 3: pink
		default: return "F29224";   // player 4: orange
	}
}

simulated function UpdateFromUnitState(XComGameState_Unit NewUnitState, bool bInitialUpdate = false, bool bForceUpdate = false)
{
	super.UpdateFromUnitState(NewUnitState, bInitialUpdate, bForceUpdate);
	RealizeCoopOwner(NewUnitState);
}

simulated function RealizeCoopOwner(XComGameState_Unit Unit)
{
	local int SlotOwner;

	if (!bIsInited || Unit == none)
	{
		return;
	}
	SlotOwner = class'CoopOwnership'.const.NO_OWNER;
	if (class'CoopRole'.static.CoopActive() && Unit.GetTeam() == eTeam_XCom)
	{
		SlotOwner = class'CoopOwnership'.static.OwnerOf(Unit);
	}
	if (SlotOwner == CoopShownOwner)
	{
		return;
	}
	CoopShownOwner = SlotOwner;
	if (SlotOwner < 0)
	{
		if (CoopOwnerText != none)
		{
			CoopOwnerText.Hide();
		}
		return;
	}
	if (CoopOwnerText == none)
	{
		CoopOwnerText = Spawn(class'UIText', self);
		CoopOwnerText.InitText('CoopOwnerTag');
		// left of the rank icon, level with the health bar (checked on screenshots at 960x540)
		CoopOwnerText.SetPosition(-70, -40);
		CoopOwnerText.SetWidth(66);
	}
	CoopOwnerText.SetHTMLText("<p align='right'><font size='22' color='#" $ OwnerColor(SlotOwner) $ "'><b>" $ OwnerLabel(SlotOwner) $ "</b></font></p>");
	CoopOwnerText.Show();
	`log("flag unit=" $ Unit.ObjectID @ "owner=" $ SlotOwner @ "label=" $ OwnerLabel(SlotOwner),, 'CoopFlags');
}

defaultproperties
{
	CoopShownOwner = -2
}

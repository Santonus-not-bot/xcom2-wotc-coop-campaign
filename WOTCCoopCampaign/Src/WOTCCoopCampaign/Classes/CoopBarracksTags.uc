//---------------------------------------------------------------------------------------
//  FILE:    CoopBarracksTags.uc
//  PURPOSE: Who owns each soldier, in the soldier lists (Barracks, squad picking...): a tag at the right end of the
//           row ("HOST" / "P2 <name>") in the owner's colour, and the rows of other players' soldiers tinted in
//           their colour (the host's rows stay as the game draws them).
//           CoopHUDScreen calls Decorate twice a second; rows the list rebuilds are decorated again.
//---------------------------------------------------------------------------------------
class CoopBarracksTags extends Object config(CoopCampaign);

const TAG_W = 200;
const TAG_X = 340;     // row-relative: ends at the right of the name column

var config bool bLoggedSize;

static function Decorate()
{
	local UIScreen Screen;
	local UIPersonnel Personnel;
	local int i, Count;

	if (`HQPRES == none || `HQPRES.ScreenStack == none || !class'CoopRole'.static.CoopActive())
	{
		return;
	}
	foreach `HQPRES.ScreenStack.Screens(Screen)
	{
		Personnel = UIPersonnel(Screen);
		if (Personnel == none || Personnel.m_kList == none)
		{
			continue;
		}
		for (i = 0; i < Personnel.m_kList.ItemCount; i++)
		{
			if (DecorateRow(UIPersonnel_ListItem(Personnel.m_kList.GetItem(i))))
			{
				Count++;
			}
		}
	}
	if (Count > 0)
	{
		`log("barracks: tagged" @ Count @ "soldier rows with their owners",, 'CoopHUD');
	}
}

// True when the row got its tag now.
static function bool DecorateRow(UIPersonnel_ListItem Row)
{
	local XComGameState_Unit Unit;
	local UIText Tag;
	local UIPanel Tint;
	local int Owner;
	local string HexColor, Label;
	local float RowW, RowH;

	if (Row == none || Row.GetChildByName('CoopOwnerTag', false) != none)
	{
		return false;
	}
	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(Row.UnitRef.ObjectID));
	if (Unit == none || !Unit.IsSoldier())
	{
		return false;
	}
	Owner = class'CoopOwnership'.static.OwnerOf(Unit);
	if (Owner < 0)
	{
		return false;    // unassigned: no tag (only soldiers given to the host say HOST)
	}
	HexColor = class'CoopUnitFlag'.static.OwnerColor(Owner);
	Label = Caps(class'CoopRoster'.static.SlotLabel(Owner));
	if (Owner != class'XComGameState_CoopCampaign'.const.SLOT_HOST)
	{
		Label = "P" $ (Owner + 1) @ class'CoopRoster'.static.DisplayName(Owner);
	}
	RowW = 1000;
	if (Row.Width > 0)
	{
		RowW = Row.Width;
	}
	RowH = 40;
	if (Row.Height > 0)
	{
		RowH = Row.Height;
	}
	if (Owner != class'XComGameState_CoopCampaign'.const.SLOT_HOST)
	{
		Tint = Row.Spawn(class'UIPanel', Row).InitPanel('CoopOwnerTint', class'UIUtilities_Controls'.const.MC_GenericPixel);
		Tint.SetPosition(0, 0);
		Tint.SetSize(RowW, RowH);
		Tint.SetColor("0x" $ HexColor);
		Tint.SetAlpha(18);
		Tint.DisableNavigation();
	}
	// at the right end of the name column (the row's own width ran past the list: no tag showed, 2026-11-19)
	Tag = Row.Spawn(class'UIText', Row);
	Tag.InitText('CoopOwnerTag', "");
	Tag.SetPosition(TAG_X, 6);
	Tag.SetWidth(TAG_W);
	Tag.SetHTMLText("<p align='RIGHT'><font size='16' color='#" $ HexColor $ "'><b>" $ Label $ "</b></font></p>");
	if (!default.bLoggedSize)
	{
		default.bLoggedSize = true;
		`log("barracks: row size" @ Row.Width $ "x" $ Row.Height @ "tag at" @ TAG_X,, 'CoopHUD');
	}
	return true;
}

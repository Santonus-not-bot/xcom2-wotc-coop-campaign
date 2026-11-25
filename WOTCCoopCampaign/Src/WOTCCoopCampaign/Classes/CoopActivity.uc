//---------------------------------------------------------------------------------------
//  FILE:    CoopActivity.uc
//  PURPOSE: What each player is doing on the Avenger, for the others ("In the Armory", "On the Geoscape").
//           Every second (CoopLink's timer) a machine on the Avenger names the screen its player is in, and
//           sends "CoopActivity"(slot, text) when that changes and every 10 s (for players who join later). The
//           host passes a guest's activity on to the other guests. CoopPlayerPanel shows it.
//           A plain Object; the state lives in class defaults (they survive map changes).
//---------------------------------------------------------------------------------------
class CoopActivity extends Object config(CoopCampaign);

const RESEND_SECONDS = 10;
const MAX_PLAYERS = 4;
const SQUAD_TEXT = "Selecting the squad";

var config bool bInited;
var config string LocalShown;          // our activity as last sent
var config int LocalSentAt;            // clock seconds of the last send
var config array<string> SlotText;     // by player slot: what that player is doing ("" = unknown)
var config array<int> SlotAt;          // by player slot: clock seconds of the last news

static function Init()
{
	local CoopActivity Listener;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	default.SlotText.Length = MAX_PLAYERS;
	default.SlotAt.Length = MAX_PLAYERS;
	Listener = new class'CoopActivity';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Listener.OnRemoteCommand);
}

// The screens that tell what a player is doing; the first match from the top of the stack wins.
static function string TextFor(UIScreen Screen)
{
	if (Screen == none)                              return "";
	if (Screen.IsA('UISquadSelect'))                 return SQUAD_TEXT;
	if (Screen.IsA('UIPersonnel_SquadSelect'))       return SQUAD_TEXT;
	if (Screen.IsA('UIArmory_Promotion') || Screen.IsA('UIArmory_PromotionHero') || Screen.IsA('UIArmory_PromotionPsiOp'))
	                                                 return "Promoting a soldier";
	if (Screen.IsA('UIArmory_Loadout'))              return "Changing a soldier's loadout";
	if (Screen.IsA('UIArmory_WeaponUpgrade'))        return "Upgrading a weapon";
	if (Screen.IsA('UIArmory_Implants'))             return "Fitting PCS implants";
	if (Screen.IsA('UIArmory_Photobooth'))           return "In the photo booth";
	if (Screen.IsA('UIArmory'))                      return "In the Armory";
	if (Screen.IsA('UIChooseResearch'))              return "Choosing research";
	if (Screen.IsA('UIChooseProject'))               return "Choosing a Proving Ground project";
	if (Screen.IsA('UIChooseClass'))                 return "Training a soldier's class";
	if (Screen.IsA('UIChoosePsiAbility'))            return "Choosing a psionic ability";
	if (Screen.IsA('UIChooseUpgrade'))               return "Upgrading a facility";
	if (Screen.IsA('UIChooseFacility') || Screen.IsA('UIBuildFacilities'))
	                                                 return "Building facilities";
	if (Screen.IsA('UIInventory_BuildItems'))        return "Building items in Engineering";
	if (Screen.IsA('UIInventory'))                   return "Looking at the inventory";
	if (Screen.IsA('UIRecruitSoldiers'))             return "Recruiting soldiers";
	if (Screen.IsA('UIPersonnel'))                   return "Managing personnel";
	if (Screen.IsA('UIBlackMarket') || Screen.IsA('UIBlackMarket_Buy') || Screen.IsA('UIBlackMarket_Sell'))
	                                                 return "At the Black Market";
	if (Screen.IsA('UIResistanceGoods'))             return "Trading with the Resistance";
	if (Screen.IsA('UICovertActions'))               return "Planning covert actions";
	if (Screen.IsA('UIStrategyPolicy'))              return "Setting Resistance Orders";
	if (Screen.IsA('UIResistanceReport') || Screen.IsA('UIResistanceReport_ChosenEvents') || Screen.IsA('UIResistanceReport_FactionEvents'))
	                                                 return "Reading the Resistance report";
	if (Screen.IsA('UIAfterAction') || Screen.IsA('UIMissionSummary'))
	                                                 return "Reviewing the mission";
	// the mission briefing before squad select (UIMission_GOps, _Council, ...) is not a UIAlert and had no line, so
	// the host showed "Reading an alert" (playtest 2026-11-19) right before "Picking the squad", probably from a
	// UIAlert lower in the stack
	if (Screen.IsA('UIMission'))                     return "Looking at a mission";
	if (Screen.IsA('UIAlert'))                       return "Reading an alert";
	if (Screen.IsA('UIFacility_Labs'))               return "In the Research Lab";
	if (Screen.IsA('UIFacility_Workshop') || Screen.IsA('UIFacility_Storage'))
	                                                 return "In Engineering";
	if (Screen.IsA('UIFacility_ProvingGround'))      return "In the Proving Ground";
	if (Screen.IsA('UIFacility_Infirmary'))          return "In the Infirmary";
	if (Screen.IsA('UIFacility_TrainingCenter'))     return "In the Training Center";
	if (Screen.IsA('UIFacility_PsiLab'))             return "In the Psi Lab";
	if (Screen.IsA('UIFacility_ShadowChamber'))      return "In the Shadow Chamber";
	if (Screen.IsA('UIFacility_CovertActions'))      return "In the Resistance Ring";
	if (Screen.IsA('UIFacility_BarMemorial'))        return "In the Bar";
	if (Screen.IsA('UIFacility_LivingQuarters'))     return "In the Living Quarters";
	if (Screen.IsA('UIFacility'))                    return "Visiting a facility";
	if (Screen.IsA('UIStrategyMap'))                 return "On the Geoscape";
	if (Screen.IsA('UIFacilityGrid') || Screen.IsA('UIAvengerHUD'))
	                                                 return "Looking around the Avenger";
	return "";
}

static function string LocalText()
{
	local XComPresentationLayerBase Pres;
	local string Text;
	local int i;

	if (XComHeadquartersGame(class'WorldInfo'.static.GetWorldInfo().Game) == none)
	{
		return "";
	}
	Pres = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres;
	if (Pres == none || Pres.ScreenStack == none)
	{
		return "";
	}
	// Squad select is one activity from opening it to the launch, also while a soldier's Armory screens or the
	// soldier list are open over it.
	for (i = 0; i < Pres.ScreenStack.Screens.Length; i++)
	{
		if (Pres.ScreenStack.Screens[i] != none && Pres.ScreenStack.Screens[i].IsA('UISquadSelect'))
		{
			return SQUAD_TEXT;
		}
	}
	for (i = 0; i < Pres.ScreenStack.Screens.Length; i++)
	{
		Text = TextFor(Pres.ScreenStack.Screens[i]);
		if (Text != "")
		{
			return Text;
		}
	}
	return "On the Avenger";
}

// CoopLink.Tick, every second.
static function Tick()
{
	local string Text;

	if (!class'CoopSession'.static.IsConnected())
	{
		return;
	}
	Init();
	Text = LocalText();
	if (Text == "")
	{
		return;
	}
	if (Text != default.LocalShown || class'CoopMissionLoading'.static.ClockSeconds() - default.LocalSentAt >= RESEND_SECONDS
		|| class'CoopMissionLoading'.static.ClockSeconds() < default.LocalSentAt)
	{
		if (Text != default.LocalShown)
		{
			`log("activity: player" @ class'CoopRole'.static.LocalSlot() @ Text,, 'CoopActivity');
		}
		default.LocalShown = Text;
		default.LocalSentAt = class'CoopMissionLoading'.static.ClockSeconds();
		Note(class'CoopRole'.static.LocalSlot(), Text);
		Send(class'CoopRole'.static.LocalSlot(), Text);
	}
}

static function Send(int Slot, string Text)
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Slot, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(Text, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopActivity", Params);
}

static function Note(int Slot, string Text)
{
	if (Slot < 0 || Slot >= MAX_PLAYERS)
	{
		return;
	}
	if (default.SlotText.Length < MAX_PLAYERS)
	{
		default.SlotText.Length = MAX_PLAYERS;
		default.SlotAt.Length = MAX_PLAYERS;
	}
	default.SlotText[Slot] = Text;
	default.SlotAt[Slot] = class'CoopMissionLoading'.static.ClockSeconds();
}

// What Slot's player is doing, "" when unknown or stale (no news for 30 s).
static function string TextOf(int Slot)
{
	local int Age;

	if (Slot < 0 || Slot >= default.SlotText.Length || default.SlotText[Slot] == "")
	{
		return "";
	}
	Age = class'CoopMissionLoading'.static.ClockSeconds() - default.SlotAt[Slot];
	if (Age >= 0 && Age <= 3 * RESEND_SECONDS)
	{
		return default.SlotText[Slot];
	}
	return "";
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local int Slot;
	local string Text;

	if (Command != "CoopActivity")
	{
		return;
	}
	Slot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Text = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
	if (Slot == class'CoopRole'.static.LocalSlot())
	{
		return;    // our own, forwarded back
	}
	if (TextOf(Slot) != Text)
	{
		`log("activity of player" @ Slot $ ":" @ Text,, 'CoopActivity');
	}
	Note(Slot, Text);
	if (!class'CoopRole'.static.IsGuest() && class'CoopRole'.default.ConnectedSlots.Length > 1)
	{
		Send(Slot, Text);    // to the other guests (guests connect only to the host)
	}
}

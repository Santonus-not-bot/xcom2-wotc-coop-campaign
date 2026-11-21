//---------------------------------------------------------------------------------------
//  FILE:    CoopHUDScreen.uc
//  PURPOSE: The mod's always-on layer for co-op information, one per map:
//             - the player panel (main menu and Avenger): every player by name in their colour, their slot,
//               their connection state (CoopRoster) and, on the Avenger, what they are doing (CoopActivity);
//             - toasts (every map): a short banner when a player joins, leaves, reconnects or comes back;
//             - in a mission, what the player whose turn it is does (CoopPresence): a marker in their colour on
//               the tile under their cursor, a tag over the soldier they selected, a line under the turn banner
//               ("Player 2 is aiming at ... with ...") and their units' abilities as they use them.
//           Loaded into the 2D movie the way the game loads its message managers (UIMovie_2D.OnInit: InitScreen +
//           LoadScreen), not pushed on the screen stack: a pushed screen takes the focus and the screen under it
//           (the Avenger HUD) hides itself (UIScreen.bHideOnLoseFocus). So it never takes input and stays up
//           whatever screen opens. UIScreenListener_CoopHUD adds it.
//---------------------------------------------------------------------------------------
class CoopHUDScreen extends UIScreen config(CoopCampaign);

var config bool bHideDebugRedScreens;   // the game's debug red screens off (test copies a person plays)

const PANEL_W = 500;
const PANEL_X = -520;     // from the right edge
const PANEL_Y = 250;
const ROW_H = 27;
const TOAST_W = 640;
const TOAST_Y = 190;
const TOAST_SECONDS = 4.0;

var UIBGBox BG, ToastBG, LineBG, SquadBG;
var UIText Header, Rows, ToastText, LineText, MarkerText, UnitTag, SquadText;
var string SquadShown;
var UIPanel MarkerDot;
var string Shown, LineShown, MarkerShown;
var float ToastUntil, FeedUntil;
var string FeedShown;
var int PresenceTicks;

const LINE_W = 760;
const LINE_Y = 250;

static function Ensure()
{
	local XComPresentationLayerBase Pres;
	local CoopHUDScreen HUD;

	Pres = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres;
	if (Pres == none || Pres.Get2DMovie() == none || !Pres.Get2DMovie().bIsInited || !Pres.IsPresentationLayerReady()
		|| !class'CoopMissionLoading'.static.MapSettled())
	{
		return;    // not ready yet: a screen loaded now never shows (CoopMissionLoading.Show); CoopLink's timer tries again
	}
	foreach class'WorldInfo'.static.GetWorldInfo().AllActors(class'CoopHUDScreen', HUD)
	{
		return;
	}
	HUD = Pres.Spawn(class'CoopHUDScreen', Pres);
	HUD.InitScreen(XComPlayerController(Pres.Owner), Pres.Get2DMovie());
	Pres.Get2DMovie().LoadScreen(HUD);
	`log("co-op HUD loaded on" @ class'WorldInfo'.static.GetWorldInfo().GetMapName(),, 'CoopHUD');
	// a guest on the Avenger or in a mission: the map it loaded is up (the host's panel stops saying "loading")
	if (class'CoopRoster'.static.GuestSide() && XComShell(class'WorldInfo'.static.GetWorldInfo().Game) == none)
	{
		class'CoopRoster'.static.GuestLoading(false);
	}
}

simulated function InitScreen(XComPlayerController InitController, UIMovie InitMovie, optional name InitName)
{
	super.InitScreen(InitController, InitMovie, InitName);
	BG = Spawn(class'UIBGBox', self);
	BG.InitBG('CoopHUDBox', 0, 0, PANEL_W, 80, eUIState_Normal);
	BG.AnchorTopRight();
	BG.SetPosition(PANEL_X, PANEL_Y);
	Header = Spawn(class'UIText', self);
	Header.InitText('CoopHUDHeader', "");
	Header.AnchorTopRight();
	Header.SetPosition(PANEL_X + 12, PANEL_Y + 6);
	Header.SetWidth(PANEL_W - 24);
	Rows = Spawn(class'UIText', self);
	Rows.InitText('CoopHUDRows', "");
	Rows.AnchorTopRight();
	Rows.SetPosition(PANEL_X + 12, PANEL_Y + 34);
	Rows.SetWidth(PANEL_W - 24);

	ToastBG = Spawn(class'UIBGBox', self);
	ToastBG.InitBG('CoopToastBox', 0, 0, TOAST_W, 50, eUIState_Highlight);
	ToastBG.AnchorTopCenter();
	ToastBG.SetPosition(-TOAST_W / 2, TOAST_Y);
	ToastText = Spawn(class'UIText', self);
	ToastText.InitText('CoopToastText', "");
	ToastText.AnchorTopCenter();
	ToastText.SetPosition(-TOAST_W / 2, TOAST_Y + 9);
	ToastText.SetWidth(TOAST_W);

	LineBG = Spawn(class'UIBGBox', self);
	LineBG.InitBG('CoopLineBox', 0, 0, LINE_W, 66, eUIState_Normal);
	LineBG.AnchorTopCenter();
	LineBG.SetPosition(-LINE_W / 2, LINE_Y);
	LineText = Spawn(class'UIText', self);
	LineText.InitText('CoopLineText', "");
	LineText.AnchorTopCenter();
	LineText.SetPosition(-LINE_W / 2, LINE_Y + 6);
	LineText.SetWidth(LINE_W);
	MarkerDot = Spawn(class'UIPanel', self).InitPanel('CoopMarkerDot', class'UIUtilities_Controls'.const.MC_GenericPixel);
	MarkerDot.SetSize(16, 16);
	MarkerText = Spawn(class'UIText', self);
	MarkerText.InitText('CoopMarkerText', "");
	MarkerText.SetWidth(300);
	UnitTag = Spawn(class'UIText', self);
	UnitTag.InitText('CoopUnitTag', "");
	UnitTag.SetWidth(300);
	SquadBG = Spawn(class'UIBGBox', self);
	SquadBG.InitBG('CoopSquadBox', 40, 250, 560, 100, eUIState_Normal);
	SquadText = Spawn(class'UIText', self);
	SquadText.InitText('CoopSquadText', "");
	SquadText.SetPosition(54, 258);
	SquadText.SetWidth(532);
	SquadBG.Hide();
	SquadText.Hide();
	LineBG.Hide();
	LineText.Hide();
	MarkerDot.Hide();
	MarkerText.Hide();
	UnitTag.Hide();

	ShowPanel(false);
	ToastBG.Hide();
	ToastText.Hide();
	Refresh();
	SetTimer(0.5f, true, nameof(Refresh));
	if (class'CoopSession'.static.InTactical())
	{
		ListenForAbilities();
		SetTimer(0.1f, true, nameof(PresenceTick));
	}
	else if (XComHeadquartersGame(WorldInfo.Game) != none)
	{
		SetTimer(0.1f, true, nameof(GeoTick));
	}
}

// The game's 'AbilityActivated' event on this map (the screen lives as long as the map), for CoopPresence's feed.
simulated function ListenForAbilities()
{
	local Object ThisObj;

	ThisObj = self;
	`XEVENTMGR.RegisterForEvent(ThisObj, 'AbilityActivated', OnAbilityActivated, ELD_OnStateSubmitted);
	`log("co-op HUD: listening for abilities to report",, 'CoopHUD');
}

function EventListenerReturn OnAbilityActivated(Object EventData, Object EventSource, XComGameState GameState, Name EventID, Object CallbackData)
{
	class'CoopPresence'.static.AbilityUsed(EventData, EventSource, GameState);
	return ELR_NoInterrupt;
}

// Ten times a second on the Avenger: a guest without control watches the host's Geoscape (CoopGeoWatch).
simulated function GeoTick()
{
	class'CoopGeoWatch'.static.GuestTick();
}

// Ten times a second in a mission: send our presence (4 times a second) and draw the other player's.
simulated function PresenceTick()
{
	local int Slot;
	local string Line, HexColor, Feed;
	local vector2D Screen2D, UIPos;
	local vector UnitLoc;
	local XGUnit Visualizer;
	local bool bOnScreen;

	PresenceTicks++;
	if (PresenceTicks % 3 == 0)
	{
		class'CoopPresence'.static.Tick();
	}
	// the feed: abilities the other player's units used, each for a few seconds
	if (FeedUntil > 0 && WorldInfo.RealTimeSeconds >= FeedUntil)
	{
		FeedUntil = 0;
		FeedShown = "";
	}
	if (FeedUntil == 0 && class'CoopPresence'.default.Feed.Length > 0)
	{
		FeedShown = class'CoopPresence'.default.Feed[0];
		class'CoopPresence'.default.Feed.Remove(0, 1);
		FeedUntil = WorldInfo.RealTimeSeconds + 4.0;
		`log("feed shown:" @ FeedShown,, 'CoopHUD');
	}
	if (!class'CoopPresence'.static.Current(Slot))
	{
		HidePresence(FeedShown);
		return;
	}
	HexColor = class'CoopUnitFlag'.static.OwnerColor(Slot);
	Line = class'CoopPresence'.static.Line();
	Feed = FeedShown;
	SetLine(Line, Feed, HexColor);

	// the marker on the tile under the other player's cursor
	bOnScreen = class'UIUtilities'.static.IsOnScreen(class'CoopPresence'.default.PresCursor, Screen2D, 0, 0);
	if (bOnScreen)
	{
		UIPos = Movie.ConvertNormalizedScreenCoordsToUICoords(Screen2D.X, Screen2D.Y, false);
		MarkerDot.SetColor("0x" $ HexColor);
		MarkerDot.SetPosition(UIPos.X - 8, UIPos.Y - 8);
		MarkerText.SetPosition(UIPos.X - 150, UIPos.Y - 40);
		if (MarkerShown != class'CoopRoster'.static.DisplayName(Slot))
		{
			MarkerShown = class'CoopRoster'.static.DisplayName(Slot);
			MarkerText.SetHTMLText("<p align='CENTER'><font size='18' color='#" $ HexColor $ "'><b>" $ MarkerShown $ "</b></font></p>");
			`log("presence marker of player" @ Slot @ "on screen at" @ int(UIPos.X) $ "," $ int(UIPos.Y),, 'CoopHUD');
		}
		MarkerDot.Show();
		MarkerText.Show();
	}
	else
	{
		MarkerDot.Hide();
		MarkerText.Hide();
	}

	// the tag over the soldier they selected
	Visualizer = XGUnit(`XCOMHISTORY.GetVisualizer(class'CoopPresence'.default.PresUnit));
	if (Visualizer != none && Visualizer.GetPawn() != none)
	{
		UnitLoc = Visualizer.GetPawn().Location;
		UnitLoc.Z += 120;
		if (class'UIUtilities'.static.IsOnScreen(UnitLoc, Screen2D, 0, 0))
		{
			UIPos = Movie.ConvertNormalizedScreenCoordsToUICoords(Screen2D.X, Screen2D.Y, false);
			UnitTag.SetPosition(UIPos.X - 150, UIPos.Y - 20);
			UnitTag.SetHTMLText("<p align='CENTER'><font size='16' color='#" $ HexColor $ "'><b>SELECTED BY " $ Caps(class'CoopRoster'.static.SlotLabel(Slot)) $ "</b></font></p>");
			UnitTag.Show();
			return;
		}
	}
	UnitTag.Hide();
}

simulated function SetLine(string Line, string Feed, string HexColor)
{
	local string Html;

	if ((Line $ Feed) == LineShown)
	{
		return;
	}
	LineShown = Line $ Feed;
	if (Line == "" && Feed == "")
	{
		LineBG.Hide();
		LineText.Hide();
		return;
	}
	Html = "<p align='CENTER'><font size='20' color='#" $ HexColor $ "'><b>" $ Line $ "</b></font>";
	if (Feed != "")
	{
		Html $= "<br/><font size='17' color='#FDCE2B'>" $ Feed $ "</font>";
	}
	LineText.SetHTMLText(Html $ "</p>");
	LineBG.SetHeight(Feed != "" ? 66 : 40);
	LineBG.Show();
	LineText.Show();
	`log("presence line:" @ Line $ (Feed != "" ? " / " $ Feed : ""),, 'CoopHUD');
}

simulated function HidePresence(string Feed)
{
	MarkerDot.Hide();
	MarkerText.Hide();
	UnitTag.Hide();
	MarkerShown = "";
	SetLine("", Feed, "FFFFFF");
}

simulated function ShowPanel(bool bShow)
{
	if (bShow)
	{
		BG.Show();
		Header.Show();
		Rows.Show();
	}
	else
	{
		BG.Hide();
		Header.Hide();
		Rows.Hide();
	}
}

// Where the panel belongs: the main menu and the Avenger. In a mission the turn banner says whose turn it is.
simulated function bool PanelWanted()
{
	return !class'CoopSession'.static.InTactical()
		&& (class'CoopSession'.static.IsConnected() || class'CoopLink'.default.bReconnecting || class'CoopMenu'.static.IsHosting());
}

static function string StateColor(int PState)
{
	switch (PState)
	{
	case class'CoopRoster'.const.PS_CONNECTED:    return "53B45E";
	case class'CoopRoster'.const.PS_RECONNECTING: return "FDCE2B";
	case class'CoopRoster'.const.PS_LOADING:      return "9ACBCB";
	case class'CoopRoster'.const.PS_LEFT:         return "BF1E2E";
	}
	return "828282";
}

// The rows are built with if/else only: with nested string ternaries the local row came out without its state
// and the others without their activity (avengerfeed 2026-11-18, compiled by the SDK's UCC).
simulated function Refresh()
{
	local string S, Plain, Line, StateText, Activity, NameText;
	local int Slot, Count, PState, MySlot;

	ShowNextToast();
	if (XComHeadquartersGame(WorldInfo.Game) != none)
	{
		class'CoopBarracksTags'.static.Decorate();
		ShowSquadView();
	}
	if (PanelWanted())
	{
		MySlot = class'CoopRoster'.static.MySlot();
		for (Slot = 0; Slot < class'CoopRoster'.const.MAX_PLAYERS; Slot++)
		{
			PState = class'CoopRoster'.static.StateOf(Slot);
			if (Slot == MySlot)
			{
				PState = class'CoopRoster'.const.PS_CONNECTED;
			}
			if (PState == class'CoopRoster'.const.PS_NONE)
			{
				continue;
			}
			StateText = class'CoopRoster'.static.StateText(PState);
			// what this guest sees of the host while the host builds a mission or the guest reconnects
			if (class'CoopRoster'.static.GuestSide() && Slot == class'XComGameState_CoopCampaign'.const.SLOT_HOST
				&& class'CoopLink'.default.bReconnecting)
			{
				PState = class'CoopRoster'.const.PS_RECONNECTING;
				if (class'CoopMissionLoading'.default.bActive)
				{
					StateText = class'CoopMissionLoading'.default.bReturn ? "loading the Avenger" : "building the mission";
				}
				else
				{
					StateText = "reconnecting";
				}
			}
			Activity = "";
			if (PState == class'CoopRoster'.const.PS_CONNECTED)
			{
				if (Slot == MySlot)
				{
					Activity = class'CoopActivity'.default.LocalShown;
				}
				else
				{
					Activity = class'CoopActivity'.static.TextOf(Slot);
				}
			}
			NameText = class'CoopRoster'.static.DisplayName(Slot);
			if (Slot == MySlot)
			{
				NameText = NameText $ " (you)";
			}
			Line = "<font color='#" $ class'CoopUnitFlag'.static.OwnerColor(Slot) $ "'><b>" $ Caps(class'CoopRoster'.static.SlotLabel(Slot))
				$ "</b></font>  <font color='#FFFFFF'>" $ NameText $ "</font>  <font size='16' color='#" $ StateColor(PState) $ "'>"
				$ StateText $ "</font>";
			if (Activity != "")
			{
				Line = Line $ "<br/><font size='16' color='#BFBFBF'>     " $ Activity $ "</font>";
				Count++;
			}
			if (S != "")
			{
				S = S $ "<br/>";
				Plain = Plain $ " | ";
			}
			S = S $ Line;
			Plain = Plain $ class'CoopRoster'.static.SlotLabel(Slot) $ " " $ NameText $ " " $ StateText;
			if (Activity != "")
			{
				Plain = Plain $ " - " $ Activity;
			}
			Count++;
		}
	}
	if (S == Shown)
	{
		return;
	}
	Shown = S;
	if (S == "")
	{
		ShowPanel(false);
		return;
	}
	Header.SetHTMLText("<font size='16' color='#9ACBCB'><b>CO-OP PLAYERS</b></font>");
	Rows.SetHTMLText("<font size='19'>" $ S $ "</font>");
	BG.SetHeight(44 + Count * ROW_H);
	ShowPanel(true);
	`log("co-op HUD rows:" @ Plain,, 'CoopHUD');
}

// A guest on the Avenger while the host picks the squad (CoopSquadView): the mission and the squad so far.
simulated function ShowSquadView()
{
	local array<string> Parts;
	local string S;
	local int i;

	S = "";
	if (class'CoopRoster'.static.GuestSide())
	{
		S = class'CoopSquadView'.static.Current();
	}
	if (S == SquadShown)
	{
		return;
	}
	SquadShown = S;
	if (S == "")
	{
		SquadBG.Hide();
		SquadText.Hide();
		return;
	}
	ParseStringIntoArray(S, Parts, "|", false);
	S = "<font size='16' color='#9ACBCB'><b>" $ Caps(class'CoopRoster'.static.DisplayName(class'XComGameState_CoopCampaign'.const.SLOT_HOST))
		$ " IS PICKING THE SQUAD</b></font><br/><font size='20' color='#FFFFFF'><b>" $ Parts[0] $ "</b></font>";
	for (i = 1; i < Parts.Length; i++)
	{
		S $= "<br/><font size='18' color='#E0E0E0'>" $ Parts[i] $ "</font>";
	}
	SquadText.SetHTMLText(S);
	SquadBG.SetHeight(66 + (Parts.Length - 1) * 25);
	SquadBG.Show();
	SquadText.Show();
	`log("squad view shown:" @ Repl(SquadShown, "|", " / "),, 'CoopHUD');
}

simulated function ShowNextToast()
{
	local string Text;

	if (ToastUntil > 0 && WorldInfo.RealTimeSeconds < ToastUntil)
	{
		return;
	}
	if (class'CoopRoster'.default.Toasts.Length == 0)
	{
		if (ToastUntil > 0)
		{
			ToastUntil = 0;
			ToastBG.Hide();
			ToastText.Hide();
		}
		return;
	}
	Text = class'CoopRoster'.default.Toasts[0];
	class'CoopRoster'.default.Toasts.Remove(0, 1);
	ToastText.SetHTMLText("<p align='CENTER'><font size='24' color='#FFFFFF'><b>" $ Text $ "</b></font></p>");
	ToastBG.Show();
	ToastText.Show();
	ToastUntil = WorldInfo.RealTimeSeconds + TOAST_SECONDS;
	`log("toast shown:" @ Text,, 'CoopHUD');
}

defaultproperties
{
	InputState = eInputState_None;
	bHideOnLoseFocus = false;
}

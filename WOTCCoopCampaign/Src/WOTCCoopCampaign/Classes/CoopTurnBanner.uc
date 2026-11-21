//---------------------------------------------------------------------------------------
//  FILE:    CoopTurnBanner.uc
//  PURPOSE: In co-op missions every player sees whose turn it is: the game's own turn overlay
//           screen (UITurnOverlay) carries a box (CoopTurnBannerPanel) that shows "YOUR TURN" on the
//           machine whose player's soldiers now act and "PLAYER 2'S TURN" (or "HOST'S TURN") on the
//           others, in that player's flag color. The machine that begins an XCom
//           initiative announces it (CoopTacticalRuleset) with "CoopTurnOf"(slot); the host passes
//           a guest's announcement on to the other guests (guests connect only to the host).
//           Enemy turns keep the game's own banners.
//           A plain Object (delegates on the network manager must not point at Actors).
//---------------------------------------------------------------------------------------
class CoopTurnBanner extends Object config(CoopCampaign);

var config bool bInited;       // config only so the default may be written
var config int LastLocalSlot;  // the player whose turn this machine announced last (-1 = none since)

static function Init()
{
	local CoopTurnBanner Banner;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	default.LastLocalSlot = -1;
	Banner = new class'CoopTurnBanner';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Banner.OnRemoteCommand);
}

// CoopTacticalRuleset: this machine just began an initiative entry.
static function OnLocalInitiativeBegun(XComGameState_BaseObject Entry)
{
	local XComGameState_AIGroup Group;
	local XComGameState_Player Player;
	local int Slot;

	if (!class'CoopRole'.static.CoopActive() || Entry == none)
	{
		return;
	}
	Group = XComGameState_AIGroup(Entry);
	Player = XComGameState_Player(Entry);
	if (!((Group != none && Group.TeamName == eTeam_XCom) || (Player != none && Player.TeamFlag == eTeam_XCom)))
	{
		// an enemy entry: the next XCom entry is a new turn. Once per enemy turn, take down the banner of the
		// player who just played, here and on the other machines ("CoopTurnOf"(-1)).
		if (default.LastLocalSlot != -2)
		{
			default.LastLocalSlot = -2;
			Init();
			Show(-1);
			Send(-1);
		}
		return;
	}
	Slot = class'CoopTactical'.static.ControllerOfInitiative(Entry);
	if (Slot == default.LastLocalSlot)
	{
		return;    // the XCom player entry and the host's own group follow each other: one banner
	}
	default.LastLocalSlot = Slot;
	Init();
	Show(Slot);
	Send(Slot);
}

// CoopTacticalRuleset: this machine handed the turn to another; its next begin is a new turn.
static function OnHandedOver()
{
	default.LastLocalSlot = -1;
}

static function Send(int Slot)
{
	local array<byte> Params;

	if (!`XCOMNETMANAGER.HasConnections())
	{
		return;
	}
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Slot, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopTurnOf", Params);
}

static function string TurnText(int Slot)
{
	if (Slot == class'CoopRole'.static.LocalSlot())
	{
		return "YOUR TURN";
	}
	return (Slot == class'XComGameState_CoopCampaign'.const.SLOT_HOST) ? "HOST'S TURN" : ("PLAYER" @ (Slot + 1) $ "'S TURN");
}

static function Show(int Slot)
{
	local XComPresentationLayer Pres;
	local UITurnOverlay Overlay;
	local CoopTurnBannerPanel Panel;
	local string Text;

	Text = (Slot < 0) ? "" : TurnText(Slot);
	`log("turn banner:" @ (Slot < 0 ? "(hidden: enemy turn)" : Text) @ "(player" @ Slot $ ")",, 'CoopBanner');
	Pres = XComPresentationLayer(XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres);
	if (Pres == none)
	{
		`log("turn banner not shown: no tactical presentation layer",, 'CoopBanner');
		return;
	}
	if (Pres.m_kTurnOverlay == none)
	{
		Pres.UITurnOverlay();
	}
	Overlay = Pres.m_kTurnOverlay;
	if (Overlay == none || !Overlay.bIsInited)
	{
		`log("turn banner not shown: overlay" @ (Overlay == none ? "missing" : "not ready"),, 'CoopBanner');
		return;
	}
	// The overlay's own XCom banner draws no text (the game shows none at the start of an XCom turn),
	// so the text is the mod's own panel on the overlay screen.
	Panel = CoopTurnBannerPanel(Overlay.GetChildByName('CoopTurnBanner', false));
	if (Panel == none)
	{
		Panel = Overlay.Spawn(class'CoopTurnBannerPanel', Overlay).InitBanner();
	}
	if (Slot < 0)
	{
		Panel.HideBanner();
		return;
	}
	// another player's turn stays up while they play; "YOUR TURN" goes after a few seconds
	Panel.ShowText(Text, class'CoopUnitFlag'.static.OwnerColor(Slot), Slot != class'CoopRole'.static.LocalSlot());
	`log("turn banner shown: overlay visible=" $ Overlay.bIsVisible @ "stack=" $ Pres.ScreenStack.IsInStack(class'UITurnOverlay') @ "panel=" $ Panel.bIsVisible @ "stays=" $ (Slot != class'CoopRole'.static.LocalSlot()),, 'CoopBanner');
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local int Slot;

	if (Command != "CoopTurnOf")
	{
		return;
	}
	Slot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	if (!class'CoopSession'.static.InTactical())
	{
		return;
	}
	if (Slot != class'CoopRole'.static.LocalSlot())
	{
		Show(Slot);
	}
	if (!class'CoopRole'.static.IsGuest() && class'CoopRole'.default.ConnectedSlots.Length > 1)
	{
		Send(Slot);    // forward a guest's turn to the other guests (the sender ignores its own slot)
	}
}

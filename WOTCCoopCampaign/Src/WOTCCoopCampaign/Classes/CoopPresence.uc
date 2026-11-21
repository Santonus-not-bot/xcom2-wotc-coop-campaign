//---------------------------------------------------------------------------------------
//  FILE:    CoopPresence.uc
//  PURPOSE: In a mission, what the player whose turn it is does, live on the other machines. The game state only
//           reaches them when the turn is handed over (the history goes with the handoff), so a watcher used to
//           see nothing at all during another player's turn (two PCs 2026-11-18).
//           The machine playing the turn sends, every 0.25 s while something changed and every 2 s anyway,
//           "CoopPresence"(slot, selected unit, cursor x/y/z, what the player does, target): the soldier
//           selected, the tile under the cursor (on the player's own turn the 3D cursor follows the mouse), and
//           whether they plan a move (a path is shown), aim an ability (targeting) or look around. It also sends
//           a line for each ability its units use ("CoopFeed"), from the game's 'AbilityActivated' event.
//           The host passes both on to the other guests. CoopHUDScreen draws them on the watching machines.
//           A plain Object; the state lives in class defaults.
//---------------------------------------------------------------------------------------
class CoopPresence extends Object config(CoopCampaign);

const DO_LOOK = 0;
const DO_MOVE = 1;
const DO_AIM = 2;
const STALE_SECONDS = 4;
const RESEND_SECONDS = 2;

var config bool bInited;
// sent (this machine)
var config string LastSent;
var config int LastSentAt;
// received: one player at a time plays a turn
var config int Slot;         // -1 = nobody
var config int PresUnit;
var config vector PresCursor;
var config int Doing;
var config int TargetID;
var config int At;           // clock seconds of the last presence received
var config array<string> Feed;   // lines waiting to be shown (CoopHUDScreen takes them)

static function Init()
{
	local CoopPresence Listener;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	default.Slot = -1;
	Listener = new class'CoopPresence';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Listener.OnRemoteCommand);
}

static function bool MyTurn()
{
	local CoopTacticalRuleset Rules;

	Rules = CoopTacticalRuleset(`TACTICALRULES);
	return Rules != none && Rules.LocalPlaysXComTurn();
}

// CoopHUDScreen's timer in a mission, 4 times a second.
static function Tick()
{
	local XComTacticalController PC;
	local XComPresentationLayer Pres;
	local X2TargetingMethod Targeting;
	local int Unit, What, Target, Now;
	local vector Loc;
	local TTile Tile;
	local string Encoded;

	if (!class'CoopSession'.static.IsConnected() || !class'CoopSession'.static.InTactical())
	{
		return;
	}
	Init();
	if (!MyTurn())
	{
		return;
	}
	PC = XComTacticalController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController());
	if (PC == none)
	{
		return;
	}
	Unit = PC.GetActiveUnitStateRef().ObjectID;
	if (PC.GetCursor() != none)
	{
		Tile = `XWORLD.GetTileCoordinatesFromPosition(PC.GetCursor().Location);
		Loc = `XWORLD.GetPositionFromTileCoordinates(Tile);
	}
	What = DO_LOOK;
	Pres = XComPresentationLayer(PC.Pres);
	Targeting = (Pres != none && Pres.GetTacticalHUD() != none) ? Pres.GetTacticalHUD().GetTargetingMethod() : none;
	if (Targeting != none)
	{
		What = DO_AIM;
		Target = Targeting.GetTargetedObjectID();
	}
	else if (PC.m_kPathingPawn != none && PC.m_kPathingPawn.PathTiles.Length > 1)
	{
		What = DO_MOVE;
	}
	Encoded = Unit $ "," $ int(Loc.X) $ "," $ int(Loc.Y) $ "," $ int(Loc.Z) $ "," $ What $ "," $ Target;
	Now = class'CoopMissionLoading'.static.ClockSeconds();
	if (Encoded == default.LastSent && Now - default.LastSentAt < RESEND_SECONDS && Now >= default.LastSentAt)
	{
		return;
	}
	if (Encoded != default.LastSent)
	{
		`log("presence sent:" @ DoingText(What) @ "unit" @ Unit @ "tile" @ Tile.X $ "," $ Tile.Y $ "," $ Tile.Z @ "target" @ Target,, 'CoopPresence');
	}
	default.LastSent = Encoded;
	default.LastSentAt = Now;
	Send(class'CoopRole'.static.LocalSlot(), Encoded);
}

static function Send(int FromSlot, string Encoded)
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(FromSlot, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(Encoded, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopPresence", Params);
}

static function SendFeed(int FromSlot, string Text)
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(FromSlot, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(Text, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopFeed", Params);
}

static function string DoingText(int What)
{
	switch (What)
	{
	case DO_MOVE: return "planning a move";
	case DO_AIM:  return "aiming";
	}
	return "looking around";
}

// The presence of the player whose turn it is, or false when there is none (or it is stale).
static function bool Current(out int OutSlot)
{
	local int Age;

	if (default.Slot < 0)
	{
		return false;
	}
	Age = class'CoopMissionLoading'.static.ClockSeconds() - default.At;
	if (Age < 0 || Age > STALE_SECONDS || MyTurn())
	{
		return false;
	}
	OutSlot = default.Slot;
	return true;
}

static function string UnitName(int ObjectID)
{
	local XComGameState_Unit Unit;

	Unit = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(ObjectID));
	if (Unit == none)
	{
		return "";
	}
	return Unit.IsSoldier() ? Unit.GetName(eNameType_RankFull) : Unit.GetName(eNameType_Full);
}

// "Player 2 is aiming at ADVENT Trooper with Sgt. Jane Kelly"
static function string Line()
{
	local string S, UnitText, TargetText;
	local int PlayerSlot;

	if (!Current(PlayerSlot))
	{
		return "";
	}
	UnitText = UnitName(default.PresUnit);
	TargetText = default.TargetID > 0 ? UnitName(default.TargetID) : "";
	S = class'CoopRoster'.static.DisplayName(PlayerSlot) @ "is" @ DoingText(default.Doing);
	if (default.Doing == DO_AIM && TargetText != "")
	{
		S @= "at" @ TargetText;
	}
	if (UnitText != "")
	{
		S @= (default.Doing == DO_LOOK ? "-" : "with") @ UnitText;
	}
	return S;
}

// The machine that plays the turn: one of its units used an ability (event 'AbilityActivated', registered by
// CoopHUDScreen on a mission map: the screen lives as long as the map).
static function AbilityUsed(Object EventData, Object EventSource, XComGameState GameState)
{
	local XComGameState_Ability Ability;
	local XComGameState_Unit Unit;
	local XComGameStateContext_Ability Context;
	local X2AbilityTemplate Template;
	local string Text, Target;

	if (!class'CoopSession'.static.IsConnected() || !MyTurn())
	{
		return;
	}
	Ability = XComGameState_Ability(EventData);
	Unit = XComGameState_Unit(EventSource);
	Context = XComGameStateContext_Ability(GameState.GetContext());
	if (Ability == none || Unit == none || Unit.GetTeam() != eTeam_XCom)
	{
		return;
	}
	Template = Ability.GetMyTemplate();
	if (Template == none || Template.LocFriendlyName == "")
	{
		return;
	}
	if (Context != none && Context.InputContext.PrimaryTarget.ObjectID > 0 && Context.InputContext.PrimaryTarget.ObjectID != Unit.ObjectID)
	{
		Target = UnitName(Context.InputContext.PrimaryTarget.ObjectID);
	}
	Text = Unit.GetName(eNameType_RankFull) @ "-" @ Template.LocFriendlyName $ (Target != "" ? " on " $ Target : "");
	`log("feed sent:" @ Text,, 'CoopPresence');
	SendFeed(class'CoopRole'.static.LocalSlot(), Text);
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local array<string> Parts;
	local int FromSlot;
	local string Encoded;

	if (Command == "CoopPresence")
	{
		FromSlot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		Encoded = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
		if (FromSlot == class'CoopRole'.static.LocalSlot())
		{
			return;
		}
		ParseStringIntoArray(Encoded, Parts, ",", false);
		if (Parts.Length >= 6)
		{
			if (default.Slot != FromSlot || int(Parts[4]) != default.Doing || int(Parts[0]) != default.PresUnit || int(Parts[5]) != default.TargetID)
			{
				`log("presence of player" @ FromSlot $ ":" @ DoingText(int(Parts[4])) @ "unit" @ Parts[0] @ "target" @ Parts[5],, 'CoopPresence');
			}
			default.Slot = FromSlot;
			default.PresUnit = int(Parts[0]);
			default.PresCursor.X = float(Parts[1]);
			default.PresCursor.Y = float(Parts[2]);
			default.PresCursor.Z = float(Parts[3]);
			default.Doing = int(Parts[4]);
			default.TargetID = int(Parts[5]);
			default.At = class'CoopMissionLoading'.static.ClockSeconds();
		}
		if (!class'CoopRole'.static.IsGuest() && class'CoopRole'.default.ConnectedSlots.Length > 1)
		{
			Send(FromSlot, Encoded);
		}
		return;
	}
	if (Command == "CoopFeed")
	{
		FromSlot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		Encoded = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
		if (FromSlot == class'CoopRole'.static.LocalSlot())
		{
			return;
		}
		`log("feed from player" @ FromSlot $ ":" @ Encoded,, 'CoopPresence');
		default.Feed.AddItem(class'CoopRoster'.static.DisplayName(FromSlot) $ ": " $ Encoded);
		if (!class'CoopRole'.static.IsGuest() && class'CoopRole'.default.ConnectedSlots.Length > 1)
		{
			SendFeed(FromSlot, Encoded);
		}
	}
}

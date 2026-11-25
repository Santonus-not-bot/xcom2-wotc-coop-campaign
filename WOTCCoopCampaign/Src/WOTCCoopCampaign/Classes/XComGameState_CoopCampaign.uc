//---------------------------------------------------------------------------------------
//  FILE:    XComGameState_CoopCampaign.uc
//  PURPOSE: Campaign-wide co-op data, saved in the history like every other state object:
//           the player slots (0 = host, 1-3 = guests) and which squad slot belongs to which
//           player. The host makes every campaign decision, including these assignments.
//           Slots, not network ids, own soldiers, so a campaign can go on with other friends.
//           Created only by the host (new objects on two machines would share an ObjectID).
//---------------------------------------------------------------------------------------
class XComGameState_CoopCampaign extends XComGameState_BaseObject;

const SLOT_HOST = 0;
const SLOT_GUEST = 1;      // the first guest
const MAX_PLAYERS = 4;

var array<string> SlotNames;        // last known player name per slot (display only)
var int PlayerCount;                // players in this campaign, 1..MAX_PLAYERS
var array<int> SquadSlotOwner;      // per squad slot index: player slot (set by the host per mission)
var bool bBalanced;                 // balanced co-op campaign (CoopBalanced), chosen at the start
var bool bScenario;                 // a scenario mode mission, not a campaign (CoopScenario)
var int ScenarioStage;              // its game stage (CoopScenario.STAGE_*)

static function XComGameState_CoopCampaign Get(optional bool bAllowNone = true)
{
	return XComGameState_CoopCampaign(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_CoopCampaign', bAllowNone));
}

// The object in NewGameState, created there if the campaign has none yet.
static function XComGameState_CoopCampaign GetForChange(XComGameState NewGameState)
{
	local XComGameState_CoopCampaign Coop;

	Coop = Get();
	if (Coop == none)
	{
		Coop = XComGameState_CoopCampaign(NewGameState.CreateNewStateObject(class'XComGameState_CoopCampaign'));
		Coop.PlayerCount = 2;
		Coop.SlotNames.AddItem("Host");
		Coop.SlotNames.AddItem("Guest 1");
		Coop.SlotNames.AddItem("Guest 2");
		Coop.SlotNames.AddItem("Guest 3");
	}
	else
	{
		Coop = XComGameState_CoopCampaign(NewGameState.ModifyStateObject(class'XComGameState_CoopCampaign', Coop.ObjectID));
	}
	return Coop;
}

static function bool IsValidPlayer(int Slot)
{
	return Slot >= 0 && Slot < MAX_PLAYERS;
}

// Default split for a squad of Size among PlayerCount players: consecutive blocks, the
// earlier players get the extra slot (6 for 2 players: 0 0 0 1 1 1; 6 for 4: 0 0 1 1 2 3).
function SetDefaultSquadSplit(int Size)
{
	local int i, Players, Base, Extra, Player, Given;

	Players = Clamp(PlayerCount, 1, MAX_PLAYERS);
	Base = Size / Players;
	Extra = Size % Players;
	SquadSlotOwner.Length = Size;
	Player = 0;
	Given = 0;
	for (i = 0; i < Size; i++)
	{
		if (Given >= Base + ((Player < Extra) ? 1 : 0) && Player < Players - 1)
		{
			Player++;
			Given = 0;
		}
		SquadSlotOwner[i] = Player;
		Given++;
	}
}

function SetSquadSlotOwner(int SquadIndex, int Slot)
{
	if (SquadIndex < 0 || !IsValidPlayer(Slot))
	{
		return;
	}
	if (SquadSlotOwner.Length <= SquadIndex)
	{
		SquadSlotOwner.Length = SquadIndex + 1;
	}
	SquadSlotOwner[SquadIndex] = Slot;
}

// Owner of a squad slot; slots beyond the stored list belong to the host.
function int OwnerOfSquadSlot(int SquadIndex)
{
	if (SquadIndex >= 0 && SquadIndex < SquadSlotOwner.Length)
	{
		return SquadSlotOwner[SquadIndex];
	}
	return SLOT_HOST;
}

function string Describe()
{
	local string Out;
	local int i;

	for (i = 0; i < SquadSlotOwner.Length; i++)
	{
		Out $= string(SquadSlotOwner[i]);
	}
	return "coop id=" $ ObjectID @ "players=" $ PlayerCount @ "balanced=" $ bBalanced @ "squadOwners=" $ Out;
}

// Not bSingletonStateType: that flag needs native SingletonCopyForHistoryDiffDuplicate support for saves.
// There is still only ever one: Get() looks it up, GetForChange() creates it once.

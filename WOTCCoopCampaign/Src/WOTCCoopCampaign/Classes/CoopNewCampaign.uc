//---------------------------------------------------------------------------------------
//  FILE:    CoopNewCampaign.uc
//  PURPOSE: A new campaign started from the main menu's "Co-op Campaign" submenu.
//             Choose: remembers the choice (regular or balanced) for the campaign the game creates next.
//             OnNewCampaign (X2DownloadableContentInfo.InstallNewCampaign): puts the co-op data into the new
//               campaign's start state, balanced or not (the only time balanced can be chosen).
//             OnAvenger (the Avenger HUD): the first time this campaign reaches the Avenger in this session, it
//               opens the co-op server as the "Host co-op" button does. (A new campaign starts with its first
//               mission, which the host plays before guests can join.)
//           Runtime state in class defaults (they survive map changes, not a restart).
//---------------------------------------------------------------------------------------
class CoopNewCampaign extends Object config(CoopCampaign);

const MODE_NONE = 0;
const MODE_REGULAR = 1;
const MODE_BALANCED = 2;

var config int PendingMode;        // chosen in the submenu, not yet given to a campaign
var config int HostPendingMode;    // the campaign was created as co-op: host it on the Avenger

static function Choose(bool bBalanced)
{
	default.PendingMode = bBalanced ? MODE_BALANCED : MODE_REGULAR;
	`log("new co-op campaign chosen: balanced=" $ class'CoopHarness'.static.BoolStr(bBalanced),, 'CoopMenu');
}

// The main menu without a choice (another menu path, or back out): forget it.
static function Forget()
{
	default.PendingMode = MODE_NONE;
}

static function OnNewCampaign(XComGameState StartState)
{
	local XComGameState_CoopCampaign Coop;

	if (default.PendingMode == MODE_NONE)
	{
		return;
	}
	Coop = XComGameState_CoopCampaign(StartState.CreateNewStateObject(class'XComGameState_CoopCampaign'));
	Coop.PlayerCount = 2;
	Coop.SlotNames.AddItem("Host");
	Coop.SlotNames.AddItem("Guest 1");
	Coop.SlotNames.AddItem("Guest 2");
	Coop.SlotNames.AddItem("Guest 3");
	Coop.bBalanced = (default.PendingMode == MODE_BALANCED);
	default.HostPendingMode = default.PendingMode;
	// from the lobby with friends in it: they play from the first mission on (the server reopens at its first unit
	// actions and they rejoin in their lobby slots), and the campaign has as many players as the lobby
	if (class'CoopLobby'.static.IsHostingLobby() && class'CoopRole'.default.ConnectedSlots.Length > 0)
	{
		Coop.PlayerCount = Max(2, class'CoopLobby'.static.PlayerCount());
		class'CoopLobby'.static.HostLeaveForGame("the campaign's first mission");
	}
	default.PendingMode = MODE_NONE;
	`log("new campaign created as co-op: balanced=" $ class'CoopHarness'.static.BoolStr(Coop.bBalanced),, 'CoopMenu');
}

// True when the Avenger should open the co-op server now (once).
static function bool TakeHostOnAvenger()
{
	if (default.HostPendingMode == MODE_NONE)
	{
		return false;
	}
	if (class'CoopLink'.default.bReturnPending || class'CoopLink'.default.bReopenAfterReturn || `XCOMNETMANAGER.HasServerConnection())
	{
		default.HostPendingMode = MODE_NONE;    // back from the first mission with friends: the return reopens the server
		return false;
	}
	class'CoopLink'.default.bReopenPending = false;    // the campaign started on the Avenger: no mission build to reopen after
	default.HostPendingMode = MODE_NONE;
	return true;
}

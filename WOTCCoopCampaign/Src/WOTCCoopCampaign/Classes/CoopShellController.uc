//---------------------------------------------------------------------------------------
//  FILE:    CoopShellController.uc
//  PURPOSE: Replaces XComShellController (ModClassOverrides), the main menu's controller. A guest waiting on the main
//           menu (in a lobby, or reconnecting after the host left the Avenger) whose connection to the host closes
//           ran the game's multiplayer lost-connection handling (NotifyConnectionError -> OnDestroyedOnlineGame ->
//           ReturnToMPMainMenu), which reloads the main menu map, and the guest crashed during that load
//           (XCom2.exe+0x4ce235; lobbyload 2026-11-25, the host quit while its friend sat in the lobby). CoopLink
//           already handles the loss (it reconnects or gives up), so for a co-op guest this skips the game's handling,
//           as CoopHeadquartersController does on the Avenger.
//---------------------------------------------------------------------------------------
class CoopShellController extends XComShellController;

function NotifyConnectionError(EProgressMessageType MessageType, optional string Message, optional string Title)
{
	if (class'CoopLink'.static.GuestLostHostOnMenu())
	{
		`log("co-op: skipped the game's lost-connection handling on the main menu, type=" $ MessageType,, 'CoopLink');
		// as the game's handler does: the engine repeats the error every frame until the dead connection is gone
		bIgnoreNetworkMessages = true;
		// The game's handler reloaded the map, which dropped the dead connection; skipping it left the failed
		// attempt's net driver up, HasClientConnection() stayed true and CoopLink never tried again (soakfresh16
		// 2026-11-25, second run: a reconnect attempt on the main menu timed out and the guest sat there for good).
		// CoopLink drops it on its next tick, then this controller hears network messages again.
		class'CoopLink'.default.bTearDownPending = true;
		class'CoopLinkTimer'.static.Ensure();
		return;
	}
	super.NotifyConnectionError(MessageType, Message, Title);
}

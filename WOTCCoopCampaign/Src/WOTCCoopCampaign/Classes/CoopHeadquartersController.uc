//---------------------------------------------------------------------------------------
//  FILE:    CoopHeadquartersController.uc
//  PURPOSE: Replaces XComHeadquartersController (ModClassOverrides). When the host closes the
//           connection (to build a mission, or to load a save), the game's lost-connection handling
//           (NotifyConnectionError -> OnDestroyedOnlineGame -> ReturnToMPMainMenu) unloads the Avenger
//           in the same frame. A sound an Avenger matinee posted just before that calls back on Wwise's
//           thread after the world is gone, and the game's handler for it reads the null world:
//           access violation at XCom2.exe+0x6d0695, no crash record (6 minidumps, 7 of 269 guest departures
//           from the Avenger in the runlogs of 2026-11-12/13). On a co-op guest this skips that handling;
//           CoopLink pauses the world, waits QuietLeaveSeconds and then calls the same ReturnToMPMainMenu.
//---------------------------------------------------------------------------------------
class CoopHeadquartersController extends XComHeadquartersController;

function NotifyConnectionError(EProgressMessageType MessageType, optional string Message, optional string Title)
{
	if (class'CoopLink'.static.GuestLostHostOnAvenger())
	{
		`log("co-op: skipped the game's lost-connection handling on the Avenger, type=" $ MessageType $ "; leaving quietly",, 'CoopLink');
		// as the game's handler does: the engine repeats the error every frame until the dead connection is gone
		bIgnoreNetworkMessages = true;
		return;
	}
	super.NotifyConnectionError(MessageType, Message, Title);
}

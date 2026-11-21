//---------------------------------------------------------------------------------------
//  FILE:    CoopSyncData.uc
//  PURPOSE: What the game and CoopSync (tools/coopsync, run outside the game) exchange so that a guest
//           refused for different mods can get the host's mods.
//           A mod cannot read Workshop ids inside the game (no such call in the SDK), so:
//           1. the host's CoopSync writes the host's active mods with their Workshop ids and version
//              fingerprints into the user config file XComCoopSync.ini ("coopsync host-export");
//           2. when the host refuses a guest for different mods, it sends that list (CoopSyncBegin,
//              CoopSyncChunk..., CoopSyncEnd) before "CoopJoinRefused";
//           3. the guest saves it as ReceivedMods in its own XComCoopSync.ini, and its CoopSync
//              ("coopsync sync") subscribes to what is missing and switches the active mods to the host's.
//           Without step 1 the list carries names only; CoopSync can then still match mods the guest has.
//---------------------------------------------------------------------------------------
class CoopSyncData extends Object config(CoopSync);

struct CoopSyncMod
{
	var string ModName;
	var string WorkshopId;
	var string Version;
};

var config array<CoopSyncMod> HostMods;        // host: written by CoopSync before the game starts
var config array<CoopSyncMod> ReceivedMods;    // guest: the host's list from the last refused join
var config string ReceivedHost;                // guest: the host's address then
var config int ReceivedExpected;               // guest: the count announced in CoopSyncBegin (runtime)
var config array<CoopSyncMod> Pending;         // guest: entries received so far (runtime; empty when saved)

var int ChunkSize;    // entries per remote command (a command's size limit is unknown; CoopModCheck sends 8 names)

// Host: the list to send. CoopSync's list when there is one, else the installed mod names without ids.
static function array<CoopSyncMod> ListToSend()
{
	local array<CoopSyncMod> Mods;
	local CoopSyncMod Entry;
	local array<string> Names;
	local string ModName;

	if (default.HostMods.Length > 0)
	{
		return default.HostMods;
	}
	Names = class'CoopModCheck'.static.LocalMods();
	foreach Names(ModName)
	{
		Entry.ModName = ModName;
		Entry.WorkshopId = "";
		Entry.Version = "";
		Mods.AddItem(Entry);
	}
	return Mods;
}

static function SendHostList()
{
	local XComGameStateNetworkManager NetMgr;
	local array<CoopSyncMod> Mods;
	local array<byte> Params;
	local string Chunk;
	local int i, WithIds;

	NetMgr = `XCOMNETMANAGER;
	Mods = ListToSend();
	for (i = 0; i < Mods.Length; i++)
	{
		if (Mods[i].WorkshopId != "")
		{
			WithIds++;
		}
	}
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Mods.Length, Params);
	NetMgr.SendRemoteCommand("CoopSyncBegin", Params);
	for (i = 0; i < Mods.Length; i++)
	{
		Chunk $= ((Chunk == "") ? "" : "|") $ Mods[i].ModName $ ";" $ Mods[i].WorkshopId $ ";" $ Mods[i].Version;
		if (((i + 1) % default.ChunkSize) == 0 || i == Mods.Length - 1)
		{
			Params.Length = 0;
			class'XComGameStateNetworkManager'.static.AddCommandParam_String(Chunk, Params);
			NetMgr.SendRemoteCommand("CoopSyncChunk", Params);
			Chunk = "";
		}
	}
	Params.Length = 0;
	NetMgr.SendRemoteCommand("CoopSyncEnd", Params);
	`log("coopsync: sent the host's mod list:" @ Mods.Length @ "mods," @ WithIds @ "with Workshop ids"
		@ (default.HostMods.Length > 0 ? "(from CoopSync)" : "(names only: the host has not run coopsync host-export)"),, 'CoopSync');
}

// Guest (CoopModCheck forwards the commands).
static function OnCommand(string Command, array<byte> RawParams)
{
	local array<string> Entries, Fields;
	local string Entry;
	local CoopSyncMod NewMod;
	local int i, WithIds;

	if (Command == "CoopSyncBegin")
	{
		default.Pending.Length = 0;
		default.ReceivedExpected = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	}
	else if (Command == "CoopSyncChunk")
	{
		ParseStringIntoArray(class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams), Entries, "|", true);
		foreach Entries(Entry)
		{
			ParseStringIntoArray(Entry, Fields, ";", false);
			NewMod.ModName = Fields.Length > 0 ? Fields[0] : "";
			NewMod.WorkshopId = Fields.Length > 1 ? Fields[1] : "";
			NewMod.Version = Fields.Length > 2 ? Fields[2] : "";
			if (NewMod.ModName != "")
			{
				default.Pending.AddItem(NewMod);
			}
		}
	}
	else if (Command == "CoopSyncEnd")
	{
		default.ReceivedMods = default.Pending;
		default.Pending.Length = 0;
		default.ReceivedHost = class'CoopLink'.default.GuestHost;
		for (i = 0; i < default.ReceivedMods.Length; i++)
		{
			if (default.ReceivedMods[i].WorkshopId != "")
			{
				WithIds++;
			}
		}
		StaticSaveConfig();
		`log("coopsync: saved the host's mod list:" @ default.ReceivedMods.Length @ "of" @ default.ReceivedExpected @ "mods,"
			@ WithIds @ "with Workshop ids, in XComCoopSync.ini",, 'CoopSync');
	}
}

static function bool IsSyncCommand(string Command)
{
	return Command == "CoopSyncBegin" || Command == "CoopSyncChunk" || Command == "CoopSyncEnd";
}

// At start: how many entries CoopSync left for this game (host side), for the log.
static function LogState()
{
	`log("coopsync: host list from CoopSync=" $ default.HostMods.Length @ "received list=" $ default.ReceivedMods.Length,, 'CoopSync');
}

defaultproperties
{
	ChunkSize = 4
}

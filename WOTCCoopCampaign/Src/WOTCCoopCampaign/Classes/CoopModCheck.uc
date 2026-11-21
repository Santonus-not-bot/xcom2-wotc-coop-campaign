//---------------------------------------------------------------------------------------
//  FILE:    CoopModCheck.uc
//  PURPOSE: Join-time checks that both players run the same content.
//           1. Mod list: one side sends its installed mod names (in chunks: remote command
//              size limits are unknown) plus the engine's mod and MP-ini hashes; the other
//              compares and answers. Meant to run BEFORE the host sends the history: a history
//              that holds objects of a class from a mod the guest lacks may not load.
//           2. Content audit: every soldier's appearance parts and voice must resolve to a body
//              part template on this machine; otherwise they show as defaults or stay silent.
//           A plain Object (not an Actor): the network manager outlives maps.
//---------------------------------------------------------------------------------------
class CoopModCheck extends Object config(CoopHarness);

var int ChunkSize;  // mod names per remote command (defaultproperties)

var config bool bInited;
// result of the last comparison (config only so the default may be written)
var config bool bHaveResult;
var config bool bMatch;
var config bool bPeerMatch;          // the partner's answer about OUR list
var config bool bHavePeerAnswer;
var config string LastDiff;
var config string PeerDiff;           // the partner's difference report about our list

// list being received
var array<string> Incoming;
var int IncomingExpected;
var int IncomingModsHash;
var string IncomingIniHash;

static function Init()
{
	local CoopModCheck Check;

	if (default.bInited)
	{
		return;
	}
	Check = new class'CoopModCheck';
	default.bInited = true;
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Check.OnRemoteCommand);
	class'CoopSyncData'.static.LogState();
}

static function array<string> LocalMods()
{
	local array<string> Mods, Sorted;
	local string ModName;
	local int i;

	Mods = class'Helpers'.static.GetInstalledModNames();
	// insertion sort, case-insensitive (no Sort() delegate: a static compare function as Sort's
	// delegate is suspected of the access violation seen in the first test run)
	foreach Mods(ModName)
	{
		for (i = 0; i < Sorted.Length && Locs(Sorted[i]) < Locs(ModName); i++)
		{
		}
		Sorted.InsertItem(i, ModName);
	}
	return Sorted;
}

static function LogLocal()
{
	local array<string> Mods;
	local string Line, ModName;
	local int ModsHash;
	local string IniHash;

	`log("mods: names...",, 'CoopModCheck');
	Mods = LocalMods();
	foreach Mods(ModName)
	{
		Line @= ModName;
	}
	`log("mods: names ok count=" $ Mods.Length @ "names=" $ Line,, 'CoopModCheck');
	ModsHash = class'Helpers'.static.NetGetInstalledModsHash();
	`log("mods: modsHash=" $ ModsHash,, 'CoopModCheck');
	IniHash = class'Helpers'.static.NetGetMPINIHash();
	`log("mods: mpIniHash=" $ IniHash,, 'CoopModCheck');
	// not Helpers.GetInstalledDLCNames(): it crashed the game in strategy (access violation, test run 2026-11-12)
	`log("mods count=" $ Mods.Length @ "modsHash=" $ ModsHash @ "mpIniHash=" $ IniHash,, 'CoopModCheck');
}

// The list both ends compare: the active mods and this mod's build. Two builds of this mod do not work together
// (two PCs 2026-11-18: a guest on the previous package passed the check, then drew a new message wrong), so a
// different build is refused like a different mod ("-WOTCCoopCampaign build X +WOTCCoopCampaign build Y").
static function array<string> CheckedList()
{
	local array<string> Mods;

	Mods = LocalMods();
	Mods.AddItem("WOTCCoopCampaign build " $ class'CoopBuildInfo'.const.BUILD_ID);
	return Mods;
}

// Send our list: CoopModsBegin(count, modsHash, iniHash), CoopModsChunk(names joined by '|')..., CoopModsEnd.
static function SendList()
{
	local XComGameStateNetworkManager NetMgr;
	local array<string> Mods;
	local array<byte> Params;
	local string Chunk;
	local int i;

	NetMgr = `XCOMNETMANAGER;
	Mods = CheckedList();
	default.bHavePeerAnswer = false;
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Mods.Length, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(class'Helpers'.static.NetGetInstalledModsHash(), Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(class'Helpers'.static.NetGetMPINIHash(), Params);
	NetMgr.SendRemoteCommand("CoopModsBegin", Params);
	for (i = 0; i < Mods.Length; i++)
	{
		Chunk $= ((Chunk == "") ? "" : "|") $ Mods[i];
		if (((i + 1) % default.ChunkSize) == 0 || i == Mods.Length - 1)
		{
			Params.Length = 0;
			class'XComGameStateNetworkManager'.static.AddCommandParam_String(Chunk, Params);
			NetMgr.SendRemoteCommand("CoopModsChunk", Params);
			Chunk = "";
		}
	}
	Params.Length = 0;
	NetMgr.SendRemoteCommand("CoopModsEnd", Params);
	`log("sent mods=" $ Mods.Length,, 'CoopModCheck');
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local array<string> Parts;
	local string Part;

	if (class'CoopSyncData'.static.IsSyncCommand(Command))
	{
		if (class'CoopRole'.static.IsGuest())
		{
			class'CoopSyncData'.static.OnCommand(Command, RawParams);
		}
		return;
	}
	if (Command == "CoopModsBegin")
	{
		Incoming.Length = 0;
		IncomingExpected = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		IncomingModsHash = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		IncomingIniHash = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
	}
	else if (Command == "CoopModsChunk")
	{
		ParseStringIntoArray(class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams), Parts, "|", true);
		foreach Parts(Part)
		{
			Incoming.AddItem(Part);
		}
	}
	else if (Command == "CoopModsEnd")
	{
		Compare();
	}
	else if (Command == "CoopModsResult")
	{
		// The engine hands every remote-command listener the same parameter buffer and each read
		// consumes it, so this is the only listener that reads these parameters (a second reader
		// crashed the host in the first two-copy run); the join flow gets the values from here.
		default.bHavePeerAnswer = true;
		default.bPeerMatch = class'XComGameStateNetworkManager'.static.GetCommandParam_Bool(RawParams);
		default.PeerDiff = class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams);
		`log("peer says lists match=" $ class'CoopHarness'.static.BoolStr(default.bPeerMatch),, 'CoopModCheck');
		class'CoopJoin'.static.OnModsResult(default.bPeerMatch, default.PeerDiff);
	}
}

function Compare()
{
	local array<string> Mine, Missing, Extra;
	local string ModName, Diff;
	local array<byte> Params;
	local int i;

	Mine = CheckedList();
	foreach Incoming(ModName)
	{
		if (FindName(Mine, ModName) == INDEX_NONE)
		{
			Missing.AddItem(ModName);
		}
	}
	foreach Mine(ModName)
	{
		if (FindName(Incoming, ModName) == INDEX_NONE)
		{
			Extra.AddItem(ModName);
		}
	}
	for (i = 0; i < Missing.Length; i++)
	{
		Diff @= "-" $ Missing[i];            // the partner has it, we do not
	}
	for (i = 0; i < Extra.Length; i++)
	{
		Diff @= "+" $ Extra[i];              // we have it, the partner does not
	}
	default.bHaveResult = true;
	default.bMatch = Incoming.Length == IncomingExpected && Missing.Length == 0 && Extra.Length == 0;
	default.LastDiff = Diff;
	`log("compare received=" $ Incoming.Length $ "/" $ IncomingExpected @ "match=" $ class'CoopHarness'.static.BoolStr(default.bMatch)
		@ "modsHash peer=" $ IncomingModsHash @ "mine=" $ class'Helpers'.static.NetGetInstalledModsHash()
		@ "iniHash equal=" $ class'CoopHarness'.static.BoolStr(IncomingIniHash == class'Helpers'.static.NetGetMPINIHash())
		@ "diff=" $ Diff,, 'CoopModCheck');
	class'XComGameStateNetworkManager'.static.AddCommandParam_Bool(default.bMatch, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(Diff, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopModsResult", Params);
}

static function int FindName(const out array<string> List, string ModName)
{
	local int i;

	for (i = 0; i < List.Length; i++)
	{
		if (List[i] ~= ModName)
		{
			return i;
		}
	}
	return INDEX_NONE;
}

//---------------------------------------------------------------------------------------
// Content audit: body parts and voices that do not resolve here

static function bool PartMissing(X2BodyPartTemplateManager PartMgr, string PartType, name PartName)
{
	return PartName != '' && PartMgr.FindUberTemplate(PartType, PartName) == none;
}

static function string MissingParts(const out TAppearance A)
{
	local X2BodyPartTemplateManager PartMgr;
	local string Out;

	PartMgr = class'X2BodyPartTemplateManager'.static.GetBodyPartTemplateManager();
	if (PartMissing(PartMgr, "Head", A.nmHead)) Out @= "Head:" $ A.nmHead;
	if (PartMissing(PartMgr, "Hair", A.nmHaircut)) Out @= "Hair:" $ A.nmHaircut;
	if (PartMissing(PartMgr, "Beards", A.nmBeard)) Out @= "Beards:" $ A.nmBeard;
	if (PartMissing(PartMgr, "Torso", A.nmTorso)) Out @= "Torso:" $ A.nmTorso;
	if (PartMissing(PartMgr, "Arms", A.nmArms)) Out @= "Arms:" $ A.nmArms;
	if (PartMissing(PartMgr, "Legs", A.nmLegs)) Out @= "Legs:" $ A.nmLegs;
	if (PartMissing(PartMgr, "Helmets", A.nmHelmet)) Out @= "Helmets:" $ A.nmHelmet;
	if (PartMissing(PartMgr, "Eyes", A.nmEye)) Out @= "Eyes:" $ A.nmEye;
	if (PartMissing(PartMgr, "Teeth", A.nmTeeth)) Out @= "Teeth:" $ A.nmTeeth;
	if (PartMissing(PartMgr, "FacePropsLower", A.nmFacePropLower)) Out @= "FacePropsLower:" $ A.nmFacePropLower;
	if (PartMissing(PartMgr, "FacePropsUpper", A.nmFacePropUpper)) Out @= "FacePropsUpper:" $ A.nmFacePropUpper;
	if (PartMissing(PartMgr, "Patterns", A.nmPatterns)) Out @= "Patterns:" $ A.nmPatterns;
	if (PartMissing(PartMgr, "Patterns", A.nmWeaponPattern)) Out @= "WeaponPattern:" $ A.nmWeaponPattern;
	if (PartMissing(PartMgr, "Tattoos", A.nmTattoo_LeftArm)) Out @= "TattooL:" $ A.nmTattoo_LeftArm;
	if (PartMissing(PartMgr, "Tattoos", A.nmTattoo_RightArm)) Out @= "TattooR:" $ A.nmTattoo_RightArm;
	if (PartMissing(PartMgr, "Scars", A.nmScars)) Out @= "Scars:" $ A.nmScars;
	if (PartMissing(PartMgr, "Facepaint", A.nmFacePaint)) Out @= "Facepaint:" $ A.nmFacePaint;
	if (PartMissing(PartMgr, "Voice", A.nmVoice)) Out @= "Voice:" $ A.nmVoice;
	if (PartMissing(PartMgr, "Pawn", A.nmPawn)) Out @= "Pawn:" $ A.nmPawn;
	if (PartMissing(PartMgr, "LeftArm", A.nmLeftArm)) Out @= "LeftArm:" $ A.nmLeftArm;
	if (PartMissing(PartMgr, "RightArm", A.nmRightArm)) Out @= "RightArm:" $ A.nmRightArm;
	if (PartMissing(PartMgr, "LeftArmDeco", A.nmLeftArmDeco)) Out @= "LeftArmDeco:" $ A.nmLeftArmDeco;
	if (PartMissing(PartMgr, "RightArmDeco", A.nmRightArmDeco)) Out @= "RightArmDeco:" $ A.nmRightArmDeco;
	if (PartMissing(PartMgr, "LeftForearm", A.nmLeftForearm)) Out @= "LeftForearm:" $ A.nmLeftForearm;
	if (PartMissing(PartMgr, "RightForearm", A.nmRightForearm)) Out @= "RightForearm:" $ A.nmRightForearm;
	if (PartMissing(PartMgr, "Thighs", A.nmThighs)) Out @= "Thighs:" $ A.nmThighs;
	if (PartMissing(PartMgr, "Shins", A.nmShins)) Out @= "Shins:" $ A.nmShins;
	if (PartMissing(PartMgr, "TorsoDeco", A.nmTorsoDeco)) Out @= "TorsoDeco:" $ A.nmTorsoDeco;
	if (PartMissing(PartMgr, "Torso", A.nmTorso_Underlay)) Out @= "TorsoUnderlay:" $ A.nmTorso_Underlay;
	if (PartMissing(PartMgr, "Arms", A.nmArms_Underlay)) Out @= "ArmsUnderlay:" $ A.nmArms_Underlay;
	if (PartMissing(PartMgr, "Legs", A.nmLegs_Underlay)) Out @= "LegsUnderlay:" $ A.nmLegs_Underlay;
	return Out;
}

// Logs one line per soldier with unresolved parts, then a summary. Returns the number of such soldiers.
static function int AuditContent()
{
	local XComGameState_Unit Unit;
	local string Missing;
	local int Units, Bad;

	foreach `XCOMHISTORY.IterateByClassType(class'XComGameState_Unit', Unit)
	{
		if (!Unit.IsSoldier())
		{
			continue;
		}
		Units++;
		Missing = MissingParts(Unit.kAppearance);
		if (Missing != "")
		{
			Bad++;
			`log("audit unit=" $ Unit.ObjectID @ "name=\"" $ Unit.GetFullName() $ "\" missing=" $ Missing,, 'CoopModCheck');
		}
	}
	`log("audit soldiers=" $ Units @ "withMissingParts=" $ Bad,, 'CoopModCheck');
	return Bad;
}

defaultproperties
{
	ChunkSize = 8
}

//---------------------------------------------------------------------------------------
//  FILE:    CoopChunks.uc
//  PURPOSE: Send a large byte array (an encoded history) as small remote commands, a few at a time.
//           A whole history sent at once by the engine never arrives above about 670 KB (soakstory16,
//           2026-11-18); a guest that has no history to take a delta against (a new player, a guest that
//           restarted its game) cannot join a long campaign. Idea: send the host's encoded history
//           (XComGameStateNetworkManager.BaseHistoryData) in chunks under that limit, rebuild it on the guest
//           and hand it to the engine with ReceiveHistory, as if it had arrived whole.
//
//           Protocol (host to every guest; guests connect only to the host):
//             "CoopChunkBegin"(id, total bytes, chunk count, hash, mode, chunk bytes)
//             "CoopChunk"(id, index) + raw bytes            at most ChunkWindow chunks ahead of the slowest ack
//             guest: "CoopChunkAck"(id, index, slot)        per chunk
//             guest, all chunks in: checks size and hash, then by mode:
//               MODE_COMPARE: compares with its own BaseHistoryData (experiment: is the format the same?)
//               MODE_FEED:    ReceiveHistory(0, bytes), then "CoopChunkDone"(id, slot, frames)
//             host, MODE_FEED: every guest done -> "CoopEnterAvenger" (the guest opens the Avenger from it)
//
//               MODE_BASE:    takes the bytes as its own BaseHistoryData (and the kept copy), then
//                             "CoopChunkDone"; host, every guest done -> CoopTacticalNet.ChunkedWholeDone: the usual
//                             partial history ("CoopNextIsWhole" + SendPartialHistory) brings them up to date
//
//           In play (bChunkedWholeSend, off by default): every whole history (a join, a mission, the campaign after a
//           mission) goes out as the host's base in chunks plus a delta (CoopTacticalNet.SendWhole), so its size has no
//           ceiling. A send that does not finish in ChunkTimeoutSeconds falls back to the engine's whole send.
//           Experiment steps: @chunkbase, @chunkfeed, @chunkprime, @chunkpause.
//           A plain Object; the state lives in class defaults.
//---------------------------------------------------------------------------------------
class CoopChunks extends Object config(CoopCampaign);

const MODE_COMPARE = 0;
const MODE_FEED = 1;
const MODE_BASE = 2;

var config int ChunkBytes;          // bytes per chunk; a remote command must fit in one bunch (16384 overflowed it:
                                    // "XCom channel bunch overflowed", the connection closed; chunktest 2026-11-24)
var config int ChunkWindow;         // chunks in flight ahead of the slowest guest's ack
var config bool bChunkedWholeSend;  // whole histories go out as the base in chunks plus a delta (CoopTacticalNet.SendWhole)
var config float ChunkTimeoutSeconds;    // host: a base send not done by then falls back to the engine's whole send

// runtime (config only so the default may be written)
var config bool bInited;
// host: the send in progress
var config array<byte> OutData;
var config int OutId, OutCount, OutNext, OutMode;
var config float OutStartedAt;
var config bool bOutActive;        // host: a send runs (MODE_BASE waits for every guest's CoopChunkDone)
var config array<int> OutSlots;     // guests the send waits for
var config array<int> OutAcked;     // by OutSlots index: chunks acknowledged
var config array<int> OutDone;      // by OutSlots index: 1 when the guest fed the history (MODE_FEED)
// guest: the receive in progress
var config array<byte> InData;
var config int InId, InCount, InGot, InHash, InMode, InChunkBytes;
var config array<int> InHave;       // by chunk index: 1 when received
var config float InStartedAt;

static function Init()
{
	local CoopChunks Listener;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	if (default.ChunkBytes <= 0)
	{
		default.ChunkBytes = 400;
	}
	if (default.ChunkWindow <= 0)
	{
		default.ChunkWindow = 32;
	}
	Listener = new class'CoopChunks';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Listener.OnRemoteCommand);
}

static function float Now()
{
	return class'WorldInfo'.static.GetWorldInfo().RealTimeSeconds;
}

// FNV-1a, 32 bit (wraps like the C++ it mirrors)
static function int Hash(array<byte> Data)
{
	local int H, i;

	H = -2128831035;    // 2166136261
	for (i = 0; i < Data.Length; i++)
	{
		H = H ^ Data[i];
		H = H * 16777619;
	}
	return H;
}

// ---------------------------------------------------------------- host

static function bool SendBytes(array<byte> Data, int Mode, string Why)
{
	local array<byte> Params;
	local int i;

	Init();
	if (class'CoopRole'.static.IsGuest())
	{
		`log("chunks: only the host sends",, 'CoopChunks');
		return false;
	}
	if (Data.Length == 0)
	{
		`log("chunks: nothing to send (" $ Why $ ")",, 'CoopChunks');
		return false;
	}
	default.OutData = Data;
	default.OutId++;
	default.bOutActive = true;
	default.OutMode = Mode;
	default.OutCount = (Data.Length + default.ChunkBytes - 1) / default.ChunkBytes;
	default.OutNext = 0;
	default.OutStartedAt = Now();
	default.OutSlots = class'CoopRole'.default.ConnectedSlots;
	default.OutAcked.Length = 0;
	default.OutDone.Length = 0;
	for (i = 0; i < default.OutSlots.Length; i++)
	{
		default.OutAcked.AddItem(0);
		default.OutDone.AddItem(0);
	}
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.OutId, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Data.Length, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.OutCount, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Hash(default.OutData), Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Mode, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.ChunkBytes, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopChunkBegin", Params);
	`log("chunks: send" @ default.OutId @ "(" $ Why $ ") bytes=" $ Data.Length @ "chunks=" $ default.OutCount
		@ "of" @ default.ChunkBytes @ "window=" $ default.ChunkWindow @ "hash=" $ Hash(default.OutData) @ "mode=" $ Mode
		@ "guests=" $ default.OutSlots.Length,, 'CoopChunks');
	Pump();
	return true;
}

static function int SlowestAck()
{
	local int i, Low;

	Low = default.OutCount;
	for (i = 0; i < default.OutAcked.Length; i++)
	{
		Low = Min(Low, default.OutAcked[i]);
	}
	return ((default.OutAcked.Length == 0) ? default.OutNext : Low);
}

static function Pump()
{
	local array<byte> Params;
	local int Start, End, i;

	while (default.OutNext < default.OutCount && default.OutNext - SlowestAck() < default.ChunkWindow)
	{
		Params.Length = 0;
		class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.OutId, Params);
		class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.OutNext, Params);
		Start = default.OutNext * default.ChunkBytes;
		End = Min(Start + default.ChunkBytes, default.OutData.Length);
		for (i = Start; i < End; i++)
		{
			Params.AddItem(default.OutData[i]);
		}
		`XCOMNETMANAGER.SendRemoteCommand("CoopChunk", Params);
		default.OutNext++;
	}
}

static function OnAck(int Id, int Index, int Slot)
{
	local int Idx;

	if (Id != default.OutId)
	{
		return;
	}
	Idx = default.OutSlots.Find(Slot);
	if (Idx == INDEX_NONE)
	{
		return;
	}
	default.OutAcked[Idx] = Max(default.OutAcked[Idx], Index + 1);
	if (SlowestAck() >= default.OutCount && default.OutNext >= default.OutCount && Index + 1 == default.OutCount)
	{
		`log("chunks: send" @ Id @ "acknowledged by every guest after" @ (Now() - default.OutStartedAt) @ "s",, 'CoopChunks');
	}
	Pump();
}

static function OnDone(int Id, int Slot, int Frames)
{
	local int Idx, i;

	if (Id != default.OutId)
	{
		return;
	}
	Idx = default.OutSlots.Find(Slot);
	if (Idx != INDEX_NONE)
	{
		default.OutDone[Idx] = 1;
	}
	if (default.OutMode == MODE_BASE)
	{
		`log("chunks: player" @ Slot @ "took send" @ Id @ "as its base:" @ Frames @ "bytes",, 'CoopChunks');
	}
	else
	{
		`log("chunks: player" @ Slot @ "fed send" @ Id @ "to its engine: frames=" $ Frames @ "(host has" @ `XCOMHISTORY.GetNumGameStates() $ ")",, 'CoopChunks');
	}
	for (i = 0; i < default.OutDone.Length; i++)
	{
		if (default.OutDone[i] == 0)
		{
			return;
		}
	}
	default.bOutActive = false;
	if (default.OutMode == MODE_FEED)
	{
		class'CoopTacticalNet'.static.Send("CoopEnterAvenger");
		`log("chunks: every guest has the history: telling them to enter the Avenger",, 'CoopChunks');
	}
	else if (default.OutMode == MODE_BASE)
	{
		`log("chunks: every guest has the base (send" @ Id $ ") after" @ (Now() - default.OutStartedAt) @ "s",, 'CoopChunks');
		class'CoopTacticalNet'.static.ChunkedWholeDone();
	}
}

// CoopLink.Tick, host: a base send that hangs (a guest left, a chunk lost) falls back to the engine's whole send.
static function Tick()
{
	if (!default.bOutActive || default.OutMode != MODE_BASE || class'CoopRole'.static.IsGuest())
	{
		return;
	}
	Pump();
	if (Now() - default.OutStartedAt > default.ChunkTimeoutSeconds || Now() < default.OutStartedAt)
	{
		default.bOutActive = false;
		`log("chunks: send" @ default.OutId @ "not done after" @ int(default.ChunkTimeoutSeconds) @ "s: whole send instead",, 'CoopChunks');
		class'CoopTacticalNet'.static.ChunkedWholeFailed();
	}
}

// Host: a guest that leaves is not waited for (its acks and its done never come).
static function OnGuestGone(int Slot)
{
	local int Idx, i;

	Idx = default.OutSlots.Find(Slot);
	if (!default.bOutActive || Idx == INDEX_NONE)
	{
		return;
	}
	default.OutSlots.Remove(Idx, 1);
	default.OutAcked.Remove(Idx, 1);
	default.OutDone.Remove(Idx, 1);
	`log("chunks: player" @ Slot @ "left during send" @ default.OutId $ "; not waiting for it",, 'CoopChunks');
	if (default.OutSlots.Length == 0)
	{
		default.bOutActive = false;
		return;
	}
	for (i = 0; i < default.OutDone.Length; i++)
	{
		if (default.OutDone[i] == 0)
		{
			Pump();
			return;
		}
	}
	OnDone(default.OutId, default.OutSlots[0], `XCOMHISTORY.GetNumGameStates());
}

// Experiment: does the engine send a history while game state sending is paused, and does BaseHistoryData change?
static function PauseProbe()
{
	local XComGameStateNetworkManager NetMgr;
	local int Before, After, HashBefore, HashAfter;

	NetMgr = `XCOMNETMANAGER;
	Before = NetMgr.BaseHistoryData.Length;
	HashBefore = Hash(NetMgr.BaseHistoryData);
	NetMgr.SetPauseGameStateSending(true);
	NetMgr.SendHistory(`XCOMHISTORY, `XEVENTMGR);
	After = NetMgr.BaseHistoryData.Length;
	HashAfter = Hash(NetMgr.BaseHistoryData);
	NetMgr.SetPauseGameStateSending(false);
	`log("chunks: pause probe: SendHistory with sending paused; base" @ Before @ "bytes hash" @ HashBefore @ "->" @ After
		@ "bytes hash" @ HashAfter @ "frames=" $ `XCOMHISTORY.GetNumGameStates(),, 'CoopChunks');
}

// Experiment: with no connection yet, does SendHistory fill BaseHistoryData (bytes to send in chunks later) without
// sending anything?
static function PrimeProbe()
{
	local XComGameStateNetworkManager NetMgr;
	local int Before;

	NetMgr = `XCOMNETMANAGER;
	Before = NetMgr.BaseHistoryData.Length;
	NetMgr.SendHistory(`XCOMHISTORY, `XEVENTMGR);
	`log("chunks: prime probe: SendHistory with connections=" $ NetMgr.HasConnections() @ "base" @ Before @ "->"
		@ NetMgr.BaseHistoryData.Length @ "bytes hash" @ Hash(NetMgr.BaseHistoryData) @ "frames=" $ `XCOMHISTORY.GetNumGameStates(),, 'CoopChunks');
}

// ---------------------------------------------------------------- guest

static function OnBegin(int Id, int Total, int Count, int H, int Mode, int Size)
{
	local int i;

	default.InId = Id;
	default.InChunkBytes = Size;
	default.InCount = Count;
	default.InGot = 0;
	default.InHash = H;
	default.InMode = Mode;
	default.InData.Length = 0;
	default.InData.Length = Total;
	default.InHave.Length = 0;
	for (i = 0; i < Count; i++)
	{
		default.InHave.AddItem(0);
	}
	default.InStartedAt = Now();
	`log("chunks: receiving" @ Id @ "bytes=" $ Total @ "chunks=" $ Count @ "of" @ Size @ "mode=" $ Mode,, 'CoopChunks');
}

static function OnChunk(int Id, int Index, array<byte> Raw)
{
	local array<byte> Params;
	local int Off, i;

	if (Id != default.InId || Index < 0 || Index >= default.InCount)
	{
		`log("chunks: stray chunk" @ Id $ "/" $ Index @ "(receiving" @ default.InId $ ")",, 'CoopChunks');
		return;
	}
	Off = Index * default.InChunkBytes;
	if (Off + Raw.Length > default.InData.Length)
	{
		`log("chunks: chunk" @ Index @ "too long:" @ Raw.Length @ "bytes at" @ Off @ "of" @ default.InData.Length,, 'CoopChunks');
		return;
	}
	for (i = 0; i < Raw.Length; i++)
	{
		default.InData[Off + i] = Raw[i];
	}
	if (default.InHave[Index] == 0)
	{
		default.InHave[Index] = 1;
		default.InGot++;
	}
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Id, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Index, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(class'CoopRole'.static.LocalSlot(), Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopChunkAck", Params);
	if (default.InGot == default.InCount)
	{
		Complete();
	}
}

static function Complete()
{
	local XComGameStateNetworkManager NetMgr;
	local array<byte> Params;
	local int H, Mine, i, FirstDiff;

	H = Hash(default.InData);
	`log("chunks: received" @ default.InId @ "complete after" @ (Now() - default.InStartedAt) @ "s: bytes=" $ default.InData.Length
		@ "hash=" $ H @ (H == default.InHash ? "matches" : "DIFFERS from") @ "the host's",, 'CoopChunks');
	if (H != default.InHash)
	{
		return;
	}
	NetMgr = `XCOMNETMANAGER;
	if (default.InMode == MODE_BASE)
	{
		NetMgr.BaseHistoryData = default.InData;
		class'CoopTacticalNet'.default.SavedBase = default.InData;
		class'CoopTacticalNet'.default.SavedBaseAt = Now();
		`log("chunks: took" @ default.InData.Length @ "bytes as the history base",, 'CoopChunks');
		class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.InId, Params);
		class'XComGameStateNetworkManager'.static.AddCommandParam_Int(class'CoopRole'.static.LocalSlot(), Params);
		class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.InData.Length, Params);
		`XCOMNETMANAGER.SendRemoteCommand("CoopChunkDone", Params);
		return;
	}
	if (default.InMode == MODE_COMPARE)
	{
		Mine = Hash(NetMgr.BaseHistoryData);
		FirstDiff = -1;
		for (i = 0; i < Min(NetMgr.BaseHistoryData.Length, default.InData.Length); i++)
		{
			if (NetMgr.BaseHistoryData[i] != default.InData[i])
			{
				FirstDiff = i;
				break;
			}
		}
		`log("chunks: compare with this guest's own base: local bytes=" $ NetMgr.BaseHistoryData.Length @ "hash=" $ Mine
			@ "identical=" $ (Mine == H && NetMgr.BaseHistoryData.Length == default.InData.Length) @ "firstdiff=" $ FirstDiff,, 'CoopChunks');
		return;
	}
	`log("chunks: feeding" @ default.InData.Length @ "bytes to ReceiveHistory; frames before=" $ `XCOMHISTORY.GetNumGameStates(),, 'CoopChunks');
	NetMgr.ReceiveHistory(0, default.InData);
	`log("chunks: ReceiveHistory returned; frames now=" $ `XCOMHISTORY.GetNumGameStates() @ "base bytes=" $ NetMgr.BaseHistoryData.Length
		@ "fp=" $ class'CoopSession'.static.Fingerprint(),, 'CoopChunks');
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(default.InId, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(class'CoopRole'.static.LocalSlot(), Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(`XCOMHISTORY.GetNumGameStates(), Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopChunkDone", Params);
}

// ---------------------------------------------------------------- both

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local int A, B, C, D, E, F;

	if (Left(Command, 9) != "CoopChunk")
	{
		return;
	}
	A = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	B = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	if (Command == "CoopChunk")
	{
		if (class'CoopRole'.static.IsGuest())
		{
			OnChunk(A, B, RawParams);
		}
		return;
	}
	C = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	if (Command == "CoopChunkAck")
	{
		if (!class'CoopRole'.static.IsGuest())
		{
			OnAck(A, B, C);
		}
	}
	else if (Command == "CoopChunkDone")
	{
		if (!class'CoopRole'.static.IsGuest())
		{
			OnDone(A, B, C);
		}
	}
	else if (Command == "CoopChunkBegin")
	{
		D = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		E = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		F = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		if (class'CoopRole'.static.IsGuest())
		{
			OnBegin(A, B, C, D, E, F);
		}
	}
}

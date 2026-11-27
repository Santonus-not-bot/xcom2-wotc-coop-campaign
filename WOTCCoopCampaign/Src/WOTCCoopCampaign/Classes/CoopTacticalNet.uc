//---------------------------------------------------------------------------------------
//  FILE:    CoopTacticalNet.uc
//  PURPOSE: Network side of missions (CoopTacticalRuleset, draft). A plain Object: the
//           network manager outlives maps, delegates bound to an Actor (the ruleset) would
//           keep the old World alive.
//           Entering a mission (guests watch from the start):
//             host, first unit-actions phase: SendHistory, wait for "CoopMissionHistoryAck"
//             guest: full history received -> "CoopMissionHistoryAck"
//             host: ack -> "CoopLoadMission" (sent after the ack: commands can overtake history)
//             guest: "CoopLoadMission" -> CoopTactical.bEnterMissionWatching, open the mission map
//                    (BattleData.m_strMapCommand, as the MPLoadTacticalMap console command does)
//           Handoff during the mission:
//             partial history received -> "CoopHistoryAck" to the sender
//             "CoopHistoryAck" -> ruleset.OnHistoryAck(); "CoopSwitchTurn"(slot, initiative, index, flags) -> ruleset.OnSwitchTurn
//           3-4 players (guests connect only to the host): the host waits for every guest's mission ack,
//           forwards a guest's partial history to all guests, and forwards a guest-to-guest switch only
//           after every guest acknowledged the forwarded frames.
//---------------------------------------------------------------------------------------
class CoopTacticalNet extends Object config(CoopCampaign);

var config bool bInited;               // config only so the default may be written
// Host: the guest slots whose "CoopMissionHistoryAck" is still missing (-1 = any guest). By slot, not a count:
// a guest that leaves between the send and its ack must not leave the host waiting for an ack that never
// comes (run guestrestart-20261113-121530: player 3 quit as the campaign went out, player 2 acknowledged,
// the count stayed at 1 and player 2 never got "CoopEnterAvenger").
var config array<int> MissionAckSlots;     // mission history sent
var config bool bRelayPending;         // host: a guest's partial history to forward on the next tick
var config bool bPartialIsWhole;
var config array<byte> SavedBase;           // copy of the network manager's BaseHistoryData (see KeepBase; runtime, never saved)
var config float SavedBaseAt;           // guest: the next partial history stands in for a whole one
var config array<int> CampaignAckSlots;    // campaign history sent after a mission or a join
var config array<int> RelayAckSlots;      // host: a guest's partial history was relayed to all guests, acks missing (by slot)
var config int PendingSwitchSlot;      // host: a guest's "CoopSwitchTurn" waiting until the relay is acknowledged (-1 = none)
var config int PendingSwitchInitiative, PendingSwitchIndex, PendingSwitchFlags;   // the rest of that switch
var config string ChunkedKind;          // host: the whole send now going out in chunks ("campaign", "mission")

static function Init()
{
	local CoopTacticalNet Net;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	default.PendingSwitchSlot = -1;
	Net = new class'CoopTacticalNet';
	`XCOMNETMANAGER.AddReceiveHistoryDelegate(Net.OnReceiveHistory);
	`XCOMNETMANAGER.AddReceivePartialHistoryDelegate(Net.OnReceivePartialHistory);
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Net.OnRemoteCommand);
}

static function Send(string Command)
{
	local array<byte> Params;

	Params.Length = 0;
	`XCOMNETMANAGER.SendRemoteCommand(Command, Params);
}

// "your turn" for the machine playing TargetSlot (every connection receives it).
// It names the initiative (object id, turn-order index, interrupt flags) that machine begins.
static function SendSwitchTurn(int TargetSlot, int InitiativeID, int Index, int Flags)
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(TargetSlot, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(InitiativeID, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Index, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Flags, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopSwitchTurn", Params);
}

// CoopLink.Tick, host: forward the frames a guest sent to every guest.
// As a full history, not a partial one: a partial history carries the size and hash of the history it builds
// on ("base"), and once the host has applied guest 1's partial history its base is guest 1's newest frame,
// which guest 2 does not have yet. Relayed partial histories therefore always failed on guest 2 ("Base size
// mismatch ... Base hash mismatch", OnSendError_RequestNewHistory) and the engine sent the full history
// after that error round trip anyway (runs mission3-20261112-192009, -194635). Two-player games never hit it.
// With chunked sends on (CoopChunks.bChunkedWholeSend): the same whole history, as the host's base in chunks plus a
// "whole" delta (SendWhole's path). The host's base is now its full history with the guest's frames, so every guest
// takes it as its own base and the delta applies on each. A whole send stops arriving above about 670 KB: in
// soakfresh16 (2026-11-26) a relay of 772 KB in mission 14 never reached either guest, and every later send waited
// behind it. Each guest acknowledges the delta with "CoopHistoryAck" (OnReceiveHistory, in a mission), as before.
static function SendRelay()
{
	default.bRelayPending = false;
	if (class'CoopChunks'.default.bChunkedWholeSend && `XCOMNETMANAGER.BaseHistoryData.Length > 0)
	{
		default.ChunkedKind = "relay";
		if (class'CoopChunks'.static.SendBytes(`XCOMNETMANAGER.BaseHistoryData, class'CoopChunks'.const.MODE_BASE, "relay"))
		{
			`log("relay: the base (" $ `XCOMNETMANAGER.BaseHistoryData.Length @ "bytes) goes out in chunks, then a delta; frames="
				$ `XCOMHISTORY.GetNumGameStates() @ "to" @ default.RelayAckSlots.Length @ "guests",, 'CoopHandoff');
			return;
		}
	}
	`XCOMNETMANAGER.SendHistory(`XCOMHISTORY, `XEVENTMGR);
	`log("relayed the history (" $ `XCOMHISTORY.GetNumGameStates() @ "frames) to" @ default.RelayAckSlots.Length @ "guests",, 'CoopHandoff');
}

// Host, back on the Avenger after a mission: send the campaign; the guests enter it on "CoopEnterAvenger".
static function HostSendCampaign()
{
	if (default.MissionAckSlots.Length > 0)
	{
		`log("a pending mission ack is dropped: the campaign replaces it",, 'CoopHandoff');
		default.MissionAckSlots.Length = 0;
	}
	default.CampaignAckSlots = ExpectedAckSlots();
	ArchiveBeforeSend();
	SendWhole("campaign");
	`log("campaign history sent to guests, waiting for ack",, 'CoopHandoff');
}

// Host on the Avenger (experiment, CoopLink.bArchiveBeforeCampaignSend): a whole history sent at once stopped
// arriving above about 670 KB (soakstory16 2026-11-18: 661 KB acknowledged, 685 KB and up never), which a campaign
// reaches after about 14 bot missions. ArchiveHistory replaces the frames with two full states of every object and,
// with SkipTacticalTransientTypes, leaves out what earlier missions left behind. Every guest gets this full history
// next, so no machine is left with the old frame numbers.
static function ArchiveBeforeSend()
{
	local int Before;

	if (!class'CoopLink'.default.bArchiveBeforeCampaignSend || class'CoopSession'.static.InTactical())
	{
		return;
	}
	Before = `XCOMHISTORY.GetNumGameStates();
	`XCOMHISTORY.ArchiveHistory("Coop campaign send", true);
	`log("history archived before the campaign send: frames" @ Before @ "->" @ `XCOMHISTORY.GetNumGameStates(),, 'CoopHandoff');
}

// Host: a whole history for the guests. A whole-history send stopped arriving above about 670 KB (soakstory16,
// 2026-11-18), which a long campaign passes. Experiment (CoopLink.bPartialResend): once a whole history went out
// this session, send the next ones as the engine's partial history, a binary delta against the last history data
// both ends hold (XComGameStateNetworkManager.BaseHistoryData), announced with "CoopNextIsWhole" so the guest treats
// it as the whole history. A guest's history survives its trip through the main menu.
static function SendWhole(string Kind)
{
	// Chunked (CoopChunks.bChunkedWholeSend): the host's base goes out in chunks, every guest takes it as its own,
	// then the usual delta (ChunkedWholeDone) brings them up to date. No size ceiling (the engine's whole send stops
	// arriving above about 670 KB). Without a base (nothing sent since the game started and no prime) or without
	// guests: the engine's whole send as before.
	if (class'CoopChunks'.default.bChunkedWholeSend && class'CoopRole'.default.ConnectedSlots.Length > 0)
	{
		RestoreBase("host");
		if (`XCOMNETMANAGER.BaseHistoryData.Length > 0)
		{
			default.ChunkedKind = Kind;
			if (class'CoopChunks'.static.SendBytes(`XCOMNETMANAGER.BaseHistoryData, class'CoopChunks'.const.MODE_BASE, Kind))
			{
				`log(Kind @ "history: the base (" $ `XCOMNETMANAGER.BaseHistoryData.Length @ "bytes) goes out in chunks, then a delta; frames="
					$ `XCOMHISTORY.GetNumGameStates(),, 'CoopHandoff');
				return;
			}
		}
		`log(Kind @ "history: no base to send in chunks: whole send",, 'CoopHandoff');
	}
	if (class'CoopLink'.default.bPartialResend && class'CoopLink'.default.WholeSendCount > 0)
	{
		RestoreBase("host");
		Send("CoopNextIsWhole");
		`XCOMNETMANAGER.SendPartialHistory(`XCOMHISTORY, `XEVENTMGR);
		`log(Kind @ "history sent as a partial history (delta), frames=" $ `XCOMHISTORY.GetNumGameStates(),, 'CoopHandoff');
		return;
	}
	`XCOMNETMANAGER.SendHistory(`XCOMHISTORY, `XEVENTMGR);
	class'CoopLink'.default.WholeSendCount++;
}

// Host: every guest took the chunked base (CoopChunks); the delta from it to now stands in for the whole history.
static function ChunkedWholeDone()
{
	Send("CoopNextIsWhole");
	`XCOMNETMANAGER.SendPartialHistory(`XCOMHISTORY, `XEVENTMGR);
	class'CoopLink'.default.WholeSendCount++;
	`log(default.ChunkedKind @ "history sent: chunked base + delta, frames=" $ `XCOMHISTORY.GetNumGameStates()
		@ "base now" @ `XCOMNETMANAGER.BaseHistoryData.Length @ "bytes",, 'CoopHandoff');
}

// Host: the chunked base did not get through in time (CoopChunks.Tick): the engine's whole send.
static function ChunkedWholeFailed()
{
	`XCOMNETMANAGER.SendHistory(`XCOMHISTORY, `XEVENTMGR);
	class'CoopLink'.default.WholeSendCount++;
	`log(default.ChunkedKind @ "history sent whole (chunked base failed), frames=" $ `XCOMHISTORY.GetNumGameStates(),, 'CoopHandoff');
}

// Host, before its server opens (CoopLink.HostOpen): with nobody connected, SendHistory fills BaseHistoryData and sends
// nothing (chunktest 2026-11-24), so the first whole send to a joining guest has a base to send in chunks.
static function PrimeBase(string Where)
{
	local XComGameStateNetworkManager NetMgr;

	NetMgr = `XCOMNETMANAGER;
	if (!class'CoopChunks'.default.bChunkedWholeSend || !class'CoopRole'.static.CoopActive() || NetMgr.HasConnections())
	{
		return;
	}
	NetMgr.SendHistory(`XCOMHISTORY, `XEVENTMGR);
	default.SavedBase = NetMgr.BaseHistoryData;
	default.SavedBaseAt = class'WorldInfo'.static.GetWorldInfo().RealTimeSeconds;
	`log("history base primed (" $ Where $ "):" @ NetMgr.BaseHistoryData.Length @ "bytes, frames=" $ `XCOMHISTORY.GetNumGameStates(),, 'CoopHandoff');
}

// The partial history is a delta against BaseHistoryData, the last history data both ends hold. A guest that left
// the Avenger after a connection timeout came back with it empty ("Base size mismatch: 378172 != 0", soakpartial
// 2026-11-18; the engine then sent the whole history). Keep a copy while connected (CoopLink.Tick, every 5 s and on
// any size change) and put it back when it has gone empty before a delta that stands in for a whole history.
static function KeepBase()
{
	local XComGameStateNetworkManager NetMgr;
	local float Now;

	if (!class'CoopLink'.default.bPartialResend && !class'CoopChunks'.default.bChunkedWholeSend)
	{
		return;
	}
	NetMgr = `XCOMNETMANAGER;
	Now = class'WorldInfo'.static.GetWorldInfo().RealTimeSeconds;
	if (NetMgr.BaseHistoryData.Length > 0 && (NetMgr.BaseHistoryData.Length != default.SavedBase.Length || Abs(Now - default.SavedBaseAt) >= 5.0f))
	{
		default.SavedBase = NetMgr.BaseHistoryData;
		default.SavedBaseAt = Now;
	}
}

static function RestoreBase(string Who)
{
	local XComGameStateNetworkManager NetMgr;

	NetMgr = `XCOMNETMANAGER;
	if (NetMgr.BaseHistoryData.Length == 0 && default.SavedBase.Length > 0)
	{
		NetMgr.BaseHistoryData = default.SavedBase;
		`log(Who $ ": history base was empty; restored the kept copy (" $ default.SavedBase.Length @ "bytes)",, 'CoopHandoff');
	}
}

// Host: the mission has started here; bring the guests in.
// A campaign send still waiting for its ack is dropped: both are acknowledged with "CoopMissionHistoryAck", and a
// stale campaign wait took the guest's ack of the mission and told it to enter the Avenger with the mission's
// history; the guest crashed building unit visuals there (chosenassault 2026-11-16: the guest rejoined on the
// Avenger, the delayed campaign send went out, and 0.1 s later the host closed the connection to build the mission).
static function HostSendMission()
{
	if (default.CampaignAckSlots.Length > 0)
	{
		`log("a pending campaign ack is dropped: the mission replaces it",, 'CoopHandoff');
		default.CampaignAckSlots.Length = 0;
	}
	default.MissionAckSlots = ExpectedAckSlots();
	SendWhole("mission");
	`log("mission history sent to guests, waiting for ack",, 'CoopHandoff');
}

static function array<int> ExpectedAckSlots()
{
	local array<int> Slots;

	Slots = class'CoopRole'.default.ConnectedSlots;
	if (Slots.Length == 0)
	{
		Slots.AddItem(-1);    // a guest whose slot is not known yet
	}
	return Slots;
}

// Host: one guest acknowledged; true when the last missing ack came in.
static function bool TakeAck(out array<int> Pending, int Slot)
{
	local int Idx;

	if (Pending.Length == 0)
	{
		return false;
	}
	Idx = Pending.Find(Slot);
	if (Idx == INDEX_NONE)
	{
		Idx = Pending.Find(-1);
	}
	if (Idx == INDEX_NONE)
	{
		Idx = 0;    // an ack without a known slot (should not happen): count it as before
	}
	Pending.Remove(Idx, 1);
	return Pending.Length == 0;
}

// CoopRole, host: a guest is gone; stop waiting for its acknowledgements.
static function OnGuestGone(int Slot)
{
	class'CoopChunks'.static.OnGuestGone(Slot);
	if (default.CampaignAckSlots.Find(Slot) != INDEX_NONE && TakeAck(default.CampaignAckSlots, Slot))
	{
		Send("CoopEnterAvenger");
		`log("the last guest without the campaign left: telling the others to enter the Avenger",, 'CoopHandoff');
	}
	if (default.MissionAckSlots.Find(Slot) != INDEX_NONE && TakeAck(default.MissionAckSlots, Slot))
	{
		Send("CoopLoadMission");
		`log("the last guest without the mission history left: telling the others to load the map",, 'CoopHandoff');
	}
	if (default.RelayAckSlots.Find(Slot) != INDEX_NONE && TakeAck(default.RelayAckSlots, Slot))
	{
		ForwardPendingSwitch("the last guest without the relayed frames left");
	}
}

function OnReceiveHistory(XComGameStateHistory InHistory, X2EventManager EventManager)
{
	local XComGameStateVisualizationMgr VisMgr;

	class'CoopLink'.default.bHistorySinceJoin = true;    // the join watchdog in CoopLink.Tick

	// Outside a mission the received history is either the campaign (in the shell, a map change follows)
	// or the host's running mission, which this copy loads next. The current map's visualization manager
	// would build visuals for the mission's frames on the Avenger, where there is no tactical presentation:
	// unit visualizers failed with "Accessed None 'PRES'" in every run and once crashed the guest
	// ("GettingNameData", run mission-20261112-114553). A new map brings a new manager, enabled by its bootstrap.
	VisMgr = XComGameReplicationInfo(class'WorldInfo'.static.GetWorldInfo().GRI) != none ? XComGameReplicationInfo(class'WorldInfo'.static.GetWorldInfo().GRI).VisualizationMgr : none;
	if (class'CoopRole'.static.IsGuest() && !class'CoopSession'.static.InTactical() && VisMgr != none)
	{
		VisMgr.EnableBuildVisualization(false);
		`log("history received outside a mission: visualization of its frames turned off on this map",, 'CoopHandoff');
	}
	if (class'CoopRole'.static.IsGuest() && class'CoopSession'.static.InTactical())
	{
		// During a mission a full history is the engine's own resend: a guest that could not apply a partial
		// history asks for it ("OnSendError_RequestNewHistory") and the host's network manager sends the whole
		// history instead (seen for the second guest of a relay, run mission3-20261112-192009). Acknowledge it
		// as the partial history it replaces.
		`log("full history received during the mission (resent instead of a partial one) frames=" $ InHistory.GetNumGameStates(),, 'CoopHandoff');
		SendHistoryAck();
		return;
	}
	if (class'CoopRole'.static.IsGuest())
	{
		SendMissionHistoryAck();
	}
}

// Guest: the full history arrived; the ack names this guest's slot.
static function SendMissionHistoryAck()
{
	local array<byte> Params;

	// during a mission launch: if "CoopLoadMission" does not follow, CoopLink.Tick loads the mission itself
	if (class'CoopMissionLoading'.default.bActive && !class'CoopMissionLoading'.default.bReturn)
	{
		class'CoopMissionLoading'.default.AckedAt = class'CoopMissionLoading'.static.ClockSeconds();
	}

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(class'CoopRole'.static.LocalSlot(), Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopMissionHistoryAck", Params);
}

// Any machine: a partial history (or the full one resent in its place) arrived. The ack names the sender's
// slot, so the host can tell whose ack for its relay is still missing.
static function SendHistoryAck()
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(class'CoopRole'.static.LocalSlot(), Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopHistoryAck", Params);
}

// Host: every guest has the relayed frames; pass on the guest-to-guest switch that waited for them.
static function ForwardPendingSwitch(string Why)
{
	if (default.PendingSwitchSlot < 0)
	{
		return;
	}
	SendSwitchTurn(default.PendingSwitchSlot, default.PendingSwitchInitiative, default.PendingSwitchIndex, default.PendingSwitchFlags);
	`log(Why $ ": forwarded switch to player" @ default.PendingSwitchSlot,, 'CoopHandoff');
	default.PendingSwitchSlot = -1;
}

function OnReceivePartialHistory(XComGameStateHistory InHistory, X2EventManager EventManager)
{
	if (class'CoopRole'.static.IsGuest() && default.bPartialIsWhole)
	{
		default.bPartialIsWhole = false;
		`log("partial history received in place of a whole one, frames=" $ InHistory.GetNumGameStates(),, 'CoopHandoff');
		OnReceiveHistory(InHistory, EventManager);
		return;
	}
	`log("partial history received frames=" $ InHistory.GetNumGameStates(),, 'CoopHandoff');
	SendHistoryAck();
	class'CoopListenerRepair'.static.RepairAll("partial history");
	// 3-4 players: guests connect only to the host, so the host forwards a guest's frames to every guest
	// (the sender gets them back too and simply acknowledges)
	// Sent on the next tick, not from inside this receive callback: sent from here, only the guest that sent
	// the frames got them back and the other guest never did (run mission3-20261112-185409).
	if (!class'CoopRole'.static.IsGuest() && class'CoopRole'.default.ConnectedSlots.Length > 1)
	{
		default.RelayAckSlots = class'CoopRole'.default.ConnectedSlots;
		default.bRelayPending = true;
		class'CoopLinkTimer'.static.Ensure();
	}
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local CoopTacticalRuleset Rules;
	local int Slot, InitiativeID, Index, Flags, i;

	if (Command == "CoopMissionHistoryAck" && !class'CoopRole'.static.IsGuest())
	{
		Slot = RawParams.Length > 0 ? class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams) : -1;
	}
	if (Command == "CoopMissionHistoryAck" && default.CampaignAckSlots.Length > 0 && !class'CoopRole'.static.IsGuest()
		&& !class'CoopSession'.static.InTactical())
	{
		// the guests acknowledge every full history; after a mission it is the campaign
		if (TakeAck(default.CampaignAckSlots, Slot))
		{
			for (i = 0; i < class'CoopRole'.default.ConnectedSlots.Length; i++)
			{
				class'CoopRoster'.static.MarkLoading(class'CoopRole'.default.ConnectedSlots[i]);    // merges wait (CoopSession.FlushBatch)
			}
			Send("CoopEnterAvenger");
			`log("guests have the campaign: telling them to enter the Avenger",, 'CoopHandoff');
		}
		return;
	}
	if (Command == "CoopScenarioOver")
	{
		if (class'CoopRole'.static.IsGuest())
		{
			class'CoopScenario'.static.GuestScenarioOver();
		}
		return;
	}
	if (Command == "CoopNextIsWhole")
	{
		if (class'CoopRole'.static.IsGuest())
		{
			default.bPartialIsWhole = true;
			RestoreBase("guest");
		}
		return;
	}
	if (Command == "CoopEnterAvenger")
	{
		if (class'CoopRole'.static.IsGuest() && !class'CoopSession'.static.InTactical())
		{
			EnterAvengerAsGuest();
		}
		return;
	}
	if (Command == "CoopMissionHistoryAck")
	{
		if (!class'CoopRole'.static.IsGuest() && TakeAck(default.MissionAckSlots, Slot))
		{
			Send("CoopLoadMission");
			`log("guest has the mission history: telling it to load the map",, 'CoopHandoff');
		}
		return;
	}
	if (Command == "CoopLoadMission")
	{
		// a guest already in the mission ignores it (the host resent the history for a guest joining late)
		if (class'CoopRole'.static.IsGuest() && !class'CoopSession'.static.InTactical())
		{
			LoadMissionAsWatcher();
		}
		return;
	}
	if (Command == "CoopMissionReturning")
	{
		`log("the host is going back to the Avenger; the connection closes until it is there",, 'CoopHandoff');
		class'CoopMissionLoading'.static.Begin("", true);
		return;
	}
	if (Command == "CoopMissionBuilding")
	{
		`log("the host is building the mission; the connection closes until its first turn",, 'CoopHandoff');
		// the mission's name since 2026-11-18 (an older host sends none)
		class'CoopMissionLoading'.static.Begin(RawParams.Length > 0 ? class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams) : "");
		return;
	}
	Rules = CoopTacticalRuleset(`TACTICALRULES);
	if (Rules == none)
	{
		return;
	}
	if (Command == "CoopHistoryAck")
	{
		Slot = RawParams.Length > 0 ? class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams) : -1;
		// an ack for the host's relay, not for a handoff of its own; while the host hands over, only from a guest the
		// relay still waits for (soakfresh16-20261127-032327: a relay ack missing from a guest outside the mission
		// swallowed both acks of the host's next handoff, which then waited for the rest of the mission)
		if (default.RelayAckSlots.Length > 0 && !class'CoopRole'.static.IsGuest()
			&& (!Rules.IsInState('TurnPhase_CoopHandoff') || default.RelayAckSlots.Find(Slot) != INDEX_NONE || Slot < 0))
		{
			if (TakeAck(default.RelayAckSlots, Slot))
			{
				ForwardPendingSwitch("relay acknowledged");
			}
			return;
		}
		Rules.OnHistoryAck();
	}
	else if (Command == "CoopSwitchTurn")
	{
		Slot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		InitiativeID = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		Index = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		Flags = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
		if (!class'CoopRole'.static.IsGuest() && Slot != class'XComGameState_CoopCampaign'.const.SLOT_HOST)
		{
			// a guest handed over to another guest: forward the switch once every guest has the frames
			if (default.RelayAckSlots.Length > 0)
			{
				default.PendingSwitchSlot = Slot;
				default.PendingSwitchInitiative = InitiativeID;
				default.PendingSwitchIndex = Index;
				default.PendingSwitchFlags = Flags;
			}
			else
			{
				SendSwitchTurn(Slot, InitiativeID, Index, Flags);
			}
			return;
		}
		Rules.OnSwitchTurn(Slot, InitiativeID, Index, Flags);
	}
}

// Guest: open the Avenger with the campaign history just received (what the test harness's @mirror does).
static function EnterAvengerAsGuest()
{
	ClearShellLiveDelegates();
	class'CoopSession'.default.bEnterAsMirror = true;
	class'CoopMissionLoading'.static.Advance(class'CoopMissionLoading'.const.STEP_LOADING, "loading the Avenger");
	class'CoopRoster'.static.GuestLoading(true);
	class'CoopMissionLoading'.static.End(class'CoopMissionLoading'.default.bReturn ? "the game's loading screen takes over" : "the host sent the campaign instead");
	`log("entering the Avenger with the host's campaign",, 'CoopHandoff');
	class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController().ConsoleCommand("open Avenger_Root?game=XComGame.XComHeadQuartersGame");
}

static function LoadMissionAsWatcher()
{
	local XComGameState_BattleData BattleData;

	BattleData = XComGameState_BattleData(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_BattleData', true));
	if (BattleData == none || BattleData.m_strMapCommand == "")
	{
		`log("load mission: no battle data in the received history",, 'CoopHandoff');
		return;
	}
	class'CoopTactical'.default.bEnterMissionWatching = true;
	class'CoopMissionLoading'.static.Advance(class'CoopMissionLoading'.const.STEP_LOADING, "loading the map");
	class'CoopMissionLoading'.static.End("the game's loading screen takes over");
	class'CoopRoster'.static.GuestLoading(true);
	ClearShellLiveDelegates();    // a guest that started the game and joined from the main menu travels from the shell
	`log("loading the host's mission as a watcher:" @ BattleData.m_strMapCommand,, 'CoopHandoff');
	class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController().ConsoleCommand(BattleData.m_strMapCommand);
}

// Moved here from the test harness (first found there, 2026-11-12):
static function ClearShellLiveDelegates()
{
	local UIFiraxisLiveLogin LiveLogin;

	// A fresh install opens the Firaxis Live login screen in the shell. It removes its delegates from
	// the engine's live client only when it closes; travelling with it open leaves the shell World
	// referenced (X2FiraxisLiveClient.ConnectionStatusDelegates) and the map load asserts (UnGame.cpp:3107).
	// Its state versions of CloseScreen do not always reach the global one that clears the delegates,
	// so clear them here for every instance, then close the screen.
	foreach class'WorldInfo'.static.GetWorldInfo().AllActors(class'UIFiraxisLiveLogin', LiveLogin)
	{
		`log("clearing the Firaxis Live login screen's delegates before travel",, 'CoopHandoff');
		`FXSLIVE.ClearClientStateChangeDelegate(LiveLogin.OnClientStateChange);
		`FXSLIVE.ClearConnectionFailureDelegate(LiveLogin.OnConnectionFailure);
		`FXSLIVE.ClearConnectionStatusDelegate(LiveLogin.OnConnectionStatusChange);
		`FXSLIVE.ClearLogonDataDelegate(LiveLogin.OnLogonData);
		`FXSLIVE.ClearLoginStatusDelegate(LiveLogin.OnLoginStatus);
		`FXSLIVE.ClearCreateNewAccountDelegate(LiveLogin.OnNewAccountNotify);
		`FXSLIVE.ClearDOBDataDelegate(LiveLogin.OnDoBNotify);
		`FXSLIVE.ClearLegalInfoDelegate(LiveLogin.OnLegalNotify);
		`ONLINEEVENTMGR.ClearCheckReadyForGameInviteAcceptDelegate(LiveLogin.OnCheckReadyForGameInviteAccept);
		if (`SCREENSTACK.IsInStack(class'UIFiraxisLiveLogin'))
		{
			LiveLogin.CloseScreen();
		}
	}
}

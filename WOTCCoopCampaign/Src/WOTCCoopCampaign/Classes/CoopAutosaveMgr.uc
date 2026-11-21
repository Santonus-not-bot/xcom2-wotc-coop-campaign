//---------------------------------------------------------------------------------------
//  FILE:    CoopAutosaveMgr.uc
//  PURPOSE: Replaces XComAutosaveMgr (ModClassOverrides). Only the host saves the shared
//           campaign: on the co-op client autosaves and quicksaves do nothing.
//           A client that sent a merge state while it was saving crashed in a worker thread
//           ("FWriteHistoryObjects", XCom2.exe+0x4ce235 reading null+0xe0), reproduced in tests
//           "autosave-burst" and "client-send-then-save"; the host did not crash in the same
//           pattern. Its saves would not be loadable as the shared campaign anyway.
//---------------------------------------------------------------------------------------
class CoopAutosaveMgr extends XComAutosaveMgr;

static function bool IsCoopClient()
{
	return `XCOMNETMANAGER.HasClientConnection();
}

function bool AutosaveEnabled(bool bIsIronman)
{
	if (IsCoopClient())
	{
		`log("autosave skipped: co-op client (the host saves the campaign)",, 'CoopCampaign');
		return false;
	}
	return super.AutosaveEnabled(bIsIronman);
}

// Logged so tests see when the host's autosave (the Ironman save in an Ironman campaign) is written.
function DoAutosave(delegate<XComOnlineEventMgr.WriteSaveGameComplete> AutoSaveCompleteCallback = none, optional bool bDebugSave, optional bool bPreMissionSave, optional bool bPostMissionSave, optional int PartialHistoryLength = -1)
{
	local XComGameState_CampaignSettings Settings;

	Settings = XComGameState_CampaignSettings(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_CampaignSettings', true));
	`log("autosave requested ironman=" $ class'CoopHarness'.static.BoolStr(Settings != none && Settings.bIronmanEnabled)
		@ "tactical=" $ class'CoopHarness'.static.BoolStr(class'CoopSession'.static.InTactical()) @ "client=" $ class'CoopHarness'.static.BoolStr(IsCoopClient()),, 'CoopCampaign');
	super.DoAutosave(AutoSaveCompleteCallback, bDebugSave, bPreMissionSave, bPostMissionSave, PartialHistoryLength);
}

function DoQuicksave(delegate<XComOnlineEventMgr.WriteSaveGameComplete> QuicksaveCompleteCallback = none)
{
	if (IsCoopClient())
	{
		`log("quicksave skipped: co-op client (the host saves the campaign)",, 'CoopCampaign');
		if (QuicksaveCompleteCallback != none)
		{
			QuicksaveCompleteCallback(false);
		}
		return;
	}
	if (class'CoopRole'.static.CoopActive() && class'Engine'.static.GetEngine().IsMultiPlayerGame())
	{
		HostQuicksave(QuicksaveCompleteCallback);
		return;
	}
	super.DoQuicksave(QuicksaveCompleteCallback);
}

// The base refuses to quicksave while IsMultiPlayerGame(), which is true whenever the co-op connection is open
// (CoopLink). The co-op host saves the shared campaign, so it quicksaves as in single player: the base code
// without that check. Not while this machine is watching another player's turn (its history then trails
// the frames still being played back) or in the middle of handing a turn over.
function HostQuicksave(delegate<XComOnlineEventMgr.WriteSaveGameComplete> QuicksaveCompleteCallback)
{
	local array<OnlineSaveGame> arrGames;
	local OnlineSaveGame kGame;
	local OnlineSaveGameDataMapping kData;
	local XComOnlineEventMgr EventMgr;
	local X2TacticalGameRuleset Rules;
	local XComGameState_CampaignSettings Settings;
	local int iSaveSlot;
	local bool bIsIronman;

	Settings = XComGameState_CampaignSettings(`XCOMHISTORY.GetSingleGameStateObjectForClass(class'XComGameState_CampaignSettings', true));
	bIsIronman = Settings != none && Settings.bIronmanEnabled;
	Rules = `TACTICALRULES;
	if (!SavingEnabled() || bIsIronman || (Rules != none && (Rules.IsInState('PerformingReplay') || Rules.IsInState('TurnPhase_CoopHandoff'))))
	{
		`log("quicksave refused: ironman, saving disabled, or another player's turn",, 'CoopCampaign');
		if (QuicksaveCompleteCallback != none)
		{
			QuicksaveCompleteCallback(false);
		}
		return;
	}
	EventMgr = `ONLINEEVENTMGR;
	iSaveSlot = -1;
	EventMgr.GetSaveGames(arrGames);
	foreach arrGames(kGame)
	{
		foreach kGame.SaveGames(kData)
		{
			if (kData.SaveGameHeader.bIsQuicksave)
			{
				iSaveSlot = kData.SaveGameHeader.SaveID;
				break;
			}
		}
		if (iSaveSlot >= 0)
		{
			break;
		}
	}
	if (iSaveSlot < 0)
	{
		iSaveSlot = GetNextSaveID();
	}
	if (QuicksaveCompleteCallback != none)
	{
		SaveGameCompleteCallback = QuicksaveCompleteCallback;
	}
	`log("co-op host quicksave to slot" @ iSaveSlot,, 'CoopCampaign');
	EventMgr.SaveGame(iSaveSlot, false, true, OnSaveGameComplete);
	EventMgr.SaveProfileSettings();
}

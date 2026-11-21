//---------------------------------------------------------------------------------------
//  FILE:    X2DownloadableContentInfo_WOTCCoopCampaign.uc
//  PURPOSE: Mod entry point.
//---------------------------------------------------------------------------------------
class X2DownloadableContentInfo_WOTCCoopCampaign extends X2DownloadableContentInfo;

static event OnLoadedSavedGame()
{
}

static event InstallNewCampaign(XComGameState StartState)
{
}

// Strategy, just before the map travel to a mission: the host builds the mission without a connection
// (CoopLink explains why).
static event OnPreMission(XComGameState StartGameState, XComGameState_MissionSite MissionState)
{
	local string MissionName;

	if (MissionState != none)
	{
		// "Operation Iron Shroud - Guerrilla Op" for the guests' loading screen
		MissionName = MissionState.GeneratedMission.BattleOpName;
		if (MissionState.GetMissionDescription() != "")
		{
			MissionName $= (MissionName == "" ? "" : " - ") $ MissionState.GetMissionDescription();
		}
	}
	class'CoopLink'.static.HostCloseForMission(MissionName);
}

static event OnPostTemplatesCreated()
{
	class'CoopRules'.static.SwapAimCalcs();
}

// Strategy, while the Avenger loads after a mission: the host reopens the connection shortly (CoopLink).
static event OnPostMission()
{
	class'CoopLink'.static.HostBackOnAvenger();
}

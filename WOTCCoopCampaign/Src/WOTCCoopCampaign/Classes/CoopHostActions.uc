//---------------------------------------------------------------------------------------
//  FILE:    CoopHostActions.uc
//  PURPOSE: Campaign decisions only the host makes (target design: the host runs the
//           campaign, guests manage their own soldiers):
//           - which player gets which squad slot for the next mission;
//           - giving a soldier to a player, or taking it back (any time);
//           - how many players the campaign has.
//           Each is one ordinary frame, so it reaches the guests like any other host change.
//           A UI calls these; for now the test bot does (@assignslot, @give, @players).
//---------------------------------------------------------------------------------------
class CoopHostActions extends Object;

static function bool RequireHost(string What)
{
	if (!class'CoopRole'.static.IsHost())
	{
		`log("refused (" $ What $ "): only the host may do this; local slot" @ class'CoopRole'.static.LocalSlot(),, 'CoopHost');
		return false;
	}
	return true;
}

static function bool AssignSquadSlot(int SquadIndex, int Player)
{
	local XComGameState NewGameState;
	local XComGameState_CoopCampaign Coop;

	if (!RequireHost("assign squad slot") || !class'XComGameState_CoopCampaign'.static.IsValidPlayer(Player))
	{
		return false;
	}
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop: assign squad slot");
	Coop = class'XComGameState_CoopCampaign'.static.GetForChange(NewGameState);
	Coop.SetSquadSlotOwner(SquadIndex, Player);
	`GAMERULES.SubmitGameState(NewGameState);
	`log("squad slot" @ SquadIndex @ "-> player" @ Player @ Coop.Describe(),, 'CoopHost');
	return true;
}

// Player -1 takes the soldier back (unowned).
static function bool GiveSoldier(int UnitID, int Player)
{
	local XComGameState NewGameState;
	local XComGameState_Unit Unit;

	if (!RequireHost("give soldier") || (Player != class'CoopOwnership'.const.NO_OWNER && !class'XComGameState_CoopCampaign'.static.IsValidPlayer(Player)))
	{
		return false;
	}
	if (XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(UnitID)) == none)
	{
		`log("give: no unit" @ UnitID,, 'CoopHost');
		return false;
	}
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop: give soldier");
	Unit = XComGameState_Unit(NewGameState.ModifyStateObject(class'XComGameState_Unit', UnitID));
	class'CoopOwnership'.static.SetOwner(Unit, Player);
	`GAMERULES.SubmitGameState(NewGameState);
	`log("soldier" @ UnitID @ "-> player" @ Player,, 'CoopHost');
	return true;
}

static function bool SetPlayerCount(int Count)
{
	local XComGameState NewGameState;
	local XComGameState_CoopCampaign Coop;

	if (!RequireHost("player count"))
	{
		return false;
	}
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop: player count");
	Coop = class'XComGameState_CoopCampaign'.static.GetForChange(NewGameState);
	Coop.PlayerCount = Clamp(Count, 1, class'XComGameState_CoopCampaign'.const.MAX_PLAYERS);
	Coop.SetDefaultSquadSplit((Coop.SquadSlotOwner.Length > 0) ? Coop.SquadSlotOwner.Length : class'X2StrategyGameRulesetDataStructures'.static.GetMaxSoldiersAllowedOnMission());
	`GAMERULES.SubmitGameState(NewGameState);
	`log("players" @ Coop.PlayerCount @ Coop.Describe(),, 'CoopHost');
	return true;
}

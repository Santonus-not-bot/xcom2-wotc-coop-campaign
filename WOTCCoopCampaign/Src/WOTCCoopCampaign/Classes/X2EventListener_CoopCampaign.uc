//---------------------------------------------------------------------------------------
//  FILE:    X2EventListener_CoopCampaign.uc
//  PURPOSE: Tactical start: split the XCom initiative group by owner (CoopTactical), in a
//           frame of its own right after begin play is submitted. Only when enabled in config
//           and the campaign has a co-op object.
//---------------------------------------------------------------------------------------
class X2EventListener_CoopCampaign extends X2EventListener;

static function array<X2DataTemplate> CreateTemplates()
{
	local array<X2DataTemplate> Templates;

	Templates.AddItem(CreateSplitTemplate());
	return Templates;
}

static function X2EventListenerTemplate CreateSplitTemplate()
{
	local X2EventListenerTemplate Template;

	`CREATE_X2TEMPLATE(class'X2EventListenerTemplate', Template, 'CoopSplitXComGroup');
	Template.RegisterInTactical = true;
	Template.AddEvent('OnTacticalBeginPlay', OnTacticalBeginPlay);
	Template.AddEvent('PlayerTurnBegun', OnPlayerTurnBegun);
	Template.AddEvent('UnitDied', OnUnitDied);
	return Template;
}

// Every death in a mission, with what caused it (the frame's ability, its user and that unit's team), for
// the test logs. Logs only.
static protected function EventListenerReturn OnUnitDied(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	local XComGameState_Unit Unit, Source;
	local XComGameStateContext_Ability AbilityContext;
	local string Cause;

	Unit = XComGameState_Unit(EventData);
	if (Unit == none || class'XComGameState_CoopCampaign'.static.Get() == none)
	{
		return ELR_NoInterrupt;
	}
	AbilityContext = (GameState != none) ? XComGameStateContext_Ability(GameState.GetContext()) : none;
	if (AbilityContext != none)
	{
		Source = XComGameState_Unit(`XCOMHISTORY.GetGameStateForObjectID(AbilityContext.InputContext.SourceObject.ObjectID));
		Cause = "ability=" $ AbilityContext.InputContext.AbilityTemplateName @ "source=" $ AbilityContext.InputContext.SourceObject.ObjectID
			@ "(" $ ((Source != none) ? (Source.GetMyTemplateName() @ Source.GetTeam()) : "none") $ ")";
	}
	else
	{
		Cause = "context=" $ ((GameState != none) ? string(GameState.GetContext().Class.Name) : "none");
	}
	`log("unit died id=" $ Unit.ObjectID @ Unit.GetMyTemplateName() @ "team=" $ Unit.GetTeam()
		@ "owner=" $ class'CoopOwnership'.static.OwnerOf(Unit) @ Cause,, 'CoopContent');
	return ELR_NoInterrupt;
}

// Each XCom player turn, on the host: soldiers a guest owns that entered play during the mission go to
// that guest's group (CoopTactical.RegroupOwnedUnits). At the turn's start, so no soldier acts twice in
// a round. Guests get the frame like any other.
static protected function EventListenerReturn OnPlayerTurnBegun(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	local XComGameState_Player Player;
	local XComGameState NewGameState;
	local int Moved;

	Player = XComGameState_Player(EventData);
	if (Player == none || Player.GetTeam() != eTeam_XCom || !class'CoopRole'.static.IsHost()
		|| !class'CoopTactical'.default.bSplitXComGroupAtStart || class'XComGameState_CoopCampaign'.static.Get() == none
		|| (class'CoopLink'.default.MissionSlots.Length == 0 && class'CoopRole'.default.ConnectedSlots.Length == 0))
	{
		return ELR_NoInterrupt;
	}
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop: soldiers who joined the mission to their owner's group");
	Moved = class'CoopTactical'.static.RegroupOwnedUnits(NewGameState);
	if (Moved > 0)
	{
		`TACTICALRULES.SubmitGameState(NewGameState);
		`log("regroup at XCom turn begin moved=" $ Moved,, 'CoopTactical');
	}
	else
	{
		`XCOMHISTORY.CleanupPendingGameState(NewGameState);
	}
	return ELR_NoInterrupt;
}

static protected function EventListenerReturn OnTacticalBeginPlay(Object EventData, Object EventSource, XComGameState GameState, Name Event, Object CallbackData)
{
	local XComGameState NewGameState;

	// only for a co-op mission: guests were connected when the host launched it (CoopLink closes the connection
	// while the mission is built, so this is remembered, not checked now)
	if (!class'CoopTactical'.default.bSplitXComGroupAtStart || class'XComGameState_CoopCampaign'.static.Get() == none
		|| (class'CoopLink'.default.MissionSlots.Length == 0 && class'CoopRole'.default.ConnectedSlots.Length == 0))
	{
		return ELR_NoInterrupt;
	}
	// Templates register with ELD_OnStateSubmitted: GameState is already in the history and must not be
	// changed, so the split is a frame of its own, submitted right after begin play.
	NewGameState = class'XComGameStateContext_ChangeContainer'.static.CreateChangeState("Coop: split XCom group at mission start");
	if (class'CoopTactical'.static.SplitXComGroup(NewGameState) > 0)
	{
		`TACTICALRULES.SubmitGameState(NewGameState);
	}
	else
	{
		`XCOMHISTORY.CleanupPendingGameState(NewGameState);
	}
	return ELR_NoInterrupt;
}

//---------------------------------------------------------------------------------------
//  FILE:    CoopTacticalController.uc
//  PURPOSE: A player can select only their own soldiers (ModClassOverrides on
//           XComTacticalController). Tab cycling (Visualizer_CycleToNextAvailableUnit) tries
//           Visualizer_SelectUnit on each candidate, so gating that one function covers clicks
//           and cycling. Unowned soldiers and non-XCom units are never blocked.
//           Off unless bGateSelection (XComCoopCampaign.ini) and the campaign has a co-op object.
//---------------------------------------------------------------------------------------
class CoopTacticalController extends XComTacticalController config(CoopCampaign);

var config bool bGateSelection;

const LOAD_MOVIE = "CIN_XP_UI_LogoSpin.bk2";

var string LastLoadState;
var int LoadStateTicks;

simulated event PostBeginPlay()
{
	super.PostBeginPlay();
	SetTimer(1.0f, true, nameof(WatchLoadMovie));
}

// A mission is loaded with a hard map change; the strategy layer plays this movie for it
// (XGStrategy.LaunchTacticalBattle: PlaySpecificLoadingMovie + PlayLoadMapMovie). With a network
// connection open the engine does not report it as a loading movie, so CreateTacticalGame waits for it
// forever ("while (IsAnyMoviePlaying() && !IsLoadingMoviePlaying())") and HideLoadingScreen, which only
// handles loading movies, never stops it (seen 2026-11-12 with the game's own ruleset; stopping it lets the
// mission start). Stop it at that point, as HideLoadingScreen would.
function WatchLoadMovie()
{
	local X2TacticalGameRuleset Rules;

	Rules = `TACTICALRULES;
	LogLoadState(Rules);
	if (Rules == none)
	{
		return;
	}
	if (!Rules.IsInState('CreateTacticalGame') && !Rules.IsInState('LoadTacticalGame'))
	{
		ClearTimer(nameof(WatchLoadMovie));    // the mission has started
		return;
	}
	// A guest joins a running mission through LoadTacticalGame, whose begin block ends with the same
	// movie loop; there it comes after the load work, when bProcessingLoad is cleared.
	if (Rules.IsInState('LoadTacticalGame') && Rules.bProcessingLoad)
	{
		return;
	}
	// only once the map is generated and streamed, where CreateTacticalGame waits on the movie: stopping it
	// while the map was still generating crashed the host ("Object is not packaged:
	// XComGameState_EnvironmentDamage None" right after "Finished Map Streaming", test run 2026-11-12)
	if (`PARCELMGR == none || `PARCELMGR.IsGeneratingMap() || !class'XComMapManager'.static.IsStreamingComplete())
	{
		return;
	}
	if (`XCOMNETMANAGER.HasConnections() && class'XComEngine'.static.IsMoviePlaying(LOAD_MOVIE) && !class'XComEngine'.static.IsLoadingMoviePlaying())
	{
		`log("stopping the stuck mission load movie" @ LOAD_MOVIE @ "(network connection open)",, 'CoopTactical');
		class'XComEngine'.static.StopCurrentMovie();
	}
}

// Diagnostic while a mission loads (both copies): the conditions the ruleset's begin block waits on,
// logged when they change and every 10 s, so a stalled load shows what it waits for.
function LogLoadState(X2TacticalGameRuleset Rules)
{
	local string S;
	local XComPresentationLayer TacPres;

	if (Rules == none)
	{
		return;
	}
	TacPres = XComPresentationLayer(Pres);
	S = "state=" $ Rules.GetStateName()
		@ "gen=" $ (`PARCELMGR != none && `PARCELMGR.IsGeneratingMap())
		@ "streamed=" $ class'XComMapManager'.static.IsStreamingComplete()
		@ "uibusy=" $ (TacPres != none && TacPres.UIIsBusy())
		@ "visbusy=" $ Rules.WaitingForVisualizer()
		@ "movie=" $ class'XComEngine'.static.IsAnyMoviePlaying()
		@ "loadmovie=" $ class'XComEngine'.static.IsLoadingMoviePlaying()
		@ "paused=" $ (WorldInfo.Pauser != none)
		@ "frames=" $ `XCOMHISTORY.GetNumGameStates();
	LoadStateTicks++;
	if (S != LastLoadState || LoadStateTicks % 10 == 0)
	{
		`log("load state" @ S,, 'CoopTactical');
		LastLoadState = S;
	}
}

simulated function bool Visualizer_SelectUnit(XComGameState_Unit SelectedUnit)
{
	local int UnitOwner, Controller;
	local XComGameState_AIGroup Group;

	if (default.bGateSelection && SelectedUnit != none && SelectedUnit.GetTeam() == eTeam_XCom && class'CoopRole'.static.CoopActive())
	{
		UnitOwner = class'CoopOwnership'.static.OwnerOf(SelectedUnit);
		if (UnitOwner != class'CoopOwnership'.const.NO_OWNER)
		{
			// the owner controls the soldier; the host does while that guest is not connected
			Controller = class'CoopRole'.static.ControllerOf(UnitOwner);
		}
		else
		{
			// no owner (a soldier or VIP joining mid-mission, an alien a player mind-controls): the machine that runs
			// its group. Before 2026-11-17 anyone could select it (joinxcom: the guest selected a soldier dropped
			// into the host's group during its own turn).
			Group = SelectedUnit.GetGroupMembership();
			Controller = (Group != none) ? class'CoopTactical'.static.ControllerOfInitiative(Group) : class'XComGameState_CoopCampaign'.const.SLOT_HOST;
		}
		if (Controller != class'CoopRole'.static.LocalSlot())
		{
			`log("select blocked unit=" $ SelectedUnit.ObjectID @ "owner=" $ UnitOwner @ "controller=" $ Controller,, 'CoopTactical');
			return false;
		}
	}
	return super.Visualizer_SelectUnit(SelectedUnit);
}

// A dropped connection in a co-op mission is planned (the host builds missions and loads saves without one) and
// CoopLink reconnects by itself. The game's PvP handling must not run: it queues the "Opponent left" notice and
// starts an asynchronous PingMCP whose completion delegate points at this controller. The guest leaves the
// mission map at once, the controller is destroyed, and when the ping completes on the main menu the engine
// asserts ("Failed to find function None in XComMCP", UnObj.cpp:2456; runs midsave-20261113-114920,
// saveload-20261113-143352, midsave-20261113-144001). A race, so it hit only some runs.
simulated function LostConnection(EQuitReason Reason)
{
	if (class'CoopRole'.static.CoopActive())
	{
		`log("co-op: skipped the game's multiplayer lost-connection handling, reason=" $ Reason,, 'CoopTactical');
		return;
	}
	super.LostConnection(Reason);
}

auto state PlayerWaiting
{
	simulated function LostConnection(EQuitReason Reason)
	{
		if (class'CoopRole'.static.CoopActive())
		{
			`log("co-op: skipped the game's multiplayer lost-connection handling (waiting), reason=" $ Reason,, 'CoopTactical');
			return;
		}
		super.LostConnection(Reason);
	}
}

// Console command, bound to Alt + left click (Config/XComInput.ini): mark the tile under the 3D cursor for the
// other players, at the tile's centre.
// The tile under the mouse, picked as the game's own cursor picks it (XComTacticalHUD.GetMousePickActor): along the
// HUD's mouse ray (XComHUD keeps it every frame), skipping geometry the cursor ignores, walls and anything outside
// the level, and taking the first hit at or below the floor the game shows (the 3D cursor's requested floor; the
// floors above are cut away on screen). The 3D cursor itself stops following the mouse while another player plays
// (two PCs 2026-11-18: every ping of the watching host landed on one tile), and a plain first hit landed on
// cut-away roofs (the pings sat at the top of the map).
exec function CoopPing()
{
	local XComHUD MouseHUD;
	local XCom3DCursor Cursor;
	local XComLevelVolume LevelVolume;
	local Actor HitActor;
	local XComLevelActor LevelActor;
	local XComFracLevelActor FracActor;
	local TraceHitInfo HitInfo;
	local vector HitLocation, HitNormal, RayStart, BestLocation;
	local int HitFloor, BestFloor, Hits, NotPickable, Ignored, Walls, Outside;
	local bool bHaveBest;
	local TTile Tile;
	local string From;

	MouseHUD = XComHUD(myHUD);
	Cursor = GetCursor();
	LevelVolume = `LEVEL != none ? `LEVEL.LevelVolume : none;
	if (MouseHUD != none && Cursor != none && LevelVolume != none && VSize(MouseHUD.CachedMouseWorldDirection) > 0)
	{
		RayStart = MouseHUD.CachedMouseWorldOrigin;
		foreach TraceActors(class'Actor', HitActor, HitLocation, HitNormal, RayStart + MouseHUD.CachedMouseWorldDirection * 165536.f,
			RayStart, vect(0,0,0), HitInfo)
		{
			Hits++;
			if (IMouseInteractionInterface(HitActor) == none || XComUnitPawn(HitActor) != none)
			{
				NotPickable++;
				continue;
			}
			if (XComInteractiveLevelActor(HitActor) == none)
			{
				LevelActor = XComLevelActor(HitActor);
				FracActor = XComFracLevelActor(HitActor);
				if ((LevelActor != none && LevelActor.bIgnoreFor3DCursorCollision) || (FracActor != none && FracActor.bIgnoreFor3DCursorCollision))
				{
					Ignored++;
					continue;
				}
				if ((vect(0, 0, 1) dot HitNormal) < 0.2)    // a wall (XComTacticalHUD.MAXIMUM_PICK_SLOPE_COEFFICIENT)
				{
					Walls++;
					continue;
				}
			}
			if (!LevelVolume.ContainsPoint(HitLocation))
			{
				Outside++;
				continue;
			}
			HitFloor = Cursor.WorldZToFloor(HitLocation);
			if (HitFloor == Cursor.m_iRequestedFloor)
			{
				HitFloor = Cursor.WorldZToFloor(HitLocation + vect(0,0,16));
			}
			// the first hit, then a lower one while the best is above the shown floor
			if (!bHaveBest || (BestFloor > Cursor.m_iRequestedFloor && HitFloor < BestFloor))
			{
				bHaveBest = true;
				BestLocation = HitLocation;
				BestFloor = HitFloor;
				From = "mouse (" $ HitActor.Class.Name $ ", floor " $ HitFloor $ " of shown " $ Cursor.m_iRequestedFloor $ ")";
			}
		}
	}
	if (!bHaveBest && Cursor != none)
	{
		BestLocation = Cursor.Location;
		From = "cursor (mouse ray: " $ Hits @ "hits, not pickable" @ NotPickable $ ", ignored" @ Ignored $ ", walls" @ Walls
			$ ", outside the level" @ Outside $ ")";
		bHaveBest = true;
	}
	if (!bHaveBest)
	{
		`log("ping: no mouse hit and no cursor",, 'CoopPing');
		return;
	}
	Tile = `XWORLD.GetTileCoordinatesFromPosition(BestLocation);
	`log("ping from the" @ From @ "at tile" @ Tile.X $ "," $ Tile.Y $ "," $ Tile.Z,, 'CoopPing');
	class'CoopPing'.static.SendPing(`XWORLD.GetPositionFromTileCoordinates(Tile));
}

// Console command: "CoopChat" opens the chat input; "CoopChat some text" sends the text directly.
exec function CoopChat(optional string Text)
{
	if (Text == "")
	{
		class'CoopChat'.static.OpenInput();
	}
	else
	{
		class'CoopChat'.static.Say(Text);
	}
}

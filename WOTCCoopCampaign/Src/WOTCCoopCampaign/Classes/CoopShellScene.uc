//---------------------------------------------------------------------------------------
//  FILE:    CoopShellScene.uc
//  PURPOSE: Main menu scene: the player's own soldiers (the character pool) standing in the game's main menu
//           scene with their backs to the camera, looking out over it. Game assets only: the soldiers are the
//           game's soldier pawns (UIPawnMgr, as the character pool screen shows them), the scene is the game's
//           own main menu map. An empty character pool gets random soldiers for the scene only (never saved).
//           Placement: MenuSoldierCount soldiers in a row MenuSoldierDistance in front of the camera, on the floor
//           found by a trace straight down; a spot without a floor below is skipped.
//---------------------------------------------------------------------------------------
class CoopShellScene extends Actor config(CoopCampaign);

var config bool bMenuSoldiers;
var config int MenuSoldierCount;
var config float MenuSoldierDistance;     // unreal units in front of the camera
var config float MenuSoldierSpacing;      // between neighbours
var config float MenuSoldierDelay;        // seconds after the menu opens (the camera settles first)

var UIShell Shell;
var array<XComGameState_Unit> Units;
var int Placed;
var array<Vector> Floors;     // by unit index: the floor point under the soldier

function Init(UIShell InShell)
{
	Shell = InShell;
	SetTimer(FMax(default.MenuSoldierDelay, 0.1), false, nameof(Build));
}

function Build()
{
	local XComPlayerController PC;
	local Vector CamLoc, Forward, Right, Spot, Top, Bottom, HitLoc, HitNormal;
	local Rotator CamRot, Facing;
	local Actor Hit;
	local int i, Count, Try;
	local float Offset;
	local array<float> Tries;

	Tries.AddItem(0); Tries.AddItem(-120); Tries.AddItem(120); Tries.AddItem(-220); Tries.AddItem(240); Tries.AddItem(-300); Tries.AddItem(400);

	PC = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController());
	if (PC == none || Shell == none)
	{
		return;
	}
	PC.GetPlayerViewPoint(CamLoc, CamRot);
	Facing.Yaw = CamRot.Yaw;
	Forward = Vector(Facing);
	Right = Vector(Facing + rot(0, 16384, 0));
	PickUnits(Max(default.MenuSoldierCount, 1));
	Count = Units.Length;
	`log("menu scene: camera at" @ CamLoc @ "yaw=" $ CamRot.Yaw @ "pitch=" $ CamRot.Pitch @ "soldiers=" $ Count
		@ "from" @ ((`XENGINE.m_CharacterPoolManager.CharacterPool.Length > 0) ? "the character pool" : "random soldiers (empty pool)"),, 'CoopMenu');
	for (i = 0; i < Count; i++)
	{
		// a spot with a floor (the scene's meshes do not all block traces): the planned distance first, then
		// nearer and farther ones
		Offset = (float(i) - float(Count - 1) / 2.0f) * default.MenuSoldierSpacing;
		Hit = none;
		for (Try = 0; Try < 7 && Hit == none; Try++)
		{
			Spot = CamLoc + Forward * (default.MenuSoldierDistance + Tries[Try]) + Right * Offset;
			Top = Spot + vect(0, 0, 200);
			Bottom = Spot - vect(0, 0, 3000);
			Hit = Trace(HitLoc, HitNormal, Bottom, Top, false);
		}
		if (Hit == none)
		{
			`log("menu scene: no floor near spot" @ i,, 'CoopMenu');
			continue;
		}
		Floors.AddItem(HitLoc);
		Shell.Movie.Pres.GetUIPawnMgr().RequestPawnByState(self, Units[i], HitLoc, Facing, OnPawnReady);
		Placed++;
		`log("menu scene: soldier" @ i @ Units[i].GetFullName() @ "at" @ HitLoc @ "on" @ Hit,, 'CoopMenu');
	}
	`log("menu scene: placed" @ Placed @ "of" @ Count,, 'CoopMenu');
}

// A soldier's pawn is loaded: stand it on the floor, give it a weapon to hold and its idle, as the character pool
// screen does (XComCharacterCustomization.OnPawnVisualsCreated): pool soldiers have no inventory, so a loadout is
// made in a temporary game state for the weapon visuals and removed again.
function OnPawnReady(XComUnitPawn Pawn)
{
	local XComGameStateHistory History;
	local XComGameState TempState;
	local XComGameState_Unit Unit;
	local X2SoldierPersonalityTemplate Personality;
	local name Idle;
	local int i;

	for (i = 0; i < Units.Length; i++)
	{
		if (Units[i] != none && Units[i].ObjectID == Pawn.ObjectID)
		{
			Unit = Units[i];
			break;
		}
	}
	if (Unit == none || i >= Floors.Length)
	{
		return;
	}
	Pawn.SetLocation(Floors[i] + vect(0, 0, 1) * Pawn.CylinderComponent.CollisionHeight);
	Pawn.GotoState('CharacterCustomization');
	History = `XCOMHISTORY;
	TempState = History.CreateNewGameState(true, class'XComGameStateContext_ChangeContainer'.static.CreateEmptyChangeContainer("Coop menu scene loadout"));
	Unit.ApplyInventoryLoadout(TempState);
	History.AddGameStateToHistory(TempState);
	Pawn.CreateVisualInventoryAttachments(Shell.Movie.Pres.GetUIPawnMgr(), Unit, TempState);
	History.ObliterateGameStatesFromHistory(1);
	Unit.EmptyInventoryItems();
	Personality = Unit.GetPersonalityTemplate();
	Idle = (Personality != none) ? Personality.IdleAnimName : '';
	Pawn.PlayHQIdleAnim(Idle);
	`log("menu scene: soldier" @ i @ "ready at" @ Pawn.Location @ "idle=" $ Idle,, 'CoopMenu');
}

// "@sceneactors": the actors that tell where the menu scene's floor and figures are (marker points, posed
// characters, pawns) within 3000 units of the camera.
static function LogSceneActors()
{
	local Actor A;
	local Vector CamLoc;
	local Rotator CamRot;
	local XComPlayerController PC;
	local int Count;

	PC = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController());
	PC.GetPlayerViewPoint(CamLoc, CamRot);
	foreach class'WorldInfo'.static.GetWorldInfo().AllActors(class'Actor', A)
	{
		if ((PointInSpace(A) == none && SkeletalMeshActor(A) == none && Pawn(A) == none && CameraActor(A) == none)
			|| VSize(A.Location - CamLoc) > 3000)
		{
			continue;
		}
		Count++;
		`log("scene actor:" @ A.Class.Name @ A.Name @ "tag=" $ A.Tag @ "at" @ A.Location @ "dist=" $ int(VSize(A.Location - CamLoc))
			@ "hidden=" $ A.bHidden,, 'CoopMenu');
	}
	`log("scene actors:" @ Count @ "near the camera at" @ CamLoc @ "map=" $ class'WorldInfo'.static.GetWorldInfo().GetMapName(),, 'CoopMenu');
}

// The character pool's soldiers (newest first is the pool's order), else random soldiers made for the scene only.
function PickUnits(int Want)
{
	local CharacterPoolManager Pool;
	local XComGameState_Unit Unit;
	local int i;

	Pool = `XENGINE.m_CharacterPoolManager;
	for (i = 0; i < Pool.CharacterPool.Length && Units.Length < Want; i++)
	{
		Unit = Pool.CharacterPool[i];
		if (Unit != none && Unit.bAllowedTypeSoldier)
		{
			Units.AddItem(Unit);
		}
	}
	while (Units.Length < Want && Pool.CharacterPool.Length == 0)
	{
		Unit = Pool.CreateSoldier('Soldier');    // not added to the pool, not saved
		if (Unit == none)
		{
			break;
		}
		Units.AddItem(Unit);
	}
}

defaultproperties
{
	bHidden = true
}

//---------------------------------------------------------------------------------------
//  FILE:    CoopActionWatch.uc
//  PURPOSE: Test probe ("@actionwatch SECONDS"): for that long, polls 5 times a second and logs each visualization
//           action class (X2Action is an actor) and each cinematic actor the first time it appears on this
//           machine, so a test can tell whether a story moment (a narrative, a matinee) played here.
//---------------------------------------------------------------------------------------
class CoopActionWatch extends Actor;

var array<name> Seen;
var float EndAt;
var int Polls;
var array<Actor> SeenKey;

static function Start(float Seconds)
{
	local CoopActionWatch Watch;

	Watch = class'WorldInfo'.static.GetWorldInfo().Spawn(class'CoopActionWatch');
	Watch.EndAt = Watch.WorldInfo.RealTimeSeconds + Seconds;
	Watch.SetTimer(0.2f, true, nameof(Poll));
	`log("actionwatch started for" @ int(Seconds) @ "s",, 'CoopContent');
}

function Note(Actor A, string Kind)
{
	local name C;

	C = A.Class.Name;
	// story and movement actions: every new instance, with its time (the others: the first of each class)
	if (C == 'X2Action_PlayNarrative' || C == 'X2Action_PlayMatinee' || C == 'X2Action_CameraFade' || C == 'X2Action_Interact'
		|| C == 'X2Action_MoveBegin' || C == 'X2Action_StartCinescriptCamera')
	{
		if (SeenKey.Find(A) == INDEX_NONE)
		{
			SeenKey.AddItem(A);
			`log("actionwatch instance" @ C @ "(" $ A.Name $ ")",, 'CoopContent');
		}
	}
	if (Seen.Find(C) != INDEX_NONE)
	{
		return;
	}
	Seen.AddItem(A.Class.Name);
	`log("actionwatch saw" @ Kind @ A.Class.Name @ "(" $ A.Name $ ")",, 'CoopContent');
}

function Poll()
{
	local X2Action Action;
	local SkeletalMeshCinematicActor Cine;

	Polls++;
	foreach AllActors(class'X2Action', Action)
	{
		Note(Action, "action");
	}
	foreach AllActors(class'SkeletalMeshCinematicActor', Cine)
	{
		Note(Cine, "cinematic");
	}
	if (WorldInfo.RealTimeSeconds >= EndAt)
	{
		`log("actionwatch done: polls=" $ Polls @ "classes=" $ Seen.Length,, 'CoopContent');
		ClearTimer(nameof(Poll));
		Destroy();
	}
}

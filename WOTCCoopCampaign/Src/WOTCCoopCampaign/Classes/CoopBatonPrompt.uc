//---------------------------------------------------------------------------------------
//  FILE:    CoopBatonPrompt.uc
//  PURPOSE: The holder of the baton (control on the Avenger) is asked before a guest gets it: "Player 2 asks for
//           control. Hand it over?" Yes hands it over (once the holder's own edit screens are closed), No tells the
//           asker. Forced requests (the host; a guest for its own soldiers) never come here (CoopSession).
//---------------------------------------------------------------------------------------
class CoopBatonPrompt extends Object config(CoopCampaign);

var config bool bOpen;       // a prompt is up
var config int AskingSlot;

static function Ask(int FromSlot)
{
	local TDialogueBoxData Data;
	local CoopBatonPrompt Prompt;

	if (default.bOpen)
	{
		`log("baton prompt: already asking; this request waits",, 'CoopCampaign');
		return;
	}
	default.bOpen = true;
	default.AskingSlot = FromSlot;
	`log("baton prompt: player" @ FromSlot @ "asks for control",, 'CoopCampaign');
	if (`PRESBASE == none)
	{
		Answer(true);
		return;
	}
	Prompt = new class'CoopBatonPrompt';
	Data.eType = eDialog_Normal;
	Data.strTitle = "Hand over control?";
	Data.strText = class'CoopRoster'.static.DisplayName(FromSlot) @ "(" $ class'CoopRoster'.static.SlotLabel(FromSlot)
		$ ") asks for control of the Avenger.";
	Data.strAccept = "Hand it over";
	Data.strCancel = "Keep it";
	Data.fnCallback = Prompt.OnAnswer;
	`PRESBASE.UIRaiseDialog(Data);
}

function OnAnswer(Name eAction)
{
	Answer(eAction == 'eUIAction_Accept');
}

// Also the test harness ("@batonanswer yes|no").
static function Answer(bool bYes)
{
	local array<byte> Params;

	if (!default.bOpen)
	{
		return;
	}
	default.bOpen = false;
	`log("baton prompt answered:" @ (bYes ? "hand it over" : "keep it"),, 'CoopCampaign');
	if (!class'CoopSession'.default.bHasBaton)
	{
		return;
	}
	if (!bYes)
	{
		`XCOMNETMANAGER.SendRemoteCommand("CoopBatonDenied", Params);
		return;
	}
	if (class'CoopEditGate'.static.IsEditing())
	{
		class'CoopSession'.default.bGrantRequested = true;    // granted when the last edit screen closes
		`XCOMNETMANAGER.SendRemoteCommand("CoopBatonDeferred", Params);
		return;
	}
	class'CoopSession'.static.GrantBaton();
}

// The harness closes the dialog itself before answering.
static function CloseDialog()
{
	if (`PRESBASE != none && `PRESBASE.Get2DMovie() != none && `PRESBASE.Get2DMovie().DialogBox != none)
	{
		`PRESBASE.Get2DMovie().DialogBox.RemoveDialog();
	}
}

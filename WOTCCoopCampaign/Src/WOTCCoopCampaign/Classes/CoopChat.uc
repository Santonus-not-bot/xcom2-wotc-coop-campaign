//---------------------------------------------------------------------------------------
//  FILE:    CoopChat.uc
//  PURPOSE: Text chat between players: "CoopChat"(slot, text). Typing opens the game's text
//           input dialog (UIInputDialog); received lines show as a notice (Notify) and in the
//           log. With 3-4 players the host forwards a guest's line to the other guests.
//           Opened from the Avenger HUD's "Chat" button (added by CoopStatusPanel) or the
//           mission console command CoopChat (CoopTacticalController).
//           A plain Object (delegates on the network manager must not point at Actors).
//---------------------------------------------------------------------------------------
class CoopChat extends Object config(CoopCampaign);

const MAX_CHARS = 120;

var config bool bInited;   // config only so the default may be written

static function Init()
{
	local CoopChat Chat;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	Chat = new class'CoopChat';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Chat.OnRemoteCommand);
}

static function OpenInput()
{
	local TInputDialogData Data;
	local XComPresentationLayerBase Pres;

	Pres = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres;
	if (Pres == none)
	{
		return;
	}
	Data.strTitle = "Co-op chat";
	Data.iMaxChars = MAX_CHARS;
	Data.DialogType = eDialogType_SingleLine;
	Data.fnCallbackAccepted = OnTextAccepted;
	Pres.UIInputDialog(Data);
}

static function OnTextAccepted(string Text)
{
	Say(Text);
}

static function Say(string Text)
{
	Text = Left(Text, MAX_CHARS);
	if (Text == "")
	{
		return;
	}
	Init();
	Send(class'CoopRole'.static.LocalSlot(), Text);
	Show(class'CoopRole'.static.LocalSlot(), Text);
}

static function Send(int Slot, string Text)
{
	local array<byte> Params;

	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Slot, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(Text, Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopChat", Params);
}

static function Show(int Slot, string Text)
{
	local XComPresentationLayerBase Pres;
	local string Line;

	Line = class'UIScreenListener_CoopOwnerButton'.static.SlotName(Slot) $ ":" @ Text;
	`log("chat" @ Line,, 'CoopChat');
	Pres = XComPlayerController(class'WorldInfo'.static.GetWorldInfo().GetALocalPlayerController()).Pres;
	if (Pres != none)
	{
		Pres.Notify(Line);
	}
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local int Slot;
	local string Text;

	if (Command != "CoopChat")
	{
		return;
	}
	Slot = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	Text = Left(class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams), MAX_CHARS);
	Show(Slot, Text);
	if (!class'CoopRole'.static.IsGuest() && class'CoopRole'.default.ConnectedSlots.Length > 1)
	{
		Send(Slot, Text);   // forward to the other guests
	}
}

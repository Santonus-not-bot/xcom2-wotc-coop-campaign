//---------------------------------------------------------------------------------------
//  FILE:    CoopTurnBannerPanel.uc
//  PURPOSE: The "YOUR TURN" / "PLAYER 2'S TURN" text of CoopTurnBanner, drawn by the mod: a box at the
//           top of the screen, below the turn order icons. "YOUR TURN" for a few seconds; another player's turn
//           stays up while that player plays (a two-PC test: the host's player missed a 3.5 s "PLAYER 2'S TURN"
//           and saw nothing telling them the guest was playing), until the next banner or an enemy turn. The game's own turn overlay
//           draws no text at the start of an XCom turn (XComPresentationLayer.UIEndTurn: "do not show any
//           banner for the start of the XCom turn"), so text set on it never showed (screenshots of run
//           mission-20261113-102541). A child of the turn overlay screen, which stays visible on every
//           machine, also while the tactical HUD is hidden on a watching player's screen.
//---------------------------------------------------------------------------------------
class CoopTurnBannerPanel extends UIPanel;

const BANNER_WIDTH = 460;
const BANNER_HEIGHT = 54;
const BANNER_SECONDS = 3.5;

var UIBGBox Box;
var UIText Label;

simulated function CoopTurnBannerPanel InitBanner()
{
	InitPanel('CoopTurnBanner');
	AnchorTopCenter();
	SetSize(BANNER_WIDTH, BANNER_HEIGHT);
	SetPosition(-BANNER_WIDTH / 2, 120);
	Box = Spawn(class'UIBGBox', self);
	Box.InitBG('CoopTurnBannerBox', 0, 0, BANNER_WIDTH, BANNER_HEIGHT, eUIState_Normal);
	Label = Spawn(class'UIText', self);
	Label.InitText('CoopTurnBannerText');
	Label.SetPosition(0, 6);
	Label.SetWidth(BANNER_WIDTH);
	Hide();
	return self;
}

// Shows Text in the player's color, for a few seconds or (bStay) until hidden.
simulated function ShowText(string Text, string HexColor, optional bool bStay)
{
	Label.SetHTMLText("<p align='CENTER'><font size='30' color='#" $ HexColor $ "'><b>" $ Text $ "</b></font></p>");
	Show();
	ClearTimer(nameof(HideBanner));
	if (!bStay)
	{
		SetTimer(BANNER_SECONDS, false, nameof(HideBanner));
	}
}

simulated function HideBanner()
{
	if (bIsVisible)
	{
		`log("turn banner hidden",, 'CoopBanner');
	}
	Hide();
}

//---------------------------------------------------------------------------------------
//  FILE:    CoopGeoWatch.uc
//  PURPOSE: Everyone may open the Geoscape; only the player holding control (the baton) runs its clock, the others
//           watch time pass on the same Geoscape.
//           The holder, while its Geoscape is open, sends its clock every second ("CoopGeoTime": time of day, day,
//           month, year, time scale). A watcher keeps its own Geoscape paused (time scale 0, so it advances nothing
//           and writes no game state: XGGeoscape.Tick then only refreshes the visuals) and sets its clock and the
//           Earth's day/night to the holder's. What changes on the map (missions, scans finished) reaches it with the
//           holder's merges as before.
//           A plain Object; the state lives in class defaults.
//---------------------------------------------------------------------------------------
class CoopGeoWatch extends Object config(CoopCampaign);

var config bool bInited;
var config bool bHaveHostTime;
var config float HostTime;
var config int HostDay, HostMonth, HostYear;
var config float HostScale;
var config int HostAt;          // clock seconds of the last host time (CoopMissionLoading.ClockSeconds)
var config bool bWatching;      // for the log: this guest is watching

static function Init()
{
	local CoopGeoWatch Listener;

	if (default.bInited)
	{
		return;
	}
	default.bInited = true;
	Listener = new class'CoopGeoWatch';
	`XCOMNETMANAGER.AddReceiveRemoteCommandDelegate(Listener.OnRemoteCommand);
}

static function bool GeoscapeOpen()
{
	return `HQPRES != none && `HQPRES.ScreenStack != none && `HQPRES.ScreenStack.GetFirstInstanceOf(class'UIStrategyMap') != none;
}

// CoopLink.Tick, every second: the holder of the baton on its Geoscape sends its clock.
static function HostTick()
{
	local XGGeoscape Geo;
	local array<byte> Params;

	if (!class'CoopSession'.default.bHasBaton || !class'CoopSession'.static.IsConnected() || `HQGAME == none || !GeoscapeOpen())
	{
		return;
	}
	Init();
	Geo = `GAME.GetGeoscape();
	if (Geo == none)
	{
		return;
	}
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(Geo.m_kDateTime.m_fTime), Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Geo.m_kDateTime.m_iDay, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Geo.m_kDateTime.m_iMonth, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_Int(Geo.m_kDateTime.m_iYear, Params);
	class'XComGameStateNetworkManager'.static.AddCommandParam_String(string(Geo.m_fTimeScale), Params);
	`XCOMNETMANAGER.SendRemoteCommand("CoopGeoTime", Params);
}

// CoopHUDScreen, ten times a second on the Avenger: whoever does not hold the baton watches.
static function GuestTick()
{
	local XGGeoscape Geo;
	local bool bWatch;

	Init();
	bWatch = class'CoopSession'.static.IsConnected() && !class'CoopSession'.default.bHasBaton && `HQGAME != none && GeoscapeOpen();
	if (bWatch != default.bWatching)
	{
		default.bWatching = bWatch;
		`log("geoscape:" @ (bWatch ? "watching the Geoscape of the player in control" : "not watching"),, 'CoopGeo');
		if (!bWatch && class'CoopSession'.default.bHasBaton && `HQGAME != none && GeoscapeOpen() && `GAME.GetGeoscape() != none
			&& `GAME.GetGeoscape().m_fTimeScale == 0)
		{
			`GAME.GetGeoscape().Resume();    // control arrived while watching: our clock runs again
		}
	}
	if (!bWatch)
	{
		return;
	}
	Geo = `GAME.GetGeoscape();
	if (Geo == none)
	{
		return;
	}
	Geo.m_fTimeScale = 0;    // XGGeoscape.PAUSED: no local time, no game state; the visuals still refresh
	if (default.bHaveHostTime)
	{
		Geo.m_kDateTime.m_fTime = default.HostTime;
		Geo.m_kDateTime.m_iDay = default.HostDay;
		Geo.m_kDateTime.m_iMonth = default.HostMonth;
		Geo.m_kDateTime.m_iYear = default.HostYear;
		`STRATEGYRULES.GameTime = Geo.m_kDateTime;
		if (`EARTH != none)
		{
			`EARTH.SetTime(Geo.m_kDateTime);
		}
	}
}

function OnRemoteCommand(string Command, array<byte> RawParams)
{
	local float NewTime;

	if (Command != "CoopGeoTime")
	{
		return;
	}
	NewTime = float(class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams));
	default.HostDay = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	default.HostMonth = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	default.HostYear = class'XComGameStateNetworkManager'.static.GetCommandParam_Int(RawParams);
	default.HostScale = float(class'XComGameStateNetworkManager'.static.GetCommandParam_String(RawParams));
	if (!default.bHaveHostTime)
	{
		`log("geoscape: host clock received" @ default.HostYear $ "-" $ default.HostMonth $ "-" $ default.HostDay @ int(NewTime) @ "scale" @ default.HostScale,, 'CoopGeo');
	}
	default.HostTime = NewTime;
	default.bHaveHostTime = true;
	default.HostAt = class'CoopMissionLoading'.static.ClockSeconds();
}

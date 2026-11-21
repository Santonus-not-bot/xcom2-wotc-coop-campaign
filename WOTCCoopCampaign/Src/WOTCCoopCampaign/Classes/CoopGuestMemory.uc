//---------------------------------------------------------------------------------------
//  FILE:    CoopGuestMemory.uc
//  PURPOSE: A guest remembers, across game restarts, which player slot it had with which host
//           (XComCoopGuest.ini in the player's config folder). Soldiers belong to slots, so a
//           guest that restarts its game and joins the same host again asks for its old slot
//           and gets its soldiers back, even when several guests rejoin in another order.
//           Its own class and file: CoopLink's runtime state is config only so its defaults may
//           be written, and must never be saved.
//---------------------------------------------------------------------------------------
class CoopGuestMemory extends Object config(CoopGuest);

var config string LastHost;
var config int LastPort;
var config int LastSlot;

static function Remember(string Host, int Port, int Slot)
{
	if (Host == "" || Slot <= 0 || (Host == default.LastHost && Port == default.LastPort && Slot == default.LastSlot))
	{
		return;
	}
	default.LastHost = Host;
	default.LastPort = Port;
	default.LastSlot = Slot;
	StaticSaveConfig();
	`log("remembered: player" @ Slot @ "with this host",, 'CoopLink');
}

// The slot to ask this host for, 0 = any.
static function int SlotFor(string Host, int Port)
{
	return (Host != "" && Host == default.LastHost && Port == default.LastPort) ? default.LastSlot : 0;
}

"""CoopSync: make a joining player's XCOM 2 WOTC mods match the host's.

Runs outside the game, before it starts (mods load only at game start).

    # host: describe the active mods (name, Workshop id, version fingerprint)
    python -I coopsync.py manifest --game <WOTC dir> --workshop <steamapps/workshop/content/268500> --modoptions <XComModOptions.ini> --out host.json
    # guest: the same on their PC, then compare
    python -I coopsync.py manifest ... --out guest.json
    python -I coopsync.py diff host.json guest.json            # what differs (exit 1 when anything does)
    python -I coopsync.py plan host.json guest.json            # what to subscribe, the ActiveMods to write
    # guest, after downloads: write the host's ActiveMods (backs up the old file)
    python -I coopsync.py write-modoptions --ini <XComModOptions.ini> --manifest host.json
    # mod settings (Mod Config Menu and other per-player settings), host -> guest
    python -I coopsync.py settings-export --manifest host.json --userconfig <host user config dir> --out settings.json
    python -I coopsync.py write-settings --userconfig <guest user config dir> --settings settings.json
    # in-game route (the mod's CoopSyncData): the host's list goes into the user config before the game starts,
    # the host's game sends it to a guest it refuses, the guest's game saves it; then on the guest's PC:
    python -I coopsync.py host-export --manifest host.json --userconfig <host user config dir>
    python -I coopsync.py sync --userconfig <guest user config dir> --game <WOTC dir> --workshop <...> --modoptions <XComModOptions.ini> [--steam-api <dll> --yes-use-my-steam-account]
    # guest: subscribe through Steam (uses the logged-in Steam account; needs Steam running)
    python -I coopsync.py subscribe --steam-api <WOTC dir>/Binaries/Win64/steam_api64.dll --ids 123,456 --yes-use-my-steam-account

Mod identity: the active mod name is the .XComMod file name. A Workshop mod lives in
<workshop>/<WorkshopId>/<Name>.XComMod (the publishedFileId= line inside can be 0, so the folder
name is the id). A local mod lives in <game>/XComGame/Mods/<Name>/<Name>.XComMod.
Version fingerprint: SHA-256 over the names and hashes of the mod's Script/*.u, Config and
Localization files and the .XComMod (content packages are listed by name and size only).
"""
from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

MANIFEST_VERSION = 1
HASHED_DIRS = ("Script", "Config", "Localization")


# ----------------------------------------------------------------------------------- reading

def read_active_mods(ini: Path) -> List[str]:
    """ActiveMods entries of [Engine.XComModOptions], in file order, duplicates dropped."""
    mods: List[str] = []
    section = ""
    for raw in ini.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith(";"):
            continue
        m = re.match(r"^\[(.+)\]$", line)
        if m:
            section = m.group(1).strip()
            continue
        if section.lower() != "engine.xcommodoptions":
            continue
        m = re.match(r'^[+.]?ActiveMods\s*=\s*"?([^"]*)"?\s*$', line, re.I)
        if m and m.group(1) and m.group(1) not in mods:
            mods.append(m.group(1))
    return mods


def read_xcommod(path: Path) -> Dict[str, str]:
    """Key/values of a .XComMod file ([mod] section, like an ini)."""
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    try:
        cp.read_string(path.read_text(encoding="utf-8-sig", errors="replace"))
    except configparser.Error:
        return {}
    return dict(cp["mod"]) if cp.has_section("mod") else {}


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def fingerprint(mod_dir: Path, xcommod: Path) -> str:
    h = hashlib.sha256()
    h.update(b"xcommod:" + sha256_file(xcommod).encode())
    for p in sorted(mod_dir.rglob("*"), key=lambda q: q.relative_to(mod_dir).as_posix().lower()):
        if not p.is_file():
            continue
        rel = p.relative_to(mod_dir).as_posix()
        top = rel.split("/", 1)[0]
        if top in HASHED_DIRS:
            h.update(f"\n{rel.lower()}:{sha256_file(p)}".encode())
        elif top in ("Content", "CookedPCConsole"):
            h.update(f"\n{rel.lower()}:size={p.stat().st_size}".encode())
    return h.hexdigest()


def index_mods(game: Optional[Path], workshop: Optional[Path]) -> Dict[str, Dict]:
    """Every installed mod by name (lower case). Local mods win over Workshop copies, as in the game's Mods folder."""
    found: Dict[str, Dict] = {}
    if workshop and workshop.is_dir():
        for d in sorted(workshop.iterdir()):
            if not d.is_dir() or not d.name.isdigit():
                continue
            for x in d.glob("*.XComMod"):
                found.setdefault(x.stem.lower(), {"name": x.stem, "source": "workshop", "workshop_id": d.name, "dir": d, "xcommod": x})
    if game:
        mods_root = game / "XComGame" / "Mods"
        if mods_root.is_dir():
            for d in sorted(mods_root.iterdir()):
                x = d / f"{d.name}.XComMod"
                if d.is_dir() and x.is_file():
                    found[d.name.lower()] = {"name": d.name, "source": "local", "workshop_id": None, "dir": d, "xcommod": x}
    return found


def mod_config_names(mod_dir: Path) -> List[str]:
    """The mod's own config files (Config/*.ini). The game writes the player's settings for them into
    the user config folder under the same names (e.g. Config/XComFoo.ini -> <user config>/XComFoo.ini)."""
    cfg = mod_dir / "Config"
    return sorted(p.name for p in cfg.glob("*.ini")) if cfg.is_dir() else []


def export_settings(manifest: Dict, user_config: Path) -> Dict:
    """Host side: the current user config files of the active mods (only those that exist)."""
    files: Dict[str, str] = {}
    for m in manifest["active_mods"]:
        for name in m.get("config_files", []):
            p = user_config / name
            if p.is_file() and name not in files:
                files[name] = p.read_text(encoding="utf-8-sig", errors="replace")
    return {"coopsync_settings": MANIFEST_VERSION, "created": time.strftime("%Y-%m-%dT%H:%M:%S"), "files": files}


def write_settings(user_config: Path, settings: Dict, protected: List[Path]) -> List[str]:
    """Guest side: write the host's mod settings files; each existing file is backed up first.
    Refuses the protected folders and hard-linked files (nothing is written then). Returns the written names."""
    user_config = user_config.resolve()
    for p in protected:
        try:
            user_config.relative_to(p.resolve())
            raise Refused(f"{user_config} is inside the protected folder {p}")
        except ValueError:
            pass
    names = sorted(settings.get("files", {}))
    for name in names:
        if Path(name).name != name or not name.lower().endswith(".ini"):
            raise Refused(f"not a plain .ini file name: {name!r}")
        target = user_config / name
        if target.exists() and os.stat(target).st_nlink > 1:
            raise Refused(f"{target} has {os.stat(target).st_nlink} hard links")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    user_config.mkdir(parents=True, exist_ok=True)
    for name in names:
        target = user_config / name
        if target.exists():
            target.with_suffix(target.suffix + f".coopsync-{stamp}.bak").write_bytes(target.read_bytes())
            target.unlink()
        target.write_text(settings["files"][name], encoding="utf-8", newline="")
    return names


def build_manifest(game: Optional[Path], workshop: Optional[Path], modoptions: Path) -> Dict:
    active = read_active_mods(modoptions)
    index = index_mods(game, workshop)
    mods = []
    for name in active:
        m = index.get(name.lower())
        if m is None:
            mods.append({"name": name, "source": "missing", "workshop_id": None, "title": "", "version": None})
            continue
        meta = read_xcommod(m["xcommod"])
        wid = m["workshop_id"]
        pid = meta.get("publishedFileId", "0").strip()
        if wid is None and pid.isdigit() and pid != "0":
            wid = pid            # a local copy of a Workshop mod that records its id
        mods.append({"name": m["name"], "source": m["source"], "workshop_id": wid, "title": meta.get("Title", ""),
                     "version": fingerprint(m["dir"], m["xcommod"]), "config_files": mod_config_names(m["dir"])})
    return {"coopsync": MANIFEST_VERSION, "created": time.strftime("%Y-%m-%dT%H:%M:%S"), "active_mods": mods}


# ----------------------------------------------------------------------------------- comparing

def diff(host: Dict, guest: Dict) -> Dict[str, List[Dict]]:
    """What the guest must change to match the host. Names compare case-insensitively."""
    g = {m["name"].lower(): m for m in guest["active_mods"]}
    h = {m["name"].lower(): m for m in host["active_mods"]}
    out: Dict[str, List[Dict]] = {"missing": [], "version": [], "extra": [], "host_missing": []}
    for key, hm in h.items():
        if hm["source"] == "missing":
            out["host_missing"].append(hm)          # active on the host but not installed there
            continue
        gm = g.get(key)
        if gm is None or gm["source"] == "missing":
            out["missing"].append(hm)
        elif hm.get("version") and gm["version"] != hm["version"]:    # no version: the host sent names only
            out["version"].append({"name": hm["name"], "workshop_id": hm["workshop_id"] or gm["workshop_id"],
                                   "host": hm["version"], "guest": gm["version"]})
    for key, gm in g.items():
        if key not in h and gm["source"] != "missing":
            out["extra"].append(gm)
    return out


def plan(host: Dict, guest: Dict) -> Dict:
    d = diff(host, guest)
    subscribe = sorted({m["workshop_id"] for m in d["missing"] if m["workshop_id"]}, key=int)
    unfetchable = [m["name"] for m in d["missing"] if not m["workshop_id"]]
    update = sorted({m["workshop_id"] for m in d["version"] if m["workshop_id"]}, key=int)
    return {
        "subscribe": subscribe,                 # Workshop ids the guest lacks
        "update": update,                       # same mod, different files: let Steam update, or the host is outdated
        "cannot_fetch": unfetchable,            # local-only mods: the host must share them some other way
        "deactivate": [m["name"] for m in d["extra"]],
        "active_mods": [m["name"] for m in host["active_mods"] if m["source"] != "missing"],
        "host_problems": [m["name"] for m in d["host_missing"]],
        "ok": not any(d[k] for k in ("missing", "version", "extra")),
    }


# ----------------------------------------------------------------------------------- writing

class Refused(Exception):
    pass


def write_modoptions(ini: Path, active: List[str], protected: List[Path]) -> Path:
    """Write ActiveMods (host order) into ini; keep other sections. Returns the backup path."""
    ini = ini.resolve()
    for p in protected:
        try:
            ini.relative_to(p.resolve())
            raise Refused(f"{ini} is inside the protected folder {p}")
        except ValueError:
            pass
    if ini.exists() and os.stat(ini).st_nlink > 1:
        raise Refused(f"{ini} has {os.stat(ini).st_nlink} hard links; writing it would change another copy")
    old = ini.read_text(encoding="utf-8-sig", errors="replace") if ini.exists() else ""
    kept, section = [], ""
    for raw in old.splitlines():
        m = re.match(r"^\s*\[(.+)\]\s*$", raw)
        if m:
            section = m.group(1).strip()
        if section.lower() == "engine.xcommodoptions" and re.match(r'^\s*[+.]?ActiveMods\s*=', raw, re.I):
            continue
        kept.append(raw)
    text = "\r\n".join(kept)
    body = "".join(f"\r\nActiveMods={n}" for n in active)
    if re.search(r"^\s*\[Engine\.XComModOptions\]\s*$", text, re.I | re.M):
        text = re.sub(r"(^\s*\[Engine\.XComModOptions\]\s*$)", lambda m: m.group(1) + body, text, count=1, flags=re.I | re.M)
    else:
        text = (text + "\r\n" if text.strip() else "") + "[Engine.XComModOptions]" + body
    backup = ini.with_suffix(ini.suffix + f".coopsync-{time.strftime('%Y%m%d-%H%M%S')}.bak")
    if ini.exists():
        backup.write_bytes(ini.read_bytes())
    tmp = ini.with_suffix(ini.suffix + ".tmp")
    tmp.write_text(text + "\r\n", encoding="ascii", errors="strict", newline="")
    if ini.exists():
        ini.unlink()                 # never write through an existing name
    tmp.rename(ini)
    return backup


def default_protected() -> List[Path]:
    home = Path(os.environ.get("USERPROFILE", str(Path.home())))
    return [home / "Documents" / "My Games" / "XCOM2 War of the Chosen", home / "Documents" / "My Games" / "XCOM2"]


# ----------------------------------------------------------------------------------- the game's list (XComCoopSync.ini)

SYNC_INI = "XComCoopSync.ini"
SYNC_SECTION = "WOTCCoopCampaign.CoopSyncData"


def _check_writable(path: Path, protected: List[Path]) -> None:
    path = path.resolve()
    for p in protected:
        try:
            path.relative_to(p.resolve())
            raise Refused(f"{path} is inside the protected folder {p}")
        except ValueError:
            pass
    if path.exists() and os.stat(path).st_nlink > 1:
        raise Refused(f"{path} has {os.stat(path).st_nlink} hard links")


def write_host_list(user_config: Path, manifest: Dict, protected: List[Path]) -> Path:
    """Host side: the active mods with Workshop ids and fingerprints, for the mod to send (CoopSyncData.HostMods).
    Other sections and keys of the file are kept. Returns the file written."""
    ini = user_config / SYNC_INI
    _check_writable(ini, protected)
    old = ini.read_text(encoding="utf-8-sig", errors="replace") if ini.exists() else ""
    kept, section = [], ""
    for raw in old.splitlines():
        m = re.match(r"^\s*\[(.+)\]\s*$", raw)
        if m:
            section = m.group(1).strip()
        if section.lower() == SYNC_SECTION.lower() and re.match(r"^\s*[+.!-]?HostMods\s*=", raw, re.I):
            continue
        kept.append(raw)
    for m in manifest["active_mods"]:
        for field in ("name", "workshop_id", "version"):
            if any(c in str(m.get(field) or "") for c in '";|\r\n'):
                raise Refused(f"mod {m['name']!r}: {field} has a character the game's list cannot carry")
    # plain repeated "HostMods=" lines, as the game writes arrays itself: this file has no default to merge with,
    # and a "+HostMods=" line was not read at all (2026-11-17: the host loaded 0 entries)
    body = "".join(f'\r\nHostMods=(ModName="{m["name"]}",WorkshopId="{m["workshop_id"] or ""}",Version="{m["version"] or ""}")'
                   for m in manifest["active_mods"] if m["source"] != "missing")
    text = "\r\n".join(kept)
    head = re.compile(r"(^\s*\[" + re.escape(SYNC_SECTION) + r"\]\s*$)", re.I | re.M)
    if head.search(text):
        text = head.sub(lambda mm: mm.group(1) + body, text, count=1)
    else:
        text = (text + "\r\n" if text.strip() else "") + f"[{SYNC_SECTION}]" + body
    user_config.mkdir(parents=True, exist_ok=True)
    tmp = ini.with_suffix(".tmp")
    tmp.write_text(text + "\r\n", encoding="utf-8", newline="")
    if ini.exists():
        ini.unlink()
    tmp.rename(ini)
    return ini


def read_sync_list(user_config: Path, key: str) -> List[Dict]:
    """Entries of CoopSyncData.<key> (HostMods or ReceivedMods) in XComCoopSync.ini, in file order."""
    ini = user_config / SYNC_INI
    if not ini.is_file():
        return []
    out, section = [], ""
    for raw in ini.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        line = raw.strip()
        m = re.match(r"^\[(.+)\]$", line)
        if m:
            section = m.group(1).strip()
            continue
        if section.lower() != SYNC_SECTION.lower():
            continue
        m = re.match(r"^[+.]?" + re.escape(key) + r"\s*=\s*\((.*)\)\s*$", line, re.I)
        if not m:
            continue
        # the game writes strings quoted and empty ones bare: ReceivedMods=(ModName="A",WorkshopId=,Version=)
        fields = {k: (q if q or v.startswith('"') else v).strip()
                  for k, v, q in re.findall(r'(\w+)\s*=\s*("([^"]*)"|[^,)]*)', m.group(1))}
        if fields.get("ModName"):
            out.append({"name": fields["ModName"], "workshop_id": fields.get("WorkshopId") or None,
                        "version": fields.get("Version") or None})
    return out


def received_manifest(user_config: Path) -> Dict:
    """Guest side: the host's list as the guest's game saved it, in manifest form."""
    mods = [{"name": m["name"], "source": "workshop" if m["workshop_id"] else "unknown",
             "workshop_id": m["workshop_id"], "title": "", "version": m["version"]}
            for m in read_sync_list(user_config, "ReceivedMods")]
    return {"coopsync": MANIFEST_VERSION, "from": "game", "active_mods": mods}


def sync(user_config: Path, game: Optional[Path], workshop: Optional[Path], modoptions: Path, steam=None,
         write: bool = True, protected: Optional[List[Path]] = None, log=print, timeout_s: float = 1800) -> int:
    """Guest side, end to end. 0 = the active mods now match the host's list; 1 = nothing received yet;
    2 = Workshop downloads needed and no Steam access given; 3 = something cannot be matched (reported)."""
    host = received_manifest(user_config)
    if not host["active_mods"]:
        log(f"no host list in {user_config / SYNC_INI}: join the host once (the refusal brings the list)")
        return 1
    guest = build_manifest(game, workshop, modoptions)
    p = plan(host, guest)
    # plan() works on the active lists only: a host mod the guest has installed but switched off shows as missing,
    # and only needs switching on. Download only what is not installed here at all.
    index = index_mods(game, workshop)
    installed_ids = {m["workshop_id"] for m in index.values() if m["workshop_id"]}
    p["subscribe"] = [w for w in p["subscribe"] if w not in installed_ids]
    log(f"host list: {len(host['active_mods'])} mods; to subscribe: {p['subscribe'] or 'none'}; "
        f"to update: {p['update'] or 'none'}; cannot fetch: {p['cannot_fetch'] or 'none'}; to switch off: {p['deactivate'] or 'none'}")
    if p["subscribe"] or p["update"]:
        if steam is None:
            log("Workshop downloads needed: run again with --steam-api <WOTC dir>/Binaries/Win64/steam_api64.dll "
                "--yes-use-my-steam-account (it subscribes your Steam account to these items)")
            return 2
        states = subscribe_and_wait(steam, [int(x) for x in p["subscribe"] + p["update"]], timeout_s, log=log)
        bad = [w for w, st in states.items() if not st & ITEM_INSTALLED]
        if bad:
            log(f"not installed after waiting: {bad}")
            return 3
    index = index_mods(game, workshop)
    absent = [m["name"] for m in host["active_mods"] if m["name"].lower() not in index]
    if absent:
        log(f"still not installed here: {absent} (no Workshop id from the host: ask the host for them)")
        return 3
    if not write:
        log("dry run: ActiveMods not written")
        return 0
    bak = write_modoptions(modoptions, [m["name"] for m in host["active_mods"]],
                           protected if protected is not None else default_protected())
    log(f"wrote the host's {len(host['active_mods'])} ActiveMods to {modoptions} (backup {bak.name}); start the game and join again")
    return 0


# ----------------------------------------------------------------------------------- Steam

class SteamUGC:
    """The game's own steam_api64.dll (2016-era flat API). Needs the Steam client running and logged in."""

    def __init__(self, dll: Path, appid: str = "268500"):
        import ctypes
        os.environ["SteamAppId"] = appid
        os.environ["SteamGameId"] = appid
        self.c = ctypes
        self.api = ctypes.CDLL(str(dll))
        self.api.SteamAPI_Init.restype = ctypes.c_bool
        if not self.api.SteamAPI_Init():
            raise RuntimeError("SteamAPI_Init failed (Steam not running, or not logged in)")
        self.api.SteamUGC.restype = ctypes.c_void_p
        self.ugc = self.api.SteamUGC()
        if not self.ugc:
            raise RuntimeError("SteamUGC() returned null")
        self.api.SteamAPI_ISteamUGC_SubscribeItem.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self.api.SteamAPI_ISteamUGC_SubscribeItem.restype = ctypes.c_uint64
        self.api.SteamAPI_ISteamUGC_GetItemState.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        self.api.SteamAPI_ISteamUGC_GetItemState.restype = ctypes.c_uint32

    def subscribe(self, wid: int) -> int:
        return int(self.api.SteamAPI_ISteamUGC_SubscribeItem(self.ugc, wid))

    def state(self, wid: int) -> int:
        return int(self.api.SteamAPI_ISteamUGC_GetItemState(self.ugc, wid))

    def pump(self) -> None:
        self.api.SteamAPI_RunCallbacks()

    def close(self) -> None:
        self.api.SteamAPI_Shutdown()


# EItemState bits
ITEM_SUBSCRIBED, ITEM_INSTALLED, ITEM_NEEDS_UPDATE, ITEM_DOWNLOADING, ITEM_DOWNLOAD_PENDING = 1, 4, 8, 16, 32


def subscribe_and_wait(steam, ids: List[int], timeout_s: float = 1800, poll_s: float = 2.0, log=print) -> Dict[int, int]:
    """Subscribe each id, then wait until every one is installed and not updating. Returns the last state per id."""
    for wid in ids:
        if not steam.state(wid) & ITEM_SUBSCRIBED:
            call = steam.subscribe(wid)
            log(f"subscribe {wid} call={call}")
    deadline = time.monotonic() + timeout_s
    states: Dict[int, int] = {}
    while True:
        steam.pump()
        states = {wid: steam.state(wid) for wid in ids}
        waiting = [w for w, s in states.items() if not (s & ITEM_INSTALLED) or s & (ITEM_NEEDS_UPDATE | ITEM_DOWNLOADING | ITEM_DOWNLOAD_PENDING)]
        if not waiting:
            return states
        if time.monotonic() > deadline:
            log(f"timeout, still waiting for {waiting}")
            return states
        time.sleep(poll_s)


# ----------------------------------------------------------------------------------- CLI

def _ids(s: str) -> List[int]:
    out = []
    for part in s.split(","):
        part = part.strip()
        if not part.isdigit():
            raise argparse.ArgumentTypeError(f"not a Workshop id: {part!r}")
        out.append(int(part))
    return out


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="coopsync")
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("manifest")
    m.add_argument("--game", type=Path)
    m.add_argument("--workshop", type=Path)
    m.add_argument("--modoptions", type=Path, required=True)
    m.add_argument("--out", type=Path)
    for name in ("diff", "plan"):
        p = sub.add_parser(name)
        p.add_argument("host", type=Path)
        p.add_argument("guest", type=Path)
    w = sub.add_parser("write-modoptions")
    w.add_argument("--ini", type=Path, required=True)
    w.add_argument("--manifest", type=Path, required=True)
    w.add_argument("--allow-user-config", action="store_true", help="allow writing under Documents\\My Games (the real game's settings)")
    e = sub.add_parser("settings-export")
    e.add_argument("--manifest", type=Path, required=True)
    e.add_argument("--userconfig", type=Path, required=True, help="the game's user config folder (with -nohomedir: <WOTC dir>/XComGame/Config)")
    e.add_argument("--out", type=Path, required=True)
    ws = sub.add_parser("write-settings")
    ws.add_argument("--userconfig", type=Path, required=True)
    ws.add_argument("--settings", type=Path, required=True)
    ws.add_argument("--allow-user-config", action="store_true", help="allow writing under Documents\\My Games (the real game's settings)")
    he = sub.add_parser("host-export")
    he.add_argument("--manifest", type=Path, required=True)
    he.add_argument("--userconfig", type=Path, required=True, help="the game's user config folder (with -nohomedir: <WOTC dir>/XComGame/Config)")
    he.add_argument("--allow-user-config", action="store_true", help="allow writing under Documents\\My Games (the real game's settings)")
    sy = sub.add_parser("sync")
    sy.add_argument("--userconfig", type=Path, required=True)
    sy.add_argument("--game", type=Path)
    sy.add_argument("--workshop", type=Path)
    sy.add_argument("--modoptions", type=Path, required=True)
    sy.add_argument("--steam-api", type=Path)
    sy.add_argument("--yes-use-my-steam-account", action="store_true")
    sy.add_argument("--dry-run", action="store_true")
    sy.add_argument("--timeout", type=float, default=1800)
    sy.add_argument("--allow-user-config", action="store_true", help="allow writing under Documents\\My Games (the real game's settings)")
    s = sub.add_parser("subscribe")
    s.add_argument("--steam-api", type=Path, required=True)
    s.add_argument("--ids", type=_ids, required=True)
    s.add_argument("--timeout", type=float, default=1800)
    s.add_argument("--yes-use-my-steam-account", action="store_true")
    a = ap.parse_args(argv)

    if a.cmd == "manifest":
        man = build_manifest(a.game, a.workshop, a.modoptions)
        text = json.dumps(man, indent=1)
        if a.out:
            a.out.write_text(text, encoding="utf-8")
            print(f"{len(man['active_mods'])} active mods -> {a.out}")
        else:
            print(text)
        return 0
    if a.cmd in ("diff", "plan"):
        host = json.loads(a.host.read_text(encoding="utf-8-sig"))
        guest = json.loads(a.guest.read_text(encoding="utf-8-sig"))
        if a.cmd == "diff":
            d = diff(host, guest)
            print(json.dumps(d, indent=1))
            return 0 if not any(d[k] for k in ("missing", "version", "extra")) else 1
        p = plan(host, guest)
        print(json.dumps(p, indent=1))
        return 0 if p["ok"] else 1
    if a.cmd == "write-modoptions":
        host = json.loads(a.manifest.read_text(encoding="utf-8-sig"))
        active = [x["name"] for x in host["active_mods"] if x["source"] != "missing"]
        try:
            bak = write_modoptions(a.ini, active, [] if a.allow_user_config else default_protected())
        except Refused as e:
            print(f"refused: {e}")
            return 3
        print(f"wrote {len(active)} ActiveMods to {a.ini} (backup {bak.name})")
        return 0
    if a.cmd == "settings-export":
        man = json.loads(a.manifest.read_text(encoding="utf-8-sig"))
        out = export_settings(man, a.userconfig)
        a.out.write_text(json.dumps(out, indent=1), encoding="utf-8")
        print(f"{len(out['files'])} mod settings files -> {a.out}")
        return 0
    if a.cmd == "write-settings":
        settings = json.loads(a.settings.read_text(encoding="utf-8-sig"))
        try:
            written = write_settings(a.userconfig, settings, [] if a.allow_user_config else default_protected())
        except Refused as e:
            print(f"refused: {e}")
            return 3
        print(f"wrote {len(written)} mod settings files to {a.userconfig}")
        return 0
    if a.cmd == "host-export":
        man = json.loads(a.manifest.read_text(encoding="utf-8-sig"))
        try:
            ini = write_host_list(a.userconfig, man, [] if a.allow_user_config else default_protected())
        except Refused as e:
            print(f"refused: {e}")
            return 3
        n = sum(1 for m in man["active_mods"] if m["source"] != "missing")
        print(f"{n} mods for the game to send -> {ini}")
        return 0
    if a.cmd == "sync":
        if a.steam_api and not a.yes_use_my_steam_account:
            print("refused: subscribing changes the logged-in Steam account's Workshop subscriptions; pass --yes-use-my-steam-account")
            return 3
        steam = SteamUGC(a.steam_api) if a.steam_api else None
        try:
            return sync(a.userconfig, a.game, a.workshop, a.modoptions, steam, write=not a.dry_run,
                        protected=[] if a.allow_user_config else default_protected(), timeout_s=a.timeout)
        except Refused as e:
            print(f"refused: {e}")
            return 3
        finally:
            if steam is not None:
                steam.close()
    if a.cmd == "subscribe":
        if not a.yes_use_my_steam_account:
            print("refused: subscribing changes the logged-in Steam account's Workshop subscriptions; pass --yes-use-my-steam-account")
            return 3
        steam = SteamUGC(a.steam_api)
        try:
            states = subscribe_and_wait(steam, a.ids, a.timeout)
        finally:
            steam.close()
        print(json.dumps({str(k): v for k, v in states.items()}))
        return 0 if all(v & ITEM_INSTALLED for v in states.values()) else 1
    return 2


if __name__ == "__main__":
    sys.exit(main())

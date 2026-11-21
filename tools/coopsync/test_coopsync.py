"""Tests for coopsync.py. Fake game/Workshop folders and a fake Steam; nothing real is read or written.

    python -I tools/coopsync/test_coopsync.py
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import coopsync as cs  # noqa: E402


def make_mod(root: Path, name: str, pid: str = "0", script: bytes = b"u1", extra: dict = None) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{name}.XComMod").write_text(f"[mod]\npublishedFileId={pid}\nTitle={name} title\nRequiresXPACK=true\n", encoding="utf-8")
    (root / "Script").mkdir(exist_ok=True)
    (root / "Script" / f"{name}.u").write_bytes(script)
    (root / "Config").mkdir(exist_ok=True)
    (root / "Config" / f"XCom{name}.ini").write_text("[x]\na=1\n", encoding="utf-8")
    for rel, data in (extra or {}).items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    return root


class World:
    """A fake PC: game folder with a Mods folder, a Workshop content folder, a mod options ini."""

    def __init__(self, base: Path):
        self.game = base / "game" / "XCom2-WarOfTheChosen"
        self.mods = self.game / "XComGame" / "Mods"
        self.workshop = base / "workshop" / "268500"
        self.ini = self.game / "XComGame" / "Config" / "XComModOptions.ini"
        self.mods.mkdir(parents=True)
        self.workshop.mkdir(parents=True)
        self.ini.parent.mkdir(parents=True)

    def active(self, *names):
        self.ini.write_text("[Engine.XComModOptions]\n" + "".join(f"ActiveMods={n}\n" for n in names), encoding="utf-8")

    def manifest(self):
        return cs.build_manifest(self.game, self.workshop, self.ini)


class CoopSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    # ------------------------------------------------------------------ reading
    def test_read_active_mods_only_from_its_section(self):
        ini = self.base / "a.ini"
        ini.write_text('﻿[Other]\nActiveMods=Nope\n[Engine.XComModOptions]\n; c\nActiveMods=A\n+ActiveMods="B"\nActiveMods=A\n.ActiveMods=C\n'
                       "[Next]\nActiveMods=Z\n", encoding="utf-8")
        self.assertEqual(cs.read_active_mods(ini), ["A", "B", "C"])

    def test_manifest_finds_workshop_local_and_missing(self):
        w = World(self.base)
        make_mod(w.workshop / "111", "WsMod")                       # publishedFileId=0: the folder name is the id
        make_mod(w.mods / "LocalMod", "LocalMod")
        make_mod(w.mods / "CopyOfWs", "CopyOfWs", pid="222")         # local copy that records its Workshop id
        w.active("WsMod", "LocalMod", "CopyOfWs", "Gone")
        mods = {m["name"]: m for m in w.manifest()["active_mods"]}
        self.assertEqual((mods["WsMod"]["source"], mods["WsMod"]["workshop_id"]), ("workshop", "111"))
        self.assertEqual((mods["LocalMod"]["source"], mods["LocalMod"]["workshop_id"]), ("local", None))
        self.assertEqual(mods["CopyOfWs"]["workshop_id"], "222")
        self.assertEqual((mods["Gone"]["source"], mods["Gone"]["version"]), ("missing", None))
        self.assertEqual([m["name"] for m in w.manifest()["active_mods"]], ["WsMod", "LocalMod", "CopyOfWs", "Gone"])

    def test_local_mod_wins_over_workshop_copy(self):
        w = World(self.base)
        make_mod(w.workshop / "111", "Same", script=b"ws")
        make_mod(w.mods / "Same", "Same", script=b"local")
        w.active("Same")
        m = w.manifest()["active_mods"][0]
        self.assertEqual(m["source"], "local")

    def test_fingerprint_tracks_code_config_and_content_size_not_previews(self):
        d = make_mod(self.base / "m", "M", extra={"Content/M.upk": b"12345", "ModPreview.jpg": b"a"})
        x = d / "M.XComMod"
        f0 = cs.fingerprint(d, x)
        (d / "ModPreview.jpg").write_bytes(b"different")
        self.assertEqual(cs.fingerprint(d, x), f0, "previews must not count")
        (d / "Script" / "M.u").write_bytes(b"u2")
        f1 = cs.fingerprint(d, x)
        self.assertNotEqual(f1, f0, "script change must count")
        (d / "Config" / "XComM.ini").write_text("[x]\na=2\n", encoding="utf-8")
        f2 = cs.fingerprint(d, x)
        self.assertNotEqual(f2, f1, "config change must count")
        (d / "Content" / "M.upk").write_bytes(b"123456")
        self.assertNotEqual(cs.fingerprint(d, x), f2, "content size change must count")

    # ------------------------------------------------------------------ comparing
    def pair(self):
        host, guest = World(self.base / "h"), World(self.base / "g")
        return host, guest

    def test_identical_setups_are_ok(self):
        h, g = self.pair()
        for w in (h, g):
            make_mod(w.workshop / "111", "A")
            make_mod(w.workshop / "222", "B")
            w.active("A", "B")
        p = cs.plan(h.manifest(), g.manifest())
        self.assertTrue(p["ok"])
        self.assertEqual(p["subscribe"], [])

    def test_plan_lists_every_kind_of_difference(self):
        h, g = self.pair()
        make_mod(h.workshop / "111", "A")
        make_mod(h.workshop / "333", "Voices")
        make_mod(h.mods / "OnlyLocal", "OnlyLocal")
        make_mod(h.workshop / "444", "Changed", script=b"v2")
        h.active("A", "Voices", "OnlyLocal", "Changed", "HostLacks")
        make_mod(g.workshop / "111", "A")
        make_mod(g.workshop / "444", "Changed", script=b"v1")
        make_mod(g.workshop / "555", "GuestExtra")
        g.active("A", "Changed", "GuestExtra")
        p = cs.plan(h.manifest(), g.manifest())
        self.assertFalse(p["ok"])
        self.assertEqual(p["subscribe"], ["333"])
        self.assertEqual(p["cannot_fetch"], ["OnlyLocal"])
        self.assertEqual(p["update"], ["444"])
        self.assertEqual(p["deactivate"], ["GuestExtra"])
        self.assertEqual(p["host_problems"], ["HostLacks"])
        self.assertEqual(p["active_mods"], ["A", "Voices", "OnlyLocal", "Changed"])

    def test_names_compare_case_insensitively(self):
        h, g = self.pair()
        make_mod(h.workshop / "111", "MyMod")
        h.active("MyMod")
        make_mod(g.workshop / "111", "MyMod")
        g.active("mymod")
        self.assertTrue(cs.plan(h.manifest(), g.manifest())["ok"])

    # ------------------------------------------------------------------ writing
    def test_write_modoptions_replaces_active_mods_keeps_the_rest_and_backs_up(self):
        ini = self.base / "XComModOptions.ini"
        ini.write_text("[Engine.XComModOptions]\nActiveMods=Old\nbSomething=True\n[Other.Section]\nKey=1\n", encoding="utf-8")
        bak = cs.write_modoptions(ini, ["A", "B"], [])
        self.assertTrue(bak.exists())
        self.assertIn("ActiveMods=Old", bak.read_text(encoding="utf-8"))
        self.assertEqual(cs.read_active_mods(ini), ["A", "B"])
        text = ini.read_text(encoding="ascii")
        self.assertIn("bSomething=True", text)
        self.assertIn("[Other.Section]", text)
        self.assertNotIn("Old", text)

    def test_write_modoptions_creates_the_section_when_missing(self):
        ini = self.base / "new.ini"
        cs.write_modoptions(ini, ["A"], [])
        self.assertEqual(cs.read_active_mods(ini), ["A"])

    def test_write_modoptions_refuses_hard_links_and_protected_folders(self):
        orig = self.base / "orig.ini"
        orig.write_text("[Engine.XComModOptions]\nActiveMods=Keep\n", encoding="utf-8")
        link = self.base / "link.ini"
        os.link(orig, link)
        with self.assertRaises(cs.Refused):
            cs.write_modoptions(link, ["X"], [])
        self.assertEqual(cs.read_active_mods(orig), ["Keep"], "the linked original must be untouched")
        prot = self.base / "MyGames"
        prot.mkdir()
        with self.assertRaises(cs.Refused):
            cs.write_modoptions(prot / "XComModOptions.ini", ["X"], [prot])
        self.assertFalse((prot / "XComModOptions.ini").exists())

    # ------------------------------------------------------------------ mod settings
    def test_settings_round_trip_with_backup(self):
        h, g = self.pair()
        make_mod(h.workshop / "111", "A")                       # ships Config/XComA.ini
        h.active("A")
        man = h.manifest()
        self.assertEqual(man["active_mods"][0]["config_files"], ["XComA.ini"])
        host_cfg = self.base / "host_cfg"
        host_cfg.mkdir()
        (host_cfg / "XComA.ini").write_text("[A.Settings]\nDifficulty=3\n", encoding="utf-8")
        (host_cfg / "XComUnrelated.ini").write_text("[x]\ny=1\n", encoding="utf-8")
        settings = cs.export_settings(man, host_cfg)
        self.assertEqual(sorted(settings["files"]), ["XComA.ini"], "only files of active mods")
        guest_cfg = self.base / "guest_cfg"
        guest_cfg.mkdir()
        (guest_cfg / "XComA.ini").write_text("[A.Settings]\nDifficulty=1\n", encoding="utf-8")
        self.assertEqual(cs.write_settings(guest_cfg, settings, []), ["XComA.ini"])
        self.assertIn("Difficulty=3", (guest_cfg / "XComA.ini").read_text(encoding="utf-8"))
        baks = list(guest_cfg.glob("XComA.ini.coopsync-*.bak"))
        self.assertEqual(len(baks), 1)
        self.assertIn("Difficulty=1", baks[0].read_text(encoding="utf-8"))

    def test_settings_export_skips_missing_files(self):
        h, _ = self.pair()
        make_mod(h.workshop / "111", "A")
        h.active("A")
        self.assertEqual(cs.export_settings(h.manifest(), self.base / "empty")["files"], {})

    def test_write_settings_refuses_links_protected_and_paths(self):
        cfg = self.base / "cfg"
        cfg.mkdir()
        orig = self.base / "orig.ini"
        orig.write_text("keep", encoding="utf-8")
        os.link(orig, cfg / "XComA.ini")
        with self.assertRaises(cs.Refused):
            cs.write_settings(cfg, {"files": {"XComA.ini": "new"}}, [])
        self.assertEqual(orig.read_text(encoding="utf-8"), "keep", "nothing written through the link")
        with self.assertRaises(cs.Refused):
            cs.write_settings(cfg, {"files": {"..\\evil.ini": "x"}}, [])
        with self.assertRaises(cs.Refused):
            cs.write_settings(cfg, {"files": {"XComB.ini": "x"}}, [self.base])
        self.assertFalse((cfg / "XComB.ini").exists())

    # ------------------------------------------------------------------ Steam (fake)
    class FakeSteam:
        def __init__(self, installed_after: int, subscribed=()):
            self.ticks = 0
            self.after = installed_after
            self.subs = set(subscribed)
            self.calls = []

        def subscribe(self, wid):
            self.calls.append(wid)
            self.subs.add(wid)
            return 1000 + wid

        def state(self, wid):
            if wid not in self.subs:
                return 0
            if self.ticks >= self.after:
                return cs.ITEM_SUBSCRIBED | cs.ITEM_INSTALLED
            return cs.ITEM_SUBSCRIBED | cs.ITEM_DOWNLOADING

        def pump(self):
            self.ticks += 1

    def test_subscribe_only_what_is_not_subscribed_and_wait_for_install(self):
        steam = self.FakeSteam(installed_after=3, subscribed={7})
        states = cs.subscribe_and_wait(steam, [7, 8], timeout_s=5, poll_s=0, log=lambda s: None)
        self.assertEqual(steam.calls, [8])
        self.assertTrue(all(s & cs.ITEM_INSTALLED for s in states.values()))
        self.assertGreaterEqual(steam.ticks, 3)

    def test_subscribe_times_out_and_reports_unfinished(self):
        steam = self.FakeSteam(installed_after=10**9)
        states = cs.subscribe_and_wait(steam, [9], timeout_s=0.01, poll_s=0, log=lambda s: None)
        self.assertFalse(states[9] & cs.ITEM_INSTALLED)

    def test_cli_subscribe_refuses_without_explicit_consent(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = cs.main(["subscribe", "--steam-api", str(self.base / "none.dll"), "--ids", "1"])
        self.assertEqual(rc, 3)
        self.assertIn("refused", out.getvalue())

    def test_cli_manifest_diff_plan_round_trip(self):
        h, g = self.pair()
        make_mod(h.workshop / "111", "A")
        h.active("A")
        g.active()
        hj, gj = self.base / "h.json", self.base / "g.json"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cs.main(["manifest", "--game", str(h.game), "--workshop", str(h.workshop), "--modoptions", str(h.ini), "--out", str(hj)]), 0)
            self.assertEqual(cs.main(["manifest", "--game", str(g.game), "--workshop", str(g.workshop), "--modoptions", str(g.ini), "--out", str(gj)]), 0)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(cs.main(["plan", str(hj), str(gj)]), 1)
        self.assertEqual(json.loads(out.getvalue())["subscribe"], ["111"])

    # ------------------------------------------------------------------ the game's list (host-export, sync)
    def received(self, cfg: Path, entries, extra_text=""):
        """What the guest's game writes (CoopSyncData.StaticSaveConfig)."""
        cfg.mkdir(parents=True, exist_ok=True)
        lines = "".join(f'ReceivedMods=(ModName="{n}",WorkshopId="{w}",Version="{v}")\n' for n, w, v in entries)
        (cfg / cs.SYNC_INI).write_text(extra_text + f"[{cs.SYNC_SECTION}]\nReceivedHost=127.0.0.1\n" + lines, encoding="utf-8")

    def test_host_export_round_trip_keeps_other_keys(self):
        h, _ = self.pair()
        make_mod(h.workshop / "111", "A")
        make_mod(h.mods / "B", "B")
        h.active("A", "B", "Gone")
        cfg = self.base / "hostcfg"
        cfg.mkdir()
        (cfg / cs.SYNC_INI).write_text(f"[Other]\nx=1\n[{cs.SYNC_SECTION}]\n+HostMods=(ModName=\"Old\")\nReceivedHost=1.2.3.4\n", encoding="utf-8")
        cs.write_host_list(cfg, h.manifest(), [])
        got = cs.read_sync_list(cfg, "HostMods")
        self.assertEqual([m["name"] for m in got], ["A", "B"])          # the missing mod is not sent
        self.assertEqual(got[0]["workshop_id"], "111")
        self.assertIsNone(got[1]["workshop_id"])
        self.assertEqual(got[0]["version"], h.manifest()["active_mods"][0]["version"])
        text = (cfg / cs.SYNC_INI).read_text(encoding="utf-8")
        self.assertIn("[Other]", text)
        self.assertIn("ReceivedHost=1.2.3.4", text)
        self.assertNotIn("Old", text)

    def test_host_export_refuses_links_protected_and_unsafe_names(self):
        h, _ = self.pair()
        make_mod(h.workshop / "111", "A")
        h.active("A")
        cfg = self.base / "cfg"
        cfg.mkdir()
        with self.assertRaises(cs.Refused):
            cs.write_host_list(cfg, h.manifest(), [self.base])
        (self.base / "orig.ini").write_text("x", encoding="utf-8")
        os.link(self.base / "orig.ini", cfg / cs.SYNC_INI)
        with self.assertRaises(cs.Refused):
            cs.write_host_list(cfg, h.manifest(), [])
        (cfg / cs.SYNC_INI).unlink()
        bad = {"active_mods": [{"name": 'A"B', "source": "local", "workshop_id": None, "version": None}]}
        with self.assertRaises(cs.Refused):
            cs.write_host_list(cfg, bad, [])

    def test_reads_the_list_as_the_game_writes_it(self):
        cfg = self.base / "cfg"
        cfg.mkdir()
        # copied from a guest's XComCoopSync.ini after a refused join (2026-11-17)
        (cfg / cs.SYNC_INI).write_text(f"[{cs.SYNC_SECTION}]\nReceivedMods=(ModName=\"WOTCCoopCampaign\",WorkshopId=,Version=)\n"
                                       "ReceivedMods=(ModName=\"B\",WorkshopId=\"333\",Version=\"abc\")\nReceivedHost=127.0.0.1\n"
                                       "ReceivedExpected=2\n", encoding="utf-8")
        got = cs.read_sync_list(cfg, "ReceivedMods")
        self.assertEqual(got, [{"name": "WOTCCoopCampaign", "workshop_id": None, "version": None},
                               {"name": "B", "workshop_id": "333", "version": "abc"}])

    def test_names_only_list_does_not_flag_versions(self):
        _, g = self.pair()
        make_mod(g.workshop / "111", "A", script=b"guest build")
        g.active("A")
        host = {"active_mods": [{"name": "A", "source": "unknown", "workshop_id": None, "version": None}]}
        self.assertEqual(cs.diff(host, g.manifest())["version"], [])

    def test_sync_without_a_received_list(self):
        _, g = self.pair()
        g.active()
        self.assertEqual(cs.sync(self.base / "cfg", g.game, g.workshop, g.ini, log=lambda s: None), 1)

    def test_sync_needs_steam_for_downloads_and_writes_nothing(self):
        _, g = self.pair()
        g.active("Mine")
        make_mod(g.mods / "Mine", "Mine")
        cfg = self.base / "cfg"
        self.received(cfg, [("A", "111", "")])
        before = g.ini.read_text(encoding="utf-8")
        self.assertEqual(cs.sync(cfg, g.game, g.workshop, g.ini, log=lambda s: None, protected=[]), 2)
        self.assertEqual(g.ini.read_text(encoding="utf-8"), before)

    class InstallingSteam(FakeSteam):
        """Puts the mod into the guest's Workshop folder once 'installed', as Steam would."""
        def __init__(self, workshop: Path, installed_after=2):
            super().__init__(installed_after)
            self.workshop = workshop

        def state(self, wid):
            st = super().state(wid)
            if st & cs.ITEM_INSTALLED and not (self.workshop / str(wid)).exists():
                make_mod(self.workshop / str(wid), {111: "A", 222: "C"}[wid])
            return st

    def test_sync_subscribes_waits_and_switches_the_active_mods(self):
        _, g = self.pair()
        make_mod(g.mods / "Mine", "Mine")
        make_mod(g.workshop / "333", "B")
        g.active("Mine")
        cfg = self.base / "cfg"
        self.received(cfg, [("A", "111", ""), ("B", "333", ""), ("C", "222", "")])
        steam = self.InstallingSteam(g.workshop)
        rc = cs.sync(cfg, g.game, g.workshop, g.ini, steam, log=lambda s: None, protected=[], timeout_s=5)
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(steam.calls), [111, 222])                 # B was installed already
        self.assertEqual(cs.read_active_mods(g.ini), ["A", "B", "C"])       # host order; Mine switched off
        self.assertTrue(list(g.ini.parent.glob("XComModOptions.ini.coopsync-*.bak")))

    def test_sync_reports_a_mod_without_workshop_id(self):
        _, g = self.pair()
        g.active()
        cfg = self.base / "cfg"
        self.received(cfg, [("HostOnly", "", "")])
        self.assertEqual(cs.sync(cfg, g.game, g.workshop, g.ini, log=lambda s: None, protected=[]), 3)

    def test_sync_dry_run_and_already_matching(self):
        _, g = self.pair()
        make_mod(g.workshop / "111", "A")
        g.active()
        cfg = self.base / "cfg"
        self.received(cfg, [("A", "111", "")])
        self.assertEqual(cs.sync(cfg, g.game, g.workshop, g.ini, write=False, log=lambda s: None, protected=[]), 0)
        self.assertEqual(cs.read_active_mods(g.ini), [])
        self.assertEqual(cs.sync(cfg, g.game, g.workshop, g.ini, log=lambda s: None, protected=[]), 0)
        self.assertEqual(cs.read_active_mods(g.ini), ["A"])

    def test_cli_sync_refuses_steam_without_explicit_consent(self):
        _, g = self.pair()
        g.active()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = cs.main(["sync", "--userconfig", str(self.base / "cfg"), "--modoptions", str(g.ini), "--steam-api", str(self.base / "none.dll")])
        self.assertEqual(rc, 3)
        self.assertIn("refused", out.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=1)

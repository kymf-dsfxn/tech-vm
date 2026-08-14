"""Unit tests for platform_node.py. Stdlib only; no VM, no root:
    python3 -m unittest discover 00.host-config/common/tests
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "guest-bin"))
import platform_node as pn  # noqa: E402


class FakeProbes:
    def __init__(self, block=(), readable=(), mounted=(), luks=()):
        self.block = set(block)
        self.readable = set(readable)
        self.mounted = set(mounted)
        self.luks = set(luks)

    def is_block_device(self, path):
        return path in self.block

    def is_readable(self, path):
        return path in self.readable

    def is_mounted(self, mountpoint):
        return mountpoint in self.mounted

    def is_luks(self, partition):
        return partition in self.luks


DEV, PART, MAPPER, MOUNT = ("/dev/sdb", "/dev/sdb1",
                            "/dev/mapper/dsfxn_data", "/srv/dsfxn")


def classify(probes):
    return pn.disk_state(DEV, PART, MAPPER, MOUNT, probes)


class DiskStateTests(unittest.TestCase):
    def test_absent(self):
        self.assertEqual(classify(FakeProbes()), "absent")

    def test_unlocked_wins_whatever_the_header_says(self):
        probes = FakeProbes(block=[DEV, PART, MAPPER], mounted=[MOUNT])
        self.assertEqual(classify(probes), "unlocked")

    def test_opened_mapper_not_mounted(self):
        probes = FakeProbes(block=[DEV, PART, MAPPER], readable=[PART])
        self.assertEqual(classify(probes), "opened")

    def test_uninitialised_no_partition(self):
        self.assertEqual(classify(FakeProbes(block=[DEV])), "uninitialised")

    def test_unknown_unreadable_header_is_never_guessed(self):
        # The load-bearing distinction: unreadable is NOT uninitialised,
        # because "no header" invites init, which reformats.
        probes = FakeProbes(block=[DEV, PART], luks=[PART])
        self.assertEqual(classify(probes), "unknown")

    def test_locked(self):
        probes = FakeProbes(block=[DEV, PART], readable=[PART], luks=[PART])
        self.assertEqual(classify(probes), "locked")

    def test_uninitialised_readable_no_header(self):
        probes = FakeProbes(block=[DEV, PART], readable=[PART])
        self.assertEqual(classify(probes), "uninitialised")

    def test_vocabulary_is_closed(self):
        self.assertEqual(
            pn.STATES,
            ("absent", "unlocked", "opened", "uninitialised", "unknown", "locked"))


class PlatformEnvTests(unittest.TestCase):
    def _write(self, text):
        handle = tempfile.NamedTemporaryFile(
            "w", suffix=".env", delete=False, encoding="utf-8")
        handle.write(text)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_parse_and_derive(self):
        path = self._write(
            "# comment\n"
            "PLATFORM_NAMESPACE=dsfxn\n"
            "PLATFORM_CORE_USER=dsfxn\n"
            "PLATFORM_DATA_ROOT=/srv/dsfxn\n"
            "PLATFORM_DATA_SHARE=/srv/dsfxn/share\n"
            "PLATFORM_DATA_STATE=/srv/dsfxn/.platform\n"
            "PLATFORM_SYNC_USER=stsync\n"
            "PLATFORM_NAMED_USER=kymf\n")
        d = pn.derived(pn.load_platform_env(path))
        self.assertEqual(d["share"], "/srv/dsfxn/share")
        self.assertEqual(d["luks_name"], "dsfxn_data")
        self.assertEqual(d["named_user"], "kymf")

    def test_fallbacks_match_the_bash_consumers(self):
        path = self._write(
            "PLATFORM_NAMESPACE=dsfxn\n"
            "PLATFORM_CORE_USER=dsfxn\n"
            "PLATFORM_DATA_ROOT=/srv/dsfxn\n")
        d = pn.derived(pn.load_platform_env(path))
        self.assertEqual(d["share"], "/srv/dsfxn/share")
        self.assertEqual(d["state_dir"], "/srv/dsfxn/.platform")
        self.assertEqual(d["sync_user"], "stsync")
        self.assertEqual(d["named_user"], "kymf")

    def test_missing_file_is_fatal(self):
        with self.assertRaises(pn.PlatformEnvError):
            pn.load_platform_env("/nonexistent/platform.env")


TEMPLATE = """<configuration version="52">
    <!-- comment naming MANUALLY_FIX_IN_COMMENT stays invisible -->
    <folder id="MANUALLY_FIX_FOLDER_ID" label="x" path="/srv/dsfxn/share">
        <device id="AUTOFILL_DEVICE_ID_SELF"></device>
        <markerName>.dsfxn-share-marker</markerName>
    </folder>
    <gui><apikey>AUTOFILL_API_KEY</apikey></gui>
</configuration>
"""

RENDERED = """<configuration version="52">
    <folder id="abcde-12345" label="x" path="/srv/dsfxn/share">
        <markerName>.custom-marker</markerName>
    </folder>
</configuration>
"""

MARKER_AS_ATTRIBUTE = """<configuration version="52">
    <folder id="abcde-12345" markerName=".sneaky"></folder>
</configuration>
"""


class TemplateScanTests(unittest.TestCase):
    def test_tokens_outside_comments_only(self):
        self.assertEqual(pn.pending_tokens(TEMPLATE, "MANUALLY_FIX_"),
                         ["MANUALLY_FIX_FOLDER_ID"])
        self.assertEqual(pn.pending_tokens(TEMPLATE, "AUTOFILL_"),
                         ["AUTOFILL_API_KEY", "AUTOFILL_DEVICE_ID_SELF"])

    def test_clean_text_has_none(self):
        self.assertEqual(pn.pending_tokens(RENDERED, "MANUALLY_FIX_"), [])


class XmlResolutionTests(unittest.TestCase):
    def _write(self, text):
        handle = tempfile.NamedTemporaryFile(
            "w", suffix=".xml", delete=False, encoding="utf-8")
        handle.write(text)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_config_beats_template_beats_default(self):
        config = self._write(RENDERED)
        template = self._write(TEMPLATE)
        self.assertEqual(pn.marker_name_configured(config, template),
                         ".custom-marker")
        self.assertEqual(pn.marker_name_configured(None, template),
                         ".dsfxn-share-marker")
        self.assertEqual(pn.marker_name_configured(None, "/nonexistent.xml"),
                         pn.MARKER_NAME_DEFAULT)

    def test_marker_as_attribute_is_ignored(self):
        # Exactly Syncthing's behaviour: an attribute is not the guard.
        path = self._write(MARKER_AS_ATTRIBUTE)
        self.assertEqual(pn.marker_name_configured(path, "/nonexistent.xml"),
                         pn.MARKER_NAME_DEFAULT)

    def test_folder_id_skips_placeholders(self):
        template = self._write(TEMPLATE)
        rendered = self._write(RENDERED)
        self.assertEqual(pn.folder_id(rendered, template), "abcde-12345")
        self.assertEqual(pn.folder_id(None, template), pn.FOLDER_ID_DEFAULT)

    def test_unreadable_is_tolerated(self):
        self.assertIsNone(pn.first_element_text("/nonexistent.xml", ".//x"))


if __name__ == "__main__":
    unittest.main()

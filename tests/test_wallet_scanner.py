import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import wallet_scanner


VALID_HASH_1 = "AAAAAAAAAAAAAAAAAAAAAAAAAAA="
VALID_HASH_2 = "BBBBBBBBBBBBBBBBBBBBBBBBBBB="

class WalletScannerTests(unittest.TestCase):
    def test_normalize_hash_accepts_only_wallet_directory_ids(self):
        self.assertEqual(wallet_scanner.normalize_hash(VALID_HASH_1), VALID_HASH_1)
        self.assertEqual(wallet_scanner.normalize_hash(VALID_HASH_1 + ".pkpass"), VALID_HASH_1)
        self.assertIsNone(wallet_scanner.normalize_hash("not-a-wallet-hash"))
        self.assertIsNone(wallet_scanner.normalize_hash("123e4567-e89b-12d3-a456-426614174000"))

    def test_flash_cover_writes_three_assets_and_removes_both_caches(self):
        def fake_sips(arguments, **_kwargs):
            Path(arguments[arguments.index("--out") + 1]).write_bytes(b"png")

        assets = (
            ("cardBackgroundCombined@3x.png", b"png"),
            ("cardBackgroundCombined@2x.png", b"png"),
            ("cardBackgroundCombined.pdf", b"pdf"),
        )
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "source.jpg"
            image.write_bytes(b"image")
            with (
                patch.object(wallet_scanner.subprocess, "run", side_effect=fake_sips),
                patch.object(wallet_scanner, "build_card_assets", return_value=assets),
                patch.object(wallet_scanner, "write_files_batch", return_value=True) as writer,
                patch.object(wallet_scanner, "remove_files", return_value=True) as remover,
            ):
                result = wallet_scanner.flash_cover("device-udid", VALID_HASH_1, image)

        self.assertTrue(result["ok"])
        self.assertEqual(len(writer.call_args.args[2]), 3)
        self.assertEqual(remover.call_count, 2)

    def test_flash_cover_reports_live_progress(self):
        def fake_sips(arguments, **_kwargs):
            Path(arguments[arguments.index("--out") + 1]).write_bytes(b"png")

        progress = []
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "source.png"
            image.write_bytes(b"image")
            with (
                patch.object(wallet_scanner.subprocess, "run", side_effect=fake_sips),
                patch.object(wallet_scanner, "build_card_assets", return_value=(("a", b"a"),)),
                patch.object(wallet_scanner, "write_files_batch", return_value=True),
                patch.object(wallet_scanner, "remove_files", return_value=True),
            ):
                result = wallet_scanner.flash_cover(
                    "device-udid", VALID_HASH_1, image, progress.append
                )
        self.assertTrue(result["ok"])
        self.assertEqual(progress, sorted(progress))
        self.assertEqual(progress[-1], 1.0)


if __name__ == "__main__":
    unittest.main()

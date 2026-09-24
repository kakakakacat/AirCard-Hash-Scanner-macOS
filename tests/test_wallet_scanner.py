import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import wallet_scanner


VALID_HASH_1 = "AAAAAAAAAAAAAAAAAAAAAAAAAAA="
VALID_HASH_2 = "BBBBBBBBBBBBBBBBBBBBBBBBBBB="


def database_bytes(rows):
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "passes23.sqlite"
        database = sqlite3.connect(path)
        database.execute(
            "CREATE TABLE PASS (UNIQUE_ID TEXT, ORGANIZATION_NAME TEXT, "
            "LOCALIZED_DESCRIPTION TEXT, SERIAL_NUMBER TEXT)"
        )
        database.executemany("INSERT INTO PASS VALUES (?, ?, ?, ?)", rows)
        database.commit()
        database.close()
        return path.read_bytes()


class WalletScannerTests(unittest.TestCase):
    def test_normalize_hash_accepts_only_wallet_directory_ids(self):
        self.assertEqual(wallet_scanner.normalize_hash(VALID_HASH_1), VALID_HASH_1)
        self.assertEqual(wallet_scanner.normalize_hash(VALID_HASH_1 + ".pkpass"), VALID_HASH_1)
        self.assertIsNone(wallet_scanner.normalize_hash("not-a-wallet-hash"))
        self.assertIsNone(wallet_scanner.normalize_hash("123e4567-e89b-12d3-a456-426614174000"))

    def test_reads_names_and_deduplicates_hashes(self):
        payload = database_bytes([
            (VALID_HASH_1, "Transit Card", "Fallback", "1"),
            (VALID_HASH_1, "Duplicate", "Duplicate", "1"),
            (VALID_HASH_2, None, "Bank Card", "2"),
            ("invalid", "Ignored", None, "3"),
        ])
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "passes23.sqlite"
            path.write_bytes(payload)
            cards = wallet_scanner.read_cards(path)
        self.assertEqual(cards, [
            {"hash": VALID_HASH_1, "name": "Transit Card"},
            {"hash": VALID_HASH_2, "name": "Bank Card"},
        ])

    def test_scan_reads_database_once(self):
        payload = database_bytes([(VALID_HASH_1, "Transit Card", None, "1")])
        with patch.object(wallet_scanner, "read_file", return_value=payload) as reader:
            result = wallet_scanner.scan_wallet("device-udid")
        self.assertTrue(result["ok"])
        self.assertEqual(result["cards"][0]["hash"], VALID_HASH_1)
        reader.assert_called_once_with(
            "device-udid", wallet_scanner.PASSES_DIRECTORY,
            wallet_scanner.DATABASE_NAME, retries=1
        )

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


if __name__ == "__main__":
    unittest.main()

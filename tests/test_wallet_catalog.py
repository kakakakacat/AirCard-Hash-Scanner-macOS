import json
import tempfile
import unittest
from pathlib import Path

import wallet_catalog


VALID_HASH = "AAAAAAAAAAAAAAAAAAAAAAAAAAA="


class WalletCatalogTests(unittest.TestCase):
    def test_reads_membership_name_from_local_mac_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pass_dir = root / "Cards" / f"{VALID_HASH}.pkpass"
            pass_dir.mkdir(parents=True)
            (pass_dir / "pass.json").write_text(
                json.dumps({
                    "organizationName": "Local Transit",
                    "description": "City Card",
                    "generic": {},
                }),
                encoding="utf-8",
            )
            catalog = wallet_catalog.build_catalog(root, [], "iPhone17,1")

        self.assertEqual(catalog["memberships"], [{
            "id": VALID_HASH,
            "name": "Local Transit · City Card",
            "source": "membership",
        }])

    def test_rejects_non_wallet_identifiers(self):
        self.assertIsNone(wallet_catalog.card("not-a-hash", "Name", "membership"))


if __name__ == "__main__":
    unittest.main()

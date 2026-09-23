from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = (ROOT / "AirCardApp.swift").read_text("utf-8")
README = (ROOT / "README.md").read_text("utf-8")
SCANNER = (ROOT / "wallet_scanner.py").read_text("utf-8")

for required in (
    'AppLanguage.english.rawValue',
    'Read all card hashes',
    '读取全部卡片 Hash',
    'LocalDevVPN',
    'AutoFill Cards',
    '自动填充卡片',
    'Export JSON',
    'Import hashes',
    '批量导入 Hash',
    'Card name',
    '卡片名称',
    'func importHashes',
    'func renameCard',
):
    assert required in SWIFT, required

for removed in (
    'Double-click Side button',
    'Tap your card',
    'Flash Skins',
    'Passcode Theme',
    'PosterBoard',
    'NFC',
):
    assert removed not in SWIFT, removed

assert 'passes23.sqlite' in SCANNER
assert 'FROM PASS WHERE UNIQUE_ID IS NOT NULL' in SCANNER
assert 'Developer Mode' in README

for obsolete in ('aircard.py', 'aircard_backend.py', 'card_assets.py'):
    assert not (ROOT / obsolete).exists(), obsolete

print('scanner-only macOS release checks passed')

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = (ROOT / "AirCardApp.swift").read_text("utf-8")
README = (ROOT / "README.md").read_text("utf-8")
SCANNER = (ROOT / "wallet_scanner.py").read_text("utf-8")
AIRTRAFFIC = (ROOT / "apply_card_skin.py").read_text("utf-8")
ASSETS = (ROOT / "card_assets.py").read_text("utf-8")

for required in (
    'AppLanguage.english.rawValue',
    'Read all card hashes',
    '读取全部卡片 Hash',
    'AutoFill Cards',
    '自动填充卡片',
    'Export JSON',
    'Import hashes',
    '批量导入 Hash',
    'Card name',
    '卡片名称',
    'func importHashes',
    'func renameCard',
    'AirCard Wallet Tool',
    'Apply selected covers',
    '写入已选择的封面',
    'Express Transit Card',
    '快捷交通卡',
    'savedArtworkKey',
    'func applyCovers',
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
assert 'def flash_cover' in SCANNER
assert 'write_files_batch' in SCANNER
assert 'remove_files' in SCANNER
assert 'def remove_files' in AIRTRAFFIC
assert 'finish-moved-removal' in AIRTRAFFIC
assert 'corrupted' not in AIRTRAFFIC.lower()
assert 'cardBackgroundCombined@3x.png' in ASSETS
assert 'cardBackgroundCombined@2x.png' in ASSETS
assert 'cardBackgroundCombined.pdf' in ASSETS
assert 'Developer Mode' in README
assert 'LocalDevVPN' in README
assert 'AirCard Wallet Tool' in README
assert 'Express Transit Card' in README
assert '快捷交通卡' in README
assert 'saved automatically' in README
assert '自动保存' in README

for obsolete in ('aircard.py', 'aircard_backend.py'):
    assert not (ROOT / obsolete).exists(), obsolete
assert (ROOT / 'card_assets.py').is_file()

print('AirCard Wallet Tool release checks passed')

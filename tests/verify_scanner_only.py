from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = (ROOT / "AirCardApp.swift").read_text("utf-8")
README = (ROOT / "README.md").read_text("utf-8")
SCANNER = (ROOT / "wallet_scanner.py").read_text("utf-8")
DISCOVERY = (ROOT / "Sources" / "WalletDiscovery.swift").read_text("utf-8")
CATALOG = (ROOT / "wallet_catalog.py").read_text("utf-8")
AIRTRAFFIC = (ROOT / "apply_card_skin.py").read_text("utf-8")
ASSETS = (ROOT / "card_assets.py").read_text("utf-8")

for required in (
    'AppLanguage.english.rawValue',
    'Read all card hashes',
    '读取全部卡片 Hash',
    'Export JSON',
    'Import hashes',
    '批量导入 Hash',
    'Card name',
    '卡片名称',
    'func importHashes',
    'func renameCard',
    'AirCard Wallet Tool',
    'Review and apply covers',
    '预览并确认写入',
    'savedArtworkKey',
    'func applyCovers',
    'scanProgress',
    'Wallet scan complete',
    'Wallet 扫描完成',
    'dropDestination(for: URL.self)',
    'Confirm and apply',
    '确认并写入',
    'EditableCardTile',
    'flashPhase',
    'Cover update complete',
    '封面写入完成',
    'completely close the Wallet app',
    '完全关闭 Wallet 应用',
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

assert 'read_file' not in SCANNER
assert '--scan' not in SCANNER
assert 'def flash_cover' in SCANNER
assert 'write_files_batch' in SCANNER
assert 'remove_files' in SCANNER
assert 'def read_file' not in AIRTRAFFIC
assert 'def remove_files' in AIRTRAFFIC
assert 'finish-moved-removal' in AIRTRAFFIC
assert 'corrupted' not in AIRTRAFFIC.lower()
assert 'cardBackgroundCombined@3x.png' in ASSETS
assert 'cardBackgroundCombined@2x.png' in ASSETS
assert 'cardBackgroundCombined.pdf' in ASSETS
assert 'os_trace_relay' in README
assert 'does not read `passes23.sqlite`' in README
assert 'AirCard Wallet Tool' in README
assert 'saved automatically' in README
assert '自动保存' in README
assert 'drag-and-drop' in README
assert (ROOT / 'Assets' / 'AirCardWalletToolIcon.png').is_file()
assert 'passIDs\\[(?:InSession|global)\\]' in DISCOVERY
assert 'Dashboard loading' in DISCOVERY
assert 'fallbackCardIDs' in DISCOVERY
assert 'Path.home() / "Library/Passes"' in CATALOG
assert '/var/mobile/Library/Passes' not in CATALOG

for obsolete in ('aircard.py', 'aircard_backend.py'):
    assert not (ROOT / obsolete).exists(), obsolete
assert (ROOT / 'card_assets.py').is_file()

print('AirCard Wallet Tool release checks passed')

# AirCard Wallet Tool for macOS

<img src="Assets/AirCardWalletToolIcon.png" alt="AirCard Wallet Tool icon" width="144">

A focused macOS utility that discovers Apple Wallet card hashes from the iPhone's read-only unified log, organizes card names, and applies custom card covers with the original Mac AirTraffic workflow.

## Features

- Trusted USB iPhone detection—no iPhone companion app, Developer Mode, or LocalDevVPN
- Non-destructive `os_trace_relay` discovery; protected Wallet files are never opened, moved, or rewritten during scanning
- Universal parsing for `PassKitUI` dashboard events, `passIDs[InSession]`, `passIDs[global]`, NFC activation JSON, and Wallet-context hash fallbacks
- Card names resolved from the Mac's local `~/Library/Passes` cache when available
- Editable local card names, saved automatically and preserved across rescans
- Batch import for plain hashes or `name + hash` lines, with validation and duplicate merging
- Per-card artwork selection and one-image-for-all assignment
- Large card previews with drag-and-drop artwork selection
- Live discovery count and scan progress, cover-write progress, and confirmation before every cover write
- Original three-asset cover write: `@3x` PNG, `@2x` PNG, and PDF
- Real unlink of `.cache` and `.pkcache` rendered files so Wallet rebuilds the cover
- Copy one hash, copy all hashes, export JSON, and automatic local persistence
- English and Simplified Chinese UI; English is the default

Passcode themes, wallpapers, protected Wallet-database extraction, NFC pairing, and unrelated iOS features have been removed.

## Use

1. Connect the iPhone to the Mac with a USB cable.
2. Unlock the iPhone and choose **Trust This Computer** if prompted.
3. Open **AirCard Wallet Tool** and click **Read all card hashes**.
4. Open Wallet once on the iPhone. Hashes appear live as Wallet emits its normal system-log events; click **Finish scan** after the list is populated.
5. Rename cards locally or use **Import hashes** to merge a pasted list.
6. Drag an image onto a large card preview, or choose an image manually.
7. Review the preview and confirm before applying the selected covers. The app shows the current card, write stage, and overall progress.
8. When the success reminder appears, completely close Wallet on the iPhone and open it again so it refreshes the rendered card faces.

Imported text may contain one hash per line, several hashes on one line, or entries such as `Transit Card, AAAAAAAAAAAAAAAAAAAAAAAAAAA=`. Card names, hashes, and selected artwork paths are saved automatically and restored when the app opens again. Renamed display names stay local and are included in exported JSON; they are not written into Wallet.

## Scan safety

Scanning is read-only. The app connects to Apple's `com.apple.os_trace_relay` service and extracts hashes only from Wallet-related log records. It does not read `passes23.sqlite` from the iPhone and does not unlink or invalidate Wallet caches during discovery.

Applying a custom cover remains a separate write operation. It writes the three standard artwork assets and removes only the corresponding rendered-cover cache files. After a successful write, completely close and reopen Wallet to refresh the cover.

## 中文说明

本工具通过已信任的 USB 连接，从 iPhone 的只读统一日志中发现 Apple Wallet 卡片 Hash，然后可以整理卡片名称并选择图片修改封面。无需手机 App、开发者模式、LocalDevVPN，也不会读取或移动手机上的 Wallet 数据库文件。

点击“读取全部卡片 Hash”后，在 iPhone 上打开一次 Wallet。工具会实时解析 `PassKitUI`、`passd` 和 `nfcd` 产生的正常系统日志，并识别 `passIDs[global]` 等记录；列表完整后点击“完成扫描”。扫描不会破坏原有卡片封面，也不需要重启手机。

支持修改本地卡片名称、批量导入纯 Hash 或“名称 + Hash”、大卡片封面预览、拖拽图片到卡片、单卡选择封面、为全部卡片指定同一张封面，以及批量写入。扫描与写入都会显示实时进度，写入前必须预览并二次确认；写入完成后会提醒在 iPhone 上完全关闭并重新打开 Wallet。卡片名称、Hash 和已选择的封面路径都会自动保存，重新打开软件或重新扫描时不会被重置。本地名称不会写入 Wallet。

扫描是只读操作；封面写入仍是独立的修改操作。写入时只更新三个标准素材，并移除对应卡片的封面渲染缓存。写入成功后，彻底关闭并重新打开 Wallet 即可刷新封面。

## Build

Requires macOS 14 or newer, Xcode command-line tools, and Python 3.

```sh
./build.sh
```

The resulting image is `build/AirCard-Wallet-Tool.dmg`.

The USB and AirTraffic implementation is derived from [Mak5er/AirCard](https://github.com/Mak5er/AirCard) and AirLift.

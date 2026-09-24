# AirCard Wallet Tool for macOS

A focused macOS utility that reads every Apple Wallet card name and hash over USB, organizes the results, and applies custom card covers with the original Mac AirTraffic workflow.

## Features

- Trusted USB iPhone detection—no iPhone companion app, Developer Mode, or LocalDevVPN
- One-click direct read of `passes23.sqlite`; no device-log or card-by-card discovery
- Card name and 28-character Wallet directory-hash extraction
- Editable local card names, saved automatically and preserved across rescans
- Batch import for plain hashes or `name + hash` lines, with validation and duplicate merging
- Per-card artwork selection and one-image-for-all assignment
- Original three-asset cover write: `@3x` PNG, `@2x` PNG, and PDF
- Real unlink of `.cache` and `.pkcache` rendered files so Wallet rebuilds the cover
- Copy one hash, copy all hashes, export JSON, and automatic local persistence
- English and Simplified Chinese UI; English is the default

Passcode themes, wallpapers, device-log scanning, side-button instructions, and unrelated iOS features have been removed.

## Use

1. Connect the iPhone to the Mac with a USB cable.
2. Unlock the iPhone and choose **Trust This Computer** if prompted.
3. Open **AirCard Wallet Tool** and click **Read all card hashes**.
4. Rename cards locally or use **Import hashes** to merge a pasted list.
5. Choose artwork for one card or all cards, then apply the selected covers.
6. Reopen Wallet after writing so it rebuilds the rendered card faces.

Imported text may contain one hash per line, several hashes on one line, or entries such as `Transit Card, AAAAAAAAAAAAAAAAAAAAAAAAAAA=`. Card names, hashes, and selected artwork paths are saved automatically and restored when the app opens again. Renamed display names stay local and are included in exported JSON; they are not written into Wallet.

## Important Wallet recovery information

The AirTraffic read primitive temporarily moves protected files and then writes them back. Reading Wallet metadata can make Wallet cards disappear temporarily.

Restart the iPhone and wait several minutes. If the cards do not return, open **Settings › Wallet & Apple Pay › AutoFill Cards**, select an existing card and try to add it. After iOS reports that the card already exists, reopen Wallet.

After recovery, also open **Settings › Wallet & Apple Pay › Express Transit Card** and reselect the default transit card if Wallet reset that preference.

## 中文说明

本工具通过已信任的 USB 连接，一次读取全部 Apple Wallet 卡片名称和 Hash，然后可以直接选择图片修改卡片封面。无需手机 App、开发者模式、LocalDevVPN，也不需要打开 Apple Pay 后逐张识别卡片。

支持修改本地卡片名称、批量导入纯 Hash 或“名称 + Hash”、单卡选择封面、为全部卡片指定同一张封面，以及批量写入。卡片名称、Hash 和已选择的封面路径都会自动保存，重新打开软件或重新扫描时不会被重置。本地名称不会写入 Wallet。

扫描会暂时移动受保护的 Wallet 文件，可能导致卡片暂时消失。请立即保存扫描结果，然后重启 iPhone 并等待几分钟。若卡片没有恢复，请进入 **设置 › 钱包与 Apple Pay › 自动填充卡片**，选择任意原有卡片并尝试添加。系统提示卡片已存在后，重新打开 Wallet。

恢复完成后，还需要进入 **设置 › 钱包与 Apple Pay › 快捷交通卡**，如果默认交通卡设置被重置，请重新选择原来的快捷交通卡。

## Build

Requires macOS 14 or newer, Xcode command-line tools, and Python 3.

```sh
./build.sh
```

The resulting image is `build/AirCard-Wallet-Tool.dmg`.

The USB and AirTraffic implementation is derived from [Mak5er/AirCard](https://github.com/Mak5er/AirCard) and AirLift.

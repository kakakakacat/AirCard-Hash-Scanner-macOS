# AirCard Hash Scanner for macOS

A minimal macOS utility that reads all Apple Wallet card names and hashes in one operation over a trusted USB connection.

## What remains

- USB iPhone detection and trust pairing
- Direct read of `passes23.sqlite`
- Card name and 28-character Wallet directory-hash extraction
- Editable local card names that never write back to Wallet
- Batch import for plain hashes or `name + hash` lines, with duplicate merging
- Copy one hash, copy all hashes, export JSON, and local result persistence
- English and Simplified Chinese UI; English is the default

There is no device-log scanning, card-by-card interaction, iPhone companion app, Developer Mode setup, LocalDevVPN, artwork writing, passcode theming, or wallpaper support.

## Use

1. Connect the iPhone to the Mac with a USB cable.
2. Unlock the iPhone and choose **Trust This Computer** if prompted.
3. Open AirCard Hash Scanner and click **Read all card hashes**.
4. Optionally rename cards locally or use **Import hashes** to merge a pasted list.
5. Save the results immediately. Use the hashes only with a separate desktop tool.

Imported text may contain one hash per line, several hashes on one line, or entries such as `Transit Card, AAAAAAAAAAAAAAAAAAAAAAAAAAA=`. Renamed display names are stored only by this Mac app and are included in exported JSON.

## Important Wallet warning

The AirTraffic read primitive temporarily moves protected files and then writes them back. Reading Wallet metadata can make Wallet cards disappear temporarily.

Restart the iPhone and wait several minutes. If the cards do not return, open **Settings › Wallet & Apple Pay › AutoFill Cards**, select any existing card and try to add it. After iOS reports that the card already exists, reopen Wallet.

## 中文说明

本工具通过已信任的 USB 连接，一次读取全部 Apple Wallet 卡片名称和 Hash。无需手机 App、开发者模式、LocalDevVPN，也不需要打开 Apple Pay 后逐张选择卡片。可以在工具内修改本地卡片名称，并批量粘贴导入纯 Hash 或“名称 + Hash”格式；修改后的名称不会写回 Wallet。

扫描会暂时移动受保护的 Wallet 文件，可能导致卡片暂时消失。请立即保存扫描结果，然后重启 iPhone 并等待几分钟。若卡片没有恢复，请进入 **设置 › 钱包与 Apple Pay › 自动填充卡片**，选择任意原有卡片并尝试添加。系统提示卡片已存在后，重新打开 Wallet。

## Build

Requires macOS 14 or newer, Xcode command-line tools, and Python 3.

```sh
./build.sh
```

The resulting image is `build/AirCard-Hash-Scanner.dmg`.

The USB and AirTraffic implementation is derived from [Mak5er/AirCard](https://github.com/Mak5er/AirCard) and AirLift.

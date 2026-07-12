<div align="center">

# GameMaster

**在 Mac 上暢玩 Windows 遊戲——原生、友善、簡單。**

一款原生 macOS 應用程式，讓任何人都能透過簡單的圖形介面安裝並執行 Windows 遊戲，
由 Apple 的 Game Porting Toolkit 驅動。

[English](README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

[![CI](https://github.com/MatrixReligio/GameMaster/actions/workflows/ci.yml/badge.svg)](https://github.com/MatrixReligio/GameMaster/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange)

<a href="https://www.producthunt.com/products/gamemaster-2?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-gamemaster-2" target="_blank" rel="noopener noreferrer"><img alt="GameMaster - Play Windows games on your Mac — Steam &amp; CS2 just work | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1194404&amp;theme=light&amp;t=1783872276501"></a>

</div>

## 功能簡介

GameMaster 把在 Mac 上執行 Windows 遊戲的命令列繁瑣操作，變成幾次點擊：

- **一鍵安裝 Steam**——把 Windows 版 Steam 裝進獨立環境，暢玩你現有的遊戲庫。
- **任意 Windows 程式**——把任意 `.exe` 或 `.msi` 拖到視窗即可執行，或加入程式庫。
- **Apple 的 DirectX 轉換**——DirectX 11/12 遊戲透過 Apple 的 D3DMetal
  （Game Porting Toolkit 3）執行，獲得 Metal 原生效能。
- **預設簡單，需要時強大**——一開始就有合理的預設值；Retina、同步模式、MetalFX、
  光線追蹤，以及每款遊戲的環境變數，都只在一個展開三角形之後。
- **原生 macOS**——以 SwiftUI 撰寫，遵循人機介面指南，自動適應淺色／深色，並提供
  英文、簡體中文、繁體中文、日文、韓文的在地化。

## 系統需求

- **macOS 26 (Tahoe) 或更新版本**
- **Apple Silicon**（M1 或更新）
- **Rosetta 2**——若缺少，GameMaster 會提示你
  （`softwareupdate --install-rosetta`）

## 安裝

1. 從 [Releases](https://github.com/MatrixReligio/GameMaster/releases/latest)
   下載最新的 `GameMaster-x.y.z.dmg`。
2. 開啟 DMG，將 **GameMaster** 拖入「應用程式」。
3. 啟動它。首次執行精靈會下載 Windows 執行環境，並引導你完成所有設定。

應用程式會自動更新（Sparkle，經 Apple 簽署與公證）。

## 圖形層的運作方式（以及為何需要你自行下載）

GameMaster 內建一套**開源 Wine 執行環境**（LGPL），已包含 DirectX 11/12 轉換，
因此 Steam 與大多數遊戲開箱即用。

Apple 的 **D3DMetal** 函式庫本身是專有軟體，**第三方應用程式不得再分發**。若要更新至
Apple 最新的圖形層，GameMaster 會引導你從
[Apple Developer](https://developer.apple.com/download/all/)
下載免費的 *"Evaluation environment for Windows games"*（Windows 遊戲評估環境）
（只需免費的 Apple ID 即可），並在本地匯入——這些函式庫始終不離開你的機器，
GameMaster 也從不打包或重新託管它們。這正是整個生態系共同遵守的界線。

## 從原始碼建置

```bash
brew install xcodegen swiftlint swiftformat
git clone https://github.com/MatrixReligio/GameMaster.git
cd GameMaster
swift test          # run the core test suite
xcodegen generate   # produce GameMaster.xcodeproj
open GameMaster.xcodeproj
```

純邏輯核心位於 Swift 套件（`Sources/GM*`）並具備完整的測試覆蓋；SwiftUI 應用程式外殼
由 XcodeGen 從 `project.yml` 產生。

## 架構

| 模組 | 職責 |
|--------|----------------|
| `GMModel` | 領域型別（遊戲瓶、程式、執行環境）——純值 |
| `GMSystem` | 處理程序／下載／磁碟映像／雜湊等基礎操作（以協定注入） |
| `GMRuntime` | Wine 執行環境安裝流程 + Apple D3DMetal 匯入 |
| `GMBottles` | 遊戲瓶生命週期、環境組合、登錄檔調整 |
| `GMLaunch` | 啟動程式、記錄、處理程序控制 |
| `GMApps` | 一鍵安裝程式、程式庫、應用程式層級狀態 |

## 參與貢獻

歡迎貢獻——請參閱 [CONTRIBUTING.md](CONTRIBUTING.md)。所有開發皆為測試驅動；
每次推送時，`swift test`、SwiftLint（嚴格模式）、SwiftFormat 與在地化覆蓋率都會在 CI 執行。

## 法律聲明

GameMaster 以 [Apache-2.0](LICENSE) 授權，不打包任何 Apple 專有軟體。Steam 是
Valve Corporation 的商標；Windows 與 DirectX 是 Microsoft 的商標；Apple、Metal、
macOS 是 Apple Inc. 的商標。GameMaster 與上述任何一方均無隸屬或背書關係。第三方聲明
請見 [NOTICE](NOTICE)。

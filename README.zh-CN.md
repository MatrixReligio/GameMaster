<div align="center">

# GameMaster

**在 Mac 上畅玩 Windows 游戏——原生、友好、简单。**

一款原生 macOS 应用，让任何人都能通过简单的图形界面安装并运行 Windows 游戏，
由 Apple 的 Game Porting Toolkit 驱动。

[English](README.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

[![CI](https://github.com/MatrixReligio/GameMaster/actions/workflows/ci.yml/badge.svg)](https://github.com/MatrixReligio/GameMaster/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange)

<a href="https://www.producthunt.com/products/gamemaster-2?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-gamemaster-2" target="_blank" rel="noopener noreferrer"><img alt="GameMaster - Play Windows games on your Mac — Steam &amp; CS2 just work | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1194404&amp;theme=light&amp;t=1783872276501"></a>

</div>

## 功能简介

GameMaster 把在 Mac 上运行 Windows 游戏的命令行折腾，变成几次点击：

- **一键安装 Steam**——把 Windows 版 Steam 装进独立环境，畅玩你现有的游戏库。
- **任意 Windows 程序**——把任意 `.exe` 或 `.msi` 拖到窗口即可运行，或加入程序库。
- **Apple 的 DirectX 转换**——DirectX 11/12 游戏通过 Apple 的 D3DMetal
  （Game Porting Toolkit 3）运行，获得 Metal 原生性能。
- **简约不简单**——默认开箱即用；Retina、同步模式、MetalFX、光线追踪、每款游戏的
  环境变量都收纳在一个展开箭头之后。
- **原生 macOS**——SwiftUI 编写，遵循人机界面指南，自适应浅色/深色，支持
  英语、简体中文、繁体中文、日语、韩语。

## 系统要求

- **macOS 26 (Tahoe) 或更高版本**
- **Apple Silicon**（M1 或更新）
- **Rosetta 2**——若缺失，GameMaster 会提示你
  （`softwareupdate --install-rosetta`）

## 安装

1. 从 [Releases](https://github.com/MatrixReligio/GameMaster/releases/latest)
   下载最新的 `GameMaster-x.y.z.dmg`。
2. 打开 DMG，将 **GameMaster** 拖入“应用程序”。
3. 启动它。首次运行向导会下载 Windows 运行时并引导你完成一切设置。

应用会自动更新（Sparkle，经 Apple 签名与公证）。

## 图形层的工作方式（以及为何需要你自行下载）

GameMaster 内置一个**开源 Wine 运行时**（LGPL），已包含 DirectX 11/12 转换，
因此 Steam 与大多数游戏开箱即用。

Apple 的 **D3DMetal** 库本身是专有软件，**第三方应用不得再分发**。若要更新到
Apple 最新的图形层，GameMaster 会引导你从
[Apple Developer](https://developer.apple.com/download/all/)
下载免费的 *“Evaluation environment for Windows games”*（免费 Apple ID 即可），
并在本地导入——这些库始终不离开你的机器，GameMaster 从不打包或转存它们。
这也是整个生态共同遵守的边界。

## 从源码构建

```bash
brew install xcodegen swiftlint swiftformat
git clone https://github.com/MatrixReligio/GameMaster.git
cd GameMaster
swift test          # 运行核心测试
xcodegen generate   # 生成 GameMaster.xcodeproj
open GameMaster.xcodeproj
```

纯逻辑核心位于 Swift 包（`Sources/GM*`）并具备完整测试覆盖；SwiftUI 应用外壳
由 XcodeGen 从 `project.yml` 生成。

## 架构

| 模块 | 职责 |
|------|------|
| `GMModel` | 领域类型（游戏瓶、程序、运行时）——纯值类型 |
| `GMSystem` | 进程 / 下载 / 磁盘映像 / 哈希 基础设施（协议注入） |
| `GMRuntime` | Wine 运行时安装流程 + Apple D3DMetal 导入 |
| `GMBottles` | 游戏瓶生命周期、环境组装、注册表调优 |
| `GMLaunch` | 程序启动、日志、进程控制 |
| `GMApps` | 一键安装器、程序库、应用级状态 |

## 参与贡献

欢迎贡献——请参阅 [CONTRIBUTING.md](CONTRIBUTING.md)。所有开发均测试驱动；
`swift test`、SwiftLint（严格）、SwiftFormat 与本地化覆盖率在每次推送时都会在 CI 运行。

## 法律声明

GameMaster 以 [Apache-2.0](LICENSE) 授权，不打包任何 Apple 专有软件。Steam 是
Valve Corporation 的商标；Windows 与 DirectX 是 Microsoft 的商标；Apple、Metal、
macOS 是 Apple Inc. 的商标。GameMaster 与它们无任何隶属或背书关系。第三方声明见
[NOTICE](NOTICE)。

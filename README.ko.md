<div align="center">

# GameMaster

**Windows 게임을 Mac에서 — 친숙하고 네이티브한 방식으로.**

누구나 간단한 그래픽 인터페이스로 Windows 게임을 설치하고 플레이할 수 있는
네이티브 macOS 앱으로, Apple의 Game Porting Toolkit으로 구동됩니다.

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-Hant.md) · [日本語](README.ja.md) · **한국어**

[![CI](https://github.com/MatrixReligio/GameMaster/actions/workflows/ci.yml/badge.svg)](https://github.com/MatrixReligio/GameMaster/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange)

<a href="https://www.producthunt.com/products/gamemaster-2?embed=true&amp;utm_source=badge-featured&amp;utm_medium=badge&amp;utm_campaign=badge-gamemaster-2" target="_blank" rel="noopener noreferrer"><img alt="GameMaster - Play Windows games on your Mac — Steam &amp; CS2 just work | Product Hunt" width="250" height="54" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1194404&amp;theme=light&amp;t=1783872276501"></a>

</div>

## 주요 기능

GameMaster는 Mac에서 Windows 게임을 실행하기 위한 번거로운 명령줄 작업을
몇 번의 클릭으로 바꿔 줍니다:

- **원클릭 Steam** — Windows용 Steam을 독립된 환경에 설치하고 기존 라이브러리를
  바로 플레이하세요.
- **모든 Windows 프로그램** — 어떤 `.exe`나 `.msi`든 창으로 끌어다 놓으면 실행하거나
  라이브러리에 추가할 수 있습니다.
- **Apple의 DirectX 변환** — DirectX 11/12 게임은 Apple의 D3DMetal
  (Game Porting Toolkit 3)을 통해 실행되어 Metal 네이티브 성능을 냅니다.
- **기본은 단순하게, 필요할 땐 강력하게** — 처음에는 합리적인 기본값으로 시작하고,
  Retina, 동기화 모드, MetalFX, 레이 트레이싱, 게임별 환경 변수는 펼침 삼각형
  하나만 열면 바로 사용할 수 있습니다.
- **네이티브 macOS** — SwiftUI로 제작되어 휴먼 인터페이스 가이드라인을 따르고,
  라이트/다크 모드에 대응하며, 영어, 간체 중국어, 번체 중국어, 일본어, 한국어로
  현지화되어 있습니다.

## 시스템 요구 사항

- **macOS 26(Tahoe) 이상**
- **Apple Silicon**(M1 이상)
- **Rosetta 2** — 설치되어 있지 않으면 GameMaster가 안내합니다
  (`softwareupdate --install-rosetta`)

## 설치

1. [Releases](https://github.com/MatrixReligio/GameMaster/releases/latest)에서
   최신 `GameMaster-x.y.z.dmg`를 다운로드하세요.
2. DMG를 열고 **GameMaster**를 「응용 프로그램」으로 끌어다 놓으세요.
3. 실행하세요. 첫 실행 마법사가 Windows 런타임을 다운로드하고 모든 과정을 안내합니다.

앱은 자동으로 업데이트됩니다(Sparkle, Apple의 서명 및 공증 완료).

## 그래픽 계층의 작동 방식(그리고 왜 별도로 다운로드하는지)

GameMaster에는 DirectX 11/12 변환을 이미 포함한 **오픈 소스 Wine 런타임**(LGPL)이
함께 제공되므로, Steam과 대부분의 게임이 기본 상태에서 작동합니다.

Apple의 **D3DMetal** 라이브러리 자체는 독점 소프트웨어이며, 서드파티 앱이
**법적으로 재배포할 수 없습니다**. Apple의 최신 그래픽 계층으로 업데이트하려면,
GameMaster의 안내에 따라 [Apple Developer](https://developer.apple.com/download/all/)에서
무료 *"Evaluation environment for Windows games"*(Windows 게임용 평가 환경)를
다운로드하고(무료 Apple ID면 충분합니다) 로컬로 가져옵니다——이 라이브러리는 절대
사용자의 컴퓨터를 벗어나지 않으며, GameMaster는 이를 결코 번들로 포함하거나 다시
호스팅하지 않습니다. 이는 생태계 전체가 지키는 것과 동일한 경계입니다.

## 소스에서 빌드하기

```bash
brew install xcodegen swiftlint swiftformat
git clone https://github.com/MatrixReligio/GameMaster.git
cd GameMaster
swift test          # run the core test suite
xcodegen generate   # produce GameMaster.xcodeproj
open GameMaster.xcodeproj
```

순수 로직 코어는 완전한 테스트 커버리지를 갖춘 Swift 패키지(`Sources/GM*`)에 있으며,
SwiftUI 앱 셸은 XcodeGen이 `project.yml`에서 생성합니다.

## 아키텍처

| 모듈 | 역할 |
|--------|----------------|
| `GMModel` | 도메인 타입(보틀, 프로그램, 런타임) — 순수 값 |
| `GMSystem` | 프로세스 / 다운로드 / 디스크 이미지 / 해싱 기본 요소(프로토콜 주입) |
| `GMRuntime` | Wine 런타임 설치 파이프라인 + Apple D3DMetal 가져오기 |
| `GMBottles` | 보틀 수명 주기, 환경 구성, 레지스트리 조정 |
| `GMLaunch` | 프로그램 실행, 로깅, 프로세스 제어 |
| `GMApps` | 원클릭 설치 프로그램, 프로그램 라이브러리, 앱 전역 상태 |

## 기여하기

기여를 환영합니다 — [CONTRIBUTING.md](CONTRIBUTING.md)를 참고하세요. 모든 작업은
테스트 주도로 이루어지며, 푸시할 때마다 `swift test`, SwiftLint(strict), SwiftFormat,
현지화 커버리지가 CI에서 실행됩니다.

## 법적 고지

GameMaster는 [Apache-2.0](LICENSE) 라이선스로 배포되며, Apple의 독점 소프트웨어를
전혀 번들로 포함하지 않습니다. Steam은 Valve Corporation의 상표입니다. Windows와
DirectX는 Microsoft의 상표입니다. Apple, Metal, macOS는 Apple Inc.의 상표입니다.
GameMaster는 이들 중 어느 곳과도 제휴하거나 보증을 받지 않았습니다. 서드파티 저작자
표시는 [NOTICE](NOTICE)를 참고하세요.

<div align="center">

# GameMaster

**Windows ゲームを Mac で——親しみやすく、ネイティブに動かそう。**

シンプルなグラフィカルインターフェースを通じて、誰もが Windows ゲームをインストールして
プレイできるネイティブ macOS アプリ。Apple の Game Porting Toolkit を搭載しています。

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-Hant.md) · **日本語** · [한국어](README.ko.md)

[![CI](https://github.com/MatrixReligio/GameMaster/actions/workflows/ci.yml/badge.svg)](https://github.com/MatrixReligio/GameMaster/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange)

</div>

## 特長

GameMaster は、Mac で Windows ゲームを動かすためのコマンドライン操作を、
わずか数クリックに変えます:

- **ワンクリック Steam** — Windows 版 Steam を専用環境にインストールし、既存の
  ライブラリをすぐにプレイできます。
- **あらゆる Windows プログラム** — 任意の `.exe` や `.msi` をウィンドウにドラッグ
  するだけで実行、またはライブラリに追加できます。
- **Apple の DirectX 変換** — DirectX 11/12 のゲームは Apple の D3DMetal
  （Game Porting Toolkit 3）を通じて動作し、Metal ネイティブのパフォーマンスを発揮します。
- **標準はシンプル、必要なときはパワフル** — 最初は無理のない既定値を用意。Retina、
  同期モード、MetalFX、レイトレーシング、ゲームごとの環境変数は、開閉用の三角形を
  ひとつ開くだけで利用できます。
- **ネイティブ macOS** — SwiftUI 製で、ヒューマンインターフェイスガイドラインに準拠し、
  ライト/ダークに対応。英語、簡体字中国語、繁体字中国語、日本語、韓国語に
  ローカライズされています。

## 動作要件

- **macOS 26 (Tahoe) 以降**
- **Apple Silicon**（M1 以降）
- **Rosetta 2** — 未インストールの場合、GameMaster が案内します
  （`softwareupdate --install-rosetta`）

## インストール

1. [Releases](https://github.com/MatrixReligio/GameMaster/releases/latest) から
   最新の `GameMaster-x.y.z.dmg` をダウンロードします。
2. DMG を開き、**GameMaster** を「アプリケーション」にドラッグします。
3. 起動します。初回起動時のウィザードが Windows ランタイムをダウンロードし、
   すべての設定を案内します。

アプリは自動的に更新されます（Sparkle、Apple による署名と公証済み）。

## グラフィックスレイヤーの仕組み（そして別途ダウンロードが必要な理由）

GameMaster には、DirectX 11/12 変換をすでに含む**オープンソースの Wine ランタイム**
（LGPL）が同梱されているため、Steam やほとんどのゲームは初期状態で動作します。

Apple の **D3DMetal** ライブラリ自体はプロプライエタリであり、サードパーティ製アプリが
**再配布することは法的に認められていません**。Apple の最新グラフィックスレイヤーに
更新するには、GameMaster の案内に従って
[Apple Developer](https://developer.apple.com/download/all/) から無償の
*"Evaluation environment for Windows games"*（Windows ゲーム用評価環境）を
ダウンロードし（無料の Apple ID があれば十分です）、ローカルにインポートします——
これらのライブラリがあなたのマシンから出ることは決してなく、GameMaster がそれらを
同梱したり再ホストしたりすることもありません。これは、エコシステム全体が尊重している
のと同じ境界線です。

## ソースからのビルド

```bash
brew install xcodegen swiftlint swiftformat
git clone https://github.com/MatrixReligio/GameMaster.git
cd GameMaster
swift test          # run the core test suite
xcodegen generate   # produce GameMaster.xcodeproj
open GameMaster.xcodeproj
```

純粋なロジックのコアは、完全なテストカバレッジを備えた Swift パッケージ
（`Sources/GM*`）にあります。SwiftUI のアプリシェルは、XcodeGen が `project.yml`
から生成します。

## アーキテクチャ

| モジュール | 責務 |
|--------|----------------|
| `GMModel` | ドメイン型（ボトル、プログラム、ランタイム）——純粋な値 |
| `GMSystem` | プロセス／ダウンロード／ディスクイメージ／ハッシュの基本操作（プロトコル注入） |
| `GMRuntime` | Wine ランタイムのインストールパイプライン + Apple D3DMetal のインポート |
| `GMBottles` | ボトルのライフサイクル、環境の構成、レジストリの調整 |
| `GMLaunch` | プログラムの起動、ロギング、プロセス制御 |
| `GMApps` | ワンクリックインストーラー、プログラムライブラリ、アプリ全体の状態 |

## コントリビューション

コントリビューションを歓迎します——[CONTRIBUTING.md](CONTRIBUTING.md) をご覧ください。
すべての作業はテスト駆動で行われます。プッシュのたびに、`swift test`、
SwiftLint（strict）、SwiftFormat、ローカライズのカバレッジが CI で実行されます。

## 法的事項

GameMaster は [Apache-2.0](LICENSE) の下でライセンスされており、Apple の
プロプライエタリソフトウェアを一切同梱していません。Steam は Valve Corporation の
商標です。Windows と DirectX は Microsoft の商標です。Apple、Metal、macOS は
Apple Inc. の商標です。GameMaster はこれらのいずれとも提携しておらず、承認も
受けていません。サードパーティの帰属表示については [NOTICE](NOTICE) をご覧ください。

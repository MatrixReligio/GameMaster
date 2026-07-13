#!/usr/bin/env python3
"""Generates App/Resources/Localizable.xcstrings from the table below.

Source language is English (the key itself). Every key carries zh-Hans,
zh-Hant, ja, ko translations; scripts/check-localizations.py enforces that
every String(localized:) key in App/Sources exists here with all languages.
"""
import json
import pathlib

# key: (zh-Hans, zh-Hant, ja, ko)
T = {
    "Check for Updates…": ("检查更新…", "檢查更新…", "アップデートを確認…", "업데이트 확인…"),
    "Something Went Wrong": ("出了点问题", "出了點問題", "問題が発生しました", "문제가 발생했습니다"),
    "OK": ("好", "好", "OK", "확인"),
    "No Bottle Yet": ("还没有游戏瓶", "還沒有遊戲瓶", "ボトルがありません", "보틀이 없습니다"),
    "Create a bottle — a private Windows environment — to install Steam or run Windows games.":
        ("创建一个游戏瓶（独立的 Windows 环境），即可安装 Steam 或运行 Windows 游戏。",
         "建立一個遊戲瓶（獨立的 Windows 環境），即可安裝 Steam 或執行 Windows 遊戲。",
         "ボトル（独立した Windows 環境)を作成して、Steam のインストールや Windows ゲームの実行ができます。",
         "보틀(독립된 Windows 환경)을 만들어 Steam을 설치하거나 Windows 게임을 실행하세요."),
    "Create Bottle": ("创建游戏瓶", "建立遊戲瓶", "ボトルを作成", "보틀 만들기"),
    "My Games": ("我的游戏", "我的遊戲", "マイゲーム", "내 게임"),
    "Bottles": ("游戏瓶", "遊戲瓶", "ボトル", "보틀"),
    "Delete Bottle…": ("删除游戏瓶…", "刪除遊戲瓶…", "ボトルを削除…", "보틀 삭제…"),
    "New Bottle": ("新建游戏瓶", "新增遊戲瓶", "新規ボトル", "새 보틀"),
    "Create a new Windows environment": ("创建一个新的 Windows 环境", "建立一個新的 Windows 環境",
                                          "新しい Windows 環境を作成します", "새 Windows 환경을 만듭니다"),
    "Delete this bottle and everything installed in it?":
        ("删除这个游戏瓶以及其中安装的所有内容？", "刪除這個遊戲瓶以及其中安裝的所有內容？",
         "このボトルと中にインストールされたすべてを削除しますか？", "이 보틀과 그 안에 설치된 모든 항목을 삭제할까요?"),
    "Delete": ("删除", "刪除", "削除", "삭제"),
    "“%@” will be moved to oblivion. This cannot be undone.":
        ("“%@”将被永久删除。此操作无法撤销。", "「%@」將被永久刪除。此操作無法復原。",
         "「%@」は完全に削除されます。この操作は取り消せません。", "“%@”이(가) 영구히 삭제됩니다. 되돌릴 수 없습니다."),
    "Runtime not installed": ("运行时未安装", "執行環境未安裝", "ランタイム未インストール", "런타임이 설치되지 않음"),
    "Installing runtime…": ("正在安装运行时…", "正在安裝執行環境…", "ランタイムをインストール中…", "런타임 설치 중…"),
    "D3DMetal %@ ready": ("D3DMetal %@ 已就绪", "D3DMetal %@ 已就緒", "D3DMetal %@ 準備完了", "D3DMetal %@ 준비됨"),
    "Runtime ready": ("运行时已就绪", "執行環境已就緒", "ランタイム準備完了", "런타임 준비됨"),
    "Run Windows Program…": ("运行 Windows 程序…", "執行 Windows 程式…", "Windows プログラムを実行…", "Windows 프로그램 실행…"),
    "Run any Windows .exe or .msi in this bottle":
        ("在此游戏瓶中运行任意 Windows .exe 或 .msi", "在此遊戲瓶中執行任意 Windows .exe 或 .msi",
         "このボトルで任意の Windows .exe / .msi を実行", "이 보틀에서 임의의 Windows .exe/.msi 실행"),
    "Logs": ("日志", "日誌", "ログ", "로그"),
    "Bottle Settings": ("游戏瓶设置", "遊戲瓶設定", "ボトル設定", "보틀 설정"),
    "Force Stop All": ("强制全部停止", "強制全部停止", "すべて強制終了", "모두 강제 종료"),
    "Terminate every Windows process in this bottle":
        ("终止此游戏瓶中的所有 Windows 进程", "終止此遊戲瓶中的所有 Windows 處理程序",
         "このボトル内のすべての Windows プロセスを終了します", "이 보틀의 모든 Windows 프로세스를 종료합니다"),
    "How do you want to open this program?":
        ("要如何打开这个程序？", "要如何開啟這個程式？", "このプログラムをどのように開きますか？", "이 프로그램을 어떻게 여시겠습니까?"),
    "Run Once": ("仅运行一次", "僅執行一次", "一度だけ実行", "한 번만 실행"),
    "Add to Library and Run": ("添加到程序库并运行", "加入程式庫並執行", "ライブラリに追加して実行", "라이브러리에 추가 후 실행"),
    "Cancel": ("取消", "取消", "キャンセル", "취소"),
    "Or run another Windows program…": ("或运行其他 Windows 程序…", "或執行其他 Windows 程式…",
                                         "または他の Windows プログラムを実行…", "또는 다른 Windows 프로그램 실행…"),
    "Install Steam for Windows": ("安装 Windows 版 Steam", "安裝 Windows 版 Steam",
                                   "Windows 版 Steam をインストール", "Windows용 Steam 설치"),
    "Set up the Windows version of Steam with one click, then install and play your Windows games.":
        ("一键装好 Windows 版 Steam，然后安装并畅玩你的 Windows 游戏。",
         "一鍵裝好 Windows 版 Steam，然後安裝並暢玩你的 Windows 遊戲。",
         "ワンクリックで Windows 版 Steam をセットアップし、Windows ゲームをインストールしてプレイ。",
         "클릭 한 번으로 Windows용 Steam을 설치하고 Windows 게임을 즐기세요."),
    "Install Steam": ("安装 Steam", "安裝 Steam", "Steam をインストール", "Steam 설치"),
    "Running": ("运行中", "執行中", "実行中", "실행 중"),
    "Play": ("开始游戏", "開始遊戲", "プレイ", "플레이"),
    "Upgrading runtime…": ("正在升级运行环境…", "正在升級執行環境…", "ランタイムをアップグレード中…", "런타임 업그레이드 중…"),
    "Starting…": ("启动中…", "啟動中…", "起動中…", "시작 중…"),
    "Closing…": ("关闭中…", "關閉中…", "終了中…", "종료 중…"),
    "Remove from Library": ("从程序库移除", "從程式庫移除", "ライブラリから削除", "라이브러리에서 제거"),
    "Downloading…": ("正在下载…", "正在下載…", "ダウンロード中…", "다운로드 중…"),
    "Installing…": ("正在安装…", "正在安裝…", "インストール中…", "설치 중…"),
    "Configuring…": ("正在配置…", "正在設定…", "設定中…", "구성 중…"),
    "Done": ("完成", "完成", "完了", "완료"),
    "Verifying…": ("正在校验…", "正在驗證…", "検証中…", "확인 중…"),
    "Unpacking…": ("正在解压…", "正在解壓…", "展開中…", "압축 해제 중…"),
    "Finishing…": ("即将完成…", "即將完成…", "仕上げ中…", "마무리 중…"),
    "Welcome to GameMaster": ("欢迎使用 GameMaster", "歡迎使用 GameMaster",
                               "GameMaster へようこそ", "GameMaster에 오신 것을 환영합니다"),
    "Play Windows games on your Mac. GameMaster sets up everything for you — no command line, no configuration files.":
        ("在 Mac 上畅玩 Windows 游戏。GameMaster 为你搞定一切——无需命令行，无需配置文件。",
         "在 Mac 上暢玩 Windows 遊戲。GameMaster 為你搞定一切——無需命令列，無需設定檔。",
         "Mac で Windows ゲームをプレイ。GameMaster がすべてをセットアップ — コマンドラインも設定ファイルも不要です。",
         "Mac에서 Windows 게임을 즐기세요. GameMaster가 모든 것을 설정해 드립니다 — 명령줄도 설정 파일도 필요 없습니다."),
    "Rosetta 2 is required. Run “softwareupdate --install-rosetta” in Terminal first.":
        ("需要 Rosetta 2。请先在“终端”中运行 “softwareupdate --install-rosetta”。",
         "需要 Rosetta 2。請先在「終端機」中執行 “softwareupdate --install-rosetta”。",
         "Rosetta 2 が必要です。まずターミナルで “softwareupdate --install-rosetta” を実行してください。",
         "Rosetta 2가 필요합니다. 먼저 터미널에서 “softwareupdate --install-rosetta”를 실행하세요."),
    "Install the Windows Runtime": ("安装 Windows 运行时", "安裝 Windows 執行環境",
                                     "Windows ランタイムをインストール", "Windows 런타임 설치"),
    "GameMaster downloads an open-source Windows compatibility runtime (about 240 MB) with Apple's DirectX translation support built in.":
        ("GameMaster 将下载一个开源的 Windows 兼容运行时（约 240 MB），内置 Apple 的 DirectX 转换支持。",
         "GameMaster 將下載一個開源的 Windows 相容執行環境（約 240 MB），內建 Apple 的 DirectX 轉換支援。",
         "GameMaster はオープンソースの Windows 互換ランタイム（約 240 MB、Apple の DirectX 変換サポート内蔵）をダウンロードします。",
         "GameMaster는 Apple의 DirectX 변환 지원이 내장된 오픈소스 Windows 호환 런타임(약 240MB)을 다운로드합니다."),
    "Runtime installed": ("运行时已安装", "執行環境已安裝", "ランタイムをインストールしました", "런타임 설치됨"),
    "Download and Install": ("下载并安装", "下載並安裝", "ダウンロードしてインストール", "다운로드 및 설치"),
    "Skip for Now": ("暂时跳过", "暫時略過", "今はスキップ", "지금은 건너뛰기"),
    "Continue": ("继续", "繼續", "続ける", "계속"),
    "Update Apple's Graphics Layer (Optional)":
        ("更新 Apple 图形层（可选）", "更新 Apple 圖形層（可選）",
         "Apple グラフィックスレイヤーを更新（任意）", "Apple 그래픽 레이어 업데이트(선택)"),
    "Your runtime already includes DirectX 11/12 translation. To update it to Apple's latest version, download “Evaluation environment for Windows games” from Apple (free Apple ID required) and import the DMG here.":
        ("你的运行时已内置 DirectX 11/12 转换。若要更新到 Apple 最新版本，请从 Apple 下载“Evaluation environment for Windows games”（需要免费 Apple ID），然后在此导入该 DMG。",
         "你的執行環境已內建 DirectX 11/12 轉換。若要更新到 Apple 最新版本，請從 Apple 下載「Evaluation environment for Windows games」（需要免費 Apple ID），然後在此匯入該 DMG。",
         "ランタイムには DirectX 11/12 変換が既に含まれています。Apple の最新版に更新するには、Apple から「Evaluation environment for Windows games」をダウンロードし（無料の Apple ID が必要）、その DMG をここで読み込んでください。",
         "런타임에는 DirectX 11/12 변환이 이미 포함되어 있습니다. Apple 최신 버전으로 업데이트하려면 Apple에서 “Evaluation environment for Windows games”를 다운로드한 후(무료 Apple ID 필요) 여기에서 DMG를 가져오세요."),
    "D3DMetal %@ active": ("D3DMetal %@ 已启用", "D3DMetal %@ 已啟用", "D3DMetal %@ 有効", "D3DMetal %@ 활성"),
    "Open Apple Downloads Page": ("打开 Apple 下载页面", "開啟 Apple 下載頁面",
                                   "Apple ダウンロードページを開く", "Apple 다운로드 페이지 열기"),
    "Import DMG…": ("导入 DMG…", "匯入 DMG…", "DMG を読み込む…", "DMG 가져오기…"),
    "Display": ("显示", "顯示", "ディスプレイ", "디스플레이"),
    "Retina resolution": ("Retina 分辨率", "Retina 解析度", "Retina 解像度", "Retina 해상도"),
    "Render at full pixel density on HiDPI displays":
        ("在 HiDPI 显示器上以完整像素密度渲染", "在 HiDPI 顯示器上以完整像素密度渲染",
         "HiDPI ディスプレイでフル解像度でレンダリング", "HiDPI 디스플레이에서 전체 픽셀 밀도로 렌더링"),
    "Graphics": ("图形", "圖形", "グラフィックス", "그래픽"),
    "DirectX translation": ("DirectX 转换", "DirectX 轉換", "DirectX 変換", "DirectX 변환"),
    "Automatic (recommended)": ("自动（推荐）", "自動（建議）", "自動（推奨）", "자동(권장)"),
    "Off": ("关闭", "關閉", "オフ", "끔"),
    "MetalFX upscaling (DLSS games)": ("MetalFX 超分辨率（DLSS 游戏）", "MetalFX 超解析度（DLSS 遊戲）",
                                        "MetalFX アップスケーリング（DLSS ゲーム）", "MetalFX 업스케일링(DLSS 게임)"),
    "Performance": ("性能", "效能", "パフォーマンス", "성능"),
    "Synchronization": ("同步方式", "同步方式", "同期方式", "동기화"),
    "ESync (default)": ("ESync（默认）", "ESync（預設）", "ESync（デフォルト）", "ESync(기본)"),
    "MSync (faster, experimental)": ("MSync（更快，实验性）", "MSync（更快，實驗性）",
                                      "MSync（高速・実験的）", "MSync(더 빠름, 실험적)"),
    "None": ("无", "無", "なし", "없음"),
    "Advanced": ("高级", "進階", "詳細", "고급"),
    "Metal performance HUD": ("Metal 性能面板", "Metal 效能面板", "Metal パフォーマンス HUD", "Metal 성능 HUD"),
    "Advertise AVX support": ("向游戏公开 AVX 支持", "向遊戲公開 AVX 支援", "AVX サポートをゲームに通知", "게임에 AVX 지원 알리기"),
    "Ray tracing (DXR)": ("光线追踪（DXR）", "光線追蹤（DXR）", "レイトレーシング（DXR）", "레이 트레이싱(DXR)"),
    "Automatic": ("自动", "自動", "自動", "자동"),
    "On": ("开启", "開啟", "オン", "켬"),
    "Environment variables (one per line, KEY=value)":
        ("环境变量（每行一个，KEY=value）", "環境變數（每行一個，KEY=value）",
         "環境変数（1 行に 1 つ、KEY=value）", "환경 변수(한 줄에 하나, KEY=value)"),
    "Save": ("保存", "儲存", "保存", "저장"),
    "No Logs Yet": ("暂无日志", "暫無日誌", "ログはまだありません", "로그가 없습니다"),
    "Launch a program and its output will appear here.":
        ("运行程序后，其输出会显示在这里。", "執行程式後，其輸出會顯示在這裡。",
         "プログラムを実行すると、その出力がここに表示されます。", "프로그램을 실행하면 출력이 여기에 표시됩니다."),
    "Close": ("关闭", "關閉", "閉じる", "닫기"),
    "Show in Finder": ("在访达中显示", "在 Finder 中顯示", "Finder に表示", "Finder에서 보기"),
    "Runtime": ("运行时", "執行環境", "ランタイム", "런타임"),
    "MetalFX quality": ("MetalFX 质量", "MetalFX 品質", "MetalFX 品質", "MetalFX 품질"),
    "Frame rate limit": ("帧率上限", "幀率上限", "フレームレート上限", "프레임레이트 제한"),
    "Recommend for this Mac": ("为这台 Mac 推荐", "為這台 Mac 推薦", "この Mac におすすめ", "이 Mac에 맞게 추천"),
    "Default": ("默认", "預設", "デフォルト", "기본값"),
    "Uncapped": ("不限", "不限", "制限なし", "무제한"),
    "Enlarges the game's rendered frame to your display resolution with MetalFX — a spatial upscaler that looks sharper than plain stretching, for a small GPU cost. It does NOT lower the game's own resolution (that's Retina); it makes a lower render resolution look crisp. Best with Retina off. Uses DXMT's upscaler, or converts DLSS on GPTK runtimes.":
        ("用 MetalFX 把游戏渲染的画面放大到你的显示器分辨率——这是空间放大器，比普通拉伸更清晰，GPU 开销很小。它不会降低游戏自身的分辨率（那是 Retina 的作用），而是让较低的渲染分辨率看起来更锐利。建议配合关闭 Retina 使用。DXMT 运行时用其放大器，GPTK 运行时则转换 DLSS。",
         "用 MetalFX 把遊戲算繪的畫面放大到你的顯示器解析度——這是空間放大器，比普通拉伸更清晰，GPU 開銷很小。它不會降低遊戲本身的解析度（那是 Retina 的作用），而是讓較低的算繪解析度看起來更銳利。建議搭配關閉 Retina 使用。DXMT 執行階段用其放大器，GPTK 執行階段則轉換 DLSS。",
         "MetalFX でゲームの描画フレームをディスプレイ解像度まで拡大します。単純な引き伸ばしより鮮明な空間アップスケーラーで、GPU コストはわずかです。ゲーム自体の解像度は下げません（それは Retina の役割）。低い描画解像度をくっきり見せます。Retina オフとの併用がおすすめです。DXMT ではそのアップスケーラーを、GPTK では DLSS を変換します。",
         "MetalFX로 게임이 렌더링한 프레임을 디스플레이 해상도로 확대합니다. 단순 확대보다 선명한 공간 업스케일러이며 GPU 비용은 적습니다. 게임 자체 해상도를 낮추지는 않으며(그건 Retina의 역할), 낮은 렌더링 해상도를 또렷하게 보이게 합니다. Retina 끄기와 함께 쓰는 것이 가장 좋습니다. DXMT는 자체 업스케일러를, GPTK는 DLSS 변환을 사용합니다."),
    "How far MetalFX enlarges the frame. A higher factor means the game renders smaller — faster, but softer. 2.0× renders at half your display's width; 1.5× renders closer to native (sharper, heavier). Default (2.0×) follows the runtime.":
        ("MetalFX 放大画面的倍数。倍数越高，游戏渲染得越小——更快但更糊。2.0× 以显示器宽度的一半渲染；1.5× 更接近原生（更清晰但更吃 GPU）。默认（2.0×）跟随运行时。",
         "MetalFX 放大畫面的倍數。倍數越高，遊戲算繪得越小——更快但更糊。2.0× 以顯示器寬度的一半算繪；1.5× 更接近原生（更清晰但更吃 GPU）。預設（2.0×）跟隨執行階段。",
         "MetalFX がフレームを拡大する倍率です。倍率が高いほどゲームは小さく描画され、速いがぼやけます。2.0× はディスプレイ幅の半分で描画し、1.5× はネイティブに近い（鮮明だが重い）です。デフォルト（2.0×）はランタイムに従います。",
         "MetalFX가 프레임을 확대하는 배율입니다. 배율이 높을수록 게임은 더 작게 렌더링되어 빠르지만 흐려집니다. 2.0×는 디스플레이 너비의 절반으로, 1.5×는 네이티브에 더 가깝게(더 선명하지만 무겁게) 렌더링합니다. 기본값(2.0×)은 런타임을 따릅니다."),
    "Caps the frame rate, paced by Metal for steadier frame times. Pick a value your Mac can hold steady — ideally a divisor of your display's refresh rate. Uncapped gives the lowest input lag (best for competitive games) at the cost of more heat and fan noise.":
        ("限制帧率，由 Metal 统一节奏，帧时间更稳。选一个你的 Mac 能稳定维持的值——最好是显示器刷新率的约数。不限帧输入延迟最低（竞技游戏最佳），代价是更热、风扇更响。",
         "限制幀率，由 Metal 統一節奏，幀時間更穩。選一個你的 Mac 能穩定維持的值——最好是顯示器更新率的約數。不限幀輸入延遲最低（競技遊戲最佳），代價是更熱、風扇更吵。",
         "フレームレートを制限し、Metal がペースを整えてフレームタイムを安定させます。Mac が安定して維持できる値を選んでください（ディスプレイのリフレッシュレートの約数が理想）。制限なしは入力遅延が最小（競技系に最適）ですが、発熱とファン音が増えます。",
         "프레임레이트를 제한하며 Metal이 페이스를 조절해 프레임 타임을 안정시킵니다. Mac이 안정적으로 유지할 수 있는 값을 고르세요(디스플레이 주사율의 약수가 이상적). 무제한은 입력 지연이 가장 낮지만(경쟁 게임에 최적) 발열과 팬 소음이 늘어납니다."),
    "Sets Retina, MetalFX and the upscale factor to values matched to this Mac's display. Nothing is applied until you tap Save, so it never changes a bottle behind your back.":
        ("把 Retina、MetalFX 和放大倍数设为匹配这台 Mac 显示器的值。点保存前不会生效，绝不会在你不知情时改动瓶子。",
         "把 Retina、MetalFX 和放大倍數設為匹配這台 Mac 顯示器的值。點儲存前不會生效，絕不會在你不知情時改動瓶子。",
         "Retina、MetalFX、アップスケール倍率をこの Mac のディスプレイに合わせた値に設定します。保存をタップするまで適用されないので、知らないうちにボトルが変わることはありません。",
         "Retina, MetalFX, 업스케일 배율을 이 Mac의 디스플레이에 맞는 값으로 설정합니다. 저장을 누르기 전에는 적용되지 않으므로 모르는 사이에 보틀이 바뀌지 않습니다."),
}

LANGS = ["zh-Hans", "zh-Hant", "ja", "ko"]


def main() -> None:
    strings = {}
    for key, translations in T.items():
        localizations = {}
        for lang, value in zip(LANGS, translations):
            localizations[lang] = {"stringUnit": {"state": "translated", "value": value}}
        strings[key] = {"localizations": localizations}
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    out = pathlib.Path(__file__).resolve().parent.parent / "App/Resources/Localizable.xcstrings"
    out.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {out} ({len(strings)} keys x {len(LANGS)} languages)")


if __name__ == "__main__":
    main()

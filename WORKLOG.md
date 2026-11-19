# DisplayControl 作業記録

## 目的と仕様

MacBook Pro（M3 Pro、macOS 27.3）と Dell S2725QC 2台の実輝度を、英語のネイティブメニューバーアプリから操作する。2026-11-20に承認された試作の細い矩形・内側の16段の仕切りと、中央に太陽を置くキー操作表示を基準にする。まず輝度を完成させる。DDPMの全機能を置き換えるための追加対応は別工程。

- 通常の輝度キーは接続中の制御可能な画面すべてに同じ差分を適用する。上限・下限では画面ごとに止める。単独調整の差は上限・下限まで保つ。
- 画面のうち1台をActive（コード上の名前は `primary`）とする。Shift＋輝度キーはActiveを前後に切り替える。初期値はmacOSの主画面。既に選んだ画面が接続中なら再検出後も保持する。切り替えで輝度やmacOSの画面配置は変えない。
- 輝度キーの上下の同時押しは、現在のActiveの値に3画面を揃える。一組につき一度。メニューからは個別・Active切替・揃え直しを操作できる。全画面の一括操作はキーだけで行い、メニューに一括のゲージは置かない（2026-11-20 ユーザー判断）。
- 起動・再接続時は現在値を読む。書き込みはユーザー操作からだけ行い、UIとは別に処理する。待ち行列の未送信値は画面ごとに最新値へまとめる。
- 実機の公開API権限の付与やシステム設定の変更は承認が必要。物理キー入力、物理輝度の変化、再接続、応答速度は個別に検証状態を記録する。インストール済みDDPMの終了や設定変更は行わない。

## 作業一覧

| 状態 | 担当 | 作業と完了条件 |
| --- | --- | --- |
| done | 画面通信 | 内蔵の読み書き、外部2台のEDID照合とDDC/CI、有効な応答検証、同型2台の読み取り確認 |
| done | UI | 承認済み試作に沿ったメニュー、16段バーと一時表示。実機制御から独立して検証できること |
| done | アプリ統合 | モデル・同時押し・権限状態・回復・パッケージ化。統合ビルドと入力・書き込み集約のテスト |
| done | 統合レビュー | 3担当の差分を読み、テストを実行。実機で検証できた範囲を記録 |
| done | 成果物とコミット | 署名・起動を確認した初版をローカルコミットに収録 |
| done | 実機書き込み | 内蔵・Dell 2台へ1段の一時書き込み、読み戻し、元の値への復元 |
| in_progress | 応答速度 | キーから書き込みまでの遅延要因を洗い出して短縮する。DDPMとの比較は計測せず、処理を速くすることで対応する（2026-11-20 ユーザー判断） |
| pending | 実キーと再接続 | 速度改善後に再ビルドしてから、アクセシビリティ許可を付け、DDPMを一時終了して物理キーと抜き差しを確認する |

## 途中で止まったとき

作業場所は `/Users/marutyan/PrivateDev/displaycontrol`。開始時点で `main` は初回コミット前。まず `git status --short --branch` と末尾の履歴を確認し、既存の作業を残す。Claude Code担当のセッションは画面通信 `b25d2b03-cb24-4fb9-9c9f-6a284a8885e8`、UI `8e910fa1-86e1-47cf-987e-bf3633dbdc78`、アプリ統合 `6faa93b2-c669-4cad-825e-4a5b5e79173d`。同じ作業場所から `claude --resume <ID>` で再開できる。完了報告と `swift test`、アプリのビルドを照合して未完了項目だけ続ける。

## 履歴

- 2026-11-20 承認済みの実機参照は、外枠322×16画像px、2x換算で161×8pt、16段の内側に細い垂直線。キー操作表示は中央に太陽。その寸法を反映したHTML試作で、ブラウザの個別操作・Primary切替・同時押しを確認済み。
- 2026-11-20 DDPM稼働中の調査で、2台のDDC/CI読み取りとEDID照合に成功。アプリからの書き込みと物理キーは未検証。
- 2026-11-20 書き込み範囲を分けてClaude Code 3担当を並列起動する。Gitコミットと統合確認はメイン担当。

### 画面通信の進捗

- 着手。担当ファイルは `Sources/DisplayControl/DisplayHardware.swift`。
- 初版作成。`DisplaySnapshot`・`DisplayHardwareError`・`DDC`（純粋なパケット生成/応答検証）・`EDIDInfo` もこのファイルで定義。actorは `DispatchSerialQueue` を実行器にするため macOS 14 以上が必要。IOAVService / DisplayServices は dlopen/dlsym で読み、無ければその種類の画面を対象外にする。`xcrun swiftc -typecheck -swift-version 6` 単体で警告・エラーなし。
- 読み取り専用の確認用ハーネス（`/private/tmp/displaycontrol-hardware.ygPaZO/scan/`、パケット・応答検証の単体確認、scan 2回、書き込み前に止まる拒否確認だけ）をビルド済み。実行は承認待ちで止まったため、実機スキャンは未実施。書き込みは一切していない。承認後は `/private/tmp/displaycontrol-hardware.ygPaZO/scan/scan` を実行すればよい。
- 照合方針: 外部画面はEDIDのベンダー・製品・シリアル（0は不可）とCGの値が双方向に一意な場合だけ採用。書き込み直前にCG属性・IORegistryの節点の存続・EDIDを照合し直し、不一致なら書かずに `.stale`/`.disconnected`。DDC読み取りが一時的に失敗した場合だけ、同じ画面・同じ経路の直前値で補う。EDIDが読めなければその回は除外する。Setは書き込みのみで、読み戻し確認はしない。
- 実機往復ハーネス `/private/tmp/displaycontrol-hardware.ygPaZO/roundtrip/main.swift`（未ビルド・未実行・未typecheck。Bash不可のため）。ユーザー承認後にメイン担当だけが `xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 -module-cache-path /private/tmp/displaycontrol-hardware.ygPaZO/module-cache -o <tmp>/roundtrip Sources/DisplayControl/DisplayHardware.swift <tmp>/roundtrip/main.swift` でビルドし、`--run-physical-check` を付けて実行する。引数が無ければ何もしない。内蔵1台とDell 2台がそろい、identityとIDがすべて異なる場合だけ動く。1台ずつ1/16下げて読み戻し、そのあと成否に関係なく元値へ復元する（最大3回）。復元できなければ終了コード2で止まり、他の画面へ進まない。生のシリアルは表示しない。注意点: scanはDDC読み取りに失敗すると直前値（書き込んだ値）で補うので、外部画面の読み戻し一致は実際の反映を保証しない。目視も併用すること。

### UIの進捗

- 着手。担当ファイルは `Sources/DisplayControl/BrightnessPanel.swift` と `Sources/DisplayControl/BrightnessHUD.swift`。
- 初版作成。`BrightnessPanel`（契約どおり）に加え、共用の `LevelBar`（Canvas、外枠161×8pt・1pt仕切り・16段・部分塗り・画素揃え、暗い外観は実測色）、`LevelSteps`（16段の丸め/次の段）、`DisplayLabel`（同名2台は x で Left/Right、3台以上は番号）、`BrightnessHUDView` を同ファイル群で定義。バーは高さ24ptの当たり範囲でクリック/ドラッグ（段に丸めて変化時のみ通知）、両端の太陽クリックで1段、フォーカス時は矢印/Home/End、VoiceOverには標準Sliderとして提示。見出し行クリックでPrimary選択（Primaryバッジと強調色アイコン、isSelected）。画面1台のときは一括とMatchを出さない。Matchは表示上1%単位で揃っていれば無効。試作の Display Settings… は持ち込まない。終了は「Quit DisplayControl ⌘Q」。HUDは非アクティブ化NSPanel（キー/主にならない、マウス透過、全Space）、ポインタのある画面の可視領域下端+120pt中央、1.2秒後0.35秒でフェード、視差低減時はフェードなし、VoiceOverへ announcement を送る。
- 検証: 一時ディレクトリの仮 `DisplaySnapshot` と合わせ `xcrun swiftc -typecheck -target arm64-apple-macos14 -swift-version 6` で警告・エラーなし。描画確認と段計算の検査用ハーネスはビルドできたが、実行が承認待ちで止まったため画像・実行時の確認は未実施。
- 画面通信担当の実ファイル `DisplayHardware.swift` と合わせた同条件の型検査も警告・エラーなし。UI担当の作業はここで区切り。残りは統合ビルド後の見た目・VoiceOver・HUD表示の実機確認。

### アプリ統合の進捗

- 着手。担当ファイルは `Package.swift`、`.gitignore`、`Sources/DisplayControl/DisplayControlApp.swift`、`Sources/DisplayControl/BrightnessModel.swift`、`Sources/DisplayControl/BrightnessKeys.swift`、`scripts/build-app.sh`、テスト。
- 設計: `BrightnessModel` は `BrightnessHardware` プロトコル（`DisplayHardware` を拡張で適合）経由で読み書き。画面ごとに未送信の最新値1件と世代番号を持ち、処理中の古い成功/失敗は世代不一致なら表示に反映しない。再走査中・送信中の画面は手元の値を優先。Primaryはユーザー選択を別保持し、再接続で戻れば復帰。キーは純粋な `KeyChordDetector`（同時押し待ち75ms、片方を離せば即確定）と CGEvent tap の `BrightnessKeyMonitor`（AXIsProcessTrusted のみ確認、プロンプトはボタン押下時だけ）。
- 担当ファイルを作成。入口は `DisplayControlMain`（`--diagnose` は読み取り結果を出して即終了、identity は文字数のみ）→ `MenuBarExtra(.window)` に `BrightnessPanel` を接続、キー操作時だけ `BrightnessHUDPresenter` を表示。画面構成変更は1秒、wake は2秒待って再走査（連続通知はまとめる）。書き込み失敗は最新の意図に対するものだけ状態文に出し、読み直しで表示を実機値へ戻す。
- 検証（01:20）: 6ファイル結合の `swift build`（debug）と `swift build -c release` が Swift 6 で警告・エラーなし。`swift test` 18件すべて成功（同時押し・リピート・Shift切替・data1解釈・Primary保持/復帰・未送信値の集約・古い失敗の無視・再走査中の意図保持・差分と上下限・揃え・切断後の破棄・起動時の読み取りのみ）。中間生成物は担当一時ディレクトリの `--scratch-path`。他担当ファイル起因のエラーはなし。
- 止まった点: `scripts/build-app.sh` の実行、ビルドしたバイナリの `--diagnose` 実行、`plutil`、`codesign` がいずれも承認待ちで実行できず。`dist/DisplayControl.app` にはリリースバイナリと Info.plist（スクリプトと同内容）を置いたが**バンドル署名は未実施**。スクリプトは `bash -n` のみ確認（zsh 構文検査も承認待ち）。物理キー、実機の読み取り、実際の書き込み、HUD・メニュー表示は未検証。
- 統合レビュー指摘の修正: (1) キー判定。期限切れで確定した後に押した反対キーが `.match` になる不具合を修正し、期限内の Shift なし上下押しだけを揃えるようにした。押下のたびに入力時刻（`NSEvent.timestamp`）で期限切れを先に確定させるので、タイマーが遅れても判定はずれない。Shift 付きは初回の押下で即切替し、そのキーを離すまでリピートを無視。Shift 混在や遅い押下はそれぞれ通常の操作として扱う。(2) HUD。Primary 切替は `level=nil`、タイトルは `DisplayLabel`（同名なら Left/Right・番号付き）。揃え時のタイトルも同様。(3) `build-app.sh` は `dist/.build-app.XXXXXX` で組み立て・署名・検証し、成功後に rename で置き換えるように変更。置き換えに失敗した場合は旧版を戻す。
- 検証: `swift test` 21件すべて成功（遅い押下・タイマー遅れ・Shift 混在の回帰テストを追加し、Shift の既存テストを新仕様に更新）、警告なし。スクリプトは構文検査も承認待ちで未実行。dist の削除と署名は行っていない。

### 統合確認の進捗

- 01:14 3担当を並列起動。現行接続で別経路の読み取り診断を再実行し、外部2台とも輝度100/100、コントラスト75/100を返すことを確認。
- 開発プロセスからの事前確認ではAccessibilityと入力監視の許可がない。署名したアプリで物理キーを検証する場合は、ユーザーがアプリの権限を付与したあとに行う。
- 01:18 画面通信とUIのSwiftファイルが揃い、3ファイルをまとめた Swift 6 の型検査に成功。アプリの入口とキー操作の担当を待って結合ビルドする。
- 01:20 メイン担当が通信の読み取り専用検査を実行。パケット検査、誤った宛先の拒否、実機3台の2回連続読み取りに成功。アプリの診断モードでも、外部2台100%、内蔵90%、異なる個体3/3と確認。
- 01:20 メイン担当が描画ハーネスを実行し、ライト・ダークのUIとHUDを目視確認。バーは2x描画で322×16px。段階計算・同型機の左右ラベルも確認。結合ビルドの初回の並行性エラーは統合担当が修正し、その後の `swift test` は18件成功。入力判定とパッケージ作成手順は追加レビュー中。
- 01:21 統合担当のdebug・releaseビルドと18件のテストが成功。統合担当が置いた仮の `.app` はバンドル署名が未実施で、`codesign --verify --strict` は失敗。署名付きバンドルの作り直しを予定。
- 01:21 コード確認で、片方を長く押したまま反対側を押すと時間差があっても同時押しになる経路を発見。統合担当に修正と回帰テストを依頼。署名済み成果物だけを配置するビルド手順の修正も依頼。画面通信・UIの固定版は独立レビュー中。
- 01:23 独立レビューで画面通信とUIの重大な指摘なし。統合担当が期限外とShift混在の同時押し誤判定を修正し、回帰テスト3件を追加。Primary切替時のHUDにも同型2台の左右を表記し、署名を済ませてから生成物を配置するようにした。
- 01:24 メイン担当の最終確認で `swift test` 21件成功。 `scripts/build-app.sh` で生成した `dist/DisplayControl.app` は `plutil -lint` と `codesign --verify --strict` が成功。アプリを起動し、同じバンドルのプロセスが待機状態で稼働することを確認。署名済みバイナリの `--diagnose` で実機3台を再確認。
- 物理キーはAccessibility未許可のため未検証。輝度の一時変更による書き込み・復元はユーザーの許可待ち。試験ハーネスは担当の一時ディレクトリでビルドし、書き込みなしで終了するモードのみ実行済み。実機での抜き差しとDDPMとの応答速度比較は未実施。

### 引き継ぎ後（Claude Code）

- 2026-11-20 `swift test` 21件成功を再確認。往復試験ハーネスに書き込み1回の所要時間の表示を加え、現行の `DisplayHardware.swift` で再ビルドした。
- 2026-11-20 ユーザー承認のうえ、DDPM起動中に往復試験を実行して PASS。全台の元値は1.000で、1/16下げた値は内蔵0.938、Dell 2台とも0.940（DDCの整数値94）で読み戻した。他の画面は変化せず、3台とも1回目の復元で1.000に戻った。書き込み1回の所要時間は内蔵0.2ms、左のDell 6.9ms、右のDell 57ms。右だけ遅い原因は不明（DDPMとの通信の競合の可能性あり、未検証）。
- アドホック署名のアプリは再ビルドするとアクセシビリティ許可が外れる。そのため、物理キーの試験は速度改善後の最終ビルドで行う。
- 2026-11-20 ユーザーの指示で、メニューの一括ゲージ（All Displays）を削除した。画面に出す「Primary」は、意図どおり「Active」に改めた。内部の識別子は並行作業との衝突を避けるため変えていない。描画ハーネスでライトとダークの見た目を確認した。

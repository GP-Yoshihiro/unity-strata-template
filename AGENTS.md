# AGENTS.md — AI エージェント共通ルール（Codex / Claude Code）

このファイルが唯一の正本です。Codex は `AGENTS.md` を、Claude Code は `CLAUDE.md`（このファイルを import）を読みます。ルール変更はここだけに書いてください。
このリポジトリは **複数の人間と複数の AI エージェントが同時に作業する** 前提です。

## プロジェクト概要
- Unity プロジェクト（エディタ版は `ProjectSettings/ProjectVersion.txt` が正）。
- ゲームコード: `Assets/Scripts/Runtime`（asmdef `Game.Runtime`, namespace `Game`）
- エディタ拡張/バッチ入口: `Assets/Scripts/Editor`（`Game.Editor.BatchEntry`）
- テスト: `Assets/Tests/EditMode`, `Assets/Tests/PlayMode`
- タスク: `Tasks/items/<id>.json`（1 タスク 1 ファイル。仕様は `Tasks/README.md`）
- 実行履歴: 非公開の別リポジトリ（`team.config.json` の `historyRepo`）。各 PC では隠しフォルダ `.history/`（git 管理外）に置かれ、`runs/YYYY-MM/<日時>-<ユーザー>-<エージェント>-<タスク>.md` が「誰がどのエージェントにどんな指示を出したか」の記録。**このリポジトリ（公開）には絶対に入れない。**
- Strata（ローカル推論サーバー https://github.com/Niko1221/Strata）: 起動設定 `.strata/launch.json`
- コンテキスト節約: `.strata/cache_config.json`（L1/L2/L3 の層定義）, `.strata/strata_index.json`（コンテキストマップ。本テンプレート独自で Strata 本体の機能ではない）
- 指示書: `Prompts/unity_csharp_coder.md`（実装サイクル）, `Prompts/PROMPT_DAILY_IMPROVEMENT.md`（日次改善）
- 仕様駆動開発: spec-kit（`.specify/`、`/speckit.*` コマンド）。原則は `.specify/memory/constitution.md`。`tasks.md` は `tools\task.cmd import` で `Tasks/items/` に起票してから claim する（spec-kit の `/speckit.implement` で claim せずに実装しない）
- 既知の落とし穴: `Docs/agent-lessons.md`（**作業前に読む**。無人ループは毎回プロンプト先頭に入れる。日次の改善パスが draft PR で更新する）

## コマンド（端末非依存。Unity / Strata のパスは自動解決されるので絶対パスを書かない）
| 目的 | Windows (PowerShell / cmd) | macOS / Linux / Git Bash |
|---|---|---|
| EditMode / PlayMode テスト | `tools\unity.cmd test EditMode` / `PlayMode` / `All` | `tools/unity.sh test EditMode` |
| .meta 生成/再インポート | `tools\unity.cmd refresh` | `tools/unity.sh refresh` |
| Unity エディタのインストール（`ProjectVersion.txt` の版） | `tools\unity.cmd install` | `tools/unity.sh install` |
| Unity の版を上げる（専用タスクで） | `tools\unity.cmd upgrade <version>` | `tools/unity.sh upgrade <version>` |
| 任意メソッド実行 | `tools\unity.cmd exec Ns.Class.Method [args]` | `tools/unity.sh exec ...` |
| コンテキスト索引 更新 / 検証 | `tools\strata-index.cmd` / `-Verify` | `pwsh tools/strata-index.ps1 [-Verify]` |
| タスク一覧 / 作成 / 着手 / 完了 / 保留 | `tools\task.cmd list` / `new` / `claim <id>` / `done <id>` / `block <id> -Note "理由"` | `pwsh tools/task.ps1 ...` |
| spec-kit の tasks.md をタスク化 | `tools\task.cmd import specs\<機能>\tasks.md` | `pwsh tools/task.ps1 import ...` |
| 初期セットアップ（対話式） | `bootstrap.cmd` / `tools\bootstrap.ps1 -Step <名前>` | `pwsh tools/bootstrap.ps1` |
| 動作確認（ファイル or プロンプト） | `tools\try.cmd -File <path>` / `tools\try.cmd "指示"` | `pwsh tools/try.ps1 ...` |
| Unity パッケージ追加 | `tools\unity.cmd packages add <id>[,<id>]` | `tools/unity.sh packages add ...` |
| 無人ループ（24 時間稼働） | `tools\loop.cmd` / `-Once` / `-Stop` | `pwsh tools/loop.ps1 ...` |
| チーム状況 / 履歴 | `tools\team.cmd status` / `history` | `pwsh tools/team.ps1 ...` |
| エージェント実行（履歴付き） | `tools\agent.cmd codex-local "指示"` | `pwsh tools/agent.ps1 ...` |
| ローカルモデル 起動 / 状態 / 停止 | `tools\strata.cmd up` / `status` / `stop` | `pwsh tools/strata.ps1 ...` |
| ローカルモデルへ委譲 | `tools\strata.cmd ask "質問" -File <path>` | `pwsh tools/strata.ps1 ask ...` |

終了コード: `0` 成功 / `2` テスト失敗 / `124` タイムアウト（`UNITY_TIMEOUT_MINUTES`、既定 60 分）/ その他 Unity 起動・設定エラー（結果 XML が無ければ失敗扱い）。結果は `Logs/*-results.xml` と `Logs/UnityTest-*.log`。

## チーム作業ルール（衝突の回避と防御）
1. **着手前に必ず claim する。** `tools\task.cmd claim <id> -Agent <自分の種別>`。claim は origin の `refs/claims/<id>` を原子的に作るので、同じタスクの二重着手や、`paths` が重なるタスクの同時着手は拒否される。拒否されたら作業しない。
2. **触ってよいのは claim したタスクの `paths` だけ。** 範囲外の変更が必要になったら、作業を止めて新しいタスクを `tools\task.cmd new` で起票する。
3. **1 タスク = 1 ブランチ（`task/<id>-...`）= 1 PR。** default ブランチへの直接 push は pre-push フックで拒否される。並列で動くエージェントは `claim -Worktree` で別ワークツリーを使う。
4. **シーン（`*.unity`）・プレハブは同時編集しない。** タスクの `paths` に明記して claim で守る。バイナリ素材（psd / fbx / blend）は `git lfs lock <file>` してから編集し、終わったら `git lfs unlock`。
5. **コミットはフックが帰属を付ける。** `Task:`（ブランチ名から）、`Agent:` と `Run-Record:`（`tools\agent.cmd` 経由の実行時）。トレーラーを消さない。`--no-verify` は使わない。
6. 作業を終えたら `tools\task.cmd done <id>`（claim は「review」状態になり、**PR がマージまたはクローズされるまで保持**される。解放は GitHub Actions `release-claims` が自動で行う）。ブランチを push して PR を作る（テンプレートの項目を埋める）。人の判断が必要なら `block <id> -Note "理由"`、途中で手放す場合は `release`。
7. 他人の claim を `-Force` で解放・上書きしない（人間の判断が必要）。
8. **秘匿情報（指示文・会話・実行結果）は `.history/` と非公開の履歴リポジトリにだけ置く。** 公開リポジトリのファイル、コミットメッセージ、PR 本文に指示文やトークン・個人情報を書かない（PR には `history:runs/...` の参照だけを書く）。

## 実装ルール
1. **`.meta` を手で作成・編集・削除しない。** ファイル追加後は `refresh` で Unity に生成させ、`.meta` も一緒にコミット（pre-commit と CI が検査）。移動/削除は `exec Game.Editor.BatchEntry.MoveAsset -from <a> -to <b>` / `DeleteAsset -path <p>`。
2. **Unity がエディタで開いている間はバッチ実行できない**（`Temp/UnityLockfile`）。失敗したらユーザーに閉じてもらう。
3. 共通ユーティリティ・基底クラスを追加/変更したら `strata-index` を更新し、`-Verify` を通してからコミット。
4. 全コードをプロンプトやレスポンスに貼らない。タスクの `strataRefs`（`cs:Namespace.Type`）から必要ファイルだけ読む。
5. コミット前チェック: EditMode テスト 0 終了 + `strata-index -Verify` 0 終了。
6. `Library/`, `Temp/`, `Obj/`, `UserSettings/`, `Logs/*`, `.codex-local/` はコミットしない。
7. マシン固有の設定は `.unity-path.local` / 環境変数に置き、リポジトリに入れない。

## Strata をエージェントの配下で使う（委譲）
Codex / Claude Code が指揮役、Strata のローカルモデルが作業役です。クラウドのトークンを使わずに済む作業は委譲してください。
- **単発の作業 → `tools\strata.cmd ask`**: ログからのエラー抽出・要約、diff の一次レビュー、定型コード・テストの下書き、命名案など。
  例: `tools\strata.cmd ask "失敗原因を3行で" -File Logs\UnityTest-EditMode.log`
- **まとまったサブタスク → `tools\agent.cmd codex-local "指示"`**: ローカルモデルの Codex に、claim 済みタスクの一部を任せる（必ず別ワークツリーで）。
- 委譲結果は必ず自分で確認してから使う（ローカルモデルは小さく、誤りやすい）。設計判断・最終レビューは指揮役が行う。
- `tools\agent.cmd` 経由の実行中に `ask` した内容は、同じ実行記録（非公開の `.history/`）に自動で追記される。

## ローカルモデル（Strata）での 24 時間稼働
- 無人運用は `tools\loop.cmd` で行う：未着手タスクを選ぶ → claim → `codex-local` がコードを編集 → **ループ（サンドボックスの外）が** `.meta` 生成・索引更新・Unity テストを実行 → 失敗内容を渡して修正（`-MaxFixRounds` 回まで）→ 成功なら PR、失敗が続けば draft PR ＋ `block`。
- ループは claim したタスクの `paths` 外の変更を**自動で取り消す**（エージェントにも通知）。タスク間で作業ツリーをリセットし、コミットできなかった変更は `Logs/loop-unsaved-*.patch` に残す。
- **能力向上の仕組み**: タスクごとの結果（ラウンド数・成否・CS エラーコード・範囲外変更・所要時間）を非公開履歴の `metrics/loop-YYYY-MM.jsonl` に記録し、24 時間ごと（`-ImproveEveryHours`、キューが空なら最短 6 時間）に改善パスを実行する。改善パスは日計レポート・`Docs/agent-lessons.md`・指示書・タスク分割を **draft PR** で提案し、人間がマージするまでループはそれを使わない（ループが拾うのは default ブランチ上のタスクだけ）。
- ループ専用の clone（エディタで開かない、`C:\dev\<name>-agent` のような浅いパス、`%TEMP%` 配下は不可）で動かす。停止は `tools\loop.cmd -Stop`、ログは `Logs\loop.log`。
- **ループから呼ばれたエージェントは、Unity・`tools\unity.*`・git commit/push を実行しない**（サンドボックスからは Unity を起動できない。実行はループが行う）。
- 単発でローカルモデルを使うときは `tools\agent.cmd codex-local` を使う（API 課金なし。Codex の設定は `tools/templates/codex-local.config.toml`）。
- コンテキストは `.strata/launch.json` の `context`（既定 64K）が上限。プロンプトは **L1 → L2 → L3 の順** に並べ、毎サイクル変わる内容（diff・ログ）は末尾に置く。先頭が毎回同一だとサーバーのプロンプトキャッシュが効く。
- ログは全文を渡さない。`error CS\d{4}` や失敗テスト名だけ抽出して渡す。
- Unity のバッチ実行とローカルモデルはメモリを取り合う。OOM に見える失敗は `tools\strata.cmd status` で確認。

## サンドボックス注意（Codex）
Unity のバッチ実行はプロジェクト外（ライセンス、`%APPDATA%\UnityHub`、`%LOCALAPPDATA%\Unity`、パッケージ取得のネットワーク）にアクセスするため、Codex の Windows サンドボックス内では動きません（検証済み）。
テストは `tools\loop.cmd` に任せるか、人間が実行する。対話中に必要なら、`tools/unity.*` の実行に昇格（承認付き実行）を求める。
`.history/` は Codex のサンドボックスから読めない設定（`CodexSandboxUsers` を拒否）。過去の指示を参照する必要はない。
Windows の Codex サンドボックスは深いパスでカレントディレクトリを見失うことがあるため、リポジトリは `C:\dev\<name>` のような浅い場所に置く。

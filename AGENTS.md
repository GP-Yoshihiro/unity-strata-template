# AGENTS.md — AI エージェント共通ルール（Codex / Claude Code）

このファイルが唯一の正本です。Codex は `AGENTS.md` を、Claude Code は `CLAUDE.md`（このファイルを import）を読みます。ルール変更はここだけに書いてください。

## プロジェクト概要
- Unity プロジェクト（エディタ版は `ProjectSettings/ProjectVersion.txt` が正）。
- ゲームコード: `Assets/Scripts/Runtime`（asmdef `Game.Runtime`, namespace `Game`）
- エディタ拡張/バッチ入口: `Assets/Scripts/Editor`（`Game.Editor.BatchEntry`）
- テスト: `Assets/Tests/EditMode`, `Assets/Tests/PlayMode`
- Strata（ローカル推論サーバー https://github.com/Niko1221/Strata）: 起動設定 `.strata/launch.json`
- コンテキスト節約: `.strata/cache_config.json`（L1/L2/L3 の層定義）, `.strata/strata_index.json`（コンテキストマップ。本テンプレート独自で Strata 本体の機能ではない）
- タスク: `Tasks/backlog.json` → 完了で `Tasks/completed.json`
- 指示書: `Prompts/unity_csharp_coder.md`（実装サイクル）, `Prompts/PROMPT_DAILY_IMPROVEMENT.md`（日次改善）

## コマンド（端末非依存。Unity のパスは自動解決されるので絶対パスを書かない）
| 目的 | Windows (PowerShell / cmd) | macOS / Linux / Git Bash |
|---|---|---|
| Unity パス確認 | `tools\unity.cmd path` | `tools/unity.sh path` |
| EditMode テスト | `tools\unity.cmd test EditMode` | `tools/unity.sh test EditMode` |
| PlayMode テスト | `tools\unity.cmd test PlayMode` | `tools/unity.sh test PlayMode` |
| .meta 生成/再インポート | `tools\unity.cmd refresh` | `tools/unity.sh refresh` |
| 任意メソッド実行 | `tools\unity.cmd exec Ns.Class.Method [args]` | `tools/unity.sh exec ...` |
| コンテキスト索引更新 | `tools\strata-index.cmd` | `pwsh tools/strata-index.ps1` |
| コンテキスト索引検証 | `tools\strata-index.cmd -Verify` | `pwsh tools/strata-index.ps1 -Verify` |
| ローカルモデル起動 / 状態 / 停止 | `tools\strata.cmd up` / `status` / `stop` | `pwsh tools/strata.ps1 up` など |
| ローカルモデル疎通 | `tools\strata.cmd health` / `check` | `pwsh tools/strata.ps1 health` |

終了コード: `0` 成功 / `2` テスト失敗 / その他 Unity 起動・設定エラー。結果は `Logs/*-results.xml` と `Logs/UnityTest-*.log`。

## 必須ルール
1. **`.meta` を手で作成・編集・削除しない。** ファイル追加後は `refresh` で Unity に生成させ、`.meta` も一緒にコミット。移動/削除は `exec Game.Editor.BatchEntry.MoveAsset -from <a> -to <b>` / `DeleteAsset -path <p>`。
2. **Unity がエディタで開いている間はバッチ実行できない**（`Temp/UnityLockfile`）。失敗したらユーザーに閉じてもらう。
3. 新しい共通ユーティリティ・基底クラスを追加/変更したら `strata-index` を更新し、`-Verify` を通してからコミット。
4. 全コードをプロンプトやレスポンスに貼らない。タスクの `strataRefs`（`cs:Namespace.Type`）から必要ファイルだけ読む。
5. コミット前チェック: EditMode テスト 0 終了 + `strata-index -Verify` 0 終了。
6. `Library/`, `Temp/`, `Obj/`, `UserSettings/`, `Logs/*` はコミットしない（`.gitignore` 済み）。
7. マシン固有の設定は `.unity-path.local` / 環境変数に置き、リポジトリに入れない。

## ローカルモデル（Strata）での 24 時間稼働
- 長時間ループ（実装サイクル、ログ要約、日次レポート）は `.strata/launch.json` のローカルモデルで回し、API 課金を発生させない。Codex は `codex --profile strata` で接続（`.codex/config.toml`）。
- ローカルモデルのコンテキストは `.strata/launch.json` の `context`（既定 64K）が上限。プロンプトは **L1 → L2 → L3 の順** に並べ、毎サイクル変わる内容（diff・ログ）は末尾に置く。先頭が毎回同一だとサーバーのプロンプトキャッシュが再利用され、処理時間が大きく減る。
- ログは全文を渡さない。`error CS\d{4}` や失敗テスト名だけ抽出して渡す。
- 難しい設計判断・大規模リファクタは通常のクラウドモデル（プロファイル指定なしの Codex / Claude Code）に回す。
- Unity のバッチ実行とローカルモデルはメモリを取り合う。テスト失敗が OOM 由来に見えたら `tools\strata.cmd status` でメモリ状況を確認。

## サンドボックス注意（Codex）
Unity のバッチ実行はプロジェクト外（ライセンス、`%LOCALAPPDATA%\Unity`、パッケージ取得のネットワーク）にもアクセスします。
サンドボックスで失敗した場合は、`tools/unity.*` の実行に昇格（承認付き実行）を求めてください。

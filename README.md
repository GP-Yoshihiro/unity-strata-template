# Unity Autonomous Game Project Framework (Strata Enhanced)

Unity Editor のバッチモード、AI エージェント（**Codex / Claude Code** のどちらでも可）、および Strata 階層コンテキストキャッシュを連携させた、24時間自律開発用の汎用ひな形です。
どの端末で clone しても同じコマンドで動くよう、Unity 実行ファイルは**自動探索**（または相対パス指定）で解決します。

## 🚀 新しい端末でのセットアップ

前提: Git + Git LFS、Unity Hub（`ProjectSettings/ProjectVersion.txt` の版をインストール）、PowerShell（Windows は標準。macOS/Linux は `pwsh` 推奨）。

```bash
git clone <repo-url> C:\dev\<name>      # Windows は浅いパス推奨（深いパスだと Unity が黙って失敗する）
cd <name>
tools\setup.ps1                          # Windows（実行ポリシーで止まる場合: powershell -ExecutionPolicy Bypass -File tools\setup.ps1）
tools/setup.sh                           # macOS / Linux / Git Bash
```

`setup` は LFS 有効化、Unity 検出、UnityYAMLMerge のマージドライバ登録（リポジトリローカル）、エージェントスキル同期、Strata 索引の再生成を行います。何度実行しても安全です。

## 🎯 Unity 実行ファイルの解決順

`tools/find-unity.ps1` / `tools/find-unity.sh` が以下の順に探します。

1. 引数 `-UnityPath`
2. 環境変数 `UNITY_EDITOR_PATH`
3. リポジトリ直下の `.unity-path.local`（**gitignore 済み**・1行。相対パスはリポジトリルート基準。例: `../UnityEditors/6000.6.7f1`）
4. `ProjectVersion.txt` と同じ版を以下から探索
   - `UNITY_EDITORS_DIR`（追加ルート。Windows は `;`、他は `:` 区切り）
   - `../UnityEditors/<版>`、`./.unity-editors/<版>`（ポータブル配置用の相対パス）
   - Unity Hub 既定のインストール先、Hub の `secondaryInstallPath`、Hub で手動登録したエディタ
5. 同じ major.minor → 最新版（警告付きフォールバック。`-Strict` / `STRICT=1` で無効）
6. `PATH` 上の `Unity`

確認: `tools\unity.cmd path` / `tools/find-unity.sh --list`

## 🔄 よく使うコマンド

| 目的 | Windows | macOS / Linux / Git Bash |
|---|---|---|
| EditMode テスト | `tools\unity.cmd test EditMode` | `tools/unity.sh test EditMode` |
| PlayMode / 全部 | `tools\unity.cmd test PlayMode` / `All` | `tools/unity.sh test All` |
| `.meta` 生成（再インポート） | `tools\unity.cmd refresh` | `tools/unity.sh refresh` |
| 任意メソッド | `tools\unity.cmd exec Ns.Class.Method ...` | `tools/unity.sh exec ...` |
| エディタで開く | `tools\unity.cmd open` | `tools/unity.sh open` |
| Strata 索引更新 / 検証 | `tools\strata-index.cmd [-Verify]` | `pwsh tools/strata-index.ps1 [-Verify]` |

テスト結果は `Logs/editmode-results.xml` / `Logs/UnityTest-EditMode.log`。終了コード `0` 成功、`2` テスト失敗。

## 🤖 AI エージェント（Codex / Claude Code）

| ファイル | 用途 |
|---|---|
| `AGENTS.md` | **共通ルールの正本**。Codex はこれを読む |
| `CLAUDE.md` | `@AGENTS.md` を import（Claude Code 用） |
| `.agents/skills/unity-workflow/` | 共通スキル（テスト・meta・Strata 手順）。Codex が読む場所 |
| `.claude/skills/unity-workflow/` | 上記のコピー（Claude Code 用、`setup` で同期） |
| `.codex/config.toml` | Codex のプロジェクト設定（workspace-write + ネットワーク許可） |
| `Prompts/unity_csharp_coder.md` | 実装サイクル指示書 |
| `Prompts/PROMPT_DAILY_IMPROVEMENT.md` | 深夜日計レポート＆自律改善指示書 |

実行例:

```bash
codex "Prompts/unity_csharp_coder.md に従って Tasks/backlog.json の最優先タスクを1件処理して"
```

```bash
claude -p "Prompts/PROMPT_DAILY_IMPROVEMENT.md を実行して"
```

推奨 Claude Code プラグイン（各端末で一度インストール）: **Unity**（Unity 公式）、**unity-perf**、**github**。

## 🤖 Strata 運用 & 開発ルール
1. **L1/L2 キャッシュの意識**: 共通ユーティリティや基底クラスを作成した場合は `strata_index.json` を更新すること（`tools/strata-index.*`）。
2. **Meta ファイルの保護**: `.meta` の欠損・重複は致命的。スクリプト削除・移動は UnityEditor API 経由（`Game.Editor.BatchEntry.MoveAsset` / `DeleteAsset`）。
3. **差分（Diff）駆動型のタスク実行**: 全コードをプロンプトに含めず、Strata の参照 ID（`cs:Namespace.Type`）を指定して指示を出すこと。

`strata-cli` が PATH にあれば `tools/strata-index.ps1` はそれを使い、無ければ同梱の組み込みインデクサで互換の `strata_index.json` を生成します。

## 📂 ディレクトリ構造
- `Assets/Scripts/Runtime/` ゲームコード（`Game.Runtime`）／ `Assets/Scripts/Editor/` バッチ入口（`Game.Editor`）
- `Assets/Tests/EditMode/`, `Assets/Tests/PlayMode/` 自動テスト
- `.strata/` `cache_config.json`（階層定義）, `strata_index.json`（コンテキストマップ）, `stats.json`（端末ローカル・非コミット）
- `Logs/` Unity CLI 出力（非コミット）
- `Tasks/` `backlog.json`, `completed.json`
- `Prompts/` AI 指示書
- `Reports/` 日計レポート
- `tools/` Unity 探索・実行・セットアップ・Strata スクリプト

## 🔒 コミットしないもの（端末ごとの設定）
`Library/`, `Temp/`, `UserSettings/`, `Logs/*`, `.unity-path.local`, `.claude/settings.local.json`, `.strata/stats.json`, `.strata/cache/`

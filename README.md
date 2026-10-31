# Unity Autonomous Game Project Framework (Strata Enhanced)

Unity Editor のバッチモード、AI エージェント（**Codex / Claude Code** のどちらでも可）、ローカル推論サーバー [**Strata**](https://github.com/Niko1221/Strata)、L1/L2/L3 の階層コンテキスト管理を組み合わせた、24時間自律開発用の汎用ひな形です。
どの端末で clone しても同じコマンドで動くよう、Unity 実行ファイルと Strata は**自動探索**（または相対パス指定）で解決します。

## 🚀 新しい端末でのセットアップ

前提: Git + Git LFS、Unity Hub（`ProjectSettings/ProjectVersion.txt` の版をインストール）、PowerShell（Windows は標準。macOS/Linux は `pwsh` 推奨）。
Windows では深いパスだと Unity が黙って失敗するので、`C:\dev\<name>` のような浅い場所に clone してください。

**Windows (PowerShell / cmd)** — 1 行ずつ実行（Windows PowerShell 5.1 は `&&` 非対応）

```powershell
git clone https://github.com/GP-Yoshihiro/unity-strata-template.git C:\dev\unity-strata-template
```

```powershell
cd C:\dev\unity-strata-template
```

```powershell
tools\setup.cmd
```

**macOS / Linux / Git Bash**

```bash
git clone https://github.com/GP-Yoshihiro/unity-strata-template.git && cd unity-strata-template && tools/setup.sh
```

`setup` は LFS 有効化、Unity 検出、UnityYAMLMerge のマージドライバ登録（リポジトリローカル）、エージェントスキル同期、コンテキスト索引の再生成、Strata の有無の確認を行います。何度実行しても安全です。
`tools\*.cmd` は PowerShell の実行ポリシーに関係なく動くラッパーです。

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
| コンテキスト索引更新 / 検証 | `tools\strata-index.cmd [-Verify]` | `pwsh tools/strata-index.ps1 [-Verify]` |
| ローカルモデル起動 / 状態 / 停止 | `tools\strata.cmd up` / `status` / `stop` | `pwsh tools/strata.ps1 up` など |
| ローカルモデル疎通確認 | `tools\strata.cmd health` / `check` | `pwsh tools/strata.ps1 health` |

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

実行例（Windows で `codex` がブロックされる場合は `codex.cmd`）:

```powershell
codex --profile strata "Prompts/unity_csharp_coder.md に従って Tasks/backlog.json の最優先タスクを1件処理して"
```

```powershell
codex "Prompts/PROMPT_DAILY_IMPROVEMENT.md を実行して"
```

`--profile strata` を付けるとローカルの Strata モデル、付けなければ通常のクラウドモデルで動きます。

推奨 Claude Code プラグイン（各端末で一度インストール）: **Unity**（Unity 公式）、**unity-perf**、**github**。

## 🧠 Strata（ローカルモデル）

[Strata](https://github.com/Niko1221/Strata) は PC 上で LLM を動かし、`http://127.0.0.1:8080` に OpenAI / Anthropic 互換 API を提供する推論サーバーです。24時間ループをローカルモデルで回すことで API 課金なしで稼働できます。

1. Strata Terminal をインストール（端末ごとに 1 回。`tools\strata.cmd install` で公式コマンドを表示）
2. `tools\strata.cmd plan` — `.strata/launch.json` のモデルのダウンロード量・メモリを確認（何も変更しない）
3. `tools\strata.cmd up` — 初回はエンジンとモデル（Coder IQ1_M で約 64GB）をダウンロードして起動
4. `tools\strata.cmd health` → `tools\strata.cmd check`（Codex 形式でプロンプト 1 回とツール呼び出し 1 回を検証）

既定モデルは **Qwen3.8-Flash-Next Coder IQ1_M / 64K context**（RTX 5070 12GB + RAM 64GB で選定）。マシンに合わせて `.strata/launch.json` を変更してください。モデルとメモリの目安は [Strata の MODELS.md](https://github.com/Niko1221/Strata/blob/main/docs/MODELS.md)。

## 🤖 コンテキスト節約 & 開発ルール
1. **L1/L2/L3 の層構成**: `.strata/cache_config.json` で層を定義。プロンプトは L1（設計・asmdef）→ L2（関連ソース）→ L3（diff・ログ）の順で組み、先頭を毎回同一に保つと Strata のプロンプトキャッシュが効く。
2. **コンテキスト索引**: 共通ユーティリティや基底クラスを作成した場合は `tools\strata-index.cmd` で `.strata/strata_index.json` を更新し、`-Verify` で検証すること。この索引は本テンプレート独自の仕組みで、Strata 本体の機能ではありません。
3. **Meta ファイルの保護**: `.meta` の欠損・重複は致命的。スクリプト削除・移動は UnityEditor API 経由（`Game.Editor.BatchEntry.MoveAsset` / `DeleteAsset`）。
4. **差分（Diff）駆動型のタスク実行**: 全コードをプロンプトに含めず、参照 ID（`cs:Namespace.Type`）を指定して指示を出すこと。

## 📂 ディレクトリ構造
- `Assets/Scripts/Runtime/` ゲームコード（`Game.Runtime`）／ `Assets/Scripts/Editor/` バッチ入口（`Game.Editor`）
- `Assets/Tests/EditMode/`, `Assets/Tests/PlayMode/` 自動テスト
- `.strata/` `launch.json`（Strata の起動設定）, `cache_config.json`（層定義）, `strata_index.json`（コンテキストマップ）, `stats.json`（端末ローカル・非コミット）
- `Logs/` Unity CLI 出力（非コミット）
- `Tasks/` `backlog.json`, `completed.json`
- `Prompts/` AI 指示書
- `Reports/` 日計レポート
- `tools/` Unity 探索・実行、セットアップ、Strata 起動、コンテキスト索引のスクリプト

## 🔒 コミットしないもの（端末ごとの設定）
`Library/`, `Temp/`, `UserSettings/`, `Logs/*`, `.unity-path.local`, `.claude/settings.local.json`, `.strata/stats.json`, `.strata/cache/`

# Unity Autonomous Game Project Framework (Strata Enhanced)

Unity Editor のバッチモード、AI エージェント（**Codex / Claude Code**）、ローカル推論サーバー [**Strata**](https://github.com/Niko1221/Strata)、L1/L2/L3 の階層コンテキスト管理を組み合わせた、**チームで 24 時間自律開発するための汎用ひな形**です。

- どの端末で clone しても同じコマンドで動く（Unity・Strata・Codex は自動探索）
- 複数の人間とエージェントが同時に作業しても衝突しない（タスクの claim、パス重複の拒否、フック、CI）
- 誰が・どのエージェントに・どんな指示で作業させたかが履歴として残る（`History/runs` とコミットトレーラー）
- Strata のローカルモデルを Codex / Claude Code の配下で使い、クラウドのトークンを節約できる

## 🚀 新しい端末でのセットアップ

前提: Git + Git LFS、Unity Hub（`ProjectSettings/ProjectVersion.txt` の版）、PowerShell（Windows は標準。macOS/Linux は `pwsh`）。
任意: [Codex CLI](https://www.npmjs.com/package/@openai/codex)（`npm.cmd install -g @openai/codex`）、Strata Terminal（下記）。
Windows では深いパスだと Unity や Codex のサンドボックスが失敗するので、`C:\dev\<name>` のような浅い場所に clone してください。

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

`setup` が行うこと（何度実行しても安全）: LFS 有効化、**チーム用 git フックの有効化**（`core.hooksPath=.githooks`）、Unity 検出、UnityYAMLMerge のマージドライバ登録、エージェントスキル同期、コンテキスト索引の再生成、Strata の有無の確認。
`tools\*.cmd` は PowerShell の実行ポリシーに関係なく動くラッパーです（`.ps1` を直接実行できない環境でも使えます）。
`git config --global user.name` が未設定だと claim と履歴が使えないので、先に設定してください。

## 👥 チームでの作業の流れ

```powershell
tools\task.cmd list                                     # 未着手タスクと、誰が何を claim しているか
tools\task.cmd claim T-261031-0001 -Agent codex          # 着手（原子的なロック + ブランチ task/<id>-... を作成）
tools\agent.cmd codex-local "Prompts/unity_csharp_coder.md に従って実装して"   # エージェント実行（履歴付き）
tools\unity.cmd test All                                 # テスト
tools\task.cmd done T-261031-0001                        # 完了 → claim 解放
git push -u origin HEAD                                  # → PR（テンプレートを埋める）
```

### 衝突の回避（起きる前に止める）
| 仕組み | 内容 |
|---|---|
| **claim**（`tools\task.cmd claim`） | origin に `refs/claims/<id>` を `git push` で作る。ref の作成はサーバー側で原子的なので、**同じタスクの二重着手は必ずどちらかが拒否**される。共有ファイルを書かないのでマージ衝突も起きない |
| **パス重複の拒否** | タスクの `paths`（例: `Assets/Scenes/Level1.unity`）が他の claim と重なると claim を拒否。シーン・プレハブの同時編集を防ぐ |
| **1 タスク 1 ファイル** | `Tasks/items/<id>.json`。別々のタスクの起票・更新が同じファイルに触れない |
| **1 タスク 1 ブランチ / ワークツリー** | `task/<id>-...`。同じ PC で並列に動くエージェントは `claim -Worktree` で別ワークツリー |
| **LFS ロック** | psd / fbx / blend は `lockable`（ロックするまで読み取り専用）。`git lfs lock <file>` してから編集 |
| **CODEOWNERS** | 領域ごとの責任者を PR のレビュアーに自動指名（`.github/CODEOWNERS` に実名を追加） |

### 衝突の防御（起きても壊さない）
| 仕組み | 内容 |
|---|---|
| **pre-commit フック** | `.meta` の欠損・孤立、生成フォルダ（Library 等）の混入、LFS 外の 5MB 超ファイル、古いコンテキスト索引をブロック |
| **pre-push フック** | default ブランチ（main）への直接 push を拒否（PR 経由に統一）。Git LFS のフックにも連結 |
| **UnityYAMLMerge** | シーン・プレハブの衝突を Unity のスマートマージで解決（`setup` が登録） |
| **CI（`.github/workflows/checks.yml`）** | PR ごとに `.meta` 整合性、索引、タスクファイル、`Task:` トレーラーを検査（Unity ライセンス不要） |
| **推奨: ブランチ保護** | GitHub の Settings → Branches で main に「PR 必須」「checks 必須」「Code Owner のレビュー必須」を設定 |

### 誰が・何を・どんな指示で（履歴）
| 見たいもの | コマンド / 場所 |
|---|---|
| 今だれが何をしているか | `tools\team.cmd status`（claim、未着手タスク、LFS ロック、直近の実行） |
| エージェントへの指示と結果 | `tools\team.cmd history [-Task id] [-User 名前] [-Agent codex-local] [-Days 7]` → `tools\team.cmd run <run-id>` で全文。未マージの他人のブランチの実行も表示 |
| 実行記録そのもの | `History/runs/YYYY-MM/<日時>-<ユーザー>-<エージェント>-<タスク>.md`（ユーザー、エージェント、モデル、ブランチ、基点コミット、**プロンプト全文**、委譲内容、結果、変更ファイル） |
| タスク単位のコミット | `git log --all --grep "Task: T-261031-0001"`、`tools\task.cmd show <id>` |
| コミットの帰属 | トレーラー `Task:` / `Agent:` / `Run-Record:`（commit-msg フックが自動付与） |

## 🤖 AI エージェント（Codex / Claude Code）と Strata

| ファイル | 用途 |
|---|---|
| `AGENTS.md` | **共通ルールの正本**（Codex が読む）。チーム作業ルール・委譲ルールもここ |
| `CLAUDE.md` | `@AGENTS.md` を import（Claude Code 用） |
| `.agents/skills/` | 共通スキル `unity-workflow` / `team-workflow` / `strata-delegate`（Codex が読む場所） |
| `.claude/skills/` | 上記のコピー（Claude Code 用、`setup` で同期） |
| `.codex/config.toml` | Codex のプロジェクト設定（workspace-write + ネットワーク許可） |
| `tools/templates/codex-local.config.toml` | ローカルモデル用 Codex 設定（`tools\codex-local.cmd` が `.codex-local/` に展開） |
| `Prompts/unity_csharp_coder.md` | 実装サイクル指示書 |
| `Prompts/PROMPT_DAILY_IMPROVEMENT.md` | 深夜日計レポート＆自律改善指示書 |

**エージェントの実行は `tools\agent.cmd` 経由にすると履歴が残ります。**

| 実行するもの | コマンド |
|---|---|
| Codex（ローカルの Strata モデル） | `tools\agent.cmd codex-local "指示"` |
| Codex（クラウド） | `tools\agent.cmd codex "指示"` |
| Claude Code | `tools\agent.cmd claude "指示"` |
| Strata に 1 問だけ | `tools\agent.cmd strata "指示"` |

**Strata を配下で使う（委譲）**: Codex / Claude Code が指揮役、Strata が作業役。ログの要約や定型コードなどは
`tools\strata.cmd ask "失敗原因を3行で" -File Logs\UnityTest-EditMode.log` で委譲できます（`git diff | tools\strata.ps1 ask "..."` のようにパイプ入力も可）。
`tools\agent.cmd` で実行中のエージェントが `ask` した内容は同じ実行記録に追記されます。

推奨 Claude Code プラグイン（各端末で一度インストール）: **Unity**（Unity 公式）、**unity-perf**、**github**。

## 🧠 Strata（ローカルモデル）を PowerShell で操作

[Strata](https://github.com/Niko1221/Strata) は PC 上で LLM を動かし、`http://127.0.0.1:8080` に OpenAI / Anthropic 互換 API を提供する推論サーバーです。Web 画面を使わず、すべて PowerShell から操作できます。

| 目的 | コマンド |
|---|---|
| インストール方法の表示（端末ごとに 1 回） | `tools\strata.cmd install` |
| 必要なダウンロード量・メモリの確認（何も変更しない） | `tools\strata.cmd plan` |
| 起動（初回はエンジンとモデル約 64GB をダウンロード） | `tools\strata.cmd up` |
| 状態 / 疎通 / Codex 互換チェック | `tools\strata.cmd status` / `health` / `check` |
| 速度・VRAM・リクエストのライブ表示 | `tools\strata.cmd monitor` |
| エンジンログ | `tools\strata.cmd logs --follow` |
| 停止（メモリ解放） | `tools\strata.cmd stop` |
| その他の strata コマンド | `tools\strata.cmd <command> ...`（そのまま渡す） |

既定モデルは **Qwen3.8-Flash-Next Coder IQ1_M / 64K context**（RTX 5070 12GB + RAM 64GB で選定）。全員が同じモデルを使うよう `.strata/launch.json` で共有しています。マシンに合わせて変える場合は `tools/templates/codex-local.config.toml` の `model` も合わせてください。モデルとメモリの目安は [Strata の MODELS.md](https://github.com/Niko1221/Strata/blob/main/docs/MODELS.md)。

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

## 🔄 Unity コマンド

| 目的 | Windows | macOS / Linux / Git Bash |
|---|---|---|
| EditMode テスト | `tools\unity.cmd test EditMode` | `tools/unity.sh test EditMode` |
| PlayMode / 全部 | `tools\unity.cmd test PlayMode` / `All` | `tools/unity.sh test All` |
| `.meta` 生成（再インポート） | `tools\unity.cmd refresh` | `tools/unity.sh refresh` |
| 任意メソッド | `tools\unity.cmd exec Ns.Class.Method ...` | `tools/unity.sh exec ...` |
| エディタで開く | `tools\unity.cmd open` | `tools/unity.sh open` |
| コンテキスト索引更新 / 検証 | `tools\strata-index.cmd [-Verify]` | `pwsh tools/strata-index.ps1 [-Verify]` |

テスト結果は `Logs/editmode-results.xml` / `Logs/UnityTest-EditMode.log`。終了コード `0` 成功、`2` テスト失敗。

## 🧩 コンテキスト節約 & 開発ルール
1. **L1/L2/L3 の層構成**: `.strata/cache_config.json` で層を定義。プロンプトは L1（設計・asmdef）→ L2（関連ソース）→ L3（diff・ログ）の順で組み、先頭を毎回同一に保つと Strata のプロンプトキャッシュが効く。
2. **コンテキスト索引**: 共通ユーティリティや基底クラスを作成した場合は `tools\strata-index.cmd` で `.strata/strata_index.json` を更新し、`-Verify` で検証すること。この索引は本テンプレート独自の仕組みで、Strata 本体の機能ではありません。
3. **Meta ファイルの保護**: `.meta` の欠損・重複は致命的。スクリプト削除・移動は UnityEditor API 経由（`Game.Editor.BatchEntry.MoveAsset` / `DeleteAsset`）。
4. **差分（Diff）駆動型のタスク実行**: 全コードをプロンプトに含めず、参照 ID（`cs:Namespace.Type`）を指定して指示を出すこと。

## 📂 ディレクトリ構造
- `Assets/Scripts/Runtime/` ゲームコード（`Game.Runtime`）／ `Assets/Scripts/Editor/` バッチ入口（`Game.Editor`）
- `Assets/Tests/EditMode/`, `Assets/Tests/PlayMode/` 自動テスト
- `Tasks/items/` タスク（1 タスク 1 ファイル。仕様は `Tasks/README.md`）
- `History/runs/` エージェント実行記録（誰が・何に・どんな指示で）
- `.strata/` `launch.json`（Strata の起動設定）, `cache_config.json`（層定義）, `strata_index.json`（コンテキストマップ）
- `.githooks/` チーム共通の git フック／`.github/` CODEOWNERS・PR テンプレート・CI
- `Prompts/` AI 指示書／`Reports/` 日計レポート／`Logs/` Unity CLI 出力（非コミット）
- `tools/` Unity・Strata・Codex の起動、タスク・チーム・履歴、セットアップのスクリプト

## 🔒 コミットしないもの（端末ごとの設定）
`Library/`, `Temp/`, `UserSettings/`, `Logs/*`, `.unity-path.local`, `.claude/settings.local.json`, `.codex-local/`, `.strata/stats.json`, `.strata/cache/`

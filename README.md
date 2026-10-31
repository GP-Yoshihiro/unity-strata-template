# Unity × Claude Code / Codex 24 時間開発テンプレート

Unity プロジェクトを、AI エージェント（**Claude Code / Codex**、任意でローカルモデル [**Strata**](https://github.com/Niko1221/Strata)）に 24 時間開発させるための汎用ひな形です。

> **📦 このリポジトリは「ダウンロードして使う」前提です。**
> GitHub の **Code → Download ZIP** で取得し、展開したフォルダを自分の新しいプロジェクトの出発点にしてください。clone や fork をして、このリポジトリに直接変更を送る使い方は想定していません。新しい GitHub リポジトリの作成は、下の立ち上げ手順の中で AI が行います。

## 🚀 立ち上げ（AI に任せる）

前提: Windows 10/11、PowerShell、[Claude Code](https://claude.com/claude-code) か [Codex CLI](https://github.com/openai/codex) のどちらか。

1. ZIP を浅い場所に展開する（例: `C:\dev\my-game`。Downloads のような深いパスは Unity とエージェントのサンドボックスが失敗しやすい）。
2. そのフォルダで Claude Code（`claude`）か Codex（`codex`）を起動し、こう頼む:

   ```text
   このリポジトリの環境を立ち上げて
   ```

AI はスキル **environment-setup**（`.agents/skills/environment-setup/SKILL.md`）に沿って、次の順に進めます。**選ぶところ**だけ質問されます。

| # | 内容 |
|---|---|
| 1 | 前提ツール（Git / Git LFS / GitHub CLI）の確認と導入 |
| 2 | **新しい GitHub リポジトリの作成**（**名前と公開設定を選ぶ**）と最初の push |
| 3 | **Unity の版を選んで**インストール（このひな形の版／最新 LTS／最新 Update）。ライセンスの有効化 |
| 4 | **Strata のモデル選択**（任意）。賢い順に、GPU 負荷（超高・高・中・低）とこの PC で動くかを表示 |
| 5 | **メイン AI と Strata の接続**、24 時間ループで使うエージェントの決定 |
| 6 | Unity の開発環境（IDE、パッケージ、最初の EditMode テスト） |
| 7 | スキル・Claude Code プラグイン・**spec-kit** の設定 |
| 8 | **動作確認**（指示を**ファイルのパス**か**プロンプト**で渡す）と main ブランチの保護 |

## 🌙 24 時間稼働

AI に「24 時間ループを動かして」と頼むと、スキル **autonomous-loop** に沿って準備・起動します。手動なら、エディタで開かない**ループ専用の clone** で次を実行します。

```powershell
tools\loop.cmd -Once
```

1 件うまく流れたら `tools\loop.cmd` で常時稼働させ、止めるときは `tools\loop.cmd -Stop` を実行します。

| 1 タスクの流れ | |
|---|---|
| 選ぶ・確保 | main 上の未着手タスクを優先度順に選び、claim（二重着手を防ぐロック）する |
| 実装 | エージェント（`claude` / `codex` / `codex-local` / `claude-local`）がタスクの `paths` 内だけを編集する。時間制限あり |
| 検証 | ループが範囲外の変更を取り消し、`.meta` 生成・Unity テストを行い、失敗を AI に返して直させる |
| 提出 | 成功なら PR、失敗が続けば draft PR と `block`。作業ツリーをリセットして次へ |
| 改善 | 24 時間ごとに、結果の記録（`Logs/loop-metrics.jsonl`）から落とし穴（`Docs/agent-lessons.md`）・指示書・タスク分割を **draft PR** で提案する。人がマージするまで使われない |

## 📁 構成

| 場所 | 中身 |
|---|---|
| `AGENTS.md`（`CLAUDE.md` から読み込み） | AI 共通ルールの正本 |
| `.agents/skills/`（`.claude/skills/` はそのコピー） | スキル: `environment-setup` / `autonomous-loop` / `team-workflow` / `unity-workflow` / `strata-delegate` |
| `tools/` | 実行部分: `loop`（24 時間ループ）、`agent`（エージェント実行）、`task`（タスク・claim・spec-kit 取り込み）、`unity`（テスト・`.meta`・インストール・パッケージ）、`strata`（ローカルモデル）、`strata-index`（コンテキスト索引） |
| `Tasks/items/` | タスク（1 タスク 1 ファイル。`Tasks/README.md`） |
| `Prompts/`、`Docs/agent-lessons.md` | 実装・日次改善の指示書、既知の落とし穴 |
| `.strata/` | Strata の起動設定・モデル一覧・コンテキスト層・索引 |
| `.githooks/`、`.github/` | `.meta` 検査・main 直 push 禁止のフック、CI、claim の自動解放 |
| `Assets/` | Unity プロジェクト（`Game.Runtime` / `Game.Editor` / EditMode・PlayMode テスト） |

コミットしないもの: `Library/`、`Temp/`、`UserSettings/`、`Logs/*`、`.unity-path.local`、`.codex-local/`、`.claude/settings.local.json`。

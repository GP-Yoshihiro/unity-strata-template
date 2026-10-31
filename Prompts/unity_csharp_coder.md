# 指示書: Unity C# 実装エージェント（Claude Code / Codex 共通）

## 役割
あなたは本プロジェクトの Unity C# 実装担当です。チームの他メンバー（人間・他エージェント）と同時に作業しています。
`tools\task.cmd list` で未着手（todo）かつ優先度の高いタスクを 1 件だけ選び、claim してから、完了条件を満たすまで実装・テストします。

## 入力（Strata 階層。この順でプロンプトを組む）
- **L1**: `AGENTS.md`、`**/*.asmdef`、`Assets/Scripts/Runtime/Core/**` — 前提知識。変更は最小限に。
- **L2**: タスクの `strataRefs` に挙がったファイルのみ読む。全ファイルを読み込まない。参照先は `.strata/strata_index.json` の `symbols[].id` → `path` で引く。
- **L3**: `git diff`、`Logs/UnityTest-*.log` から抽出したエラー、`Logs/*-results.xml` の失敗テスト名。

## 手順
1. `tools\task.cmd claim <id> -Agent <claude|codex|codex-local>`（並列実行中なら `-Worktree` を付け、以降はそのワークツリーで作業）。拒否されたら別のタスクを選ぶ。
2. 実装（テスト先行が望ましい）。触るのはタスクの `paths` の範囲だけ。新規 `.cs` は適切な asmdef 配下に置く。
3. ログの要約・定型コードの下書きなど軽い作業は `tools\strata.cmd ask` でローカルモデルに委譲してよい（結果は必ず確認）。
4. `tools\unity.cmd test EditMode`（必要なら `PlayMode` / `All`）を実行し、終了コード 0 を確認。
5. ファイルを追加・削除・移動したら `tools\unity.cmd refresh` で `.meta` を生成し、`.meta` もコミットに含める。
6. `tools\strata-index.cmd` で索引更新 → `tools\strata-index.cmd -Verify` が 0。
7. 意味のある単位でコミット（`Task:` などのトレーラーはフックが付ける）。最後に `tools\task.cmd done <id>`、ブランチを push、PR テンプレートを埋めて PR を作る。

## 出力制約
- 応答本文にはコード全文を貼らない。変更は直接ファイルに書き、説明は **変更点の要約と `git diff --stat` 相当** に留める。
- 既存コードを貼り直す必要がある場合は `git diff` 互換の差分のみ。

## 禁止事項
- claim せずに作業すること、他人の claim を `-Force` で奪うこと、タスクの `paths` 外を変更すること。
- default ブランチへの直接 push、`--no-verify`。
- `.meta` ファイルの手書き・手動削除（移動/削除は `Game.Editor.BatchEntry.MoveAsset` / `DeleteAsset`）。
- `Library/`, `Temp/`, `UserSettings/` の編集やコミット。
- Unity / Strata 実行ファイルのパスをハードコードすること（必ず `tools/` 経由）。

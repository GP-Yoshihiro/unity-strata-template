# 指示書: Unity C# 実装エージェント（Claude Code / Codex 共通）

## 役割
あなたは本プロジェクトの Unity C# 実装担当です。`Tasks/backlog.json` の最優先 `todo` タスクを 1 件だけ取り、完了条件を満たすまで実装・テストします。

## 入力（Strata 階層）
- **L1**: `AGENTS.md`、`**/*.asmdef`、`Assets/Scripts/Runtime/Core/**` — 前提知識として参照。変更は最小限に。
- **L2**: タスクの `strataRefs` に挙がったファイルのみ読む。全ファイルを読み込まない。参照先は `.strata/strata_index.json` の `symbols[].id` → `path` で引く。
- **L3**: `git diff`、`Logs/UnityTest-*.log`、`Logs/*-results.xml`。

## 手順
1. タスクを `doing` に更新。
2. 実装（テスト先行が望ましい）。新規 `.cs` は適切な asmdef 配下に置く。
3. `tools/unity.cmd test EditMode`（必要なら `PlayMode` / `All`）を実行し、終了コード 0 を確認。
4. 新規ファイル追加・削除・移動をした場合は `tools/unity.cmd refresh` で `.meta` を生成し、`.meta` もコミットに含める。
5. `tools/strata-index.ps1` でインデックス更新 → `-Verify` が 0 で終わることを確認。
6. タスクを `Tasks/completed.json` へ移動し、1 タスク = 1 コミットでコミット。

## 出力制約
- 応答本文にはコード全文を貼らない。変更は直接ファイルに書き、説明は **変更点の要約と `git diff --stat` 相当** に留める。
- 既存コードを貼り直す必要がある場合は `git diff` 互換の差分のみ。

## 禁止事項
- `.meta` ファイルの手書き・手動削除（移動/削除は `Game.Editor.BatchEntry.MoveAsset` / `DeleteAsset` を使う）。
- `Library/`, `Temp/`, `UserSettings/` の編集やコミット。
- Unity 実行ファイルのパスをハードコードすること（必ず `tools/find-unity.*` 経由）。

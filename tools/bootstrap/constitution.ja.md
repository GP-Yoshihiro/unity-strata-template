# {PROJECT} Constitution

spec-kit（`/speckit.*` コマンド）が仕様・計画・タスクを作るときに守る、このプロジェクトの原則です。
詳細なルールの正本は `AGENTS.md`、既知の落とし穴は `Docs/agent-lessons.md`。

## Core Principles

### I. Unity の作法を守る
- ゲームコードは `Assets/Scripts/Runtime`（asmdef `Game.Runtime`、namespace `Game`）、エディタ拡張は `Assets/Scripts/Editor`。
- `.meta` を手で作成・編集・削除しない（生成は `tools\unity.cmd refresh`、移動・削除は `Game.Editor.BatchEntry`）。
- シーン・プレハブは同時に 1 人（1 タスク）だけが編集する。バイナリ素材は `git lfs lock` してから。

### II. テスト先行（NON-NEGOTIABLE）
- 振る舞いを足すときは先に EditMode テスト（`Assets/Tests/EditMode`）を書く。ロジックは `UnityEngine` に依存しない純粋な C# に寄せる。
- 完了の条件は `tools\unity.cmd test EditMode`（必要なら `All`）と `tools\strata-index.cmd -Verify` が終了コード 0。

### III. 小さく分けて衝突させない
- 1 タスク = 1 ブランチ = 1 PR。タスクの `paths`（触るファイル・フォルダ）を狭く明確にする。
- spec-kit の `tasks.md` は `tools\task.cmd import <tasks.md>` で `Tasks/items/` に起票し、claim してから着手する。

### IV. コンテキストを節約する
- コードは `cs:Namespace.Type`（`.strata/strata_index.json`）で参照し、全文を貼らない。
- ログは全文ではなく `error CS\d{4}` と失敗テスト名だけを渡す。軽い作業はローカルモデル（`tools\strata.cmd ask`）に委譲し、結果は必ず確認する。

### V. 秘匿情報を公開しない
- 指示文・会話・実行結果は非公開の `.history/` と履歴リポジトリにだけ置く。公開リポジトリ・コミット・PR に書かない。

## Governance
- この Constitution は仕様・計画・タスクより優先する。変更は PR で行い、`AGENTS.md` と矛盾させない。

**Version**: 1.0.0 | **Ratified**: {DATE} | **Last Amended**: {DATE}

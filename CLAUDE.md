# CLAUDE.md

共通ルールは AGENTS.md（Codex と共有）にあります。Claude 固有の追記のみここに書きます。

@AGENTS.md

## Claude Code 固有
- プロジェクトスキル `unity-workflow` / `team-workflow` / `strata-delegate`（`.claude/skills/`）は `.agents/skills/` のコピーです。編集は `.agents/skills/` 側で行い、`tools\setup.cmd`（または `tools/setup.sh`）で同期してください。
- Claude Code を直接使うときも、着手前に `tools\task.cmd claim` を行い、履歴を残したい実行は `tools\agent.cmd claude "指示"` 経由で行ってください。

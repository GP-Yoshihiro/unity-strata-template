# CLAUDE.md

共通ルールは AGENTS.md（Codex と共有）にあります。Claude 固有の追記のみここに書きます。

@AGENTS.md

## Claude Code 固有
- プロジェクトスキル `unity-workflow`（`.claude/skills/`）は `.agents/skills/` のコピーです。編集は `.agents/skills/` 側で行い、`tools/setup.ps1`（または `tools/setup.sh`）で同期してください。

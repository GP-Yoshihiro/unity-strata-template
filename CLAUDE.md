# CLAUDE.md

共通ルールは AGENTS.md（Codex と共有）にあります。Claude Code 固有の追記のみここに書きます。

@AGENTS.md

## Claude Code 固有
- `.claude/skills/` は `.agents/skills/` のコピーです。編集は `.agents/skills/` 側で行い、`Copy-Item .agents\skills\* .claude\skills -Recurse -Force` で同期してください。
- 権限は `.claude/settings.json`（`.meta` の編集、force push、`--no-verify` を拒否）。

# CLAUDE.md

This project's agent guide is [AGENTS.md](AGENTS.md) — it already targets both
Claude Code and Codex, and is kept in sync with the code. Read it before
touching anything here; nothing below duplicates it.

Quick pointers specific to working from Claude Code in this repo:

- Shell is PowerShell 7 (`pwsh`), not bash — see AGENTS.md's "طقوس الإصدار" and
  "الاختبار" sections for the exact commands (`Run-Checks.ps1`, Pester paths).
- Never send an air-changing command (`SHOW`, `HIDE`, `EXIT_SCENE_LOOP`) to a
  live Cinegy port while developing or diagnosing — status reads are fine.
- Never print, log, or commit `BotToken` or anything matching
  `token|secret|password|apikey`.
- `config.json`, `templates.json`, `logs/`, `artifacts/`, `dist/` are runtime
  output, not source — don't hand-edit `config.json` while the bridge is
  running, and don't add these to git.

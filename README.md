# KING

## ECC integration

This repository is wired up for [ECC](https://github.com/affaan-m/ECC) (Agent
Harness Performance Optimization System) — an MIT-licensed plugin for Claude
Code that adds structured agents, skills, hooks, and review workflows.

### Install validation

Before installing anything, the ECC repository and its documented install
paths were reviewed (without cloning) to confirm the safe, official route.
ECC's own README states:

> Install ECC only from verified channels: the GitHub repository, the npm
> packages (`ecc-universal` and `ecc-agentshield`), the GitHub App, and the
> project website. Third-party re-uploads and unofficial mirrors are not
> maintained or reviewed and may contain malware.

The recommended path for Claude Code is the native plugin marketplace
mechanism (not a manual `git clone` + script run), so that's what was used:

```
claude plugin marketplace add https://github.com/affaan-m/ECC
claude plugin install ecc@ecc
```

This avoids stacking installation methods (plugin + manual `install.sh` +
npm), which ECC's docs warn causes duplicated skills, commands, and hooks.

### What's installed

- Plugin: `ecc@ecc` v2.2.0 — 380 skills, 68 agents, 7 lifecycle hooks
  (`PreToolUse`, `PostToolUse`, `SessionStart`, etc.), 1 MCP server
  (`chrome-devtools`).
- Config: `hooks_enabled: true`, `hook_profile: standard`.
- Manifest validated with `claude plugin validate`.

### Project-level integration

[`.claude/settings.json`](.claude/settings.json) declares the `ecc`
marketplace and enables the `ecc@ecc` plugin at **project scope**. Anyone who
clones this repository and opens it in Claude Code gets the ECC marketplace
and plugin automatically — no manual per-user setup required.

### Notes for contributors

- Do not layer the manual `./install.sh` or `ecc-universal` npm install on
  top of this project-scope plugin install — pick one method only.
- Plugin changes take effect after restarting the Claude Code session.
- Run `claude plugin list` to confirm `ecc@ecc` is enabled, and
  `claude plugin details ecc@ecc` to see the current component inventory and
  projected token cost.

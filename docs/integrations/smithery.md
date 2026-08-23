# Smithery

A hosted MCP server registry/marketplace ("discover and connect to 100K+ AI
tools and skills") — not a library, nothing vendored. Integrated purely via
its CLI and account, matching the tier decision in
[scalability-system.md](./scalability-system.md): **integrate, don't
vendor**.

## CLI, verified against the real 1.2.0 release

```bash
npx -y smithery@latest --help
```

```
Commands:
  mcp    Search, connect, and manage MCP servers
  tool   Find and call tools from MCP servers added via 'smithery mcp'
Authentication:
  auth   Authentication and permissions
Management:
  setup  Install the Smithery CLI skill for your agent
```

- **Auth**: `smithery auth login` (opens a browser OAuth flow; non-TTY
  contexts get a JSON `auth_url` back for the operator to open manually).
  `smithery auth whoami` / `smithery auth logout`.
- **Discover**: `smithery mcp search <term>`.
- **Connect** (several real forms, confirmed via `--help`):
  ```bash
  smithery mcp add exa                                          # by registry name
  smithery mcp add http://localhost:9090/mcp --id chrome         # by URL
  smithery mcp add --id chrome -- npx -y @some/mcp-server        # wraps a stdio command
  smithery mcp add exa --client claude                           # installs straight into a client's own MCP config
  ```
  `--client` accepts `claude-code`, `cursor`, `vscode`, `windsurf`, `cline`,
  and a dozen others — this can write directly into e.g. this workspace's
  own `.mcp.json` (the same file `claude mcp add repomix` wrote to in the
  repomix phase) if you want a Smithery-discovered server registered the
  same way.
- **Use tools**: `smithery tool list <connection>`,
  `smithery tool find <connection> <query>`,
  `smithery tool call <connection> <tool> '<json-args>'`.
- **Publish** (for putting OmniRoute's own MCP server on the registry, see
  below): `smithery mcp publish <url> -n <org/name>`.

## Two integration directions for this workspace

### 1. Pull third-party MCP servers in (the common case)

Use `smithery mcp add <name-or-url>` to give `agent-sidecar` or OpenHands
Agent Canvas access to any registry MCP server without hand-vendoring it —
the same role Smithery plays for the whole MCP ecosystem that `graphify
claude install` and `claude mcp add repomix` play for this repo's own two
tools. Point `agent_sidecar/mcp_tools.py`'s pattern (see
`smolagents_mcp_server_parameters()`/`pydantic_ai_mcp_toolset()`) at
whatever URL `smithery mcp add` reports for the connection.

### 2. Publish OmniRoute's own MCP server (deliberately not done here)

OmniRoute's MCP server (`omniroute/open-sse/mcp-server/`, 110 tools) could
be published to Smithery for external discoverability —
`smithery mcp publish <your-tunnel-or-public-url> -n <org>/omniroute`. This
is **not done as part of this phase**, on purpose: publishing exposes
OmniRoute's MCP surface to callers outside this machine, which is exactly
the class of decision `omniroute/AGENTS.md` Hard Rules #15 and #17 are
about (routes that spawn child processes — including `/api/mcp/` — must
stay `isLocalOnlyPath()`-classified; a leaked JWT via a tunnel must not be
able to trigger process spawning). Publishing would need either a properly
authenticated public gateway in front of OmniRoute's MCP endpoint, or a
narrowly-scoped read-only tool subset — a real design decision for the
repo's operator to make deliberately, not something to default into via a
one-line CLI command. Do this only after operating the MCP server locally
for a while (phases 3–5 of this doc set already did) and deciding
specifically what should be exposed.

## Skill install — validated, and it's user-level, not project-level

Ran `npx -y smithery@latest setup -a claude-code` in this workspace to give
Claude Code sessions a discovery skill for Smithery, the same way `graphify
claude install` did for Graphify. **Important difference, found by
checking where it actually landed**: unlike Graphify's install (which
writes into the project's own `CLAUDE.md` + `.claude/settings.json`, so
every KING contributor gets it automatically on clone), Smithery's `setup`
command installed to `~/.claude/skills/smithery-ai-cli` — the operator's
**home directory**, not `/home/user/KING/.claude/skills/`. Confirmed via
`git status` showing zero repo changes from the command. This isn't a bug
to work around: Smithery's whole model is "connect once, use everywhere"
tied to *your* account and OAuth session, so a user-level, per-operator
install is the coherent behavior here — unlike Graphify (deterministic,
credential-free, sensible as shared project config), baking Smithery's
skill into the repo wouldn't make sense anyway, since the account behind it
is personal. Anyone who wants this skill in their own Claude Code runs the
same one command themselves:

```bash
npx -y smithery@latest setup -a claude-code
```

## Status

CLI installed and its exact command surface verified against the real
1.2.0 release (not just documentation). `setup` was run and confirmed to
install correctly, at user scope. Actually connecting a third-party MCP
server and publishing OmniRoute's own were **not** exercised — the former
needs a concrete third-party server the operator actually wants, the
latter needs the deliberate exposure-scoping decision described above;
both are next steps for whoever operates this workspace, not something to
default into.

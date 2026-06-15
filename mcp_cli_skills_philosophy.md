# MCP vs Direct CLI Usage with Skills

## A practical philosophy for GPT-5.5/Codex-style agents

The preferred architecture is not **MCP everywhere**. It is a layered tool philosophy:

> **Use direct CLI for the local development loop, skills for repeatable workflows, AGENTS.md for standing repo guidance, and MCP for external systems or shared integrations.**

State-of-the-art coding agents are strong enough to use shell tools directly when those tools are predictable, scriptable, and well documented. Wrapping every command in MCP usually adds ceremony without improving capability. MCP is valuable, but it should be used where it creates a real integration boundary, not as decorative plumbing.

---

## Core principle

Choose the thinnest reliable interface that gives the agent the right capability.

A good agent stack should optimize for:

1. **Composability**: tools should work together through files, pipes, JSON, exit codes, and normal developer workflows.
2. **Low friction**: the agent should not need a protocol server for every local command.
3. **Repeatability**: workflows that recur should be captured as skills, not re-explained in every prompt.
4. **Context efficiency**: instructions and external data should be loaded only when needed.
5. **Governance**: dangerous actions should have clear approval gates, dry-run modes, logs, and safe defaults.
6. **Human usefulness**: tools built for agents should also be useful to humans, CI jobs, and scripts.

The practical result:

```text
AGENTS.md      = standing repo rules
Direct CLI     = local execution and coding loop
Skills         = repeatable procedures and tool-use recipes
MCP            = external systems, shared auth, and durable integrations
Subagents      = specialized delegation when workflows become complex
```

---

## The default architecture

For most engineering teams, the best baseline is:

```text
repo/
  AGENTS.md
  .codex/
    config.toml
  .agents/
    skills/
      release-notes/
        SKILL.md
      ci-triage/
        SKILL.md
      database-migration-review/
        SKILL.md
  bin/
    internal-tool
    agent-search
    deploy-helper
```

Use this structure as the default before introducing MCP servers for everything.

---

## What each layer is for

### AGENTS.md

`AGENTS.md` defines durable repo-level guidance.

It should answer questions like:

- What package manager should the agent use?
- Which test commands matter?
- What code style and review rules should be followed?
- Which directories are generated or off-limits?
- Which changes require extra care or approval?
- How should commits, branches, or PRs be structured?

Use `AGENTS.md` for rules that apply broadly across the repository.

Do not put long task-specific operating manuals in `AGENTS.md`. Those belong in skills.

---

### Direct CLI

Direct CLI is the preferred interface for the local development loop.

Use direct shell or CLI calls for:

- `git`
- `rg`, `grep`, `find`, `jq`, `sed`, `awk`
- package managers such as `npm`, `pnpm`, `yarn`, `pip`, `uv`, `cargo`, `go`, `bundle`
- test runners such as `pytest`, `vitest`, `jest`, `go test`, `cargo test`
- linters and formatters
- local scripts
- internal command-line tools
- database migration tooling, when safe and scoped
- build commands
- artifact generation

Direct CLI works best when commands are:

- non-interactive by default
- documented with useful `--help`
- deterministic
- safe to run repeatedly
- compatible with environment-based auth
- able to emit JSON or concise structured output
- clear about exit codes
- equipped with `--dry-run`, `--limit`, `--output`, or `--yes` where appropriate

A state-of-the-art coding model can usually compose these tools effectively without an MCP wrapper.

---

### Skills

Skills are for repeatable workflows.

They are the procedural layer that tells the agent:

- when to use a workflow
- which tools to use
- what order to use them in
- what to inspect first
- what output to preserve
- what risks to avoid
- what approval gates apply
- what final format is expected

Use a skill when a workflow is repeated often enough that you do not want to describe it from scratch each time.

Good skill examples:

- CI failure triage
- release-note generation
- dependency upgrade review
- migration safety review
- incident log summarization
- design-doc drafting
- performance regression investigation
- customer bug reproduction
- security-sensitive code review
- PR readiness checklist

Skills are especially effective when paired with an agent-friendly CLI.

The CLI gives the agent capability. The skill teaches judgment.

---

### MCP

MCP is for durable integrations with external or shared systems.

Use MCP when the agent needs:

- authenticated access to an external system
- structured tools exposed across multiple clients
- OAuth or bearer-token handling
- shared team configuration
- remote resources outside the repo
- live context that should not be pasted into prompts
- a stable schema around an API
- approval boundaries for sensitive actions
- reusable access to issue trackers, design tools, observability platforms, docs, cloud services, or browsers

Good MCP examples:

- Linear, Jira, GitHub Issues, or GitLab issues
- Sentry, Datadog, Honeycomb, Grafana, or similar observability tools
- Figma or design systems
- documentation portals and internal knowledge bases
- browser automation
- cloud management APIs
- customer-support systems
- CRM or ticketing systems
- internal platform APIs with shared auth requirements

MCP is valuable when it turns a messy external system into a clear, typed, reusable capability.

It is usually not valuable for wrapping simple local commands that already work well in the terminal.

---

## Decision matrix

| Need | Preferred interface | Why |
|---|---:|---|
| Edit code, inspect files, run tests | Direct CLI | Lowest friction and closest to normal development |
| Search the repo | Direct CLI | `rg`, `git grep`, and file tools are already excellent |
| Run build, lint, format, or tests | Direct CLI | These are native shell workflows |
| Enforce standing repo conventions | AGENTS.md | Always-on guidance without repeated prompts |
| Repeat a multi-step process | Skill | Captures procedure without bloating every prompt |
| Teach the agent how to use an internal CLI | Skill + direct CLI | Keeps tool composable and human-usable |
| Access external systems | MCP | Provides structured, authenticated integration |
| Share a tool integration across teams | MCP | Centralizes setup, schemas, and auth patterns |
| Connect skills to external APIs | Skill + MCP | Skill provides workflow, MCP provides capability |
| Delegate specialized tasks | Subagent | Useful once workflows become complex or role-specific |

---

## The promotion path

Do not start with MCP by default. Promote gradually.

### Stage 1: Direct CLI

Start by making the command agent-friendly.

Useful traits:

```text
--help
--json
--limit
--id
--dry-run
--output-file
--no-color
--non-interactive
--yes
--verbose
--quiet
```

Prefer compact, paginated, exact output over large dumps.

Bad:

```bash
internal-tool dump-everything
```

Better:

```bash
internal-tool search errors --query "timeout" --limit 20 --json
internal-tool get issue --id ISSUE-123 --json
internal-tool update issue --id ISSUE-123 --status resolved --dry-run
```

### Stage 2: Add a skill

When the workflow becomes repeatable, write a skill.

The skill should explain:

- when to trigger the workflow
- first commands to run
- how to inspect state
- how to avoid excessive output
- what actions require approval
- expected final answer format

Example skill purpose:

```text
Use this skill when triaging failed CI jobs.
It guides the agent through fetching failure metadata, identifying the failing test,
checking recent related changes, reproducing locally, and producing a concise fix plan.
```

### Stage 3: Promote to MCP

Move to MCP when the workflow needs:

- external live data
- shared authentication
- cross-client availability
- reusable schemas
- centralized governance
- remote execution
- secure access boundaries

MCP should be a deliberate productization step, not a reflex.

---

## Agent-friendly CLI design contract

A CLI intended for agents should follow this contract.

### 1. Be discoverable

Every command should have useful help text.

```bash
mytool --help
mytool search --help
mytool get --help
mytool update --help
```

### 2. Be non-interactive

Avoid prompts. Use flags instead.

Bad:

```text
Are you sure? [y/N]
```

Better:

```bash
mytool deploy --env staging --confirm
mytool deploy --env staging --dry-run
```

### 3. Emit structured output

Support JSON for machine-readable results.

```bash
mytool search tickets --query "login timeout" --limit 10 --json
```

### 4. Keep output bounded

Large output poisons context.

Prefer limits, pagination, IDs, summaries, and exact retrieval.

```bash
mytool logs search --service api --since 1h --limit 50 --json
mytool logs get --id log_abc123 --context 20
```

### 5. Separate reads from writes

Reads should be easy. Writes should be explicit.

```bash
mytool issue update --id ENG-123 --status done --dry-run
mytool issue update --id ENG-123 --status done --confirm
```

### 6. Use meaningful exit codes

The agent should be able to distinguish:

- success
- no results
- validation failure
- auth failure
- remote service failure
- unsafe operation blocked

### 7. Support dry runs

For any destructive or externally visible action, provide a dry-run mode.

```bash
mytool delete-cache --service api --dry-run
```

### 8. Make auth boring

Prefer environment variables, standard credential helpers, or preconfigured profiles.

The agent should not paste secrets into prompts or command lines.

---

## Skill design contract

A good skill should be short, scoped, and operational.

It should include:

1. **Purpose**: when the skill applies.
2. **Inputs**: what information the agent needs.
3. **Procedure**: the recommended step sequence.
4. **Tools**: commands, CLIs, MCP tools, or scripts to use.
5. **Safety rules**: actions requiring confirmation.
6. **Output format**: what the agent should return.
7. **Examples**: one or two concrete examples when helpful.

A skill should not become a junk drawer.

Bad skill:

```text
engineering-everything
```

Good skills:

```text
ci-triage
release-notes
migration-review
dependency-upgrade
incident-summary
```

Skills should be small enough that the agent can decide when to load them without dragging half the organization’s operating manual into context.

---

## MCP design contract

An MCP server should expose meaningful capabilities, not merely mirror shell commands one-to-one.

Good MCP tools are:

- scoped
- typed
- documented
- permission-aware
- safe by default
- explicit about side effects
- consistent in response shape
- useful across multiple agent clients

Bad MCP design:

```text
run_shell_command(command: string)
```

This recreates a shell with extra risk and less transparency.

Better MCP design:

```text
search_issues(query, status, limit)
get_issue(id)
create_issue(title, body, labels)
update_issue_status(id, status)
list_recent_errors(service, since, limit)
get_error_trace(error_id)
```

MCP should expose domain-level operations, not arbitrary remote execution unless that is explicitly the product and heavily governed.

---

## Anti-patterns

### Anti-pattern 1: MCP-wrapping every local command

Do not create MCP tools for commands like:

```bash
git status
rg "foo"
npm test
pytest
cargo test
jq . file.json
```

These commands already work well through direct CLI.

Wrapping them usually reduces composability and increases maintenance.

### Anti-pattern 2: giant AGENTS.md files

`AGENTS.md` should not contain every process in the company.

Move task-specific procedures into skills.

### Anti-pattern 3: giant skills

A skill should represent one workflow.

If a skill has many unrelated sections, split it.

### Anti-pattern 4: raw API dumping

Do not make the agent ingest huge unfiltered API responses.

Prefer search, filtering, exact retrieval, and summaries.

### Anti-pattern 5: hidden side effects

Any tool that changes state should make side effects obvious.

Use:

```text
preview -> dry run -> confirmation -> execution -> audit trail
```

### Anti-pattern 6: interactive-only internal tools

Agents are poor at interactive terminal sessions compared with deterministic commands.

Provide flags, JSON, and explicit confirmation options.

---

## Security and governance

Tooling for agents should assume that mistakes are possible.

Use guardrails such as:

- read-only defaults
- explicit write modes
- dry-run support
- approval requirements for destructive actions
- scoped credentials
- environment-specific permissions
- audit logs
- least-privilege tokens
- safe output redaction
- command allowlists where appropriate

Sensitive workflows should distinguish between:

```text
read actions       = usually okay by default
write actions      = require explicit intent
external effects   = require confirmation or policy gate
destructive actions = require strong approval and auditability
```

Examples of high-risk actions:

- production deploys
- database writes
- deleting data
- changing permissions
- rotating secrets
- modifying billing settings
- sending customer communications
- closing security incidents
- merging high-risk PRs

For these, the tool surface should make caution structural, not optional.

---

## Practical examples

### Example 1: CI triage

Preferred stack:

```text
AGENTS.md: tells the agent which test commands matter
Direct CLI: runs tests locally
Skill: defines the CI triage process
MCP: fetches CI provider logs only if needed
```

Workflow:

```bash
rg "failing_test_name"
pnpm test -- failing_test_name
pnpm lint
```

If CI logs live externally and require authenticated structured access, use MCP for those logs.

---

### Example 2: Release notes

Preferred stack:

```text
Direct CLI: git log, git diff, local changelog script
Skill: release-note style and classification rules
MCP: issue tracker lookup for ticket metadata
```

The agent can use local Git history directly. MCP is useful only for enriching commits with external ticket context.

---

### Example 3: Internal observability

Preferred stack:

```text
MCP: structured access to errors, traces, dashboards, and incidents
Skill: incident investigation workflow
Direct CLI: local reproduction and test execution
```

Observability data changes constantly, lives outside the repo, and often needs authenticated access. MCP is appropriate.

---

### Example 4: Database migration review

Preferred stack:

```text
AGENTS.md: migration safety rules
Direct CLI: migration diff, schema validation, test DB checks
Skill: review checklist and risk classification
MCP: production metadata only if access is approved and necessary
```

Do not casually give the agent broad production write access. Use explicit read-only metadata tools where possible.

---

## Rule of thumb

Use this decision tree:

```text
Is this a standing repo rule?
  -> Put it in AGENTS.md.

Is this a local command or script that already works well in a terminal?
  -> Use direct CLI.

Is this a repeated multi-step workflow?
  -> Write a skill.

Does the workflow need external, live, authenticated, shared, or cross-client access?
  -> Use MCP.

Is the workflow complex enough to require a specialized role or parallel delegation?
  -> Consider a subagent.
```

The best system is usually a braid, not a tower.

```text
AGENTS.md gives orientation.
CLI gives hands.
Skills give habits.
MCP gives reach.
Subagents give specialization.
```

---

## Recommended team standard

Adopt the following policy:

> We do not wrap local developer commands in MCP unless there is a specific integration, security, or sharing reason. We first make tools agent-friendly as CLIs, document repeated procedures as skills, and introduce MCP for external systems, shared authentication, typed APIs, and durable cross-client integrations.

This keeps the agent stack simple, powerful, inspectable, and useful to both humans and models.

---

## Implementation checklist

Before building an MCP server, ask:

- Can the agent already do this safely through direct CLI?
- Would a better `--json` or `--dry-run` flag solve the problem?
- Is the missing piece actually workflow knowledge rather than tool access?
- Would a skill be enough?
- Does this need shared authentication or access to external live data?
- Will multiple teams or agent clients reuse this integration?
- Are there clear permission and approval boundaries?
- Are side effects explicit and auditable?

If the answer is mostly “local command + repeated process,” build an agent-friendly CLI and a skill.

If the answer is mostly “external system + shared auth + structured tool surface,” build MCP.

---

## References

- [OpenAI Codex CLI documentation](https://developers.openai.com/codex/cli)
- [OpenAI Codex skills documentation](https://developers.openai.com/codex/skills)
- [OpenAI Codex best practices](https://developers.openai.com/codex/learn/best-practices)
- [OpenAI Codex AGENTS.md guide](https://developers.openai.com/codex/guides/agents-md)
- [OpenAI Codex MCP documentation](https://developers.openai.com/codex/mcp)
- [OpenAI agent-friendly CLI use case](https://developers.openai.com/codex/use-cases/agent-friendly-clis)
- [Model Context Protocol documentation](https://modelcontextprotocol.io/docs/getting-started/intro)

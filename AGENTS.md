# AGENTS.md

## Mandatory execution policy — GitHub-first, operator-minimal

This policy has top workflow priority for all current and future development, remediation, review, and maintenance phases in this repository. It overrides older execution/workflow instructions where they conflict, but it never overrides an explicit scope or safety boundary in the current user mandate.

1. **GitHub is the primary work surface and source of truth.** Use GitHub-native/connected capabilities first for repository inspection, branches, file edits, commits, pull requests, diffs, reviews, CI status/logs, and merges when the current phase authorizes them.
2. **Minimize operator involvement.** Do not ask the user to copy/paste scripts, relay command output, or perform routine Git/GitHub steps when an available connected tool can perform the same operation. Within the currently authorized phase, carry routine steps through autonomously.
3. **Respect the phase boundary.** Autonomy applies only to the phase currently authorized. Do not start a subsequent phase, broaden product scope, deploy, publish, merge, mutate production data, or perform another action that the current mandate reserves for later approval.
4. **Independent reviews remain read-only.** A review/re-review agent must not modify the reviewed branch, remediate findings, or alter runtime state unless the user explicitly changes the mandate.
5. **Remote Desktop Commander is a last resort.** Use it only when the required operation is genuinely impossible through GitHub, CI, available connectors/tools, or another non-interactive route and access to the real NAS/PC/GUI/filesystem/runtime is indispensable. Never select it merely out of convenience.
6. **CloudCLI requires explicit prior user authorization.** Use CloudCLI only when coding/debugging truly requires the real environment and GitHub/CI cannot provide sufficient evidence or execution. Do not use CloudCLI for ordinary repository editing, Git operations, documentation updates, or routine inspection.
7. **Prefer reproducible automation over ad-hoc terminal work.** When real-environment execution is recurring, encode it in versioned scripts or GitHub Actions/self-hosted-runner workflows where safe, rather than repeatedly asking the user to execute shell fragments.
8. **Manual user steps are exceptional.** If no automated route exists, explain why the manual step is unavoidable and provide the smallest safe self-contained command block. Do not split a routine operation into many copy/paste exchanges.
9. **Ask only for decisions that require human authority or information.** Examples: a product/scope choice not determined by the current mandate, destructive/irreversible production action, secret/credential input, or an explicit approval gate. Do not ask for confirmation of routine reversible steps already covered by the phase.
10. **Verify before claiming completion.** Check the exact branch/SHA, relevant diff, CI/tests, and any required runtime evidence. At handoff report the exact state, what was verified, unresolved limitations, and the next permitted step.
11. **Do not silently substitute environments.** GitHub/CI evidence is preferred for source-level work. If correctness depends on NAS/Windows/Home Assistant/other real runtime behavior, state that dependency and obtain the required authorization before using CloudCLI; use Remote Desktop Commander only if indispensable under rule 5.
12. **Keep secrets and production state out of GitHub.** Use repository secrets/environments or runtime secret stores. Never commit tokens, passwords, private runtime databases, or sensitive generated state.

### Default execution order

GitHub inspection → scoped branch/worktree → implementation or read-only review as mandated → automated tests/CI → PR/review evidence → merge only if authorized → real-environment validation/deploy only if authorized and necessary.

If a task can be completed reliably without involving the user in mechanical steps, it should be.

## Source-integrity invariant — no local-only source changes

This invariant is mandatory for every coding agent, including CloudCLI/Claude Code, Codex, ChatGPT, self-hosted runners, and future agents.

1. **A production/runtime checkout is never a development workspace.** Do not edit application source in a directory whose files are consumed directly by a running service/container/plugin/runtime. Use a dedicated task branch and a separate worktree/clone.
2. **Every source change must become a GitHub commit before handoff or deployment.** A change is not durable, shareable, reviewable, or complete while it exists only as an uncommitted/unpushed local filesystem edit.
3. **Push before deploy.** The exact code intended for runtime must first exist on GitHub at a named branch and immutable commit SHA. Runtime actions must record/verify that SHA.
4. **No deploy from a dirty tree.** Do not restart/redeploy merely to activate uncommitted source edits. If a runtime checkout is dirty, treat that as source-integrity drift and stop normal deployment.
5. **Never erase drift to make Git look clean.** If a production/runtime checkout contains local-only changes, preserve them first on a rescue branch/commit and push them to GitHub before reset, checkout, pull, rebase, replacement, or cleanup.
6. **Agent isolation is mandatory.** One task/agent = one branch/worktree. Two agents must not write concurrently to the same working tree. Handoff occurs through pushed commits/PRs, not shared uncommitted files.
7. **Start from remote truth.** Before editing, fetch origin and verify the intended remote branch/SHA. A clean worktree whose HEAD differs from GitHub is still drifted.
8. **End with remote truth.** Before claiming completion, verify that the final intended commit exists on GitHub and report its branch/SHA. If a task intentionally remains read-only, say so instead.
9. **Runtime verification is separate from source publication.** Tests or behavior observed from locally modified runtime files do not prove that GitHub contains those changes.
10. **Local-only emergency fixes are temporary quarantine states, not a workflow.** If an emergency runtime edit is unavoidable, immediately capture the exact source delta on a dedicated rescue/fix branch, test it, push it, and only then continue normal work.

For repositories with a NAS bridge, the bridge should compare both the technical Git workspace and, where available, the real runtime checkout. A green technical mirror must never be interpreted as proof that production is synchronized.

## Shared NAS control bridge — canonical runtime access path

This repository participates in a shared, GitHub-mediated NAS control architecture. This section is operational policy and does not override repository-specific review, deployment, or production safety gates.

### Canonical path

ChatGPT / connected GitHub tooling → `golgoth85/upscaler` branch `ops/nas-control` → GitHub Actions workflow `NAS Control` → self-hosted runner label `nas-control` → authenticated local agent `nas-control-agent` → Unraid Docker / approved filesystem reads / LAN services.

### Security boundary

- The active runner container is `github-runner-nas-control-v2`.
- The runner is intentionally least-privilege: it has runner state plus the local control token mounted read-only; it does **not** receive `/var/run/docker.sock` and does **not** mount `/mnt/user/appdata` directly.
- The local `nas-control-agent` is the only component with Docker-socket access. It exposes a typed allowlist of operations, not an arbitrary root shell.
- `/mnt/user/appdata` is mounted read-only inside the agent.
- Potentially sensitive files such as env/secret/token/credential/key material are blocked from generic file-read operations.
- State-changing Docker actions require an explicit confirmation field.
- Never weaken this boundary merely to make an operation more convenient. Add a typed, narrowly scoped capability instead.

### Current verified reachability

- Unraid main web surface: `192.168.1.55:1234`.
- Home Assistant: `192.168.1.147:8123`; network reachability is verified. `/api/` returns 401 without authentication, so authenticated HA actions require a separately provisioned token/secret boundary.
- LM Studio: `192.168.1.249:1234`; when the PC is on and LM Studio server is running, `/v1/models` returns an OpenAI-compatible HTTP 200 response.
- Tailscale is installed on the Flint 2 router. Tailscale on Unraid is disabled. Normal NAS/LAN access therefore goes directly over the LAN; do not assume a local `tailscaled` socket exists on Unraid.

### Available / intended typed operations

The hardened agent supports or is designed to support typed operations including capabilities, Docker list/inspect/logs/start/stop/restart, controlled appdata listing/file reads, Git status, TCP/HTTP probes, Home Assistant discovery/probe, and LM Studio model probing.

A read-only `disk_space` capability for the Unraid `/mnt/user` filesystem is versioned in `ops/nas-control`. If the running agent predates that version, refresh the live agent before relying on `disk_space`.

### Execution preference

1. Use GitHub-native repository operations for source-level work.
2. Use the shared NAS control bridge for runtime inspection or narrowly scoped runtime actions when the current mandate authorizes them.
3. Do not ask the operator to use Termius for routine actions that the bridge can perform.
4. Remote Desktop Commander is not the preferred path and may be unavailable due to quota.
5. CloudCLI still requires explicit prior user authorization.
6. A runtime bridge capability never overrides an independent-review read-only mandate, a no-deploy/no-merge instruction, or another explicit phase gate.


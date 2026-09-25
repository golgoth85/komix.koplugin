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

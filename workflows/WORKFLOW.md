---
config:
  vendor: github
  id: humdrum00001010/symphony
  states:
    - OPEN
  terminal_states:
    - CLOSED
  workspace: ./.symphony/
mount: mkdir -p "$workspace/$repo_id" && git worktree add --detach "$workspace/$repo_id/$issue" HEAD
terminate: git worktree remove --force "$workspace/$repo_id/$issue"
agent:
  vendor: codex
  model: gpt-5.6-sol
  reasoning: high
---

Your session pauses only when the last GitHub issue comment ends with "∎". Use `gh` CLI.

You are responsible with implementation & PR of the issue.

Workflow is simple:
- Read CONTRIBUTING.md if exists, follow it, especially with tests before PR.
- Prefer debugger to understand the nature of the issue. Write debugger script when supported by the debugger.
- When you could reduce problem into single function, explain it with the name in issue comment, work on, make PR.

Branch in git with <service>/<content> branch name, expected to use clean commit messages.

PR body must detail focusing on the semantics on the implementation you wrote.
Inline comment is expected for most works. Write assertive comments on abstraction of code you wrote.

You aren't allowed to merge PR, open PR always in Draft mode.

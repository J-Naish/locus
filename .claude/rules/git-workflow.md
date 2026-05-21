# Git Workflow

## Commit Message Format

Use short imperative commit messages:

```text
Add workspace listing tests
Fix file list sorting
Update macOS bridge logging
```

Use an optional body when the change needs rationale, tradeoffs, or follow-up context.
Do not mention agents, AI tools, or implementation process unless that is the actual product or documentation change.

Note: Attribution disabled globally via ~/.claude/settings.json.

## Pull Request Workflow

When creating PRs:
1. Analyze full commit history (not just latest commit)
2. Use `git diff [base-branch]...HEAD` to see all changes
3. Draft comprehensive PR summary
4. Include a test plan with completed checks and any clearly labeled gaps
5. Push with `-u` flag if new branch

## Change Hygiene

- Keep each commit focused on one coherent product, documentation, or infrastructure change
- Stage files explicitly
- Do not reformat unrelated files
- Do not amend, squash, rebase, force-push, or rewrite history unless explicitly asked
- If unrelated work is present, leave it unstaged and mention it

> For the full development process before git operations, follow the project rules and the relevant language-specific rules.

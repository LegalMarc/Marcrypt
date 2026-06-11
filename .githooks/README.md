# Git hooks

Repo-managed hooks that keep confidential and internal content out of the
published repository.

## Enable (once per clone)

```bash
git config core.hooksPath .githooks
```

## `pre-commit`

Runs `scripts/check_publishable.py` and blocks the commit if the staged tree
contains:

- confidential/binary document files (PDF, Word, Excel, PowerPoint, iWork, RTF,
  ZIP, …) — these may carry client or personal data and must never be tracked;
- forbidden text — client/company identifiers, sibling-project codenames,
  internal backlog ticket ids, or app-specific-password-format credentials.

The same check runs in CI (`.github/workflows/public-beta-validation.yml` and
`scripts/test_all.sh`), so it is enforced even if the local hook is not enabled.
Real sample documents belong under the git-ignored `ignore-resources/` tree.

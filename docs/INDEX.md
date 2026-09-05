# Docs index

<!-- docs-sync
roots: docs/ README.md
exclude: vendor/ node_modules/ .venv*/ .claude/ .git/ .next/ coverage/ .terraform/ .pytest_cache/
code: Sources/ Marcrypt/ Tests/ scripts/
-->

Read this file first. Each line: `path` — one-sentence scope. anchors: heading-slugs. covers: code globs.

## (root)
- `README.md` — Public front door: what Marcrypt is, its feature set and security model, install instructions, and how to build and run the app, CLI, and tests from source. anchors: why-marcrypt, features, security-model, requirements, install, build-from-source, command-line-usage, privacy covers: Sources/MarcryptCore/**, Sources/MarcryptCLI/**, Marcrypt/Marcrypt/**

## docs/
- `docs/APP_STORE_BUILD_GUIDE.md` — Why direct distribution and App Store submission are separate paths, plus the export-compliance and public-repository-hygiene rules that apply to each. anchors: public-repository-hygiene, direct-distribution, app-store-submission, export-compliance covers: scripts/submit_appstore.sh, scripts/build_appstore_release.sh
- `docs/BUILD_SETUP.md` — Setup and usage of the automated direct-distribution build: required signing configuration, how to run the scripts, expected output, and troubleshooting. anchors: overview, current-project-configuration, required-setup-steps, usage, output, troubleshooting, next-steps-for-distribution, files-modifiedcreated covers: scripts/build_direct_release.sh, scripts/build_appstore_release.sh, scripts/bundle_app.sh, scripts/increment_version.sh
- `docs/CONTEXT.md` — Glossary of Marcrypt's domain vocabulary: the encryption, watermarking, Bates, and shredding terms used consistently across code and docs.
- `docs/PRD_Features_Draft.md` — Superseded early feature draft derived from codebase analysis; kept for provenance behind PRODUCT_REQUIREMENTS.md. anchors: 1-product-overview, 2-core-functional-features, 3-user-interface-uiux
- `docs/PRODUCT_REQUIREMENTS.md` — Authoritative product requirements: goals, core features, UI requirements, technical constraints, and workflow logic for the shipped 1.0. anchors: 1-executive-summary, 2-product-goals, 3-core-features, 4-user-interface-ui-requirements, 5-technical-requirements, 6-workflow-logic, 7-future-scope
- `docs/RELEASE_NOTES_v1.0.0-beta.md` — User-facing release notes for the 1.0 public beta: highlights, install steps, and known limitations. anchors: highlights, install, known-limitations-beta, feedback
- `docs/backlog.md` — Short running list of confirmed follow-ups across test, project, and repo hygiene. anchors: confirmed, test-hygiene, project-hygiene
- `docs/cli_harness_test_matrix.md` — Scenario coverage, expected behavior, and timeout policy for the CLI harness that exercises MarcryptCLI end to end. anchors: command, harness-behavior, scenario-coverage, known-expected-behavior, timeout-policy covers: Tests/CLIHarness/**, Sources/MarcryptCLI/**
- `docs/core_e2e_testing.md` — How to validate core encryption, watermark, Bates, and archive behavior headlessly via the CoreE2EHarness executable. anchors: command, coverage, bug-loop, current-baseline covers: Tests/CoreE2EHarness/**, Sources/MarcryptCore/**
- `docs/worktree_integration_review.md` — Historical review of parallel worktree branches: validation evidence, recommended integration order, and per-file disposition. anchors: summary, validation-evidence, recommended-integration-order, file-disposition, integration-notes

## docs/adr/
- `docs/adr/0000-template.md` — Blank architecture-decision-record template to copy for new decisions. anchors: status, context, decision, consequences, date

## docs/backlog/
- `docs/backlog/public-beta-audit-remediation-2026-05-13.md` — Stacked remediation plan from the 2026-05-13 audit, covering data hygiene, temp/CLI privacy, correctness, scale, and release readiness. anchors: stack-01-backlog-and-data-hygiene, stack-02-confidential-temp-audit-and-cli-privacy, stack-03-state-cancellation-and-correctness, stack-04-scale-and-progress, stack-05-release-readiness, review-and-validation-policy
- `docs/backlog/public-beta-launch-audit-2026-06-10.md` — Full 2026-06-10 launch audit: blocker summary, repository hygiene, security and correctness findings, and ready-to-paste README and release-note copy. anchors: 0-launch-blocker-summary-do-these-first, section-a--pre-publication-repository-hygiene-p0, section-b--security--correctness-findings, section-c--in-app-help-system-mirror-the-marcut-pattern, section-d--about-screen-revamp-mirror-the-marcut-pattern, section-e--repo-readmemd-ready-to-paste, section-f--github-v10-release-notes-ready-to-paste, section-g--code-quality-correctness--nothing-embarrassing-pass
- `docs/backlog/public-beta-remediation-plan.md` — Severity-ranked remediation plan for the public beta, with the workflow and validation rules that govern it. anchors: critical, high, medium, low, workflow, validation
- `docs/backlog/public-beta-security-audit.md` — Security audit findings for the public beta, ranked by severity, plus the operational-readiness baseline. anchors: critical, high, medium, operational-readiness, current-baseline
- `docs/backlog/remediate-review-findings.md` — Five specific review tickets with acceptance criteria, covering archive extraction, clear-history, secure deletion, and notarization skips. anchors: ticket-1-archive-extraction-must-not-delete-caller-owned-directories, ticket-2-clear-history-must-not-interrupt-active-processing, ticket-3-secure-deletion-must-recurse-into-package-directories, ticket-4-skip-notarization-builds-must-skip-notarization-validation, ticket-5-clear-history-must-avoid-ui-hangs
- `docs/backlog/testing-gap-closure.md` — The six-gate testing strategy, from fast local checks through signed-app smoke, Xcode UI, and release dry run, with operating rules. anchors: current-gaps, gate-1-fast-local, gate-2-artifact-acceptance, gate-3-configuration-and-compliance, gate-4-signed-app-smoke, gate-5-xcode-ui, gate-6-release-dry-run, operating-rules covers: scripts/test_all.sh, scripts/release_readiness_gate.sh, Tests/**

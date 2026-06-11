# Core End-to-End Testing

Use the `CoreE2EHarness` SwiftPM executable when validating core Marcrypt behavior without the macOS UI or external sample files.

## Command

```bash
swift run CoreE2EHarness
```

Keep generated sample files for inspection:

```bash
swift run CoreE2EHarness --keep
```

Use a fixed working directory:

```bash
swift run CoreE2EHarness --workdir /tmp/marcrypt-core-e2e --keep
```

## Coverage

The harness generates fresh fixtures and validates:

- Preflight validation against generated inputs and destination.
- PDF metadata stripping, watermarking, Bates numbering, password encryption, wrong-password rejection, correct-password unlock, and SHA-256 sidecar generation.
- DOCX metadata stripping, mark-as-final/editing restriction, watermark header injection, Bates field injection, Office-style OLE encryption, wrong-password rejection, and decrypt byte-for-byte round trip.
- ZIP password-protected archive creation, wrong-password rejection, extraction, recursive content comparison, and password guessing from a candidate list.
- Batch HTML report generation.

## Bug Loop

For core-service bugs, use this loop:

1. Run `swift run CoreE2EHarness --keep`.
2. Inspect the generated workdir printed by the harness if a check fails.
3. Fix the core service or harness expectation.
4. Re-run `swift run CoreE2EHarness --keep`.
5. Run `swift test` before committing.

The harness exits non-zero on any failed section and prints a pass/fail summary. Each section runs independently so one failure does not hide later failures.

## Current Baseline

As of 2026-05-12, `swift run CoreE2EHarness`, `swift test`, `swift build --product Marcrypt`, and the Xcode `Marcrypt` Debug build all pass.

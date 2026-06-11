# CLI Harness Test Matrix

Last updated: 2026-05-12

`CLIHarness` is the subprocess-level acceptance harness for `MarcryptCLI`. It assumes `swift build --product MarcryptCLI` has already produced `.build/debug/MarcryptCLI`, then runs the CLI as a child process with isolated `HOME`, `TMPDIR`, and `MARCRYPT_TEMP_ROOT` values so destructive cleanup and history actions do not touch user data.

## Command

```bash
swift build --product MarcryptCLI
swift run CoreE2EHarness --keep
swift run CLIHarness --keep
swift test
```

For the default public-beta validation gate, prefer:

```bash
scripts/test_all.sh
```

`scripts/test_all.sh` also validates the SwiftPM skip allowlist and release-path
guard invariants before it runs the harnesses.

Use a fixed workdir when preserving artifacts for debugging:

```bash
swift run CLIHarness --workdir /tmp/marcrypt-cli-harness --keep
```

Set `MARCRYPT_CLI_PATH=/path/to/MarcryptCLI` to test a specific binary.

## Harness Behavior

- Runs the real CLI binary through `Process`; command implementations are not called directly.
- Captures stdout, stderr, exit status, command label, and timeout state.
- Kills any child process that exceeds the per-command timeout.
- Generates fresh PDF, DOCX, folder, corrupt archive, collision, and permission fixtures.
- Verifies output artifacts using PDFKit, direct byte checks, SHA-256 hashes, recursive directory comparison, and DOCX ZIP/XML inspection.
- Cleans generated artifacts unless `--keep` is supplied.

## Scenario Coverage

| Area | Scenarios | Expected result |
| --- | --- | --- |
| Shell behavior | Top-level help, every subcommand help page, unknown command, missing required args, unexpected flags, invalid integer values | Help exits 0; malformed invocations exit non-zero with parser errors |
| Password handling | `--password-stdin`, piped interactive fallback, empty stdin rejection, spaces/unicode/long password, output leakage check | Valid passwords succeed; empty password fails; secret text is not echoed |
| `encrypt` PDF | Generated PDF to encrypted PDF | Exit 0; output exists; hash differs; PDF is locked, rejects wrong password, unlocks with correct password |
| `encrypt` DOCX | Generated DOCX to encrypted DOCX | Exit 0; output exists; OLE compound file magic is present; hash differs |
| `encrypt` ZIP | Folder to password ZIP | Exit 0; output exists; source remains unless `--remove-originals` is used |
| `encrypt` failures | Missing input, file passed as folder archive input, invalid output parent | Exit non-zero; no usable output; source survives failure |
| `encrypt` collisions | Existing output default, `--keep-both`, `--replace`, conflicting flags, replacing directory with file | Default/conflict/directory replacement fail; keep-both creates numbered output; replace overwrites file |
| `encrypt --remove-originals` | Success and failure paths | Success removes source after output exists; failure preserves source |
| `decrypt` ZIP | Correct password, wrong password, corrupt archive | Correct password extracts matching tree; wrong/corrupt fail and do not leave destination |
| `decrypt` DOCX | Correct password, wrong password, unencrypted DOCX | Correct password round-trips bytes; wrong/invalid fail with no output |
| `decrypt` unsupported | PDF decrypt, unsupported extension | Exit non-zero with current explicit unsupported messaging |
| `decrypt` collisions | Existing file default, `--keep-both`, `--replace`, ZIP empty dir replace, ZIP non-empty dir refusal, conflicting flags | Matches CLI collision policy and preserves non-empty destinations |
| `watermark` PDF/DOCX | Default options and boundary options | Exit 0; PDF text/annotations or DOCX XML contain watermark text |
| `watermark` failures | Invalid size, opacity, location, color, unsupported extension, collisions, conflicting flags | Exit non-zero; no accepted invalid options |
| `bates` PDF/DOCX | Default options, digit/font/location/color options, timestamp flag | Exit 0; PDF text/annotations or DOCX XML contain expected zero-padded stamps |
| `bates` failures | Invalid start number, digit count, location, font family, font size, color, unsupported extension, collisions, conflicting flags | Exit non-zero; no accepted invalid options |
| `preflight` | Single file, multiple files, folder sizing, missing input, no inputs, missing destination, unreadable input when supported, unwritable destination when supported | Valid inputs pass and print sizing/permission lines; invalid inputs fail |
| `clear-history` | Isolated history cleanup, idempotency, isolated partial failure | Cleanup removes isolated log/audit/temp targets; repeated cleanup succeeds; forced cleanup failure exits non-zero |

## Known Expected Behavior

- PDF decryption is currently expected to fail through the CLI with the explicit unsupported message.
- Permission-denied preflight cases are skipped by the harness if the local filesystem still reports the test path as readable or writable after permission changes.
- `clear-history` failure simulation uses an immutable file inside the harness `HOME`; artifacts are isolated and restored after the scenario.

## Timeout Policy

The default per-command timeout is 20 seconds. This is intentionally longer than the normal local runtime for individual scenarios but short enough to catch stuck prompts or process hangs. A timeout is recorded as a scenario failure and the harness continues to the next scenario.

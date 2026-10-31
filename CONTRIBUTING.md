# Contributing

Fixes and improvements are welcome. The scripts are small on purpose, so most
of this page is about the checks a change must pass and the promises the
scaffolds make to their users.

## What you need

- bash 3.2 or newer. The scripts must keep running on macOS stock bash; CI
  puts `/bin/bash` first on PATH on the macOS runner to prove it.
- git 2.28+, python3 3.12+ with the `venv` module, terraform or OpenTofu
  (`TF_BIN=tofu`), shellcheck and shfmt.
- Network access to PyPI, Ansible Galaxy and the Terraform registry for the
  full test run.

## Checks

```bash
shellcheck ./*.sh
shfmt -d ./*.sh
./test.sh
```

`test.sh` starts with those two static checks and then runs both scaffolds end
to end in a temporary directory with a temporary `HOME`: online and with `-o`
behind closed proxy ports, the refusals (non-empty directory, two paths, the
home directory, a world-writable directory, a loose vault key, a changed
collection manifest, an interpreter below the floor), `-f` keeping files and
pins, the vault round-trip and plaintext guard, and `clean.sh` removing only
what a scaffold run rebuilds. It takes a few minutes and downloads the locked
packages; pip's cache is `~/.cache/pip` unless `PIP_CACHE_DIR` is set.

CI (`.github/workflows/ci.yml`) runs `./test.sh` on `ubuntu-latest` and
`macos-latest` with Python 3.13 and the current Terraform, on pull requests
and on pushes to `main`.

## Style

- shfmt's defaults: tabs, as in the existing files and `.editorconfig`. Run
  `shfmt -w ./*.sh` before committing if your editor does not apply it.
- `set -euo pipefail` at the top, `die` for errors, `put` for every generated
  file so that `-f` can never overwrite one. Comments explain intent that the
  code does not show, in the voice of the existing ones.
- No bash 4 features (associative arrays, `mapfile`, `${var,,}`); bash 3.2
  has to run it.

## Promises the scaffolds make

A change that touches one of these needs a check in `test.sh` that fails
without the change:

- Nothing is overwritten, restructured or adopted; `-f` adds what is missing
  and reports `keep <file>` for the rest.
- One new directory is created, never a path; the home directory and
  world-writable directories are refused.
- Python packages install only from a hash-locked `requirements.txt` resolved
  under the release cooldown; collections are chosen under the same cutoff and
  checked against `collections/lock.sha256`; `pip-audit` runs before any
  installed tool does.
- Nothing the scaffold runs writes a secret to disk; vault keys stay in
  `~/.ansible/vault/` and are refused when group- or world-readable.
- `clean.sh` removes only what a scaffold run rebuilds; keys, state and
  project files are never touched, lockfiles only with `-l`.
- Both scaffolds stop after `git init`; the first commit belongs to the user.

When a flag or variable changes, update the usage text in the script and the
README's flag list; both are written for the same reader.

## Pull requests

- Branch from `main`, one topic per pull request.
- Commit subjects are imperative and say what changed; use the body for why.
  There is no prefix convention.
- Say which OS and bash version you ran `./test.sh` on. CI must be green on
  both runners.
- There are no releases; `main` is what people copy or clone. The maintainer
  reviews and merges. Security problems go through
  [SECURITY.md](SECURITY.md).

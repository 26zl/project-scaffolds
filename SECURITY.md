# Security policy

The scaffolds exist to make a new Ansible or Terraform project safer than a
hand-made one: hash-locked dependencies under a release cooldown, verified
collections, vault keys that never enter the repository, and scripts that
refuse to overwrite, adopt or delete what they did not create. A bug in one of
those promises is a security issue here, and a private report is appreciated.

## What to report

- A way to make `init-ansible.sh` or `init-terraform.sh` overwrite or adopt an
  existing file, create more than one new directory, run in the home directory
  or in a world-writable one, or accept with `-f` a layout it should refuse.
- A gap in the locking: a package installed without a matching hash, a release
  newer than the cooldown accepted, a collection whose manifest changed but
  still installs, or `pip-audit` skipped before an installed project tool runs.
- `bin/vault-check.sh` passing a plaintext vault file inside its stated scope
  (`*vault*.yml`, `.yaml` and `.json`, on disk or staged), or a scaffold writing
  a secret to disk: a fact cache, a navigator artifact, a key outside
  `~/.ansible/vault/`, or a key readable by group or world.
- `clean.sh` removing something it promises to keep (project files, vault keys,
  Terraform state, lockfiles without `-l`) or reaching outside the project and
  the named cache roots.
- A secret committed to this repository.

Vulnerabilities in pip, ansible-core, Terraform, OpenTofu, providers or the
packages a lock resolves belong to those projects. `pip-audit` runs on every
lock; to relock, run `clean.sh -l` and then the scaffold with `-f`.

## How to report

Use GitHub private vulnerability reporting:
[open a draft security advisory](https://github.com/26zl/project-scaffolds/security/advisories/new).
Do not open a public issue for something exploitable. Ordinary bugs go in a
normal [issue](https://github.com/26zl/project-scaffolds/issues).

Include the operating system, the bash, python3 and terraform versions, the
exact command and flags, and the output. Use throwaway directories and
synthetic data; never include a real vault key, a lockfile from a private
project or Terraform state.

## Supported versions

There are no releases. `main` is the supported version; the scripts are
self-contained, so updating is a `git pull` or a fresh copy of the script.

## What to expect

One person maintains this repository, so there is no guaranteed response time;
reports are read and answered as soon as possible. A confirmed problem is fixed
on `main` with a check in `test.sh`, and the advisory is published afterwards,
crediting you if you want that.

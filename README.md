# project-scaffolds

Scaffolds for Ansible and Terraform projects. Each script builds the layout,
locks the tooling and proves the result by running it. The Ansible environment
bootstraps from `python3 -m venv` and pip; the Terraform scaffold uses the
Terraform or OpenTofu binary already installed on the machine.

```bash
./init-ansible.sh   ~/projects/my-infra   # venv, hash-locked deps, dev/prod inventories
./init-terraform.sh ~/projects/my-stack   # root module, per-env tfvars, init/validate
./clean.sh          ~/projects/my-infra   # remove what -f rebuilds: venv, collections, caches
./test.sh                                 # self-check, needs network
```

Every flag and variable:

```bash
./init-ansible.sh   ~/infra                 # ansible-core, ansible-lint, ansible-navigator
./init-ansible.sh   ~/infra -d              # ansible-dev-tools instead (first run only)
./init-ansible.sh   ~/infra -f              # add what is missing, keep everything else
./init-ansible.sh   -f                      # no path: the directory you are in
./init-ansible.sh   -h                      # full option list
PYTHON_VERSION=3.13 ./init-ansible.sh -d -f ~/infra
COOLDOWN_DAYS=0     ./init-ansible.sh ~/infra   # lock without the release cooldown, for a fix that cannot wait
./init-terraform.sh ~/stack -f
TF_BIN=tofu ./init-terraform.sh ~/stack     # run OpenTofu for this run only; generated docs assume Terraform
./clean.sh -n ~/infra                       # name what would go; -l also removes locks, -c shared caches
```

## Existing projects

Pointed at a non-empty directory, both scripts refuse and name what they found;
hidden files count. A path whose parent does not exist is refused too - one new
directory is made, not a whole new path. With `-f` they add only what is missing, reported as
`keep <file>`, and never overwrite, restructure or adopt a layout - delete a
file to have it regenerated. `-f` on a fresh clone of a scaffolded project is
the onboarding step, and it runs that clone's `ansible.cfg`, playbook and lint
on your machine. Terraform `-f` runs `init`, `validate` and `plan`, which can
download and execute provider code. Use either scaffold only on repositories
you trust. Flags work before or after the path, and the path defaults to the
current directory, so a copy of either script runs on the project it sits in.
Both run `git init` and stop there - the first commit is yours.

First-run choices stay: `-d` on a project locked to another package set is
refused (delete `requirements.in` and `requirements.txt` to switch), an
existing `.venv` keeps its Python (delete `.venv` to rebuild on another), and a
`requirements.txt` locked under a different Python or on another
OS/architecture is refused too. `-f` on an Ansible project needs an
`ansible.cfg` whose `vault_identity_list` names matching dev and prod keys
directly under `~/.ansible/vault`; another vault layout is refused rather than
adopted, so scaffold a foreign project into a new directory instead. Terraform
settings a module may hold only once - `required_providers` and the backend -
are matched on content rather than file name, so a project that keeps them in
`providers.tf` still initialises; two copies already on disk are named and the
run stops.

`clean.sh` removes what a scaffold run rebuilds - `.venv`, installed
collections, `.terraform`, tool caches, navigator artifacts, logs, plans and
`__pycache__` - and nothing the project cannot get back. `-l` also removes the
lock records. `-c` clears the pip and ansible-lint caches shared with every
other project, so it is a separate ask, and it reaches only directories below
`~/.cache` or `~/Library/Caches`. Vault keys and Terraform state are never
removed - a key may be shared by other clones, and local state is the only
record of what exists.

## Supply chain

pip resolves the Python lock itself under a release cooldown (pip 26's
`--uploaded-prior-to`): nothing uploaded in the last `COOLDOWN_DAYS` (default
7) is considered, because a hijacked release is usually pulled within days. A
relock first installs a hash-pinned pip, since the venv's bundled one may be
older. The lock is wheels only, so no source distribution runs a build step on
your machine, and it carries every eligible wheel hash the index lists per
pinned version. Resolution is still platform-specific: a lock created on one
OS/architecture is not guaranteed to install on another. `pip-audit` runs after
installation and before any installed project tool is executed. Direct
collections are picked from Galaxy's release dates under the same cooldown, and
every version Galaxy resolves as a dependency is held to the cutoff too, before
any collection code runs. The installed manifests are recorded in
`collections/lock.sha256`; a later install that receives different content for
the same versions is refused. Behind a mirror, check that it passes upload
times through.

Nothing the scaffold runs writes secrets to disk: no fact cache, no navigator
replay artifacts. Vault keys live in `~/.ansible/vault/`, never in the repo; a
group- or world-readable key is refused, and only the dev key is generated -
the prod key is made once by whoever operates prod. `bin/vault-check.sh`
refuses plaintext vault files (`*vault*.yml`, `.yaml` and `.json` only; it is
not a secret scanner). No CI is generated.

## Requirements

bash 3.2+ (macOS stock bash is enough; on Windows use WSL and keep the project
on the Linux filesystem - `/mnt/c` looks world-writable, ansible would ignore
its `ansible.cfg`, and the scaffold refuses it), git 2.28+, python3 3.12+ with
the venv module and a trusted CA bundle (checked before the downloads),
terraform or OpenTofu, and shellcheck for `test.sh`. Network access to PyPI,
Ansible Galaxy and the Terraform registry. The generated `.vscode/` files
assume [vscode_config](https://github.com/26zl/vscode_config).

MIT.

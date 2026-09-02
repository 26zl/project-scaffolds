#!/usr/bin/env bash
# Scaffold a Terraform root module: standard layout, per-env tfvars, init + validate.
set -euo pipefail

TF_BIN="${TF_BIN:-terraform}"

die() {
	printf 'init-terraform: %s\n' "$*" >&2
	exit 1
}

# Write stdin to $1 unless it exists, so -f can never overwrite user files.
put() {
	if [ -e "$1" ] || [ -L "$1" ]; then
		printf 'keep %s\n' "$1"
		cat >/dev/null
	else
		cat >"$1"
	fi
}

STEPS=3
step_n=0
# Each header closes the previous phase with its duration, so a slow phase reads as progress rather than a hang.
step() {
	if [ -n "${step_start:-}" ]; then
		printf '    done in %ds\n' "$(($(date +%s) - step_start))"
	fi
	step_start=$(date +%s)
	step_n=$((step_n + 1))
	printf '\n==> [%d/%d] %s\n' "$step_n" "$STEPS" "$*"
}

usage() {
	cat <<'USAGE'
Usage: init-terraform.sh [-f] [<project-path>]

Creates versions.tf, backend.tf, main.tf, variables.tf, outputs.tf,
modules/, per-environment tfvars, .gitignore and an empty git repo (you make
the first commit), then runs init / validate / plan.

Options may come before or after the path, which defaults to the current
directory - copy this script into a project and run it there. An existing
project is not empty, so that needs -f.

  -f          allow a non-empty directory; existing files are kept,
              delete one to have it regenerated. Re-running an existing
              project with -f is the safe way to fill in what is missing.
              required_providers and the backend are matched on content,
              so a project that keeps them under other file names does
              not end up declaring either of them twice; two copies
              already on disk are named and the run stops
  TF_BIN=x    binary to run (default: terraform)

Needs network access for the provider download.

-f runs init, validate and plan against the existing Terraform configuration,
which may download and execute provider code. Use it only on repositories you
trust.
USAGE
}

force=0
# getopts stops at the first non-option argument, so the path is set aside and parsing continues past it.
args=()
while [ $# -gt 0 ]; do
	OPTIND=1
	while getopts ':fh' o; do
		case $o in
		f) force=1 ;;
		h)
			usage
			exit 0
			;;
		*)
			printf 'init-terraform: unknown option -%s\n\n' "$OPTARG" >&2
			usage >&2
			exit 2
			;;
		esac
	done
	shift $((OPTIND - 1))
	[ $# -eq 0 ] || {
		args+=("$1")
		shift
	}
done
set -- ${args[@]+"${args[@]}"}
# No path means this directory, so a copy of the script runs on the project it sits in.
[ $# -le 1 ] || {
	usage >&2
	exit 2
}
command -v "$TF_BIN" >/dev/null 2>&1 || die "$TF_BIN not found"
command -v git >/dev/null 2>&1 || die "git not found; Git 2.28 or newer is required"

project=${1:-.}
[ ! -e "$project" ] || [ -d "$project" ] || die "$project is a file, not a directory"
# ls -A counts dotfiles, so a lone .DS_Store trips this on a directory that looks empty; name what was found.
existing=$(ls -A "$project" 2>/dev/null || true)
if [ -n "$existing" ] && [ "$force" -eq 0 ]; then
	die "$project is not empty; it holds ${existing//$'\n'/ }; re-run with -f (before or after the path) to keep those files and add only what is missing"
fi

# One new directory is made, not a whole new path: ~/home/you/x is a typo for ~/x, and mkdir -p would
# build every missing level of it without a word.
if [ ! -d "$project" ]; then
	parent=$(dirname "$project")
	[ -d "$parent" ] || die "$parent does not exist, so $project would be a whole new path rather than one new directory; check the path - a pwd already starts at / and needs no ~/ in front - or create the parent first"
fi
mkdir -p "$project"
cd "$project"
root=$PWD
for path in modules envs .vscode .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup; do
	[ ! -L "$path" ] || die "$path is a symbolic link; refusing to write outside $root"
done
mkdir -p modules envs .vscode
[ -e modules/.gitkeep ] || [ -L modules/.gitkeep ] || : >modules/.gitkeep

# Name every root *.tf or *.tf.json that declares a setting a module may hold only once, whatever the file is called: $1 matches an HCL line at its start, $2 a JSON key anywhere.
# modules/ is left out: a child module carries its own required_providers.
declares() {
	local f found=1 pattern
	for f in ./*.tf ./*.tf.json; do
		[ -e "$f" ] || continue
		# Terraform merges an override file into the base, so what it declares is not a second copy.
		case $f in ./override.tf | ./*_override.tf | ./override.tf.json | ./*_override.tf.json) continue ;; esac
		case $f in *.json) pattern=$2 ;; *) pattern="^[[:space:]]*$1" ;; esac
		if grep -qE "$pattern" "$f"; then
			printf '%s\n' "${f#./}"
			found=0
		fi
	done
	return "$found"
}
version_hcl='required_version[[:space:]]*=' version_json='"required_version"[[:space:]]*:'
providers_hcl='required_providers[[:space:]]*(\{|=)' providers_json='"required_providers"[[:space:]]*:'
state_hcl='(backend[[:space:]]+"|cloud[[:space:]]*\{)' state_json='"(backend|cloud)"[[:space:]]*:[[:space:]]*\{'

# Two copies already on disk are init's error to raise, but it names one line and not the choice, so say where both are and stop here.
# required_version is exempt: Terraform combines those constraints wherever written.
once() {
	local files
	files=$(declares "$1" "$2") || return 0
	[ "$(printf '%s\n' "$files" | wc -l)" -eq 1 ] ||
		die "$3 is declared in ${files//$'\n'/ and }; a module may have only one, so delete the copy you do not want and re-run"
}
once "$providers_hcl" "$providers_json" required_providers
once "$state_hcl" "$state_json" 'a backend or cloud block'

# versions.tf is assembled from whichever settings are still missing, so a
# project that pins providers but no core version gets the half it lacks.
if [ -e versions.tf ] || [ -L versions.tf ]; then
	printf 'keep versions.tf\n'
else
	settings=()
	if owner=$(declares "$version_hcl" "$version_json"); then
		printf 'keep required_version in %s\n' "${owner%%$'\n'*}"
	else
		settings+=('  required_version = ">= 1.9"')
	fi
	if owner=$(declares "$providers_hcl" "$providers_json"); then
		printf 'keep required_providers in %s\n' "${owner%%$'\n'*}"
	else
		settings+=('  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }')
	fi
	if [ ${#settings[@]} -gt 0 ]; then
		{
			printf 'terraform {\n'
			sep=
			for s in ${settings[@]+"${settings[@]}"}; do
				printf '%s%s\n' "$sep" "$s"
				sep=$'\n'
			done
			printf '}\n'
		} >versions.tf
	fi
fi

# A cloud block is where state lives too, so it rules out a backend just as another backend does.
if [ -e backend.tf ] || [ -L backend.tf ]; then
	printf 'keep backend.tf\n'
elif owner=$(declares "$state_hcl" "$state_json"); then
	printf 'keep state configuration in %s\n' "${owner%%$'\n'*}"
else
	put backend.tf <<'TF'
# Local state suits one machine only; before sharing, move to a remote backend with locking via -backend-config.
terraform {
  backend "local" {}
}
TF
fi

put variables.tf <<'TF'
variable "environment" {
  description = "Deployment environment this root module manages."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}
TF

put main.tf <<'TF'
locals {
  tags = merge(var.tags, { environment = var.environment })
}

# Placeholder so init/validate/plan prove the chain; delete once real resources exist.
resource "random_pet" "placeholder" {
  length = 2
  prefix = var.environment
}
TF

put outputs.tf <<'TF'
output "placeholder_name" {
  description = "Proof the root module plans and applies."
  value       = random_pet.placeholder.id
}
TF

for e in dev stage prod; do
	put "envs/$e.tfvars" <<TF
environment = "$e"
tags = {
  owner = "change-me"
}
TF
done

put .gitignore <<'GIT'
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
crash.log
crash.*.log
.terraformrc
terraform.rc
override.tf
override.tf.json
*_override.tf
*_override.tf.json
# tfvars may hold secrets; only the tracked envs/ files are allowed in.
*.tfvars
*.tfvars.json
!envs/*.tfvars
# Finder and Windows Explorer drop these into any directory they open.
.DS_Store
Thumbs.db
desktop.ini
GIT

put .gitattributes <<'ATTR'
# Keep LF on every platform, so one clone works from macOS, Linux and Windows/WSL.
* text=auto eol=lf
ATTR

put .vscode/extensions.json <<'JSON'
{
  "recommendations": ["hashicorp.terraform"]
}
JSON

put README.md <<MD
# $(basename "$root")

\`\`\`bash
terraform init
terraform plan  -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
\`\`\`

One root module; environments differ only by \`-var-file\`. If they ever need
different resources, split into separate root directories instead of adding
conditionals. \`envs/*.tfvars\` are committed, so no secrets in them: a tfvars
file anywhere else is gitignored, and \`TF_VAR_<name>\` environment variables
work too. State can hold secrets as well, which is why it is never committed.

A var-file does not isolate state. The generated local/default state is for the
dev example only; before using stage or prod, give each environment a separate
root or an independently locked remote backend and state key.

Commit \`.terraform.lock.hcl\`. For mixed platforms, record each one once:
\`terraform providers lock -platform=linux_amd64 -platform=darwin_arm64\`.
MD

# init asks checkpoint.hashicorp.com whether a newer release exists; the scaffold has no use for the answer.
export CHECKPOINT_DISABLE=1
step "init ($("$TF_BIN" version | sed -n 1p))"
"$TF_BIN" init -input=false

step validate
"$TF_BIN" validate

if [ ! -d .git ]; then
	git init -q -b main
fi

step verify
# A kept project may hold files the scaffold never wrote, so an unformatted one is reported rather than fatal.
"$TF_BIN" fmt -check -recursive || printf 'fmt: run "%s fmt -recursive"\n' "$TF_BIN"
"$TF_BIN" plan -input=false -var-file=envs/dev.tfvars -no-color | tail -5
printf '    done in %ds\n\nOK: %s\n' "$(($(date +%s) - step_start))" "$root"

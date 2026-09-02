#!/usr/bin/env bash
# Self-check: both scaffolds build and verify, refuse non-empty dirs, keep files under -f, vault round-trips.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
repo=$PWD

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Keep the scaffold's vault keys out of the real home, but leave pip's cache in it so re-runs do not refetch.
home="$tmp/home"
mkdir -p "$home"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$HOME/.cache/pip}"
# Fixtures that stand in for the scaffold's venv must use the interpreter it would.
py="python${PYTHON_VERSION:-3}"

fail() {
	printf 'fail: %s\n' "$*" >&2
	exit 1
}

valid_json() {
	"$py" -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" || fail "$1 is not valid JSON"
}

# stat(1) spells the mode differently on BSD and GNU; python is already required here.
mode600() {
	"$py" -c 'import os,sys; sys.exit(os.stat(sys.argv[1]).st_mode & 0o777 != 0o600)' "$1" 2>/dev/null
}

# Fail with $3 unless $1 matches the glob $2.
# shellcheck disable=SC2053
expect() {
	[[ $1 == $2 ]] || fail "$3; got: $1"
}

command -v shellcheck >/dev/null 2>&1 || fail "shellcheck is not installed; it runs the static checks"
shellcheck ./*.sh
if command -v shfmt >/dev/null 2>&1; then
	shfmt -d ./*.sh
fi
echo "ok: static checks"

# No path means the caller's directory, which also exercises the empty args expansion under set -u.
mkdir -p "$tmp/here"
: >"$tmp/here/occupied"
for s in init-ansible.sh init-terraform.sh; do
	nopath=$(cd "$tmp/here" && { HOME=$home "$repo/$s" 2>&1 || true; })
	expect "$nopath" '*. is not empty*occupied*' "$s: no path did not default to the current directory"
	! "$repo/$s" "$tmp/one" "$tmp/two" >/dev/null 2>&1 || fail "$s accepted two paths"
	expect "$("$repo/$s" "$tmp/here/occupied" 2>&1 || true)" '*is a file, not a directory*' "$s: a file path was not refused"
	# ~/home/you/x is a typo for ~/x; mkdir -p would build the whole path silently.
	expect "$("$repo/$s" "$tmp/nosuch/deep" 2>&1 || true)" '*does not exist*' "$s: a path whose parent is missing was not refused"
	[ ! -e "$tmp/nosuch" ] || fail "$s: a path whose parent is missing was created anyway"
done
# A bogus interpreter stops the run at step 1 without network; the layout next to the caller proves -f scaffolded in place.
inplace=$(cd "$tmp/here" && { HOME=$home PYTHON_VERSION=-missing "$repo/init-ansible.sh" -f 2>&1 || true; })
expect "$inplace" '*1/6] virtualenv*' "ansible: -f with no path did not scaffold the current directory"
[ -d "$tmp/here/playbooks" ] || fail "ansible: -f with no path built the layout somewhere else"

mkdir -p "$tmp/linked-ansible" "$tmp/outside-roles"
ln -s "$tmp/outside-roles" "$tmp/linked-ansible/roles"
linked=$(HOME=$home PYTHON_VERSION=-missing ./init-ansible.sh -f "$tmp/linked-ansible" 2>&1 || true)
expect "$linked" '*roles is a symbolic link*' "ansible: a managed directory symlink was not refused"
[ ! -e "$tmp/outside-roles/.gitkeep" ] || fail "ansible: a managed directory symlink wrote outside the project"
echo "ok: no path means this directory, two paths rejected"

./init-terraform.sh "$tmp/tf" >/dev/null
! git -C "$tmp/tf" rev-parse --verify -q HEAD >/dev/null || fail "terraform: scaffold made a commit"
! git -C "$tmp/tf" check-ignore .terraform.lock.hcl envs/dev.tfvars >/dev/null || fail "terraform: lockfile or env tfvars is gitignored"
[ "$(git -C "$tmp/tf" check-ignore .terraform terraform.tfstate secret.tfvars | wc -l)" -eq 3 ] ||
	fail "terraform: state or stray tfvars not gitignored"
"${TF_BIN:-terraform}" fmt -check -recursive "$tmp/tf" >/dev/null ||
	fail "terraform: generated files are not canonically formatted"
valid_json "$tmp/tf/.vscode/extensions.json"
[ ! -e "$tmp/tf/.github" ] || fail "terraform: scaffold generated .github"
git -C "$tmp/tf" check-attr eol -- main.tf | grep -q 'eol: lf' ||
	fail "terraform: .gitattributes does not force LF"
echo "ok: terraform scaffold"

! ./init-terraform.sh "$tmp/tf" >/dev/null 2>&1 || fail "terraform: non-empty dir accepted without -f"
printf 'mine\n' >"$tmp/tf/README.md"
./init-terraform.sh -f "$tmp/tf" >/dev/null
# A flag written after the path must scaffold too.
./init-terraform.sh "$tmp/tf" -f >/dev/null
[ "$(cat "$tmp/tf/README.md")" = mine ] || fail "terraform: -f overwrote README.md"

rm "$tmp/tf/README.md"
ln -s "$tmp/outside-readme" "$tmp/tf/README.md"
./init-terraform.sh -f "$tmp/tf" >/dev/null
[ -L "$tmp/tf/README.md" ] || fail "terraform: -f replaced a dangling file symlink"
[ ! -e "$tmp/outside-readme" ] || fail "terraform: -f followed a dangling file symlink outside the project"
rm "$tmp/tf/README.md"
printf 'mine\n' >"$tmp/tf/README.md"

rm -rf "$tmp/tf/.vscode"
mkdir "$tmp/outside-vscode"
ln -s "$tmp/outside-vscode" "$tmp/tf/.vscode"
linked=$(./init-terraform.sh -f "$tmp/tf" 2>&1 || true)
expect "$linked" '*.vscode is a symbolic link*' "terraform: a managed directory symlink was not refused"
[ ! -e "$tmp/outside-vscode/extensions.json" ] || fail "terraform: a managed directory symlink wrote outside the project"
rm "$tmp/tf/.vscode"
mkdir "$tmp/tf/.vscode"
echo "ok: terraform -f keeps files, before or after the path"

# clean.sh takes only what a scaffold run rebuilds; lockfiles, state and project files stay unless asked for.
./clean.sh -n "$tmp/tf" | grep -qx 'would remove .terraform' || fail "clean: dry run did not name .terraform"
[ -d "$tmp/tf/.terraform" ] || fail "clean: dry run removed something"
: >"$tmp/tf/terraform.tfstate"
# A tool's own log is rebuilt by the next run; one the project keeps by hand is not, so a *.log glob would lose it.
: >"$tmp/tf/crash.log"
: >"$tmp/tf/deploy.log"
./clean.sh "$tmp/tf" >/dev/null
[ ! -e "$tmp/tf/.terraform" ] || fail "clean: .terraform was not removed"
[ ! -e "$tmp/tf/crash.log" ] || fail "clean: the terraform crash log was not removed"
for keep in .terraform.lock.hcl terraform.tfstate main.tf envs/dev.tfvars deploy.log .git; do
	[ -e "$tmp/tf/$keep" ] || fail "clean: removed $keep, which is not the scaffold's to remove"
done
./clean.sh -l "$tmp/tf" >/dev/null
[ ! -e "$tmp/tf/.terraform.lock.hcl" ] || fail "clean: -l kept the provider lock"
[ -e "$tmp/tf/terraform.tfstate" ] || fail "clean: -l removed state"
expect "$(./clean.sh "$tmp/tf")" 'nothing to clean*' "clean: a clean project was not reported as such"
echo "ok: clean removes only what is rebuilt"

# Terraform allows one required_providers and one backend per module whatever the file, so -f over a providers.tf must not add a second copy.
mkdir -p "$tmp/tfdup"
cat >"$tmp/tfdup/providers.tf" <<'TF'
terraform {
  required_version = ">= 1.9"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  backend "local" {}
}
TF
dup=$(./init-terraform.sh -f "$tmp/tfdup" 2>&1) || fail "terraform: -f over an existing providers.tf failed: $dup"
expect "$dup" '*keep required_providers in providers.tf*' "terraform: -f did not report the required_providers it found"
[ ! -e "$tmp/tfdup/versions.tf" ] || fail "terraform: -f added a second required_providers"
[ ! -e "$tmp/tfdup/backend.tf" ] || fail "terraform: -f added a second backend configuration"

# Only the missing half is written: providers pinned but no core version still gets one.
mkdir -p "$tmp/tfhalf"
cat >"$tmp/tfhalf/terraform.tf" <<'TF'
terraform {
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
TF
half=$(./init-terraform.sh -f "$tmp/tfhalf" 2>&1) || fail "terraform: -f over an existing terraform.tf failed: $half"
grep -q required_version "$tmp/tfhalf/versions.tf" || fail "terraform: -f did not add the missing required_version"
! grep -q required_providers "$tmp/tfhalf/versions.tf" || fail "terraform: -f added a second required_providers"
[ -e "$tmp/tfhalf/backend.tf" ] || fail "terraform: -f skipped a backend the project does not have"
"${TF_BIN:-terraform}" fmt -check "$tmp/tfhalf/versions.tf" >/dev/null ||
	fail "terraform: an assembled versions.tf is not canonically formatted"
echo "ok: terraform -f adds only the terraform settings a project lacks"

# Two copies already on disk have to be named and refused here, not left to init to complain about one line of.
mkdir -p "$tmp/tfboth"
cp "$tmp/tfhalf/terraform.tf" "$tmp/tfboth/providers.tf"
cp "$tmp/tfhalf/terraform.tf" "$tmp/tfboth/versions.tf"
both=$(./init-terraform.sh -f "$tmp/tfboth" 2>&1 || true)
expect "$both" '*required_providers is declared in providers.tf and versions.tf*' \
	"terraform: an existing duplicate required_providers was not named and refused"
./init-terraform.sh -f "$tmp/tfboth" >/dev/null 2>&1 && fail "terraform: a duplicate required_providers did not fail the run"
rm "$tmp/tfboth/versions.tf"
./init-terraform.sh -f "$tmp/tfboth" >/dev/null || fail "terraform: deleting the duplicate did not clear the refusal"

# Terraform reads *.tf.json too, so a JSON-declared block counts the same as an HCL one.
mkdir -p "$tmp/tfjson"
printf '{"terraform": {"required_providers": {"random": {"source": "hashicorp/random", "version": "~> 3.7"}}, "backend": {"local": {}}}}\n' >"$tmp/tfjson/providers.tf.json"
./init-terraform.sh -f "$tmp/tfjson" >/dev/null || fail "terraform: -f over a providers.tf.json failed"
[ ! -e "$tmp/tfjson/backend.tf" ] || fail "terraform: -f added a backend next to a JSON one"
! grep -q required_providers "$tmp/tfjson/versions.tf" || fail "terraform: -f added required_providers next to a JSON one"
# Terraform merges override files into the base, so theirs is not a second copy.
mkdir -p "$tmp/tfover"
cp "$tmp/tfhalf/terraform.tf" "$tmp/tfover/providers.tf"
cp "$tmp/tfhalf/terraform.tf" "$tmp/tfover/random_override.tf"
./init-terraform.sh -f "$tmp/tfover" >/dev/null || fail "terraform: an override file was mistaken for a duplicate"
echo "ok: terraform names an existing duplicate and ignores override files"

# A directory holding only a dotfile looks empty, so the guard has to name what it found.
mkdir -p "$tmp/hidden"
: >"$tmp/hidden/.DS_Store"
hidden_msg=$(./init-terraform.sh "$tmp/hidden" 2>&1 || true)
expect "$hidden_msg" '*.DS_Store*' "terraform: guard did not name the dotfile that tripped it"
echo "ok: guard names what it found"

ans_out=$(HOME=$home ./init-ansible.sh "$tmp/ans")
! git -C "$tmp/ans" rev-parse --verify -q HEAD >/dev/null || fail "ansible: scaffold made a commit"
[ "$(git -C "$tmp/ans" check-ignore .venv .vault_pass collections/ansible_collections playbooks/site-artifact-1.json .ansible | wc -l)" -eq 5 ] ||
	fail "ansible: venv, vault password, installed collections, navigator artifacts or ansible-lint's ANSIBLE_HOME not gitignored"
valid_json "$tmp/ans/.vscode/settings.json"
grep -q ansibleNavigator "$tmp/ans/.vscode/settings.json" || fail "ansible: navigator path missing from settings.json"
valid_json "$tmp/ans/.vscode/extensions.json"
! grep -q "$tmp" "$tmp/ans/.vscode/settings.json" "$tmp/ans/ansible.cfg" || fail "ansible: absolute path leaked into settings.json or ansible.cfg"
grep -q -- '--hash=sha256:' "$tmp/ans/requirements.txt" || fail "ansible: requirements.txt has no hashes"
"$tmp/ans/.venv/bin/python" -c 'import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' \
	"$tmp/ans/playbooks/site.yml" "$tmp/ans/inventory/dev/hosts.yml" \
	"$tmp/ans/collections/requirements.yml" "$tmp/ans/.ansible-lint" "$tmp/ans/ansible-navigator.yml" ||
	fail "generated YAML is invalid"
installed=("$tmp/ans"/collections/ansible_collections/*/*/MANIFEST.json)
[ "$(wc -l <"$tmp/ans/collections/lock.sha256")" -eq "${#installed[@]}" ] || fail "ansible: collections/lock.sha256 does not cover every installed collection"
[ "$(grep -c 'version: "' "$tmp/ans/collections/requirements.yml")" -eq "${#installed[@]}" ] || fail "ansible: requirements.yml does not pin every installed collection, dependencies included"
[ ! -e "$tmp/ans/.github" ] || fail "ansible: scaffold generated .github"
git -C "$tmp/ans" check-attr eol -- bin/vault-check.sh | grep -q 'eol: lf' ||
	fail "ansible: .gitattributes does not force LF"
# Facts carry the whole environment of the shell, so nothing may cache them to disk: not ansible, not navigator's replay.
[ ! -e "$tmp/ans/.ansible_cache" ] || fail "ansible: the verify run cached facts to disk"
! grep -q fact_caching "$tmp/ans/ansible.cfg" || fail "ansible: generated ansible.cfg enables a fact cache"
grep -A1 'playbook-artifact' "$tmp/ans/ansible-navigator.yml" | grep -q 'enable: false' || fail "ansible: navigator replay artifacts are not disabled"
grep -q 'locked with Python' "$tmp/ans/requirements.txt" || fail "ansible: lockfile header does not record the Python it was locked with"
case ${COOLDOWN_DAYS:-7} in 0) want='no cooldown' ;; *) want='uploaded before' ;; esac
grep -q "$want" "$tmp/ans/requirements.txt" || fail "ansible: lockfile header does not record the cooldown the run was given"
# Galaxy has no cooldown, so the scaffold picks each collection's release itself and says which one and why.
expect "$ans_out" '*pinned ansible.posix [0-9]*' "ansible: ansible.posix was not pinned before install"
[ "${COOLDOWN_DAYS:-7}" -eq 0 ] || expect "$ans_out" '*pinned community.general *newest release before*' "ansible: collection pins did not honour the cooldown"
grep -q '^pip==' "$tmp/ans/requirements.txt" || fail "ansible: pip itself is not pinned in the lock"
# A Galaxy that does not answer must not read as a cooldown violation, or a timeout throws the pins away.
# The checker is lifted out of the script so both outcomes can be forced; the extraction fails loudly if it drifts.
"$py" - "$repo/init-ansible.sh" "$tmp/checker.py" <<'EXTRACT'
import re, sys
found = re.search(r"check_collection_cooldown\(\) \{.*?<<'PY'\n(.*?)\nPY\n", open(sys.argv[1]).read(), re.S)
if not found or "created_at" not in found.group(1):
    sys.exit("test.sh can no longer lift the cooldown checker out of init-ansible.sh")
open(sys.argv[2], "w").write(found.group(1) + "\n")
EXTRACT
rc=0
"$py" "$tmp/checker.py" 2000-01-01T00:00:00Z "${installed[0]}" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "ansible: a collection inside the cutoff must exit 2, got $rc"
rc=0
https_proxy=http://127.0.0.1:1 "$py" "$tmp/checker.py" 2000-01-01T00:00:00Z "${installed[0]}" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "ansible: an unreachable Galaxy must exit 1, got $rc - anything else reads as a cooldown violation"
echo "ok: ansible scaffold"

# Finder writes .DS_Store into any directory it opens, so an unignored one lands in the first commit.
for d in "$tmp/tf" "$tmp/ans"; do
	: >"$d/.DS_Store"
	git -C "$d" check-ignore -q .DS_Store || fail "$d: generated .gitignore does not ignore .DS_Store"
done
echo "ok: scaffolds ignore OS noise"

mode600 "$home/.ansible/vault/ans-dev" || fail "ansible: vault key dev missing or not mode 600"
# A prod key made on a developer machine looks real and encrypts what nobody in prod can read.
[ ! -e "$home/.ansible/vault/ans-prod" ] || fail "ansible: scaffold generated a prod key"
vault="$tmp/ans/inventory/dev/group_vars/all/vault.yml"
printf 'vault_check: round-trip\n' |
	HOME=$home ANSIBLE_CONFIG="$tmp/ans/ansible.cfg" "$tmp/ans/.venv/bin/ansible-vault" encrypt --encrypt-vault-id dev --output "$vault" 2>/dev/null
HOME=$home ANSIBLE_CONFIG="$tmp/ans/ansible.cfg" "$tmp/ans/.venv/bin/ansible" localhost -m debug -a var=vault_check 2>/dev/null |
	grep -q 'round-trip' || fail "ansible: vaulted variable did not decrypt with the dev key"
"$tmp/ans/bin/vault-check.sh" || fail "ansible: vault-check rejected an encrypted file"
printf 'plain: oops\n' >"$tmp/ans/inventory/prod/group_vars/all/vault.yml"
! "$tmp/ans/bin/vault-check.sh" 2>/dev/null || fail "ansible: vault-check accepted a plaintext vault file"
rm "$tmp/ans/inventory/prod/group_vars/all/vault.yml"
printf '{"plain": "oops"}\n' >"$tmp/ans/inventory/prod/group_vars/all/vault.json"
! "$tmp/ans/bin/vault-check.sh" 2>/dev/null || fail "ansible: vault-check accepted a non-YAML plaintext vault file"
rm "$tmp/ans/inventory/prod/group_vars/all/vault.json"
echo "ok: vault round-trip and plaintext guard"

# A shared key copied into place can arrive group-readable, and a re-run has to refuse it.
chmod 644 "$home/.ansible/vault/ans-dev"
loose=$(HOME=$home ./init-ansible.sh -f "$tmp/ans" 2>&1 || true)
expect "$loose" '*readable by group or others*' "ansible: a group-readable vault key was not refused"
chmod 600 "$home/.ansible/vault/ans-dev"
echo "ok: loose vault key refused"

# A manifest that differs from what the lock recorded has to stop the run.
manifest="$tmp/ans/collections/ansible_collections/ansible/posix/MANIFEST.json"
cp "$manifest" "$tmp/manifest.orig"
printf '\n' >>"$manifest"
tampered=$(HOME=$home ./init-ansible.sh -f "$tmp/ans" 2>&1 || true)
expect "$tampered" '*do not match collections/lock.sha256*' "ansible: a changed collection manifest was not refused"
cp "$tmp/manifest.orig" "$manifest"
echo "ok: collection lock refuses a changed manifest"

! ./init-ansible.sh "$tmp/ans" >/dev/null 2>&1 || fail "ansible: non-empty dir accepted without -f"
# Reaching step 1 at all proves -f after the path was parsed; the bogus interpreter stops it there without network.
mkdir -p "$tmp/order"
: >"$tmp/order/occupied"
past_guard=$(HOME=$home PYTHON_VERSION=-missing ./init-ansible.sh "$tmp/order" -f 2>&1 || true)
expect "$past_guard" '*1/6] virtualenv*' "ansible: -f after the path did not clear the non-empty guard"
echo "ok: ansible -f parsed after the path"

# A clone's ansible.cfg decides the key names, so one that points out of ~/.ansible/vault has to be refused before anything is written.
mkdir -p "$tmp/trav"
printf 'vault_identity_list = dev@~/.ansible/vault/../../evil-dev, prod@~/.ansible/vault/../../evil-prod\n' >"$tmp/trav/ansible.cfg"
trav=$(HOME=$home ./init-ansible.sh -f "$tmp/trav" 2>&1 || true)
expect "$trav" '*must name matching dev and prod keys*' "ansible: a vault key path outside ~/.ansible/vault was not refused"
[ ! -e "$home/evil-dev" ] || fail "ansible: a traversing key name was acted on"
[ ! -e "$tmp/trav/.venv" ] || fail "ansible: the traversing key name was refused only after the venv was built"
# A foreign ansible.cfg decides nothing about the scaffold's keys, so -f has to say so rather than adopt the project.
mkdir -p "$tmp/foreign"
printf '[defaults]\ninventory = inventory\n' >"$tmp/foreign/ansible.cfg"
foreign=$(HOME=$home ./init-ansible.sh -f "$tmp/foreign" 2>&1 || true)
expect "$foreign" '*has no vault_identity_list*' "ansible: an ansible.cfg without vault_identity_list was not refused"
printf '%s\n' '[defaults]' 'vault_identity_list = dev@~/.ansible/vault/a-dev, prod@~/.ansible/vault/a-prod' \
	'vault_identity_list = dev@~/.ansible/vault/b-dev, prod@~/.ansible/vault/b-prod' >"$tmp/foreign/ansible.cfg"
twice=$(HOME=$home ./init-ansible.sh -f "$tmp/foreign" 2>&1 || true)
expect "$twice" '*more than once*' "ansible: a duplicated vault_identity_list was not refused"
[ ! -e "$tmp/foreign/.venv" ] || fail "ansible: a foreign ansible.cfg was refused only after the venv was built"
bad_cooldown=$(COOLDOWN_DAYS=week ./init-ansible.sh "$tmp/cool" 2>&1 || true)
expect "$bad_cooldown" '*not a whole number of days*' "ansible: a non-numeric COOLDOWN_DAYS was not refused"
echo "ok: traversing key name and bad cooldown refused"

# Ansible ignores an ansible.cfg in a world-writable directory, so the scaffold has to refuse one.
mkdir -p "$tmp/wideopen"
chmod 777 "$tmp/wideopen"
wide=$(HOME=$home ./init-ansible.sh "$tmp/wideopen" 2>&1 || true)
expect "$wide" '*world-writable*' "ansible: a world-writable project directory was not refused"
echo "ok: world-writable project directory refused"

# -d on a project locked to another set must be refused; the refusal lands before the venv, so no network.
mkdir -p "$tmp/switch"
printf 'ansible-core\n' >"$tmp/switch/requirements.in"
switch_msg=$(HOME=$home ./init-ansible.sh "$tmp/switch" -d -f 2>&1 || true)
expect "$switch_msg" '*already locks ansible-core*' "ansible: -d on a project locked to ansible-core was not refused"
# A lock from before navigator joined the default set has to be told to relock, not rebuilt without it.
stale=$(HOME=$home ./init-ansible.sh "$tmp/switch" -f 2>&1 || true)
expect "$stale" '*before ansible-navigator*' "ansible: a lock without ansible-navigator was not refused"
# A relock over a requirements.in left by the previous lock tool would pin pip-tools into the project; it has to be refused.
mkdir -p "$tmp/pt"
printf 'ansible-core\nansible-navigator\npip-tools\n' >"$tmp/pt/requirements.in"
oldtool=$(HOME=$home ./init-ansible.sh -f "$tmp/pt" 2>&1 || true)
expect "$oldtool" '*still lists pip-tools*' "ansible: a relock over a pip-tools requirements.in was not refused"
# The documented -f re-run must still work on a project that was built with -d.
printf 'ansible-dev-tools\n' >"$tmp/switch/requirements.in"
kept=$(HOME=$home PYTHON_VERSION=-missing ./init-ansible.sh "$tmp/switch" -f 2>&1 || true)
expect "$kept" '*1/6] virtualenv*' "ansible: plain -f was refused on a dev-tools project"
echo "ok: -d and a pre-navigator lock refused, plain -f still re-runs"

# The stub prints a version and fails the floor check like a real too-old python, which must be refused.
mkdir -p "$tmp/bin" "$tmp/toolow"
printf '#!/bin/sh\necho 3.1.0\nexit 1\n' >"$tmp/bin/python0.1"
chmod +x "$tmp/bin/python0.1"
toolow=$(PATH="$tmp/bin:$PATH" HOME=$home PYTHON_VERSION=0.1 ./init-ansible.sh "$tmp/toolow" 2>&1 || true)
expect "$toolow" '*below the minimum ansible-core supports*' "ansible: an interpreter below the ansible-core floor was not refused"
# A python that trusts no CA bundle is refused at step 1, before the downloads that would fail on it.
mkdir -p "$tmp/noca"
noca=$(HOME=$home SSL_CERT_FILE=/nonexistent SSL_CERT_DIR=/nonexistent ./init-ansible.sh "$tmp/noca" 2>&1 || true)
expect "$noca" '*trusts no CA certificates*' "ansible: an interpreter without a CA bundle was not refused"
# A kept requirements.txt locked under another Python must be refused, not reinstalled.
mkdir -p "$tmp/relock"
"$py" -m venv "$tmp/relock/.venv" >/dev/null
printf '# This file is autogenerated by pip-compile with Python 1.0\n' >"$tmp/relock/requirements.txt"
relock=$(HOME=$home ./init-ansible.sh -f "$tmp/relock" 2>&1 || true)
expect "$relock" '*locked with Python 1.0*' "ansible: a lockfile from another Python was not refused"
# A wheel pinned for one platform is not always published for another, so a lock carries the platform it was made on.
mkdir -p "$tmp/replat"
"$py" -m venv "$tmp/replat/.venv" >/dev/null
printf '# init-ansible.sh, locked with Python %s on plan9-vax from packages uploaded before 2020-01-01T00:00:00Z\n' \
	"$("$py" -c 'import sys;print("%d.%d" % sys.version_info[:2])')" >"$tmp/replat/requirements.txt"
replat=$(HOME=$home ./init-ansible.sh -f "$tmp/replat" 2>&1 || true)
expect "$replat" '*locked on plan9-vax*' "ansible: a lockfile from another platform was not refused"
echo "ok: interpreter below the floor, no CA bundle and cross-Python lockfile refused"

# A moved .venv must be refused naming where it was built, whether its pip shebang is direct or a /bin/sh trampoline.
for src in movesrc 'move src'; do
	mkdir -p "$tmp/$src"
	"$py" -m venv "$tmp/$src/.venv" >/dev/null
	mv "$tmp/$src" "$tmp/moved"
	moved_msg=$(HOME=$home ./init-ansible.sh -f "$tmp/moved" 2>&1 || true)
	expect "$moved_msg" '*built at ?* and the project now lives*' "ansible: a moved .venv from '$src' was not refused naming where it was built"
	rm -rf "$tmp/moved"
done
echo "ok: moved .venv refused"

# PYTHON_VERSION against an existing .venv must be refused; the refusal lands at step 1 without network.
have=$("$tmp/ans/.venv/bin/python" -c 'import sys;print("%d.%d" % sys.version_info[:2])')
repin=$(HOME=$home PYTHON_VERSION=1.0 ./init-ansible.sh -f "$tmp/ans" 2>&1 || true)
expect "$repin" "*already runs Python $have*" "ansible: PYTHON_VERSION against an existing .venv was not refused"
echo "ok: PYTHON_VERSION refused against an existing .venv"

cp "$tmp/ans/requirements.txt" "$tmp/req.before"
printf 'mine\n' >"$tmp/ans/README.md"
# The version it already runs must be accepted, and the run has to close by saying how to enter the venv.
rerun=$(HOME=$home PYTHON_VERSION=$have ./init-ansible.sh -f "$tmp/ans")
expect "$rerun" '*source .venv/bin/activate*' "ansible: final output does not say how to enter the venv"
[ "$(cat "$tmp/ans/README.md")" = mine ] || fail "ansible: -f overwrote README.md"
cmp -s "$tmp/req.before" "$tmp/ans/requirements.txt" || fail "ansible: -f changed requirements.txt"
echo "ok: ansible -f keeps files and pins"

# A clone under another directory name must keep using the keys its ansible.cfg names, not generate its own.
mkdir -p "$tmp/renamed"
cp -R "$tmp/ans"/. "$tmp/renamed"/ && rm -rf "$tmp/renamed/.venv"
cloned=$(HOME=$home ./init-ansible.sh -f "$tmp/renamed" 2>&1)
expect "$cloned" "*keep $home/.ansible/vault/ans-dev*" "ansible: a renamed clone did not keep the keys ansible.cfg names"
[ ! -e "$home/.ansible/vault/renamed-dev" ] || fail "ansible: a renamed clone generated keys of its own"
echo "ok: renamed clone keeps the keys ansible.cfg names"

# Vault keys are never clean.sh's to remove, and -c reaches only directories below the user's cache roots.
! ./clean.sh -k "$tmp/ans" >/dev/null 2>&1 || fail "clean: -k was accepted, but keys are not clean's to remove"
! ./clean.sh -a "$tmp/ans" >/dev/null 2>&1 || fail "clean: -a was accepted"
mkdir -p "$home/.cache/pip-custom" "$home/.cache/pip" "$home/elsewhere"
unsafe=$(HOME=$home PIP_CACHE_DIR="$home" ./clean.sh -c -n "$tmp/ans" 2>&1 || true)
expect "$unsafe" '*not below ~/.cache*' "clean: -c accepted HOME as PIP_CACHE_DIR"
! HOME=$home PIP_CACHE_DIR="$home/elsewhere" ./clean.sh -c -n "$tmp/ans" >/dev/null 2>&1 ||
	fail "clean: a PIP_CACHE_DIR outside the cache roots was accepted"
[ -d "$home/elsewhere" ] || fail "clean: a refused -c removed the directory it refused"
[ -d "$tmp/ans/.venv" ] || fail "clean: a refused -c removed the venv"
HOME=$home PIP_CACHE_DIR="$home/.cache/pip-custom" ./clean.sh -c "$tmp/ans" >/dev/null
[ ! -e "$home/.cache/pip-custom" ] || fail "clean: -c kept the configured pip cache"
[ -d "$home/.cache/pip" ] || fail "clean: PIP_CACHE_DIR did not replace the default pip cache"
[ ! -e "$tmp/ans/.venv" ] || fail "clean: the venv survived"
[ ! -e "$tmp/ans/collections/ansible_collections" ] || fail "clean: the installed collections survived"
[ -e "$tmp/ans/requirements.txt" ] || fail "clean: removed requirements.txt without -l"
[ -e "$tmp/ans/collections/lock.sha256" ] || fail "clean: removed the collections lock without -l"
env -u PIP_CACHE_DIR HOME="$home" ./clean.sh -c "$tmp/ans" >/dev/null
[ ! -e "$home/.cache/pip" ] || fail "clean: -c kept the pip cache"
mode600 "$home/.ansible/vault/ans-dev" || fail "clean: the dev key is gone"
echo "ok: clean leaves vault keys alone and confines -c to the cache roots"

echo "all ok"

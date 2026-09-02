#!/usr/bin/env bash
# Scaffold an Ansible project: hash-locked virtualenv, verified collections, per-environment vault.
set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-}"
MIN_PYTHON=3.12 # ansible-core's own Requires-Python; bump it when a release raises that floor
# A hijacked release is usually pulled within days, so a new lock takes nothing uploaded more recently than this. 0 turns it off.
COOLDOWN_DAYS="${COOLDOWN_DAYS:-7}"
COLLECTIONS=(ansible.posix community.general)
PACKAGES=(ansible-core ansible-lint ansible-navigator)

die() {
	printf 'init-ansible: %s\n' "$*" >&2
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

# Print pip option $1 as pip install resolves it: the install section wins over global.
# pip prints values with %r, so they are single-quoted unless they hold a single quote.
pip_option() {
	local section value
	for section in install global; do
		# No head(1) in the pipeline: pipefail would report its SIGPIPE and lose the match.
		value=$(.venv/bin/pip config list 2>/dev/null | sed -En "s/^$section\.$1=['\"](.*)['\"]$/\1/p")
		[ -z "$value" ] || {
			printf '%s\n' "${value%%$'\n'*}"
			return 0
		}
	done
	return 1
}

# Print the newest release of collection $1 uploaded before $cutoff, or the newest of all when the cooldown is off; Galaxy pages the list.
galaxy_version() {
	.venv/bin/python - "$1" "$cutoff" <<'PY'
import json, sys, urllib.parse, urllib.request
ns, name = sys.argv[1].split(".")
cutoff = sys.argv[2]
url = "https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/index/%s/%s/versions/?limit=100" % (ns, name)
releases = []
while url:
    page = json.load(urllib.request.urlopen(url, timeout=30))
    releases += page["data"]
    url = page["links"]["next"] and urllib.parse.urljoin(url, page["links"]["next"])
def numeric(v):
    parts = v.split(".")
    return tuple(int(p) for p in parts) if all(p.isdigit() for p in parts) else None
ok = [r["version"] for r in releases if numeric(r["version"]) and (not cutoff or r["created_at"] < cutoff)]
if not ok:
    sys.exit("%s.%s has no release older than the cooldown" % (ns, name))
print(max(ok, key=numeric))
PY
}

# Refuse any resolved collection uploaded inside the cooldown, including dependencies chosen by Galaxy.
# Exit 2 means a release really is too new. Any other failure means Galaxy did not answer, which is not the
# same thing and must not be reported as one: the pins are still good, they just could not be checked.
check_collection_cooldown() {
	[ -z "$cutoff" ] || .venv/bin/python - "$cutoff" "$@" <<'PY'
import json, sys, urllib.parse, urllib.request
cutoff, manifests = sys.argv[1], sys.argv[2:]
for manifest in manifests:
    info = json.load(open(manifest))["collection_info"]
    namespace, name, version = info["namespace"], info["name"], info["version"]
    url = "https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/index/%s/%s/versions/?limit=100" % (namespace, name)
    release = None
    try:
        while url and release is None:
            page = json.load(urllib.request.urlopen(url, timeout=30))
            release = next((r for r in page["data"] if r["version"] == version), None)
            url = page["links"]["next"] and urllib.parse.urljoin(url, page["links"]["next"])
    except (OSError, ValueError) as err:
        sys.exit("galaxy.ansible.com did not answer for %s.%s %s: %s" % (namespace, name, version, err))
    if release is None:
        sys.exit("%s.%s %s is not listed by Galaxy" % (namespace, name, version))
    if release["created_at"] >= cutoff:
        print("%s.%s %s was uploaded inside the cooldown" % (namespace, name, version), file=sys.stderr)
        sys.exit(2)
PY
}

# Write lock $2 from pip's install report $1 with every eligible wheel hash the index lists for each pinned version; $3 is the header.
write_lock() {
	# The index URL can carry credentials, and argv is world-readable in /proc while the environment is not.
	LOCK_INDEX="${index:-https://pypi.org/simple}" .venv/bin/python - "$1" "$2" "$3" "$cutoff" <<'PY'
import json, os, re, sys, urllib.request
report, out, header, cutoff = sys.argv[1:5]
index = os.environ["LOCK_INDEX"]
rows = []
for item in json.load(open(report))["install"]:
    name = re.sub(r"[-_.]+", "-", item["metadata"]["name"]).lower()
    version = item["metadata"]["version"]
    request = urllib.request.Request("%s/%s/" % (index.rstrip("/"), name), headers={"Accept": "application/vnd.pypi.simple.v1+json"})
    files = json.load(urllib.request.urlopen(request, timeout=60))["files"]
    hashes = sorted({f["hashes"]["sha256"] for f in files
                     if f["filename"].endswith(".whl") and f["filename"].split("-")[1] == version
                     and not f.get("yanked") and (not cutoff or f.get("upload-time", "") < cutoff)})
    chosen = item["download_info"]["archive_info"]["hashes"]["sha256"]
    if chosen not in hashes:
        sys.exit("%s %s: the wheel pip chose is not among the files the configured index lists for that version" % (name, version))
    rows.append((name, version, hashes))
with open(out, "w") as fh:
    fh.write("# %s\n" % header)
    for name, version, hashes in sorted(rows):
        fh.write("%s==%s \\\n%s\n" % (name, version, " \\\n".join("    --hash=sha256:" + h for h in hashes)))
PY
}

# Print the version of interpreter $1; fail if it is older than MIN_PYTHON.
py_probe() {
	"$1" -c 'import sys;print("%d.%d.%d" % sys.version_info[:3]);sys.exit(sys.version_info[:2] < tuple(map(int, sys.argv[1].split("."))))' "$MIN_PYTHON"
}

STEPS=6
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
Usage: init-ansible.sh [-f] [-d] [<project-path>]

Creates .venv from a hash-locked requirements.txt, ansible.cfg, dev/prod
inventories with separate vault keys, playbooks/, roles/, pinned and
checksum-verified collections, lint config and an empty git repo (you make the
first commit), then lints and runs the playbook.
Only python3 (venv module) and pip are needed.

Options may come before or after the path, which defaults to the current
directory - copy this script into a project and run it there. An existing
project is not empty, so that needs -f.

  -f                 allow a non-empty directory; existing files are kept,
                     delete one to have it regenerated. Re-running an existing
                     project with -f is the safe way to fill in what is missing
  -d                 lock ansible-dev-tools (molecule, creator, builder and
                     more) instead of ansible-core + ansible-lint; navigator
                     is in both sets. First-run choice: -d on a project already
                     locked to another set is refused, delete requirements.in
                     and requirements.txt first
  PYTHON_VERSION=X   pin the interpreter a new venv is built with (default:
                     python3). An interpreter older than ansible-core
                     supports is refused rather than locked to an old core. An
                     existing .venv keeps the Python it was created with;
                     delete .venv to rebuild on another one
  COOLDOWN_DAYS=N    a new lock takes no package or collection uploaded in the
                     last N days (default: 7), since a hijacked release is
                     usually pulled within days; 0 turns that off, for a fix
                     that cannot wait

Needs network access to PyPI and Ansible Galaxy.

-f on a clone runs that clone's ansible.cfg, playbook and lint on this
machine, so use it only on a repository you trust.
USAGE
}

force=0
devtools=0
# getopts stops at the first non-option argument, so the path is set aside and parsing continues past it.
args=()
while [ $# -gt 0 ]; do
	OPTIND=1
	while getopts ':fdh' o; do
		case $o in
		f) force=1 ;;
		d)
			devtools=1
			PACKAGES=(ansible-dev-tools)
			;;
		h)
			usage
			exit 0
			;;
		*)
			printf 'init-ansible: unknown option -%s\n\n' "$OPTARG" >&2
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
case $COOLDOWN_DAYS in
'' | *[!0-9]*) die "COOLDOWN_DAYS=$COOLDOWN_DAYS is not a whole number of days" ;;
esac
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
# Ansible ignores an ansible.cfg in a world-writable directory, which is every path under /mnt/c on WSL.
[ -z "$(find . -maxdepth 0 -perm -0002)" ] ||
	die "$root is world-writable, so ansible would ignore its ansible.cfg and parse no inventory; on WSL keep the project on the Linux filesystem rather than under /mnt/c"

# put keeps an existing requirements.in, so without this a later -d is silently ignored.
if [ "$devtools" -eq 1 ] && [ -f requirements.in ] && ! grep -qx ansible-dev-tools requirements.in; then
	die "-d asks for ansible-dev-tools but requirements.in already locks $(head -1 requirements.in); delete requirements.in and requirements.txt to switch package set"
fi
# A lock from before navigator joined the default set would fail in verify; a dev-tools lock already carries it.
if [ "$devtools" -eq 0 ] && [ -f requirements.in ] && ! grep -qxE 'ansible-navigator|ansible-dev-tools' requirements.in; then
	die "requirements.in was locked before ansible-navigator became standard; delete requirements.in and requirements.txt to relock with it"
fi

if [ -e ansible.cfg ] || [ -L ansible.cfg ]; then
	[ -f ansible.cfg ] || die "ansible.cfg exists but is not a regular file"
	setting=$(sed -n '/^[[:space:]]*vault_identity_list[[:space:]]*=/p' ansible.cfg)
	case $setting in
	'') die "ansible.cfg has no vault_identity_list, so it does not name the per-environment keys this scaffold manages; -f fills in what is missing but does not adopt another vault layout - scaffold into a new directory instead" ;;
	*$'\n'*) die "ansible.cfg sets vault_identity_list more than once; keep the line this project uses and delete the rest" ;;
	esac
	# The two ids are read apart and compared in the shell: a \1 backreference is a GNU sed extension, and BSD sed takes its ERE from the system regex.
	dev_key=$(printf '%s\n' "$setting" | sed -E -n 's|^[[:space:]]*vault_identity_list[[:space:]]*=[[:space:]]*dev@~/\.ansible/vault/([A-Za-z0-9._-]+)-dev,.*$|\1|p')
	prod_key=$(printf '%s\n' "$setting" | sed -E -n 's|^.*,[[:space:]]*prod@~/\.ansible/vault/([A-Za-z0-9._-]+)-prod[[:space:]]*$|\1|p')
	if [ -z "$dev_key" ] || [ "$dev_key" != "$prod_key" ]; then
		die "ansible.cfg must name matching dev and prod keys directly under ~/.ansible/vault - vault_identity_list = dev@~/.ansible/vault/<name>-dev, prod@~/.ansible/vault/<name>-prod - before -f can use it"
	fi
	name=$dev_key
else
	name=$(basename "$root" | sed 's/[^A-Za-z0-9._-]/_/g')
fi

managed_dirs=(.venv .ansible inventory inventory/dev inventory/dev/group_vars inventory/dev/group_vars/all
	inventory/dev/host_vars inventory/prod inventory/prod/group_vars inventory/prod/group_vars/all
	inventory/prod/host_vars playbooks roles collections collections/ansible_collections bin .vscode)
for d in "${managed_dirs[@]}"; do
	[ ! -L "$d" ] || die "$d is a symbolic link; refusing to write outside $root"
done
mkdir -p inventory/dev/{group_vars/all,host_vars} inventory/prod/{group_vars/all,host_vars} \
	playbooks roles collections bin .vscode
for marker in roles/.gitkeep inventory/dev/host_vars/.gitkeep inventory/prod/host_vars/.gitkeep; do
	[ -e "$marker" ] || [ -L "$marker" ] || : >"$marker"
done

step virtualenv
export PIP_DISABLE_PIP_VERSION_CHECK=1
# The default 15s read timeout trips on slow or proxied links while fetching large wheels.
export PIP_TIMEOUT=60
# A venv is bound to the interpreter that built it, so PYTHON_VERSION cannot re-point an existing one.
if [ -d .venv ]; then
	have=$(.venv/bin/python -c 'import sys;print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) ||
		die ".venv exists but its python does not run; delete .venv and re-run to rebuild it"
	# bin/python is a symlink and survives a move; the console scripts' absolute shebangs do not.
	if ! .venv/bin/pip --version >/dev/null 2>&1; then
		# sed on a missing pip must not let set -e kill the script before die speaks
		shebang=$(sed -n '1s/^#!//p' .venv/bin/pip 2>/dev/null || true)
		case $shebang in
		"$root"/.venv/*) die ".venv has a pip that does not run; delete .venv and re-run to rebuild it" ;;
		?*)
			# A venv path with a space gets a /bin/sh trampoline, not a direct shebang.
			origin=${shebang%/bin/*}
			die ".venv was built at ${origin:-another path} and the project now lives at $root; a venv is not relocatable - delete .venv and re-run to rebuild it"
			;;
		*) die ".venv has no working pip; delete .venv and re-run to rebuild it" ;;
		esac
	fi
	printf 'keep .venv (Python %s)\n' "$have"
	case $PYTHON_VERSION in
	'' | "$have" | "${have%.*}" | "${have%%.*}") ;;
	*) die "PYTHON_VERSION=$PYTHON_VERSION but .venv already runs Python $have; a venv cannot be re-pointed, delete .venv to rebuild it" ;;
	esac
	py_probe .venv/bin/python >/dev/null ||
		printf 'warning: .venv runs Python %s, which is older than ansible-core supports; delete .venv and requirements.txt to relock on a newer one\n' "$have" >&2
else
	interp="python${PYTHON_VERSION:-3}"
	command -v "$interp" >/dev/null 2>&1 || die "$interp not found; install it or pick another with PYTHON_VERSION="
	# Too old an interpreter still builds a venv, and the resolver then locks the last ansible-core that supported it.
	pick=$(py_probe "$interp") ||
		die "Python $pick is below the minimum ansible-core supports, so a lock made on it would pin an older core than the rest of the toolchain; pick $MIN_PYTHON or newer with PYTHON_VERSION="
	"$interp" -m venv .venv
fi
# A venv from a Windows python has Scripts/, not bin/, and the CA probe below would blame the certificate store for it.
[ -x .venv/bin/python ] || die ".venv has no bin/python, so it was not built by a POSIX python; on Windows run this from WSL"
# A python without a CA bundle fails HTTPS minutes into the downloads; OpenSSL fills a hashed cert directory lazily, so the store count alone reads as empty on a capath-only system.
.venv/bin/python -c 'import os,ssl,sys; p=ssl.get_default_verify_paths(); sys.exit(not (p.cafile or (p.capath and os.listdir(p.capath)) or ssl.create_default_context().cert_store_stats()["x509_ca"]))' ||
	die "this python trusts no CA certificates, so HTTPS will fail; pick another with PYTHON_VERSION=, or set SSL_CERT_FILE to your CA bundle"
pyver=$(.venv/bin/python -c 'import sys;print("%d.%d" % sys.version_info[:2])')
lock_platform=$(.venv/bin/python -c 'import platform;print("%s-%s" % (platform.system().lower(), platform.machine().lower()))')
# Anything uploaded inside the cooldown is invisible to both resolvers, so a release hijacked this week cannot end up in a lock.
cutoff=
if [ "$COOLDOWN_DAYS" -gt 0 ]; then
	cutoff=$(.venv/bin/python -c 'import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=int(sys.argv[1]))).replace(microsecond=0).isoformat().replace("+00:00","Z"))' "$COOLDOWN_DAYS")
fi
step "dependencies (the first run resolves and hash-locks every package)"
# pip-audit is the engineer's audit tool and pip both resolves and installs the lock, so both are pinned in it.
printf '%s\n' "${PACKAGES[@]}" pip-audit pip | put requirements.in
if [ -e requirements.txt ] || [ -L requirements.txt ]; then
	[ -f requirements.txt ] || die "requirements.txt exists but is not a regular file"
	# A lock is specific to the Python that resolved it, since markers and available wheels differ.
	locked=$(sed -En 's/.*with Python ([0-9.]+).*/\1/p' requirements.txt | head -1)
	if [ -n "$locked" ] && [ "$locked" != "$pyver" ]; then
		die "requirements.txt was locked with Python $locked but .venv runs Python $pyver; delete requirements.txt to relock it, or rebuild .venv on Python $locked"
	fi
	locked_platform=$(sed -E -n 's/.* on ([^ ]+) (from|with) .*/\1/p' requirements.txt | head -1)
	if [ -n "$locked_platform" ] && [ "$locked_platform" != "$lock_platform" ]; then
		die "requirements.txt was locked on $locked_platform but this machine is $lock_platform, and a wheel pinned for one is not always published for the other; delete requirements.txt and re-run to relock here"
	fi
	if grep -q 'autogenerated by pip-compile' requirements.txt; then
		die "requirements.txt is a legacy pip-compile lock that may install source distributions; delete it and requirements.in to relock wheels-only under a cooldown"
	else
		printf 'keep requirements.txt\n'
	fi
else
	# put kept an old requirements.in; relocking it would pin pip-tools into the project and leave pip unpinned.
	if grep -qx pip-tools requirements.in; then
		die "requirements.in still lists pip-tools from the previous lock tool; delete it too, so the relock takes the current package set"
	fi
	# --uploaded-prior-to arrived in pip 26.0 and the venv's bundled pip may be older, so the lock is taken by a hash-pinned pip that obeys the cooldown itself. Bump it with
	#   python3 -c 'import json,datetime as dt,urllib.request; d=json.load(urllib.request.urlopen("https://pypi.org/pypi/pip/json")); cut=(dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"); ok={v:f for v,f in d["releases"].items() if f and v.replace(".","").isdigit() and max(x["upload_time_iso_8601"] for x in f)<cut}; v=max(ok,key=lambda v:tuple(map(int,v.split(".")))); print("pip=="+v, *sorted("    --hash=sha256:"+x["digests"]["sha256"] for x in ok[v] if x["packagetype"]=="bdist_wheel"), sep=" \\\n")'
	.venv/bin/pip install -q --require-hashes --only-binary=:all: -r /dev/stdin <<'BOOT'
pip==26.2.1 \
    --hash=sha256:71138adf1f4ca900cdb7d289c21b7494329f2332b6d85f0e1c42108c0384ed3e
BOOT
	# write_lock reads the index on its own, so it is handed pip's CA bundle and index; pip itself already knows both.
	cert=${PIP_CERT:-$(pip_option cert || true)}
	[ -z "$cert" ] || export SSL_CERT_FILE="${SSL_CERT_FILE:-$cert}"
	index=${PIP_INDEX_URL:-$(pip_option index-url || true)}
	if [ -n "$cutoff" ]; then
		cooldown=(--uploaded-prior-to "$cutoff")
		provenance="from packages uploaded before $cutoff"
	else
		cooldown=()
		provenance="with no cooldown"
	fi
	# Wheels only: an sdist runs its build backend during resolution and installation, before any hash exists to check it against.
	# The header records the Python and the cutoff, which is what a re-run checks and a reader wants to know.
	.venv/bin/pip install -q --dry-run --ignore-installed --only-binary=:all: ${cooldown[@]+"${cooldown[@]}"} \
		--report .venv/lock-report.json -r requirements.in
	write_lock .venv/lock-report.json requirements.txt "init-ansible.sh, locked with Python $pyver on $lock_platform $provenance"
	rm .venv/lock-report.json
fi
.venv/bin/pip install --require-hashes --only-binary=:all: -r requirements.txt
# Audit before any installed project tool is executed.
.venv/bin/pip-audit --strict --no-deps --timeout 60 --progress-spinner off -r requirements.txt ||
	die "pip-audit rejected requirements.txt; delete it and re-run to relock, with COOLDOWN_DAYS=0 if the fixed release is newer than the cooldown"
export PATH="$root/.venv/bin:$PATH"
export ANSIBLE_CONFIG="$root/ansible.cfg"

# Keys live outside the repo, and only the dev key is made here: a prod key generated on a developer machine looks real yet encrypts what prod cannot read.
step "vault keys"
vault_dir=~/.ansible/vault
[ ! -L "$vault_dir" ] || die "$vault_dir is a symbolic link; refusing to place vault keys through it"
(umask 077 && mkdir -p "$vault_dir")
chmod 700 "$vault_dir"
for id in dev prod; do
	key=$vault_dir/$name-$id
	if [ -e "$key" ] || [ -L "$key" ]; then
		[ -f "$key" ] || die "$key exists but is not a regular file"
		# umask protects only keys made here; a hand-copied shared key arrives with whatever mode it had.
		.venv/bin/python -c 'import os,sys; sys.exit((os.stat(sys.argv[1]).st_mode & 0o077) != 0)' "$key" ||
			die "$key is readable by group or others; chmod 600 it - a vault key is a password"
		printf 'keep %s\n' "$key"
	elif [ "$id" = dev ]; then
		(umask 077 && .venv/bin/python -c 'import secrets;print(secrets.token_urlsafe(32))' >"$key")
		printf 'generated %s - store it in the password manager; on a clone, replace it with the shared key\n' "$key"
	else
		printf 'missing %s - only whoever operates prod needs it; README under Vault says how it is made\n' "$key"
	fi
done

step "project files"

# Navigator defaults to a container image; the venv already holds everything, so no podman or docker is needed.
put ansible-navigator.yml <<'NAV'
---
ansible-navigator:
  execution-environment:
    enabled: false
  # A replay artifact holds the whole run, facts and the environment included; that stays off disk.
  playbook-artifact:
    enable: false
NAV

put ansible.cfg <<CFG
[defaults]
# Dev by default; production runs must pass -i inventory/prod explicitly.
inventory = inventory/dev
roles_path = roles
collections_path = collections
interpreter_python = auto_silent
host_key_checking = True
forks = 20
# No fact cache: facts include the environment of the shell, tokens and all, and a cache would write that to disk.
retry_files_enabled = False
display_skipped_hosts = False
callback_result_format = yaml
callbacks_enabled = ansible.posix.profile_tasks
vault_identity_list = dev@~/.ansible/vault/$name-dev, prod@~/.ansible/vault/$name-prod

[privilege_escalation]
become = False
become_method = sudo
become_ask_pass = False

[ssh_connection]
pipelining = True
ssh_args = -C -o ControlMaster=auto -o ControlPersist=60s -o PreferredAuthentications=publickey
CFG

put inventory/dev/hosts.yml <<'YML'
---
all:
  children:
    local:
      hosts:
        localhost:
          ansible_connection: local
YML

put inventory/prod/hosts.yml <<'YML'
---
all:
  children:
    web:
      hosts: {}
    db:
      hosts: {}
YML

put inventory/dev/group_vars/all/vars.yml <<'YML'
---
env_name: dev
YML

put inventory/prod/group_vars/all/vars.yml <<'YML'
---
env_name: prod
YML

put playbooks/site.yml <<'YML'
---
- name: Base configuration
  hosts: all
  gather_facts: true
  tasks:
    - name: Show what we are talking to
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }} ({{ env_name }}) runs {{ ansible_facts['distribution'] | default('unknown') }}"
YML

vault_check_new=0
[ -e bin/vault-check.sh ] || [ -L bin/vault-check.sh ] || vault_check_new=1
put bin/vault-check.sh <<'SH'
#!/usr/bin/env bash
# Fails if any vault file in the tree is plaintext, so it can never be committed that way.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v git >/dev/null 2>&1 || {
	printf 'vault-check: git is required\n' >&2
	exit 1
}
status=0
scan_complete=0
while IFS= read -r -d '' f; do
	if [ -z "$f" ]; then
		scan_complete=1
		continue
	fi
	if ! head -c 14 "$f" | grep -q '^\$ANSIBLE_VAULT'; then
		printf 'unencrypted vault file: %s\n' "$f" >&2
		status=1
	fi
done < <({ git ls-files -co --exclude-standard -z -- '*vault*.yml' '*vault*.yaml' '*vault*.json' && printf '\0'; })
[ "$scan_complete" -eq 1 ] || {
	printf 'vault-check: could not enumerate files\n' >&2
	exit 1
}
exit "$status"
SH
[ "$vault_check_new" -eq 0 ] || chmod +x bin/vault-check.sh

put .ansible-lint <<'YML'
---
profile: production
exclude_paths:
  - .venv/
  - collections/
YML

put .gitignore <<'GIT'
.venv/
collections/ansible_collections/
# ansible-lint gives itself an ANSIBLE_HOME here.
.ansible/
.ansible_cache/
.vault_pass*
*.retry
__pycache__/
*.log
# ansible-navigator writes a replayable artifact next to each playbook it runs.
*-artifact-*.json
# Finder and Windows Explorer drop these into any directory they open.
.DS_Store
Thumbs.db
desktop.ini
GIT

put .gitattributes <<'ATTR'
# Keep LF on every platform, so a Windows clone does not hand bin/vault-check.sh to bash with CR line endings.
* text=auto eol=lf
ATTR

# redhat.ansible expands ${workspaceFolder} only in interpreterPath; executable paths stay relative to the workspace root.
put .vscode/settings.json <<'JSON'
{
  "ansible.python.interpreterPath": "${workspaceFolder}/.venv/bin/python",
  "python.defaultInterpreterPath": "${workspaceFolder}/.venv/bin/python",
  "ansible.ansibleNavigator.path": ".venv/bin/ansible-navigator",
  "ansible.ansible.path": ".venv/bin/ansible"
}
JSON

put .vscode/extensions.json <<'JSON'
{
  "recommendations": ["redhat.ansible", "ms-python.python", "ms-python.vscode-python-envs"]
}
JSON

put README.md <<MD
# $name

\`\`\`bash
source .venv/bin/activate                                # per shell; or call .venv/bin/<tool> directly
ansible-playbook playbooks/site.yml                      # dev (default inventory)
ansible-playbook -i inventory/prod playbooks/site.yml    # prod, always explicit
ansible-navigator run playbooks/site.yml                 # dev, in the navigator TUI
ansible-lint
\`\`\`

SSH is key-only; get keys onto new hosts first.

## Setup after cloning

Use Python $pyver, the version the lockfile was made with:

\`\`\`bash
python$pyver -m venv .venv && .venv/bin/pip install --require-hashes --only-binary=:all: -r requirements.txt
.venv/bin/ansible-galaxy collection install -r collections/requirements.yml -p collections
\`\`\`

Re-running the scaffold with \`-f\` does the same and also checks the collections
against \`collections/lock.sha256\`. A venv is bound to its interpreter and its
path: to change Python, or after moving the project, delete \`.venv\` and rebuild.
The Python lock was resolved on \`$lock_platform\`; it is not guaranteed to
install on another OS or architecture, even though it records all wheel hashes.

To upgrade the Python packages, delete \`requirements.txt\` and re-run the
scaffold with \`-f\`; it takes only releases older than \`COOLDOWN_DAYS\` (default
7, \`0\` turns that off). To upgrade a collection, pin its \`version:\` in
\`collections/requirements.yml\`, delete \`collections/lock.sha256\` and re-run.

## Vault

One key per environment, outside the repo, mode 600. \`~/.ansible/vault/$name-dev\`
is shared through the password manager; \`~/.ansible/vault/$name-prod\` is made
once by whoever operates prod, and without it prod runs fail while dev runs only
warn:

\`\`\`bash
(umask 077 && python3 -c 'import secrets;print(secrets.token_urlsafe(32))' >~/.ansible/vault/$name-prod)
ansible-vault create --encrypt-vault-id prod inventory/prod/group_vars/all/vault.yml
\`\`\`

An executable key file is run and its output used, so a key can stay in the
password manager (\`exec pass show ansible/$name-dev\`). Secrets go in \`vault.yml\`
next to \`vars.yml\` and are referenced from there (\`db_password: "{{ vault_db_password }}"\`);
tasks that handle them get \`no_log: true\`. \`bin/vault-check.sh\` fails on any
plaintext \`*vault*.yml\`, \`.yaml\` or \`.json\` file - run it before committing.
MD

step collections
if [ -e collections/requirements.yml ] || [ -L collections/requirements.yml ]; then
	[ -f collections/requirements.yml ] || die "collections/requirements.yml exists but is not a regular file"
	printf 'keep collections/requirements.yml\n'
	ansible-galaxy collection install -r collections/requirements.yml -p collections
else
	# Galaxy has no cooldown of its own, so each requested collection is pinned to its newest release from before the cutoff; dependencies are locked as installed.
	pins=()
	for c in "${COLLECTIONS[@]}"; do
		v=$(galaxy_version "$c") || die "could not pick a release of $c from galaxy.ansible.com, so the cooldown cannot be applied"
		pins+=("  - name: $c" "    version: \"$v\"")
		printf 'pinned %s %s%s\n' "$c" "$v" "${cutoff:+ (newest release before $cutoff)}"
	done
	{
		echo "---"
		echo "collections:"
		printf '%s\n' "${pins[@]}"
	} >collections/requirements.yml
	ansible-galaxy collection install -r collections/requirements.yml -p collections
	# Galaxy picks the dependencies itself, so every installed version is held to the same cutoff before it is locked.
	cooldown_rc=0
	check_collection_cooldown collections/ansible_collections/*/*/MANIFEST.json || cooldown_rc=$?
	case $cooldown_rc in
	0) ;;
	2)
		rm -f collections/requirements.yml
		die "a collection Galaxy installed as a dependency is newer than the cooldown; the pins were discarded but collections/ansible_collections still holds that install - remove it, then re-run once the release has aged, write your own pins into collections/requirements.yml, or use COOLDOWN_DAYS=0 for a release that cannot wait"
		;;
	*) die "the installed collections could not be held to the cooldown - the line above says why; the pins in collections/requirements.yml are kept, so re-run once Galaxy answers again" ;;
	esac
	# Re-pin to everything galaxy installed, dependencies included, so the file is a complete lockfile.
	{
		echo "---"
		echo "collections:"
		.venv/bin/python -c 'import json,sys; [print("%(namespace)s.%(name)s %(version)s" % json.load(open(f))["collection_info"]) for f in sorted(sys.argv[1:])]' collections/ansible_collections/*/*/MANIFEST.json |
			while read -r c v; do printf '  - name: %s\n    version: "%s"\n' "$c" "$v"; done
	} >collections/requirements.yml
fi
# Galaxy is trusted once: the installed manifests are hashed into a lock that every later install of the same versions has to match.
manifests=$(.venv/bin/python -c 'import hashlib,sys; [print(hashlib.sha256(open(f,"rb").read()).hexdigest(), f) for f in sorted(sys.argv[1:])]' collections/ansible_collections/*/*/MANIFEST.json)
if [ -e collections/lock.sha256 ] || [ -L collections/lock.sha256 ]; then
	[ -f collections/lock.sha256 ] || die "collections/lock.sha256 exists but is not a regular file"
	[ "$manifests" = "$(cat collections/lock.sha256)" ] || die "installed collections do not match collections/lock.sha256; if you added or upgraded a collection on purpose, pin its version in collections/requirements.yml and delete the lock, otherwise Galaxy served something else for the same versions"
	printf 'keep collections/lock.sha256\n'
else
	printf '%s\n' "$manifests" >collections/lock.sha256
fi

if [ ! -d .git ]; then
	git init -q -b main
fi

step verify
ansible --version | sed -n 1p
ansible-lint --version | sed -n 1p
ansible-navigator --version | sed -n 1p
ansible-galaxy collection list -p collections 2>/dev/null | sed -n '/^ansible\./p;/^community\./p'
# Imported plugins leave __pycache__ in the collection tree, which verify reports as modified content.
find collections -name __pycache__ -type d -prune -exec rm -rf {} +
ansible-galaxy collection verify --offline -r collections/requirements.yml -p collections
bin/vault-check.sh
ansible-inventory -i inventory/dev --graph
ansible-lint
ansible-playbook playbooks/site.yml --check
printf '    done in %ds\n\nOK: %s\n' "$(($(date +%s) - step_start))" "$root"
# The venv PATH belonged to this script, so the calling shell is not in the venv.
cat <<MSG

Your shell is not in the venv - this run's PATH went with the script. Enter it
per shell, until deactivate or the terminal closes:

  cd "$root" && source .venv/bin/activate

or skip activation and call the tools by path, from any shell:

  "$root/.venv/bin/ansible-playbook" playbooks/site.yml --check
MSG

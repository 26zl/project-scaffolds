#!/usr/bin/env bash
# Remove what a scaffolded project can rebuild: venv, installed collections, caches and tool leftovers. Never state, never project files.
set -euo pipefail

die() {
	printf 'clean: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'USAGE'
Usage: clean.sh [-n] [-l] [-c] [<project-path>]

Removes what init-ansible.sh and init-terraform.sh can rebuild, so a re-run
with -f restores the project from its lockfiles: .venv, installed collections,
.terraform, ansible and lint caches, navigator artifacts and logs, plans, crash
logs and __pycache__. Project files, git history, vault keys and Terraform
state are always left alone; lockfiles too, unless -l asks for them. The path
defaults to the current directory.

  -n   dry run: name what would go, remove nothing
  -l   also the lock records (requirements.txt, collections/lock.sha256,
       .terraform.lock.hcl), so the next scaffold run relocks under a fresh
       cooldown; requirements.in and collections/requirements.yml stay
  -c   also the user-level tool caches shared with other projects: pip,
       ansible-lint and ansible-compat, below ~/.cache or ~/Library/Caches only

Terraform state is never removed: with a local backend it is the only record
of what exists, and terraform destroy is the way to take that down.
USAGE
}

dry=0 locks=0 caches=0
# getopts stops at the first non-option argument, so the path is set aside and parsing continues past it.
args=()
while [ $# -gt 0 ]; do
	OPTIND=1
	while getopts ':nlch' o; do
		case $o in
		n) dry=1 ;;
		l) locks=1 ;;
		c) caches=1 ;;
		h)
			usage
			exit 0
			;;
		*)
			printf 'clean: unknown option -%s\n\n' "$OPTARG" >&2
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
[ $# -le 1 ] || {
	usage >&2
	exit 2
}

project=${1:-.}
[ -d "$project" ] || die "$project is not a directory"
cd "$project"
root=$PWD

# Everything is collected first and removed last, so a refusal below leaves the project untouched.
targets=()
add() {
	local t
	[ -e "$1" ] || return 0
	# A cache named twice, by its variable and by its default location, goes once.
	for t in ${targets[@]+"${targets[@]}"}; do
		[ "$t" != "${1#./}" ] || return 0
	done
	targets+=("${1#./}")
}

# A cache is only ever a directory below the user's cache roots, so -c can never be pointed at HOME or a project.
add_cache() {
	local dir home
	[ -d "$1" ] || return 0
	dir=$(cd -P -- "$1" && pwd -P) || die "$1 cannot be resolved; nothing removed"
	home=$(cd -P -- "$HOME" && pwd -P) || die "HOME cannot be resolved; nothing removed"
	case $dir in
	"$home"/.cache/?* | "$home"/Library/Caches/?*) add "$dir" ;;
	*) die "$1 is not below ~/.cache or ~/Library/Caches, so -c will not remove it; clear it yourself. Nothing removed" ;;
	esac
}

# What a scaffold run or the tools it installs write next to the project files; each is rebuilt or regenerated.
# Logs are named one by one: a *.log glob would also take a log the project keeps by hand, which nothing rebuilds.
add .venv
add collections/ansible_collections
add .ansible
add .ansible_cache
add .terraform
for f in ./*-artifact-*.json playbooks/*-artifact-*.json ./*.retry ./ansible-navigator.log ./crash.log ./crash.*.log ./*.tfplan; do
	add "$f"
done
# Interpreter and test caches anywhere in the tree; .venv goes as a whole and .git is never entered.
while IFS= read -r -d '' d; do
	targets+=("${d#./}")
done < <(find . \( -name .git -o -name .venv \) -prune -o \
	\( -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache -o -name .tox \) -type d -print0)

if [ "$locks" -eq 1 ]; then
	add requirements.txt
	add collections/lock.sha256
	add .terraform.lock.hcl
fi

if [ "$caches" -eq 1 ]; then
	# An explicit PIP_CACHE_DIR replaces the default locations rather than adding to them.
	if [ -n "${PIP_CACHE_DIR:-}" ]; then
		add_cache "$PIP_CACHE_DIR"
	else
		add_cache "$HOME/.cache/pip"
		add_cache "$HOME/Library/Caches/pip"
	fi
	for c in ansible-lint ansible-compat; do
		add_cache "$HOME/.cache/$c"
		add_cache "$HOME/Library/Caches/$c"
	done
fi

[ ${#targets[@]} -gt 0 ] || {
	printf 'nothing to clean in %s\n' "$root"
	exit 0
}
for t in "${targets[@]}"; do
	if [ "$dry" -eq 1 ]; then
		printf 'would remove %s\n' "$t"
	else
		rm -rf -- "$t"
		printf 'removed %s\n' "$t"
	fi
done

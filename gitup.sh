#!/usr/bin/env bash
# gitup.sh — create / update GitHub repositories from local folders, with
#            automatic Git LFS handling for large files.
#
# Usage:
#   ./gitup.sh                       process the current directory
#   ./gitup.sh --folder DIR [DIR…]   process one or more directories
#   ./gitup.sh --folder all          process every direct subfolder of $PWD
#   ./gitup.sh --all                 same as `--folder all`
#
# Options:
#   -y, --yes       don't ask questions (confirmations, installs). The GitHub-account
#                   question (see "Account" below) is still asked on a terminal.
#   -n, --dry-run   only show which folders / repo names would be used
#       --private   create new repositories as private (default: public)
#       --public    create new repositories as public (this is the default)
#       --safe      never overwrite or rewrite anything: keep the existing .git, and
#                   stop when the GitHub repo has different history
#       --keep-git  keep a folder's existing .git instead of replacing it
#       --fresh     always replace the folder's .git with a fresh one
#   -h, --help      show this help
#
# Environment:
#   GITUP_YES=1                 same as --yes
#   GITUP_SKIP="a b"            extra directory names to skip in `--all` mode
#   GITUP_LFS_MB=25             files bigger than this go to Git LFS   (max 100)
#   GITUP_LFS_MAX_MB=2048       files bigger than this can't be uploaded at all
#   GITUP_RETRIES=3             attempts for network operations
#   GITUP_RATE_RETRIES=4        waits when GitHub throttles repo creation (0 = don't wait)
#   GITUP_RATE_WAIT=60          first wait in seconds (doubles each time)
#   GITUP_CREATE_DELAY=3        pause in seconds between repository creations
#   GITUP_PKG_MANAGER=NAME      force apt-get|dnf|yum|pacman|zypper|apk|xbps-install|brew
#   GITUP_NO_DEFAULT_IGNORE=1   don't add default ignores to repos w/o .gitignore
#   GITUP_NO_ACCOUNT_PROMPT=1   don't ask which GitHub account to use (use the logged-in one)
#
# Account:
#   gitup uses the GitHub account that `gh` is logged in to. If one is, it shows the
#   name and asks:  y = upload with this account
#                   n = run `gh auth login` for another account, then continue
#                   q = quit
#   If `gh` is not logged in, `gh auth login` starts right away. No question is asked
#   without a terminal (cron, pipes) or when GH_TOKEN / GITHUB_TOKEN is set.
#
# Self-exclusion:
#   The *currently running* script is excluded from a push only when it lives
#   inside the repo being pushed. Same-named files elsewhere (e.g. in a
#   subfolder) are pushed normally. Renaming the script (gitup.sh → gitpush.sh
#   → …) is fully supported.
#
# Works on any Linux distro (apt, dnf/yum, pacman, zypper, apk, xbps) and on
# macOS (Homebrew), including the stock bash 3.2.

# ─── guards (written in plain POSIX until we know we're in bash) ──────────────
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: gitup.sh needs bash — run it as: bash $0" >&2
    exit 1
fi

# Refuse to be sourced. Done BEFORE touching shell options.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf 'Error: run this script as ./gitup.sh or bash gitup.sh — do not source it.\n' >&2
    # shellcheck disable=SC2317  # `exit` is the fallback when `return` is not allowed
    return 1 2>/dev/null || exit 1
fi

# NOTE: errexit is *ignored* inside anything called from an `if`/`||`/`&&`
# condition, so every critical command below is checked explicitly.
set -euo pipefail

# ─── absolute path of the running script (for self-exclusion) ─────────────────
SELF_PATH=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _self_dir=""
    if _self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P); then
        _self_name=$(basename -- "${BASH_SOURCE[0]}")
        if [[ -n "$_self_name" && -e "$_self_dir/$_self_name" ]]; then
            SELF_PATH="$_self_dir/$_self_name"
        fi
    fi
    unset _self_dir _self_name
fi

# ─── settings ─────────────────────────────────────────────────────────────────
GH_HARD_MB=100                              # GitHub rejects bigger files outside LFS
LFS_MB="${GITUP_LFS_MB:-25}"
LFS_MAX_MB="${GITUP_LFS_MAX_MB:-2048}"      # GitHub Free/Pro LFS per-file cap
RETRIES="${GITUP_RETRIES:-3}"
ASSUME_YES=0
if [[ "${GITUP_YES:-0}" == "1" ]]; then ASSUME_YES=1; fi
DRY_RUN=0
WANT_ALL=0
FORCE_OVERWRITE=1                           # --safe turns it off
GIT_MODE="auto"                             # auto | keep (--keep-git, --safe) | always (--fresh)
RATE_RETRIES="${GITUP_RATE_RETRIES:-4}"     # waits when GitHub throttles repo creation
RATE_WAIT="${GITUP_RATE_WAIT:-60}"          # first wait in seconds; doubles each time
CREATE_DELAY="${GITUP_CREATE_DELAY:-3}"     # pause between repository creations
RATE_BLOCKED=0; LAST_CREATE=0; CREATE_OUT=""
FRESH_REPO=0; OLD_ORIGIN=""; BACKUP_PATH=""; LFS_ALL=1
VISIBILITY="public"                         # new repos; --private switches it
REQUESTED=()

GH_LOGIN=""; GH_ID=""; GH_NAME=""; GH_EMAIL=""
FOLDERS=(); SEEN=(); ALL_DIRS=(); SKIP_BIG=()
RES_URL=""; RES_NOTE=""; SELF_REL=""
SUM_DIRS=(); SUM_STATE=(); SUM_INFO=(); FAILED_DIRS=()
FIRST_ERR=""; REMOTE_SETUP=0; REMOTE_NAME="origin"; REMOTE_URL=""
TMP_FILE=""

# ─── colours & logging (all to stderr) ────────────────────────────────────────
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi
log_info() { printf '%s[INFO]%s  %s\n' "$BLUE"   "$NC" "$*" >&2; }
log_ok()   { printf '%s[ OK ]%s  %s\n' "$GREEN"  "$NC" "$*" >&2; }
log_warn() { printf '%s[WARN]%s  %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_err()  {
    printf '%s[FAIL]%s  %s\n' "$RED" "$NC" "$*" >&2
    if [[ -z "$FIRST_ERR" ]]; then FIRST_ERR="$*"; fi
}
die()      { log_err "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    if [[ -n "$TMP_FILE" ]]; then rm -f "$TMP_FILE"; fi
    return 0
}
trap cleanup EXIT
trap 'printf "\n" >&2; log_err "Interrupted."; exit 130' INT TERM

# Interactive prompt. Honours --yes; without a terminal it returns the default.
confirm() {
    local prompt="$1" default="${2:-n}" ans=""
    if (( ASSUME_YES )); then return 0; fi
    if [[ ! -t 0 ]]; then
        [[ "$default" == "y" ]]
        return
    fi
    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n] " ans || true
        [[ -z "$ans" || "$ans" == [Yy]* ]]
    else
        read -r -p "$prompt [y/N] " ans || true
        [[ "$ans" == [Yy]* ]]
    fi
}

show_help() {
    cat <<'EOF'
gitup.sh — create / update GitHub repositories from local folders, with
automatic Git LFS handling for large files.

Usage:
  ./gitup.sh                       process the current directory
  ./gitup.sh --folder DIR [DIR…]   process one or more directories
  ./gitup.sh --folder all          process every direct subfolder of $PWD
  ./gitup.sh --all                 same as `--folder all`
  ./gitup.sh DIR [DIR…]            shorthand for --folder

Options:
  -y, --yes       don't ask questions (confirmations, installs). The GitHub-account
                  question (see "Account" below) is still asked on a terminal.
  -n, --dry-run   only show which folders / repo names would be used
      --private   create new repositories as private (default: public)
      --public    create new repositories as public (this is the default)
      --safe      never overwrite or rewrite anything: keep the existing .git, and
                  stop when the GitHub repo has different history
      --keep-git  keep a folder's existing .git instead of replacing it
      --fresh     always replace the folder's .git with a fresh one
  -h, --help      show this help

Environment:
  GITUP_YES=1                 same as --yes
  GITUP_SKIP="a b"            extra directory names to skip in `--all` mode
  GITUP_LFS_MB=25             files bigger than this go to Git LFS (max 100)
  GITUP_LFS_MAX_MB=2048       files bigger than this can't be uploaded at all
  GITUP_RETRIES=3             attempts for network operations
  GITUP_RATE_RETRIES=4        waits when GitHub throttles repo creation (0 = don't wait)
  GITUP_RATE_WAIT=60          first wait in seconds (doubles each time)
  GITUP_CREATE_DELAY=3        pause in seconds between repository creations
  GITUP_PKG_MANAGER=NAME      force apt-get|dnf|yum|pacman|zypper|apk|xbps-install|brew
  GITUP_NO_DEFAULT_IGNORE=1   don't add default ignores to repos w/o .gitignore
  GITUP_NO_ACCOUNT_PROMPT=1   don't ask which GitHub account to use (use the logged-in one)

Account:
  • gitup uses the GitHub account that `gh` is logged in to. If one is, it shows
    the name and asks:   y = upload with this account
                         n = run `gh auth login` for another account, then continue
                         q = quit
  • If `gh` is not logged in, `gh auth login` starts right away.
  • No question is asked without a terminal (cron, pipes) or when GH_TOKEN /
    GITHUB_TOKEN is set; GITUP_NO_ACCOUNT_PROMPT=1 turns it off.

How it works:
  • Each folder becomes its own repository, named after the folder
    (spaces → '-', unsupported characters removed).
  • A folder's old .git is replaced by a fresh one (the old one is MOVED to
    <parent>/.gitup-backups/, not deleted), then it runs the equivalent of
    `git remote add origin …; git branch -M main; git push -u origin main`.
    Repositories gitup created itself are simply updated on later runs.
    (`--keep-git` keeps your own .git as it is.)
  • The remote is always YOUR current account's repo named after the folder,
    even if the old .git pointed at another account.
  • If that repository already exists, the folder's content is put on top of
    its history (nothing is force-pushed; files that are gone locally are
    removed). `--safe` stops instead.
  • If GitHub throttles repository creation (secondary rate limit), gitup
    waits and retries, then tells you to re-run later.
  • Files over GITUP_LFS_MB are stored with Git LFS automatically.
  • A repo without a .gitignore skips node_modules, __pycache__, .venv,
    .DS_Store and Thumbs.db (local exclude only; nothing is added to the repo).
  • In `--all` mode hidden folders, symlinks, empty folders and common
    build/dependency folders (node_modules, .venv, dist, build, target, …)
    are skipped.  Naming a folder explicitly always processes it.
  • A folder literally called `all` can be processed with `--folder ./all`.

Self-exclusion:
  The running script is excluded from a push only when it lives inside the
  repo being pushed. Same-named files elsewhere are pushed. Renaming the
  script is supported.
EOF
}

# ─── tiny helpers ─────────────────────────────────────────────────────────────
run_privileged() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    elif command_exists doas; then
        doas "$@"
    else
        log_err "Root privileges are needed to run: $*  (install sudo or run as root)"
        return 1
    fi
}

fetch_url() {
    if command_exists curl; then
        curl -fsSL "$1"
    elif command_exists wget; then
        wget -qO- "$1"
    else
        log_err "curl or wget is needed to download $1"
        return 1
    fi
}

# Escape characters that are special in .gitignore patterns.
gitignore_escape() { printf '%s' "$1" | sed -e 's/[][*?\\]/\\&/g'; }

# Append a line to an exclude file unless already present.
exclude_add() {
    mkdir -p "$(dirname -- "$1")" 2>/dev/null || return 1
    touch "$1" 2>/dev/null || return 1
    if ! grep -qxF -- "$2" "$1" 2>/dev/null; then
        printf '%s\n' "$2" >> "$1" || return 1
    fi
    return 0
}

# ─── package managers ─────────────────────────────────────────────────────────
ensure_brew_on_path() {
    local b
    if command_exists brew; then return 0; fi
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew \
             /home/linuxbrew/.linuxbrew/bin/brew "${HOME:-/nonexistent}/.linuxbrew/bin/brew"; do
        if [[ -x "$b" ]]; then
            eval "$("$b" shellenv)"
            hash -r 2>/dev/null || true
            return 0
        fi
    done
    return 1
}

detect_pkg_manager() {
    local m
    if [[ -n "${GITUP_PKG_MANAGER:-}" ]]; then
        printf '%s\n' "$GITUP_PKG_MANAGER"
        return 0
    fi
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if command_exists brew; then echo brew; fi
        return 0
    fi
    for m in apt-get dnf yum pacman zypper apk xbps-install brew; do
        if command_exists "$m"; then
            echo "$m"
            return 0
        fi
    done
    return 0
}

# Distro package name for a tool (Arch/Alpine/Void call gh "github-cli").
pkg_name_for() {
    case "$2" in
        gh)
            case "$1" in
                pacman|apk|xbps-install) echo github-cli ;;
                *) echo gh ;;
            esac ;;
        *) echo "$2" ;;
    esac
}

install_with_mgr() {
    local mgr="$1"; shift
    case "$mgr" in
        apt-get)
            if ! run_privileged apt-get update -qq; then
                log_warn "'apt-get update' failed — trying to install anyway."
            fi
            run_privileged apt-get install -y "$@" ;;
        dnf)          run_privileged dnf install -y "$@" ;;
        yum)          run_privileged yum install -y "$@" ;;
        pacman)       run_privileged pacman -S --noconfirm --needed "$@" ;;
        zypper)       run_privileged zypper --non-interactive install "$@" ;;
        apk)          run_privileged apk add "$@" ;;
        xbps-install) run_privileged xbps-install -y "$@" ;;
        brew)         brew install "$@" ;;
        *)            log_err "Unsupported package manager: $mgr"; return 1 ;;
    esac
}

# GitHub's official package repositories, for distros whose own repos lack `gh`.
add_gh_official_repo() {
    local keyring="/etc/apt/keyrings/githubcli-archive-keyring.gpg" arch
    case "$1" in
        apt-get)
            arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
            run_privileged mkdir -p -m 755 /etc/apt/keyrings || return 1
            fetch_url https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                | run_privileged tee "$keyring" >/dev/null || return 1
            run_privileged chmod go+r "$keyring" || return 1
            printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' "$arch" "$keyring" \
                | run_privileged tee /etc/apt/sources.list.d/github-cli.list >/dev/null || return 1
            run_privileged apt-get update -qq ;;
        dnf|yum)
            fetch_url https://cli.github.com/packages/rpm/gh-cli.repo \
                | run_privileged tee /etc/yum.repos.d/gh-cli.repo >/dev/null ;;
        zypper)
            run_privileged zypper --non-interactive addrepo https://cli.github.com/packages/rpm/gh-cli.repo || return 1
            run_privileged zypper --non-interactive --gpg-auto-import-keys refresh ;;
        *) return 1 ;;
    esac
}

print_manual_hint() {
    case "$1" in
        git)
            if [[ "$(uname -s)" == "Darwin" ]]; then
                log_err "Install git with:  xcode-select --install   (or: brew install git)"
            else
                log_err "Install git with your package manager, then re-run."
            fi ;;
        gh)      log_err "Install the GitHub CLI: https://github.com/cli/cli#installation" ;;
        git-lfs) log_err "Install Git LFS: https://git-lfs.com" ;;
    esac
    if [[ "$(uname -s)" == "Darwin" ]] && ! command_exists brew; then
        log_err "Homebrew is not installed — get it from https://brew.sh and re-run."
    fi
}

install_tool() {
    local tool="$1" mgr pkg
    mgr=$(detect_pkg_manager)
    if [[ -z "$mgr" ]]; then
        log_err "No supported package manager found (apt, dnf, yum, pacman, zypper, apk, xbps, brew)."
        print_manual_hint "$tool"
        return 1
    fi
    pkg=$(pkg_name_for "$mgr" "$tool")
    log_info "Installing '$pkg' via $mgr…"
    if install_with_mgr "$mgr" "$pkg"; then
        hash -r 2>/dev/null || true
        return 0
    fi
    if [[ "$tool" == "gh" ]]; then
        case "$mgr" in
            apt-get|dnf|yum|zypper)
                log_warn "'gh' is not available from the distro repositories — adding GitHub's official package repository."
                if add_gh_official_repo "$mgr" && install_with_mgr "$mgr" "$pkg"; then
                    hash -r 2>/dev/null || true
                    return 0
                fi ;;
        esac
    fi
    if [[ "$mgr" == "pacman" ]]; then
        log_warn "If pacman could not find or fetch the package, update first:  sudo pacman -Syu"
    fi
    print_manual_hint "$tool"
    return 1
}

git_usable() { command_exists git && git --version >/dev/null 2>&1; }

ensure_dependencies() {
    local -a missing=()
    local tool
    ensure_brew_on_path || true
    if ! git_usable; then missing+=("git"); fi
    if ! command_exists gh; then missing+=("gh"); fi
    if (( ${#missing[@]} == 0 )); then
        log_ok "git and gh are installed."
        return 0
    fi
    log_warn "Missing dependencies: ${missing[*]}"
    if ! confirm "Install them now using your package manager? (you may be asked for your password)" n; then
        die "git and gh are required. Aborting."
    fi
    for tool in "${missing[@]}"; do
        install_tool "$tool" || die "Installation of '$tool' failed."
    done
    git_usable || die "git is still not usable after installation."
    command_exists gh || die "gh is still not available after installation."
    log_ok "Dependencies installed."
}

# ─── GitHub auth & identity ───────────────────────────────────────────────────
# Ask which GitHub account to use? Only on a terminal, and not when a token in the environment
# decides the account (`gh auth login` could not change that anyway).
should_ask_account() {
    if [[ ! -t 0 ]]; then return 1; fi
    if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then return 1; fi
    if [[ "${GITUP_NO_ACCOUNT_PROMPT:-0}" == "1" ]]; then return 1; fi
    return 0
}

# ask_account LOGIN — shows the logged-in account and prints the answer: y | n | q
# (only an explicit answer counts, so a stray Enter can't upload to the wrong account)
ask_account() {
    local who="$1" ans=""
    while true; do
        printf '\n' >&2
        log_info "GitHub account currently logged in:  ${who}"
        printf '    Do you want to upload to this GitHub account?\n' >&2
        printf '      y = yes, continue with %s\n' "$who" >&2
        printf '      n = no, log in to another account (gh auth login), then continue\n' >&2
        printf '      q = quit\n' >&2
        if ! read -r -p "    Your choice [y/n/q]: " ans; then ans="q"; fi
        ans="${ans//[[:space:]]/}"
        case "$ans" in
            [Yy]|[Yy][Ee][Ss])        echo y; return 0 ;;
            [Nn]|[Nn][Oo])            echo n; return 0 ;;
            [Qq]|[Qq][Uu][Ii][Tt])    echo q; return 0 ;;
        esac
        log_warn "Please type y, n or q."
    done
}

ensure_auth() {
    local out="" who="" choice=""
    while true; do
        if out=$(gh api user --jq .login 2>&1) && [[ -n "$out" ]]; then
            who="${out%%$'\n'*}"
            if should_ask_account; then
                choice=$(ask_account "$who")
                case "$choice" in
                    y)
                        log_ok "Using GitHub account: ${who}" ;;
                    q)
                        log_warn "Quit — nothing was uploaded."
                        exit 0 ;;
                    n)
                        log_info "Starting 'gh auth login' to log in to another account…"
                        if ! gh auth login --hostname github.com; then
                            log_err "The login did not finish."
                            continue            # back to the question
                        fi
                        out=$(gh api user --jq .login 2>&1) || die "Still not authenticated after login."
                        if [[ -z "$out" ]]; then die "Still not authenticated after login."; fi
                        log_ok "Logged in as ${out%%$'\n'*} — continuing with the upload." ;;
                esac
            else
                log_ok "GitHub CLI is authenticated as ${who}."
            fi
            break
        elif gh auth status --hostname github.com >/dev/null 2>&1; then
            die "You appear to be logged in, but GitHub could not be reached: $out"
        else
            if [[ ! -t 0 ]]; then
                die "GitHub CLI is not logged in and there is no terminal for the login. Run 'gh auth login' first, or set GH_TOKEN."
            fi
            log_warn "GitHub CLI is not logged in — starting 'gh auth login' now…"
            gh auth login --hostname github.com || die "Authentication failed."
            gh api user --jq .login >/dev/null 2>&1 || die "Still not authenticated after login."
            log_ok "Login finished — continuing with the upload."
            break
        fi
    done
    gh auth setup-git >/dev/null 2>&1 || true
}

load_github_identity() {
    local out=""
    if ! out=$(gh api user --jq '.login, .id, (.name // "")' 2>&1); then
        die "Could not query your GitHub account: $out"
    fi
    { IFS= read -r GH_LOGIN; IFS= read -r GH_ID; IFS= read -r GH_NAME; } <<EOF || true
$out
EOF
    if [[ -z "$GH_LOGIN" ]]; then die "GitHub returned no username. Try: gh auth status"; fi
    if [[ -z "$GH_NAME" ]]; then GH_NAME="$GH_LOGIN"; fi
    case "$GH_ID" in
        ''|*[!0-9]*) GH_EMAIL="${GH_LOGIN}@users.noreply.github.com" ;;
        *)           GH_EMAIL="${GH_ID}+${GH_LOGIN}@users.noreply.github.com" ;;
    esac
}

ensure_git_identity() {
    local n e
    n=$(git config user.name  2>/dev/null || true)
    e=$(git config user.email 2>/dev/null || true)
    if [[ -n "$n" && -n "$e" ]]; then return 0; fi
    if [[ -z "$n" ]]; then git config user.name  "$GH_NAME"  || return 1; fi
    if [[ -z "$e" ]]; then git config user.email "$GH_EMAIL" || return 1; fi
    log_info "No git identity configured — using your GitHub identity for this repo."
}

# ─── Git LFS ──────────────────────────────────────────────────────────────────
have_lfs() { git lfs version >/dev/null 2>&1; }

repo_uses_lfs() { [[ -f .gitattributes ]] && grep -q 'filter=lfs' .gitattributes 2>/dev/null; }

ensure_lfs() {
    if have_lfs; then return 0; fi
    log_warn "Git LFS is needed to upload files larger than ${LFS_MB} MB."
    if ! confirm "Install Git LFS now?" n; then return 1; fi
    install_tool git-lfs || return 1
    if have_lfs; then return 0; fi
    log_err "Git LFS was installed but is not on PATH."
    return 1
}

lfs_activate() {
    if ! git lfs install --local >/dev/null 2>&1; then
        log_warn "'git lfs install --local' reported a problem (existing hooks?) — gitup will upload LFS objects explicitly."
    fi
    if [[ -z "$(git config --get filter.lfs.clean 2>/dev/null || true)" ]]; then
        log_err "Git LFS filter is not configured for this repository."
        return 1
    fi
}

file_size_mb() { echo $(( $(wc -c < "$1") / 1048576 )); }

# true if file $1 is bigger than $2 MiB (portable: GNU and BSD find)
file_over_mb() { [[ -n "$(find "$1" -maxdepth 0 -type f -size "+$2M" -print 2>/dev/null)" ]]; }

# true if git would stage this path (tracked, or untracked and not ignored)
path_is_addable() {
    [[ -n "$(GIT_LITERAL_PATHSPECS=1 git ls-files --cached --others --exclude-standard -- "$1" 2>/dev/null)" ]]
}

# Finds files that need LFS (or can't be uploaded), prepares LFS tracking.
# Fills SKIP_BIG with files above the LFS cap. Returns 1 on a fatal problem.
prepare_large_files() {
    local f rel mb attr hard=0
    local -a candidates=()
    SKIP_BIG=()

    while IFS= read -r -d '' f; do
        if ! path_is_addable "$f"; then continue; fi
        if file_over_mb "$f" "$LFS_MAX_MB"; then
            SKIP_BIG+=("$f")
            continue
        fi
        candidates+=("$f")
        if file_over_mb "$f" "$GH_HARD_MB"; then hard=1; fi
    done < <(find . -name .git -prune -o -type f -size "+${LFS_MB}M" -print0 2>/dev/null)

    if (( ${#SKIP_BIG[@]} )); then
        for f in "${SKIP_BIG[@]}"; do
            log_warn "Too large for GitHub (over ${LFS_MAX_MB} MB, $(file_size_mb "$f") MB) — NOT uploaded: ${f#./}"
        done
    fi

    if (( ${#candidates[@]} == 0 )) && ! repo_uses_lfs; then return 0; fi

    if ! have_lfs; then
        if ! ensure_lfs; then
            if repo_uses_lfs; then
                log_err "This repository already uses Git LFS, which is not available — refusing to commit raw files."
                return 1
            fi
            if (( hard )); then
                log_err "Files over ${GH_HARD_MB} MB can't be pushed to GitHub without Git LFS:"
                for f in "${candidates[@]}"; do
                    if file_over_mb "$f" "$GH_HARD_MB"; then log_err "  ${f#./}"; fi
                done
                return 1
            fi
            log_warn "Git LFS unavailable — files over ${LFS_MB} MB will be committed normally (GitHub warns above 50 MB)."
            return 0
        fi
    fi

    lfs_activate || return 1

    if (( ${#candidates[@]} )); then
        log_info "Using Git LFS for files larger than ${LFS_MB} MB:"
        for f in "${candidates[@]}"; do
            rel="${f#./}"
            mb=$(file_size_mb "$f")
            attr=$(git check-attr filter -- "$f" 2>/dev/null || true)
            if [[ "$attr" == *": filter: lfs" ]]; then
                log_info "  = $rel (${mb} MB, already tracked)"
                continue
            fi
            if git lfs track --filename -- "$f" >/dev/null 2>&1; then
                log_info "  + $rel (${mb} MB)"
            else
                log_err "  ! could not track $rel with Git LFS"
                return 1
            fi
        done
    fi
    return 0
}

# ─── network operations with retry ────────────────────────────────────────────
is_transient_failure() {
    grep -Eqi 'RPC failed|early EOF|unexpected disconnect|remote end hung up|reset by peer|timed out|timeout|Could not resolve host|Could not connect|Failed to connect|Connection (closed|refused|reset)|Broken pipe|HTTP/2 stream|SSL_|GnuTLS|(error|status|HTTP|returned error:) 5[0-9][0-9]' "$1"
}

# run_with_retry LABEL cmd…   (output is shown live and kept in $TMP_FILE)
run_with_retry() {
    local label="$1" attempt=1 rc delay
    shift
    while true; do
        rc=0
        "$@" 2>&1 | tee "$TMP_FILE" >&2 || rc=$?
        if (( rc == 0 )); then return 0; fi
        if (( attempt >= RETRIES )) || ! is_transient_failure "$TMP_FILE"; then
            return "$rc"
        fi
        delay=$(( attempt * 4 ))
        attempt=$(( attempt + 1 ))
        log_warn "$label failed (network problem?) — retrying in ${delay}s (attempt ${attempt}/${RETRIES})…"
        sleep "$delay"
    done
}

diagnose_push_failure() {
    local f="$1" branch="$2"
    if grep -Eqi 'GH001|exceeds GitHub.s file size limit|Large files detected' "$f"; then
        log_err "A file over ${GH_HARD_MB} MB is stored in the commit history without Git LFS."
        log_err "Re-run without --safe and gitup moves such files into Git LFS for you, or run:"
        log_err "    git lfs migrate import --include-ref=refs/heads/${branch} --above=${GH_HARD_MB}MiB"
    elif grep -Eqi 'workflow.*scope|without .?workflow.? scope' "$f"; then
        log_err "GitHub refused workflow files (.github/workflows) — your login lacks the 'workflow' scope."
        log_err "Fix:  gh auth refresh -h github.com -s workflow"
    elif grep -Eqi 'GH013|push cannot contain secrets|secret scanning' "$f"; then
        log_err "GitHub blocked the push (secret scanning / repository rule). Read the message above,"
        log_err "remove the flagged secret from your files and commit, then re-run."
    elif grep -Eqi 'quota|over its data|LFS.*(budget|limit exceeded)' "$f"; then
        log_err "GitHub LFS storage/bandwidth quota exceeded. Free accounts get limited LFS data."
        log_err "Buy more LFS data on GitHub, delete old LFS objects, or raise GITUP_LFS_MB so mid-size files skip LFS."
    elif grep -Eqi 'archived' "$f"; then
        log_err "The GitHub repository is archived (read-only). Unarchive it under Settings → Danger Zone, then re-run."
    elif grep -Eqi 'protected branch|protected ref|cannot force.push|force.push.*(denied|blocked)' "$f"; then
        log_err "Branch protection blocks this push. Turn it off in the repository's Settings → Branches, then re-run."
    elif grep -Eqi 'non-fast-forward|fetch first|tip of your current branch is behind' "$f"; then
        if (( FORCE_OVERWRITE )); then
            log_err "The remote branch has different history and gitup could not overwrite it."
        else
            log_err "The remote branch has different history (--safe mode: nothing was overwritten)."
            log_err "Re-run without --safe to overwrite it, or merge first:"
            log_err "    git pull --no-rebase --allow-unrelated-histories origin ${branch}"
        fi
    elif grep -Eqi 'Authentication failed|could not read (Username|Password)|Permission denied \(publickey\)|HTTP Basic: Access denied|Support for password authentication|returned error: 403|invalid credentials|Permission to .* denied' "$f"; then
        log_err "GitHub rejected your credentials (logged in as ${GH_LOGIN}). Try:  gh auth login   and   gh auth setup-git"
    elif grep -Eqi 'Repository not found|does not appear to be a git repository' "$f"; then
        log_err "The remote repository was not found. Check 'git remote -v' — it may have been deleted or renamed."
    else
        log_err "Push failed — see the git output above."
    fi
}

add_note() {
    if [[ -z "$RES_NOTE" ]]; then RES_NOTE="$1"; else RES_NOTE="${RES_NOTE}, $1"; fi
}

push_branch() {
    local remote="$1" branch="$2" prev=""
    local -a lfs_opts=()
    if (( LFS_ALL )); then lfs_opts=(--all); fi
    if have_lfs && repo_uses_lfs; then
        log_info "Uploading Git LFS objects to '$remote'…"
        # --all (default): don't trust remote-tracking refs, they may belong to another repo.
        # Not used after adopting GitHub's history: those objects are already on the server.
        if ! run_with_retry "LFS upload" git lfs push ${lfs_opts[@]+"${lfs_opts[@]}"} "$remote" "$branch"; then
            diagnose_push_failure "$TMP_FILE" "$branch"
            return 1
        fi
    fi
    log_info "Pushing '$branch' to '$remote'…"
    if run_with_retry "git push" git push --progress -u "$remote" "$branch"; then
        return 0
    fi
    if (( FORCE_OVERWRITE )) && grep -Eqi 'non-fast-forward|fetch first|tip of your current branch is behind' "$TMP_FILE"; then
        prev=$(git ls-remote "$remote" "refs/heads/$branch" 2>/dev/null | cut -f1 | head -n 1 || true)
        log_warn "The remote branch '$branch' has different history — overwriting it with this folder's content."
        if [[ -n "$prev" ]]; then log_warn "  (previous remote tip: ${prev})"; fi
        if run_with_retry "forced push" git push --progress --force -u "$remote" "$branch"; then
            add_note "overwrote existing remote content"
            return 0
        fi
    fi
    diagnose_push_failure "$TMP_FILE" "$branch"
    return 1
}

# ─── repo naming & remote setup ───────────────────────────────────────────────
sanitize_repo_name() {
    local n
    n=$(printf '%s' "$1" | LC_ALL=C tr ' ' '-' | LC_ALL=C tr -cd 'A-Za-z0-9._-')
    n="${n%.git}"
    n="${n:0:100}"
    case "$n" in
        '') return 1 ;;
        *[!.]*) ;;          # contains something other than dots → fine
        *) return 1 ;;      # only dots ('.', '..')
    esac
    printf '%s' "$n"
}

web_url() {
    printf '%s' "$1" | sed -e 's#^git@github\.com:#https://github.com/#' \
                           -e 's#^ssh://git@github\.com/#https://github.com/#' \
                           -e 's#\.git$##'
}

is_github_url() {
    case "$1" in
        *github.com[:/]*) return 0 ;;
    esac
    return 1
}

# Prints OWNER/NAME for a github.com remote URL (https, ssh, scp-style); fails for other hosts.
github_slug() {
    local s
    is_github_url "$1" || return 1
    s=$(printf '%s' "$1" | sed -E -e 's#^(https?|ssh|git)://([^/@]+@)?github\.com(:[0-9]+)?/##' \
                                  -e 's#^[^@/:]+@github\.com:##' -e 's#\.git/?$##' -e 's#/+$##')
    case "$s" in
        */*/*|/*|*/|'') return 1 ;;
        */*)            printf '%s' "$s" ;;
        *)              return 1 ;;
    esac
}

# Can the logged-in account push to OWNER/NAME?  Prints yes | no | missing | unknown,
# or "error: …" (and returns 1) when GitHub could not be asked.
repo_access_state() {
    local out rc=0
    out=$(gh api "repos/$1" --jq '.permissions.push' 2>&1) || rc=$?
    if (( rc == 0 )); then
        case "$out" in
            true)  echo yes ;;
            false) echo no ;;
            *)     echo unknown ;;
        esac
    elif [[ "$out" == *"404"* || "$out" == *"Not Found"* ]]; then
        echo missing
    elif [[ "$out" == *"403"* ]]; then
        echo no
    else
        printf 'error: %s\n' "$out"
        return 1
    fi
}

# One short line out of a `gh api` error (gh prints the JSON body, then a "gh: …" line).
short_gh_error() {
    local t="$1" line
    if [[ "$t" == *"gh: "* ]]; then line="${t##*gh: }"; else line="$t"; fi
    line="${line%%$'\n'*}"
    if (( ${#line} > 220 )); then line="${line:0:220}…"; fi
    printf '%s' "$line"
}

is_rate_limited() {
    case "$1" in
        *"secondary rate limit"*|*"rate limit"*|*"abuse detection"*|*"retry-after"*|*"Retry-After"*) return 0 ;;
    esac
    return 1
}

# GitHub throttles bursts of repository creation; keep a small gap between them.
pace_creation() {
    local now gap
    if (( CREATE_DELAY > 0 && LAST_CREATE > 0 )); then
        now=$(date +%s)
        gap=$(( LAST_CREATE + CREATE_DELAY - now ))
        if (( gap > 0 )); then sleep "$gap"; fi
    fi
}

# Creates $GH_LOGIN/NAME, waiting out GitHub's "secondary rate limit" when it kicks in.
# Sets CREATE_OUT (the three URL lines). Returns 0 = created, 1 = failed, 3 = it already exists.
create_github_repo() {
    local name="$1" private_flag="true" tries=0 wait="$RATE_WAIT" out rc
    if [[ "$VISIBILITY" == "public" ]]; then private_flag="false"; fi
    while true; do
        pace_creation
        rc=0
        out=$(gh api --method POST user/repos -f name="$name" -F private="$private_flag" \
                --jq '.clone_url, .ssh_url, .html_url' 2>&1) || rc=$?
        LAST_CREATE=$(date +%s)
        if (( rc == 0 )); then
            CREATE_OUT="$out"; RATE_BLOCKED=0
            return 0
        fi
        if is_rate_limited "$out"; then
            if (( RATE_BLOCKED || tries >= RATE_RETRIES )); then
                RATE_BLOCKED=1
                log_err "GitHub is temporarily blocking repository creation for your account (rate limit) — wait a while, then re-run."
                log_info "This is GitHub-side throttling, not a problem with this folder. It usually lifts within minutes to an hour (longer for brand-new accounts). Folders whose repository already exists are not affected."
                return 1
            fi
            tries=$(( tries + 1 ))
            log_warn "GitHub is rate-limiting repository creation — waiting ${wait}s, then retrying (${tries}/${RATE_RETRIES}). Ctrl-C stops."
            sleep "$wait"
            wait=$(( wait * 2 ))
            if (( wait > 600 )); then wait=600; fi
            continue
        fi
        case "$out" in
            *"already exists"*) return 3 ;;
        esac
        log_err "Could not create repository '$name': $(short_gh_error "$out")"
        return 1
    done
}

# Makes sure $GH_LOGIN/NAME exists on GitHub (creating it if needed).
# Sets REMOTE_URL and RES_URL.
ensure_github_repo() {
    local repo_name="$1" out="" rc crc pass found=0 clone ssh html proto
    # shellcheck disable=SC2034  # two passes: the second one re-reads a repo that appeared meanwhile
    for pass in 1 2; do
        rc=0
        out=$(gh api "repos/$GH_LOGIN/$repo_name" --jq '.clone_url, .ssh_url, .html_url' 2>&1) || rc=$?
        if (( rc == 0 )); then
            if (( FORCE_OVERWRITE )); then
                log_warn "GitHub repo '$GH_LOGIN/$repo_name' already exists — its content will be replaced with this folder's."
            else
                log_warn "GitHub repo '$GH_LOGIN/$repo_name' already exists — attaching to it."
            fi
            add_note "existing repo"
            found=1; break
        fi
        if [[ "$out" != *"404"* && "$out" != *"Not Found"* ]]; then
            log_err "Could not check GitHub for '$repo_name': $(short_gh_error "$out")"
            return 1
        fi
        log_info "Creating ${VISIBILITY} GitHub repository '$repo_name'…"
        crc=0
        create_github_repo "$repo_name" || crc=$?
        if (( crc == 0 )); then
            out="$CREATE_OUT"
            log_ok "Created repository $GH_LOGIN/$repo_name (${VISIBILITY})."
            add_note "created"
            found=1; break
        fi
        if (( crc != 3 )); then return 1; fi
        # it appeared in the meantime (or differs only in letter case): look it up again
    done
    if (( ! found )); then
        log_err "GitHub says '$repo_name' already exists, but it can't be read with your login (${GH_LOGIN})."
        return 1
    fi

    clone=$(printf '%s\n' "$out" | sed -n '1p')
    ssh=$(printf '%s\n' "$out" | sed -n '2p')
    html=$(printf '%s\n' "$out" | sed -n '3p')
    proto=$(gh config get git_protocol 2>/dev/null || true)
    if [[ "$proto" == "ssh" && -n "$ssh" ]]; then REMOTE_URL="$ssh"; else REMOTE_URL="$clone"; fi
    if [[ -z "$REMOTE_URL" ]]; then
        log_err "GitHub did not return a clone URL for '$repo_name'."
        return 1
    fi
    RES_URL="$html"
    if [[ -z "$RES_URL" ]]; then RES_URL=$(web_url "$REMOTE_URL"); fi
    return 0
}

# Decides which remote to push to. Sets REMOTE_NAME, REMOTE_URL, RES_URL,
# REMOTE_SETUP (1 when the remote was created / attached / switched this run).
setup_remote() {
    local dir="$1" base repo_name other slug state why old_slug="" switch=0 r
    REMOTE_SETUP=0; REMOTE_NAME="origin"
    REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || true)
    if [[ -z "$REMOTE_URL" ]]; then
        # no `origin`: use the first remote that lives on GitHub (a Codeberg remote added by
        # codebergup.sh must never be mistaken for ours)
        while IFS= read -r other; do
            if [[ -z "$other" ]]; then continue; fi
            slug=$(git config --get "remote.$other.url" 2>/dev/null || true)
            if is_github_url "$slug"; then
                REMOTE_NAME="$other"; REMOTE_URL="$slug"
                break
            fi
        done < <(git remote 2>/dev/null)
        slug=""
    fi

    if [[ -n "$REMOTE_URL" ]]; then
        RES_URL=$(web_url "$REMOTE_URL")
        if ! slug=$(github_slug "$REMOTE_URL"); then
            log_info "Using existing remote '$REMOTE_NAME' → $REMOTE_URL"
            return 0
        fi
        if ! state=$(repo_access_state "$slug"); then
            log_err "Could not check '$slug' on GitHub: ${state#error: }"
            return 1
        fi
        case "$state" in
            yes|unknown)
                log_info "Using existing remote '$REMOTE_NAME' → $REMOTE_URL"
                return 0 ;;
            missing) why="does not exist (deleted, or private to another account)" ;;
            *)       why="can't be written to with your current GitHub login (${GH_LOGIN})" ;;
        esac
        log_warn "Remote '$REMOTE_NAME' ($slug) $why — switching it to your own account."
        old_slug="$slug"
        switch=1
    fi

    base=$(basename -- "$dir")
    if ! repo_name=$(sanitize_repo_name "$base"); then
        log_err "Cannot derive a valid GitHub repository name from folder '$base' (use letters, digits, '.', '_' or '-')."
        return 1
    fi
    if [[ "$repo_name" != "$base" ]]; then
        log_warn "Repository name sanitised: '$base' → '$repo_name'."
    fi

    ensure_github_repo "$repo_name" || return 1

    if (( switch )); then
        git remote set-url "$REMOTE_NAME" "$REMOTE_URL" || return 1
        # remote-tracking refs of the old account's repo are meaningless now
        git for-each-ref --format='%(refname)' "refs/remotes/$REMOTE_NAME/" 2>/dev/null \
            | while IFS= read -r r; do git update-ref -d "$r" 2>/dev/null || true; done
        add_note "switched from ${old_slug}"
        log_info "Remote '$REMOTE_NAME' now points to $REMOTE_URL"
    else
        git remote add "$REMOTE_NAME" "$REMOTE_URL" || return 1
    fi
    REMOTE_SETUP=1
    return 0
}

# After (re)pointing a remote, make the GitHub default branch the one we pushed.
align_default_branch() {
    local branch="$1" slug cur
    slug=$(github_slug "$REMOTE_URL") || return 0
    cur=$(gh api "repos/$slug" --jq .default_branch 2>/dev/null || true)
    if [[ -n "$cur" && "$cur" != "$branch" ]]; then
        if gh api --method PATCH "repos/$slug" -f default_branch="$branch" >/dev/null 2>&1; then
            log_info "GitHub default branch switched: $cur → $branch"
        else
            log_warn "Could not switch the GitHub default branch to '$branch' (it is '$cur')."
        fi
    fi
    return 0
}

# Moves the folder's own .git out of the way (it is never deleted) so a fresh repository
# can be created. Sets BACKUP_PATH. Backups live next to the project folders, in
# <parent>/.gitup-backups/ (same filesystem → instant); falls back to ~/.cache.
retire_git_dir() {
    local phys="$1" stamp base dest root
    stamp=$(date '+%Y%m%d-%H%M%S')
    base=$(basename -- "$phys")
    root="$(dirname -- "$phys")/.gitup-backups"
    dest="$root/${base}-${stamp}.git"
    if mkdir -p -- "$root" 2>/dev/null && mv -- .git "$dest" 2>/dev/null; then
        BACKUP_PATH="$dest"; return 0
    fi
    root="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/gitup-backups"
    dest="$root/${base}-${stamp}.git"
    if mkdir -p -- "$root" 2>/dev/null && mv -- .git "$dest" 2>/dev/null; then
        BACKUP_PATH="$dest"; return 0
    fi
    return 1
}

# A fresh repository knows nothing about what is already on GitHub. If the repository there
# already has this branch, put this folder's content on top of it: a normal fast-forward push,
# nothing is force-pushed, the old history stays, and files that no longer exist locally are
# removed (the remote ends up matching the folder).
adopt_remote_history() {
    local branch="$1" ref rtip new msg
    if (( ! FRESH_REPO || ! FORCE_OVERWRITE )); then return 0; fi
    if ! git ls-remote --exit-code --heads "$REMOTE_NAME" "$branch" >/dev/null 2>&1; then
        return 0        # no such branch there yet (or unreachable: the push will explain)
    fi
    ref="refs/remotes/$REMOTE_NAME/$branch"
    log_info "GitHub already has '$branch' — putting this folder's content on top of it."
    if ! run_with_retry "fetch" git fetch --no-tags --quiet "$REMOTE_NAME" "+refs/heads/$branch:$ref"; then
        log_warn "Could not read the existing '$branch' from GitHub — trying a direct push instead."
        return 0
    fi
    rtip=$(git rev-parse --verify -q "$ref^{commit}") || return 0
    LFS_ALL=0
    if [[ "$(git rev-parse "$rtip^{tree}")" == "$(git rev-parse 'HEAD^{tree}')" ]]; then
        git update-ref "refs/heads/$branch" "$rtip" || return 0
        add_note "already identical on GitHub"
        return 0
    fi
    msg="Update from gitup.sh $(date '+%Y-%m-%d %H:%M:%S')"
    if new=$(git commit-tree 'HEAD^{tree}' -p "$rtip" -m "$msg") && git update-ref "refs/heads/$branch" "$new"; then
        add_note "content replaced, history kept"
    else
        LFS_ALL=1
        log_warn "Could not build the update on top of GitHub's history — trying a direct push instead."
    fi
    return 0
}

# GitHub rejects a push whose history contains a blob over 100 MiB that is not an LFS pointer.
# Detect that up front and, unless --safe, move those files into Git LFS (history rewrite of
# this branch only; the old history stays reachable under refs/gitup-backup/).
fix_large_history() {
    local branch="$1" big f backup limit oldtip
    limit=$(( GH_HARD_MB * 1048576 ))
    big=$(git rev-list --objects "refs/heads/$branch" --not --remotes="$REMOTE_NAME" 2>/dev/null \
          | git cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' 2>/dev/null \
          | awk -v lim="$limit" '$1 == "blob" && $2 + 0 > lim' | cut -d' ' -f3- | head -n 5 || true)
    if [[ -z "$big" ]]; then return 0; fi

    log_warn "Files in this folder's commit history are over ${GH_HARD_MB} MB and not in Git LFS (GitHub would reject the push):"
    printf '%s\n' "$big" | while IFS= read -r f; do log_warn "    $f"; done
    if (( ! FORCE_OVERWRITE )); then
        log_err "Rewrite the history once with:  git lfs migrate import --include-ref=refs/heads/${branch} --above=${GH_HARD_MB}MiB   (or re-run without --safe)"
        return 1
    fi
    if ! have_lfs && ! ensure_lfs; then
        log_err "Git LFS is required to fix the history, but it is not available."
        return 1
    fi
    lfs_activate || return 1
    oldtip=$(git rev-parse "refs/heads/$branch") || return 1
    backup="refs/gitup-backup/${branch}-$(date '+%Y%m%d%H%M%S')"
    git update-ref "$backup" "$oldtip" || return 1
    log_info "Moving those files into Git LFS (rewrites this folder's history; the old history stays at $backup)…"
    if ! git lfs migrate import --include-ref="refs/heads/$branch" --above="${GH_HARD_MB}MiB"; then
        git update-ref "$backup" "$oldtip" 2>/dev/null || true
        log_err "git lfs migrate failed; your original history is untouched (also saved at $backup)."
        return 1
    fi
    # `migrate` also rewrites other refs that pointed at the old tip — including our backup. Restore it.
    git update-ref "$backup" "$oldtip" || true
    log_info "Old history kept locally at $backup (free the space later with:  git update-ref -d $backup && git gc --prune=now)."
    add_note "moved big files in history to LFS"
    return 0
}

# ─── folder discovery ─────────────────────────────────────────────────────────
DEFAULT_SKIP_DIRS=(
    node_modules __pycache__ .venv venv env virtualenv
    dist build out target bin obj
    .idea .vscode .vs .history
    .cache .pytest_cache .mypy_cache .ruff_cache .tox
    vendor .next .nuxt .svelte-kit .turbo
)

is_skipped_dir() {
    local name="$1" skip
    local -a extra=()
    if [[ "$name" == .* ]]; then return 0; fi
    for skip in "${DEFAULT_SKIP_DIRS[@]}"; do
        if [[ "$name" == "$skip" ]]; then return 0; fi
    done
    if [[ -n "${GITUP_SKIP:-}" ]]; then
        IFS=' ,' read -r -a extra <<< "$GITUP_SKIP" || true
        if (( ${#extra[@]} )); then
            for skip in "${extra[@]}"; do
                if [[ "$name" == "$skip" ]]; then return 0; fi
            done
        fi
    fi
    return 1
}

# Fills ALL_DIRS with the direct subfolders of $PWD that should be processed.
enumerate_all_subfolders() {
    local d name
    ALL_DIRS=()
    for d in */; do
        [[ -d "$d" ]] || continue
        name="${d%/}"
        if [[ -L "$name" ]]; then
            log_warn "Skipping '$name' (symbolic link)."
            continue
        fi
        if is_skipped_dir "$name"; then
            log_warn "Skipping '$name' (build/dependency/ignored folder)."
            continue
        fi
        if [[ -z "$(ls -A "$name" 2>/dev/null)" ]]; then
            log_warn "Skipping '$name' (empty folder)."
            continue
        fi
        ALL_DIRS+=("$name")
    done
}

# Adds a folder (absolute path) to FOLDERS unless the same directory is already there.
add_folder() {
    local abs key s
    abs=$(cd -- "$1" 2>/dev/null && pwd) || return 0
    key=$(cd -- "$1" 2>/dev/null && pwd -P) || return 0
    if (( ${#SEEN[@]} )); then
        for s in "${SEEN[@]}"; do
            if [[ "$s" == "$key" ]]; then return 0; fi
        done
    fi
    SEEN+=("$key")
    FOLDERS+=("$abs")
}

# ─── per-folder work ──────────────────────────────────────────────────────────
# Returns 0 = done, 1 = failed, 2 = skipped (nothing to upload).
# true when the .git in $PWD was created by gitup.sh or by codebergup.sh
is_managed_repo() {
    [[ "$(git config --local --get gitup.managed 2>/dev/null || true)" == "true" ]] \
        || [[ "$(git config --local --get codebergup.managed 2>/dev/null || true)" == "true" ]]
}

process_dir_impl() {
    local dir="$1" phys branch gp excl parent err pat rel f msg risky slug
    local self_base tmp grep_rc
    local -a addargs=()
    RES_URL=""; RES_NOTE=""; SELF_REL=""; REMOTE_SETUP=0

    phys=$(pwd -P)

    # 1. repository ----------------------------------------------------------
    FRESH_REPO=0; OLD_ORIGIN=""; LFS_ALL=1
    if [[ -e .git && "$GIT_MODE" != "keep" ]]; then
        # A .git that gitup created earlier is simply updated; any other .git is replaced by
        # a fresh one (the old one is moved aside, not deleted).
        if [[ "$GIT_MODE" == "always" ]] || ! is_managed_repo; then
            OLD_ORIGIN=$(git config --local --get remote.origin.url 2>/dev/null || true)
            if retire_git_dir "$phys"; then
                log_warn "Replacing the existing .git with a fresh one. The old one is saved at: $BACKUP_PATH"
                add_note "new .git"
            else
                log_err "Could not move the old .git out of the way (read-only folder or disk?). Fix that, or use --keep-git to keep using it."
                return 1
            fi
        fi
    fi
    if [[ -e .git ]]; then
        if ! err=$(git rev-parse --git-dir 2>&1 >/dev/null); then
            log_err "'.git' exists but git cannot use it: $err"
            return 1
        fi
        log_info "Existing git repository."
    else
        parent=$(git rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -n "$parent" ]]; then
            log_warn "This folder sits inside another git repository ($parent) — creating a separate repository here."
        fi
        if ! git init -q; then log_err "git init failed."; return 1; fi
        # like `git branch -M main`: a repository made by gitup always starts on main
        git symbolic-ref HEAD refs/heads/main || return 1
        git config --local gitup.managed true || true
        FRESH_REPO=1
        log_ok "Initialised a new git repository."
        # an old remote that already lives on THIS account is kept; anything else is replaced
        if [[ -n "$OLD_ORIGIN" ]] && slug=$(github_slug "$OLD_ORIGIN"); then
            if [[ "$(printf '%s' "${slug%%/*}" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$GH_LOGIN" | tr '[:upper:]' '[:lower:]')" ]]; then
                git remote add origin "$OLD_ORIGIN" || true
            fi
        fi
    fi

    # 2. branch must be sane -------------------------------------------------
    if ! branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null); then
        log_err "HEAD is detached. Check out a branch first (e.g. 'git switch main') and re-run."
        return 1
    fi
    for gp in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
        if [[ -e "$(git rev-parse --git-path "$gp" 2>/dev/null)" ]]; then
            log_err "A merge/rebase/cherry-pick is in progress ($gp). Finish or abort it first."
            return 1
        fi
    done

    # 3. identity ------------------------------------------------------------
    ensure_git_identity || { log_err "Could not set a git identity."; return 1; }

    # 4. local-only excludes (never committed) --------------------------------
    excl=$(git rev-parse --git-path info/exclude 2>/dev/null || true)
    if [[ -z "$excl" ]]; then excl=".git/info/exclude"; fi

    for pat in .gitup-backups .codebergup-backups; do
        if [[ -d "$pat" ]]; then exclude_add "$excl" "/${pat}/" || true; fi
    done

    # 4a. running script: excluded only if it lives inside this repo
    case "$SELF_PATH" in
        "$phys"/*) SELF_REL="${SELF_PATH#"$phys"/}" ;;
    esac
    if [[ -n "$SELF_REL" ]]; then
        # An older gitup wrote an *unanchored* rule (just the file name), which also
        # hid same-named files in subfolders. Drop it; the anchored rule replaces it.
        self_base=$(basename -- "$SELF_REL")
        if grep -qxF -- "$self_base" "$excl" 2>/dev/null; then
            tmp="${excl}.gitup.$$"
            grep_rc=0
            grep -vxF -- "$self_base" "$excl" > "$tmp" 2>/dev/null || grep_rc=$?
            case $grep_rc in
                0) mv -f "$tmp" "$excl" ;;
                1) : > "$excl"; rm -f "$tmp" ;;
                *) rm -f "$tmp"; log_warn "Could not rewrite $excl (grep status $grep_rc)." ;;
            esac
            log_info "Removed an old unanchored exclude rule: $self_base"
        fi
        if exclude_add "$excl" "/$(gitignore_escape "$SELF_REL")"; then
            log_info "Not uploading the running script: $SELF_REL"
        fi
        # committed by an earlier run? untrack it
        if GIT_LITERAL_PATHSPECS=1 git ls-files --error-unmatch -- "$SELF_REL" >/dev/null 2>&1; then
            if GIT_LITERAL_PATHSPECS=1 git rm --cached -f -q -- "$SELF_REL"; then
                log_info "Untracked the running script (an earlier run had committed it): $SELF_REL"
            else
                log_warn "Could not untrack $SELF_REL"
            fi
        fi
    fi

    # 4b. sensible defaults for projects that have no .gitignore at all
    if [[ ! -e .gitignore && -z "${GITUP_NO_DEFAULT_IGNORE:-}" ]]; then
        if ! grep -qxF '# gitup: default ignores' "$excl" 2>/dev/null; then
            exclude_add "$excl" '# gitup: default ignores' || true
            for pat in .DS_Store Thumbs.db node_modules/ __pycache__/ '*.pyc' .venv/; do
                exclude_add "$excl" "$pat" || true
            done
            log_info "No .gitignore found — skipping node_modules, __pycache__, .venv, .DS_Store, Thumbs.db."
        fi
    fi

    # 5. large files -----------------------------------------------------------
    prepare_large_files || return 1

    # 6. stage -----------------------------------------------------------------
    addargs=(-A -- .)
    if (( ${#SKIP_BIG[@]} )); then
        for f in "${SKIP_BIG[@]}"; do addargs+=(":(exclude,literal)${f#./}"); done
    fi
    # (the running script needs no pathspec: its exclude rule + untracking above keep it out,
    #  and naming an *ignored* path in a pathspec would make `git add` abort)
    if ! git add "${addargs[@]}"; then
        log_err "git add failed."
        return 1
    fi

    # 7. heads-up about things people rarely want in a repo ---------------------
    # Newly added files only (already-tracked ones were decided on earlier runs).
    risky=$(git diff --cached --name-only --diff-filter=A 2>/dev/null \
            | grep -Ei '(^|/)(\.env|\.env\.[A-Za-z0-9_-]+|id_rsa|id_dsa|id_ecdsa|id_ed25519|[^/]*\.pem|[^/]*\.p12|[^/]*\.pfx|[^/]*\.key)$' \
            | grep -Eiv '\.(example|sample|template|dist)$' | head -n 5 || true)
    if [[ -n "$risky" ]]; then
        log_warn "These new files look like secrets/credentials:"
        printf '%s\n' "$risky" | while IFS= read -r f; do log_warn "    $f"; done
        if [[ "$VISIBILITY" == "public" ]]; then
            log_warn "New repositories are PUBLIC by default — anyone could read these files."
        fi
        if ! confirm "Upload them anyway?" n; then
            if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
                git reset -q || true
            else
                git rm -r -q --cached -f --ignore-unmatch -- . >/dev/null 2>&1 || true
            fi
            log_warn "Skipped '$dir'. Add those files to .gitignore and re-run (or use -y to upload anyway)."
            RES_NOTE="possible secrets — not uploaded"
            return 2
        fi
    fi
    risky=$(git diff --cached --raw --diff-filter=A 2>/dev/null | grep -E '^:[0-7]+ 160000 ' | cut -f2 | head -n 5 || true)
    if [[ -n "$risky" ]]; then
        log_warn "Nested git repositories were added as empty links (their files are NOT uploaded):"
        printf '%s\n' "$risky" | while IFS= read -r f; do log_warn "    $f"; done
    fi

    # 8. commit ----------------------------------------------------------------
    if git diff --cached --quiet; then
        log_info "No new changes to commit."
    else
        if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
            msg="Update from gitup.sh $(date '+%Y-%m-%d %H:%M:%S')"
        else
            msg="Initial commit"
        fi
        if ! git commit -q -m "$msg"; then
            log_err "git commit failed."
            return 1
        fi
        log_ok "Committed local changes."
    fi
    if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
        log_warn "Nothing to upload in '$dir' (empty, or everything is ignored) — skipped."
        RES_NOTE="nothing to upload"
        return 2
    fi

    # 9. remote + push ----------------------------------------------------------
    setup_remote "$dir" || return 1

    # Brand-new / switched remote: follow the usual `git branch -M main` convention.
    if (( REMOTE_SETUP )) && [[ "$branch" == "master" ]] && ! git show-ref --verify --quiet refs/heads/main; then
        if git branch -M main; then
            branch="main"
            log_info "Renamed local branch 'master' → 'main' for the new remote."
        fi
    fi

    adopt_remote_history "$branch"
    if is_github_url "$REMOTE_URL"; then
        fix_large_history "$branch" || return 1
    fi
    push_branch "$REMOTE_NAME" "$branch" || return 1
    if (( REMOTE_SETUP || FRESH_REPO )); then align_default_branch "$branch"; fi
    if [[ -z "$RES_NOTE" ]]; then RES_NOTE="updated"; fi
    log_ok "Done: $RES_URL"
    return 0
}

process_directory() {
    local dir="$1" prev="$PWD" rc=0
    RES_URL=""; RES_NOTE=""; FIRST_ERR=""
    if ! cd -- "$dir"; then
        log_err "Cannot enter '$dir'"
        return 1
    fi
    process_dir_impl "$dir" || rc=$?
    cd -- "$prev" 2>/dev/null || true
    return "$rc"
}

# ─── argument parsing & main ──────────────────────────────────────────────────
parse_args() {
    local got
    KEEP_GIT_FLAG=0; FRESH_FLAG=0
    while (( $# )); do
        case "$1" in
            -h|--help)    show_help; exit 0 ;;
            -y|--yes)     ASSUME_YES=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            --all)        WANT_ALL=1; shift ;;
            --public)     VISIBILITY="public"; shift ;;
            --private)    VISIBILITY="private"; shift ;;
            --safe|--no-force) FORCE_OVERWRITE=0; shift ;;
            --keep-git)   KEEP_GIT_FLAG=1; shift ;;
            --fresh)      FRESH_FLAG=1; shift ;;
            --folder|--folders)
                shift
                got=0
                while (( $# )) && [[ "$1" != -* ]]; do
                    REQUESTED+=("$1"); got=1; shift
                done
                if (( ! got )); then
                    die "--folder needs at least one directory (or 'all'). Folder names starting with '-' must be written as ./-name"
                fi ;;
            --folder=*)
                if [[ -z "${1#--folder=}" ]]; then die "--folder= needs a directory."; fi
                REQUESTED+=("${1#--folder=}"); shift ;;
            --)
                shift
                while (( $# )); do REQUESTED+=("$1"); shift; done ;;
            -*)
                die "Unknown option: $1 (try --help)" ;;
            *)
                REQUESTED+=("$1"); shift ;;
        esac
    done
}

validate_settings() {
    local re='^[0-9]+$'
    if ! [[ "$LFS_MB" =~ $re ]] || (( LFS_MB < 1 )); then die "GITUP_LFS_MB must be a positive whole number."; fi
    if ! [[ "$LFS_MAX_MB" =~ $re ]] || (( LFS_MAX_MB < 1 )); then die "GITUP_LFS_MAX_MB must be a positive whole number."; fi
    if ! [[ "$RETRIES" =~ $re ]] || (( RETRIES < 1 )); then die "GITUP_RETRIES must be a positive whole number."; fi
    if ! [[ "$RATE_RETRIES" =~ $re ]]; then die "GITUP_RATE_RETRIES must be a whole number (0 = don't wait)."; fi
    if ! [[ "$RATE_WAIT" =~ $re ]] || (( RATE_WAIT < 1 )); then die "GITUP_RATE_WAIT must be a positive whole number of seconds."; fi
    if ! [[ "$CREATE_DELAY" =~ $re ]]; then die "GITUP_CREATE_DELAY must be a whole number of seconds."; fi
    if (( FRESH_FLAG && KEEP_GIT_FLAG )); then die "--fresh and --keep-git cannot be combined."; fi
    if (( FRESH_FLAG && ! FORCE_OVERWRITE )); then die "--fresh and --safe cannot be combined."; fi
    if (( FRESH_FLAG )); then GIT_MODE="always"; fi
    if (( KEEP_GIT_FLAG || ! FORCE_OVERWRITE )); then GIT_MODE="keep"; fi
    if (( LFS_MB > GH_HARD_MB )); then
        log_warn "GITUP_LFS_MB=${LFS_MB} is above GitHub's ${GH_HARD_MB} MB file limit — using ${GH_HARD_MB}."
        LFS_MB=$GH_HARD_MB
    fi
}

build_folder_list() {
    local a d have_all=0 expanded=0
    local -a missing=()

    if (( ${#REQUESTED[@]} )); then
        for a in "${REQUESTED[@]}"; do
            if [[ "$a" == "all" ]]; then have_all=1; fi
        done
    fi

    if (( WANT_ALL || have_all )); then
        expanded=1
        log_info "Expanding 'all' — scanning $PWD for direct subfolders…"
        if (( have_all )) && [[ -d all ]]; then
            log_info "Note: a folder literally named 'all' exists too; use ./all to process only that one."
        fi
        enumerate_all_subfolders
        if (( ${#ALL_DIRS[@]} )); then
            for d in "${ALL_DIRS[@]}"; do add_folder "$d"; done
        fi
    fi

    if (( ${#REQUESTED[@]} )); then
        for a in "${REQUESTED[@]}"; do
            if [[ "$a" == "all" ]]; then continue; fi
            if [[ -z "$a" || ! -d "$a" ]]; then missing+=("$a"); continue; fi
            add_folder "$a"
        done
    fi
    if (( ${#missing[@]} )); then
        for a in "${missing[@]}"; do log_err "Not a directory: '$a'"; done
        die "Nothing was uploaded. Fix the folder name(s) above and re-run."
    fi

    if (( ! WANT_ALL && ! have_all && ${#REQUESTED[@]} == 0 )); then
        add_folder "$PWD"
    fi

    if (( ${#FOLDERS[@]} == 0 )); then
        if (( expanded )); then die "No subfolders to process in $PWD (all were empty or skipped)."; fi
        die "No folders to process."
    fi

    EXPANDED=$expanded
}

main() {
    local f i total rc failures=0 skipped=0 shown label
    EXPANDED=0
    parse_args "$@"
    validate_settings
    build_folder_list
    total=${#FOLDERS[@]}

    if (( DRY_RUN )); then
        log_info "Dry run — ${total} folder(s) would be processed (new repositories: ${VISIBILITY}):"
        for f in "${FOLDERS[@]}"; do
            if [[ -e "$f/.git" ]]; then
                if [[ "$GIT_MODE" == "keep" ]]; then
                    label="existing repo — kept as it is"
                elif [[ "$GIT_MODE" != "always" ]] && ( cd -- "$f" 2>/dev/null && is_managed_repo ); then
                    label="existing gitup/codebergup repo — updated"
                else
                    label="existing .git — replaced by a fresh one (old one saved aside)"
                fi
            else
                label="new repo: $(sanitize_repo_name "$(basename -- "$f")" || echo '(invalid name)')"
            fi
            log_info "  • $f   [$label]"
        done
        exit 0
    fi

    if (( EXPANDED && total > 5 )); then
        log_info "Will process ${total} folders:"
        shown=0
        for f in "${FOLDERS[@]}"; do
            if (( shown < 10 )); then
                log_info "  • $(basename -- "$f")"
                shown=$(( shown + 1 ))
            else
                log_info "  … and $(( total - shown )) more"
                break
            fi
        done
        if ! confirm "Proceed?" y; then
            log_warn "Aborted."
            exit 0
        fi
    fi

    if [[ ! -t 0 ]]; then export GIT_TERMINAL_PROMPT=0; fi
    export GIT_LFS_FORCE_PROGRESS=1
    TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/gitup.XXXXXX") || die "Cannot create a temporary file."

    ensure_dependencies
    ensure_auth
    load_github_identity
    log_info "Signed in to GitHub as ${GH_LOGIN}."

    i=0
    for f in "${FOLDERS[@]}"; do
        i=$(( i + 1 ))
        printf '\n' >&2
        log_info "[${i}/${total}] $(basename -- "$f")"
        rc=0
        process_directory "$f" || rc=$?
        SUM_DIRS+=("$(basename -- "$f")")
        case $rc in
            0) SUM_STATE+=("OK");   SUM_INFO+=("${RES_URL}  (${RES_NOTE})") ;;
            2) SUM_STATE+=("SKIP"); SUM_INFO+=("${RES_NOTE}"); skipped=$(( skipped + 1 )) ;;
            *) SUM_STATE+=("FAIL"); SUM_INFO+=("${FIRST_ERR:-see the messages above}")
               FAILED_DIRS+=("$f"); failures=$(( failures + 1 )) ;;
        esac
    done

    printf '\n' >&2
    log_info "Summary"
    for (( i = 0; i < total; i++ )); do
        case "${SUM_STATE[$i]}" in
            OK)   log_ok   "${SUM_DIRS[$i]}  →  ${SUM_INFO[$i]}" ;;
            SKIP) log_warn "${SUM_DIRS[$i]}  →  skipped (${SUM_INFO[$i]})" ;;
            *)    log_err  "${SUM_DIRS[$i]}  →  failed: ${SUM_INFO[$i]}" ;;
        esac
    done

    if (( failures > 0 )); then
        log_err "${failures} of ${total} folder(s) failed."
        log_info "After fixing the cause, re-run only the failed folders:"
        case "$0" in
            */*) printf '    %q --folder' "$0" >&2 ;;
            *)   printf '    bash %q --folder' "$0" >&2 ;;
        esac
        for f in "${FAILED_DIRS[@]}"; do
            case "$f" in
                "$PWD"/*) f="${f#"$PWD"/}" ;;
            esac
            printf ' %q' "$f" >&2
        done
        printf '\n' >&2
        exit 1
    fi
    log_ok "Done — $(( total - skipped )) of ${total} folder(s) uploaded."
}

main "$@"

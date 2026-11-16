#!/usr/bin/env bash
# codebergup.sh — create / update Codeberg repositories from local folders, with
#                 automatic Git LFS handling for large files. You log in with your
#                 Codeberg username and password (or an access token).
#
# Usage:
#   ./codebergup.sh                       process the current directory
#   ./codebergup.sh --folder DIR [DIR…]   process one or more directories
#   ./codebergup.sh --folder all          process every direct subfolder of $PWD
#   ./codebergup.sh --all                 same as `--folder all`
#
# Options:
#   -u, --user NAME  Codeberg username (otherwise you are asked)
#   -y, --yes        don't ask questions (confirmations, installs)
#   -n, --dry-run    only show which folders / repo names would be used
#       --private    create new repositories as private (default: public)
#       --public     create new repositories as public (this is the default)
#       --safe       never overwrite or rewrite anything: keep the existing .git, and
#                    stop when the Codeberg repo has different history
#       --keep-git   keep a folder's existing .git instead of replacing it
#       --fresh      always replace the folder's .git with a fresh one
#   -h, --help       show this help
#
# Login (nothing is stored on disk):
#   You are asked for username and password. For scripts set CODEBERG_USER and
#   CODEBERG_PASSWORD. Accounts with two-factor authentication need an access
#   token instead of the password (CODEBERG_TOKEN, or type it at the prompt).
#
# Environment:
#   CODEBERG_USER, CODEBERG_PASSWORD, CODEBERG_TOKEN   login without prompts
#   CODEBERGUP_YES=1             same as --yes
#   CODEBERGUP_SKIP="a b"        extra directory names to skip in `--all` mode
#   CODEBERGUP_LFS_MB=25         files bigger than this go to Git LFS   (max 100)
#   CODEBERGUP_LFS_MAX_MB=1536   files bigger than this can't be uploaded at all
#   CODEBERGUP_RETRIES=3         attempts for network operations
#   CODEBERGUP_RATE_RETRIES=4    waits when Codeberg rate-limits repo creation (0 = don't wait)
#   CODEBERGUP_RATE_WAIT=60      first wait in seconds (doubles each time)
#   CODEBERGUP_CREATE_DELAY=2    pause in seconds between repository creations
#   CODEBERGUP_PKG_MANAGER=NAME  force apt-get|dnf|yum|pacman|zypper|apk|xbps-install|brew
#   CODEBERGUP_NO_DEFAULT_IGNORE=1   don't add default ignores to repos w/o .gitignore
#
# Self-exclusion:
#   The *currently running* script is excluded from a push only when it lives
#   inside the repo being pushed. Same-named files elsewhere (e.g. in a
#   subfolder) are pushed normally. Renaming the script is fully supported.
#
# Works on any Linux distro (apt, dnf/yum, pacman, zypper, apk, xbps) and on
# macOS (Homebrew), including the stock bash 3.2. Needs git, curl and jq.

# ─── guards (written in plain POSIX until we know we're in bash) ──────────────
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: codebergup.sh needs bash — run it as: bash $0" >&2
    exit 1
fi

# Refuse to be sourced. Done BEFORE touching shell options.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf 'Error: run this script as ./codebergup.sh or bash codebergup.sh — do not source it.\n' >&2
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
CB_HOST="${CODEBERGUP_HOST:-codeberg.org}"  # other Forgejo/Gitea hosts: untested
CB_SCHEME="${CODEBERGUP_SCHEME:-https}"
CB_URL="${CB_SCHEME}://${CB_HOST}"
CB_API="${CB_URL}/api/v1"
CB_HARD_MB=100                              # files above this must go through LFS
LFS_MB="${CODEBERGUP_LFS_MB:-25}"
LFS_MAX_MB="${CODEBERGUP_LFS_MAX_MB:-1536}" # Codeberg: LFS+packages+attachments ≈ 1.5 GiB before you must ask
RETRIES="${CODEBERGUP_RETRIES:-3}"
ASSUME_YES=0
if [[ "${CODEBERGUP_YES:-0}" == "1" ]]; then ASSUME_YES=1; fi
DRY_RUN=0
WANT_ALL=0
FORCE_OVERWRITE=1                           # --safe turns it off
GIT_MODE="auto"                             # auto | keep (--keep-git, --safe) | always (--fresh)
RATE_RETRIES="${CODEBERGUP_RATE_RETRIES:-4}" # waits when Codeberg throttles repo creation
RATE_WAIT="${CODEBERGUP_RATE_WAIT:-60}"     # first wait in seconds; doubles each time
CREATE_DELAY="${CODEBERGUP_CREATE_DELAY:-2}" # pause between repository creations
RATE_BLOCKED=0; LAST_CREATE=0
FRESH_REPO=0; OLD_ORIGIN=""; BACKUP_PATH=""; LFS_ALL=1; TREE_MB=0
VISIBILITY="public"                         # new repos; --private switches it
REMOTE_DEFAULT="codeberg"
REQUESTED=()

CB_USER_ARG=""; CB_USER=""; CB_SECRET=""
CB_LOGIN=""; CB_NAME=""; CB_EMAIL=""
FOLDERS=(); SEEN=(); ALL_DIRS=(); SKIP_BIG=()
RES_URL=""; RES_NOTE=""; SELF_REL=""
SUM_DIRS=(); SUM_STATE=(); SUM_INFO=(); FAILED_DIRS=()
FIRST_ERR=""; REMOTE_SETUP=0; REMOTE_NAME="$REMOTE_DEFAULT"; REMOTE_URL=""
WORK_DIR=""; TMP_FILE=""
API_CODE=""; API_BODY=""; API_HDRS=""; API_ERR=""; REPO_JSON=""

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

# Every git command ignores saved credential helpers: an old stored password for this host
# would otherwise win over the login you typed. (Git then asks our private askpass helper.)
git() { command git -c credential.helper= "$@"; }

cleanup() {
    if [[ -n "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
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
codebergup.sh — create / update Codeberg repositories from local folders, with
automatic Git LFS handling for large files. Log in with your Codeberg username
and password (or an access token).

Usage:
  ./codebergup.sh                       process the current directory
  ./codebergup.sh --folder DIR [DIR…]   process one or more directories
  ./codebergup.sh --folder all          process every direct subfolder of $PWD
  ./codebergup.sh --all                 same as `--folder all`
  ./codebergup.sh DIR [DIR…]            shorthand for --folder

Options:
  -u, --user NAME  Codeberg username (otherwise you are asked)
  -y, --yes        don't ask questions (confirmations, installs)
  -n, --dry-run    only show which folders / repo names would be used
      --private    create new repositories as private (default: public)
      --public     create new repositories as public (this is the default)
      --safe       never overwrite or rewrite anything: keep the existing .git, and
                   stop when the Codeberg repo has different history
      --keep-git   keep a folder's existing .git instead of replacing it
      --fresh      always replace the folder's .git with a fresh one
  -h, --help       show this help

Login:
  You are asked for your Codeberg username and password once per run (the
  password is hidden while you type, and is never written to disk or into a
  repository). For scripts: CODEBERG_USER and CODEBERG_PASSWORD.
  Accounts with two-factor authentication must use an access token instead of
  the password: https://codeberg.org/user/settings/applications
  (permissions: repository → read and write, user → read).

Environment:
  CODEBERG_USER, CODEBERG_PASSWORD, CODEBERG_TOKEN   login without prompts
  CODEBERGUP_YES=1             same as --yes
  CODEBERGUP_SKIP="a b"        extra directory names to skip in `--all` mode
  CODEBERGUP_LFS_MB=25         files bigger than this go to Git LFS (max 100)
  CODEBERGUP_LFS_MAX_MB=1536   files bigger than this can't be uploaded at all
  CODEBERGUP_RETRIES=3         attempts for network operations
  CODEBERGUP_RATE_RETRIES=4    waits when Codeberg rate-limits repo creation (0 = don't wait)
  CODEBERGUP_RATE_WAIT=60      first wait in seconds (doubles each time)
  CODEBERGUP_CREATE_DELAY=2    pause in seconds between repository creations
  CODEBERGUP_PKG_MANAGER=NAME  force apt-get|dnf|yum|pacman|zypper|apk|xbps-install|brew
  CODEBERGUP_NO_DEFAULT_IGNORE=1   don't add default ignores to repos w/o .gitignore

How it works:
  • Each folder becomes its own repository, named after the folder
    (spaces → '-', unsupported characters removed).
  • A folder's old .git is replaced by a fresh one (the old one is MOVED to
    <parent>/.codebergup-backups/, not deleted), then it runs the equivalent of
    `git remote add codeberg …; git branch -M main; git push -u codeberg main`.
    Repositories codebergup (or gitup.sh) created itself are simply updated on
    later runs. (`--keep-git` keeps your own .git as it is.)
  • The remote is called `codeberg`, so a folder can also keep a GitHub remote
    (gitup.sh) without the two tools getting in each other's way.
  • The remote is always YOUR account's repo named after the folder, even if
    the old .git pointed at another account.
  • If that repository already exists, the folder's content is put on top of
    its history (nothing is force-pushed; files that are gone locally are
    removed). `--safe` stops instead.
  • If Codeberg rate-limits repository creation, codebergup waits and retries.
  • Files over CODEBERGUP_LFS_MB are stored with Git LFS automatically.
  • A repo without a .gitignore skips node_modules, __pycache__, .venv,
    .DS_Store and Thumbs.db (local exclude only; nothing is added to the repo).
  • In `--all` mode hidden folders, symlinks, empty folders and common
    build/dependency folders (node_modules, .venv, dist, build, target, …)
    are skipped.  Naming a folder explicitly always processes it.
  • A folder literally called `all` can be processed with `--folder ./all`.

Codeberg's guidance on size: ask for extra resources before using more than
750 MiB of Git storage, or 1.5 GiB of LFS/packages/attachments together.
Private repositories get only 100 MB by default. Repositories per account: 100.

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
    if [[ -n "${CODEBERGUP_PKG_MANAGER:-}" ]]; then
        printf '%s\n' "$CODEBERGUP_PKG_MANAGER"
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

# Distro package name for a tool (git, curl and jq are called the same everywhere).
pkg_name_for() { echo "$2"; }

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

print_manual_hint() {
    case "$1" in
        git)
            if [[ "$(uname -s)" == "Darwin" ]]; then
                log_err "Install git with:  xcode-select --install   (or: brew install git)"
            else
                log_err "Install git with your package manager, then re-run."
            fi ;;
        curl)    log_err "Install curl with your package manager, then re-run." ;;
        jq)      log_err "Install jq with your package manager (https://jqlang.org), then re-run." ;;
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
    if ! command_exists curl; then missing+=("curl"); fi
    if ! command_exists jq; then missing+=("jq"); fi
    if (( ${#missing[@]} == 0 )); then
        log_ok "git, curl and jq are installed."
        return 0
    fi
    log_warn "Missing dependencies: ${missing[*]}"
    if ! confirm "Install them now using your package manager? (you may be asked for your password)" n; then
        die "${missing[*]} required. Aborting."
    fi
    for tool in "${missing[@]}"; do
        install_tool "$tool" || die "Installation of '$tool' failed."
    done
    git_usable || die "git is still not usable after installation."
    command_exists curl || die "curl is still not available after installation."
    command_exists jq || die "jq is still not available after installation."
    log_ok "Dependencies installed."
}

# ─── Codeberg API & login ─────────────────────────────────────────────────────
cfg_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

jq_get() { jq -r "$2 // empty" "$1" 2>/dev/null || true; }

# api METHOD PATH [JSON-BODY]
# Sets API_CODE (HTTP status; 000 = no answer), API_BODY / API_HDRS (response files).
# The login reaches curl through its config on stdin, so it never appears in `ps`.
api() {
    local method="$1" path="$2" data="${3:-}" attempt=1 rc delay
    local -a args
    while true; do
        args=(-sS --connect-timeout 20 --max-time 120 -o "$API_BODY" -D "$API_HDRS" -w '%{http_code}' \
              -X "$method" -H 'Accept: application/json')
        if [[ -n "$data" ]]; then args+=(-H 'Content-Type: application/json' --data-binary "$data"); fi
        : > "$API_BODY"; : > "$API_HDRS"; : > "$API_ERR"
        rc=0
        API_CODE=$(printf 'user = "%s:%s"\n' "$(cfg_escape "$CB_USER")" "$(cfg_escape "$CB_SECRET")" \
                   | curl "${args[@]}" -K - "${CB_API}${path}" 2>"$API_ERR") || rc=$?
        if (( rc != 0 )) || [[ ! "$API_CODE" =~ ^[0-9]{3}$ ]]; then API_CODE="000"; fi
        case "$API_CODE" in
            000|502|503|504)
                if (( attempt < RETRIES )); then
                    delay=$(( attempt * 3 ))
                    attempt=$(( attempt + 1 ))
                    sleep "$delay"
                    continue
                fi ;;
        esac
        return 0
    done
}

# One short line describing the last API answer.
api_message() {
    local m=""
    if [[ -s "$API_BODY" ]]; then m=$(jq_get "$API_BODY" '.message'); fi
    if [[ -z "$m" && "$API_CODE" == "000" && -s "$API_ERR" ]]; then m=$(head -n 1 "$API_ERR"); fi
    if [[ -z "$m" ]]; then m="HTTP ${API_CODE}"; fi
    m="${m%%$'\n'*}"
    if (( ${#m} > 220 )); then m="${m:0:220}…"; fi
    printf '%s' "$m"
}

# Git asks a tiny private helper for the login, so it is never put in a URL or in .git/config.
setup_git_credentials() {
    local askpass="$WORK_DIR/askpass.sh"
    cat > "$askpass" <<'EOF'
#!/bin/sh
case "$1" in
    *sername*) printf '%s\n' "$CODEBERGUP_ASK_USER" ;;
    *)         printf '%s\n' "$CODEBERGUP_ASK_SECRET" ;;
esac
EOF
    chmod 700 "$askpass" || die "Cannot prepare the git login helper."
    export GIT_ASKPASS="$askpass" CODEBERGUP_ASK_USER="$CB_USER" CODEBERGUP_ASK_SECRET="$CB_SECRET"
    export GIT_TERMINAL_PROMPT=0
    unset SSH_ASKPASS 2>/dev/null || true
}

ensure_auth() {
    local interactive=0 attempt=0 fixed_user=0 fixed_secret=0 login name why
    if [[ -t 0 ]]; then interactive=1; fi
    CB_USER="${CB_USER_ARG:-${CODEBERG_USER:-}}"
    CB_SECRET="${CODEBERG_TOKEN:-${CODEBERG_PASSWORD:-}}"
    if [[ -n "$CB_USER" ]]; then fixed_user=1; fi
    if [[ -n "$CB_SECRET" ]]; then fixed_secret=1; fi
    while true; do
        attempt=$(( attempt + 1 ))
        if [[ -z "$CB_USER" || -z "$CB_SECRET" ]]; then
            if (( ! interactive )); then
                die "No Codeberg login and no terminal to ask for it. Set CODEBERG_USER and CODEBERG_PASSWORD (or CODEBERG_TOKEN)."
            fi
            if (( attempt == 1 )); then log_info "Log in to ${CB_HOST} (nothing is stored)."; fi
            if [[ -z "$CB_USER" ]]; then
                read -r -p "Codeberg username: " CB_USER || true
            fi
            if [[ -z "$CB_SECRET" ]]; then
                IFS= read -r -s -p "Password for ${CB_USER} (or an access token): " CB_SECRET || true
                printf '\n' >&2
            fi
        fi
        if [[ -z "$CB_USER" || -z "$CB_SECRET" ]]; then die "A username and a password are required."; fi

        api GET /user
        case "$API_CODE" in
            200) break ;;
            000) die "Could not reach ${CB_HOST}: $(api_message)" ;;
            401|403)
                why="Codeberg rejected that username/password."
                if grep -qi 'otp' "$API_HDRS" 2>/dev/null; then
                    why="This account uses two-factor authentication, so the password alone is not accepted."
                fi
                log_err "$why"
                log_info "Two-factor accounts: use an access token as the password — create one at ${CB_URL}/user/settings/applications (permissions: repository → read and write, user → read)."
                if (( ! interactive || attempt >= 3 || (fixed_user && fixed_secret) )); then
                    die "Login failed."
                fi
                if (( ! fixed_secret )); then CB_SECRET=""; fi
                if (( ! fixed_user )); then CB_USER=""; fi
                fixed_user=0; fixed_secret=0 ;;
            429) die "Codeberg is rate-limiting requests from you right now. Wait a few minutes and re-run." ;;
            *)   die "Codeberg answered: $(api_message)" ;;
        esac
    done

    login=$(jq_get "$API_BODY" '.login')
    name=$(jq_get "$API_BODY" '.full_name')
    if [[ -z "$login" ]]; then die "Codeberg answered, but did not say who you are."; fi
    CB_LOGIN="$login"
    CB_NAME="${name:-$login}"
    CB_EMAIL="${CB_LOGIN}@noreply.${CB_HOST%%:*}"
    CB_USER="$CB_LOGIN"
    setup_git_credentials
    log_ok "Signed in to Codeberg as ${CB_LOGIN}."
}

ensure_git_identity() {
    local n e
    n=$(git config user.name  2>/dev/null || true)
    e=$(git config user.email 2>/dev/null || true)
    if [[ -n "$n" && -n "$e" ]]; then return 0; fi
    if [[ -z "$n" ]]; then git config user.name  "$CB_NAME"  || return 1; fi
    if [[ -z "$e" ]]; then git config user.email "$CB_EMAIL" || return 1; fi
    log_info "No git identity configured — using your Codeberg identity for this repo."
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
        log_warn "'git lfs install --local' reported a problem (existing hooks?) — codebergup will upload LFS objects explicitly."
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
        if file_over_mb "$f" "$CB_HARD_MB"; then hard=1; fi
    done < <(find . -name .git -prune -o -type f -size "+${LFS_MB}M" -print0 2>/dev/null)

    if (( ${#SKIP_BIG[@]} )); then
        for f in "${SKIP_BIG[@]}"; do
            log_warn "Too large for Codeberg's default allowance (over ${LFS_MAX_MB} MB, $(file_size_mb "$f") MB) — NOT uploaded: ${f#./}"
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
                log_err "Files over ${CB_HARD_MB} MB should not be pushed to Codeberg without Git LFS:"
                for f in "${candidates[@]}"; do
                    if file_over_mb "$f" "$CB_HARD_MB"; then log_err "  ${f#./}"; fi
                done
                return 1
            fi
            log_warn "Git LFS unavailable — files over ${LFS_MB} MB will be committed normally."
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
    if grep -Eqi 'non-fast-forward|fetch first|tip of your current branch is behind' "$f"; then
        if (( FORCE_OVERWRITE )); then
            log_err "The remote branch has different history and codebergup could not overwrite it."
        else
            log_err "The remote branch has different history (--safe mode: nothing was overwritten)."
            log_err "Re-run without --safe to overwrite it, or merge first:"
            log_err "    git pull --no-rebase --allow-unrelated-histories ${REMOTE_NAME} ${branch}"
        fi
    elif grep -Eqi 'Authentication failed|Invalid username or password|returned error: 401|HTTP 401|could not read (Username|Password)|two-factor|2FA' "$f"; then
        log_err "Codeberg rejected your login (user ${CB_LOGIN}). Two-factor accounts must use an access token as the password:"
        log_err "    ${CB_URL}/user/settings/applications  (permissions: repository → read and write)"
    elif grep -Eqi 'returned error: 403|Permission denied|not allowed to push|do not have (write )?(access|permission)' "$f"; then
        log_err "No write access to this repository with your login (${CB_LOGIN}). It may belong to someone else, or be archived."
    elif grep -Eqi 'archived|read-only mirror|is a mirror' "$f"; then
        log_err "The repository is archived or a mirror (read-only). Change that in its Settings on Codeberg, then re-run."
    elif grep -Eqi 'protected branch|protected ref|branch.*protected|pre-receive hook declined|push rule' "$f"; then
        log_err "A branch protection or push rule blocks this push. Change it in the repository's Settings → Branches, then re-run."
    elif grep -Eqi 'Request Entity Too Large|returned error: 413|HTTP 413|payload too large|too large|exceeds.*(limit|size)|file size' "$f"; then
        log_err "Codeberg refused the upload because something was too big."
        log_err "Lower CODEBERGUP_LFS_MB (for example 10) so more files go through Git LFS. For big files already in old commits:"
        log_err "    git lfs migrate import --include-ref=refs/heads/${branch} --above=${CB_HARD_MB}MiB"
    elif grep -Eqi 'quota|storage limit|limit exceeded|LFS.*(limit|exceeded|full)|No space left' "$f"; then
        log_err "Codeberg's storage limit is reached. Codeberg asks you to request more resources before using over"
        log_err "750 MiB of Git storage or 1.5 GiB of LFS/packages/attachments:  https://codeberg.org/Codeberg-e.V./requests"
    elif grep -Eqi 'Too Many Requests|returned error: 429|HTTP 429' "$f"; then
        log_err "Codeberg is rate-limiting you. Wait a few minutes, then re-run."
    elif grep -Eqi 'Repository not found|does not appear to be a git repository|returned error: 404' "$f"; then
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
        # Not used after adopting Codeberg's history: those objects are already on the server.
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
        *.wiki|*.rss|*.atom) n="${n%.*}-${n##*.}" ;;      # endings Forgejo reserves
    esac
    case "$n" in
        *[A-Za-z0-9]*) ;;       # needs at least one letter or digit
        *) return 1 ;;
    esac
    printf '%s' "$n"
}

cb_host_re() { printf '%s' "${CB_HOST%%:*}" | sed -e 's/\./\\./g'; }

web_url() {
    local re
    re=$(cb_host_re)
    printf '%s' "$1" | sed -E -e "s#^git@${re}:#${CB_URL}/#" \
                              -e "s#^ssh://git@${re}(:[0-9]+)?/#${CB_URL}/#" \
                              -e 's#\.git$##'
}

# Prints OWNER/NAME for a remote URL on this Codeberg host (https, ssh, scp-style); fails otherwise.
cb_slug() {
    local re s
    re=$(cb_host_re)
    s=$(printf '%s' "$1" | sed -E -e "s#^(https?|ssh|git)://([^/@]+@)?${re}(:[0-9]+)?/##" \
                                  -e "s#^[^@/:]+@${re}:##" -e 's#\.git/?$##' -e 's#/+$##')
    case "$s" in
        *:*|*/*/*|/*|*/|'') return 1 ;;
        */*)                printf '%s' "$s" ;;
        *)                  return 1 ;;
    esac
}

is_cb_url() { cb_slug "$1" >/dev/null 2>&1; }

# Can the logged-in account push to OWNER/NAME?  Prints yes | no | missing | unknown,
# or "error: …" (and returns 1) when Codeberg could not be asked.
repo_access_state() {
    local push
    api GET "/repos/$1"
    case "$API_CODE" in
        200)
            # (jq's `//` would turn `false` into "nothing", so test the value explicitly)
            push=$(jq -r 'if .permissions.push == true then "true" elif .permissions.push == false then "false" else "unknown" end' "$API_BODY" 2>/dev/null || echo unknown)
            case "$push" in
                true)  echo yes ;;
                false) echo no ;;
                *)     echo unknown ;;
            esac ;;
        404)     echo missing ;;
        401|403) echo no ;;
        *)       printf 'error: %s\n' "$(api_message)"; return 1 ;;
    esac
}

# Codeberg may throttle bursts of repository creation; keep a small gap between them.
pace_creation() {
    local now gap
    if (( CREATE_DELAY > 0 && LAST_CREATE > 0 )); then
        now=$(date +%s)
        gap=$(( LAST_CREATE + CREATE_DELAY - now ))
        if (( gap > 0 )); then sleep "$gap"; fi
    fi
}

# Creates CB_LOGIN/NAME, waiting out rate limits. On success the repo JSON is in $REPO_JSON.
# Returns 0 = created, 1 = failed, 3 = it already exists.
create_cb_repo() {
    local name="$1" priv="false" tries=0 wait="$RATE_WAIT" now_wait ra msg body limited
    if [[ "$VISIBILITY" == "private" ]]; then priv="true"; fi
    body=$(jq -n -c --arg n "$name" --argjson p "$priv" '{name:$n, private:$p, default_branch:"main"}') || return 1
    while true; do
        pace_creation
        api POST /user/repos "$body"
        LAST_CREATE=$(date +%s)
        msg=$(api_message)
        limited=0
        case "$API_CODE" in
            201) cp "$API_BODY" "$REPO_JSON"; RATE_BLOCKED=0; return 0 ;;
            409) return 3 ;;
            429) limited=1 ;;
            403)
                case "$msg" in
                    *"limit of"*)
                        log_err "Your Codeberg account has reached its repository limit (${msg}). Ask for more at https://codeberg.org/Codeberg-e.V./requests"
                        return 1 ;;
                    *[Rr]ate*limit*|*"too many"*|*"Too many"*) limited=1 ;;
                esac ;;
        esac
        if (( ! limited )); then
            case "$msg" in
                *"already exist"*) return 3 ;;
            esac
            log_err "Could not create repository '$name': $msg"
            return 1
        fi
        if (( RATE_BLOCKED || tries >= RATE_RETRIES )); then
            RATE_BLOCKED=1
            log_err "Codeberg is temporarily blocking repository creation for your account (rate limit) — wait a while, then re-run."
            log_info "This is Codeberg-side throttling, not a problem with this folder. Folders whose repository already exists are not affected."
            return 1
        fi
        tries=$(( tries + 1 ))
        now_wait="$wait"
        ra=$(sed -n -E 's/^[Rr]etry-[Aa]fter:[[:space:]]*([0-9]+).*/\1/p' "$API_HDRS" | head -n 1)
        if [[ -n "$ra" ]] && (( ra >= 1 )); then
            now_wait=$ra
            if (( now_wait > 600 )); then now_wait=600; fi
        fi
        log_warn "Codeberg is rate-limiting repository creation — waiting ${now_wait}s, then retrying (${tries}/${RATE_RETRIES}). Ctrl-C stops."
        sleep "$now_wait"
        wait=$(( wait * 2 ))
        if (( wait > 600 )); then wait=600; fi
    done
}

# Makes sure CB_LOGIN/NAME exists on Codeberg (creating it if needed).
# Sets REMOTE_URL and RES_URL.
ensure_cb_repo() {
    local repo_name="$1" crc pass found=0
    # shellcheck disable=SC2034  # two passes: the second one re-reads a repo that appeared meanwhile
    for pass in 1 2; do
        api GET "/repos/$CB_LOGIN/$repo_name"
        case "$API_CODE" in
            200)
                cp "$API_BODY" "$REPO_JSON"
                if (( FORCE_OVERWRITE )); then
                    log_warn "Codeberg repo '$CB_LOGIN/$repo_name' already exists — its content will be replaced with this folder's."
                else
                    log_warn "Codeberg repo '$CB_LOGIN/$repo_name' already exists — attaching to it."
                fi
                add_note "existing repo"
                found=1; break ;;
            404) ;;
            *)
                log_err "Could not check Codeberg for '$repo_name': $(api_message)"
                return 1 ;;
        esac
        log_info "Creating ${VISIBILITY} Codeberg repository '$repo_name'…"
        crc=0
        create_cb_repo "$repo_name" || crc=$?
        if (( crc == 0 )); then
            log_ok "Created repository $CB_LOGIN/$repo_name (${VISIBILITY})."
            add_note "created"
            if [[ "$VISIBILITY" == "private" ]] && (( TREE_MB > 100 )); then
                log_warn "Codeberg gives private repositories only 100 MB by default (this folder is ~${TREE_MB} MB); request more at https://codeberg.org/Codeberg-e.V./requests"
            fi
            found=1; break
        fi
        if (( crc != 3 )); then return 1; fi
        # it appeared in the meantime (or differs only in letter case): look it up again
    done
    if (( ! found )); then
        log_err "Codeberg says '$repo_name' already exists, but it can't be read with your login (${CB_LOGIN})."
        return 1
    fi
    REMOTE_URL=$(jq_get "$REPO_JSON" '.clone_url')
    if [[ -z "$REMOTE_URL" ]]; then
        log_err "Codeberg did not return a clone URL for '$repo_name'."
        return 1
    fi
    RES_URL=$(jq_get "$REPO_JSON" '.html_url')
    if [[ -z "$RES_URL" ]]; then RES_URL=$(web_url "$REMOTE_URL"); fi
    return 0
}

# Chooses the remote to use: `codeberg`, else the first remote that lives on this host.
# Sets REMOTE_NAME and REMOTE_URL (empty URL = none yet).
pick_cb_remote() {
    local r u
    REMOTE_NAME="$REMOTE_DEFAULT"
    REMOTE_URL=$(git config --get "remote.${REMOTE_NAME}.url" 2>/dev/null || true)
    if [[ -n "$REMOTE_URL" ]]; then return 0; fi
    while IFS= read -r r; do
        if [[ -z "$r" ]]; then continue; fi
        u=$(git config --get "remote.${r}.url" 2>/dev/null || true)
        if is_cb_url "$u"; then
            REMOTE_NAME="$r"; REMOTE_URL="$u"
            return 0
        fi
    done < <(git remote 2>/dev/null)
    return 0
}

# Prints the URL of an existing remote that already belongs to THIS account (if any).
own_cb_remote_url() {
    local r u slug
    while IFS= read -r r; do
        if [[ -z "$r" ]]; then continue; fi
        u=$(git config --get "remote.${r}.url" 2>/dev/null || true)
        if slug=$(cb_slug "$u"); then
            if [[ "$(printf '%s' "${slug%%/*}" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$CB_LOGIN" | tr '[:upper:]' '[:lower:]')" ]]; then
                printf '%s' "$u"
                return 0
            fi
        fi
    done < <(git remote 2>/dev/null)
    return 0
}

# Decides which remote to push to. Sets REMOTE_NAME, REMOTE_URL, RES_URL,
# REMOTE_SETUP (1 when the remote was created / attached / switched this run).
setup_remote() {
    local dir="$1" base repo_name slug state why old_slug="" switch=0 r
    REMOTE_SETUP=0
    pick_cb_remote

    if [[ -n "$REMOTE_URL" ]]; then
        RES_URL=$(web_url "$REMOTE_URL")
        if ! slug=$(cb_slug "$REMOTE_URL"); then
            log_info "Using existing remote '$REMOTE_NAME' → $REMOTE_URL"
            return 0
        fi
        if ! state=$(repo_access_state "$slug"); then
            log_err "Could not check '$slug' on Codeberg: ${state#error: }"
            return 1
        fi
        case "$state" in
            yes|unknown)
                log_info "Using existing remote '$REMOTE_NAME' → $REMOTE_URL"
                return 0 ;;
            missing) why="does not exist (deleted, or private to another account)" ;;
            *)       why="can't be written to with your current Codeberg login (${CB_LOGIN})" ;;
        esac
        log_warn "Remote '$REMOTE_NAME' ($slug) $why — switching it to your own account."
        old_slug="$slug"
        switch=1
    fi

    base=$(basename -- "$dir")
    if ! repo_name=$(sanitize_repo_name "$base"); then
        log_err "Cannot derive a valid Codeberg repository name from folder '$base' (use letters, digits, '.', '_' or '-')."
        return 1
    fi
    if [[ "$repo_name" != "$base" ]]; then
        log_warn "Repository name sanitised: '$base' → '$repo_name'."
    fi

    ensure_cb_repo "$repo_name" || return 1

    if (( switch )); then
        git remote set-url "$REMOTE_NAME" "$REMOTE_URL" || return 1
        # remote-tracking refs of the old repository are meaningless now
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

# After (re)pointing a remote, make Codeberg's default branch the one we pushed.
align_default_branch() {
    local branch="$1" slug cur
    slug=$(cb_slug "$REMOTE_URL") || return 0
    api GET "/repos/$slug"
    if [[ "$API_CODE" != "200" ]]; then return 0; fi
    cur=$(jq_get "$API_BODY" '.default_branch')
    if [[ -n "$cur" && "$cur" != "$branch" ]]; then
        api PATCH "/repos/$slug" "$(jq -n -c --arg b "$branch" '{default_branch:$b}')"
        case "$API_CODE" in
            200|201) log_info "Codeberg default branch switched: $cur → $branch" ;;
            *)       log_warn "Could not switch the Codeberg default branch to '$branch' (it is '$cur')." ;;
        esac
    fi
    return 0
}

# Moves the folder's own .git out of the way (it is never deleted) so a fresh repository
# can be created. Sets BACKUP_PATH. Backups live next to the project folders, in
# <parent>/.codebergup-backups/ (same filesystem → instant); falls back to ~/.cache.
retire_git_dir() {
    local phys="$1" stamp base dest root
    stamp=$(date '+%Y%m%d-%H%M%S')
    base=$(basename -- "$phys")
    root="$(dirname -- "$phys")/.codebergup-backups"
    dest="$root/${base}-${stamp}.git"
    if mkdir -p -- "$root" 2>/dev/null && mv -- .git "$dest" 2>/dev/null; then
        BACKUP_PATH="$dest"; return 0
    fi
    root="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/codebergup-backups"
    dest="$root/${base}-${stamp}.git"
    if mkdir -p -- "$root" 2>/dev/null && mv -- .git "$dest" 2>/dev/null; then
        BACKUP_PATH="$dest"; return 0
    fi
    return 1
}

# A fresh repository knows nothing about what is already on Codeberg. If the repository there
# already has this branch with different history, put this folder's content on top of it: a
# normal fast-forward push, nothing is force-pushed, the old history stays, and files that no
# longer exist locally are removed (the remote ends up matching the folder).
adopt_remote_history() {
    local branch="$1" ref rtip new msg old backup
    if (( ! FORCE_OVERWRITE )); then return 0; fi
    if (( ! FRESH_REPO && ! REMOTE_SETUP )); then return 0; fi
    if ! git ls-remote --exit-code --heads "$REMOTE_NAME" "$branch" >/dev/null 2>&1; then
        return 0        # no such branch there yet (or unreachable: the push will explain)
    fi
    ref="refs/remotes/$REMOTE_NAME/$branch"
    if ! run_with_retry "fetch" git fetch --no-tags --quiet "$REMOTE_NAME" "+refs/heads/$branch:$ref"; then
        log_warn "Could not read the existing '$branch' from Codeberg — trying a direct push instead."
        return 0
    fi
    rtip=$(git rev-parse --verify -q "$ref^{commit}") || return 0
    LFS_ALL=0                                       # remote-tracking refs are fresh now
    if git merge-base --is-ancestor "$rtip" HEAD 2>/dev/null; then
        return 0                                    # ordinary fast-forward
    fi
    log_info "Codeberg already has '$branch' with different history — putting this folder's content on top of it."
    if (( ! FRESH_REPO )); then
        old=$(git rev-parse HEAD)
        backup="refs/codebergup-backup/${branch}-$(date '+%Y%m%d%H%M%S')"
        if git update-ref "$backup" "$old"; then
            log_info "Your previous local '$branch' stays reachable as $backup"
        fi
    fi
    if [[ "$(git rev-parse "$rtip^{tree}")" == "$(git rev-parse 'HEAD^{tree}')" ]]; then
        git update-ref "refs/heads/$branch" "$rtip" || return 0
        add_note "already identical on Codeberg"
        return 0
    fi
    msg="Update from codebergup.sh $(date '+%Y-%m-%d %H:%M:%S')"
    if new=$(git commit-tree 'HEAD^{tree}' -p "$rtip" -m "$msg") && git update-ref "refs/heads/$branch" "$new"; then
        add_note "content replaced, history kept"
    else
        LFS_ALL=1
        log_warn "Could not build the update on top of Codeberg's history — trying a direct push instead."
    fi
    return 0
}

# Codeberg rejects a push whose history contains a blob over 100 MiB that is not an LFS pointer.
# Detect that up front and, unless --safe, move those files into Git LFS (history rewrite of
# this branch only; the old history stays reachable under refs/codebergup-backup/).
fix_large_history() {
    local branch="$1" big f backup limit oldtip
    limit=$(( CB_HARD_MB * 1048576 ))
    big=$(git rev-list --objects "refs/heads/$branch" --not --remotes="$REMOTE_NAME" 2>/dev/null \
          | git cat-file --batch-check='%(objecttype) %(objectsize) %(rest)' 2>/dev/null \
          | awk -v lim="$limit" '$1 == "blob" && $2 + 0 > lim' | cut -d' ' -f3- | head -n 5 || true)
    if [[ -z "$big" ]]; then return 0; fi

    log_warn "Files in this folder's commit history are over ${CB_HARD_MB} MB and not in Git LFS (Codeberg may reject the push, and asks for big files in LFS):"
    printf '%s\n' "$big" | while IFS= read -r f; do log_warn "    $f"; done
    if (( ! FORCE_OVERWRITE )); then
        log_err "Rewrite the history once with:  git lfs migrate import --include-ref=refs/heads/${branch} --above=${CB_HARD_MB}MiB   (or re-run without --safe)"
        return 1
    fi
    if ! have_lfs && ! ensure_lfs; then
        log_err "Git LFS is required to fix the history, but it is not available."
        return 1
    fi
    lfs_activate || return 1
    oldtip=$(git rev-parse "refs/heads/$branch") || return 1
    backup="refs/codebergup-backup/${branch}-$(date '+%Y%m%d%H%M%S')"
    git update-ref "$backup" "$oldtip" || return 1
    log_info "Moving those files into Git LFS (rewrites this folder's history; the old history stays at $backup)…"
    if ! git lfs migrate import --include-ref="refs/heads/$branch" --above="${CB_HARD_MB}MiB"; then
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
    if [[ -n "${CODEBERGUP_SKIP:-}" ]]; then
        IFS=' ,' read -r -a extra <<< "$CODEBERGUP_SKIP" || true
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
# true when the .git in $PWD was created by codebergup.sh or gitup.sh
is_managed_repo() {
    [[ "$(git config --local --get codebergup.managed 2>/dev/null || true)" == "true" ]] \
        || [[ "$(git config --local --get gitup.managed 2>/dev/null || true)" == "true" ]]
}

# Total size in MiB of the files git tracks in $PWD (after `git add`).
tree_size_mb() {
    git ls-files -z --cached 2>/dev/null | xargs -0 wc -c 2>/dev/null \
        | awk '{ n = $1; $1 = ""; if ($0 == " total") next; s += n } END { printf "%d", s / 1048576 }'
}

process_dir_impl() {
    local dir="$1" phys branch gp excl parent err pat rel f msg risky
    local self_base tmp grep_rc
    local -a addargs=()
    RES_URL=""; RES_NOTE=""; SELF_REL=""; REMOTE_SETUP=0

    phys=$(pwd -P)

    # 1. repository ----------------------------------------------------------
    FRESH_REPO=0; OLD_ORIGIN=""; LFS_ALL=1
    if [[ -e .git && "$GIT_MODE" != "keep" ]]; then
        # A .git that codebergup created earlier is simply updated; any other .git is replaced by
        # a fresh one (the old one is moved aside, not deleted).
        if [[ "$GIT_MODE" == "always" ]] || ! is_managed_repo; then
            OLD_ORIGIN=$(own_cb_remote_url)
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
        # like `git branch -M main`: a repository made by codebergup always starts on main
        git symbolic-ref HEAD refs/heads/main || return 1
        git config --local codebergup.managed true || true
        FRESH_REPO=1
        log_ok "Initialised a new git repository."
        # an old remote that already lives on THIS account is kept; anything else is replaced
        if [[ -n "$OLD_ORIGIN" ]]; then
            git remote add "$REMOTE_DEFAULT" "$OLD_ORIGIN" || true
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

    for pat in .codebergup-backups .gitup-backups; do
        if [[ -d "$pat" ]]; then exclude_add "$excl" "/${pat}/" || true; fi
    done

    # 4a. running script: excluded only if it lives inside this repo
    case "$SELF_PATH" in
        "$phys"/*) SELF_REL="${SELF_PATH#"$phys"/}" ;;
    esac
    if [[ -n "$SELF_REL" ]]; then
        # An older codebergup wrote an *unanchored* rule (just the file name), which also
        # hid same-named files in subfolders. Drop it; the anchored rule replaces it.
        self_base=$(basename -- "$SELF_REL")
        if grep -qxF -- "$self_base" "$excl" 2>/dev/null; then
            tmp="${excl}.codebergup.$$"
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
    if [[ ! -e .gitignore && -z "${CODEBERGUP_NO_DEFAULT_IGNORE:-}" ]]; then
        if ! grep -qxF '# codebergup: default ignores' "$excl" 2>/dev/null; then
            exclude_add "$excl" '# codebergup: default ignores' || true
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
    TREE_MB=$(tree_size_mb)
    if (( TREE_MB >= 750 )); then
        log_warn "This folder is about ${TREE_MB} MB. Codeberg asks you to request extra resources before using over 750 MiB of Git storage (or 1.5 GiB of LFS/packages/attachments): https://codeberg.org/Codeberg-e.V./requests"
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
            msg="Update from codebergup.sh $(date '+%Y-%m-%d %H:%M:%S')"
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
    if is_cb_url "$REMOTE_URL"; then
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
            -u|--user)
                if (( $# < 2 )) || [[ "$2" == -* ]]; then die "$1 needs a Codeberg username."; fi
                CB_USER_ARG="$2"; shift 2 ;;
            --user=*)     CB_USER_ARG="${1#--user=}"; shift ;;
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
    if ! [[ "$LFS_MB" =~ $re ]] || (( LFS_MB < 1 )); then die "CODEBERGUP_LFS_MB must be a positive whole number."; fi
    if ! [[ "$LFS_MAX_MB" =~ $re ]] || (( LFS_MAX_MB < 1 )); then die "CODEBERGUP_LFS_MAX_MB must be a positive whole number."; fi
    if ! [[ "$RETRIES" =~ $re ]] || (( RETRIES < 1 )); then die "CODEBERGUP_RETRIES must be a positive whole number."; fi
    if ! [[ "$RATE_RETRIES" =~ $re ]]; then die "CODEBERGUP_RATE_RETRIES must be a whole number (0 = don't wait)."; fi
    if ! [[ "$RATE_WAIT" =~ $re ]] || (( RATE_WAIT < 1 )); then die "CODEBERGUP_RATE_WAIT must be a positive whole number of seconds."; fi
    if ! [[ "$CREATE_DELAY" =~ $re ]]; then die "CODEBERGUP_CREATE_DELAY must be a whole number of seconds."; fi
    if (( FRESH_FLAG && KEEP_GIT_FLAG )); then die "--fresh and --keep-git cannot be combined."; fi
    if (( FRESH_FLAG && ! FORCE_OVERWRITE )); then die "--fresh and --safe cannot be combined."; fi
    if (( FRESH_FLAG )); then GIT_MODE="always"; fi
    if (( KEEP_GIT_FLAG || ! FORCE_OVERWRITE )); then GIT_MODE="keep"; fi
    if (( LFS_MB > CB_HARD_MB )); then
        log_warn "CODEBERGUP_LFS_MB=${LFS_MB} is above ${CB_HARD_MB} MB — using ${CB_HARD_MB}."
        LFS_MB=$CB_HARD_MB
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
                    label="existing codebergup/gitup repo — updated"
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

    export GIT_LFS_FORCE_PROGRESS=1
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codebergup.XXXXXX") || die "Cannot create a temporary folder."
    chmod 700 "$WORK_DIR" || true
    TMP_FILE="$WORK_DIR/out.txt"; API_BODY="$WORK_DIR/api.json"; API_HDRS="$WORK_DIR/api.hdr"
    API_ERR="$WORK_DIR/api.err"; REPO_JSON="$WORK_DIR/repo.json"
    : > "$TMP_FILE"

    ensure_dependencies
    ensure_auth

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

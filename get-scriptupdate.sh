#!/usr/bin/env bash
#===============================================================================
# Name:         get-scriptupdate.sh
# Author:       flo.alt@it-flows.de
# Date:         2026-10-27
# Purpose:      Update all Git-cloned scripts below SCRIPTS_ROOT to the newest
#               signed release tag. Patch and minor releases are applied
#               automatically, major releases are only reported.
# Usage:        get-scriptupdate.sh [--dry-run] [--only NAME] [--help]
# Requires:     bash, git 2.34+, ssh-keygen, flock, runuser, timeout, sort -V;
#               runs as root (cron)
# Exit codes:   0 ok | 1 error | 2 usage | 3 config | 4 already running
#               5 attention needed (script skipped or major update pending)
#               6 update failed (fetch, signature, checkout)
#===============================================================================

set -euo pipefail

# Cron starts jobs with a minimal PATH (/usr/bin:/bin) that lacks runuser (in /usr/sbin)
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VERSION="1.0.1"
REQUIRED_CONFIG_VERSION="1"

# The only paths derived in the script: its own directory and, by convention,
# the config next to it. Every other path comes from the config.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
CONFIG_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.config"

# --- Exit codes ---
EXIT_OK=0
EXIT_ERROR=1
EXIT_USAGE=2
EXIT_CONFIG=3
EXIT_LOCKED=4
EXIT_ATTENTION=5
EXIT_FAILED=6

# Release tags look like v1.2.3 (no pre-release suffixes)
TAG_RE='^v([0-9]+)\.([0-9]+)\.([0-9]+)$'

# Options
DRY_RUN=0
ONLY=""

# Defaults for optional config values (the config may override them)
EXCLUDE_DIRS=()

# Counters for the summary and the exit code
N_UPDATED=0
N_UPTODATE=0
N_SKIPPED=0
N_MAJOR=0
N_ERRORS=0
LAST_RESULT=""

# State of the script directory that is processed right now
CUR_DIR=""
CUR_OWNER=""
CUR_HOME=""

# Print the help text
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME}.sh [--dry-run] [--only NAME] [--help]

Updates every Git clone below the scripts directory to the newest signed
release tag of the same major version. A newer major version is only reported.

  --dry-run     fetch and check, but change nothing and write no marker file
  --only NAME   process only the script directory NAME (no marker file)
  --help        show this help

Exit codes: 0 ok, 1 error, 2 usage, 3 config, 4 already running,
            5 attention needed (skipped / major pending), 6 update failed
EOF
}

# Write one log line with timestamp and level.
# Before the config is loaded there is no LOG_FILE yet, so fall back to stderr.
# On a terminal the line is also printed to stdout (manual runs).
log() {
    local line
    line="$(printf '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2")"
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "${line}" >> "${LOG_FILE}"
        if [[ -t 1 ]]; then
            printf '%s\n' "${line}"
        fi
    else
        printf '%s\n' "${line}" >&2
    fi
}

# Log an error and terminate with the given exit code
die() {
    log "ERROR" "$2"
    exit "$1"
}

# Abort unless file exists and has the expected octal permissions.
# With a third argument "root" the file must also be owned by root:root.
check_file() {
    local file="$1" expected="$2" need_owner="${3:-}" actual owner
    [[ -f "${file}" ]] || die "${EXIT_CONFIG}" "Missing file: ${file}"
    if [[ "${need_owner}" == "root" ]]; then
        owner="$(stat -c '%U:%G' "${file}")"
        [[ "${owner}" == "root:root" ]] \
            || die "${EXIT_CONFIG}" "Wrong owner on ${file}: ${owner} (expected root:root)"
    fi
    actual="$(stat -c '%a' "${file}")"
    [[ "${actual}" == "${expected}" ]] \
        || die "${EXIT_CONFIG}" "Wrong permissions on ${file}: ${actual} (expected ${expected})"
}

# Always log the end of the run together with the exit code (called by the EXIT trap)
# shellcheck disable=SC2329
on_exit() {
    local rc=$?
    log "INFO" "END (exit ${rc})"
}

# Run git inside the current script directory, as the owner of that directory.
# Reasons: git refuses repositories of other users ("dubious ownership"), and
# running git as root in a user-owned repository would execute hooks and config
# of that repository as root. Global and system git config are ignored, the
# signature settings are forced on the command line.
# core.fileMode=false: a differing executable bit is not a local change. Tags
# created before the bit was tracked (or on file systems that lose it) would
# otherwise block the update; a checkout still applies the mode of the new tag.
# With "--net" as first argument the call is limited by GIT_TIMEOUT_SECONDS.
git_run() {
    local -a cmd=()
    local net=0
    if [[ "${1:-}" == "--net" ]]; then
        net=1
        shift
    fi
    if [[ "${CUR_OWNER}" != "$(id -un)" ]]; then
        cmd+=(runuser -u "${CUR_OWNER}" --)
    fi
    if (( net )); then
        cmd+=(timeout "${GIT_TIMEOUT_SECONDS}")
    fi
    cmd+=(env GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
        LC_ALL=C "HOME=${CUR_HOME}"
        git -C "${CUR_DIR}"
        -c gpg.format=ssh -c gpg.ssh.program=ssh-keygen -c core.fileMode=false
        -c "gpg.ssh.allowedSignersFile=${ALLOWED_SIGNERS_FILE}"
        "$@")
    "${cmd[@]}"
}

# True if version $1 (e.g. v1.2.0) is strictly newer than version $2
version_gt() {
    local a="${1#v}" b="${2#v}"
    [[ "${a}" != "${b}" ]] \
        && [[ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | tail -n1)" == "${a}" ]]
}

# Print the release tags of the current directory, newest first
list_release_tags() {
    git_run tag --list 'v*' --sort=-v:refname | grep -E "${TAG_RE}" || true
}

# Record the outcome of one script and log it. $1 = name, $2 = counter, $3 = level, $4 = message
result() {
    LAST_RESULT="$2"
    case "$2" in
        updated)  N_UPDATED=$((N_UPDATED + 1)) ;;
        uptodate) N_UPTODATE=$((N_UPTODATE + 1)) ;;
        skipped)  N_SKIPPED=$((N_SKIPPED + 1)) ;;
        major)    N_MAJOR=$((N_MAJOR + 1)) ;;
        error)    N_ERRORS=$((N_ERRORS + 1)) ;;
    esac
    log "$3" "$1: $4"
}

# Check one script directory and update it if a newer signed tag of the same
# major version exists. Never exits; problems are counted and logged.
process_dir() {
    local name="$1" current target newest cur_major out commit tagname

    CUR_DIR="${SCRIPTS_ROOT}/${name}"

    if [[ ! -e "${CUR_DIR}/.git" ]]; then
        result "${name}" skipped WARN "not a Git clone, skipped (convert it once by hand)"
        return 0
    fi

    CUR_OWNER="$(stat -c '%U' "${CUR_DIR}")"
    if ! id -u "${CUR_OWNER}" >/dev/null 2>&1; then
        result "${name}" error ERROR "directory owner '${CUR_OWNER}' is not a known user"
        return 0
    fi
    CUR_HOME="$(getent passwd "${CUR_OWNER}" | cut -d: -f6 || true)"
    [[ -d "${CUR_HOME}" ]] || CUR_HOME="/"

    # Local changes to tracked files block the update (the executable bit is ignored, see git_run)
    if ! out="$(git_run status --porcelain --untracked-files=no 2>&1)"; then
        result "${name}" error ERROR "git status failed: $(head -n1 <<<"${out}")"
        return 0
    fi
    if [[ -n "${out}" ]]; then
        result "${name}" skipped WARN "local changes, skipped: $(head -n3 <<<"${out}" | tr '\n' ';')"
        return 0
    fi

    # The clone must sit exactly on a release tag
    if ! current="$(git_run describe --tags --exact-match HEAD 2>/dev/null)" \
        || [[ ! "${current}" =~ ${TAG_RE} ]]; then
        result "${name}" skipped WARN "HEAD is not on a release tag, skipped"
        return 0
    fi
    cur_major="${BASH_REMATCH[1]}"

    if ! out="$(git_run --net fetch --quiet --tags "${REMOTE_NAME}" 2>&1)"; then
        result "${name}" error ERROR "fetch failed: $(head -n1 <<<"${out}")"
        return 0
    fi

    # A newer major release is only reported
    newest="$(list_release_tags | head -n1 || true)"
    if [[ -n "${newest}" ]] && [[ "${newest}" =~ ${TAG_RE} ]] && (( BASH_REMATCH[1] > cur_major )); then
        result "${name}" major WARN "major update ${newest} available (installed ${current}), not applied automatically"
    fi

    # Newest tag of the same major version
    target="$(list_release_tags | grep -E "^v${cur_major}\." | head -n1 || true)"
    if [[ -z "${target}" ]] || ! version_gt "${target}" "${current}"; then
        if [[ -z "${newest}" ]] || ! version_gt "${newest}" "${current}"; then
            result "${name}" uptodate INFO "up to date (${current})"
        fi
        return 0
    fi

    # Resolve the tag to a commit and verify the signature (exit code only)
    if ! commit="$(git_run rev-parse --verify "refs/tags/${target}^{commit}" 2>/dev/null)"; then
        result "${name}" error ERROR "cannot resolve ${target}, not applied"
        return 0
    fi
    if ! git_run verify-tag "refs/tags/${target}" >/dev/null 2>&1; then
        result "${name}" error ERROR "signature of ${target} NOT verified, not applied"
        return 0
    fi
    # The signed tag object must carry the same name as the ref (no tag swapping)
    tagname="$(git_run for-each-ref --format='%(tag)' "refs/tags/${target}" 2>/dev/null || true)"
    if [[ "${tagname}" != "${target}" ]]; then
        result "${name}" error ERROR "tag object name '${tagname}' does not match ${target}, not applied"
        return 0
    fi

    if (( DRY_RUN )); then
        result "${name}" updated INFO "DRY-RUN: would update ${current} -> ${target}"
        return 0
    fi

    # Switch to the verified commit; on failure go back to the old tag
    if ! out="$(git_run checkout --quiet --detach "${commit}" 2>&1)"; then
        log "ERROR" "${name}: checkout of ${target} failed: $(head -n1 <<<"${out}")"
        if git_run checkout --quiet --detach "refs/tags/${current}" >/dev/null 2>&1; then
            result "${name}" error ERROR "rolled back to ${current}"
        else
            result "${name}" error ERROR "rollback to ${current} FAILED, check the directory by hand"
        fi
        return 0
    fi

    result "${name}" updated INFO "updated ${current} -> ${target}"
}

# Main program (a function, so bash has parsed the whole file before a
# self-update replaces it)
main() {
    local arg d name self_name="" found=0
    local -a names=()

    # --- Parse options ---
    while (( $# > 0 )); do
        arg="$1"
        case "${arg}" in
            --dry-run) DRY_RUN=1 ;;
            --only)
                [[ $# -ge 2 ]] || { echo "Option --only needs a name" >&2; exit "${EXIT_USAGE}"; }
                ONLY="$2"
                shift
                ;;
            --help|-h) usage; exit "${EXIT_OK}" ;;
            *) echo "Unknown option: ${arg}" >&2; usage >&2; exit "${EXIT_USAGE}" ;;
        esac
        shift
    done
    if [[ -n "${ONLY}" && ! "${ONLY}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Invalid name for --only: ${ONLY}" >&2
        exit "${EXIT_USAGE}"
    fi

    # --- Startup ---
    trap on_exit EXIT

    [[ "${EUID}" -eq 0 ]] || die "${EXIT_ERROR}" "Must run as root"

    # Load config (SCRIPT_DIR and SCRIPT_NAME are available inside it)
    check_file "${CONFIG_FILE}" 660
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    # Config must match the version this script expects
    [[ "${CONFIG_VERSION:-}" == "${REQUIRED_CONFIG_VERSION}" ]] \
        || die "${EXIT_CONFIG}" "CONFIG_VERSION '${CONFIG_VERSION:-unset}' does not match required '${REQUIRED_CONFIG_VERSION}'"

    log "INFO" "START (version ${VERSION})"
    (( DRY_RUN )) && log "INFO" "Dry run: nothing will be changed"

    # Prevent parallel runs (LOCK_FILE comes from the config)
    # shellcheck disable=SC2153
    exec 9>"${LOCK_FILE}"
    flock -n 9 || die "${EXIT_LOCKED}" "Another instance is already running"

    # --- Check config values ---
    [[ -d "${SCRIPTS_ROOT:-}" ]] || die "${EXIT_CONFIG}" "SCRIPTS_ROOT is not a directory: ${SCRIPTS_ROOT:-unset}"
    [[ -n "${REMOTE_NAME:-}" ]] || die "${EXIT_CONFIG}" "REMOTE_NAME is not set"
    [[ "${GIT_TIMEOUT_SECONDS:-}" =~ ^[0-9]+$ ]] || die "${EXIT_CONFIG}" "GIT_TIMEOUT_SECONDS must be a number"
    # The trust anchor must be a root-owned file that nobody else can write
    [[ -f "${ALLOWED_SIGNERS_FILE:-}" ]] || die "${EXIT_CONFIG}" "Missing allowed_signers file: ${ALLOWED_SIGNERS_FILE:-unset}"
    [[ "$(stat -c '%U:%G' "${ALLOWED_SIGNERS_FILE}")" == "root:root" ]] \
        || die "${EXIT_CONFIG}" "allowed_signers must be owned by root:root: ${ALLOWED_SIGNERS_FILE}"
    (( (8#$(stat -c '%a' "${ALLOWED_SIGNERS_FILE}") & 8#022) == 0 )) \
        || die "${EXIT_CONFIG}" "allowed_signers must not be writable by group or others: ${ALLOWED_SIGNERS_FILE}"

    # --- Collect the script directories (this script last, see self-update) ---
    for d in "${SCRIPTS_ROOT}"/*/; do
        [[ -d "${d}" ]] || continue
        name="$(basename "${d}")"
        if [[ -n "${ONLY}" ]]; then
            [[ "${name}" == "${ONLY}" ]] || continue
            found=1
        elif [[ " ${EXCLUDE_DIRS[*]:-} " == *" ${name} "* ]]; then
            log "INFO" "${name}: excluded by config"
            continue
        fi
        if [[ "${d%/}" -ef "${SCRIPT_DIR}" ]]; then
            self_name="${name}"
        else
            names+=("${name}")
        fi
    done
    if [[ -n "${ONLY}" && "${found}" -eq 0 ]]; then
        die "${EXIT_USAGE}" "--only: no directory '${ONLY}' in ${SCRIPTS_ROOT}"
    fi
    [[ -z "${self_name}" ]] || names+=("${self_name}")

    # --- Main logic ---
    for name in "${names[@]}"; do
        process_dir "${name}"
        if [[ "${name}" == "${self_name}" && "${LAST_RESULT}" == "updated" && "${DRY_RUN}" -eq 0 ]]; then
            log "INFO" "${name}: this script was updated, the new version is used from the next run"
        fi
    done

    log "INFO" "SUMMARY: updated=${N_UPDATED} up-to-date=${N_UPTODATE} skipped=${N_SKIPPED} major-pending=${N_MAJOR} errors=${N_ERRORS}"

    if (( N_ERRORS > 0 )); then
        exit "${EXIT_FAILED}"
    fi
    if (( N_SKIPPED > 0 || N_MAJOR > 0 )); then
        exit "${EXIT_ATTENTION}"
    fi

    # --- Success: write marker as the very last step ---
    # Not on a dry run and not after a partial run (--only)
    if (( DRY_RUN == 0 )) && [[ -z "${ONLY}" ]]; then
        date '+%Y-%m-%d %H:%M:%S' > "${MARKER_FILE}"
    fi
    exit "${EXIT_OK}"
}

main "$@"
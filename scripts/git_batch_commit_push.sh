#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMIT_MESSAGE=""

usage() {
    cat <<'EOF'
Usage:
  bash scripts/git_batch_commit_push.sh
  bash scripts/git_batch_commit_push.sh -m "your commit message"

Behavior:
  - Scans the hushine workspace for Git repositories.
  - Removes each repo-root logs/ directory before staging.
  - Runs: git add -A -> git commit -> git push for each repo.
  - Skips clean repos.
  - Continues even if add / commit / push fails on one repo.
  - Prints a final report and exits non-zero if any repo failed.
EOF
}

summarize_output() {
    local text="${1:-}"
    text="$(printf '%s' "${text}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
    if [ "${#text}" -gt 200 ]; then
        text="${text:0:197}..."
    fi
    printf '%s' "${text}"
}

rel_path() {
    local path="$1"
    if [[ "${path}" == "${ROOT}/"* ]]; then
        printf '%s' "${path#${ROOT}/}"
    else
        printf '%s' "${path}"
    fi
}

record_report() {
    local status="$1"
    local repo="$2"
    local branch="$3"
    local sha="$4"
    local detail="$5"
    REPORT_LINES+=("${status}|${repo}|${branch}|${sha}|${detail}")
}

cleanup_repo_logs() {
    local repo="$1"
    local logs_dir="${repo}/logs"
    CLEANUP_DETAIL="logs already absent"

    if [ ! -d "${logs_dir}" ]; then
        return 0
    fi

    if rm -rf "${logs_dir}"; then
        CLEANUP_DETAIL="removed logs/"
        return 0
    fi

    CLEANUP_DETAIL="failed to remove logs/"
    return 1
}

push_current_repo() {
    local repo="$1"
    local branch="$2"
    local push_output=""

    if git -C "${repo}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        if push_output="$(git -C "${repo}" push 2>&1)"; then
            PUSH_DETAIL="git push"
            return 0
        fi
        PUSH_DETAIL="$(summarize_output "${push_output}")"
        return 1
    fi

    if [ "${branch}" != "HEAD" ] && git -C "${repo}" remote | grep -qx 'origin'; then
        if push_output="$(git -C "${repo}" push -u origin "${branch}" 2>&1)"; then
            PUSH_DETAIL="git push -u origin ${branch}"
            return 0
        fi
        PUSH_DETAIL="$(summarize_output "${push_output}")"
        return 1
    fi

    local remote_count
    remote_count="$(git -C "${repo}" remote | wc -l | tr -d ' ')"
    if [ "${branch}" != "HEAD" ] && [ "${remote_count}" = "1" ]; then
        local remote_name
        remote_name="$(git -C "${repo}" remote | head -n 1)"
        if push_output="$(git -C "${repo}" push -u "${remote_name}" "${branch}" 2>&1)"; then
            PUSH_DETAIL="git push -u ${remote_name} ${branch}"
            return 0
        fi
        PUSH_DETAIL="$(summarize_output "${push_output}")"
        return 1
    fi

    if push_output="$(git -C "${repo}" push 2>&1)"; then
        PUSH_DETAIL="git push"
        return 0
    fi
    PUSH_DETAIL="$(summarize_output "${push_output}")"
    return 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -m|--message)
            shift
            if [ $# -eq 0 ]; then
                echo "Missing value for -m/--message"
                usage
                exit 2
            fi
            COMMIT_MESSAGE="$1"
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
    shift
done

if [ -z "${COMMIT_MESSAGE}" ]; then
    printf 'Commit message: '
    IFS= read -r COMMIT_MESSAGE
fi

if [ -z "${COMMIT_MESSAGE}" ]; then
    echo "Commit message cannot be empty."
    exit 2
fi

REPOS=()
while IFS= read -r git_meta; do
    [ -n "${git_meta}" ] || continue
    REPOS+=("$(dirname "${git_meta}")")
done < <(
    {
        find "${ROOT}" -type d -name .git -prune -print
        find "${ROOT}" -type f -name .git -print
    } | sort
)

if [ "${#REPOS[@]}" -eq 0 ]; then
    echo "No Git repositories found under ${ROOT}."
    exit 1
fi

REPORT_LINES=()
SUCCESS_COUNT=0
CLEAN_COUNT=0
FAIL_COUNT=0

echo "Workspace: ${ROOT}"
echo "Commit message: ${COMMIT_MESSAGE}"
echo "Repositories found: ${#REPOS[@]}"
echo

for repo in "${REPOS[@]}"; do
    repo_display="$(rel_path "${repo}")"
    branch="$(git -C "${repo}" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')"
    sha_before="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || printf '-')"

    echo "==> ${repo_display} [${branch}]"

    CLEANUP_DETAIL=""
    if ! cleanup_repo_logs "${repo}"; then
        detail="${CLEANUP_DETAIL}"
        echo "    cleanup failed: ${detail}"
        record_report "CLEANUP_FAILED" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    echo "    cleanup: ${CLEANUP_DETAIL}"

    if ! add_output="$(git -C "${repo}" add -A 2>&1)"; then
        detail="$(summarize_output "${add_output}")"
        echo "    add failed: ${detail}"
        record_report "ADD_FAILED" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    if git -C "${repo}" diff --cached --quiet --ignore-submodules --; then
        echo "    clean: nothing to commit"
        record_report "CLEAN" "${repo_display}" "${branch}" "${sha_before}" "nothing to commit"
        CLEAN_COUNT=$((CLEAN_COUNT + 1))
        continue
    fi

    if ! commit_output="$(git -C "${repo}" commit -m "${COMMIT_MESSAGE}" 2>&1)"; then
        detail="$(summarize_output "${commit_output}")"
        echo "    commit failed: ${detail}"
        record_report "COMMIT_FAILED" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    sha_after="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || printf '-')"
    echo "    committed: ${sha_after}"

    PUSH_DETAIL=""
    if push_current_repo "${repo}" "${branch}"; then
        echo "    pushed: ${PUSH_DETAIL}"
        record_report "PUSHED" "${repo_display}" "${branch}" "${sha_after}" "${PUSH_DETAIL}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "    push failed: ${PUSH_DETAIL}"
        record_report "PUSH_FAILED" "${repo_display}" "${branch}" "${sha_after}" "${PUSH_DETAIL}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo
echo "Report"
printf '%-14s %-28s %-18s %-10s %s\n' "STATUS" "REPO" "BRANCH" "COMMIT" "DETAIL"
printf '%-14s %-28s %-18s %-10s %s\n' "------" "----" "------" "------" "------"

for line in "${REPORT_LINES[@]}"; do
    IFS='|' read -r status repo branch sha detail <<< "${line}"
    printf '%-14s %-28s %-18s %-10s %s\n' "${status}" "${repo}" "${branch}" "${sha}" "${detail}"
done

echo
echo "Summary: pushed=${SUCCESS_COUNT} clean=${CLEAN_COUNT} failed=${FAIL_COUNT} total=${#REPOS[@]}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi

exit 0

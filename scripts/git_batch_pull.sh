#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    cat <<'EOF'
Usage:
  bash scripts/git_batch_pull.sh

Behavior:
  - Scans the hushine workspace for Git repositories.
  - Fetches remotes with prune for each repo.
  - Pulls only fast-forward updates from the current upstream branch.
  - Skips dirty repos to avoid overwriting local work.
  - Skips detached HEAD repos and repos without a resolvable upstream.
  - Reports diverged or local-ahead repos without changing them.
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

ensure_upstream() {
    local repo="$1"
    local branch="$2"

    if git -C "${repo}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        UPSTREAM_REF="$(git -C "${repo}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
        return 0
    fi

    if [ "${branch}" = "HEAD" ]; then
        UPSTREAM_REF=""
        return 1
    fi

    if git -C "${repo}" remote | grep -qx 'origin' && git -C "${repo}" show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
        if git -C "${repo}" branch --set-upstream-to="origin/${branch}" "${branch}" >/dev/null 2>&1; then
            UPSTREAM_REF="origin/${branch}"
            return 0
        fi
    fi

    local remote_count
    remote_count="$(git -C "${repo}" remote | wc -l | tr -d ' ')"
    if [ "${remote_count}" = "1" ]; then
        local remote_name
        remote_name="$(git -C "${repo}" remote | head -n 1)"
        if git -C "${repo}" show-ref --verify --quiet "refs/remotes/${remote_name}/${branch}"; then
            if git -C "${repo}" branch --set-upstream-to="${remote_name}/${branch}" "${branch}" >/dev/null 2>&1; then
                UPSTREAM_REF="${remote_name}/${branch}"
                return 0
            fi
        fi
    fi

    UPSTREAM_REF=""
    return 1
}

if [ $# -gt 0 ]; then
    case "$1" in
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
UPDATED_COUNT=0
CURRENT_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

echo "Workspace: ${ROOT}"
echo "Repositories found: ${#REPOS[@]}"
echo

for repo in "${REPOS[@]}"; do
    repo_display="$(rel_path "${repo}")"
    branch="$(git -C "${repo}" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')"
    sha_before="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || printf '-')"

    echo "==> ${repo_display} [${branch}]"

    if [ "${branch}" = "HEAD" ]; then
        detail="detached HEAD"
        echo "    skipped: ${detail}"
        record_report "DETACHED" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if [ -n "$(git -C "${repo}" status --porcelain 2>/dev/null)" ]; then
        detail="working tree not clean"
        echo "    skipped: ${detail}"
        record_report "DIRTY_SKIP" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if ! fetch_output="$(git -C "${repo}" fetch --all --prune 2>&1)"; then
        detail="$(summarize_output "${fetch_output}")"
        echo "    fetch failed: ${detail}"
        record_report "FETCH_FAILED" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    UPSTREAM_REF=""
    if ! ensure_upstream "${repo}" "${branch}"; then
        detail="no upstream branch configured"
        echo "    skipped: ${detail}"
        record_report "NO_UPSTREAM" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if ! read -r behind ahead < <(git -C "${repo}" rev-list --left-right --count "${UPSTREAM_REF}...HEAD" 2>/dev/null); then
        detail="unable to compare against ${UPSTREAM_REF}"
        echo "    compare failed: ${detail}"
        record_report "COMPARE_FAIL" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    if [ "${behind}" = "0" ] && [ "${ahead}" = "0" ]; then
        detail="up to date with ${UPSTREAM_REF}"
        echo "    current: ${detail}"
        record_report "CURRENT" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        CURRENT_COUNT=$((CURRENT_COUNT + 1))
        continue
    fi

    if [ "${behind}" = "0" ] && [ "${ahead}" != "0" ]; then
        detail="local branch is ahead of ${UPSTREAM_REF} by ${ahead} commit(s)"
        echo "    skipped: ${detail}"
        record_report "LOCAL_AHEAD" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if [ "${behind}" != "0" ] && [ "${ahead}" != "0" ]; then
        detail="branch diverged from ${UPSTREAM_REF} (behind=${behind}, ahead=${ahead})"
        echo "    skipped: ${detail}"
        record_report "DIVERGED" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    if ! pull_output="$(git -C "${repo}" pull --ff-only 2>&1)"; then
        detail="$(summarize_output "${pull_output}")"
        echo "    pull failed: ${detail}"
        record_report "PULL_FAILED" "${repo_display}" "${branch}" "${sha_before}" "${detail}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    sha_after="$(git -C "${repo}" rev-parse --short HEAD 2>/dev/null || printf '-')"
    detail="fast-forwarded from ${sha_before} to ${sha_after}"
    echo "    updated: ${detail}"
    record_report "UPDATED" "${repo_display}" "${branch}" "${sha_after}" "${detail}"
    UPDATED_COUNT=$((UPDATED_COUNT + 1))
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
echo "Summary: updated=${UPDATED_COUNT} current=${CURRENT_COUNT} skipped=${SKIP_COUNT} failed=${FAIL_COUNT} total=${#REPOS[@]}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi

exit 0

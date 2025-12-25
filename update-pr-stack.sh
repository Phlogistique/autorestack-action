#!/bin/bash
#
# Updates PR stack after merging a PR
#
# Required environment variables:
# SQUASH_COMMIT - The hash of the squash commit that was merged
# MERGED_BRANCH - The name of the branch that was merged and will be deleted
# TARGET_BRANCH - The name of the branch that the PR was merged into
#
# Design note:
# This script aims to output a transcript of "plain" git/gh commands that a
# human could follow through manually. For this reason:
# - We use git refs (e.g., SQUASH_COMMIT) instead of shell variables where
#   possible, so the logged commands are self-contained and reproducible
# - We strive to keep commands as simple as possible

set -ueo pipefail  # Exit on error, undefined var, or pipeline failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/command_utils.sh"

CONFLICT_LABEL="autorestack-needs-conflict-resolution"

# Allow replacing git and gh
[ -v GIT ] && git() { "$GIT" "$@"; }
[ -v GH ] && gh() { "$GH" "$@"; }

# Function to check if a required environment variable is set
check_env_var() {
    if [[ -z "${!1-}" ]]; then
        echo "Error: $1 is not set" >&2
        exit 1
    fi
}

# Check if a branch already has the squash commit merged (squash-merge mode only)
# Requires SQUASH_COMMIT ref to be set via git update-ref
#
# Note: This uses local branch refs. The caller must ensure both branches
# exist locally before calling (e.g., via git checkout).
has_squash_commit() {
    local BRANCH="$1"
    local BASE="$2"
    git merge-base --is-ancestor "$BASE" "$BRANCH" \
        && git merge-base --is-ancestor SQUASH_COMMIT "$BRANCH"
}

format_branch_list_for_text() {
    for ((i=1; i<=$#; i++)); do
        case $i in
            1) format='`%s`';;
            $#) format=', and `%s`';;
            *) format=', `%s`';;
        esac
        printf "$format" "${!i}"
    done
}

update_direct_target() {
    local BRANCH="$1"
    local BASE_BRANCH="$2"

    # Checkout first to ensure the local branch exists (created from origin if
    # needed). This allows has_squash_commit to compare local refs, which matters
    # for testing where the script may run multiple times in the same repo.
    log_cmd git checkout "$BRANCH"

    if has_squash_commit "$BRANCH" "$TARGET_BRANCH"; then
        echo "✓ $BRANCH already up-to-date; skipping"
        return
    fi

    echo "Updating direct target $BRANCH (from $MERGED_BRANCH to $BASE_BRANCH)"

    CONFLICTS=()
    log_cmd git update-ref BEFORE_MERGE HEAD
    if ! log_cmd git merge --no-edit "origin/$MERGED_BRANCH"; then
        CONFLICTS+=("origin/$MERGED_BRANCH")
        log_cmd git merge --abort
    fi
    if ! log_cmd git merge --no-edit SQUASH_COMMIT~; then
        CONFLICTS+=( "$(git rev-parse SQUASH_COMMIT~)" )
        log_cmd git merge --abort
    fi

    if [[ "${#CONFLICTS[@]}" -gt 0 ]]; then
        {
            echo "### ⚠️ Automatic update blocked by merge conflicts"
            echo
            echo -n "I tried to merge "
            format_branch_list_for_text "${CONFLICTS[@]}"
            echo
            echo "into this branch while updating the PR stack and hit conflicts."
            echo
            echo "#### How to resolve"
            echo '```bash'
            echo "git fetch origin"
            echo "git switch $BRANCH"
            for conflict in "${CONFLICTS[@]}"; do
                echo "git merge $conflict"
                echo "# ..."
                echo "# fix conflicts, for instance with `git mergetool`"
                echo "# ..."
                echo "git commit"
            done
            echo "git push"
            echo '```'
        } | log_cmd gh pr comment "$BRANCH" -F -
        # Create the label if it doesn't exist, then add it to the PR
        gh label create "$CONFLICT_LABEL" --description "PR needs manual conflict resolution" --color "d73a4a" 2>/dev/null || true
        log_cmd gh pr edit "$BRANCH" --add-label "$CONFLICT_LABEL"
    else
        log_cmd git merge --no-edit -s ours "$SQUASH_COMMIT"
        log_cmd git update-ref MERGE_RESULT "HEAD^{tree}"
        COMMIT_MSG="Merge updates from $BASE_BRANCH and squash commit"
        CUSTOM_COMMIT=$(log_cmd git commit-tree MERGE_RESULT -p BEFORE_MERGE -p "origin/$MERGED_BRANCH" -p SQUASH_COMMIT -m "$COMMIT_MSG")
        log_cmd git reset --hard "$CUSTOM_COMMIT"
    fi
}

update_indirect_target() {
    local BRANCH="$1"
    local BASE_BRANCH="$2"

    # At this point in the control flow:
    # - BASE_BRANCH has already been checked out and potentially modified locally
    # - BRANCH has not been touched yet
    #
    # We checkout BRANCH first (which creates the local branch from origin if
    # needed), then compare against the local BASE_BRANCH to check if it's
    # already an ancestor.
    log_cmd git checkout "$BRANCH"

    if git merge-base --is-ancestor "$BASE_BRANCH" "$BRANCH"; then
        echo "✓ $BRANCH already up-to-date with $BASE_BRANCH; skipping"
        return
    fi

    echo "Updating indirect target $BRANCH (based on $BASE_BRANCH)"
    log_cmd git merge --no-edit "$BASE_BRANCH"
}

ALL_CHILDREN=()
update_branch_recursive() {
    local BRANCH="$1"

    # Find and update branches based on this one
    CHILD_BRANCHES=$(log_cmd gh pr list --base "$BRANCH" --json headRefName --jq '.[].headRefName')
    ALL_CHILDREN+=($CHILD_BRANCHES)
    for CHILD_BRANCH in $CHILD_BRANCHES; do
        update_indirect_target "$CHILD_BRANCH" "$BRANCH"
        update_branch_recursive "$CHILD_BRANCH"
    done
}

# Check if a PR has the conflict resolution label
pr_has_conflict_label() {
    local BRANCH="$1"
    local LABELS
    LABELS=$(gh pr view "$BRANCH" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
    echo "$LABELS" | grep -q "^${CONFLICT_LABEL}$"
}

# Continue processing after user manually resolved conflicts
continue_after_resolution() {
    check_env_var "PR_BRANCH"

    echo "Checking if $PR_BRANCH needs continuation after conflict resolution..."

    # Check if the PR has the conflict label
    if ! pr_has_conflict_label "$PR_BRANCH"; then
        echo "✓ $PR_BRANCH does not have conflict label; nothing to do"
        return
    fi

    echo "Found conflict label on $PR_BRANCH, continuing stack update..."

    # Remove the conflict label
    log_cmd gh pr edit "$PR_BRANCH" --remove-label "$CONFLICT_LABEL"

    # Post a comment acknowledging the resolution
    echo "✅ Conflict resolved! Continuing to update dependent PRs..." | log_cmd gh pr comment "$PR_BRANCH" -F -

    # Find and update child PRs (PRs based on this branch)
    CHILD_BRANCHES=$(log_cmd gh pr list --base "$PR_BRANCH" --json headRefName --jq '.[].headRefName')

    if [[ -z "$CHILD_BRANCHES" ]]; then
        echo "✓ No child PRs to update"
        return
    fi

    ALL_CHILDREN=()
    for CHILD_BRANCH in $CHILD_BRANCHES; do
        echo "Updating child branch $CHILD_BRANCH based on $PR_BRANCH"
        log_cmd git checkout "$CHILD_BRANCH"
        if ! log_cmd git merge --no-edit "origin/$PR_BRANCH"; then
            echo "⚠️ Merge conflict updating $CHILD_BRANCH"
            log_cmd git merge --abort
            # Add conflict label to the child PR
            gh label create "$CONFLICT_LABEL" --description "PR needs manual conflict resolution" --color "d73a4a" 2>/dev/null || true
            log_cmd gh pr edit "$CHILD_BRANCH" --add-label "$CONFLICT_LABEL"
            {
                echo "### ⚠️ Automatic update blocked by merge conflicts"
                echo
                echo "I tried to merge \`origin/$PR_BRANCH\` into this branch while continuing the PR stack update and hit conflicts."
                echo
                echo "#### How to resolve"
                echo '```bash'
                echo "git fetch origin"
                echo "git switch $CHILD_BRANCH"
                echo "git merge origin/$PR_BRANCH"
                echo "# ..."
                echo "# fix conflicts, for instance with \`git mergetool\`"
                echo "# ..."
                echo "git commit"
                echo "git push"
                echo '```'
            } | log_cmd gh pr comment "$CHILD_BRANCH" -F -
            continue
        fi
        ALL_CHILDREN+=("$CHILD_BRANCH")
        update_branch_recursive "$CHILD_BRANCH"
    done

    # Push all updated branches
    if [[ "${#ALL_CHILDREN[@]}" -gt 0 ]]; then
        log_cmd git push origin "${ALL_CHILDREN[@]}"
    fi
}

main() {
    # Check required environment variables
    check_env_var "SQUASH_COMMIT"
    check_env_var "MERGED_BRANCH"
    check_env_var "TARGET_BRANCH"

    log_cmd git update-ref SQUASH_COMMIT "$SQUASH_COMMIT"

    # Find all PRs directly targeting the merged PR's head
    INITIAL_TARGETS=($(log_cmd gh pr list --base "$MERGED_BRANCH" --json headRefName --jq '.[].headRefName'))

    for BRANCH in "${INITIAL_TARGETS[@]}"; do
        update_direct_target "$BRANCH" "$TARGET_BRANCH"
        update_branch_recursive "$BRANCH"
    done

    # Update base branches for direct target PRs
    for BRANCH in "${INITIAL_TARGETS[@]}"; do
        log_cmd gh pr edit "$BRANCH" --base "$TARGET_BRANCH"
    done

    # Push all updated branches and delete the merged branch
    log_cmd git push origin ":$MERGED_BRANCH" "${INITIAL_TARGETS[@]}" "${ALL_CHILDREN[@]}"
}

# Only run if the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${ACTION_MODE:-squash-merge}" in
        squash-merge)
            main
            ;;
        conflict-resolved)
            continue_after_resolution
            ;;
        *)
            echo "Error: Unknown ACTION_MODE: $ACTION_MODE" >&2
            exit 1
            ;;
    esac
fi

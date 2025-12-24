#!/bin/bash
#
# Updates PR stack after merging a PR
#
# Required environment variables:
# SQUASH_COMMIT - The hash of the squash commit that was merged
# MERGED_BRANCH - The name of the branch that was merged and will be deleted
# TARGET_BRANCH - The name of the branch that the PR was merged into

set -ueo pipefail  # Exit on error, undefined var, or pipeline failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/command_utils.sh"

# Debug output
echo "=== update-pr-stack.sh starting ===" >&2
echo "SQUASH_COMMIT: $SQUASH_COMMIT" >&2
echo "MERGED_BRANCH: $MERGED_BRANCH" >&2
echo "TARGET_BRANCH: $TARGET_BRANCH" >&2
echo "Current directory: $(pwd)" >&2
echo "Git remotes:" >&2
git remote -v >&2
echo "Git branches:" >&2
git branch -a >&2
echo "==================================" >&2

# Allow replacing git and gh
[ -v GIT ] && git() { "$GIT" "$@"; }
[ -v GH ] && gh() { "$GH" "$@"; }

# Function to check if a required environment variable is set
check_env_var() {
    if [ -z "${!1}" ]; then
        echo "Error: $1 is not set" >&2
        exit 1
    fi
}

skip_if_clean() {
    local BRANCH="$1"
    local BASE="$2"
    # If BASE is already an ancestor of BRANCH *and*
    # the squash commit is already in history, we're done.
    git merge-base --is-ancestor "origin/$BASE" "origin/$BRANCH" \
        && git merge-base --is-ancestor SQUASH_COMMIT "origin/$BRANCH"
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

    if skip_if_clean "$BRANCH" "$TARGET_BRANCH"; then
        echo "✓ $BRANCH already up-to-date; skipping"
        return
    fi

    echo "Updating direct target $BRANCH (from $MERGED_BRANCH to $BASE_BRANCH)"
    log_cmd git checkout "$BRANCH"

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
        log_cmd gh pr edit "$BRANCH" --add-label autorestack-needs-conflict-resolution
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

    if skip_if_clean "$BRANCH" "$BASE_BRANCH"; then
        echo "✓ $BRANCH already up-to-date with $BASE_BRANCH; skipping"
        return
    fi

    echo "Updating indirect target $BRANCH (based on $BASE_BRANCH)"
    log_cmd git checkout "$BRANCH"
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

# Only run main() if the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi

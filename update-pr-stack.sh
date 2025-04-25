#!/bin/bash
#
# Updates PR stack after merging a PR
#
# Required environment variables:
# SQUASH_COMMIT - The hash of the squash commit that was merged
# MERGED_BRANCH - The name of the branch that was merged and will be deleted
# TARGET_BRANCH - The name of the branch that the PR was merged into

set -ue  # Exit immediately if a command exits with a non-zero status.

source ./command_utils.sh

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
    git merge-base --is-ancestor "origin/$BASE" "$BRANCH" \
        && git merge-base --is-ancestor "$SQUASH_COMMIT" "$BRANCH"
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

    log_cmd git update-ref BEFORE_MERGE HEAD
    log_cmd git merge --no-edit "origin/$MERGED_BRANCH"
    log_cmd git merge --no-edit "${SQUASH_COMMIT}~"
    log_cmd git merge --no-edit -s ours "$SQUASH_COMMIT"

    log_cmd git update-ref MERGE_RESULT "HEAD^{tree}"
    COMMIT_MSG="Merge updates from $BASE_BRANCH and squash commit"
    CUSTOM_COMMIT=$(log_cmd git commit-tree MERGE_RESULT -p BEFORE_MERGE -p "origin/$MERGED_BRANCH" -p SQUASH_COMMIT -m "$COMMIT_MSG")
    log_cmd git reset --hard "$CUSTOM_COMMIT"
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
    log_cmd git merge --no-edit "origin/$BASE_BRANCH"
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

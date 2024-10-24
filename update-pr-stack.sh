#!/bin/bash
#
# Updates PR stack after merging a PR
#
# Required environment variables:
# SQUASH_COMMIT - The hash of the squash commit that was merged
# MERGED_BRANCH - The name of the branch that was merged and will be deleted
# TARGET_BRANCH - The name of the branch that the PR was merged into

set -e  # Exit immediately if a command exits with a non-zero status.

# Function to log and execute git commands
git_cmd() {
    printf "Executing: git" >&2
    printf " %q" "$@" >&2
    printf "\n" >&2
    git "$@"
}

# Function to check if a required environment variable is set
check_env_var() {
    if [ -z "${!1}" ]; then
        echo "Error: $1 is not set" >&2
        exit 1
    fi
}

update_direct_target() {
    local BRANCH="$1"
    local BASE_BRANCH="$2"

    echo "Updating direct target $BRANCH (from $MERGED_BRANCH to $BASE_BRANCH)"
    git_cmd checkout "$BRANCH"

    ORIGINAL_HEAD=$(git_cmd rev-parse HEAD)
    git_cmd merge --no-edit "origin/$MERGED_BRANCH"
    git_cmd merge --no-edit "${SQUASH_COMMIT}~"
    git_cmd merge --no-edit -s ours "$SQUASH_COMMIT"

    TREE_HASH=$(git_cmd rev-parse "HEAD^{tree}")
    COMMIT_MSG="Merge updates from $BASE_BRANCH and squash commit"
    CUSTOM_COMMIT=$(git_cmd commit-tree "$TREE_HASH" -p "$ORIGINAL_HEAD" -p "origin/$MERGED_BRANCH" -p "$SQUASH_COMMIT" -m "$COMMIT_MSG")
    git_cmd reset --hard "$CUSTOM_COMMIT"
}

update_indirect_target() {
    local BRANCH="$1"
    local BASE_BRANCH="$2"

    echo "Updating indirect target $BRANCH (based on $BASE_BRANCH)"
    git_cmd checkout "$BRANCH"
    git_cmd merge --no-edit "origin/$BASE_BRANCH"
}

ALL_CHILDREN=()
update_branch_recursive() {
    local BRANCH="$1"
    local BASE_BRANCH="$2"

    # Find and update branches based on this one
    CHILD_BRANCHES=$(gh pr list --base "$BRANCH" --json headRefName --jq '.[].headRefName')
    ALL_CHILDREN+=($CHILD_BRANCHES)
    for CHILD_BRANCH in $CHILD_BRANCHES; do
        update_indirect_target "$CHILD_BRANCH" "$BRANCH"
        update_branch_recursive "$CHILD_BRANCH" "$BRANCH"
    done
}

main() {
    # Check required environment variables
    check_env_var "SQUASH_COMMIT"
    check_env_var "MERGED_BRANCH"
    check_env_var "TARGET_BRANCH"

    # Find all PRs directly targeting the merged PR's head
    INITIAL_TARGETS=($(gh pr list --base "$MERGED_BRANCH" --json headRefName --jq '.[].headRefName'))

    for BRANCH in "${INITIAL_TARGETS[@]}"; do
        update_direct_target "$BRANCH" "$TARGET_BRANCH"
        update_branch_recursive "$BRANCH" "$TARGET_BRANCH"
    done

    # Update base branches for direct target PRs
    for BRANCH in "${INITIAL_TARGETS[@]}"; do
        gh pr edit "$BRANCH" --base "$TARGET_BRANCH"
    done

    # Push all updated branches and delete the merged branch
    git_cmd push origin ":$MERGED_BRANCH" "${INITAL_TARGETS[@]}" "${ALL_CHILDREN[@]}"
}

# Only run main() if the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi

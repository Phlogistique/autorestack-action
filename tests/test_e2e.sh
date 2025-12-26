#!/bin/bash
# =============================================================================
# End-to-End Test for the update-pr-stack Action
# =============================================================================
#
# PURPOSE:
# This test validates the full functionality of the update-pr-stack GitHub
# Action, which automatically updates stacked PRs after a base PR is merged.
#
# WARNING: This test creates and deletes a REAL GitHub repository.
# It requires a GITHUB_TOKEN environment variable with appropriate permissions:
# repo (full control), workflow, pull_request (write).
#
# =============================================================================
# TEST SCENARIOS
# =============================================================================
#
# SCENARIO 0: Diff Validation Test (Steps 0a-0j)
# -----------------------------------------------
# This scenario validates that the action correctly preserves PR diffs by
# testing TWO separate stacks:
#
# Part A - Without Action (proves diffs break):
#   - Create 3-PR stack: main <- noact_feature1 <- noact_feature2 <- noact_feature3
#   - Each PR modifies line 3 of file.txt
#   - Capture initial diffs (each should show only 1 line change)
#   - Merge noact_feature1 into main (no action runs - not installed yet)
#   - Verify noact_feature2's diff is NOW BROKEN (shows accumulated changes)
#
# Part B - With Action (proves diffs are preserved):
#   - Install the action workflow
#   - Create 3-PR stack: main <- act_feature1 <- act_feature2 <- act_feature3
#   - Each PR modifies line 4 of file.txt
#   - Capture initial diffs (each should show only 1 line change)
#   - Merge act_feature1 into main (action runs and updates stack)
#   - Wait for action to complete
#   - Verify act_feature2 and act_feature3 diffs are IDENTICAL to initial diffs
#
# This approach avoids race conditions by observing the broken state at leisure
# (no action to race against), then verifying the fixed state after action runs.
#
# SCENARIO 1: Nominal Linear Stack with Clean Merges (Steps 1-7)
# --------------------------------------------------------------
# Tests the happy path where PRs are merged without conflicts.
#
# Setup:
#   - Create a stack of 4 PRs: main <- feature1 <- feature2 <- feature3 <- feature4
#   - Each PR modifies line 2 of file.txt (same line, different content)
#
# Action Trigger:
#   - Squash merge PR1 (feature1) into main
#
# Expected Behavior:
#   - The action should detect that PR2 (feature2) was based on feature1
#   - Update PR2's base branch from feature1 to main
#   - Merge main into feature2 to incorporate the squash commit
#   - Propagate the merge to feature3 and feature4 as well
#   - Delete the merged branch (feature1)
#
# Verifications:
#   - feature1 branch is deleted from remote
#   - PR2 base branch is updated from feature1 to main
#   - PR3 base branch remains feature2 (only direct children are updated)
#   - feature2, feature3, and feature4 branches contain the squash merge commit
#   - PR diffs show the correct changes relative to their new bases
#
# SCENARIO 2: Conflict Handling (Steps 8-13)
# ------------------------------------------
# Tests the action's behavior when a merge conflict occurs.
#
# Setup:
#   - After Scenario 1, modify line 7 on feature3 and push
#   - Also modify line 7 on main with different content (creating a conflict)
#   - feature4 (grandchild) exists based on feature3
#
# Action Trigger:
#   - Squash merge PR2 (feature2) into main
#
# Expected Behavior:
#   - The action attempts to merge main into feature3
#   - Detects a merge conflict (both modified line 7 differently)
#   - Does NOT push any conflicted state to the remote
#   - Posts a comment on PR3 explaining the conflict
#   - Adds a label "autorestack-needs-conflict-resolution" to PR3
#   - Does NOT update PR3's base branch (keeps it as feature2 for readable diff)
#   - Does NOT delete feature2 branch (still referenced by conflicted PR)
#   - Exits with success (conflict is handled gracefully, not a failure)
#
# Verifications:
#   - feature2 branch is NOT deleted from remote (still referenced by conflicted PR3)
#   - PR3 base branch stays as feature2 (not updated to main)
#   - Conflict comment exists on PR3
#   - Conflict label "autorestack-needs-conflict-resolution" exists on PR3
#   - feature3 branch was NOT updated (still at pre-conflict SHA)
#
# Manual Conflict Resolution (Steps 12-15):
#   - Test simulates user resolving the conflict manually
#   - Merge main into feature3, resolve conflict (keep feature3's changes)
#   - Push the resolved branch
#   - The push triggers the 'synchronize' event on PR3
#   - The action detects the conflict label and removes it
#   - Updates PR3's base branch to main
#   - Deletes feature2 branch (no other conflicted PRs depend on it)
#   - The continuation workflow updates feature4 (grandchild) recursively
#   - Verify the label is removed, base updated, branch deleted, and feature4 is updated
#
# Grandchild Update (feature4):
#   - Tests that update_branch_recursive properly handles grandchildren
#   - Even when SQUASH_COMMIT is undefined (in conflict-resolved mode)
#   - The skip_if_clean guard must handle the missing SQUASH_COMMIT ref
#
# =============================================================================
set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Debugging: print commands as they are executed
# --- Configuration ---
# Temporary repository name prefix
REPO_PREFIX="temp-e2e-test-stack-"

# Generate a unique repository name
REPO_NAME=$(echo "$REPO_PREFIX$(date +%s)-$RANDOM" | tr '[:upper:]' '[:lower:]')

# Get GitHub username
# Default to 'autorestack-test' if GH_USER is not set or empty
: ${GH_USER:=autorestack-test}
REPO_FULL_NAME="$GH_USER/$REPO_NAME"

# Get the directory of the currently executing script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# Source command utils for logging
source "$PROJECT_ROOT/command_utils.sh"

# Workflow file name
WORKFLOW_FILE="update-pr-stack.yml"

# --- Helper Functions ---
cleanup() {
  local exit_code=$?
  # If PRESERVE_ON_FAILURE is set and there was an error, skip cleanup
  if [[ "${PRESERVE_ON_FAILURE:-}" == "1" ]] && [[ $exit_code -ne 0 ]]; then
    echo >&2 "--- Preserving repo for debugging (PRESERVE_ON_FAILURE=1) ---"
    echo >&2 "Repo: $REPO_FULL_NAME"
    echo >&2 "Local dir: $TEST_DIR"
    return 0
  fi

  echo >&2 "--- Cleaning up ---"
  if [[ -d "$TEST_DIR" ]]; then
    echo >&2 "Removing local test directory: $TEST_DIR"
    rm -rf "$TEST_DIR"
  fi
  # Check if repo exists before attempting deletion
  if gh repo view "$REPO_FULL_NAME" &> /dev/null; then
      echo >&2 "Deleting remote GitHub repository: $REPO_FULL_NAME"
      if ! gh repo delete "$REPO_FULL_NAME" --yes; then
          echo >&2 "Failed to delete repository $REPO_FULL_NAME. Please delete it manually."
          else
          echo >&2 "Successfully deleted remote repository $REPO_FULL_NAME."
      fi
  else
      echo >&2 "Remote repository $REPO_FULL_NAME does not exist or was already deleted."
  fi

}

# Trap EXIT signal to ensure cleanup runs even if the script fails
trap cleanup EXIT


# Get the full PR diff from GitHub.
# This captures GitHub's view of what the PR changes (head vs base).
# Used to verify the action preserves correct diff semantics.
get_pr_diff() {
    local pr_url=$1
    gh pr diff "$pr_url" --repo "$REPO_FULL_NAME" 2>/dev/null
}

# Compare two diffs and return 0 if identical, 1 if different.
# Also prints a message describing the result.
compare_diffs() {
    local diff1="$1"
    local diff2="$2"
    local context="$3"

    if [[ "$diff1" == "$diff2" ]]; then
        echo >&2 "✅ Diffs match: $context"
        return 0
    else
        echo >&2 "❌ Diffs differ: $context"
        echo >&2 "--- Expected diff ---"
        echo "$diff1" >&2
        echo >&2 "--- Actual diff ---"
        echo "$diff2" >&2
        echo >&2 "--------------------"
        return 1
    fi
}

# Merge a PR with retry logic to handle transient "not mergeable" errors.
# After pushing to a PR's base branch, GitHub's mergeability computation is async
# and can take several seconds. During this time, merge attempts fail with
# "Pull Request is not mergeable" even when there's no actual conflict.
# See: https://github.com/cli/cli/issues/8092
#      https://github.com/orgs/community/discussions/24462
merge_pr_with_retry() {
    local pr_url=$1
    local max_attempts=5
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        echo >&2 "Merge attempt $attempt/$max_attempts for $pr_url..."

        if log_cmd gh pr merge "$pr_url" --squash --repo "$REPO_FULL_NAME" 2>&1; then
            echo >&2 "PR merged successfully on attempt $attempt."
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            local sleep_time=$((attempt * 2))
            echo >&2 "Merge failed, retrying in ${sleep_time}s..."
            sleep $sleep_time
        fi
    done

    echo >&2 "Failed to merge PR after $max_attempts attempts."
    return 1
}

wait_for_synchronize_workflow() {
    local pr_number=$1 # PR number that was updated
    local branch_name=$2 # The branch name that was pushed
    local expected_conclusion=${3:-success} # Expected conclusion (success, failure, etc.)
    local max_attempts=20 # ~7 mins max wait
    local attempt=0
    local target_run_id=""
    local start_time=$(date +%s)

    echo >&2 "Waiting for workflow '$WORKFLOW_FILE' triggered by synchronize event on PR #$pr_number (branch $branch_name)..."

    while [[ $attempt -lt $max_attempts ]]; do
        sleep_time=$(( (attempt + 1) * 2 ))
        echo >&2 "Attempt $((attempt + 1))/$max_attempts: Checking for workflow run..."

        if [[ -z "$target_run_id" ]]; then
            echo >&2 "Searching for the specific workflow run..."
            # List recent runs for the workflow triggered by pull_request event
            candidate_run_ids=$(log_cmd gh run list \
                --repo "$REPO_FULL_NAME" \
                --workflow "$WORKFLOW_FILE" \
                --event pull_request \
                --limit 15 \
                --json databaseId,createdAt --jq '.[] | select(.createdAt >= "'$(date -d "@$start_time" -Iseconds 2>/dev/null || date -r $start_time +%Y-%m-%dT%H:%M:%S)'") | .databaseId' || echo "")

            if [[ -z "$candidate_run_ids" ]]; then
                echo >&2 "No recent '$WORKFLOW_FILE' runs found since start. Sleeping $sleep_time seconds."
                sleep $sleep_time
                attempt=$((attempt + 1))
                continue
            fi

            echo >&2 "Found candidate run IDs: $candidate_run_ids. Checking runs..."
            for run_id in $candidate_run_ids; do
                echo >&2 "Checking candidate run ID: $run_id"
                run_info=$(log_cmd gh run view "$run_id" --repo "$REPO_FULL_NAME" --json headBranch,jobs || echo "{}")

                run_head_branch=$(echo "$run_info" | jq -r '.headBranch // ""')
                # Check if this run has the continue-after-conflict-resolution job
                has_continue_job=$(echo "$run_info" | jq -r '.jobs[] | select(.name == "continue-after-conflict-resolution") | .name' || echo "")

                echo >&2 "  Run head branch: $run_head_branch, has continue job: $has_continue_job"

                if [[ "$run_head_branch" == "$branch_name" && -n "$has_continue_job" ]]; then
                    echo >&2 "Found matching workflow run ID: $run_id (synchronize with continue job)"
                    target_run_id="$run_id"
                    break
                fi
            done
        fi

        if [[ -z "$target_run_id" ]]; then
            echo >&2 "Target workflow run not found among recent runs. Sleeping $sleep_time seconds."
            sleep $sleep_time
            attempt=$((attempt + 1))
            continue
        fi

        # Monitor the identified target run
        echo >&2 "Monitoring workflow run ID: $target_run_id"
        run_info=$(log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --json status,conclusion)
        run_status=$(echo "$run_info" | jq -r '.status')
        run_conclusion=$(echo "$run_info" | jq -r '.conclusion')

        echo >&2 "Workflow run $target_run_id status: $run_status, conclusion: $run_conclusion"

        if [[ "$run_status" == "completed" ]]; then
            if [[ "$run_conclusion" == "$expected_conclusion" ]]; then
                echo >&2 "Workflow $target_run_id completed with expected conclusion: $run_conclusion."
                return 0
            else
                echo >&2 "Workflow $target_run_id completed with unexpected conclusion: $run_conclusion (expected: $expected_conclusion)"
                log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $target_run_id"
                return 1
            fi
        elif [[ "$run_status" == "queued" || "$run_status" == "in_progress" || "$run_status" == "waiting" ]]; then
            echo >&2 "Workflow $target_run_id is $run_status. Sleeping $sleep_time seconds."
        else
            echo >&2 "Workflow $target_run_id has unexpected status: $run_status. Conclusion: $run_conclusion"
            log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $target_run_id"
            return 1
        fi

        sleep $sleep_time
        attempt=$((attempt + 1))
    done

    echo >&2 "Timeout waiting for synchronize workflow run to complete."
    gh run list --repo "$REPO_FULL_NAME" --workflow "$WORKFLOW_FILE" --limit 10 || echo >&2 "Could not list recent runs."
    return 1
}

wait_for_workflow() {
    local pr_number=$1 # PR number that was merged
    local merged_branch_name=$2 # The head branch name of the merged PR (unused now, but kept for context)
    local merge_commit_sha=$3 # The SHA of the merge commit
    local expected_conclusion=${4:-success} # Expected conclusion (success, failure, etc.)
    local max_attempts=20 # Increased attempts (~7 mins max wait)
    local attempt=0
    local target_run_id=""

    echo >&2 "Waiting for workflow '$WORKFLOW_FILE' triggered by merge of PR #$pr_number (merge commit $merge_commit_sha)..."

    while [[ $attempt -lt $max_attempts ]]; do
        # Calculate sleep time: increases with attempts
        sleep_time=$(( (attempt + 1) * 2 ))
        echo >&2 "Attempt $((attempt + 1))/$max_attempts: Checking for workflow run..."

        # If we haven't found the target run ID yet, search for it
        if [[ -z "$target_run_id" ]]; then
            echo >&2 "Searching for the specific workflow run..."
            # List recent runs for the specific workflow triggered by pull_request event
            candidate_run_ids=$(log_cmd gh run list \
                --repo "$REPO_FULL_NAME" \
                --workflow "$WORKFLOW_FILE" \
                --event pull_request \
                --limit 10 \
                --json databaseId --jq '.[].databaseId' || echo "") # Get IDs, handle potential errors

            if [[ -z "$candidate_run_ids" ]]; then
                echo >&2 "No recent '$WORKFLOW_FILE' runs found for 'pull_request' event. Sleeping $sleep_time seconds."
                sleep $sleep_time
                attempt=$((attempt + 1))
                continue # Go to next attempt
            fi

            echo >&2 "Found candidate run IDs: $candidate_run_ids. Checking runs..."
            for run_id in $candidate_run_ids; do
                echo >&2 "Checking candidate run ID: $run_id"
                run_info=$(log_cmd gh run view "$run_id" --repo "$REPO_FULL_NAME" --json headBranch,headSha || echo "{}") # Fetch run info, default to empty JSON on error

                # Check if the run matches our merged branch
                run_head_branch=$(echo "$run_info" | jq -r '.headBranch // ""')
                run_head_sha=$(echo "$run_info" | jq -r '.headSha // ""')

                echo >&2 "  Run head branch: $run_head_branch, head SHA: $run_head_sha"
                echo >&2 "  Expected merged branch: $merged_branch_name, merge commit SHA: $merge_commit_sha"

                # For pull_request events, the workflow runs on the PR's head branch
                # Match by the head branch being the merged branch name
                if [[ "$run_head_branch" == "$merged_branch_name" ]]; then
                    echo >&2 "Found matching workflow run ID: $run_id (headBranch matches merged branch)"
                    target_run_id="$run_id"
                    break # Found the run, exit the inner loop
                else
                     echo >&2 "Run $run_id does not match the merge event criteria."
                fi
            done
        fi

        # If we still haven't found the run ID after checking candidates, wait and retry listing
        if [[ -z "$target_run_id" ]]; then
            echo >&2 "Target workflow run not found among recent runs. Sleeping $sleep_time seconds."
            sleep $sleep_time
            attempt=$((attempt + 1))
            continue # Go to next attempt
        fi

        # --- Monitor the identified target run ---
        echo >&2 "Monitoring workflow run ID: $target_run_id"
        run_info=$(log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --json status,conclusion)
        run_status=$(echo "$run_info" | jq -r '.status')
        run_conclusion=$(echo "$run_info" | jq -r '.conclusion') # Might be null if not completed

        echo >&2 "Workflow run $target_run_id status: $run_status, conclusion: $run_conclusion"

        if [[ "$run_status" == "completed" ]]; then
            if [[ "$run_conclusion" == "$expected_conclusion" ]]; then
                echo >&2 "Workflow $target_run_id completed with expected conclusion: $run_conclusion."
                return 0
            else
                echo >&2 "Workflow $target_run_id completed with unexpected conclusion: $run_conclusion (expected: $expected_conclusion)"
                log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $target_run_id"
                return 1
            fi
        elif [[ "$run_status" == "queued" || "$run_status" == "in_progress" || "$run_status" == "waiting" ]]; then
            echo >&2 "Workflow $target_run_id is $run_status. Sleeping $sleep_time seconds."
        else
            echo >&2 "Workflow $target_run_id has unexpected status: $run_status. Conclusion: $run_conclusion"
            log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $target_run_id"
            return 1
        fi

        sleep $sleep_time
        attempt=$((attempt + 1))
    done

    echo >&2 "Timeout waiting for workflow run triggered by merge of PR #$pr_number (merge commit $merge_commit_sha) to complete with conclusion $expected_conclusion."
    # List recent runs for debugging
    echo >&2 "Recent runs for workflow '$WORKFLOW_FILE':"
    gh run list --repo "$REPO_FULL_NAME" --workflow "$WORKFLOW_FILE" --limit 10 || echo >&2 "Could not list recent runs."
    return 1
}

# --- Test Execution ---
echo >&2 "--- Starting E2E Test ---"

# 1. Setup local repository
echo >&2 "1. Setting up local test repository..."
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
echo >&2 "Created test directory: $TEST_DIR"
log_cmd git init -b main
log_cmd git config user.email "test-e2e@example.com"
log_cmd git config user.name "E2E Test Bot"

# Create initial content with enough lines for context separation
# (Git needs ~3 lines of context between changes to avoid treating them as overlapping hunks)
echo "Base file content line 1" > file.txt
echo "Base file content line 2" >> file.txt
echo "Base file content line 3" >> file.txt
echo "Base file content line 4" >> file.txt
echo "Base file content line 5" >> file.txt
echo "Base file content line 6" >> file.txt
echo "Base file content line 7" >> file.txt
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
INITIAL_COMMIT_SHA=$(git rev-parse HEAD)

# 2. Create remote GitHub repository
echo >&2 "2. Creating remote GitHub repository: $REPO_FULL_NAME"

log_cmd gh repo create "$REPO_FULL_NAME" --description "Temporary E2E test repo for update-pr-stack action" --public
echo >&2 "Successfully created $REPO_FULL_NAME"

# Enable GitHub Actions on the new repository (may be disabled by default in CI environments)
echo >&2 "Enabling GitHub Actions on the repository..."
log_cmd gh api -X PUT "/repos/$REPO_FULL_NAME/actions/permissions" --input - <<< '{"enabled":true,"allowed_actions":"all"}'

# 3. Push initial state
echo >&2 "3. Pushing initial state to remote..."
REMOTE_URL="https://github.com/$REPO_FULL_NAME.git"
log_cmd git remote add origin "$REMOTE_URL"

log_cmd git push -u origin main

# =============================================================================
# SCENARIO 0: Diff Validation Test
# =============================================================================
# This scenario validates that the action correctly preserves PR diffs.
# It runs TWO separate stacks:
#   1. Without the action installed: proves diffs break after merge
#   2. With the action installed: proves diffs are preserved
#
# This avoids race conditions since we observe the "broken" state at leisure
# (no action runs to fix it), then verify the "fixed" state after action runs.
# =============================================================================

echo >&2 "--- SCENARIO 0: Diff Validation Test ---"

# --- Part A: Create stack WITHOUT the action, verify diffs break ---
echo >&2 "0a. Creating 'no action' stack to verify diffs break without the action..."

# Create 3 PRs for the no-action test (using prefix 'noact_')
# IMPORTANT: Each feature changes a DIFFERENT line so that after retarget,
# the diff clearly shows accumulated changes (multiple lines instead of just one)
log_cmd git checkout main
log_cmd git checkout -b noact_feature1 main
sed -i '3s/.*/NoAct Feature 1 line 3/' file.txt  # Feature 1 changes LINE 3
log_cmd git add file.txt
log_cmd git commit -m "NoAct: Add feature 1"
log_cmd git push origin noact_feature1
NOACT_PR1_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head noact_feature1 --title "NoAct Feature 1" --body "NoAct PR 1")
NOACT_PR1_NUM=$(echo "$NOACT_PR1_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created NoAct PR #$NOACT_PR1_NUM: $NOACT_PR1_URL"

log_cmd git checkout -b noact_feature2 noact_feature1
sed -i '4s/.*/NoAct Feature 2 line 4/' file.txt  # Feature 2 changes LINE 4 (different!)
log_cmd git add file.txt
log_cmd git commit -m "NoAct: Add feature 2"
log_cmd git push origin noact_feature2
NOACT_PR2_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base noact_feature1 --head noact_feature2 --title "NoAct Feature 2" --body "NoAct PR 2, based on NoAct PR 1")
NOACT_PR2_NUM=$(echo "$NOACT_PR2_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created NoAct PR #$NOACT_PR2_NUM: $NOACT_PR2_URL"

log_cmd git checkout -b noact_feature3 noact_feature2
sed -i '5s/.*/NoAct Feature 3 line 5/' file.txt  # Feature 3 changes LINE 5 (different!)
log_cmd git add file.txt
log_cmd git commit -m "NoAct: Add feature 3"
log_cmd git push origin noact_feature3
NOACT_PR3_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base noact_feature2 --head noact_feature3 --title "NoAct Feature 3" --body "NoAct PR 3, based on NoAct PR 2")
NOACT_PR3_NUM=$(echo "$NOACT_PR3_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created NoAct PR #$NOACT_PR3_NUM: $NOACT_PR3_URL"

# Capture initial diffs (each should show only 1 line change)
echo >&2 "0b. Capturing initial diffs for 'no action' stack..."
NOACT_PR1_DIFF_INITIAL=$(get_pr_diff "$NOACT_PR1_URL")
NOACT_PR2_DIFF_INITIAL=$(get_pr_diff "$NOACT_PR2_URL")
NOACT_PR3_DIFF_INITIAL=$(get_pr_diff "$NOACT_PR3_URL")

# Verify each PR initially shows only its own single line change
# PR1 should show "NoAct Feature 1", PR2 should show "NoAct Feature 2", etc.
echo >&2 "Verifying initial diffs show only 1 line change each..."
NOACT_PR1_CHANGES=$(echo "$NOACT_PR1_DIFF_INITIAL" | grep -c '^+NoAct Feature 1' || true)
NOACT_PR2_CHANGES=$(echo "$NOACT_PR2_DIFF_INITIAL" | grep -c '^+NoAct Feature 2' || true)
NOACT_PR3_CHANGES=$(echo "$NOACT_PR3_DIFF_INITIAL" | grep -c '^+NoAct Feature 3' || true)

# Also verify NO cross-contamination (PR2 shouldn't show Feature 1's changes)
NOACT_PR2_POLLUTION=$(echo "$NOACT_PR2_DIFF_INITIAL" | grep -c '^+NoAct Feature 1' || true)

if [[ "$NOACT_PR1_CHANGES" -eq 1 && "$NOACT_PR2_CHANGES" -eq 1 && "$NOACT_PR3_CHANGES" -eq 1 && "$NOACT_PR2_POLLUTION" -eq 0 ]]; then
    echo >&2 "✅ Initial diffs correct: each PR shows exactly its own 1 line change"
else
    echo >&2 "❌ Initial diffs incorrect: PR1=$NOACT_PR1_CHANGES, PR2=$NOACT_PR2_CHANGES, PR3=$NOACT_PR3_CHANGES, PR2 pollution=$NOACT_PR2_POLLUTION"
    exit 1
fi

# Merge bottom PR WITHOUT the action installed
echo >&2 "0c. Merging NoAct PR1 (without action installed)..."
merge_pr_with_retry "$NOACT_PR1_URL"
echo >&2 "NoAct PR1 merged."

# Manually retarget PR2 to main to simulate the "broken" state.
# This must be done BEFORE deleting the branch to keep the PR open.
#
# In practice, this happens when:
# - GitHub auto-retargets (depending on repo settings)
# - A user manually changes the base branch
# - A tool like "gh pr edit --base" is used
#
# Without the autorestack action, when you retarget to main, the diff becomes
# "polluted" because it now shows ALL changes from the head branch relative to main,
# not just the incremental changes from the previous PR in the stack.
echo >&2 "0d. Retargeting PR2 to main to demonstrate broken diff state..."
log_cmd gh pr edit "$NOACT_PR2_NUM" --repo "$REPO_FULL_NAME" --base main

# Wait for GitHub to process the base change
sleep 3

NOACT_PR2_DIFF_AFTER_RETARGET=$(get_pr_diff "$NOACT_PR2_URL")

# Debug: Show the actual diffs to see the difference
echo >&2 "--- Initial PR2 diff (vs noact_feature1) ---"
echo "$NOACT_PR2_DIFF_INITIAL" >&2
echo >&2 "--- After retarget PR2 diff (vs main) ---"
echo "$NOACT_PR2_DIFF_AFTER_RETARGET" >&2
echo >&2 "------------------------"

# The diff should now be "polluted":
# - Initial diff (vs noact_feature1): shows only Feature2's line 4 change
# - After retarget (vs main): shows BOTH Feature1's line 3 AND Feature2's line 4 changes
# This is the "broken" state - the PR now shows accumulated changes instead of incremental.

# Check for pollution: after retarget, PR2's diff should now include Feature1's changes
NOACT_PR2_POLLUTION_AFTER=$(echo "$NOACT_PR2_DIFF_AFTER_RETARGET" | grep -c 'NoAct Feature 1' || true)

if [[ "$NOACT_PR2_POLLUTION_AFTER" -gt 0 ]]; then
    echo >&2 "✅ Confirmed: PR2 diff is now POLLUTED with Feature1's changes (broken state demonstrated)"
    echo >&2 "   Initial: only Feature2 changes visible"
    echo >&2 "   After retarget: Feature1 changes also visible (pollution=$NOACT_PR2_POLLUTION_AFTER)"
else
    echo >&2 "❌ Unexpected: PR2 diff does NOT show Feature1's changes after retarget."
    echo >&2 "Expected the diff to be polluted with accumulated changes."
    exit 1
fi

# Now delete the merged branch (cleanup)
echo >&2 "Deleting noact_feature1 branch..."
log_cmd git push origin --delete noact_feature1

# --- Part B: Install the action and create a new stack ---
echo >&2 "0e. Installing action and workflow..."

log_cmd git checkout main
log_cmd git pull origin main

# Copy action files
cp "$PROJECT_ROOT/action.yml" .
cp "$PROJECT_ROOT/update-pr-stack.sh" .
cp "$PROJECT_ROOT/command_utils.sh" .

# Create workflow file pointing to the local action
mkdir -p .github/workflows
cat > .github/workflows/"$WORKFLOW_FILE" <<EOF
name: Update Stacked PRs on Squash Merge (E2E Test)
on:
  pull_request:
    types: [closed, synchronize]
permissions:
  contents: write
  pull-requests: write
jobs:
  update-pr-stack:
    # Only run on actual squash merges initiated by the test script
    if: |
      github.event.action == 'closed' &&
      github.event.pull_request.merged == true &&
      github.event.pull_request.merge_commit_sha != ''
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          # Fetch all history for all branches and tags
          fetch-depth: 0
          # Use a PAT token for checkout to allow pushing updates
          token: \${{ secrets.GITHUB_TOKEN }}
      - name: Update PR stack
        # Use the action from the current repository checkout
        uses: ./
        with:
          github-token: \${{ secrets.GITHUB_TOKEN }}
  continue-after-conflict-resolution:
    # Run when a PR with the conflict label is updated (user pushed conflict resolution)
    if: |
      github.event.action == 'synchronize' &&
      contains(github.event.pull_request.labels.*.name, 'autorestack-needs-conflict-resolution')
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: \${{ secrets.GITHUB_TOKEN }}
      - name: Continue PR stack update after conflict resolution
        uses: ./
        with:
          github-token: \${{ secrets.GITHUB_TOKEN }}
          mode: conflict-resolved
          pr-branch: \${{ github.event.pull_request.head.ref }}
EOF

log_cmd git add action.yml update-pr-stack.sh command_utils.sh .github/workflows/"$WORKFLOW_FILE"
log_cmd git commit -m "Add action and workflow files"
log_cmd git push origin main

echo >&2 "0f. Creating 'with action' stack to verify diffs are preserved..."

# Create 3 PRs for the with-action test (using prefix 'act_')
# IMPORTANT: Each feature changes a DIFFERENT line (using 6, 7 to avoid overlap with noact_ stack's 3, 4, 5)
log_cmd git checkout -b act_feature1 main
sed -i '6s/.*/Act Feature 1 line 6/' file.txt  # Feature 1 changes LINE 6
log_cmd git add file.txt
log_cmd git commit -m "Act: Add feature 1"
log_cmd git push origin act_feature1
ACT_PR1_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head act_feature1 --title "Act Feature 1" --body "Act PR 1")
ACT_PR1_NUM=$(echo "$ACT_PR1_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created Act PR #$ACT_PR1_NUM: $ACT_PR1_URL"

log_cmd git checkout -b act_feature2 act_feature1
sed -i '7s/.*/Act Feature 2 line 7/' file.txt  # Feature 2 changes LINE 7 (different!)
log_cmd git add file.txt
log_cmd git commit -m "Act: Add feature 2"
log_cmd git push origin act_feature2
ACT_PR2_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base act_feature1 --head act_feature2 --title "Act Feature 2" --body "Act PR 2, based on Act PR 1")
ACT_PR2_NUM=$(echo "$ACT_PR2_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created Act PR #$ACT_PR2_NUM: $ACT_PR2_URL"

log_cmd git checkout -b act_feature3 act_feature2
sed -i '2s/.*/Act Feature 3 line 2/' file.txt  # Feature 3 changes LINE 2 (different!)
log_cmd git add file.txt
log_cmd git commit -m "Act: Add feature 3"
log_cmd git push origin act_feature3
ACT_PR3_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base act_feature2 --head act_feature3 --title "Act Feature 3" --body "Act PR 3, based on Act PR 2")
ACT_PR3_NUM=$(echo "$ACT_PR3_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created Act PR #$ACT_PR3_NUM: $ACT_PR3_URL"

# Capture initial diffs
echo >&2 "0g. Capturing initial diffs for 'with action' stack..."
ACT_PR1_DIFF_INITIAL=$(get_pr_diff "$ACT_PR1_URL")
ACT_PR2_DIFF_INITIAL=$(get_pr_diff "$ACT_PR2_URL")
ACT_PR3_DIFF_INITIAL=$(get_pr_diff "$ACT_PR3_URL")

# Verify initial diffs are correct (each PR shows only its own 1 line change)
ACT_PR1_CHANGES=$(echo "$ACT_PR1_DIFF_INITIAL" | grep -c '^+Act Feature 1' || true)
ACT_PR2_CHANGES=$(echo "$ACT_PR2_DIFF_INITIAL" | grep -c '^+Act Feature 2' || true)
ACT_PR3_CHANGES=$(echo "$ACT_PR3_DIFF_INITIAL" | grep -c '^+Act Feature 3' || true)

# Also verify NO cross-contamination (PR2's diff shouldn't ADD Feature 1's changes)
# Use ^+ to only match actual additions, not context lines
ACT_PR2_POLLUTION=$(echo "$ACT_PR2_DIFF_INITIAL" | grep -c '^+.*Act Feature 1' || true)

if [[ "$ACT_PR1_CHANGES" -eq 1 && "$ACT_PR2_CHANGES" -eq 1 && "$ACT_PR3_CHANGES" -eq 1 && "$ACT_PR2_POLLUTION" -eq 0 ]]; then
    echo >&2 "✅ Initial diffs correct: each Act PR shows exactly its own 1 line change"
else
    echo >&2 "❌ Initial diffs incorrect: PR1=$ACT_PR1_CHANGES, PR2=$ACT_PR2_CHANGES, PR3=$ACT_PR3_CHANGES, PR2 pollution=$ACT_PR2_POLLUTION"
    exit 1
fi

# Merge bottom PR WITH the action installed
echo >&2 "0h. Merging Act PR1 (with action installed)..."
merge_pr_with_retry "$ACT_PR1_URL"
ACT_MERGE_COMMIT_SHA=$(gh pr view "$ACT_PR1_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
echo >&2 "Act PR1 merged. Merge commit SHA: $ACT_MERGE_COMMIT_SHA"

# Wait for the action to run
echo >&2 "0i. Waiting for action to update the stack..."
if ! wait_for_workflow "$ACT_PR1_NUM" "act_feature1" "$ACT_MERGE_COMMIT_SHA" "success"; then
    echo >&2 "Action workflow did not complete successfully."
    exit 1
fi

# Verify diffs are PRESERVED (identical to initial)
echo >&2 "0j. Verifying diffs are PRESERVED after action ran..."
ACT_PR2_DIFF_AFTER=$(get_pr_diff "$ACT_PR2_URL")
ACT_PR3_DIFF_AFTER=$(get_pr_diff "$ACT_PR3_URL")

# Debug: show the diffs
echo >&2 "--- Act PR2 diff after action ---"
echo "$ACT_PR2_DIFF_AFTER" >&2
echo >&2 "------------------------"

# Verify no pollution (PR2's diff should still not ADD Feature 1's changes)
# Use ^+ to only match actual additions, not context lines
ACT_PR2_POLLUTION_AFTER=$(echo "$ACT_PR2_DIFF_AFTER" | grep -c '^+.*Act Feature 1' || true)
if [[ "$ACT_PR2_POLLUTION_AFTER" -gt 0 ]]; then
    echo >&2 "❌ Act PR2 diff is polluted with Feature 1's changes after action"
    echo >&2 "The action should preserve incremental diffs, but pollution found."
    exit 1
fi
echo >&2 "✅ Act PR2 diff has no pollution (Feature 1 not added in diff)"

if compare_diffs "$ACT_PR2_DIFF_INITIAL" "$ACT_PR2_DIFF_AFTER" "Act PR2 diff preserved"; then
    echo >&2 "✅ Act PR2 diff is identical before and after merge+action"
else
    echo >&2 "❌ Act PR2 diff changed - action did not preserve diff correctly"
    exit 1
fi

if compare_diffs "$ACT_PR3_DIFF_INITIAL" "$ACT_PR3_DIFF_AFTER" "Act PR3 diff preserved"; then
    echo >&2 "✅ Act PR3 diff is identical before and after merge+action"
else
    echo >&2 "❌ Act PR3 diff changed - action did not preserve diff correctly"
    exit 1
fi

echo >&2 "--- SCENARIO 0 PASSED: Diff validation test successful ---"
echo >&2 "  - Without action: diffs broke as expected"
echo >&2 "  - With action: diffs preserved correctly"


# 4. Create stacked PRs
echo >&2 "4. Creating stacked branches and PRs..."
# Branch feature1 (base: main)
log_cmd git checkout -b feature1 main
sed -i '2s/.*/Feature 1 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 1"
log_cmd git push origin feature1
PR1_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head feature1 --title "Feature 1" --body "This is PR 1")
PR1_NUM=$(echo "$PR1_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR1_NUM: $PR1_URL"
# Branch feature2 (base: feature1)
log_cmd git checkout -b feature2 feature1
sed -i '2s/.*/Feature 2 content line 2/' file.txt # Edit line 2 again
log_cmd git add file.txt
log_cmd git commit -m "Add feature 2"
log_cmd git push origin feature2
PR2_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature1 --head feature2 --title "Feature 2" --body "This is PR 2, based on PR 1")
PR2_NUM=$(echo "$PR2_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR2_NUM: $PR2_URL"
# Branch feature3 (base: feature2)
log_cmd git checkout -b feature3 feature2
sed -i '2s/.*/Feature 3 content line 2/' file.txt # Edit line 2 again
log_cmd git add file.txt
log_cmd git commit -m "Add feature 3"
log_cmd git push origin feature3
PR3_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature2 --head feature3 --title "Feature 3" --body "This is PR 3, based on PR 2")
PR3_NUM=$(echo "$PR3_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR3_NUM: $PR3_URL"

# Branch feature4 (base: feature3) - tests grandchildren in conflict resolution
log_cmd git checkout -b feature4 feature3
sed -i '2s/.*/Feature 4 content line 2/' file.txt # Edit line 2 again
log_cmd git add file.txt
log_cmd git commit -m "Add feature 4"
log_cmd git push origin feature4
PR4_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature3 --head feature4 --title "Feature 4" --body "This is PR 4, based on PR 3 (grandchild for conflict resolution test)")
PR4_NUM=$(echo "$PR4_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR4_NUM: $PR4_URL"

# --- Initial Merge Scenario ---
echo >&2 "--- Testing Initial Merge (PR1) ---"

# 5. Trigger Action by Squash Merging PR1
echo >&2 "5. Squash merging PR #$PR1_NUM to trigger the action..."
merge_pr_with_retry "$PR1_URL"
MERGE_COMMIT_SHA1=$(gh pr view "$PR1_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
if [[ -z "$MERGE_COMMIT_SHA1" ]]; then
    echo >&2 "Failed to get merge commit SHA for PR #$PR1_NUM."
    exit 1
fi
echo >&2 "PR #$PR1_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA1"
# 6. Wait for the workflow to complete
echo >&2 "6. Waiting for the 'Update Stacked PRs' workflow (triggered by PR1 merge) to complete..."
if ! wait_for_workflow "$PR1_NUM" "feature1" "$MERGE_COMMIT_SHA1" "success"; then
    echo >&2 "Workflow for PR1 merge did not complete successfully."
    exit 1
fi
# 7. Verification for Initial Merge
echo >&2 "7. Verifying the results of the initial merge..."
echo >&2 "Fetching latest state from remote..."
log_cmd git fetch origin --prune # Prune deleted branches like feature1
# Verify feature1 branch was deleted remotely
if git show-ref --verify --quiet refs/remotes/origin/feature1; then
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature1' still exists."
    exit 1
else
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature1' was deleted."
fi
# Verify PR2 base branch was updated
echo >&2 "Checking PR #$PR2_NUM base branch..."
PR2_BASE=$(log_cmd gh pr view "$PR2_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR2_BASE" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR2_NUM base branch updated to 'main'."
else
    echo >&2 "❌ Verification Failed: PR #$PR2_NUM base branch is '$PR2_BASE', expected 'main'."
    exit 1
fi
# Verify PR3 base branch is still feature2 (action should only update direct children's base)
echo >&2 "Checking PR #$PR3_NUM base branch..."
PR3_BASE=$(log_cmd gh pr view "$PR3_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR3_BASE" == "feature2" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR3_NUM base branch remains 'feature2'."
else
    echo >&2 "❌ Verification Failed: PR #$PR3_NUM base branch is '$PR3_BASE', expected 'feature2'."
    exit 1
fi
# Verify local branches are updated to include the squash commit
echo >&2 "Checking if branches incorporate the squash commit..."
log_cmd git checkout feature2 # Checkout local branch first
log_cmd git pull origin feature2 # Pull updates pushed by the action
log_cmd git checkout feature3
log_cmd git pull origin feature3
log_cmd git checkout feature4
log_cmd git pull origin feature4

# Check ancestry
if log_cmd git merge-base --is-ancestor "$MERGE_COMMIT_SHA1" feature2; then
    echo >&2 "✅ Verification Passed: feature2 correctly incorporates the squash commit $MERGE_COMMIT_SHA1."
else
    echo >&2 "❌ Verification Failed: feature2 does not include the squash commit $MERGE_COMMIT_SHA1."
    log_cmd git log --graph --oneline feature2 main
    exit 1
fi
if log_cmd git merge-base --is-ancestor "$MERGE_COMMIT_SHA1" feature3; then
    echo >&2 "✅ Verification Passed: feature3 correctly incorporates the squash commit $MERGE_COMMIT_SHA1."
else
    echo >&2 "❌ Verification Failed: feature3 does not include the squash commit $MERGE_COMMIT_SHA1."
    log_cmd git log --graph --oneline feature3 main
    exit 1
fi
if log_cmd git merge-base --is-ancestor "$MERGE_COMMIT_SHA1" feature4; then
    echo >&2 "✅ Verification Passed: feature4 correctly incorporates the squash commit $MERGE_COMMIT_SHA1."
else
    echo >&2 "❌ Verification Failed: feature4 does not include the squash commit $MERGE_COMMIT_SHA1."
    log_cmd git log --graph --oneline feature4 main
    exit 1
fi
# Verify diffs (using triple-dot diff against the *new* base: main)
echo >&2 "Verifying diff content for updated PRs..."
# Expected diff for feature2 vs main (should only contain feature2 changes relative to feature1)
# Note: The content check here is tricky because the base changed. We check the PR diff on GitHub.
EXPECTED_DIFF2_CONTENT="Feature 2 content line 2"
ACTUAL_DIFF2_CONTENT=$(log_cmd gh pr diff "$PR2_URL" --repo "$REPO_FULL_NAME" | grep '^+Feature 2' | sed 's/^+//')

if [[ "$ACTUAL_DIFF2_CONTENT" == "$EXPECTED_DIFF2_CONTENT" ]]; then
    echo >&2 "✅ Verification Passed: Diff content for PR #$PR2_NUM seems correct."
else
    echo >&2 "❌ Verification Failed: Diff content for PR #$PR2_NUM is incorrect."
    echo "Expected Added Line Content: $EXPECTED_DIFF2_CONTENT"
    echo "Actual Added Line Content: $ACTUAL_DIFF2_CONTENT"
    gh pr diff "$PR2_URL" --repo "$REPO_FULL_NAME"
    exit 1
fi

# Expected diff for feature3 vs feature2 (should only contain feature3 changes relative to feature2)
EXPECTED_DIFF3_CONTENT="Feature 3 content line 2"
ACTUAL_DIFF3_CONTENT=$(log_cmd gh pr diff "$PR3_URL" --repo "$REPO_FULL_NAME" | grep '^+Feature 3' | sed 's/^+//')

if [[ "$ACTUAL_DIFF3_CONTENT" == "$EXPECTED_DIFF3_CONTENT" ]]; then
    echo >&2 "✅ Verification Passed: Diff content for PR #$PR3_NUM seems correct."
else
    echo >&2 "❌ Verification Failed: Diff content for PR #$PR3_NUM is incorrect."
    echo "Expected Added Line Content: $EXPECTED_DIFF3_CONTENT"
    echo "Actual Added Line Content: $ACTUAL_DIFF3_CONTENT"
    gh pr diff "$PR3_URL" --repo "$REPO_FULL_NAME"
    exit 1
fi

# Expected diff for feature4 vs feature3 (should only contain feature4 changes relative to feature3)
EXPECTED_DIFF4_CONTENT="Feature 4 content line 2"
ACTUAL_DIFF4_CONTENT=$(log_cmd gh pr diff "$PR4_URL" --repo "$REPO_FULL_NAME" | grep '^+Feature 4' | sed 's/^+//')

if [[ "$ACTUAL_DIFF4_CONTENT" == "$EXPECTED_DIFF4_CONTENT" ]]; then
    echo >&2 "✅ Verification Passed: Diff content for PR #$PR4_NUM seems correct."
else
    echo >&2 "❌ Verification Failed: Diff content for PR #$PR4_NUM is incorrect."
    echo "Expected Added Line Content: $EXPECTED_DIFF4_CONTENT"
    echo "Actual Added Line Content: $ACTUAL_DIFF4_CONTENT"
    gh pr diff "$PR4_URL" --repo "$REPO_FULL_NAME"
    exit 1
fi

echo >&2 "--- Initial Merge Test Completed Successfully ---"


# --- Conflict Scenario ---
echo >&2 "--- Testing Conflict Scenario (Merging PR2) ---"

# 8. Introduce conflicting changes
echo >&2 "8. Introducing conflicting changes..."
# Change line 7 on feature3 (far from line 2 to avoid adjacent-line conflicts)
log_cmd git checkout feature3
sed -i '7s/.*/Feature 3 conflicting change line 7/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Conflict: Modify line 7 on feature3"
FEATURE3_CONFLICT_COMMIT_SHA=$(git rev-parse HEAD) # Store this SHA
log_cmd git push origin feature3
# Change line 7 on main differently - this will conflict when rebasing feature3 after PR2 merge
log_cmd git checkout main
log_cmd git pull origin main  # Pull latest changes from PR1 merge
sed -i '7s/.*/Main conflicting change line 7/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Conflict: Modify line 7 on main"
log_cmd git push origin main

# 9. Trigger Action by Squash Merging PR2 (which is now based on the updated main from step 7)
echo >&2 "9. Squash merging PR #$PR2_NUM (feature2) to trigger conflict..."
merge_pr_with_retry "$PR2_URL"
MERGE_COMMIT_SHA2=$(gh pr view "$PR2_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
if [[ -z "$MERGE_COMMIT_SHA2" ]]; then
    echo >&2 "Failed to get merge commit SHA for PR #$PR2_NUM."
    exit 1
fi
echo >&2 "PR #$PR2_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA2"

# 10. Wait for the workflow to complete (it should succeed despite internal conflict)
echo >&2 "10. Waiting for the 'Update Stacked PRs' workflow (triggered by PR2 merge)..."
# The action itself should succeed because it posts a comment on conflict, not fail the run.
if ! wait_for_workflow "$PR2_NUM" "feature2" "$MERGE_COMMIT_SHA2" "success"; then
    echo >&2 "Workflow for PR2 merge did not complete successfully as expected."
    exit 1
fi

# 11. Verification for Conflict Scenario
echo >&2 "11. Verifying the results of the conflict scenario..."
echo >&2 "Fetching latest state from remote..."
log_cmd git fetch origin --prune

# Verify feature2 branch was NOT deleted (still referenced by conflicted PR3)
if git show-ref --verify --quiet refs/remotes/origin/feature2; then
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature2' still exists (kept for conflicted PR)."
else
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature2' was deleted prematurely."
    exit 1
fi

# Verify PR3 base branch was NOT updated (stays as feature2 for readable diff)
echo >&2 "Checking PR #$PR3_NUM base branch..."
PR3_BASE_AFTER_CONFLICT=$(log_cmd gh pr view "$PR3_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR3_BASE_AFTER_CONFLICT" == "feature2" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR3_NUM base branch stays as 'feature2' (not updated during conflict)."
else
    echo >&2 "❌ Verification Failed: PR #$PR3_NUM base branch is '$PR3_BASE_AFTER_CONFLICT', expected 'feature2'."
    exit 1
fi


# Verify conflict comment exists on PR3
echo >&2 "Checking for conflict comment on PR #$PR3_NUM..."
# Give GitHub some time to process the comment
sleep 5
CONFLICT_COMMENT=$(log_cmd gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json comments --jq '.comments[] | select(.body | contains("Automatic update blocked by merge conflicts")) | .body')
if [[ -n "$CONFLICT_COMMENT" ]]; then
    echo >&2 "✅ Verification Passed: Conflict comment found on PR #$PR3_NUM."
    echo "$CONFLICT_COMMENT" # Log the comment
else
    echo >&2 "❌ Verification Failed: Conflict comment not found on PR #$PR3_NUM."
    echo >&2 "--- Comments on PR #$PR3_NUM ---"
    gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json comments --jq '.comments[].body' || echo "Failed to get comments"
    echo >&2 "-----------------------------"
    exit 1
fi

# Verify conflict label exists on PR3
echo >&2 "Checking for conflict label on PR #$PR3_NUM..."
CONFLICT_LABEL=$(log_cmd gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ "$CONFLICT_LABEL" == "autorestack-needs-conflict-resolution" ]]; then
    echo >&2 "✅ Verification Passed: Conflict label 'autorestack-needs-conflict-resolution' found on PR #$PR3_NUM."
else
    echo >&2 "❌ Verification Failed: Conflict label not found on PR #$PR3_NUM."
    echo >&2 "--- Labels on PR #$PR3_NUM ---"
    gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[].name' || echo "Failed to get labels"
    echo >&2 "-----------------------------"
    exit 1
fi

# Verify feature3 branch was NOT pushed with conflicts (check its head SHA)
REMOTE_FEATURE3_SHA_BEFORE_RESOLVE=$(log_cmd git rev-parse "refs/remotes/origin/feature3")
# The action failed the merge locally, so it shouldn't have pushed feature3.
# The remote SHA should still be the one from step 8 ("Conflict: Modify line 3 on feature3").
EXPECTED_FEATURE3_SHA_BEFORE_RESOLVE=$FEATURE3_CONFLICT_COMMIT_SHA
if [[ "$REMOTE_FEATURE3_SHA_BEFORE_RESOLVE" == "$EXPECTED_FEATURE3_SHA_BEFORE_RESOLVE" ]]; then
     echo >&2 "✅ Verification Passed: Remote feature3 branch was not updated by the action due to conflict."
else
     echo >&2 "❌ Verification Failed: Remote feature3 branch SHA ($REMOTE_FEATURE3_SHA_BEFORE_RESOLVE) differs from expected SHA before conflict resolution ($EXPECTED_FEATURE3_SHA_BEFORE_RESOLVE)."
     exit 1
fi


# 12. Resolve conflict manually
echo >&2 "12. Resolving conflict manually on feature3..."
log_cmd git checkout feature3
# Ensure we have the latest main which includes the PR2 merge commit AND the conflicting change on main
log_cmd git fetch origin
# Now, perform the merge that the action tried and failed
echo >&2 "Attempting merge of origin/main into feature3..."
if git merge origin/main; then
    echo >&2 "❌ Conflict Resolution Failed: Merge of main into feature3 succeeded unexpectedly (no conflict?)"
    log_cmd git status
    log_cmd git log --graph --oneline --all
    exit 1
else
    echo >&2 "Merge conflict occurred as expected. Resolving..."
    # Check status to confirm conflict
    log_cmd git status
    # Resolve conflict - keep feature3's version (ours) of the conflicting file
    # This preserves both line 2 (Feature 3 content) and line 7 (Feature 3 conflicting change)
    log_cmd git checkout --ours file.txt
    echo "Resolved file.txt content:"
    cat file.txt
    log_cmd git add file.txt
    # Use 'git commit' without '-m' to use the default merge commit message
    log_cmd git commit --no-edit
    echo >&2 "Conflict resolved and committed."
fi
log_cmd git push origin feature3
echo >&2 "Pushed resolved feature3."

# 13. Wait for continuation workflow triggered by push
echo >&2 "13. Waiting for continuation workflow after conflict resolution push..."
if ! wait_for_synchronize_workflow "$PR3_NUM" "feature3" "success"; then
    echo >&2 "Continuation workflow for feature3 conflict resolution did not complete successfully."
    exit 1
fi

# 14. Verify continuation workflow effects
echo >&2 "14. Verifying continuation workflow effects..."

# Verify conflict label was removed from PR3
echo >&2 "Checking that conflict label was removed from PR #$PR3_NUM..."
sleep 5 # Give GitHub time to process
CONFLICT_LABEL_AFTER=$(log_cmd gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ -z "$CONFLICT_LABEL_AFTER" ]]; then
    echo >&2 "✅ Verification Passed: Conflict label was removed from PR #$PR3_NUM."
else
    echo >&2 "❌ Verification Failed: Conflict label still exists on PR #$PR3_NUM."
    exit 1
fi

# Verify PR3 base branch was updated to main after resolution
echo >&2 "Checking PR #$PR3_NUM base branch after resolution..."
PR3_BASE_AFTER_RESOLUTION=$(log_cmd gh pr view "$PR3_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR3_BASE_AFTER_RESOLUTION" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR3_NUM base branch updated to 'main' after resolution."
else
    echo >&2 "❌ Verification Failed: PR #$PR3_NUM base branch is '$PR3_BASE_AFTER_RESOLUTION', expected 'main'."
    exit 1
fi

# Verify feature2 was deleted after resolution (no other conflicted PRs depend on it)
echo >&2 "Checking that feature2 branch was deleted after resolution..."
log_cmd git fetch origin --prune
if git show-ref --verify --quiet refs/remotes/origin/feature2; then
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature2' still exists after resolution."
    exit 1
else
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature2' was deleted after resolution."
fi

echo >&2 "--- Continuation Workflow Test Completed Successfully ---"

# 15. Verify conflict resolution (content checks)
echo >&2 "15. Verifying conflict resolution content..."
# Fetch the latest state again
log_cmd git fetch origin
log_cmd git checkout feature3
log_cmd git pull origin feature3
log_cmd git checkout feature4
log_cmd git pull origin feature4

# Verify feature3 now incorporates main (including PR2 merge commit and main's conflict commit)
if log_cmd git merge-base --is-ancestor origin/main feature3; then
    echo >&2 "✅ Verification Passed: Resolved feature3 correctly incorporates main."
else
    echo >&2 "❌ Verification Failed: Resolved feature3 does not include main."
    log_cmd git log --graph --oneline feature3 origin/main
    exit 1
fi

# Verify feature4 (grandchild) was updated by continuation workflow
# This tests that update_branch_recursive properly handles grandchildren even when SQUASH_COMMIT is undefined
if log_cmd git merge-base --is-ancestor origin/feature3 feature4; then
    echo >&2 "✅ Verification Passed: feature4 (grandchild) correctly incorporates resolved feature3."
else
    echo >&2 "❌ Verification Failed: feature4 does not include the resolved feature3."
    log_cmd git log --graph --oneline feature4 feature3
    exit 1
fi

# Verify the final content of file.txt on feature3
# Line 1: Original base
# Line 2: From feature 3 commit ("Feature 3 content line 2")
# Line 7: From feature 3 conflict commit, kept during resolution ("Feature 3 conflicting change line 7")
log_cmd git checkout feature3
EXPECTED_CONTENT_LINE1="Base file content line 1"
EXPECTED_CONTENT_LINE2="Feature 3 content line 2"
EXPECTED_CONTENT_LINE7="Feature 3 conflicting change line 7"

ACTUAL_CONTENT_LINE1=$(sed -n '1p' file.txt)
ACTUAL_CONTENT_LINE2=$(sed -n '2p' file.txt)
ACTUAL_CONTENT_LINE7=$(sed -n '7p' file.txt)

if [[ "$ACTUAL_CONTENT_LINE1" == "$EXPECTED_CONTENT_LINE1" && \
      "$ACTUAL_CONTENT_LINE2" == "$EXPECTED_CONTENT_LINE2" && \
      "$ACTUAL_CONTENT_LINE7" == "$EXPECTED_CONTENT_LINE7" ]]; then
    echo >&2 "✅ Verification Passed: file.txt content on resolved feature3 is correct."
else
    echo >&2 "❌ Verification Failed: file.txt content on resolved feature3 is incorrect."
    echo "Expected:"
    echo "$EXPECTED_CONTENT_LINE1"
    echo "$EXPECTED_CONTENT_LINE2"
    echo "$EXPECTED_CONTENT_LINE7"
    echo "Actual:"
    cat file.txt
    exit 1
fi

echo >&2 "--- Conflict Scenario Test Completed Successfully ---"


# --- SCENARIO 3: Sibling Conflicts (Multiple PRs from same base, both conflict) ---
# ===================================================================================
# Tests that the old base branch is kept until ALL sibling PRs resolve their conflicts.
#
# Setup:
#   - Create a new stack: main <- feature5 <- (feature6, feature7) parallel children
#   - feature6 and feature7 both modify line 5 of file.txt
#   - main modifies line 5 differently (creating conflict with both siblings)
#
# Expected Behavior:
#   - After merging feature5, both feature6 and feature7 have conflicts
#   - feature5 branch is kept (referenced by both conflicted PRs)
#   - After resolving feature6, feature5 is still kept (feature7 still conflicted)
#   - After resolving feature7, feature5 is deleted (no more conflicted siblings)
# ===================================================================================

echo >&2 "--- Testing Sibling Conflicts Scenario ---"

# 16. Create new stack for sibling conflict test
echo >&2 "16. Creating new stack for sibling conflict test..."
log_cmd git checkout main
log_cmd git pull origin main

# Create feature5 based on main (modifies line 2, no conflict with line 5)
log_cmd git checkout -b feature5 main
sed -i '2s/.*/Feature 5 content line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 5"
log_cmd git push origin feature5
PR5_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head feature5 --title "Feature 5" --body "This is PR 5")
PR5_NUM=$(echo "$PR5_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR5_NUM: $PR5_URL"

# Create feature6 based on feature5 (modifies line 5, will conflict with main)
log_cmd git checkout -b feature6 feature5
sed -i '5s/.*/Feature 6 conflicting content line 5/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 6 (modifies line 5)"
log_cmd git push origin feature6
PR6_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature5 --head feature6 --title "Feature 6" --body "This is PR 6, sibling of PR 7")
PR6_NUM=$(echo "$PR6_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR6_NUM: $PR6_URL"

# Create feature7 based on feature5 (also modifies line 5, will conflict with main)
log_cmd git checkout feature5
log_cmd git checkout -b feature7
sed -i '5s/.*/Feature 7 conflicting content line 5/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 7 (also modifies line 5)"
log_cmd git push origin feature7
PR7_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature5 --head feature7 --title "Feature 7" --body "This is PR 7, sibling of PR 6")
PR7_NUM=$(echo "$PR7_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR7_NUM: $PR7_URL"

# Introduce conflicting change on main (line 5) - this will conflict with feature6/7
# when the action tries to merge SQUASH_COMMIT~ into them
log_cmd git checkout main
sed -i '5s/.*/Main conflicting content line 5/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add conflicting change on main line 5"
log_cmd git push origin main

# 17. Merge feature5 to trigger conflicts on both siblings
echo >&2 "17. Squash merging PR #$PR5_NUM (feature5) to trigger sibling conflicts..."
merge_pr_with_retry "$PR5_URL"
MERGE_COMMIT_SHA5=$(gh pr view "$PR5_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
echo >&2 "PR #$PR5_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA5"

# Wait for workflow
echo >&2 "Waiting for workflow..."
if ! wait_for_workflow "$PR5_NUM" "feature5" "$MERGE_COMMIT_SHA5" "success"; then
    echo >&2 "Workflow for PR5 merge did not complete successfully."
    exit 1
fi

# 18. Verify both siblings have conflicts and feature5 is kept
echo >&2 "18. Verifying sibling conflict state..."
log_cmd git fetch origin

# Verify feature5 branch was NOT deleted (both siblings conflicted)
if git show-ref --verify --quiet refs/remotes/origin/feature5; then
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature5' still exists (kept for conflicted siblings)."
else
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature5' was deleted prematurely."
    exit 1
fi

# Verify both PRs have conflict labels
PR6_HAS_LABEL=$(gh pr view "$PR6_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
PR7_HAS_LABEL=$(gh pr view "$PR7_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')

if [[ "$PR6_HAS_LABEL" == "autorestack-needs-conflict-resolution" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR6_NUM has conflict label."
else
    echo >&2 "❌ Verification Failed: PR #$PR6_NUM does not have conflict label."
    exit 1
fi

if [[ "$PR7_HAS_LABEL" == "autorestack-needs-conflict-resolution" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR7_NUM has conflict label."
else
    echo >&2 "❌ Verification Failed: PR #$PR7_NUM does not have conflict label."
    exit 1
fi

# Verify both PRs still have feature5 as base
PR6_BASE=$(gh pr view "$PR6_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
PR7_BASE=$(gh pr view "$PR7_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)

if [[ "$PR6_BASE" == "feature5" && "$PR7_BASE" == "feature5" ]]; then
    echo >&2 "✅ Verification Passed: Both sibling PRs still have 'feature5' as base."
else
    echo >&2 "❌ Verification Failed: PR6 base is '$PR6_BASE', PR7 base is '$PR7_BASE', expected both to be 'feature5'."
    exit 1
fi

# 19. Resolve first sibling (feature6) - feature5 should still be kept
echo >&2 "19. Resolving first sibling (feature6)..."
log_cmd git checkout feature6
log_cmd git fetch origin
if git merge origin/main; then
    echo >&2 "Merge succeeded unexpectedly (no conflict?)"
else
    echo >&2 "Resolving conflict on feature6..."
    log_cmd git checkout --ours file.txt
    log_cmd git add file.txt
    log_cmd git commit --no-edit
fi
log_cmd git push origin feature6

# Wait for continuation workflow
echo >&2 "Waiting for continuation workflow for feature6..."
if ! wait_for_synchronize_workflow "$PR6_NUM" "feature6" "success"; then
    echo >&2 "Continuation workflow for feature6 did not complete successfully."
    exit 1
fi

# 20. Verify feature5 is still kept (feature7 still conflicted)
echo >&2 "20. Verifying feature5 is still kept after first sibling resolution..."
log_cmd git fetch origin

# feature5 should still exist
if git show-ref --verify --quiet refs/remotes/origin/feature5; then
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature5' still exists (feature7 still conflicted)."
else
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature5' was deleted prematurely (feature7 still needs it)."
    exit 1
fi

# PR6 base should now be main
PR6_BASE_AFTER=$(gh pr view "$PR6_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR6_BASE_AFTER" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR6_NUM base updated to 'main' after resolution."
else
    echo >&2 "❌ Verification Failed: PR #$PR6_NUM base is '$PR6_BASE_AFTER', expected 'main'."
    exit 1
fi

# PR6 should no longer have conflict label
PR6_LABEL_AFTER=$(gh pr view "$PR6_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ -z "$PR6_LABEL_AFTER" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR6_NUM conflict label removed."
else
    echo >&2 "❌ Verification Failed: PR #$PR6_NUM still has conflict label."
    exit 1
fi

# PR7 should still have conflict label and feature5 as base
PR7_LABEL_STILL=$(gh pr view "$PR7_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
PR7_BASE_STILL=$(gh pr view "$PR7_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR7_LABEL_STILL" == "autorestack-needs-conflict-resolution" && "$PR7_BASE_STILL" == "feature5" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR7_NUM still has conflict label and 'feature5' base."
else
    echo >&2 "❌ Verification Failed: PR7 label='$PR7_LABEL_STILL', base='$PR7_BASE_STILL'."
    exit 1
fi

# 21. Resolve second sibling (feature7) - now feature5 should be deleted
echo >&2 "21. Resolving second sibling (feature7)..."
log_cmd git checkout feature7
log_cmd git fetch origin
if git merge origin/main; then
    echo >&2 "Merge succeeded unexpectedly (no conflict?)"
else
    echo >&2 "Resolving conflict on feature7..."
    log_cmd git checkout --ours file.txt
    log_cmd git add file.txt
    log_cmd git commit --no-edit
fi
log_cmd git push origin feature7

# Wait for continuation workflow
echo >&2 "Waiting for continuation workflow for feature7..."
if ! wait_for_synchronize_workflow "$PR7_NUM" "feature7" "success"; then
    echo >&2 "Continuation workflow for feature7 did not complete successfully."
    exit 1
fi

# 22. Verify feature5 is now deleted (all siblings resolved)
echo >&2 "22. Verifying feature5 is deleted after all siblings resolved..."
log_cmd git fetch origin --prune

if git show-ref --verify --quiet refs/remotes/origin/feature5; then
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature5' still exists after all siblings resolved."
    exit 1
else
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature5' was deleted after all siblings resolved."
fi

# PR7 base should now be main
PR7_BASE_FINAL=$(gh pr view "$PR7_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR7_BASE_FINAL" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR7_NUM base updated to 'main' after resolution."
else
    echo >&2 "❌ Verification Failed: PR #$PR7_NUM base is '$PR7_BASE_FINAL', expected 'main'."
    exit 1
fi

echo >&2 "--- Sibling Conflicts Scenario Test Completed Successfully ---"


# --- Test Succeeded ---
echo >&2 "--- E2E Test Completed Successfully! ---"

# Cleanup is handled by the trap

#!/bin/bash
# End-to-End test for the update-pr-stack action.
# WARNING: This test creates and deletes a REAL GitHub repository.
# It requires a GITHUB_TOKEN environment variable with appropriate permissions:
# repo (full control), workflow, pull_request (write).
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

# Create initial content
echo "Base file content line 1" > file.txt
echo "Base file content line 2" >> file.txt
echo "Base file content line 3" >> file.txt
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
INITIAL_COMMIT_SHA=$(git rev-parse HEAD)

# Copy action files
echo >&2 "Copying action files..."
cp "$PROJECT_ROOT/action.yml" .
cp "$PROJECT_ROOT/update-pr-stack.sh" .
cp "$PROJECT_ROOT/command_utils.sh" .

# Create workflow file pointing to the local action
echo >&2 "Creating workflow file..."
mkdir -p .github/workflows
cat > .github/workflows/"$WORKFLOW_FILE" <<EOF
name: Update Stacked PRs on Squash Merge (E2E Test)
on:
  pull_request:
    types: [closed]
permissions:
  contents: write
  pull-requests: write
jobs:
  update-pr-stack:
    # Only run on actual squash merges initiated by the test script
    if: |
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
EOF

log_cmd git add action.yml update-pr-stack.sh command_utils.sh .github/workflows/"$WORKFLOW_FILE"
log_cmd git commit -m "Add action and workflow files"
ACTION_COMMIT_SHA=$(git rev-parse HEAD)

# 2. Create remote GitHub repository
echo >&2 "2. Creating remote GitHub repository: $REPO_FULL_NAME"

log_cmd gh repo create "$REPO_FULL_NAME" --description "Temporary E2E test repo for update-pr-stack action" --public
echo >&2 "Successfully created $REPO_FULL_NAME"
# 3. Push initial state
echo >&2 "3. Pushing initial state to remote..."
REMOTE_URL="https://github.com/$REPO_FULL_NAME.git"
log_cmd git remote add origin "$REMOTE_URL"

log_cmd git push -u origin main
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

# --- Initial Merge Scenario ---
echo >&2 "--- Testing Initial Merge (PR1) ---"

# 5. Trigger Action by Squash Merging PR1
echo >&2 "5. Squash merging PR #$PR1_NUM to trigger the action..."
log_cmd gh pr merge "$PR1_URL" --squash --repo "$REPO_FULL_NAME"
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
log_cmd git checkout main # Ensure main is up-to-date locally
log_cmd git pull origin main
log_cmd git checkout feature2 # Checkout local branch first
log_cmd git pull origin feature2 # Pull updates pushed by the action
log_cmd git checkout feature3
log_cmd git pull origin feature3

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

echo >&2 "--- Initial Merge Test Completed Successfully ---"


# --- Conflict Scenario ---
echo >&2 "--- Testing Conflict Scenario (Merging PR2) ---"

# 8. Introduce conflicting change on main BEFORE merging PR2
echo >&2 "8. Introducing conflicting change on main..."
log_cmd git checkout main
sed -i '3s/.*/Main conflicting change line 3/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Conflict: Modify line 3 on main"
MAIN_CONFLICT_COMMIT_SHA=$(git rev-parse HEAD) # Store this SHA
log_cmd git push origin main

# 9. Introduce conflicting change on feature3 (this will conflict when the action tries to update it)
echo >&2 "9. Introducing conflicting change on feature3..."
log_cmd git checkout feature3
sed -i '3s/.*/Feature 3 conflicting change line 3/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Conflict: Modify line 3 on feature3"
FEATURE3_CONFLICT_COMMIT_SHA=$(git rev-parse HEAD) # Store this SHA
log_cmd git push origin feature3

# 10. Update PR2's branch to incorporate the new main commit
echo >&2 "10. Updating PR #$PR2_NUM branch to incorporate latest main..."
# This should succeed since feature2 doesn't modify line 3
gh api -X PUT "/repos/$REPO_FULL_NAME/pulls/$PR2_NUM/update-branch" --silent || {
    echo >&2 "Failed to update PR #$PR2_NUM branch"
    exit 1
}
# Wait a moment for GitHub to process the update
sleep 3

# 11. Merge PR2 to trigger the action (which should encounter a conflict updating PR3)
echo >&2 "11. Squash merging PR #$PR2_NUM (feature2) to trigger conflict scenario..."
log_cmd gh pr merge "$PR2_URL" --squash --repo "$REPO_FULL_NAME"
MERGE_COMMIT_SHA2=$(gh pr view "$PR2_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
if [[ -z "$MERGE_COMMIT_SHA2" ]]; then
    echo >&2 "Failed to get merge commit SHA for PR #$PR2_NUM."
    exit 1
fi
echo >&2 "PR #$PR2_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA2"

# 12. Wait for the workflow to complete (it should succeed despite internal conflict)
echo >&2 "12. Waiting for the 'Update Stacked PRs' workflow (triggered by PR2 merge)..."
# The action itself should succeed because it posts a comment on conflict, not fail the run.
if ! wait_for_workflow "$PR2_NUM" "feature2" "$MERGE_COMMIT_SHA2" "success"; then
    echo >&2 "Workflow for PR2 merge did not complete successfully as expected."
    exit 1
fi

# 13. Verification for Conflict Scenario
echo >&2 "13. Verifying the results of the conflict scenario..."
echo >&2 "Fetching latest state from remote..."
log_cmd git fetch origin --prune # Prune deleted branch feature2

# Verify feature2 branch was deleted remotely
if git show-ref --verify --quiet refs/remotes/origin/feature2; then
    echo >&2 "❌ Verification Failed: Remote branch 'origin/feature2' still exists after merge."
    exit 1
else
    echo >&2 "✅ Verification Passed: Remote branch 'origin/feature2' was deleted."
fi

# Verify PR3 base branch was updated to main (action updates base even on conflict)
echo >&2 "Checking PR #$PR3_NUM base branch..."
PR3_BASE_AFTER_CONFLICT=$(log_cmd gh pr view "$PR3_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR3_BASE_AFTER_CONFLICT" == "main" ]]; then
    echo >&2 "✅ Verification Passed: PR #$PR3_NUM base branch updated to 'main'."
else
    echo >&2 "❌ Verification Failed: PR #$PR3_NUM base branch is '$PR3_BASE_AFTER_CONFLICT', expected 'main'."
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


# 14. Resolve conflict manually
echo >&2 "14. Resolving conflict manually on feature3..."
log_cmd git checkout feature3
# Ensure we have the latest main which includes the PR2 merge commit AND the conflicting change on main
log_cmd git fetch origin
log_cmd git checkout main
log_cmd git pull origin main # Make sure local main is up-to-date
log_cmd git checkout feature3
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
    # Resolve conflict - let's keep the change from feature3 ("Feature 3 conflicting change line 3")
    # Remove conflict markers and keep the desired line 3
    sed -i '/<<<<<<< HEAD/,/=======/{//!d}' file.txt # Remove lines between <<<< and ==== (inclusive of <<<<)
    sed -i '/=======/,/>>>>>>> origin\/main/d' file.txt # Remove lines between ==== and >>>> (inclusive of ==== and >>>>)

    echo "Resolved file.txt content:"
    cat file.txt
    log_cmd git add file.txt
    # Use 'git commit' without '-m' to use the default merge commit message
    log_cmd git commit --no-edit
    echo >&2 "Conflict resolved and committed."
fi
log_cmd git push origin feature3
echo >&2 "Pushed resolved feature3."

# 15. Verify conflict resolution
echo >&2 "15. Verifying conflict resolution..."
# Fetch the latest state again
log_cmd git fetch origin
log_cmd git checkout main
log_cmd git pull origin main
log_cmd git checkout feature3
log_cmd git pull origin feature3

# Verify feature3 now incorporates main (including PR2 merge commit and main's conflict commit)
if log_cmd git merge-base --is-ancestor origin/main feature3; then
    echo >&2 "✅ Verification Passed: Resolved feature3 correctly incorporates main."
else
    echo >&2 "❌ Verification Failed: Resolved feature3 does not include main."
    log_cmd git log --graph --oneline feature3 origin/main
    exit 1
fi

# Verify the final content of file.txt on feature3
# Line 1: Original base
# Line 2: From feature 3 commit ("Feature 3 content line 2")
# Line 3: From feature 3 conflict commit, kept during resolution ("Feature 3 conflicting change line 3")
EXPECTED_CONTENT_LINE1="Base file content line 1"
EXPECTED_CONTENT_LINE2="Feature 3 content line 2"
EXPECTED_CONTENT_LINE3="Feature 3 conflicting change line 3"

ACTUAL_CONTENT_LINE1=$(sed -n '1p' file.txt)
ACTUAL_CONTENT_LINE2=$(sed -n '2p' file.txt)
ACTUAL_CONTENT_LINE3=$(sed -n '3p' file.txt)

if [[ "$ACTUAL_CONTENT_LINE1" == "$EXPECTED_CONTENT_LINE1" && \
      "$ACTUAL_CONTENT_LINE2" == "$EXPECTED_CONTENT_LINE2" && \
      "$ACTUAL_CONTENT_LINE3" == "$EXPECTED_CONTENT_LINE3" ]]; then
    echo >&2 "✅ Verification Passed: file.txt content on resolved feature3 is correct."
else
    echo >&2 "❌ Verification Failed: file.txt content on resolved feature3 is incorrect."
    echo "Expected:"
    echo "$EXPECTED_CONTENT_LINE1"
    echo "$EXPECTED_CONTENT_LINE2"
    echo "$EXPECTED_CONTENT_LINE3"
    echo "Actual:"
    cat file.txt
    exit 1
fi

# Optional: Verify the conflict label could be removed (manual step usually)
# We won't automate label removal check as the action doesn't do it.

echo >&2 "--- Conflict Scenario Test Completed Successfully ---"


# --- Test Succeeded ---
echo >&2 "--- E2E Test Completed Successfully! ---"

# Cleanup is handled by the trap

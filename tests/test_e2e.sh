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
: ${GH_USER=autorestack-test}
REPO_FULL_NAME="$GH_USER/$REPO_NAME"

# Get the directory of the currently executing script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# Source command utils for logging
source "$PROJECT_ROOT/command_utils.sh"

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
#trap cleanup EXIT

wait_for_workflow() {
    local branch=$1
    local max_attempts=11 # ~2 minutes max wait time
    local attempt=0
    local workflow_file="update-pr-stack.yml" # Name of the workflow file
    echo >&2 "Waiting for workflow triggered by merge commit $merge_commit_sha (PR #$pr_number)..."
    while [[ $attempt -lt $max_attempts ]]; do
        sleep=$(( 3**attempt / 2**attempt ))
        attempt=$((attempt + 1))

        if [[ -z "$run_id" ]]; then
            # List recent workflow runs for the specific workflow file on the main branch
            run_id=$(log_cmd gh run list \
                --repo "$REPO_FULL_NAME" \
                --json databaseId,headSha,status,conclusion \
                --event pull_request \
                --limit 1 \
                --branch $branch \
                --jq ".[] | .databaseId"
            )
        fi

        if [[ -z "$run_id" ]]; then
            echo >&2 "Workflow run for commit $merge_commit_sha not found yet (attempt $attempt/$max_attempts), sleeping $sleep seconds."
        else
            # Check the status of the specific run
            run_status=$(log_cmd gh run view "$run_id" --repo "$REPO_FULL_NAME" --json status --jq '.status')
            echo >&2 "Workflow run $run_id status: $run_status"
            if [[ "$run_status" == "completed" ]]; then
                run_conclusion=$(log_cmd gh run view "$run_id" --repo "$REPO_FULL_NAME" --json conclusion --jq '.conclusion')
                echo >&2 "Workflow run $run_id completed with conclusion: $run_conclusion"
                if [[ "$run_conclusion" == "success" ]]; then
                    echo >&2 "Workflow completed successfully."
                    return 0
                else
                    echo >&2 "Workflow failed with conclusion: $run_conclusion"
                    # Fetch logs for debugging
                    log_cmd gh run view "$run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $run_id"
                    return 1
                fi
            elif [[ "$run_status" == "queued" || "$run_status" == "in_progress" || "$run_status" == "waiting" ]]; then
                echo >&2 "Workflow is $run_status. (attempt $attempt/$max_attempts)"
            else
                echo >&2 "Workflow has unexpected status: $run_status"
                gh run view "$run_id" --repo "$REPO_FULL_NAME" --log || echo >&2 "Could not fetch logs for run $run_id"
                return 1
            fi
        fi

        sleep $sleep
    done


    if [[ -z "$run_id" ]]; then
        echo >&2 "Timeout waiting for workflow run to complete."
        return 1
    fi
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

# Copy action files
echo >&2 "Copying action files..."
cp "$PROJECT_ROOT/action.yml" .
cp "$PROJECT_ROOT/update-pr-stack.sh" .
cp "$PROJECT_ROOT/command_utils.sh" .

# Create workflow file pointing to the local action
echo >&2 "Creating workflow file..."
mkdir -p .github/workflows
cat > .github/workflows/update-pr-stack.yml <<'EOF'
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
          token: ${{ secrets.GITHUB_TOKEN }}
      - name: Update PR stack
        # Use the action from the current repository checkout
        uses: ./
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
EOF

log_cmd git add action.yml update-pr-stack.sh command_utils.sh .github/workflows/update-pr-stack.yml
log_cmd git commit -m "Add action and workflow files"

# 2. Create remote GitHub repository
echo >&2 "2. Creating remote GitHub repository: $REPO_FULL_NAME"

log_cmd gh repo create "$REPO_FULL_NAME" --description "Temporary E2E test repo for update-pr-stack action" --public
echo >&2 "Successfully created $REPO_FULL_NAME"
# 3. Push initial state
echo >&2 "3. Pushing initial state to remote..."
REMOTE_URL="https://github.com/$REPO_FULL_NAME.git"
log_cmd git remote add origin "$REMOTE_URL"

log_cmd git push -u origin main # Use force in case repo wasn't empty
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
sed -i '2s/.*/Feature 2 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 2"
log_cmd git push origin feature2
PR2_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature1 --head feature2 --title "Feature 2" --body "This is PR 2, based on PR 1")
PR2_NUM=$(echo "$PR2_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR2_NUM: $PR2_URL"
# Branch feature3 (base: feature2)
log_cmd git checkout -b feature3 feature2
sed -i '2s/.*/Feature 3 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 3"
log_cmd git push origin feature3
PR3_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature2 --head feature3 --title "Feature 3" --body "This is PR 3, based on PR 2")
PR3_NUM=$(echo "$PR3_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR3_NUM: $PR3_URL"
# 5. Trigger Action by Squash Merging PR1
echo >&2 "5. Squash merging PR #$PR1_NUM to trigger the action..."
log_cmd gh pr merge "$PR1_URL" --squash --repo "$REPO_FULL_NAME"
MERGE_COMMIT_SHA=$(gh pr view "$PR1_URL" --json mergeCommit -q .mergeCommit.oid)
if [[ -z "$MERGE_COMMIT_SHA" ]]; then
    echo >&2 "Failed to get merge commit SHA for PR #$PR1_NUM."
    exit 1
fi
echo >&2 "PR #$PR1_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA"
# 6. Wait for the workflow to complete
echo >&2 "6. Waiting for the 'Update Stacked PRs' workflow to complete..."
if ! wait_for_workflow feature1; then
    echo >&2 "Workflow did not complete successfully."
    exit 1
fi
# 7. Verification
echo >&2 "7. Verifying the results..."
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
log_cmd git checkout main
log_cmd git pull origin main # Ensure main is up-to-date locally
# Check ancestry
if log_cmd git merge-base --is-ancestor "$MERGE_COMMIT_SHA" feature2; then
    echo >&2 "✅ Verification Passed: feature2 correctly incorporates the squash commit."
else
    echo >&2 "❌ Verification Failed: feature2 does not include the squash commit."
    log_cmd git log --graph --oneline feature2 main
    exit 1
fi
if log_cmd git merge-base --is-ancestor "$MERGE_COMMIT_SHA" feature3; then
    echo >&2 "✅ Verification Passed: feature3 correctly incorporates the squash commit."
else
    echo >&2 "❌ Verification Failed: feature3 does not include the squash commit."
    log_cmd git log --graph --oneline feature3 main
    exit 1
fi
# Verify diffs (using triple-dot diff against the *new* base: main)
echo >&2 "Verifying diff content for updated PRs..."
# Expected diff for feature2 vs main (should only contain feature2 changes)
EXPECTED_DIFF2=$(cat <<EOF
diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -1,3 +1,3 @@
 Base file content line 1
-Feature 1 content line 2
+Feature 2 content line 2
 Base file content line 3
EOF
)
# Use range diff main...feature2
ACTUAL_DIFF2=$(log_cmd gh pr diff "$PR2_URL" | grep -v '^index') # Ignore index lines
if [[ "$NORM_ACTUAL_DIFF2" == "$NORM_EXPECTED_DIFF2" ]]; then
    echo >&2 "✅ Verification Passed: Diff for feature2 (main...feature2) is correct."
else
    echo >&2 "❌ Verification Failed: Diff for feature2 (main...feature2) is incorrect."
    echo "Expected Diff:"
    echo "$EXPECTED_DIFF2"
    echo "Actual Diff:"
    echo "$ACTUAL_DIFF2"
    exit 1
fi
# Expected diff for feature3 vs main (should contain feature2 + feature3 changes)
EXPECTED_DIFF3=$(cat <<EOF
diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -1,3 +1,3 @@
 Base file content line 1
-Feature 2 content line 2
+Feature 3 content line 2
 Base file content line 3
EOF
)
# Use range diff main...feature3
ACTUAL_DIFF3=$(log_cmd gh pr diff "$PR3_URL" | grep -v '^index') # Ignore index lines
# Normalize potential whitespace differences
NORM_EXPECTED_DIFF3=$(echo "$EXPECTED_DIFF3" | sed 's/ *$//')
NORM_ACTUAL_DIFF3=$(echo "$ACTUAL_DIFF3" | sed 's/ *$//')
if [[ "$NORM_ACTUAL_DIFF3" == "$NORM_EXPECTED_DIFF3" ]]; then
    echo >&2 "✅ Verification Passed: Diff for feature3 (feature2...feature3) is correct."
else
    echo >&2 "❌ Verification Failed: Diff for feature3 (feature2...feature3) is incorrect."
    echo "Expected Diff:"
    echo "$EXPECTED_DIFF3"
    echo "Actual Diff:"
    echo "$ACTUAL_DIFF3"
    exit 1
fi
# --- Test Succeeded ---
echo >&2 "--- E2E Test Completed Successfully! ---"

cleanup

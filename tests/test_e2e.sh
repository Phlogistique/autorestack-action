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
#
# REQUIRED ENVIRONMENT:
# - GITHUB_TOKEN or GH_TOKEN: Token with repo, workflow, pull_request permissions
#
# =============================================================================
# TEST APPROACH: BASELINE vs ACTION COMPARISON
# =============================================================================
#
# To prove the action actually fixes something, we run two scenarios:
#
# PHASE 0: BASELINE (no action installed)
# - Create a stack: main <- baseline-f1 <- baseline-f2
# - Capture baseline-f2's diff (shows only its own 1-line change)
# - Merge baseline-f1 into main (no action runs)
# - Capture baseline-f2's diff again - it's now "BROKEN" (shows 2 lines or different)
# - This proves what happens WITHOUT the action
#
# PHASE 1: WITH ACTION
# - Install the action workflow
# - Create a stack: main <- feature1 <- feature2 <- feature3 <- feature4
# - Capture each PR's diff before merge
# - Merge feature1, action runs and updates the stack
# - Verify each PR's diff is IDENTICAL to pre-merge (action preserved them)
#
# This approach requires no special permissions or environment protection.
#
# =============================================================================
# TEST SCENARIOS (after baseline)
# =============================================================================
#
# SCENARIO 1: Nominal Linear Stack with Clean Merges
# - Merge feature1, verify feature2/3/4 diffs are preserved
# - Verify base branches are updated correctly
#
# SCENARIO 2: Conflict Handling
# - Introduce conflicting changes on feature3 and main
# - Merge feature2, action detects conflict
# - Verify conflict comment and label on PR3
# - Manually resolve conflict, push
# - Verify continuation workflow updates grandchildren
#
# =============================================================================
set -e

# --- Configuration ---
REPO_PREFIX="temp-e2e-test-stack-"
REPO_NAME=$(echo "$REPO_PREFIX$(date +%s)-$RANDOM" | tr '[:upper:]' '[:lower:]')
: ${GH_USER:=autorestack-test}
REPO_FULL_NAME="$GH_USER/$REPO_NAME"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

source "$PROJECT_ROOT/command_utils.sh"

WORKFLOW_FILE="update-pr-stack.yml"

# --- Helper Functions ---
cleanup() {
  local exit_code=$?
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

trap cleanup EXIT

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

wait_for_workflow() {
    local pr_number=$1
    local merged_branch_name=$2
    local merge_commit_sha=$3
    local expected_conclusion=${4:-success}
    local max_attempts=20
    local attempt=0
    local target_run_id=""

    echo >&2 "Waiting for workflow '$WORKFLOW_FILE' triggered by merge of PR #$pr_number..."

    while [[ $attempt -lt $max_attempts ]]; do
        sleep_time=$(( (attempt + 1) * 2 ))
        echo >&2 "Attempt $((attempt + 1))/$max_attempts: Checking for workflow run..."

        if [[ -z "$target_run_id" ]]; then
            candidate_run_ids=$(log_cmd gh run list \
                --repo "$REPO_FULL_NAME" \
                --workflow "$WORKFLOW_FILE" \
                --event pull_request \
                --limit 10 \
                --json databaseId --jq '.[].databaseId' || echo "")

            if [[ -z "$candidate_run_ids" ]]; then
                echo >&2 "No recent runs found. Sleeping $sleep_time seconds."
                sleep $sleep_time
                attempt=$((attempt + 1))
                continue
            fi

            for run_id in $candidate_run_ids; do
                run_head_branch=$(log_cmd gh run view "$run_id" --repo "$REPO_FULL_NAME" --json headBranch --jq '.headBranch // ""' || echo "")
                if [[ "$run_head_branch" == "$merged_branch_name" ]]; then
                    echo >&2 "Found matching workflow run ID: $run_id"
                    target_run_id="$run_id"
                    break
                fi
            done
        fi

        if [[ -z "$target_run_id" ]]; then
            echo >&2 "Target run not found. Sleeping $sleep_time seconds."
            sleep $sleep_time
            attempt=$((attempt + 1))
            continue
        fi

        run_info=$(log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --json status,conclusion)
        run_status=$(echo "$run_info" | jq -r '.status')
        run_conclusion=$(echo "$run_info" | jq -r '.conclusion')

        echo >&2 "Run $target_run_id: status=$run_status, conclusion=$run_conclusion"

        if [[ "$run_status" == "completed" ]]; then
            if [[ "$run_conclusion" == "$expected_conclusion" ]]; then
                echo >&2 "Workflow completed with expected conclusion: $run_conclusion"
                return 0
            else
                echo >&2 "Workflow completed with unexpected conclusion: $run_conclusion"
                log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --log || true
                return 1
            fi
        fi

        sleep $sleep_time
        attempt=$((attempt + 1))
    done

    echo >&2 "Timeout waiting for workflow."
    return 1
}

wait_for_synchronize_workflow() {
    local pr_number=$1
    local branch_name=$2
    local expected_conclusion=${3:-success}
    local max_attempts=20
    local attempt=0
    local target_run_id=""
    local start_time=$(date +%s)

    echo >&2 "Waiting for synchronize workflow on PR #$pr_number..."

    while [[ $attempt -lt $max_attempts ]]; do
        sleep_time=$(( (attempt + 1) * 2 ))
        echo >&2 "Attempt $((attempt + 1))/$max_attempts..."

        if [[ -z "$target_run_id" ]]; then
            candidate_run_ids=$(log_cmd gh run list \
                --repo "$REPO_FULL_NAME" \
                --workflow "$WORKFLOW_FILE" \
                --event pull_request \
                --limit 15 \
                --json databaseId,createdAt --jq '.[] | select(.createdAt >= "'$(date -d "@$start_time" -Iseconds 2>/dev/null || date -r $start_time +%Y-%m-%dT%H:%M:%S)'") | .databaseId' || echo "")

            if [[ -z "$candidate_run_ids" ]]; then
                sleep $sleep_time
                attempt=$((attempt + 1))
                continue
            fi

            for run_id in $candidate_run_ids; do
                run_info=$(log_cmd gh run view "$run_id" --repo "$REPO_FULL_NAME" --json headBranch,jobs || echo "{}")
                run_head_branch=$(echo "$run_info" | jq -r '.headBranch // ""')
                has_continue_job=$(echo "$run_info" | jq -r '.jobs[] | select(.name == "continue-after-conflict-resolution") | .name' || echo "")

                if [[ "$run_head_branch" == "$branch_name" && -n "$has_continue_job" ]]; then
                    echo >&2 "Found matching run ID: $run_id"
                    target_run_id="$run_id"
                    break
                fi
            done
        fi

        if [[ -z "$target_run_id" ]]; then
            sleep $sleep_time
            attempt=$((attempt + 1))
            continue
        fi

        run_info=$(log_cmd gh run view "$target_run_id" --repo "$REPO_FULL_NAME" --json status,conclusion)
        run_status=$(echo "$run_info" | jq -r '.status')
        run_conclusion=$(echo "$run_info" | jq -r '.conclusion')

        if [[ "$run_status" == "completed" ]]; then
            if [[ "$run_conclusion" == "$expected_conclusion" ]]; then
                echo >&2 "Workflow completed successfully."
                return 0
            else
                echo >&2 "Workflow failed: $run_conclusion"
                return 1
            fi
        fi

        sleep $sleep_time
        attempt=$((attempt + 1))
    done

    echo >&2 "Timeout waiting for synchronize workflow."
    return 1
}

# Capture PR diff and normalize it for comparison
capture_pr_diff() {
    local pr_url=$1
    gh pr diff "$pr_url" --repo "$REPO_FULL_NAME" 2>/dev/null | grep -E '^[+-]' | grep -v '^[+-]{3}' || echo ""
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
cat > file.txt << 'FILECONTENT'
Base file content line 1
Base file content line 2
Base file content line 3
Base file content line 4
Base file content line 5
Base file content line 6
Base file content line 7
FILECONTENT
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"

# Copy action files (but NOT the workflow yet - we'll add it after baseline test)
echo >&2 "Copying action files (workflow will be added later)..."
cp "$PROJECT_ROOT/action.yml" .
cp "$PROJECT_ROOT/update-pr-stack.sh" .
cp "$PROJECT_ROOT/command_utils.sh" .
log_cmd git add action.yml update-pr-stack.sh command_utils.sh
log_cmd git commit -m "Add action files (no workflow yet)"

# 2. Create remote GitHub repository
echo >&2 "2. Creating remote GitHub repository: $REPO_FULL_NAME"
log_cmd gh repo create "$REPO_FULL_NAME" --description "Temporary E2E test repo" --public
echo >&2 "Successfully created $REPO_FULL_NAME"

echo >&2 "Enabling GitHub Actions..."
log_cmd gh api -X PUT "/repos/$REPO_FULL_NAME/actions/permissions" --input - <<< '{"enabled":true,"allowed_actions":"all"}'

# 3. Push initial state (WITHOUT workflow)
echo >&2 "3. Pushing initial state (no workflow installed)..."
REMOTE_URL="https://github.com/$REPO_FULL_NAME.git"
log_cmd git remote add origin "$REMOTE_URL"
log_cmd git push -u origin main

# =============================================================================
# PHASE 0: BASELINE TEST (without action)
# =============================================================================
# This proves what happens when a parent PR is merged WITHOUT the action:
# the child PR's diff becomes "broken" (shows accumulated changes)
# =============================================================================

echo >&2 ""
echo >&2 "=============================================="
echo >&2 "PHASE 0: BASELINE TEST (no action installed)"
echo >&2 "=============================================="

# Create baseline stack: main <- baseline-f1 <- baseline-f2
echo >&2 "Creating baseline stack..."

log_cmd git checkout -b baseline-f1 main
sed -i '2s/.*/Baseline Feature 1 line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Baseline feature 1"
log_cmd git push origin baseline-f1
BASELINE_PR1_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head baseline-f1 --title "Baseline F1" --body "Baseline PR 1")
BASELINE_PR1_NUM=$(echo "$BASELINE_PR1_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created baseline PR #$BASELINE_PR1_NUM"

log_cmd git checkout -b baseline-f2 baseline-f1
sed -i '2s/.*/Baseline Feature 2 line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Baseline feature 2"
log_cmd git push origin baseline-f2
BASELINE_PR2_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base baseline-f1 --head baseline-f2 --title "Baseline F2" --body "Baseline PR 2, based on F1")
BASELINE_PR2_NUM=$(echo "$BASELINE_PR2_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created baseline PR #$BASELINE_PR2_NUM"

# Capture baseline-f2's diff BEFORE merge
echo >&2 "Capturing baseline PR #$BASELINE_PR2_NUM diff BEFORE merge..."
BASELINE_DIFF_BEFORE=$(capture_pr_diff "$BASELINE_PR2_URL")
echo >&2 "Baseline diff before merge:"
echo "$BASELINE_DIFF_BEFORE" | head -10

# Merge baseline-f1 (no action will run - workflow not installed)
echo >&2 "Merging baseline PR #$BASELINE_PR1_NUM (no action installed)..."
merge_pr_with_retry "$BASELINE_PR1_URL"

# Wait a moment for GitHub to process
sleep 3

# Capture baseline-f2's diff AFTER merge (should be "broken")
echo >&2 "Capturing baseline PR #$BASELINE_PR2_NUM diff AFTER merge (expecting broken)..."
BASELINE_DIFF_AFTER=$(capture_pr_diff "$BASELINE_PR2_URL")
echo >&2 "Baseline diff after merge:"
echo "$BASELINE_DIFF_AFTER" | head -10

# Verify the diff changed (is "broken")
if [[ "$BASELINE_DIFF_BEFORE" == "$BASELINE_DIFF_AFTER" ]]; then
    echo >&2 "⚠️  Baseline diff did NOT change after merge."
    echo >&2 "   This might mean GitHub handles orphaned bases gracefully."
    echo >&2 "   Continuing with test, but diff preservation check may be less meaningful."
else
    echo >&2 "✅ BASELINE VERIFIED: Diff changed after merge (without action)."
    echo >&2 "   Before: $(echo "$BASELINE_DIFF_BEFORE" | wc -l) lines"
    echo >&2 "   After:  $(echo "$BASELINE_DIFF_AFTER" | wc -l) lines"
fi

echo >&2 ""
echo >&2 "=============================================="
echo >&2 "PHASE 1: ACTION TEST (with action installed)"
echo >&2 "=============================================="

# Install the workflow
echo >&2 "Installing action workflow..."
log_cmd git checkout main
log_cmd git pull origin main

mkdir -p .github/workflows
cat > .github/workflows/"$WORKFLOW_FILE" << 'EOF'
name: Update Stacked PRs on Squash Merge (E2E Test)
on:
  pull_request:
    types: [closed, synchronize]
permissions:
  contents: write
  pull-requests: write
jobs:
  update-pr-stack:
    if: |
      github.event.action == 'closed' &&
      github.event.pull_request.merged == true &&
      github.event.pull_request.merge_commit_sha != ''
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}
      - name: Update PR stack
        uses: ./
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
  continue-after-conflict-resolution:
    if: |
      github.event.action == 'synchronize' &&
      contains(github.event.pull_request.labels.*.name, 'autorestack-needs-conflict-resolution')
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}
      - name: Continue PR stack update after conflict resolution
        uses: ./
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          mode: conflict-resolved
          pr-branch: ${{ github.event.pull_request.head.ref }}
EOF

log_cmd git add .github/workflows/"$WORKFLOW_FILE"
log_cmd git commit -m "Add action workflow"
log_cmd git push origin main

# Create test stack: main <- feature1 <- feature2 <- feature3 <- feature4
echo >&2 "Creating test stack with action installed..."

log_cmd git checkout -b feature1 main
sed -i '2s/.*/Feature 1 content line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 1"
log_cmd git push origin feature1
PR1_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base main --head feature1 --title "Feature 1" --body "This is PR 1")
PR1_NUM=$(echo "$PR1_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR1_NUM: $PR1_URL"

log_cmd git checkout -b feature2 feature1
sed -i '2s/.*/Feature 2 content line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 2"
log_cmd git push origin feature2
PR2_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature1 --head feature2 --title "Feature 2" --body "This is PR 2")
PR2_NUM=$(echo "$PR2_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR2_NUM: $PR2_URL"

log_cmd git checkout -b feature3 feature2
sed -i '2s/.*/Feature 3 content line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 3"
log_cmd git push origin feature3
PR3_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature2 --head feature3 --title "Feature 3" --body "This is PR 3")
PR3_NUM=$(echo "$PR3_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR3_NUM: $PR3_URL"

log_cmd git checkout -b feature4 feature3
sed -i '2s/.*/Feature 4 content line 2/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 4"
log_cmd git push origin feature4
PR4_URL=$(log_cmd gh pr create --repo "$REPO_FULL_NAME" --base feature3 --head feature4 --title "Feature 4" --body "This is PR 4")
PR4_NUM=$(echo "$PR4_URL" | awk -F'/' '{print $NF}')
echo >&2 "Created PR #$PR4_NUM: $PR4_URL"

# Capture diffs BEFORE merge
echo >&2 "Capturing PR diffs BEFORE merge..."
DIFF2_BEFORE=$(capture_pr_diff "$PR2_URL")
DIFF3_BEFORE=$(capture_pr_diff "$PR3_URL")
DIFF4_BEFORE=$(capture_pr_diff "$PR4_URL")
echo >&2 "PR2 diff before: $(echo "$DIFF2_BEFORE" | wc -l) lines"
echo >&2 "PR3 diff before: $(echo "$DIFF3_BEFORE" | wc -l) lines"
echo >&2 "PR4 diff before: $(echo "$DIFF4_BEFORE" | wc -l) lines"

# --- Initial Merge Scenario ---
echo >&2 ""
echo >&2 "--- Testing Initial Merge (PR1) ---"

echo >&2 "Merging PR #$PR1_NUM to trigger the action..."
merge_pr_with_retry "$PR1_URL"
MERGE_COMMIT_SHA1=$(gh pr view "$PR1_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
echo >&2 "PR #$PR1_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA1"

echo >&2 "Waiting for action to complete..."
if ! wait_for_workflow "$PR1_NUM" "feature1" "$MERGE_COMMIT_SHA1" "success"; then
    echo >&2 "Workflow did not complete successfully."
    exit 1
fi

# Verify diffs are PRESERVED (identical to before merge)
echo >&2 "Verifying PR diffs are PRESERVED after action..."
DIFF2_AFTER=$(capture_pr_diff "$PR2_URL")
DIFF3_AFTER=$(capture_pr_diff "$PR3_URL")
DIFF4_AFTER=$(capture_pr_diff "$PR4_URL")

if [[ "$DIFF2_BEFORE" == "$DIFF2_AFTER" ]]; then
    echo >&2 "✅ PR #$PR2_NUM diff PRESERVED (identical to before merge)"
else
    echo >&2 "❌ PR #$PR2_NUM diff CHANGED after action"
    echo >&2 "Before:"
    echo "$DIFF2_BEFORE"
    echo >&2 "After:"
    echo "$DIFF2_AFTER"
    exit 1
fi

if [[ "$DIFF3_BEFORE" == "$DIFF3_AFTER" ]]; then
    echo >&2 "✅ PR #$PR3_NUM diff PRESERVED (identical to before merge)"
else
    echo >&2 "❌ PR #$PR3_NUM diff CHANGED after action"
    exit 1
fi

if [[ "$DIFF4_BEFORE" == "$DIFF4_AFTER" ]]; then
    echo >&2 "✅ PR #$PR4_NUM diff PRESERVED (identical to before merge)"
else
    echo >&2 "❌ PR #$PR4_NUM diff CHANGED after action"
    exit 1
fi

# Additional verifications
echo >&2 "Verifying branch states..."
log_cmd git fetch origin --prune

# Verify feature1 branch was deleted
if git show-ref --verify --quiet refs/remotes/origin/feature1; then
    echo >&2 "❌ feature1 branch still exists"
    exit 1
else
    echo >&2 "✅ feature1 branch deleted"
fi

# Verify PR2 base was updated
PR2_BASE=$(gh pr view "$PR2_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR2_BASE" == "main" ]]; then
    echo >&2 "✅ PR #$PR2_NUM base updated to main"
else
    echo >&2 "❌ PR #$PR2_NUM base is '$PR2_BASE', expected 'main'"
    exit 1
fi

# Verify branches contain merge commit
log_cmd git checkout feature2 && log_cmd git pull origin feature2
log_cmd git checkout feature3 && log_cmd git pull origin feature3
log_cmd git checkout feature4 && log_cmd git pull origin feature4

if git merge-base --is-ancestor "$MERGE_COMMIT_SHA1" feature2; then
    echo >&2 "✅ feature2 contains merge commit"
else
    echo >&2 "❌ feature2 missing merge commit"
    exit 1
fi

echo >&2 "--- Initial Merge Test Completed Successfully ---"

# --- Conflict Scenario ---
echo >&2 ""
echo >&2 "--- Testing Conflict Scenario (Merging PR2) ---"

# Introduce conflicting changes
echo >&2 "Introducing conflicting changes..."
log_cmd git checkout feature3
sed -i '7s/.*/Feature 3 conflicting change line 7/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Conflict: Modify line 7 on feature3"
FEATURE3_CONFLICT_SHA=$(git rev-parse HEAD)
log_cmd git push origin feature3

log_cmd git checkout main
log_cmd git pull origin main
sed -i '7s/.*/Main conflicting change line 7/' file.txt
log_cmd git add file.txt
log_cmd git commit -m "Conflict: Modify line 7 on main"
log_cmd git push origin main

# Merge PR2
echo >&2 "Merging PR #$PR2_NUM to trigger conflict..."
merge_pr_with_retry "$PR2_URL"
MERGE_COMMIT_SHA2=$(gh pr view "$PR2_URL" --repo "$REPO_FULL_NAME" --json mergeCommit -q .mergeCommit.oid)
echo >&2 "PR #$PR2_NUM merged. Squash commit SHA: $MERGE_COMMIT_SHA2"

echo >&2 "Waiting for action..."
if ! wait_for_workflow "$PR2_NUM" "feature2" "$MERGE_COMMIT_SHA2" "success"; then
    echo >&2 "Workflow did not complete successfully."
    exit 1
fi

# Verify conflict handling
echo >&2 "Verifying conflict handling..."
log_cmd git fetch origin --prune

# Verify PR3 base was updated
PR3_BASE=$(gh pr view "$PR3_NUM" --repo "$REPO_FULL_NAME" --json baseRefName --jq .baseRefName)
if [[ "$PR3_BASE" == "main" ]]; then
    echo >&2 "✅ PR #$PR3_NUM base updated to main"
else
    echo >&2 "❌ PR #$PR3_NUM base is '$PR3_BASE'"
    exit 1
fi

# Verify conflict comment
sleep 3
CONFLICT_COMMENT=$(gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json comments --jq '.comments[] | select(.body | contains("Automatic update blocked by merge conflicts")) | .body')
if [[ -n "$CONFLICT_COMMENT" ]]; then
    echo >&2 "✅ Conflict comment found on PR #$PR3_NUM"
else
    echo >&2 "❌ Conflict comment not found"
    exit 1
fi

# Verify conflict label
CONFLICT_LABEL=$(gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ "$CONFLICT_LABEL" == "autorestack-needs-conflict-resolution" ]]; then
    echo >&2 "✅ Conflict label found on PR #$PR3_NUM"
else
    echo >&2 "❌ Conflict label not found"
    exit 1
fi

# Verify feature3 was NOT pushed (conflict blocked it)
REMOTE_F3_SHA=$(git rev-parse refs/remotes/origin/feature3)
if [[ "$REMOTE_F3_SHA" == "$FEATURE3_CONFLICT_SHA" ]]; then
    echo >&2 "✅ feature3 was not updated (conflict blocked push)"
else
    echo >&2 "❌ feature3 was unexpectedly updated"
    exit 1
fi

# Resolve conflict manually
echo >&2 "Resolving conflict manually..."
log_cmd git checkout feature3
log_cmd git fetch origin
if git merge origin/main; then
    echo >&2 "❌ Expected merge conflict but merge succeeded"
    exit 1
else
    echo >&2 "Conflict occurred as expected, resolving..."
    log_cmd git checkout --ours file.txt
    log_cmd git add file.txt
    log_cmd git commit --no-edit
fi
log_cmd git push origin feature3

# Wait for continuation workflow
echo >&2 "Waiting for continuation workflow..."
if ! wait_for_synchronize_workflow "$PR3_NUM" "feature3" "success"; then
    echo >&2 "Continuation workflow failed"
    exit 1
fi

# Verify label removed
sleep 3
LABEL_AFTER=$(gh pr view "$PR3_URL" --repo "$REPO_FULL_NAME" --json labels --jq '.labels[] | select(.name == "autorestack-needs-conflict-resolution") | .name')
if [[ -z "$LABEL_AFTER" ]]; then
    echo >&2 "✅ Conflict label removed"
else
    echo >&2 "❌ Conflict label still present"
    exit 1
fi

# Verify feature4 was updated
log_cmd git fetch origin
log_cmd git checkout feature4
log_cmd git pull origin feature4
if git merge-base --is-ancestor origin/feature3 feature4; then
    echo >&2 "✅ feature4 updated with resolved feature3"
else
    echo >&2 "❌ feature4 not updated"
    exit 1
fi

echo >&2 "--- Conflict Scenario Test Completed Successfully ---"
echo >&2 ""
echo >&2 "=== E2E Test Completed Successfully! ==="

#!/bin/bash

set -e

# Get script directory (needed for static mock files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source command utils from the project root to get log_cmd early
# Assuming command_utils.sh is one level up from the tests directory
source "$SCRIPT_DIR/../command_utils.sh"

# Helper function to simulate 'git push origin <branch>'
simulate_push() {
    local branch_name="$1"
    # Use the helper log_cmd for consistency
    log_cmd git update-ref "refs/remotes/origin/$branch_name" "$branch_name"
}

# Helper function to simulate 'git push origin :<branch>'
simulate_delete_remote_branch() {
    local branch_name="$1"
    log_cmd git update-ref -d "refs/remotes/origin/$branch_name"
}

# Create a temporary directory for the test repository
TEST_REPO=$(mktemp -d)
cd "$TEST_REPO"
echo "Created test repo at $TEST_REPO"

# Initialize a repo, set the initial branch name to main, and set up basic config
log_cmd git init -b main
log_cmd git config user.email "test@example.com"
log_cmd git config user.name "Test User"

# Create initial commit on main branch
echo "Initial line 1" > file.txt
echo "Initial line 2" >> file.txt
echo "Initial line 3" >> file.txt
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
simulate_push main

# Create feature1 branch - Modify line 2
log_cmd git checkout -b feature1
sed -i '2s/.*/Feature 1 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 1"
simulate_push feature1

# Make a note of the commit we'll squash/cherry-pick
FEATURE1_COMMIT=$(log_cmd git rev-parse HEAD)

# Create feature2 branch based on feature1 - Modify line 2
log_cmd git checkout -b feature2
sed -i '2s/.*/Feature 2 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 2"
simulate_push feature2

# Create feature3 branch based on feature2 - Modify line 2
log_cmd git checkout -b feature3
sed -i '2s/.*/Feature 3 content line 2/' file.txt # Edit line 2
log_cmd git add file.txt
log_cmd git commit -m "Add feature 3"
simulate_push feature3

# Simulate a squash merge of feature1 into main by cherry-picking
log_cmd git checkout main
log_cmd git cherry-pick "$FEATURE1_COMMIT" # Apply the changes from feature1's commit
# The cherry-pick creates a *new* commit on main, simulating the squash merge result
SQUASH_COMMIT=$(log_cmd git rev-parse HEAD) # Get the hash of the new commit on main
simulate_push main # Update origin/main to include the squash commit

echo "Simulated Squash commit (via cherry-pick): $SQUASH_COMMIT"

# Run the update-pr-stack.sh script with our mocked gh command

echo "Running update-pr-stack.sh..."
# The update script sources command_utils.sh itself
log_cmd \
  env \
  SQUASH_COMMIT=$SQUASH_COMMIT \
  MERGED_BRANCH=feature1 \
  TARGET_BRANCH=main \
  GH="$SCRIPT_DIR/mock_gh.sh" \
  GIT="$SCRIPT_DIR/mock_git.sh" \
  $SCRIPT_DIR/../update-pr-stack.sh

# Verify the results
cd "$TEST_REPO"

# Test if the squash commit is incorporated into feature2
if log_cmd git merge-base --is-ancestor "$SQUASH_COMMIT" feature2; then
    echo "✅ feature2 includes the squash commit"
else
    echo "❌ feature2 does not include the squash commit"
    log_cmd git log --graph --oneline --all
    exit 1
fi

# Test if the squash commit is incorporated into feature3
if log_cmd git merge-base --is-ancestor "$SQUASH_COMMIT" feature3; then
    echo "✅ feature3 includes the squash commit"
else
    echo "❌ feature3 does not include the squash commit"
    log_cmd git log --graph --oneline --all
    exit 1
fi

# Show the contents of feature2 and feature3 to verify they contain all changes
echo -e "\nContent of feature2 branch:"
log_cmd git show feature2:file.txt

echo -e "\nContent of feature3 branch:"
log_cmd git show feature3:file.txt

# Test triple dot diff on feature2
log_cmd git checkout feature2
echo -e "\nDiff between main and feature2:"
log_cmd git diff main...feature2
# After rebase, the diff should only contain the changes unique to feature2
# In this conflict scenario, feature2's change should overwrite feature1's change
# Filter out the 'index ...' line which contains changing hashes
EXPECTED_DIFF2=$(cat <<EOF | grep -v '^index '
--- a/file.txt
+++ b/file.txt
@@ -1,3 +1,3 @@
 Initial line 1
-Feature 1 content line 2
+Feature 2 content line 2
 Initial line 3
EOF
)
ACTUAL_DIFF2=$(log_cmd git diff main...feature2 | grep -v '^index ')
if [[ "$ACTUAL_DIFF2" == "$EXPECTED_DIFF2" ]]; then
    echo "✅ Triple dot diff for feature2 shows expected changes (ignoring index line)"
else
    echo "❌ Triple dot diff for feature2 doesn't show expected changes (ignoring index line)"
    echo "Expected:"
    echo "$EXPECTED_DIFF2"
    echo "Actual:"
    echo "$ACTUAL_DIFF2"
    exit 1
fi


# Test triple dot diff on feature3
log_cmd git checkout feature3
echo -e "\nDiff between main and feature3:"
log_cmd git diff main...feature3
# After rebase, the diff should only contain the changes unique to feature3 relative to main
# Filter out the 'index ...' line which contains changing hashes
EXPECTED_DIFF3=$(cat <<EOF | grep -v '^index '
--- a/file.txt
+++ b/file.txt
@@ -1,3 +1,3 @@
 Initial line 1
-Feature 1 content line 2
+Feature 3 content line 2
 Initial line 3
EOF
)
ACTUAL_DIFF3=$(log_cmd git diff main...feature3 | grep -v '^index ')
if [[ "$ACTUAL_DIFF3" == "$EXPECTED_DIFF3" ]]; then
    echo "✅ Triple dot diff for feature3 shows expected changes (ignoring index line)"
else
    echo "❌ Triple dot diff for feature3 doesn't show expected changes (ignoring index line)"
    echo "Expected:"
    echo "$EXPECTED_DIFF3"
    echo "Actual:"
    echo "$ACTUAL_DIFF3"
    exit 1
fi


# Test idempotence by running the update again
# Note: The previous run checked out feature3, stay there for commit hash check
FEATURE3_COMMIT_BEFORE=$(log_cmd git rev-parse HEAD)
log_cmd git checkout feature2
FEATURE2_COMMIT_BEFORE=$(log_cmd git rev-parse HEAD)

echo -e "\nRunning update script again to test idempotence..."
# Run update script again with mocked push
log_cmd \
  env \
  SQUASH_COMMIT=$SQUASH_COMMIT \
  MERGED_BRANCH=feature1 \
  TARGET_BRANCH=main \
  GH="$SCRIPT_DIR/mock_gh.sh" \
  GIT="$SCRIPT_DIR/mock_git.sh" \
  $SCRIPT_DIR/../update-pr-stack.sh


# Simulate the push again (should be no-op if idempotent)
echo "Simulating push after idempotence run..."
simulate_push feature2
simulate_push feature3
# Deletion should fail harmlessly if already deleted, or succeed if somehow recreated
# We expect it to be deleted already, so this might show an error, which is fine.
# Let's suppress the error for the delete attempt during idempotence check.
log_cmd git update-ref -d "refs/remotes/origin/$MERGED_BRANCH" 2>/dev/null || true


# Check that no new commits were created
cd "$TEST_REPO"
log_cmd git checkout feature2
FEATURE2_COMMIT_AFTER=$(log_cmd git rev-parse HEAD)
log_cmd git checkout feature3
FEATURE3_COMMIT_AFTER=$(log_cmd git rev-parse HEAD)

if [[ "$FEATURE2_COMMIT_BEFORE" == "$FEATURE2_COMMIT_AFTER" ]]; then
    echo "✅ Idempotence test passed for feature2"
else
    echo "❌ Idempotence test failed for feature2"
    log_cmd git log --graph --oneline --all
    exit 1
fi

if [[ "$FEATURE3_COMMIT_BEFORE" == "$FEATURE3_COMMIT_AFTER" ]]; then
    echo "✅ Idempotence test passed for feature3"
else
    echo "❌ Idempotence test failed for feature3"
    log_cmd git log --graph --oneline --all
    exit 1
fi

echo -e "\nAll tests passed! 🎉"

# Clean up
# cd /tmp
# rm -rf "$TEST_REPO"
echo "Test repository remains at: $TEST_REPO for inspection"


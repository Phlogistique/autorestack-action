#!/bin/bash

set -e

# Get script directory (needed for static mock files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create a temporary directory for the test repository
TEST_REPO=$(mktemp -d)
cd "$TEST_REPO"
echo "Created test repo at $TEST_REPO"

# Initialize a repo and set up basic config
git init
git config user.email "test@example.com"
git config user.name "Test User"

# Create initial commit
echo "Initial line 1" > file.txt
echo "Initial line 2" >> file.txt
echo "Initial line 3" >> file.txt
git add file.txt
git commit -m "Initial commit"

# Create the main branch
git branch main
git checkout main

# Create feature1 branch - Modify line 2
git checkout -b feature1
sed -i '2s/.*/Feature 1 content line 2/' file.txt # Edit line 2
git add file.txt
git commit -m "Add feature 1"

# Make a note of the commit we'll squash
FEATURE1_COMMIT=$(git rev-parse HEAD)

# Create feature2 branch based on feature1 - Modify line 2
git checkout -b feature2
sed -i '2s/.*/Feature 2 content line 2/' file.txt # Edit line 2
git add file.txt
git commit -m "Add feature 2"

# Create feature3 branch based on feature2 - Modify line 2
git checkout -b feature3
sed -i '2s/.*/Feature 3 content line 2/' file.txt # Edit line 2
git add file.txt
git commit -m "Add feature 3"

# Simulate a squash merge of feature1 into main
git checkout main
echo "Initial line 1" > file.txt
echo "Feature 1 content line 2" >> file.txt # Reflect feature1 change on line 2
echo "Initial line 3" >> file.txt
git add file.txt
git commit -m "Squashed: Add feature 1"
SQUASH_COMMIT=$(git rev-parse HEAD) # Get the hash of the squash commit

echo "Squash commit: $SQUASH_COMMIT"

# Copy the necessary scripts to the test repo
mkdir -p scripts
cp /home/noe/work/test-stack-3/test-stack/update-pr-stack.sh scripts/
cp /home/noe/work/test-stack-3/test-stack/command_utils.sh scripts/

# Run the update-pr-stack.sh script with our mocked gh command
cd scripts
export SQUASH_COMMIT=$SQUASH_COMMIT
export MERGED_BRANCH=feature1
export TARGET_BRANCH=main
export GH="$SCRIPT_DIR/mock_gh.sh"

echo "Running update-pr-stack.sh..."
bash ./update-pr-stack.sh

# Verify the results
cd "$TEST_REPO"

# Test if the squash commit is incorporated into feature2
git checkout feature2
if git merge-base --is-ancestor "$SQUASH_COMMIT" HEAD; then
    echo "✅ feature2 includes the squash commit"
else
    echo "❌ feature2 does not include the squash commit"
    exit 1
fi

# Test if the squash commit is incorporated into feature3
git checkout feature3
if git merge-base --is-ancestor "$SQUASH_COMMIT" HEAD; then
    echo "✅ feature3 includes the squash commit"
else
    echo "❌ feature3 does not include the squash commit"
    exit 1
fi

# Show the contents of feature2 and feature3 to verify they contain all changes
echo -e "\nContent of feature2 branch:"
git checkout feature2
cat file.txt

echo -e "\nContent of feature3 branch:"
git checkout feature3
cat file.txt

# Test triple dot diff on feature2
git checkout feature2
echo -e "\nDiff between main and feature2:"
git diff main...feature2
DIFF_COUNT=$(git diff main...feature2 | grep -c "^[+-][^+-]")
if [[ "$DIFF_COUNT" -gt 0 ]]; then
    echo "✅ Triple dot diff for feature2 shows expected changes"
else
    echo "❌ Triple dot diff for feature2 doesn't show expected changes"
    exit 1
fi

# Test triple dot diff on feature3
git checkout feature3
echo -e "\nDiff between main and feature3:"
git diff main...feature3
DIFF_COUNT=$(git diff main...feature3 | grep -c "^[+-][^+-]")
if [[ "$DIFF_COUNT" -gt 0 ]]; then
    echo "✅ Triple dot diff for feature3 shows expected changes"
else
    echo "❌ Triple dot diff for feature3 doesn't show expected changes"
    exit 1
fi

# Test idempotence by running the update again
cd "$TEST_REPO/scripts"
echo -e "\nRunning update script again to test idempotence..."

# Store current commit hashes
cd "$TEST_REPO"
git checkout feature2
FEATURE2_COMMIT_BEFORE=$(git rev-parse HEAD)
git checkout feature3
FEATURE3_COMMIT_BEFORE=$(git rev-parse HEAD)

# Run update script again
cd "$TEST_REPO/scripts"
bash ./update-pr-stack.sh

# Check that no new commits were created
cd "$TEST_REPO"
git checkout feature2
FEATURE2_COMMIT_AFTER=$(git rev-parse HEAD)
git checkout feature3
FEATURE3_COMMIT_AFTER=$(git rev-parse HEAD)

if [[ "$FEATURE2_COMMIT_BEFORE" == "$FEATURE2_COMMIT_AFTER" ]]; then
    echo "✅ Idempotence test passed for feature2"
else
    echo "❌ Idempotence test failed for feature2"
    exit 1
fi

if [[ "$FEATURE3_COMMIT_BEFORE" == "$FEATURE3_COMMIT_AFTER" ]]; then
    echo "✅ Idempotence test passed for feature3"
else
    echo "❌ Idempotence test failed for feature3"
    exit 1
fi

echo -e "\nAll tests passed! 🎉"

# Clean up
# cd /tmp
# rm -rf "$TEST_REPO"
echo "Test repository remains at: $TEST_REPO for inspection"

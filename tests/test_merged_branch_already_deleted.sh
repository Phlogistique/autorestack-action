#!/bin/bash
#
# Someone can click "Delete branch" on the merged PR while the action is still
# running, so `git push origin :<merged>` fails with "remote ref does not
# exist". The deletion is the last step, after the children are updated and
# retargeted, so the run must still end green.

set -ueo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../command_utils.sh"

simulate_push() {
    log_cmd git update-ref "refs/remotes/origin/$1" "$1"
}

MOCK_DIR=$(mktemp -d)
TEST_REPO=$(mktemp -d)
cd "$TEST_REPO"
echo "Created test repo at $TEST_REPO"

log_cmd git init -b main
log_cmd git config user.email "test@example.com"
log_cmd git config user.name "Test User"

echo "line" > file.txt
log_cmd git add file.txt
log_cmd git commit -m "Initial commit"
simulate_push main

log_cmd git checkout -b feature1
echo "f1" >> file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 1"
simulate_push feature1

log_cmd git checkout -b feature2
echo "f2" >> file.txt
log_cmd git add file.txt
log_cmd git commit -m "Add feature 2"
simulate_push feature2

# Squash feature1 into main
log_cmd git checkout main
log_cmd git merge --squash feature1
log_cmd git commit -m "Add feature 1 (#1)"
SQUASH=$(git rev-parse HEAD)
simulate_push main

# A git that refuses branch deletions, like the remote does once the branch is gone
cat > "$MOCK_DIR/failing_git.sh" <<'MOCK'
#!/bin/bash
if [[ "$1" == "push" && "$3" == :* ]]; then
    echo "error: unable to delete '${3#:}': remote ref does not exist" >&2
    exit 1
fi
exec "$MOCK_GIT" "$@"
MOCK
chmod +x "$MOCK_DIR/failing_git.sh"

set +e
OUT=$(env \
    SQUASH_COMMIT="$SQUASH" \
    MERGED_BRANCH=feature1 \
    PR_NUMBER=1 \
    TARGET_BRANCH=main \
    MOCK_GIT="$SCRIPT_DIR/mock_git.sh" \
    GH="$SCRIPT_DIR/mock_gh.sh" \
    GIT="$MOCK_DIR/failing_git.sh" \
    "$SCRIPT_DIR/../update-pr-stack.sh" 2>&1)
RC=$?
set -e
echo "$OUT"

if [[ "$RC" -ne 0 ]]; then
    echo "❌ The run must succeed when the merged branch is already deleted (exit $RC)"
    exit 1
fi
if ! grep -q "Could not delete 'feature1'" <<<"$OUT"; then
    echo "❌ Expected a warning about the failed deletion"
    exit 1
fi
if ! grep -q "gh pr edit 2 --base main" <<<"$OUT"; then
    echo "❌ The child PR must still be retargeted"
    exit 1
fi
ACTUAL_DIFF=$(git diff main...feature2 | grep '^[+-]' | grep -v '^[+-][+-][+-]')
if [[ "$ACTUAL_DIFF" != "+f2" ]]; then
    echo "❌ Diff main...feature2 should show only feature2's change, got:"
    echo "$ACTUAL_DIFF"
    exit 1
fi

echo "✅ Already-deleted merged branch: warned, not failed"

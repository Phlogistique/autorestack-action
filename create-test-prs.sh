#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status.

# Function to log and execute git commands
git_cmd() {
    printf "Executing: git" >&2
    printf " %q" "$@" >&2
    printf "\n" >&2
    git "$@"
}

# Create and switch to first branch
BRANCH1="feature/add-hello-1"
git_cmd checkout -b "$BRANCH1" main

# Add first change
echo "hello 1" >> toto
git_cmd add toto
git_cmd commit -m "Add hello 1"
git_cmd push -u origin "$BRANCH1"

# Create first PR
PR1_URL=$(gh pr create --base main --head "$BRANCH1" --title "Add hello 1" --body "Adds hello 1 to toto file")
echo "Created PR1: $PR1_URL"

# Create and switch to second branch
BRANCH2="feature/add-hello-2"
git_cmd checkout -b "$BRANCH2" "$BRANCH1"

# Add second change
echo "hello 2" >> toto
git_cmd add toto
git_cmd commit -m "Add hello 2"
git_cmd push -u origin "$BRANCH2"

# Create second PR targeting the first branch
PR2_URL=$(gh pr create --base "$BRANCH1" --head "$BRANCH2" --title "Add hello 2" --body "Adds hello 2 to toto file")
echo "Created PR2: $PR2_URL"

# Return to main branch
git_cmd checkout main

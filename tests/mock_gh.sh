#!/bin/bash

if [[ "$1" == "pr" && "$2" == "list" ]]; then
    # Parse the --base argument to determine which PRs to return
    base=""
    jq_flag=""
    for ((i=1; i<=$#; i++)); do
        if [[ "${!i}" == "--base" ]]; then
            next=$((i+1))
            base="${!next}"
        fi
        if [[ "${!i}" == "--jq" ]]; then
            next=$((i+1))
            jq_flag="${!next}"
        fi
    done

    if [[ "$base" == "main" ]]; then
        : # No PRs target main in our test
    elif [[ "$base" == "feature1" ]]; then
        echo 'feature2'
    elif [[ "$base" == "feature2" ]]; then
        echo feature3
    elif [[ "$base" == "feature3" ]]; then
        :
    else
        echo "Unknown base branch: $@" >&2
        exit 1
    fi
elif [[ "$1" == "pr" && "$2" == "edit" ]]; then
    # Just log the edit command
    echo "Mock: gh pr edit $3 --base $5"
else
    echo "Unknown gh command: $@" >&2
    exit 1
fi

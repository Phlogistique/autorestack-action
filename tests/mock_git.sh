#!/bin/bash


if [[ "$1" == "push" ]]; then
    # Log the attempt but don't execute, preventing failure
    printf "Executing (mocked):" >&2
    printf " %q" "git" "$@" >&2
    printf "\n" >&2
else
    # Pass through any other git command to the real git
    exec git "$@"
fi

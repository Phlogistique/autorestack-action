#!/bin/bash

# Function to log and execute commands
log_cmd() {
    printf "Executing:" >&2
    printf " %q" "$@" >&2
    printf "\n" >&2
    "$@"
}

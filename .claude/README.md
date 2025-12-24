# Claude Scripts

This directory contains helper scripts for development and testing.

## Scripts

### `run-e2e-tests.sh`

Idempotent script that sets up the environment and runs end-to-end tests.

**What it does:**
1. Installs `gh` CLI if not already installed (downloads latest release for Linux amd64)
2. Acquires a GitHub App token using `get_github_app_token.py`
3. Configures git (disables commit signing temporarily)
4. Sets up gh authentication
5. Runs the e2e test suite
6. Restores original git configuration

**Usage:**
```bash
# Ensure required environment variables are set
export GH_APP_ID="your-app-id"
export GH_APP_PRIVATE_KEY_PEM_B64="your-base64-encoded-private-key"

# Run the script
./.claude/run-e2e-tests.sh
```

**Requirements:**
- `GH_APP_ID`: GitHub App ID
- `GH_APP_PRIVATE_KEY_PEM_B64`: Base64-encoded GitHub App private key
- `uv`: Python package manager (for running the token generation script)
- `curl`, `jq`: For downloading gh CLI and processing JSON
- `sudo`: For installing gh CLI to `/usr/local/bin`

### `get_github_app_token.py`

Python script that generates a GitHub App installation token.

**What it does:**
1. Reads GitHub App credentials from environment variables
2. Generates a JWT token
3. Fetches the app's installations
4. Creates an installation access token with appropriate permissions

**Usage:**
```bash
export GH_APP_ID="your-app-id"
export GH_APP_PRIVATE_KEY_PEM_B64="your-base64-encoded-private-key"

uv run ./.claude/get_github_app_token.py
```

**Output:**
Prints the installation access token to stdout.

## Notes

- The token generated is temporary and expires after a short period
- The `run-e2e-tests.sh` script is designed to be run multiple times safely (idempotent)
- Both scripts require the same environment variables to be set

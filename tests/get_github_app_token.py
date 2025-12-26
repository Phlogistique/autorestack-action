#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "PyJWT",
#     "requests",
#     "cryptography",
# ]
# ///
"""
GitHub App Token Generator with caching

Generates an installation access token from GitHub App credentials in environment.
Caches tokens and reuses them until they expire (with 5-minute buffer).

Environment variables required:
- GH_APP_ID: GitHub App ID
- GH_APP_PRIVATE_KEY_PEM_B64: Base64-encoded private key

Usage:
    # Run with uv (automatically installs dependencies)
    uv run get_github_app_token.py

    # Save to file
    uv run get_github_app_token.py > token.txt

    # Use in shell
    export GITHUB_TOKEN=$(uv run get_github_app_token.py)
"""

import base64
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import jwt
import requests

# Cache file location
CACHE_FILE = Path("/tmp/gh_app_token_cache.json")
# Buffer time before expiration (5 minutes)
EXPIRATION_BUFFER_SECONDS = 300


def get_cached_token():
    """Get cached token if it exists and is still valid."""
    if not CACHE_FILE.exists():
        return None

    try:
        with open(CACHE_FILE, 'r') as f:
            cache_data = json.load(f)

        token = cache_data.get('token')
        expires_at_str = cache_data.get('expires_at')

        if not token or not expires_at_str:
            return None

        # Parse expiration time (GitHub returns ISO 8601 format)
        expires_at = datetime.fromisoformat(expires_at_str.replace('Z', '+00:00'))
        now = datetime.now(timezone.utc)

        # Check if token is still valid (with buffer)
        time_until_expiry = (expires_at - now).total_seconds()

        if time_until_expiry > EXPIRATION_BUFFER_SECONDS:
            print(f"Using cached token (expires in {int(time_until_expiry/60)} minutes)", file=sys.stderr)
            return token
        else:
            print("Cached token expired or expiring soon, generating new token", file=sys.stderr)
            return None

    except (json.JSONDecodeError, ValueError, KeyError) as e:
        print(f"Error reading cache: {e}, generating new token", file=sys.stderr)
        return None


def save_token_to_cache(token, expires_at):
    """Save token and expiration to cache file."""
    cache_data = {
        'token': token,
        'expires_at': expires_at,
        'cached_at': datetime.now(timezone.utc).isoformat()
    }

    try:
        with open(CACHE_FILE, 'w') as f:
            json.dump(cache_data, f)
        print("Token cached successfully", file=sys.stderr)
    except Exception as e:
        print(f"Warning: Failed to cache token: {e}", file=sys.stderr)


def generate_installation_token():
    """Generate a new installation access token for the GitHub App."""
    # Get credentials from environment
    app_id = os.getenv("GH_APP_ID")
    private_key_b64 = os.getenv("GH_APP_PRIVATE_KEY_PEM_B64")

    if not all([app_id, private_key_b64]):
        print("Error: Missing GH_APP_ID or GH_APP_PRIVATE_KEY_PEM_B64", file=sys.stderr)
        sys.exit(1)

    # Decode private key
    private_key = base64.b64decode(private_key_b64).decode('utf-8')

    # Generate JWT
    now = int(time.time())
    payload = {
        "iat": now - 60,
        "exp": now + (10 * 60),
        "iss": app_id,
    }
    jwt_token = jwt.encode(payload, private_key, algorithm="RS256")

    # Get installations
    headers = {
        "Authorization": f"Bearer {jwt_token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }

    response = requests.get("https://api.github.com/app/installations", headers=headers)
    response.raise_for_status()
    installations = response.json()

    if not installations:
        print("Error: No installations found for this GitHub App", file=sys.stderr)
        sys.exit(1)

    installation_id_env = os.getenv("GH_APP_INSTALLATION_ID")
    if installation_id_env:
        try:
            desired_id = int(installation_id_env)
        except ValueError:
            print("Error: GH_APP_INSTALLATION_ID must be an integer", file=sys.stderr)
            sys.exit(1)
        installation = next((i for i in installations if i.get("id") == desired_id), None)
        if not installation:
            available_ids = [i.get("id") for i in installations if "id" in i]
            print(
                f"Error: GH_APP_INSTALLATION_ID {desired_id} not found. "
                f"Available installation IDs: {available_ids}",
                file=sys.stderr,
            )
            sys.exit(1)
    else:
        installation = installations[0]
        available = ", ".join(
            f"{i.get('id')}:{i.get('account', {}).get('login', 'unknown')}"
            for i in installations
        )
        print(f"Available installations: {available}", file=sys.stderr)

    installation_id = installation["id"]
    account_login = installation.get("account", {}).get("login", "unknown")
    print(
        f"Using installation id {installation_id} (account {account_login})",
        file=sys.stderr,
    )

    # Create installation token
    url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
    response = requests.post(url, headers=headers)
    response.raise_for_status()

    token_info = response.json()

    # Save to cache
    save_token_to_cache(token_info['token'], token_info['expires_at'])

    return token_info['token']


def get_token():
    """Get a valid token, either from cache or by generating a new one."""
    # Try to get cached token first
    cached_token = get_cached_token()
    if cached_token:
        return cached_token

    # Generate new token if cache miss or expired
    print("Generating new GitHub App token", file=sys.stderr)
    return generate_installation_token()


if __name__ == "__main__":
    try:
        token = get_token()
        print(token)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

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
GitHub App Token Generator

Generates an installation access token from GitHub App credentials in environment.

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
import os
import sys
import time

import jwt
import requests


def get_installation_token():
    """Generate an installation access token for the GitHub App."""

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

    # Create installation token
    installation_id = installations[0]['id']
    url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
    response = requests.post(url, headers=headers)
    response.raise_for_status()

    token_info = response.json()
    return token_info['token']


if __name__ == "__main__":
    try:
        token = get_installation_token()
        print(token)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

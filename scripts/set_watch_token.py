#!/usr/bin/env python3
import getpass
import secrets
import base64
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "SleepWatch" / "Config.swift"
TOKEN_PREFIXES = ("github_pat_", "ghp_")


def main():
    token = getpass.getpass("Paste GitHub token for the Watch app: ").strip()
    if not token:
        raise SystemExit("No token entered.")
    if not token.startswith(TOKEN_PREFIXES):
        raise SystemExit("That does not look like a GitHub token.")

    existing_key = ""
    for line in CONFIG.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("static let reportEncryptionKey = "):
            parts = stripped.split('"')
            if len(parts) >= 2:
                existing_key = parts[1]

    if existing_key and "REPLACE" not in existing_key:
        report_key = existing_key
    else:
        report_key = base64.b64encode(secrets.token_bytes(32)).decode("ascii")

    text = CONFIG.read_text(encoding="utf-8")
    lines = text.splitlines()
    updated = []
    replaced = False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("static let githubToken = "):
            indent = line[: len(line) - len(line.lstrip())]
            updated.append(f'{indent}static let githubToken = "{token}"')
            replaced = True
        elif stripped.startswith("static let reportEncryptionKey = "):
            indent = line[: len(line) - len(line.lstrip())]
            updated.append(f'{indent}static let reportEncryptionKey = "{report_key}"')
        else:
            updated.append(line)

    if not replaced:
        raise SystemExit(f"Could not find githubToken in {CONFIG}")

    CONFIG.write_text("\n".join(updated) + "\n", encoding="utf-8")

    try:
        subprocess.run(
            ["git", "update-index", "--skip-worktree", "SleepWatch/Config.swift"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
    except Exception as error:
        print(f"Token saved, but could not mark Config.swift skip-worktree: {error}")
        print("Do not commit SleepWatch/Config.swift while it contains your token.")
        return

    print("Token saved locally.")
    print("Report encryption key saved locally.")
    print("SleepWatch/Config.swift is now marked skip-worktree so the token is not committed.")
    print("Set the same report encryption key as GitHub secret HEALTH_REPORT_KEY.")


if __name__ == "__main__":
    main()

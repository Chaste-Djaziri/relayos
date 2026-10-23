"""Small macOS Keychain adapter for onboarding secrets.

Secrets are deliberately kept out of the JSON profile and process arguments.
The adapter is dependency-free so the signed app can use the system Keychain
without shipping another credential database.
"""
import os
import subprocess

SERVICE = "rw.shangazi.laptop-bridge"


def _available():
    return os.name == "posix" and subprocess.call(["/usr/bin/which", "security"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def set_secret(account, value):
    if not _available():
        raise RuntimeError("macOS Keychain is unavailable")
    result = subprocess.run(
        ["/usr/bin/security", "add-generic-password", "-U", "-s", SERVICE, "-a", account, "-w", value],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Could not save the credential in Keychain")


def get_secret(account):
    if not _available():
        return None
    result = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", account, "-w"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False,
    )
    return result.stdout.rstrip("\n") if result.returncode == 0 else None


def delete_secret(account):
    if not _available():
        return
    subprocess.run(
        ["/usr/bin/security", "delete-generic-password", "-s", SERVICE, "-a", account],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )

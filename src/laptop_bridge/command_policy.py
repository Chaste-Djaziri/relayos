# Path: src/laptop_bridge/command_policy.py
"""Validated reusable command prefixes, selected by a client and confirmed locally.

An approved prefix is a literal sequence of argv tokens, not a shell glob,
string startswith or regular expression. Never automatically extend its scope.
"""
from pathlib import Path

# Existing approvals keep the established git-add family semantics.
_REUSABLE_GIT_SUBCOMMANDS = {"add"}
# Commands that delegate arbitrary code or executables must use exact approval.
_NO_PREFIX_EXECUTABLES = {
    "sh", "bash", "zsh", "fish", "dash", "sudo", "su", "doas",
    "env", "python", "python3", "node", "ruby", "perl", "osascript",
    "eval", "npx", "bunx", "pip", "pip3",
}


def reusable_command_family(executable, argv):
    if not argv or Path(executable).name != "git":
        return None
    if len(argv) < 2 or argv[1] not in _REUSABLE_GIT_SUBCOMMANDS:
        return None
    return f"git:{argv[1]}"


def command_family_label(key):
    if key and key.startswith("git:") and key.split(":", 1)[1] in _REUSABLE_GIT_SUBCOMMANDS:
        return key.replace(":", " ", 1)
    return None


def validate_scope_prefix(executable, argv, scope_prefix):
    """Validate requested literal prefix; None retains legacy exact/git-add behavior.

    The first two complete argv tokens must be fixed. This prevents blanket
    executable grants such as all 'git', all 'npm', or arbitrary shell scripts.
    A local user must separately consent to every prefix selected by the client.
    """
    if scope_prefix is None:
        return None
    if not isinstance(scope_prefix, list) or not 2 <= len(scope_prefix) <= len(argv):
        raise ValueError("scope_prefix must contain at least two original command tokens")
    if len(scope_prefix) > 32 or any(
        not isinstance(part, str) or not part or len(part) > 2048
        or any(ord(char) < 32 for char in part)
        for part in scope_prefix
    ):
        raise ValueError("scope_prefix must contain valid literal argument strings")
    if argv[:len(scope_prefix)] != scope_prefix:
        raise ValueError("scope_prefix must be the literal beginning of argv")
    if Path(executable).name.lower() in _NO_PREFIX_EXECUTABLES:
        raise ValueError("This executable needs exact-command approval, not a reusable prefix")
    if scope_prefix[1].startswith("-") and Path(executable).name in {"git", "npm", "pnpm", "yarn"}:
        raise ValueError("Prefix must include a subcommand, not a global option")
    return list(scope_prefix)


def matches_scope_prefix(argv, scope_prefix):
    return isinstance(scope_prefix, list) and len(scope_prefix) >= 2 and argv[:len(scope_prefix)] == scope_prefix

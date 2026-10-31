"""Explicit, narrow reusable command families for locally approved project operations.

A family grant never means "all arguments to this executable". Only prefixes
reviewed here can be made reusable; other commands remain exact-argv grants.
"""
from pathlib import Path


# These subcommands don't automatically authorize other git operations.
_REUSABLE_GIT_SUBCOMMANDS = {"add"}


def reusable_command_family(executable, argv):
    """Return a stable project-scoped family key, or None for exact-only commands."""
    if not argv or Path(executable).name != "git":
        return None
    if len(argv) < 2 or argv[1] not in _REUSABLE_GIT_SUBCOMMANDS:
        return None
    # Git global flags (-C, -c, --git-dir, --work-tree) can change command
    # execution context. Reusable approval requires an immediate subcommand.
    return f"git:{argv[1]}"


def command_family_label(key):
    if key and key.startswith("git:") and key.split(":", 1)[1] in _REUSABLE_GIT_SUBCOMMANDS:
        return key.replace(":", " ", 1)
    return None

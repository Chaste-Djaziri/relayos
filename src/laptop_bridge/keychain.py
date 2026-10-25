"""Platform credential storage for onboarding secrets.

Secrets stay out of the JSON profile and process arguments. macOS uses the
system Keychain and Windows uses the current user's Credential Manager vault.
"""
import ctypes
import os
import subprocess

SERVICE = "rw.shangazi.laptop-bridge"

_CRED_TYPE_GENERIC = 1
_CRED_PERSIST_LOCAL_MACHINE = 2


class _FILETIME(ctypes.Structure):
    _fields_ = [("dwLowDateTime", ctypes.c_uint32), ("dwHighDateTime", ctypes.c_uint32)]


class _CREDENTIALW(ctypes.Structure):
    _fields_ = [
        ("Flags", ctypes.c_uint32), ("Type", ctypes.c_uint32), ("TargetName", ctypes.c_wchar_p),
        ("Comment", ctypes.c_wchar_p), ("LastWritten", _FILETIME),
        ("CredentialBlobSize", ctypes.c_uint32), ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
        ("Persist", ctypes.c_uint32), ("AttributeCount", ctypes.c_uint32), ("Attributes", ctypes.c_void_p),
        ("TargetAlias", ctypes.c_wchar_p), ("UserName", ctypes.c_wchar_p),
    ]


def _target(account):
    return f"{SERVICE}/{account}"


def _windows_available():
    return os.name == "nt" and hasattr(ctypes, "windll")


def _windows_api():
    if not _windows_available():
        return None
    return ctypes.windll.advapi32


def _set_windows_secret(account, value):
    encoded = value.encode("utf-16-le")
    blob = (ctypes.c_ubyte * len(encoded)).from_buffer_copy(encoded)
    credential = _CREDENTIALW(
        0, _CRED_TYPE_GENERIC, _target(account), None, _FILETIME(), len(encoded), blob,
        _CRED_PERSIST_LOCAL_MACHINE, 0, None, None, account,
    )
    api = _windows_api()
    if not api.CredWriteW(ctypes.byref(credential), 0):
        raise ctypes.WinError(ctypes.get_last_error())


def _get_windows_secret(account):
    result = ctypes.POINTER(_CREDENTIALW)()
    api = _windows_api()
    if not api.CredReadW(_target(account), _CRED_TYPE_GENERIC, 0, ctypes.byref(result)):
        return None
    try:
        blob = ctypes.string_at(result.contents.CredentialBlob, result.contents.CredentialBlobSize)
        return blob.decode("utf-16-le")
    finally:
        api.CredFree(result)


def _delete_windows_secret(account):
    api = _windows_api()
    # Deleting an absent generic credential is intentionally idempotent.
    api.CredDeleteW(_target(account), _CRED_TYPE_GENERIC, 0)


def _available():
    return os.name == "posix" and subprocess.call(["/usr/bin/which", "security"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0


def set_secret(account, value):
    if _windows_available():
        _set_windows_secret(account, value)
        return
    if not _available():
        raise RuntimeError("No supported system credential store is available")
    result = subprocess.run(
        ["/usr/bin/security", "add-generic-password", "-U", "-s", SERVICE, "-a", account, "-w", value],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Could not save the credential in Keychain")


def get_secret(account):
    if _windows_available():
        return _get_windows_secret(account)
    if not _available():
        return None
    result = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", account, "-w"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False,
    )
    return result.stdout.rstrip("\n") if result.returncode == 0 else None


def delete_secret(account):
    if _windows_available():
        _delete_windows_secret(account)
        return
    if not _available():
        return
    subprocess.run(
        ["/usr/bin/security", "delete-generic-password", "-s", SERVICE, "-a", account],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )

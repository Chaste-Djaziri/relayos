import ctypes

from laptop_bridge import keychain


class FakeCredentialApi:
    def __init__(self):
        self.writes = []
        self.deleted = []
        self.credential = None
        self.blob = None

    def CredWriteW(self, credential_ptr, _flags):
        credential = ctypes.cast(credential_ptr, ctypes.POINTER(keychain._CREDENTIALW)).contents
        self.writes.append((credential.TargetName, credential.UserName, credential.CredentialBlobSize))
        self.blob = (ctypes.c_ubyte * credential.CredentialBlobSize).from_buffer_copy(
            ctypes.string_at(credential.CredentialBlob, credential.CredentialBlobSize)
        )
        self.credential = keychain._CREDENTIALW(
            0, keychain._CRED_TYPE_GENERIC, credential.TargetName, None, keychain._FILETIME(),
            credential.CredentialBlobSize, self.blob, keychain._CRED_PERSIST_LOCAL_MACHINE,
            0, None, None, credential.UserName,
        )
        return 1

    def CredReadW(self, _target, _kind, _flags, output):
        if self.credential is None:
            return 0
        pointer = ctypes.pointer(self.credential)
        ctypes.cast(output, ctypes.POINTER(ctypes.POINTER(keychain._CREDENTIALW)))[0] = pointer
        return 1

    def CredFree(self, _credential):
        return None

    def CredDeleteW(self, target, kind, flags):
        self.deleted.append((target, kind, flags))
        return 1


def test_windows_credential_manager_round_trip(monkeypatch):
    api = FakeCredentialApi()
    monkeypatch.setattr(keychain, "_windows_available", lambda: True)
    monkeypatch.setattr(keychain, "_windows_api", lambda: api)

    keychain.set_secret("ngrok_authtoken", "very-secret")

    assert api.writes == [("rw.shangazi.laptop-bridge/ngrok_authtoken", "ngrok_authtoken", 22)]
    assert keychain.get_secret("ngrok_authtoken") == "very-secret"
    keychain.delete_secret("ngrok_authtoken")
    assert api.deleted == [("rw.shangazi.laptop-bridge/ngrok_authtoken", keychain._CRED_TYPE_GENERIC, 0)]


def test_windows_credential_manager_missing_secret_returns_none(monkeypatch):
    api = FakeCredentialApi()
    monkeypatch.setattr(keychain, "_windows_available", lambda: True)
    monkeypatch.setattr(keychain, "_windows_api", lambda: api)

    assert keychain.get_secret("missing") is None

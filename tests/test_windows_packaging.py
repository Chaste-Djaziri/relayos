from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_native_windows_project_is_self_contained_x64():
    project = (ROOT / "Native/RelayOSWindows/RelayOSWindows.csproj").read_text(encoding="utf-8")

    assert "<RuntimeIdentifier>win-x64</RuntimeIdentifier>" in project
    assert "<SelfContained>true</SelfContained>" in project
    assert "<WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>" in project
    assert "<WindowsAppSdkBootstrapInitialize>false</WindowsAppSdkBootstrapInitialize>" in project
    assert "<WindowsAppSdkDeploymentManagerInitialize>false</WindowsAppSdkDeploymentManagerInitialize>" in project
    assert "<WindowsAppSdkUndockedRegFreeWinRTInitialize>true</WindowsAppSdkUndockedRegFreeWinRTInitialize>" in project
    assert "<PublishTrimmed>false</PublishTrimmed>" in project
    assert "<PublishSingleFile>false</PublishSingleFile>" in project


def test_windows_build_and_release_use_self_contained_installer_name():
    build = (ROOT / "scripts/build_windows_native.ps1").read_text(encoding="utf-8")
    installer = (ROOT / "packaging/windows-installer.iss").read_text(encoding="utf-8")
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    page = (ROOT / "website/app/page.tsx").read_text(encoding="utf-8")

    assert "-r win-x64 --self-contained true" in build
    assert "Microsoft.UI.Xaml.dll" in build
    assert "Microsoft.WindowsAppRuntime*.dll" in build
    assert "OutputBaseFilename=RelayOS-Setup-{#AppVersion}" in installer
    assert "RelayOS-Setup-*.exe" in workflow
    assert "Verify self-contained Windows payload" in workflow
    assert "RelayOS-Setup-0.1.0.exe" in page
    assert "windowsappruntimeinstall-x64.exe" in page

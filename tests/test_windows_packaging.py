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


def test_windows_build_remains_developer_only_and_public_site_says_coming_soon():
    build = (ROOT / "scripts/build_windows_native.ps1").read_text(encoding="utf-8")
    developer_publish = (ROOT / "scripts/publish_windows_native.ps1").read_text(encoding="utf-8")
    installer = (ROOT / "packaging/windows-installer.iss").read_text(encoding="utf-8")
    workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    page = (ROOT / "website/app/page.tsx").read_text(encoding="utf-8")
    project = (ROOT / "pyproject.toml").read_text(encoding="utf-8")

    assert "-r win-x64 --self-contained true" in build
    assert "Microsoft.UI.Xaml.dll" in build
    assert "Microsoft.WindowsAppRuntime*.dll" in build
    assert "-r win-x64 --self-contained true" in developer_publish
    assert "win-x64\\publish" in developer_publish
    assert "OutputBaseFilename=RelayOS-Setup-{#AppVersion}" in installer
    # Windows builds remain available to developers but are intentionally not
    # shipped by the public release pipeline until the platform is ready.
    assert "  windows:" not in workflow
    assert "Test and package Apple Silicon DMG" in workflow
    assert "RelayOS.dmg" in workflow
    assert "            dist/RelayOS-Windows-*.zip" not in workflow
    assert "gh release delete-asset nightly" in workflow
    assert "Compress-Archive" not in build
    assert "typer>=0.12" in project
    assert "Verify self-contained Windows payload" not in workflow
    assert "RelayOS-Setup-0.1.0.exe" not in page
    assert "windowsappruntimeinstall-x64.exe" not in page
    assert "Windows" in page and "Coming Soon" in page

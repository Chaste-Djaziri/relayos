# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['packaging/desktop_entry.py'],
    pathex=['src'],
    binaries=[],
    datas=[],
    hiddenimports=['AppKit', 'Foundation'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='Laptop Bridge',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file='packaging/macos.entitlements',
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='Laptop Bridge',
)
app = BUNDLE(
    coll,
    name='Laptop Bridge.app',
    icon=None,
    bundle_identifier='rw.shangazi.laptop-bridge',
)

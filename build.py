#!/usr/bin/env python3
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
APP = ROOT / "build.noindex/智能体工作灯.app"
CONTENTS = APP / "Contents"
(CONTENTS / "MacOS").mkdir(parents=True, exist_ok=True)
(CONTENTS / "Resources").mkdir(parents=True, exist_ok=True)
for resource in (ROOT / "Resources").iterdir():
    if resource.is_file(): shutil.copy2(resource, CONTENTS / "Resources" / resource.name)
info = {
    "CFBundleIdentifier": "local.agentlantern.desktop",
    "CFBundleName": "智能体工作灯",
    "CFBundleDisplayName": "智能体工作灯",
    "CFBundleExecutable": "AgentLantern",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.2.1",
    "CFBundleVersion": "3",
    "LSMinimumSystemVersion": "14.0",
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
    "NSSupportsAutomaticGraphicsSwitching": True,
    "CFBundleIconFile": "AppIcon",
}
(CONTENTS / "Info.plist").write_bytes(plistlib.dumps(info))
iconset = ROOT / "build.noindex/AppIcon.iconset"
subprocess.run(["/usr/bin/swift", str(ROOT / "make-icon.swift"), str(iconset)], check=True)
subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(CONTENTS / "Resources/AppIcon.icns")], check=True)
subprocess.run(["/usr/bin/swiftc", "-swift-version", "5", "-O", "-target", "arm64-apple-macosx14.0",
                "-framework", "AppKit", "-framework", "SwiftUI", str(ROOT / "Sources/CompletionGate.swift"), str(ROOT / "Sources/main.swift"),
                "-o", str(CONTENTS / "MacOS/AgentLantern")], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(APP)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(APP)], check=True)
print(APP)

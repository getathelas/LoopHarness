#!/usr/bin/env python3
"""Run the native LiveAudio/music smoke test on an already-booted simulator.

Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
       python3 scripts/test_live_music_ios.py SIMULATOR_UDID
Plays a quiet local tone; microphone samples are counted and discarded.
"""
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
if len(sys.argv) != 2:
    raise SystemExit("Pass an already-booted iOS simulator UDID.")
device = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="loop-live-music-") as tmp:
    folder = pathlib.Path(tmp)
    app = folder / "MusicSmoke.app"
    app.mkdir()
    bundle = "com.loop.live-music-smoke"
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle, "CFBundleExecutable": "MusicSmoke",
        "CFBundleName": "MusicSmoke", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "LSRequiresIPhoneOS": True, "UILaunchScreen": {},
        "NSMicrophoneUsageDescription": "Tests music and voice capture; samples are discarded.",
    }))
    shutil.copyfile(root / "scripts/test_live_music_ios.swift", folder / "main.swift")
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    subprocess.run(["xcrun", "swiftc", "-sdk", sdk, "-target", "arm64-apple-ios17.6-simulator",
                    str(root / "LoopIOS/Live/LiveAudio.swift"), str(folder / "main.swift"),
                    "-o", str(app / "MusicSmoke")], check=True)
    subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True)
    try:
        subprocess.run(["xcrun", "simctl", "privacy", device, "grant", "microphone", bundle], check=True)
        result = subprocess.run(["xcrun", "simctl", "launch", "--console", device, bundle],
                                capture_output=True, text=True, timeout=45, check=True)
        print(result.stdout)
        if "PASS: music playback" not in result.stdout:
            raise SystemExit("Audio test did not pass: " + result.stderr)
    finally:
        subprocess.run(["xcrun", "simctl", "uninstall", device, bundle], check=False)

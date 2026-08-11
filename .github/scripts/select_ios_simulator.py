#!/usr/bin/env python3
"""Return a usable iPhone simulator UDID for GitHub Actions.

GitHub's macOS images occasionally expose Xcode without any pre-created
simulator device. When the iOS runtime itself is also missing, install the
latest runtime supported by the selected Xcode before creating a device.
"""

from __future__ import annotations

import json
import platform
import subprocess
import sys
from typing import Any


def command_json(*command: str) -> dict[str, Any]:
    output = subprocess.check_output(command, text=True)
    return json.loads(output)


def version_key(value: object) -> tuple[int, ...]:
    try:
        return tuple(int(component) for component in str(value).split("."))
    except ValueError:
        return ()


def available_ios_runtimes() -> list[dict[str, Any]]:
    payload = command_json("xcrun", "simctl", "list", "runtimes", "--json")
    return [
        runtime
        for runtime in payload.get("runtimes", [])
        if runtime.get("isAvailable") is True
        and str(runtime.get("identifier", "")).startswith(
            "com.apple.CoreSimulator.SimRuntime.iOS-"
        )
    ]


def install_ios_runtime() -> None:
    command = ["xcodebuild", "-downloadPlatform", "iOS"]
    if platform.machine() == "arm64":
        command.extend(["-architectureVariant", "arm64"])
    print("No iOS Simulator runtime found; downloading one with Xcode.", file=sys.stderr)
    subprocess.run(command, check=True, stdout=sys.stderr, stderr=sys.stderr)


def preferred(items: list[dict[str, Any]], name: str) -> dict[str, Any] | None:
    return next((item for item in items if item.get("name") == name), None)


def main() -> int:
    runtimes = available_ios_runtimes()
    if not runtimes:
        install_ios_runtime()
        runtimes = available_ios_runtimes()
    if not runtimes:
        raise RuntimeError("Xcode did not expose an available iOS Simulator runtime.")

    runtime = max(runtimes, key=lambda item: version_key(item.get("version")))
    runtime_id = str(runtime["identifier"])

    device_payload = command_json("xcrun", "simctl", "list", "devices", "available", "--json")
    iphone_devices = [
        device
        for device in device_payload.get("devices", {}).get(runtime_id, [])
        if device.get("isAvailable") is True
        and str(device.get("name", "")).startswith("iPhone")
    ]
    device = preferred(iphone_devices, "iPhone 17 Pro")
    if device is None and iphone_devices:
        device = iphone_devices[0]
    if device is not None:
        print(device["udid"])
        return 0

    supported_types = [
        device_type
        for device_type in runtime.get("supportedDeviceTypes", [])
        if device_type.get("productFamily") == "iPhone"
    ]
    device_type = preferred(supported_types, "iPhone 17 Pro")
    if device_type is None and supported_types:
        device_type = supported_types[0]
    if device_type is None:
        raise RuntimeError(f"Runtime {runtime_id} exposes no supported iPhone device type.")

    created_udid = subprocess.check_output(
        [
            "xcrun",
            "simctl",
            "create",
            "HomeLibrary CI",
            str(device_type["identifier"]),
            runtime_id,
        ],
        text=True,
    ).strip()
    if not created_udid:
        raise RuntimeError("simctl did not return the created simulator UDID.")
    print(created_udid)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Unable to prepare an iOS Simulator: {error}", file=sys.stderr)
        raise SystemExit(1) from error

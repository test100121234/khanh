# QA Remote Device Management (RDM) & Central Coordination Engine

Production-grade remote iOS test automation engine and multi-core centralized coordination server designed for headless background testing over corporate Wi-Fi (Aruba APs).

---

## 1. Architecture Overview

```
 +---------------------------------------------------------+
 |                Central Windows/Linux Host               |
 |                                                         |
 |   +-------------------------------------------------+   |
 |   |        CentralCoordinatorServer (Python 3)      |   |
 |   |  - Async WebSocket Data Plane (ws://<IP>:8100)  |   |
 |   |  - Watchdog Supervisor (auto go-ios relaunch)   |   |
 |   +------------------------+------------------------+   |
 |                            | (multiprocessing.Queue)    |
 |                            v                            |
 |   +-------------------------------------------------+   |
 |   |       PaddleOCR-ONNX Engine (Process Pool)      |   |
 |   |  - N-2 Host CPU Cores (CPUExecutionProvider)    |   |
 |   |  - Real-time Screen Analysis & Command Routing  |   |
 |   +-------------------------------------------------+   |
 +----------------------------+----------------------------+
                              |
                     Wi-Fi (Aruba APs)
                              |
 +----------------------------v----------------------------+
 |                   Target iOS Device                     |
 |                                                         |
 |   +-------------------------------------------------+   |
 |   |           Headless QA Remote Agent              |   |
 |   |  - SilentAudioQueue (0% CPU background keeper)  |   |
 |   |  - AgentWebSocketServer (TCP_NODELAY @ 8100)    |   |
 |   |  - ScreenTelemetryCapturer (VT Hardware JPEG)   |   |
 |   |  - HIDEventSynthesizer (IOHIDEvent / BKS)       |   |
 |   |  - SystemController (LSWorkspace / UIPasteboard)|   |
 |   +-------------------------------------------------+   |
 +---------------------------------------------------------+
```

---

## 2. Modules & Capabilities

### Module 1: QA Remote Agent (iOS Objective-C / C)
- **Zero-CPU Keep-Alive**: `SilentAudioQueue` runs an audio queue playing empty PCM silence under `UIBackgroundModes: audio` to prevent iOS from suspending the background session.
- **Microsecond RPC**: Standalone, non-blocking `AgentWebSocketServer` bound to `0.0.0.0:8100` with `TCP_NODELAY`.
- **Bandwidth-Optimized Telemetry**: `ScreenTelemetryCapturer` captures pixel buffers via `IOSurface` / CoreGraphics and compresses frames on hardware via `VTCompressionSession` (Hardware JPEG, Quality 0.15). Transmits only on-demand when `{"action":"req_frame"}` is received.
- **Hardware-Level Event Synthesis**: Direct invocation of `IOHIDEventCreateDigitizerEvent`, `IOHIDEventCreateDigitizerFingerEventWithUserData`, `IOHIDEventCreateKeyboardEvent`, and `BKSHIDServicesPostEvent`.
- **System IPC & Routing**: `LSApplicationWorkspace` for opening app bundle IDs and URLs; `BKSTerminateApplication` for app kills; main-thread `UIPasteboard` synchronization; hardware and thermal telemetry.

### Module 2: CI/CD Deployment Pipeline (`scripts/deploy.sh`)
- Extracts provisioning profile metadata with `security cms -D`.
- Generates production-parity entitlements (`get-task-allow = false`).
- Injects Bundle ID & audio background mode into `Info.plist`.
- Builds `.app` with `xcodebuild` targeting `iphoneos`.
- Packages and re-signs with `zsign` using `.p12`.

### Module 3: Central Async Coordination Server (`server/coordinator_server.py`)
- **Device Provisioning**: Wraps `go-ios` CLI (`ios mounter mount`, `ios location set`, `ios launch`).
- **Telemetry Data Plane**: Async WebSocket client polling 2 FPS on-demand frames without flooding the wireless spectrum.
- **CV Analysis Engine**: Spawns \(N-2\) worker processes running `PaddleOCR-ONNX` in CPU mode.
- **Self-Healing Watchdog**: Catches disconnections and automatically triggers `go-ios launch` over Wi-Fi.

---

## 3. Quickstart

### Deploying the iOS Agent:
```bash
./scripts/deploy.sh -p enterprise.mobileprovision -c enterprise.p12 -k yay
```

### Running the Central Coordinator:
```bash
pip install -r server/requirements.txt
python server/coordinator_server.py
```

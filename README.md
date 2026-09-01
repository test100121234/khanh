# DeviceKit iOS - Headless QA Remote Agent & Fake WDA Server

A minimalistic, low-latency background agent and Fake WDA server for iOS test automation and remote device management (RDM) in enterprise Wi-Fi environments (Aruba APs).

**100% Free of XCTest, WDA Runner Daemons, and SPM bloat.**

---

## 🌟 Key Features

1. **Fake WDA + Ultra-Low Latency WebSocket RPC (`0.0.0.0:8100`)**:
   - Responds to standard WDA HTTP REST endpoints (`/status`, `/session`, `/screenshot`, `/wda/tap`, `/wda/keys`, `/wda/homescreen`, `/wda/lock`, `/wda/apps/launch`, `/wda/apps/terminate`, `/wda/clipboard`, `/wda/telemetry`).
   - Handles real-time WebSocket binary streaming with `TCP_NODELAY`.
2. **0% CPU Continuous Background Execution**:
   - `SilentAudioQueue` runs an empty PCM audio buffer under `UIBackgroundModes: audio` to prevent iOS from suspending the background testing session.
3. **Bandwidth-Optimized Screen Telemetry**:
   - Hardware-accelerated GPU pixel extraction via `IOSurface`.
   - `VTCompressionSession` hardware JPEG compression (Quality: 0.15).
   - Only transmits binary JPEG frames on-demand (`{"action":"req_frame"}`) to preserve Wi-Fi airtime.
4. **Hardware-Level Event Synthesis**:
   - Native touch/swipe injection via `IOHIDEventCreateDigitizerEvent` and `BKSHIDServicesPostEvent`.
   - Hardware text typing via `IOHIDEventCreateKeyboardEvent`.
   - Hardware Home/Power/Lock button simulation (Usage Page `0x0C`).
5. **System IPC & Routing**:
   - `LSApplicationWorkspace` for opening URLs, Universal Links, and bundle IDs.
   - `BKSTerminateApplication` for app management.
   - Main-thread `UIPasteboard` synchronization and battery/thermal telemetry.

---

## 📂 Repository Structure

```
├── DeviceKit/
│   ├── RemoteAgent/
│   │   ├── ApplePrivateHeaders.h          # IOHIDEvent, IOKit, & LSWorkspace Private APIs
│   │   ├── SilentAudioQueue.h/.m          # 0% CPU Audio Queue keep-alive
│   │   ├── ScreenTelemetryCapturer.h/.m   # IOSurface + VTCompressionSession hardware JPEG
│   │   ├── HIDEventSynthesizer.h/.m       # Digitizer & Keyboard hardware event synthesis
│   │   ├── SystemController.h/.m          # IPC, Clipboard, App Launch/Kill, & Telemetry
│   │   ├── AgentWebSocketServer.h/.m      # Fake WDA REST + WebSocket Server (TCP_NODELAY)
│   │   └── DeviceKitAgent-Bridging-Header.h
│   ├── View/
│   │   └── ContentView.swift              # Status Dashboard
│   ├── devicekit_iosApp.swift             # App Launch & Lifecycle Manager
│   └── Info.plist                         # UIBackgroundModes: audio
├── scripts/
│   └── deploy.sh                          # Enterprise build, plist injection, & zsign signing
├── server/
│   ├── coordinator_server.py              # Multi-core Python Async Coordinator & OCR
│   ├── devices.txt                        # Target device static IP list
│   └── requirements.txt                   # Python dependencies
├── devicekit-ios.xcodeproj                # Minimal Xcode project (Single app target, 0 XCTest)
└── Makefile                               # Clean build targets
```

---

## 🚀 Quickstart

### 1. Build Standalone App / IPA
```bash
# Build .app using Xcode
make build CONFIGURATION=Release

# Package unsigned IPA
make ipa
```

### 2. Enterprise Build & Auto-Signing
```bash
make deploy-enterprise PROVISION_PROFILE="path/to/enterprise.mobileprovision" CERT_P12="path/to/cert.p12" P12_PASSWORD="yay"
```

### 3. Start Multi-Core Async Coordinator
```bash
cd server
pip install -r requirements.txt
python coordinator_server.py
```

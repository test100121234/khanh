import SwiftUI

struct ContentView: View {
    @State private var uptime: String = "0s"
    @State private var memory: String = "-- MB"
    @State private var battery: String = "--%"
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 18) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 50)
                    .foregroundColor(.green)

                Text("DeviceKit QA Remote Agent")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text("Standalone iOS 18+ Automation Service")
                    .font(.caption)
                    .foregroundColor(.gray)

                VStack(alignment: .leading, spacing: 8) {
                    StatusRow(title: "WebSocket & Fake WDA", value: "0.0.0.0:8100 (TCP_NODELAY)", status: .active)
                    StatusRow(title: "Background Loop", value: "Silent PCM 8kHz (0% CPU)", status: .active)
                    StatusRow(title: "Telemetry Stream", value: "IOSurface + Hardware VT JPEG", status: .active)
                    StatusRow(title: "Memory / Battery", value: "\(memory) / \(battery)", status: .active)
                    StatusRow(title: "Uptime", value: uptime, status: .active)
                }
                .padding(14)
                .background(Color(white: 0.12))
                .cornerRadius(12)

                Text("Optimized for LAN Ethernet & Aruba Wi-Fi 24/7")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(20)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            SilentAudioQueue.sharedInstance().start()
            AgentWebSocketServer.sharedInstance().start(onPort: 8100)
        }
        .onReceive(timer) { _ in
            let tel = SystemController.sharedInstance().getSystemTelemetry()
            if let ram = tel["memory_usage_mb"] as? NSNumber {
                memory = String(format: "%.1f MB", ram.doubleValue)
            }
            if let bat = tel["battery_level"] as? NSNumber {
                let lvl = bat.floatValue
                battery = (lvl >= 0) ? String(format: "%.0f%%", lvl * 100) : "Charging"
            }
            if let up = tel["system_uptime"] as? NSNumber {
                let s = Int(up.doubleValue)
                let hours = s / 3600
                let mins = (s % 3600) / 60
                let secs = s % 60
                uptime = String(format: "%02dh %02dm %02ds", hours, mins, secs)
            }
        }
    }
}

enum StatusState {
    case active
    case inactive
}

struct StatusRow: View {
    let title: String
    let value: String
    let status: StatusState

    var body: some View {
        HStack {
            Circle()
                .fill(status == .active ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                Text(value)
                    .font(.footnote)
                    .foregroundColor(.white)
            }
            Spacer()
        }
    }
}

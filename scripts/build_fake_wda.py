#!/usr/bin/env python3
import os
import subprocess
import shutil
import sys
import glob

def run_cmd(cmd, cwd=None):
    print(f"[*] Chạy lệnh: {cmd}")
    subprocess.run(cmd, shell=True, check=True, cwd=cwd)

def main():
    print("=" * 70)
    print("🚀 DEVICEKIT FAKE WDA & STEALTH COMPILER")
    print("=" * 70)

    # 1. Clone Appium WebDriverAgent (Vỏ bọc chuẩn XCUITest)
    wda_dir = "wda_stealth_build"
    if os.path.exists(wda_dir):
        shutil.rmtree(wda_dir)
    run_cmd(f"git clone --depth 1 https://github.com/appium/WebDriverAgent.git {wda_dir}")

    # 2. Xóa sạch nhân xử lý nặng nề của Appium (Để lại vỏ bọc)
    print("[*] Đang loại bỏ toàn bộ mã nguồn nặng của Appium WebDriverAgentLib...")
    wda_lib_src = os.path.join(wda_dir, "WebDriverAgentLib")
    # Chúng ta không cần xoá file vật lý để tránh lỗi pbxproj reference, 
    # Thay vào đó, chúng ta sẽ làm rỗng file hoặc phớt lờ chúng, nhưng tốt nhất là thay thế ruột của file entry point.

    # 3. Tạo file Unity Build (Gộp toàn bộ code DeviceKit vào 1 file)
    print("[*] Đang tạo file Unity Build kết hợp mã nguồn DeviceKit...")
    unity_code = """
// ==============================================================================
// DEVICEKIT FAKE WDA - ULTRA LIGHTWEIGHT INJECTION
// ==============================================================================
#import <XCTest/XCTest.h>
#import <objc/runtime.h>

// Nhúng trực tiếp toàn bộ mã nguồn DeviceKit vào XCTest Runner
#import "AgentWebSocketServer.m"
#import "HIDEventSynthesizer.m"
#import "ScreenTelemetryCapturer.m"
#import "SystemController.m"
#import "SilentAudioQueue.m"

@interface DeviceKitFakeWDARunner : XCTestCase
@end

@implementation DeviceKitFakeWDARunner

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = YES;
}

- (void)testDeviceKitStealthAgent {
    NSLog(@"[🚀 DEVICEKIT] KÍCH HOẠT FAKE WDA - ĐỘNG CƠ XCUITEST VỚI 0%% CPU");
    
    // Tắt các tính năng rác của Appium nếu có chạy ngầm
    // Khởi động server nội bộ siêu nhẹ của DeviceKit
    AgentWebSocketServer *server = [AgentWebSocketServer sharedServer];
    [server startOnPort:8100];
    
    // Giữ cho luồng XCTest sống vĩnh viễn (nhường đường cho testmanagerd)
    NSLog(@"[🚀 DEVICEKIT] Kênh testmanagerd đã mở. Nhường đường cho OS xử lý sự kiện qua port 8100...");
    while (YES) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    }
}
@end
"""
    
    # 4. Sao chép toàn bộ thư mục DeviceKit/RemoteAgent vào WDA Runner
    print("[*] Đang sao chép mã nguồn DeviceKit vào dự án XCUITest...")
    src_dir = os.path.abspath("DeviceKit/RemoteAgent")
    target_dir = os.path.join(wda_dir, "WebDriverAgentRunner")
    
    for filename in os.listdir(src_dir):
        if filename.endswith(".h") or filename.endswith(".m"):
            shutil.copy(os.path.join(src_dir, filename), target_dir)

    # 5. Ghi đè file UITestingUITests.m của Appium bằng Unity Code của chúng ta
    entry_file = os.path.join(target_dir, "UITestingUITests.m")
    with open(entry_file, "w", encoding="utf-8") as f:
        f.write(unity_code)

    # 6. Ngụy trang Bundle ID và Tên ứng dụng (Stealth)
    print("[*] Đang ngụy trang Bundle ID (Stealth Mode)...")
    pbxproj_path = os.path.join(wda_dir, "WebDriverAgent.xcodeproj", "project.pbxproj")
    with open(pbxproj_path, "r", encoding="utf-8") as f:
        pbx_content = f.read()

    # Thay thế com.facebook.WebDriverAgentRunner thành Bundle sạch
    stealth_bundle = "hk.com.hsbc.enterprise.runner"
    pbx_content = pbx_content.replace("com.facebook.WebDriverAgentRunner", stealth_bundle)
    pbx_content = pbx_content.replace("com.facebook.wda.runner", stealth_bundle)
    pbx_content = pbx_content.replace("PRODUCT_NAME = WebDriverAgentRunner", "PRODUCT_NAME = DeviceKitRunner")
    
    with open(pbxproj_path, "w", encoding="utf-8") as f:
        f.write(pbx_content)

    print("[*] Kịch bản tạo Fake WDA & Stealth Compiler đã cấu hình xong!")
    print("[*] (Script này sẽ được gọi bởi GitHub Actions để compile IPA trên macOS)")

if __name__ == "__main__":
    main()

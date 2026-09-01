# ==============================================================================
# DeviceKit Fake WDA & QA Remote Agent - Build Makefile
# ==============================================================================

PROJECT = devicekit-ios.xcodeproj
SCHEME = devicekit-ios
BUILD_DIR = build
EXPORT_PATH = $(BUILD_DIR)/export

# Build configuration (Debug or Release)
CONFIGURATION ?= Release

# Enterprise Code Signing Defaults (HSBC Enterprise InHouse Profile)
PROVISION_PROFILE ?= cert/HSBC.mobileprovision
CERT_P12 ?= cert/HSBC.p12
P12_PASSWORD ?= yay

.PHONY: help clean build ipa deploy-enterprise coordinator

.DEFAULT_GOAL := help

help:
	@echo "================================================================="
	@echo " DeviceKit QA Remote Agent & Fake WDA Server Build System"
	@echo "================================================================="
	@echo "Available targets:"
	@echo "  build              Build standalone agent .app using xcodebuild"
	@echo "  ipa                Package unsigned .ipa for physical iOS devices"
	@echo "  deploy-enterprise  Build and sign enterprise agent IPA using deploy.sh"
	@echo "  coordinator        Start Python multi-core async coordination server"
	@echo "  clean              Clean all build artifacts"
	@echo ""

clean:
	@echo "[*] Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR)
	@xcodebuild clean -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) 2>/dev/null || true

# Build standalone agent .app
build:
	@echo "[*] Building $(SCHEME) ($(CONFIGURATION)) for iOS devices..."
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination 'generic/platform=iOS' \
		-derivedDataPath $(BUILD_DIR) \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO

# Package unsigned IPA
ipa: build
	@echo "[*] Packaging $(SCHEME).ipa..."
	@mkdir -p $(EXPORT_PATH)/Payload
	@cp -r "$(BUILD_DIR)/Build/Products/$(CONFIGURATION)-iphoneos/$(SCHEME).app" $(EXPORT_PATH)/Payload/
	@cd $(EXPORT_PATH) && zip -qry $(SCHEME).ipa Payload
	@rm -rf $(EXPORT_PATH)/Payload
	@echo "[✓] IPA packaged at: $(EXPORT_PATH)/$(SCHEME).ipa"

# Build and sign Enterprise Agent IPA via deploy.sh
deploy-enterprise:
	@chmod +x scripts/deploy.sh
	@scripts/deploy.sh -p "$(PROVISION_PROFILE)" -c "$(CERT_P12)" -k "$(P12_PASSWORD)"

# Start Central Async Coordination Server
coordinator:
	@python3 server/coordinator_server.py

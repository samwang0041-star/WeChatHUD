.PHONY: build app package notarize archive-notarized icon run debug preview self-check ai-check clean test

build:
	swift build -c release

# Keep the repository's existing local development identity as the default.
# Override with SIGN_IDENTITY=- for ad hoc local signing, or with a Developer
# ID Application identity for distribution.
SIGN_IDENTITY ?= WeChatHUD-DevCert

app: build
	SIGN_IDENTITY="$(SIGN_IDENTITY)" scripts/package-app.sh

package: build
	SIGN_IDENTITY="$(SIGN_IDENTITY)" scripts/package-app.sh --archive

icon:
	swift scripts/generate-app-icon.swift

# This target only prints the command. It never uploads to Apple. The archive
# must be signed with Developer ID and NOTARY_PROFILE must name a local
# notarytool keychain profile before a human runs the printed command.
APP_VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null)
DIST_ARCHIVE := .build/distribution/WeChatHUD-$(APP_VERSION)-macOS14-arm64.zip
KEY_TOOL_SRC := /Users/yuriwong/wechatcli/repo/wechat_cli/bin/find_all_keys_macos.arm64

notarize:
	@case "$(SIGN_IDENTITY)" in "Developer ID Application:"*) ;; *) echo "notarize requires SIGN_IDENTITY='Developer ID Application: ...'" >&2; exit 2 ;; esac
	@test -n "$(NOTARY_PROFILE)" || (echo "notarize requires NOTARY_PROFILE=<local notarytool keychain profile>" >&2; exit 2)
	@test -f "$(DIST_ARCHIVE)" || (echo "archive not found: $(DIST_ARCHIVE); run make package first" >&2; exit 2)
	@echo "No Apple upload was performed. Review the signed archive, then run manually:"
	@echo "xcrun notarytool submit \"$(DIST_ARCHIVE)\" --keychain-profile \"$(NOTARY_PROFILE)\" --wait"
	@echo "xcrun stapler staple .build/WeChatHUD.app"
	@echo "make archive-notarized"

# Re-archive the stapled app without rebuilding or replacing its signature.
archive-notarized:
	xcrun stapler validate .build/WeChatHUD.app
	spctl --assess --type execute --verbose=4 .build/WeChatHUD.app
	ditto -c -k --sequesterRsrc --keepParent .build/WeChatHUD.app "$(DIST_ARCHIVE)"
	@cd .build/distribution && shasum -a 256 "$(notdir $(DIST_ARCHIVE))" > "$(notdir $(DIST_ARCHIVE)).sha256"

run: app
	open .build/WeChatHUD.app

debug:
	swift build
	"$$(swift build --show-bin-path)/WeChatHUD"

# Separate identity and fictional local data; never starts the WeChat monitor.
preview:
	swift build
	@test -f Resources/AppIcon.icns || swift scripts/generate-app-icon.swift
	@mkdir -p ".build/WeChatHUD Preview.app/Contents/MacOS" ".build/WeChatHUD Preview.app/Contents/Resources"
	@cp "$$(swift build --show-bin-path)/WeChatHUD" ".build/WeChatHUD Preview.app/Contents/MacOS/"
	@cp Resources/Info.plist ".build/WeChatHUD Preview.app/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wechathud.product-preview" ".build/WeChatHUD Preview.app/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleName WeChatHUD Preview" ".build/WeChatHUD Preview.app/Contents/Info.plist"
	@cp Resources/AppIcon.icns ".build/WeChatHUD Preview.app/Contents/Resources/"
	@rm -rf ".build/WeChatHUD Preview.app/Contents/Resources/WeChatHUD_WeChatHUD.bundle"
	@cp -R "$$(swift build --show-bin-path)/WeChatHUD_WeChatHUD.bundle" ".build/WeChatHUD Preview.app/Contents/Resources/"
	@mkdir -p ".build/WeChatHUD Preview.app/Contents/Resources/keytools"
	@test -f "$(KEY_TOOL_SRC)" || { echo "key tool missing: $(KEY_TOOL_SRC)" >&2; exit 1; }
	@cp "$(KEY_TOOL_SRC)" ".build/WeChatHUD Preview.app/Contents/Resources/keytools/find_all_keys_macos.arm64"
	@chmod +x ".build/WeChatHUD Preview.app/Contents/Resources/keytools/find_all_keys_macos.arm64"
	@codesign --force --deep --sign - ".build/WeChatHUD Preview.app"
	@echo "Preview ready: .build/WeChatHUD Preview.app"

# Source databases are read-only; app-owned settings may be initialized.
self-check:
	swift build
	"$$(swift build --show-bin-path)/WeChatHUD" self-check

ai-check:
	swift build
	"$$(swift build --show-bin-path)/WeChatHUD" ai-check

clean:
	swift package clean
	rm -rf .build/WeChatHUD.app
	rm -rf .build/distribution

test:
	swift test

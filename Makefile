.PHONY: build app run debug clean test

build:
	swift build -c release

# Code signing identity. Override with: make app SIGN_IDENTITY="Your Name"
SIGN_IDENTITY ?= WeChatHUD-DevCert

app: build
	@rm -rf .build/WeChatHUD.app
	@mkdir -p .build/WeChatHUD.app/Contents/MacOS
	@mkdir -p .build/WeChatHUD.app/Contents/Resources
	@cp "$$(swift build -c release --show-bin-path)/WeChatHUD" .build/WeChatHUD.app/Contents/MacOS/
	@cp Resources/Info.plist .build/WeChatHUD.app/Contents/
	@codesign --force --deep --sign "$(SIGN_IDENTITY)" .build/WeChatHUD.app
	@echo "Built & signed: .build/WeChatHUD.app ($(SIGN_IDENTITY))"

run: app
	open .build/WeChatHUD.app

debug:
	swift build
	"$$(swift build --show-bin-path)/WeChatHUD"

clean:
	swift package clean
	rm -rf .build/WeChatHUD.app

test:
	swift test

.PHONY: build app run debug clean test

build:
	swift build -c release

app: build
	@rm -rf .build/WeChatHUD.app
	@mkdir -p .build/WeChatHUD.app/Contents/MacOS
	@mkdir -p .build/WeChatHUD.app/Contents/Resources
	@cp "$$(swift build -c release --show-bin-path)/WeChatHUD" .build/WeChatHUD.app/Contents/MacOS/
	@cp Resources/Info.plist .build/WeChatHUD.app/Contents/
	@echo "Built: .build/WeChatHUD.app"

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

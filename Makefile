VERSION ?= 1.0.0
APP_NAME = CodeLight
APP_BUNDLE = $(APP_NAME).app
ZIP_FILE = $(APP_NAME)-v$(VERSION).zip
SWIFT_SRC = main.swift Config.swift HotkeyManager.swift Weather.swift UI.swift CodeLight.swift PermissionBubble.swift HookConfig.swift MenuBuilder.swift LightWindowBuilder.swift LightAnimator.swift WebDAVSync.swift SettingsUI.swift SkillsManager.swift SkillsTab.swift
CLI_SRC = codelight-cli.swift
SERVER_SRC = light-server.py
BINARY = $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
RESOURCES = $(APP_BUNDLE)/Contents/Resources

.PHONY: build cli clean package release test test-unit test-integration

build: ## 编译 Universal Binary (arm64 + x86_64)
	swiftc -O -target arm64-apple-macosx13.0 \
		-framework Cocoa -framework CoreLocation -framework Foundation -framework ServiceManagement -framework UserNotifications \
		-o $(BINARY)-arm64 $(SWIFT_SRC)
	swiftc -O -target x86_64-apple-macosx13.0 \
		-framework Cocoa -framework CoreLocation -framework Foundation -framework ServiceManagement -framework UserNotifications \
		-o $(BINARY)-x86_64 $(SWIFT_SRC)
	lipo -create -output $(BINARY) $(BINARY)-arm64 $(BINARY)-x86_64
	rm -f $(BINARY)-arm64 $(BINARY)-x86_64
	-[ -f $(SERVER_SRC) ] && cp $(SERVER_SRC) $(RESOURCES)/light-server.py || true
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "✅ 编译完成: $(APP_BUNDLE) (Universal Binary)"

cli: ## 编译 CLI 工具 (Universal Binary)
	swiftc -O -arch arm64 -arch x86_64 -o codelight $(CLI_SRC)
	@echo "✅ CLI 编译完成: codelight (Universal Binary)"

clean: ## 清理编译产物
	rm -f $(BINARY) codelight
	@echo "🧹 已清理"

package: build ## 打包 zip
	rm -f $(ZIP_FILE)
	zip -r $(ZIP_FILE) $(APP_BUNDLE)
	@echo "📦 打包完成: $(ZIP_FILE)"

release: package ## 编译 + 打包 + 创建 GitHub Release（用法: make release VERSION=1.0.1）
	gh release create v$(VERSION) $(ZIP_FILE) \
		--title "v$(VERSION)" \
		--notes "$(shell cat release-notes.md 2>/dev/null || echo 'See README for details.')"
	@echo "🚀 已发布 v$(VERSION) 到 GitHub Releases"
	rm -f $(ZIP_FILE)

test: test-unit test-integration ## 运行所有测试

test-unit: ## 运行单元测试（纯逻辑，不需要运行应用）
	swift -target arm64-apple-macosx13.0 Tests/ConfigTests.swift

test-integration: ## 运行集成测试（需要 CodeLight 正在运行）
	bash Tests/run_tests.sh

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

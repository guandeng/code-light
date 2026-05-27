VERSION ?= 1.0.0
APP_NAME = CodeLight
APP_BUNDLE = $(APP_NAME).app
ZIP_FILE = $(APP_NAME)-v$(VERSION).zip
SWIFT_SRC = main.swift Config.swift Weather.swift UI.swift CodeLight.swift
SERVER_SRC = light-server.py
BINARY = $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
RESOURCES = $(APP_BUNDLE)/Contents/Resources

.PHONY: build clean package release

build: ## 编译 Swift 并更新 App Bundle
	swiftc -O -target arm64-apple-macosx13.0 \
		-framework Cocoa -framework CoreLocation -framework Foundation -framework ServiceManagement -framework UserNotifications \
		-o $(BINARY) $(SWIFT_SRC)
	-[ -f $(SERVER_SRC) ] && cp $(SERVER_SRC) $(RESOURCES)/light-server.py || true
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "✅ 编译完成: $(APP_BUNDLE)"

clean: ## 清理编译产物
	rm -f $(BINARY)
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

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

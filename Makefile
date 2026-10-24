APP_NAME := GH Switch.app
INSTALL_DIR := $(HOME)/Applications
BIN_DIR := $(HOME)/.local/bin

.PHONY: build test app install claude run clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

# Installs the app, links the CLI onto PATH, and registers the MCP server with Claude Code.
install: app
	pkill -x GHSwitch || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	mkdir -p "$(INSTALL_DIR)" "$(BIN_DIR)"
	cp -R "build/$(APP_NAME)" "$(INSTALL_DIR)/"
	ln -sf "$(INSTALL_DIR)/$(APP_NAME)/Contents/MacOS/gh-switch" "$(BIN_DIR)/gh-switch"
	"$(BIN_DIR)/gh-switch" install-claude
	open "$(INSTALL_DIR)/$(APP_NAME)"

claude:
	"$(BIN_DIR)/gh-switch" install-claude

run:
	swift run GHSwitch

clean:
	rm -rf .build build

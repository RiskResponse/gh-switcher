APP_NAME := GH Switch.app
INSTALL_DIR := $(HOME)/Applications
BIN_DIR := $(HOME)/.local/bin

.PHONY: build test app install claude desktop run clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

# Installs the app, links the CLI onto PATH, and registers the MCP server with Claude Code and the Claude desktop app.
install: app
	pkill -x GHSwitch || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	mkdir -p "$(INSTALL_DIR)" "$(BIN_DIR)"
	cp -R "build/$(APP_NAME)" "$(INSTALL_DIR)/"
	ln -sf "$(INSTALL_DIR)/$(APP_NAME)/Contents/MacOS/gh-switch" "$(BIN_DIR)/gh-switch"
	"$(BIN_DIR)/gh-switch" install-claude || echo "Skipped Claude Code (claude CLI not found)"
	"$(BIN_DIR)/gh-switch" install-desktop || echo "Skipped Claude desktop app (not installed)"
	open "$(INSTALL_DIR)/$(APP_NAME)"

claude:
	"$(BIN_DIR)/gh-switch" install-claude

desktop:
	"$(BIN_DIR)/gh-switch" install-desktop

run:
	swift run GHSwitch

clean:
	rm -rf .build build

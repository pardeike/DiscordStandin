SWIFT ?= swift
CONFIGURATION ?= release
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)
CODEX_MCP_ROOT ?= $(HOME)/.codex/mcp-servers
INSTALL_DIR ?= $(CODEX_MCP_ROOT)/discord-standin
APP_DIR ?= $(INSTALL_DIR)/DiscordStandin.app
INSTALLED_EXECUTABLE ?= $(APP_DIR)/Contents/MacOS/DiscordStandin
MCP_REGISTRAR ?= $(HOME)/Scripts/mcp-local

.PHONY: build test install

build:
	$(SWIFT) build -c $(CONFIGURATION)

test:
	$(SWIFT) test
	$(SWIFT) build
	python3 scripts/test-handshake.py .build/debug/DiscordStandin

install: test
	@test -n "$(CODESIGN_IDENTITY)" || { \
		echo "No Developer ID Application identity was found. Set CODESIGN_IDENTITY to a persistent signing identity." >&2; \
		exit 1; \
	}
	$(SWIFT) build -c release
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	install -m 755 ".build/release/DiscordStandin" "$(INSTALLED_EXECUTABLE)"
	install -m 644 "Resources/Info.plist" "$(APP_DIR)/Contents/Info.plist"
	codesign --force --deep --options runtime --timestamp --sign "$(CODESIGN_IDENTITY)" "$(APP_DIR)"
	codesign --verify --deep --strict "$(APP_DIR)"
	"$(INSTALLED_EXECUTABLE)" help >/dev/null
	python3 scripts/test-handshake.py "$(INSTALLED_EXECUTABLE)"
	@if [ -x "$(MCP_REGISTRAR)" ]; then "$(MCP_REGISTRAR)" register discord-standin "$(INSTALLED_EXECUTABLE)" server >/dev/null; fi

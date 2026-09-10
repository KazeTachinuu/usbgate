BIN     := usbgate
# Reverse-DNS service identifier. Used as the LaunchDaemon label, the plist
# filename and the log subsystem, and must match Gate.domain in the source.
LABEL   := io.github.kazetachinuu.usbgate
PREFIX  := /usr/local/libexec
DAEMON  := /Library/LaunchDaemons/$(LABEL).plist
RELEASE := .build/release/$(BIN)
LOG     := .build/install.log
STATE   := /var/db/usbgate

MIN_MACOS := 13
MIN_SWIFT := 6.0.3
CLT       := /Library/Developer/CommandLineTools

# Chosen by version, not by location: a suitable Swift on PATH always wins.
SWIFT = $(eval SWIFT := $(shell ./scripts/swift-toolchain.sh $(MIN_SWIFT)))$(SWIFT)

# usbgate has no dependencies, so the compiler is enough: no SwiftPM, and
# nothing in it to go wrong. Flags mirror the swiftSettings in Package.swift,
# which is still what runs the tests.
SWIFTC = $(dir $(SWIFT))swiftc
STRICT := -O -swift-version 6 -enable-upcoming-feature ExistentialAny \
	  -enable-upcoming-feature InternalImportsByDefault
OUT    := $(dir $(RELEASE))

# True when an earlier 'sudo make' left files a user build cannot overwrite.
ROOT_OWNED = [ -d .build ] && find .build -user root -print -quit 2>/dev/null | grep -q .

# swiftlint needs sourcekitd, which Command Line Tools ships outside the search
# path. It has to be set on the command itself: SIP strips DYLD_* when make execs
# /bin/sh, so exporting it from here would never reach swiftlint.
SOURCEKIT = DYLD_FRAMEWORK_PATH=$(shell xcode-select -p)/usr/lib

.DEFAULT_GOAL := build

.PHONY: build test lint format sast check tools integration install uninstall clean not-root sane prereqs

# Everything the build and the daemon require, checked before anything is built.
prereqs:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo "  [-] usbgate is macOS only (Disk Arbitration and IOKit)"; exit 1; fi
	@macos=$$(sw_vers -productVersion); major=$$(echo $$macos | cut -d. -f1); \
		if [ "$$major" -lt "$(MIN_MACOS)" ]; then \
			echo "  [-] macOS $$macos; usbgate needs macOS $(MIN_MACOS) or later"; exit 1; fi; \
		echo "  [+] macOS $$macos"
	@command -v $(SWIFT) >/dev/null 2>&1 || { \
		echo "  [-] no swift found"; \
		echo "      install the developer tools:  xcode-select --install"; exit 1; }
	@ver=$$($(SWIFT) -version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1); \
		if [ -z "$$ver" ]; then \
			echo "  [-] $(SWIFT) exists but does not run"; \
			case "$(SWIFT)" in \
				/usr/bin/*|$(CLT)/*) \
					echo "      sudo rm -rf $(CLT) && xcode-select --install" ;; \
				*.app/*) echo "      update Xcode from the App Store" ;; \
				*) echo "      swiftly install latest" ;; \
			esac; \
			exit 1; fi; \
		if [ "$$(printf '%s\n%s\n' "$(MIN_SWIFT)" "$$ver" | sort -V | head -1)" != "$(MIN_SWIFT)" ]; then \
			echo "  [-] swift $$ver at $(SWIFT); this needs $(MIN_SWIFT) or later"; \
			case "$(SWIFT)" in \
				/usr/bin/*|$(CLT)/*) \
					echo "      sudo rm -rf $(CLT) && xcode-select --install" ;; \
				*.app/*) echo "      update Xcode from the App Store" ;; \
				*) echo "      swiftly install latest" ;; \
			esac; \
			exit 1; fi; \
		echo "  [+] swift $$ver at $(SWIFT)"

# A past 'sudo make' leaves root-owned files in .build that a later user build
# cannot overwrite, and the resulting errors do not say why.
sane:
	@if $(ROOT_OWNED); then \
		echo "[!] .build contains root-owned files from an earlier sudo run"; \
		echo "    fix with: make clean"; \
		exit 1; \
	fi

build: sane prereqs
	@mkdir -p $(OUT)
	@$(SWIFTC) $(STRICT) -emit-library -static -emit-module -module-name USBGateKit \
		-emit-module-path $(OUT)USBGateKit.swiftmodule \
		-o $(OUT)libUSBGateKit.a Sources/USBGateKit/*.swift
	@$(SWIFTC) $(STRICT) -module-name $(BIN) -o $(RELEASE) Sources/usbgate/*.swift \
		-I $(OUT) -L $(OUT) -lUSBGateKit \
		-framework DiskArbitration -framework IOKit
	@echo "  [+] $(RELEASE)"

test: sane prereqs
	$(SWIFT) test

lint:
	@if command -v swift-format >/dev/null 2>&1; then \
		swift-format lint --strict --recursive Sources Tests && echo "[+] swift-format"; \
	else echo "[!] swift-format not installed, skipped   (brew install swift-format)"; fi
	@if command -v swiftlint >/dev/null 2>&1; then \
		$(SOURCEKIT) swiftlint lint --quiet --strict && echo "[+] swiftlint"; \
	else echo "[!] swiftlint not installed, skipped      (brew install swiftlint)"; fi

format:
	@command -v swift-format >/dev/null 2>&1 \
		&& swift-format format --in-place --recursive Sources Tests \
		|| echo "[!] swift-format not installed   (brew install swift-format)"

# Settings kept in the build directory: semgrep otherwise writes to ~/.semgrep,
# which one run under sudo leaves root-owned and unusable.
sast:
	@mkdir -p .build
	@if command -v semgrep >/dev/null 2>&1; then \
		SEMGREP_SETTINGS_FILE=.build/semgrep.yml \
		semgrep --config .semgrep.yml --error --quiet Sources && echo "[+] semgrep"; \
	else echo "[!] semgrep not installed, skipped        (brew install semgrep)"; fi

check: test lint sast

tools:
	brew install swift-format swiftlint semgrep

integration:
	@./scripts/integration-test.sh

# First prerequisite, so it refuses before anything is built. Building as root
# leaves root-owned files in .build and breaks every later build; only the steps
# in the recipe need privileges.
not-root:
	@if [ "$$(id -u)" -eq 0 ]; then \
		echo "[-] run 'make install' as yourself, not with sudo"; \
		echo "    it asks for sudo only where it needs it"; \
		exit 1; \
	fi

# Quiet by design: each step reports one line, and only a failure prints detail.
# Linting and the SAST scan are developer tools and are not part of installing.
install: not-root sane prereqs
	@mkdir -p .build
	@printf "\n  usbgate\n\n"
	@printf "  [*] building\n"
	@$(MAKE) build >$(LOG) 2>&1 || { \
		printf "  [-] build failed\n\n"; \
		{ grep -E "error:" $(LOG) || cat $(LOG); } | head -20; \
		printf "\n  full output: %s\n\n" "$(LOG)"; exit 1; }
	@printf "  [*] installing, sudo required\n"
	@sudo install -d -o root -g wheel -m 755 $(PREFIX)
	@sudo install -o root -g wheel -m 755 $(RELEASE) $(PREFIX)/$(BIN)
	@sudo ln -sf $(PREFIX)/$(BIN) /usr/local/bin/$(BIN)
	@sudo install -o root -g wheel -m 644 deploy/$(LABEL).plist $(DAEMON)
	@sudo launchctl bootout system $(DAEMON) 2>/dev/null || true
	@sudo launchctl bootstrap system $(DAEMON)
	@printf "  [+] %s\n" "$(PREFIX)/$(BIN)"
	@printf "  [+] %s\n" "/usr/local/bin/$(BIN)"
	@if launchctl print system/$(LABEL) 2>/dev/null | grep -q "state = running"; then \
		printf "  [+] daemon running\n"; \
	else printf "  [-] daemon did not start, see: usbgate log\n"; exit 1; fi
	@if [ -t 1 ]; then G="\033[1;32m"; D="\033[2m"; Z="\033[0m"; fi; \
		printf "\n  $$G%s$$Z\n" "-----------------------------------------------"; \
		printf "  $$G  usbgate installed successfully$$Z\n"; \
		printf "  $$G%s$$Z\n" "-----------------------------------------------"; \
		printf "\n  $${D}current state$$Z\n"
	@sudo $(PREFIX)/$(BIN) status

# The allowlist is left in place so reinstalling does not lose the devices you
# authorised. Removing it is one command, printed below.
uninstall:
	@printf "\n  [*] removing usbgate, sudo required\n"
	@sudo launchctl bootout system $(DAEMON) 2>/dev/null || true
	@sudo rm -f $(DAEMON) $(PREFIX)/$(BIN) /usr/local/bin/$(BIN)
	@printf "  [+] daemon stopped\n"
	@printf "  [+] removed  %s\n" "$(PREFIX)/$(BIN)"
	@printf "  [+] removed  %s\n" "/usr/local/bin/$(BIN)"
	@printf "  [+] removed  %s\n" "$(DAEMON)"
	@printf "  [!] kept     %s   (your allowlist)\n" "$(STATE)"
	@printf "\n      to remove that too:  sudo rm -rf %s\n\n" "$(STATE)"

clean:
	@if $(ROOT_OWNED); then \
		echo "[!] removing root-owned build files, this needs sudo"; \
		sudo rm -rf .build; \
	else rm -rf .build; fi

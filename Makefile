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
MIN_SWIFT := 6.0

# Chosen by version, not by location: a suitable Swift on PATH always wins.
SWIFT := $(shell ./scripts/swift-toolchain.sh $(MIN_SWIFT))

# swiftlint needs sourcekitd, which Command Line Tools ships outside the search
# path. It has to be set on the command itself: SIP strips DYLD_* when make execs
# /bin/sh, so exporting it from here would never reach swiftlint.
SOURCEKIT := DYLD_FRAMEWORK_PATH=$(shell xcode-select -p)/usr/lib

.PHONY: build test lint format sast check tools integration install uninstall clean not-root sane prereqs

# Building and installing need only the Swift toolchain. The linters and the SAST
# scanner are optional: when absent they say so and are skipped.

# Everything the build and the daemon require, checked before anything is built.
prereqs:
	@printf "\n  usbgate\n\n"
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo "  [-] usbgate is macOS only (Disk Arbitration and IOKit)"; exit 1; fi
	@macos=$$(sw_vers -productVersion); major=$$(echo $$macos | cut -d. -f1); \
		if [ "$$major" -lt "$(MIN_MACOS)" ]; then \
			echo "  [-] macOS $$macos; $(MIN_SWIFT) needs macOS $(MIN_MACOS) or later"; exit 1; fi; \
		echo "  [+] macOS $$macos"
	@command -v $(SWIFT) >/dev/null 2>&1 || { \
		echo "  [-] swift not found"; \
		echo "      install the command line tools:  xcode-select --install"; exit 1; }
	@ver=$$($(SWIFT) -version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1); \
		major=$$(echo $$ver | cut -d. -f1); minor=$$(echo $$ver | cut -d. -f2); \
		want_major=$$(echo $(MIN_SWIFT) | cut -d. -f1); want_minor=$$(echo $(MIN_SWIFT) | cut -d. -f2); \
		if [ "$$major" -lt "$$want_major" ] || \
		   { [ "$$major" -eq "$$want_major" ] && [ "$$minor" -lt "$$want_minor" ]; }; then \
			echo "  [-] swift $$ver at $(SWIFT); this needs $(MIN_SWIFT) or later"; \
			echo "      install one:  brew install swiftly && swiftly init && swiftly install $(MIN_SWIFT)"; \
			exit 1; fi; \
		echo "  [+] swift $$ver"

# A past 'sudo make' leaves root-owned files in .build that a later user build
# cannot overwrite, and the resulting errors do not say why.
sane:
	@if [ -d .build ] && find .build -user root -print -quit 2>/dev/null | grep -q .; then \
		echo "[!] .build contains root-owned files from an earlier sudo run"; \
		echo "    fix with: make clean"; \
		exit 1; \
	fi

build: sane
	$(SWIFT) build -c release

test: sane
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
install: not-root prereqs sane
	@mkdir -p .build
	@printf "  [*] building\n"
	@$(SWIFT) build -c release >$(LOG) 2>&1 || { \
		printf "  [-] build failed\n\n"; \
		grep -E "error:" $(LOG) | head -20 || cat $(LOG); \
		printf "\n  full output: %s\n\n" "$(LOG)"; exit 1; }
	@printf "  [*] testing\n"
	@$(SWIFT) test >$(LOG) 2>&1 || { \
		printf "  [-] tests failed\n\n"; \
		grep -E "error:|recorded an issue|Test .* failed" $(LOG) | head -20 || cat $(LOG); \
		printf "\n  full output: %s\n\n" "$(LOG)"; exit 1; }
	@printf "  [+] %s tests passed\n" \
		"$$(sed -n 's/.*with \([0-9]*\) tests passed.*/\1/p' $(LOG) | tail -1)"
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
	@if [ -d .build ] && find .build -user root -print -quit 2>/dev/null | grep -q .; then \
		echo "[!] removing root-owned build files, this needs sudo"; \
		sudo rm -rf .build; \
	else rm -rf .build; fi

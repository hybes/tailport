PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
DARWIN_ARTIFACT := $(CURDIR)/dist/tailport-darwin
export TAILPORT_BUILD_DIR ?= $(CURDIR)/macos/.build

.PHONY: build app test test-app package release install uninstall clean

build:
	zsh scripts/build.zsh

app:
	zsh scripts/build-app.zsh

test: build
	zsh -n src/tailport.zsh
	zsh tests/tailport_test.zsh "$(DARWIN_ARTIFACT)"
	$(MAKE) test-app

test-app:
	swift test --package-path macos --scratch-path "$(TAILPORT_BUILD_DIR)"

package: test app
	zsh scripts/package.zsh

release:
	$(MAKE) clean
	$(MAKE) package
	@printf '\nRelease artifacts are ready in dist/.\n'

install: build
	mkdir -p "$(BINDIR)"
	install -m 0755 "$(DARWIN_ARTIFACT)" "$(BINDIR)/tailport"
	ln -sfn tailport "$(BINDIR)/tp"
	@printf 'Installed tailport and tp in %s\n' "$(BINDIR)"

uninstall:
	rm -f "$(BINDIR)/tailport"
	@if [ "$$(readlink "$(BINDIR)/tp" 2>/dev/null)" = "tailport" ]; then \
		rm "$(BINDIR)/tp"; \
	fi
	@printf 'Removed tailport from %s\n' "$(BINDIR)"

clean:
	rm -rf dist

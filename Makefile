PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
DARWIN_ARTIFACT := $(CURDIR)/dist/tailport-darwin
export TAILPORT_BUILD_DIR ?= $(CURDIR)/macos/.build
DOTNET ?= dotnet

.PHONY: build app test test-app windows-app test-windows-app windows-screenshots package release publish install uninstall clean

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

# The Windows app needs the .NET 10 SDK; it is not part of `make test` or `make release`.
windows-app:
	DOTNET="$(DOTNET)" zsh scripts/build-windows-app.zsh

test-windows-app:
	"$(DOTNET)" test windows/tests/Tailport.Core.Tests

windows-screenshots:
	"$(DOTNET)" run --project windows/tools/Tailport.Screenshots -- "$(CURDIR)/dist/windows-screenshots"

package: test app
	zsh scripts/package.zsh

# Release builds of the Mac app run on Apple silicon and Intel Macs.
release:
	$(MAKE) clean
	TAILPORT_ARCHS="$${TAILPORT_ARCHS:-arm64 x86_64}" $(MAKE) package
	@printf '\nRelease artifacts are ready in dist/.\n'

# Signs with Developer ID, notarises, tags and creates the GitHub release. NOTES=file sets the release notes.
publish:
	zsh scripts/publish.zsh $(NOTES)

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

# Caliper -- a front door to the commands in Tools/ and the website in Website/.
#
# The scripts stay the source of truth: this file never reimplements bundling,
# signing or releasing, it only spells out the invocations that are easy to get
# wrong from memory. Everything here works from a clean checkout with nothing
# installed but Xcode's toolchain.

BENCH       := .build/release/caliper-bench
APP         := build/Caliper.app
DURATION    ?= 30

.DEFAULT_GOAL := help

# Every target is a verb, and `build/` is a real directory in this tree -- an
# undeclared `build` target would silently be "up to date" forever.
.PHONY: help build release test run app open install stop bundle bench-tool \
        bench soak watch sensors preview gallery icon package update-key clean \
        docs docs-dev docs-build docs-stop

help: ## List the available targets
	@echo "Caliper, last released as $$(git describe --tags --abbrev=0 2>/dev/null || echo nothing yet)"
	@echo
	@grep -E '^[a-z][a-zA-Z0-9_-]*:.*##' $(MAKEFILE_LIST) \
		| awk -F':.*##[ ]*' '{ printf "  %-10s %s\n", $$1, $$2 }'
	@echo
	@echo "  variables: DURATION=$(DURATION) DOCS_PORT=$(DOCS_PORT)"

## -- day to day ------------------------------------------------------------

run: stop ## Build and run the app from source (Ctrl-C to quit)
	swift run Caliper

build: ## Compile everything, debug
	swift build

release: ## Compile everything, release
	swift build -c release

test: ## Run the test suite
	swift test

## -- the bundle ------------------------------------------------------------

# `run` is the fast loop and is the real strip, but a bundle-less binary has no
# bundle identifier, so update checks and notifications take their fallback
# paths. Exercising either one means building the .app.

bundle: ## Assemble build/Caliper.app (release, signed)
	./Tools/bundle.sh release

app: stop bundle ## Bundle the app and launch it
	open $(APP)

open: app ## Alias for `app`

install: bundle ## Copy the bundled app to /Applications
	@rm -rf /Applications/Caliper.app
	cp -R $(APP) /Applications/Caliper.app
	@echo "installed /Applications/Caliper.app"

stop: ## Quit any running Caliper
	@pkill -x Caliper 2>/dev/null && echo "stopped the running Caliper" || true

## -- measuring -------------------------------------------------------------

bench-tool:
	@swift build -c release --product caliper-bench

bench: bench-tool ## Micro-benchmarks: sampler and render costs
	$(BENCH) micro

soak: bench-tool ## Full pipeline against the budget, DURATION seconds
	$(BENCH) soak $(DURATION)

watch: bench-tool ## Measure the running Caliper.app, DURATION seconds
	$(BENCH) watch $(DURATION)

sensors: bench-tool ## List every metric source and what it reads
	$(BENCH) sensors

preview: bench-tool ## Render the live strip to build/strip.png
	@mkdir -p build
	$(BENCH) preview build/strip.png $(DURATION)

gallery: bench-tool ## Render every cell style to build/gallery.png
	@mkdir -p build
	$(BENCH) gallery build/gallery.png

icon: bench-tool ## Redraw the app iconset from code
	@mkdir -p build
	$(BENCH) icon build/AppIcon.iconset

## -- releasing -----------------------------------------------------------

# Releases are made by .github/workflows/release.yml -- push a v1.2.0 tag on
# main -- not from here. `package` runs the same script, so it is how to try the
# pipeline: it needs a Developer ID, and NOTARY_PROFILE to notarise. Without
# CALIPER_VERSION and CALIPER_BUILD the image holds a development build, which
# never updates itself.

package: ## Signed, notarised disk image in build/. NOTARY_PROFILE=<profile>
	./Tools/package.sh

# One-time: the key pair Sparkle signs releases with. Writes the public half into
# Resources/Info.plist and keeps the private half in your login Keychain.
update-key: ## Make (or find) the update signing key
	./Tools/update-key.sh

clean: ## Remove all build products, the website's included
	rm -rf .build build $(WEBSITE)/dist

## -- the website ---------------------------------------------------------

# The homepage and documentation: Astro + Starlight, static output in
# Website/dist. Needs Node (the version in Website/.nvmrc). Nothing here touches
# the app build.

WEBSITE     := Website
DOCS_PORT   ?= 4321

# A real directory target, so npm only runs when the manifest is newer than
# what is installed.
$(WEBSITE)/node_modules: $(WEBSITE)/package.json
	@npm --prefix $(WEBSITE) install
	@touch $@

# astro preview daemonises, so this hands the prompt back with the server up.
docs: docs-build ## Build the website and serve it, as deployed
	@npm --prefix $(WEBSITE) run preview -- --port $(DOCS_PORT) --open
	@echo "serving http://localhost:$(DOCS_PORT)/caliper/ - stop it with: make docs-stop"

docs-stop: ## Stop the server `make docs` started
	@npm --prefix $(WEBSITE) run preview:stop 2>/dev/null || true

docs-dev: $(WEBSITE)/node_modules ## Hot-reloading website server (Ctrl-C to quit)
	@npm --prefix $(WEBSITE) run dev -- --open

docs-build: $(WEBSITE)/node_modules ## Build the website into Website/dist
	@npm --prefix $(WEBSITE) run build

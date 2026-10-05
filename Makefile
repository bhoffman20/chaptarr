# Build and run a local dev instance of Chaptarr from this checkout.
#
#   make build      backend + frontend
#   make start      start the dev instance in the background (via $(DEV_RUN))
#   make stop       stop it gracefully
#   make restart    stop + start (does not rebuild; use `make rebuild` for that)
#   make rebuild    build + restart
#   make status / logs / test
#   make wipe-db    stop, move the dev databases into $(DEV_BACKUPS)/<timestamp>, leave dev stopped
#   make fresh      wipe-db + start (config.xml is kept, so port/auth/API key survive)
#   make save-config     save dev's settings + root folders to $(DEV_DATA)/config-baseline (no library data)
#   make restore-config  restore that baseline into the running dev instance
#   make fresh-config    fresh + restore-config
#   make docker-push     build Dockerfile.cross and push $(IMAGE):<branch> and :<branch>-<sha>
#                        (override TAG=, IMAGE=, PLATFORMS=; ALLOW_DIRTY=1 to build uncommitted changes)
#
# The dev instance is launched by an external run script (sandboxing, port, data dir, API key
# live there, not in the repo). Override with: make start DEV_DIR=/path/to/dev

SHELL := /bin/bash

DOTNET_ROOT ?= $(HOME)/.dotnet
export PATH := $(DOTNET_ROOT):$(PATH)
export DOTNET_CLI_TELEMETRY_OPTOUT := 1

CONFIGURATION ?= Release
YARN ?= npx --yes yarn@1.22.19

DEV_DIR ?= /mnt/z/dev/chaptarr
DEV_RUN ?= $(DEV_DIR)/run-dev.sh
DEV_LOG ?= $(DEV_DIR)/run-dev.log
DEV_APP_LOG ?= $(DEV_DIR)/data/logs/chaptarr.txt
DEV_PORT ?= 8790
DEV_DATA ?= $(DEV_DIR)/data
DEV_BACKUPS ?= $(DEV_DIR)/db-backups
DEV_CONFIG_TOOL ?= $(DEV_DIR)/dev-config.py

IMAGE ?= ghcr.io/bhoffman20/chaptarr
IMAGE_SOURCE ?= https://github.com/bhoffman20/chaptarr
PLATFORMS ?= linux/amd64

APP_DLL := $(CURDIR)/_output/net10.0/Chaptarr.dll
# Matches only the dev process started from this checkout, never prod's container process.
DEV_PATTERN := ^dotnet $(APP_DLL)

.PHONY: build backend frontend frontend-deps test start stop restart rebuild status logs wipe-db fresh save-config restore-config fresh-config docker-push

build: backend frontend

backend:
	dotnet build src/Chaptarr.sln -c $(CONFIGURATION)

frontend-deps: node_modules/.yarn-integrity

node_modules/.yarn-integrity: package.json yarn.lock
	$(YARN) install --frozen-lockfile

frontend: frontend-deps
	$(YARN) build

test:
	dotnet test src/Chaptarr.Core.Test/Chaptarr.Core.Test.csproj -c $(CONFIGURATION) $(if $(FILTER),--filter "$(FILTER)")

# One shell block: an early `exit 0` on a separate recipe line wouldn't stop the later lines.
start:
	@if pgrep -f "$(DEV_PATTERN)" >/dev/null; then echo "dev already running (pid $$(pgrep -f '$(DEV_PATTERN)'))"; exit 0; fi; \
	test -x "$(DEV_RUN)" || { echo "$(DEV_RUN) not found; set DEV_DIR or DEV_RUN" >&2; exit 1; }; \
	test -f "$(APP_DLL)" || { echo "$(APP_DLL) missing; run 'make build' first" >&2; exit 1; }; \
	(cd "$(DEV_DIR)" && nohup "$(DEV_RUN)" >> "$(DEV_LOG)" 2>&1 < /dev/null &); \
	echo -n "starting dev on :$(DEV_PORT) "; \
	for i in $$(seq 1 90); do \
		if curl -fs "http://localhost:$(DEV_PORT)/ping" >/dev/null 2>&1; then echo " up (pid $$(pgrep -f '$(DEV_PATTERN)'))"; exit 0; fi; \
		if [ $$i -gt 5 ] && ! pgrep -f "$(DEV_PATTERN)" >/dev/null; then echo " exited; see $(DEV_LOG)"; tail -n 20 "$(DEV_LOG)"; exit 1; fi; \
		echo -n .; sleep 1; \
	done; echo " timed out waiting for /ping; see $(DEV_LOG)"; exit 1

stop:
	@pid=$$(pgrep -f "$(DEV_PATTERN)" || true); \
	if [ -z "$$pid" ]; then echo "dev not running"; exit 0; fi; \
	echo -n "stopping dev (pid $$pid) "; kill $$pid; \
	for i in $$(seq 1 30); do kill -0 $$pid 2>/dev/null || { echo " stopped"; exit 0; }; echo -n .; sleep 1; done; \
	echo " still running after 30s, sending SIGKILL"; kill -9 $$pid

restart: stop start

rebuild: build restart

status:
	@pid=$$(pgrep -f "$(DEV_PATTERN)" || true); \
	if [ -n "$$pid" ]; then echo "running (pid $$pid)"; curl -fs "http://localhost:$(DEV_PORT)/ping" >/dev/null && echo "responding on :$(DEV_PORT)" || echo "not responding on :$(DEV_PORT)"; \
	else echo "not running"; fi

logs:
	tail -n 50 -f "$(DEV_APP_LOG)"

# Moves (not copies) the databases, so the backup is also the wipe. Also moves MediaCover and the
# seed-dev.py marker files, which describe state that only exists in the old database.
wipe-db: stop
	@test -f "$(DEV_DATA)/config.xml" || { echo "$(DEV_DATA) doesn't look like a Chaptarr data dir; refusing" >&2; exit 1; }; \
	if pgrep -f "$(DEV_PATTERN)" >/dev/null; then echo "dev still running; refusing" >&2; exit 1; fi; \
	shopt -s nullglob; \
	files=(); \
	for f in "$(DEV_DATA)"/*.db "$(DEV_DATA)"/*.db-{wal,shm,journal} "$(DEV_DATA)"/.rescanned-* \
	         "$(DEV_DATA)"/.settings-restored "$(DEV_DATA)"/MediaCover; do \
		[ -e "$$f" ] && files+=("$$f"); \
	done; \
	if [ $${#files[@]} -eq 0 ]; then echo "nothing to wipe"; exit 0; fi; \
	dest="$(DEV_BACKUPS)/$$(date +%Y%m%d-%H%M%S)"; \
	mkdir -p "$(DEV_BACKUPS)" && mkdir "$$dest" || { echo "can't create $$dest; refusing" >&2; exit 1; }; \
	mv -- "$${files[@]}" "$$dest"/; \
	echo "moved $${#files[@]} items to $$dest"

fresh: wipe-db
	@$(MAKE) --no-print-directory start

save-config:
	"$(DEV_CONFIG_TOOL)" save

restore-config:
	"$(DEV_CONFIG_TOOL)" restore

fresh-config: fresh
	@$(MAKE) --no-print-directory restore-config

# The build context is the working tree, so uncommitted changes would ship under a commit's tag;
# with ALLOW_DIRTY=1 the sha tag gets a -dirty suffix.
docker-push:
	@dirty=""; \
	if [ -n "$$(git status --porcelain)" ]; then \
		if [ -z "$(ALLOW_DIRTY)" ]; then echo "working tree not clean; commit first or pass ALLOW_DIRTY=1" >&2; exit 1; fi; \
		dirty="-dirty"; \
	fi; \
	tag="$(TAG)"; \
	if [ -z "$$tag" ]; then \
		branch=$$(git symbolic-ref --short -q HEAD) || { echo "detached HEAD; pass TAG=<name>" >&2; exit 1; }; \
		tag=$$(echo "$$branch" | sed -E 's/[^A-Za-z0-9_.-]+/-/g; s/^[.-]+//'); \
	fi; \
	if [[ ! "$$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,119}$$ ]]; then echo "invalid image tag: $$tag" >&2; exit 1; fi; \
	sha=$$(git rev-parse --short HEAD)$$dirty; \
	echo "pushing $(IMAGE):$$tag and $(IMAGE):$$tag-$$sha ($(PLATFORMS))"; \
	docker buildx build -f Dockerfile.cross --platform "$(PLATFORMS)" \
		--label org.opencontainers.image.source=$(IMAGE_SOURCE) \
		--label org.opencontainers.image.revision=$$(git rev-parse HEAD) \
		-t "$(IMAGE):$$tag" -t "$(IMAGE):$$tag-$$sha" \
		--push .

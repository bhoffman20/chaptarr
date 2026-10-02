# Build and run a local dev instance of Chaptarr from this checkout.
#
#   make build      backend + frontend
#   make start      start the dev instance in the background (via $(DEV_RUN))
#   make stop       stop it gracefully
#   make restart    stop + start (does not rebuild; use `make rebuild` for that)
#   make rebuild    build + restart
#   make status / logs / test
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

APP_DLL := $(CURDIR)/_output/net10.0/Chaptarr.dll
# Matches only the dev process started from this checkout, never prod's container process.
DEV_PATTERN := ^dotnet $(APP_DLL)

.PHONY: build backend frontend frontend-deps test start stop restart rebuild status logs

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

.PHONY: help inventory version changelog release-major release-minor release-patch deploy-full deploy-gateway deploy-control deploy-service-x redeploy-full redeploy-gateway redeploy-control redeploy-service-x ui ui-install ui-stop

VERSION := $(shell cat VERSION 2>/dev/null)
UI_PORT := 8090
UI_VENV := .venv-ui
UI_PY := $(UI_VENV)/bin/python3
UI_CMD_MATCH := .venv-ui/bin/python3 -m uvicorn server:app

help:
	@echo "Targets:"
	@echo "  version             Print the current repo version"
	@echo "  changelog           Show the top of CHANGELOG.md"
	@echo "  release-major       Bump the major version and scaffold the changelog"
	@echo "  release-minor       Bump the minor version and scaffold the changelog"
	@echo "  release-patch       Bump the patch version and scaffold the changelog"
	@echo "  inventory           Refresh ansible inventory from Terraform outputs"
	@echo "  deploy-full         Deploy all; if existing infra detected, optionally destroy+recreate"
	@echo "  deploy-gateway      Deploy gateway; if it exists, optionally destroy+recreate"
	@echo "  deploy-control      Deploy control/core; if it exists, optionally destroy+recreate"
	@echo "  deploy-service-x    Placeholder for future service"
	@echo "  ui                  Start the local web UI (http://localhost:8090)"
	@echo "  ui-install          Install Python dependencies for the web UI"
	@echo "  ui-stop             Stop the running web UI (SIGINT, equivalent to Ctrl-C)"
	@echo ""
	@echo "Tip: add DEPLOY_YES=1 to auto-answer yes (e.g. make DEPLOY_YES=1 deploy-gateway)"

version:
	@printf '%s\n' "$(VERSION)"

changelog:
	@sed -n '1,80p' CHANGELOG.md

release-major:
	@scripts/release.sh bump major

release-minor:
	@scripts/release.sh bump minor

release-patch:
	@scripts/release.sh bump patch

inventory:
	terraform -chdir=terraform output -json > ansible/inventory/terraform-outputs.json
	chmod +x ansible/inventory/tfgrid.py || true

deploy-full:
	DEPLOY_YES=$(DEPLOY_YES) scripts/deploy.sh full $(if $(DEPLOY_YES),--yes,)

deploy-gateway:
	DEPLOY_YES=$(DEPLOY_YES) scripts/deploy.sh gateway $(if $(DEPLOY_YES),--yes,)

deploy-control:
	DEPLOY_YES=$(DEPLOY_YES) scripts/deploy.sh control $(if $(DEPLOY_YES),--yes,)

deploy-service-x:
	DEPLOY_YES=$(DEPLOY_YES) scripts/deploy.sh service-x $(if $(DEPLOY_YES),--yes,)

# Backwards-compatible aliases
redeploy-full: deploy-full
redeploy-gateway: deploy-gateway
redeploy-control: deploy-control
redeploy-service-x: deploy-service-x

ui-install:
	python3 -m venv $(UI_VENV)
	$(UI_PY) -m pip install --upgrade pip
	$(UI_PY) -m pip install -q -r ui/requirements.txt

ui:
	@pid="$$(lsof -ti tcp:$(UI_PORT) -sTCP:LISTEN 2>/dev/null || true)"; \
	if [ -n "$$pid" ]; then \
	  cmd="$$(ps -p $$pid -o cmd= 2>/dev/null || true)"; \
	  case "$$cmd" in \
	    *"$(UI_CMD_MATCH)"*) \
	      echo "Blueprint UI is already running on http://localhost:$(UI_PORT) (pid $$pid)"; \
	      echo "Use 'make ui-stop' to stop it first if you want to restart it."; \
	      exit 0; \
	      ;; \
	    *) \
	      echo "Port $(UI_PORT) is already in use by: $$cmd" >&2; \
	      echo "Free the port or stop that process before running 'make ui'." >&2; \
	      exit 1; \
	      ;; \
	  esac; \
	fi; \
	echo "Starting Blueprint UI on http://localhost:$(UI_PORT) — press Ctrl-C to stop"; \
	if [ ! -x "$(UI_PY)" ]; then \
	  echo "UI virtualenv not found. Run 'make ui-install' first." >&2; \
	  exit 1; \
	fi; \
	cd ui && ../$(UI_PY) -m uvicorn server:app --host 0.0.0.0 --port $(UI_PORT) --timeout-graceful-shutdown 1

ui-stop:
	@pid="$$(lsof -ti tcp:$(UI_PORT) -sTCP:LISTEN 2>/dev/null || true)"; \
	if [ -z "$$pid" ]; then \
	  echo "No process found on port $(UI_PORT)"; \
	  exit 0; \
	fi; \
	cmd="$$(ps -p $$pid -o cmd= 2>/dev/null || true)"; \
	case "$$cmd" in \
	  *"$(UI_CMD_MATCH)"*) \
	    kill -INT $$pid 2>/dev/null && echo "UI stopped" || { echo "Failed to stop UI" >&2; exit 1; }; \
	    ;; \
	  *) \
	    echo "Port $(UI_PORT) is owned by a non-Blueprint process: $$cmd" >&2; \
	    echo "Refusing to stop it via 'make ui-stop'." >&2; \
	    exit 1; \
	    ;; \
	esac

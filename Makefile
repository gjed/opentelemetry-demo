# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


# All documents to be used in spell check.
ALL_DOCS := $(shell find . -type f -name '*.md' -not -path './.github/*' -not -path './.opencode/*' -not -path '*/node_modules/*' -not -path '*/_build/*' -not -path '*/deps/*' -not -path */Pods/* -not -path */.expo/* | sort)
PWD := $(shell pwd)

TOOLS_DIR := ./internal/tools
MISSPELL_BINARY=bin/misspell
MISSPELL = $(TOOLS_DIR)/$(MISSPELL_BINARY)
ADDLICENSE_BINARY=bin/addlicense
ADDLICENSE = $(TOOLS_DIR)/$(ADDLICENSE_BINARY)

DOCKER_CMD ?= docker
DOCKER_COMPOSE_CMD ?= docker compose
DOCKER_COMPOSE_ENV=--env-file .env --env-file .env.override

# Compose file layers — combine with -f flags for the desired configuration:
#   Core (minimal):             compose.yaml
#   Full (adds Kafka group):    compose.yaml + compose.full.yaml
#   With observability stack:   + compose.observability.yaml
#   With extras customizations: + compose.extras.yaml (always last)
DOCKER_COMPOSE_FILES_CORE=-f compose.yaml
DOCKER_COMPOSE_FILES_FULL=$(DOCKER_COMPOSE_FILES_CORE) -f compose.full.yaml
DOCKER_COMPOSE_FILES_OBSERVABILITY=-f compose.observability.yaml
DOCKER_COMPOSE_FILES_PROFILING=-f compose.profiling.yaml
DOCKER_COMPOSE_FILES_EXTRAS=-f compose.extras.yaml
DOCKER_COMPOSE_FILES_TESTS=-f compose.tests.yaml
DOCKER_COMPOSE_FILES_AGENT=-f compose.agent.yaml

# Default: full demo + observability stack + extras stub
DOCKER_COMPOSE_FILES=$(DOCKER_COMPOSE_FILES_FULL) $(DOCKER_COMPOSE_FILES_OBSERVABILITY) $(DOCKER_COMPOSE_FILES_EXTRAS)

# Accept either `service=` or `SERVICE=` for single-service targets (build, restart, redeploy).
# Must be evaluated at file scope; an `ifdef SERVICE` block inside a recipe is a shell command,
# not a Make conditional, so the alias never takes effect there.
ifdef SERVICE
service := $(SERVICE)
endif


# see https://github.com/open-telemetry/build-tools/releases for semconvgen updates
# Keep links in semantic_conventions/README.md and .vscode/settings.json in sync!
SEMCONVGEN_VERSION=0.11.0
YAMLLINT_VERSION=1.30.0

# Changelog fragment tooling (chloggen). Pinned to match the OpenTelemetry
# Collector. Invoked from the repo root, which has no go.mod, so `go run` runs
# the pinned tool without touching any local Go module.
CHLOGGEN_VERSION=0.30.0
CHLOGGEN_CONFIG=.chloggen/config.yaml
CHLOGGEN=go run go.opentelemetry.io/build-tools/chloggen@v$(CHLOGGEN_VERSION)
# Default changelog fragment filename is derived from the current branch name.
FILENAME?=$(shell git branch --show-current | sed 's/[^a-zA-Z0-9]/_/g')

.PHONY: all
all: install-tools markdownlint misspell yamllint

$(MISSPELL):
	cd $(TOOLS_DIR) && go build -o $(MISSPELL_BINARY) github.com/client9/misspell/cmd/misspell

$(ADDLICENSE):
	cd $(TOOLS_DIR) && go build -o $(ADDLICENSE_BINARY) github.com/google/addlicense

.PHONY: misspell
misspell:	$(MISSPELL)
	$(MISSPELL) -error $(ALL_DOCS)

.PHONY: misspell-correction
misspell-correction:	$(MISSPELL)
	$(MISSPELL) -w $(ALL_DOCS)

.PHONY: markdownlint
markdownlint:
	@if ! npm ls markdownlint; then npm install; fi
	@for f in $(ALL_DOCS); do \
		echo $$f; \
		npx --no -p markdownlint-cli markdownlint -c .markdownlint.yaml $$f \
			|| exit 1; \
	done

.PHONY: install-yamllint
install-yamllint:
    # Using a venv is recommended
	yamllint --version >/dev/null 2>&1 || pip install -U yamllint~=$(YAMLLINT_VERSION)

.PHONY: yamllint
yamllint: install-yamllint
	yamllint .

.PHONY: checklicense
checklicense:	$(ADDLICENSE)
	@echo "Checking license headers..."
	$(ADDLICENSE) -check -c "The OpenTelemetry Authors" -l apache -s=only -y "" \
		-ignore node_modules/** \
		-ignore .expo/** \
		-ignore Pods/** \
		-ignore ".chloggen/**" \
		-ignore ".opencode/**" \
		-ignore "openspec/**" \
		-ignore **/extras/** \
		-ignore **/vendor/** \
		-ignore **/.venv/** \
		-ignore **/dist/** \
		-ignore **/build/** \
		-ignore **/*_pb2.py \
		-ignore **/*_pb2_grpc.py \
		-ignore **/genproto/** \
		-ignore **/protos/*.ts \
		.

.PHONY: addlicense
addlicense:	$(ADDLICENSE)
	@echo "Adding license headers..."
	$(ADDLICENSE) -c "The OpenTelemetry Authors" -l apache -s=only -y "" \
		-ignore node_modules/** \
		-ignore .expo/** \
		-ignore Pods/** \
		-ignore ".chloggen/**" \
		-ignore **/extras/** \
		-ignore **/vendor/** \
		-ignore **/.venv/** \
		-ignore **/dist/** \
		-ignore **/build/** \
		-ignore **/*_pb2.py \
		-ignore **/*_pb2_grpc.py \
		-ignore **/genproto/** \
		-ignore **/protos/*.ts \
		.

.PHONY: checklinks
checklinks:
	@echo "Checking links..."
	lychee --config .lychee.toml --cache .

# Run all checks in order of speed / likely failure.
.PHONY: check
check: misspell markdownlint checklicense checklinks chlog-validate
	@echo "All checks complete"

# Attempt to fix issues / regenerate tables.
.PHONY: fix
fix: misspell-correction
	@echo "All autofixes complete"

# Changelog fragments (chloggen). See CONTRIBUTING.md for the workflow.
# Create a new fragment for the current branch (edit the generated file after):
#   make chlog-new
.PHONY: chlog-new
chlog-new:
	$(CHLOGGEN) new --config $(CHLOGGEN_CONFIG) --filename $(FILENAME)

# Validate that every fragment in .chloggen/ is well-formed. Run in CI.
.PHONY: chlog-validate
chlog-validate:
	$(CHLOGGEN) validate --config $(CHLOGGEN_CONFIG)

# Preview the CHANGELOG.md that the current fragments would produce.
.PHONY: chlog-preview
chlog-preview:
	$(CHLOGGEN) update --config $(CHLOGGEN_CONFIG) --dry

# Fold all fragments into CHANGELOG.md under the given version and delete them.
# Run during the release process:
#   make chlog-update VERSION=1.13.0
.PHONY: chlog-update
chlog-update:
	$(CHLOGGEN) update --config $(CHLOGGEN_CONFIG) --version $(VERSION)

.PHONY: install-tools
install-tools: $(MISSPELL) $(ADDLICENSE)
	npm install
	@echo "All tools installed"

# Use to build all services, or a single service component
# Example: make build service=frontend
.PHONY: build
build:
ifneq ($(strip $(service)),)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) build $(service)
else
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) build
endif

# Build all services including the agentic layer (agent, mcp, chatbot).
# Used by the agentic CI workflow so those images are present when
# make run-telemetry-tests-agentic loads them from the artifact.
.PHONY: build-agentic
build-agentic:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) $(DOCKER_COMPOSE_FILES_AGENT) build

.PHONY: build-and-push
build-and-push:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) build --push

# Create multiplatform builder for buildx
.PHONY: create-multiplatform-builder
create-multiplatform-builder:
	docker buildx create --name otel-demo-builder --bootstrap --use --driver docker-container --config ./buildkitd.toml

# Remove multiplatform builder for buildx
.PHONY: remove-multiplatform-builder
remove-multiplatform-builder:
	docker buildx rm otel-demo-builder

# Build and push multiplatform images (linux/amd64, linux/arm64) using buildx.
# Requires docker with buildx enabled and a multi-platform capable builder in use.
# Docker needs to be configured to use containerd storage for images to be loaded into the local registry.
.PHONY: build-multiplatform
build-multiplatform:
	# Because buildx bake does not support --env-file yet, we need to load it into the environment first.
	set -a; . ./.env.override; set +a && docker buildx bake $(DOCKER_COMPOSE_FILES) --load --set "*.platform=linux/amd64,linux/arm64"

.PHONY: build-multiplatform-and-push
build-multiplatform-and-push:
	# Because buildx bake does not support --env-file yet, we need to load it into the environment first.
	set -a; . ./.env.override; set +a && docker buildx bake $(DOCKER_COMPOSE_FILES) --push --set "*.platform=linux/amd64,linux/arm64"

.PHONY: clean-images
clean-images:
	$(DOCKER_CMD) rmi $(shell $(DOCKER_CMD) images --filter=reference="ghcr.io/open-telemetry/demo:latest-*" -q); \
    if [ $$? -ne 0 ]; \
    then \
    	echo; \
        echo "Failed to removed 1 or more OpenTelemetry Demo images."; \
        echo "Check to ensure the Demo is not running by executing: make stop"; \
        false; \
    fi

.PHONY: run-frontend-tests
run-frontend-tests:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) $(DOCKER_COMPOSE_FILES_TESTS) run frontendTests

.PHONY: run-telemetry-tests
run-telemetry-tests: start
	$(DOCKER_CMD) build -t opentelemetry-demo-telemetry-tests ./test/telemetry
	@touch .env.override
	@# Capture test exit code, always tear down the demo, then propagate the code.
	@set +e; \
	$(DOCKER_CMD) run --rm --network opentelemetry-demo \
		--env-file .env --env-file .env.override \
		-e TEST_SCOPE=full \
		-e WARMUP_SECONDS=$${WARMUP_SECONDS:-240} \
		-e POLL_TIMEOUT=$${POLL_TIMEOUT:-180} \
		-e WARMUP_PROBE_ENABLED=$${WARMUP_PROBE_ENABLED:-true} \
		-e WARMUP_PROBE_CHECKOUTS=$${WARMUP_PROBE_CHECKOUTS:-5} \
		-e WARMUP_PROBE_TIMEOUT=$${WARMUP_PROBE_TIMEOUT:-120} \
		opentelemetry-demo-telemetry-tests; \
	rc=$$?; \
	$(MAKE) stop; \
	exit $$rc

.PHONY: run-telemetry-tests-minimal
run-telemetry-tests-minimal: start-minimal
	$(DOCKER_CMD) build -t opentelemetry-demo-telemetry-tests ./test/telemetry
	@touch .env.override
	@set +e; \
	$(DOCKER_CMD) run --rm --network opentelemetry-demo \
		--env-file .env --env-file .env.override \
		-e TEST_SCOPE=minimal \
		-e WARMUP_SECONDS=$${WARMUP_SECONDS:-240} \
		-e POLL_TIMEOUT=$${POLL_TIMEOUT:-180} \
		-e WARMUP_PROBE_ENABLED=$${WARMUP_PROBE_ENABLED:-true} \
		-e WARMUP_PROBE_CHECKOUTS=$${WARMUP_PROBE_CHECKOUTS:-5} \
		-e WARMUP_PROBE_TIMEOUT=$${WARMUP_PROBE_TIMEOUT:-120} \
		opentelemetry-demo-telemetry-tests; \
	rc=$$?; \
	$(MAKE) stop; \
	exit $$rc

.PHONY: run-telemetry-tests-agentic
run-telemetry-tests-agentic:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) $(DOCKER_COMPOSE_FILES_AGENT) up --force-recreate --remove-orphans --detach
	$(DOCKER_CMD) build -t opentelemetry-demo-telemetry-tests ./test/telemetry
	@touch .env.override
	@set +e; \
	$(DOCKER_CMD) run --rm --network opentelemetry-demo \
		--env-file .env --env-file .env.override \
		-e TEST_SCOPE=agentic \
		-e WARMUP_SECONDS=$${WARMUP_SECONDS:-240} \
		-e POLL_TIMEOUT=$${POLL_TIMEOUT:-180} \
		-e WARMUP_PROBE_ENABLED=false \
		-e WARMUP_PROBE_CHECKOUTS=0 \
		-e WARMUP_PROBE_TIMEOUT=$${WARMUP_PROBE_TIMEOUT:-120} \
		opentelemetry-demo-telemetry-tests; \
	rc=$$?; \
	$(MAKE) stop; \
	exit $$rc

.PHONY: generate-protobuf
generate-protobuf:
	./ide-gen-proto.sh

.PHONY: docker-generate-protobuf
docker-generate-protobuf:
	./docker-gen-proto.sh

.PHONY: clean
clean:
	rm -rf ./src/{checkout,product-catalog}/genproto/oteldemo/
	rm -rf ./src/frontend/protos/demo.ts

.PHONY: check-clean-work-tree
check-clean-work-tree:
	@if ! git diff --quiet; then \
	  echo; \
	  echo 'Working tree is not clean, did you forget to run "make docker-generate-protobuf"?'; \
	  echo; \
	  git status; \
	  exit 1; \
	fi

.PHONY: start
start:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo is running."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/jaeger/ui for the Jaeger UI."
	@echo "Go to http://localhost:8080/grafana/ for the Grafana UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to http://localhost:8080/feature/ to change feature flags."
	@echo "Go to http://localhost:8080/telemetry/ for the Weaver generated telemetry documentation."

.PHONY: start-minimal
start-minimal:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES_CORE) $(DOCKER_COMPOSE_FILES_OBSERVABILITY) $(DOCKER_COMPOSE_FILES_EXTRAS) up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo in minimal mode is running."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/jaeger/ui for the Jaeger UI."
	@echo "Go to http://localhost:8080/grafana/ for the Grafana UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to http://localhost:8080/feature/ to change feature flags."
	@echo "Go to http://localhost:8080/telemetry/ for the Weaver generated telemetry documentation."

.PHONY: start-no-o11y
start-no-o11y:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES_FULL) $(DOCKER_COMPOSE_FILES_EXTRAS) up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo is running (no observability stack)."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to http://localhost:8080/feature/ to change feature flags."
	@echo "Go to http://localhost:8080/telemetry/ for the Weaver generated telemetry documentation."

.PHONY: start-minimal-no-o11y
start-minimal-no-o11y:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES_CORE) $(DOCKER_COMPOSE_FILES_EXTRAS) up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo in minimal mode is running (no observability stack)."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to http://localhost:8080/feature/ to change feature flags."
	@echo "Go to http://localhost:8080/telemetry/ for the Weaver generated telemetry documentation."

.PHONY: start-profiling
start-profiling:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES_FULL) $(DOCKER_COMPOSE_FILES_OBSERVABILITY) $(DOCKER_COMPOSE_FILES_PROFILING) $(DOCKER_COMPOSE_FILES_EXTRAS) up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo in profiling mode is running."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/jaeger/ui for the Jaeger UI."
	@echo "Go to http://localhost:8080/grafana/ for the Grafana UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to http://localhost:8080/profiles/ for the Firepit UI."
	@echo "Go to http://localhost:8080/telemetry/ for the Weaver generated telemetry documentation."

.PHONY: start-agentic
start-agentic:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) $(DOCKER_COMPOSE_FILES_AGENT) up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo with the agent, mcp and chatbot is running."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/jaeger/ui for the Jaeger UI."
	@echo "Go to http://localhost:8080/grafana/ for the Grafana UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to http://localhost:8080/feature/ to change feature flags."
	@echo "Go to http://localhost:8080/telemetry/ for the Weaver generated telemetry documentation."
	@echo "Go to http://localhost:8080/chatbot/ for interacting with demo application using an agent."

.PHONY: stop
stop:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) down --remove-orphans --volumes
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) $(DOCKER_COMPOSE_FILES_AGENT) down --remove-orphans --volumes
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) $(DOCKER_COMPOSE_FILES_PROFILING) down --remove-orphans --volumes
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) $(DOCKER_COMPOSE_FILES_TESTS) down --remove-orphans --volumes
	@echo ""
	@echo "OpenTelemetry Demo is stopped."

# Use to restart a single service component
# Example: make restart service=frontend
.PHONY: restart
restart:
ifneq ($(strip $(service)),)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) stop $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) rm --force $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) create $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) start $(service)
else
	@echo "Please provide a service name using 'service=<name>' or 'SERVICE=<name>'"
endif

# Use to rebuild and restart (redeploy) a single service component
# Example: make redeploy service=frontend
.PHONY: redeploy
redeploy:
ifneq ($(strip $(service)),)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) build $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) stop $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) rm --force $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) create $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(DOCKER_COMPOSE_FILES) start $(service)
else
	@echo "Please provide a service name using 'service=<name>' or 'SERVICE=<name>'"
endif

.PHONY: build-react-native-android
build-react-native-android:
	$(DOCKER_CMD) build -f src/react-native-app/android.Dockerfile --platform=linux/amd64 --output=. src/react-native-app

# ──────────────────────────────────────────────────────────────────────
# Weaver Observability-by-Design demo targets
# See WEAVER-DEMO.md for the full walkthrough.
# ──────────────────────────────────────────────────────────────────────

WEAVER_COMPOSE=$(DOCKER_COMPOSE_FILES) -f docker-compose-weaver.yml

# Weaver CLI for codegen. Defaults to the pinned image so the generated
# artifacts match the live-check sidecar; set WEAVER=weaver to use a local binary.
WEAVER_IMAGE?=$(shell sed -n 's/^WEAVER_IMAGE=//p' .env)
WEAVER?=docker run --rm -u $(shell id -u):$(shell id -g) -v $(CURDIR):/work -w /work $(WEAVER_IMAGE)

# Generate Grafana dashboards and alert rules from the telemetry schema.
.PHONY: demo-generate
demo-generate:
	$(WEAVER) registry generate --registry telemetry-schema/ --templates weaver-templates --skip-policies -D variant=schema grafana

# Generate dashboard 02 ("after drift") from the schema with the FIX(drift)
# edits applied: the names the developer actually shipped. Works on a temp copy
# of the registry so telemetry-schema/ keeps the correct names. To do it by
# hand instead, apply the `# FIX(drift)` comments in telemetry-schema/ and run
# `make demo-generate`.
.PHONY: demo-generate-baseline
demo-generate-baseline:
	rm -rf output/baseline-registry && cp -r telemetry-schema output/baseline-registry
	sed -i -E 's/^(\s*(- )?(key|name|ref)): demo\.payment\.transactions$$/\1: app.payment.transactions/; s/^(\s*(- )?(key|ref)): demo\.payment\.currency$$/\1: currencyCode/; s/^(\s*(- )?(key|ref)): demo\.order\.amount$$/\1: orderAmount/; s/^(\s*(- )?(key|ref)): demo\.order\.items\.count$$/\1: orderItemsCount/' \
		output/baseline-registry/metrics/payment.yaml output/baseline-registry/attributes/order.yaml output/baseline-registry/services/checkout.yaml
	$(WEAVER) registry generate --registry output/baseline-registry/ --templates weaver-templates --skip-policies -D variant=baseline grafana output/baseline

# Copy generated artifacts from output/ to the Grafana provisioning directories.
# Uses cp --update to avoid clobbering unchanged files; never deletes existing
# non-generated files (alerts, dashboards placed by other means are safe).
.PHONY: demo-provision
demo-provision:
	cp -v --update output/weaver-demo-dashboard.json src/grafana/provisioning/dashboards/weaver/weaver-demo-dashboard-02-schema.json
	cp -v --update output/weaver-demo-alerting.yml src/grafana/provisioning/alerting/weaver-demo-alerting-02-schema.yml
	cp -v --update output/weaver-apm-dashboard.json src/grafana/provisioning/dashboards/weaver/weaver-apm-dashboard.json
	cp -v --update output/weaver-comparison-dashboard.json src/grafana/provisioning/dashboards/weaver/weaver-comparison-dashboard.json
	[ -f output/baseline/weaver-demo-dashboard.json ] && cp -v --update output/baseline/weaver-demo-dashboard.json src/grafana/provisioning/dashboards/weaver/weaver-demo-dashboard-01-baseline.json || true
	[ -f output/baseline/weaver-demo-alerting.yml ] && cp -v --update output/baseline/weaver-demo-alerting.yml src/grafana/provisioning/alerting/weaver-demo-alerting-01-baseline.yml || true
	@echo ""
	@echo "Generated artifacts copied to Grafana provisioning directories."

# Remove generated Weaver artifacts (output dir + provisioned copies).
.PHONY: demo-clean
demo-clean:
	rm -rf output/
	@echo "Generated artifacts removed (output/). Provisioned copies in src/grafana/provisioning/ are kept."

# Validate the telemetry schema is well-formed.
.PHONY: demo-check
demo-check:
	$(WEAVER) registry check --registry telemetry-schema/

# Registry statistics: groups, attributes, metrics (custom + semconv dependency).
.PHONY: demo-stats
demo-stats:
	$(WEAVER) registry stats --registry telemetry-schema/


# Start the demo with the Weaver live-check sidecar (idempotent — no-op if already running).
.PHONY: demo-start
demo-start:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(WEAVER_COMPOSE) up --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo with Weaver live-check is running."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/grafana/ for the Grafana UI."
	@echo "Go to http://localhost:8080/feature/ to toggle telemetrySchemaBreak."
	@echo "Run 'make demo-logs' to see Weaver live-check output."
	@echo "See WEAVER-DEMO.md for the full walkthrough."

# Restart the demo from scratch (force-recreates all containers).
.PHONY: demo-restart
demo-restart:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(WEAVER_COMPOSE) up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo with Weaver live-check has been restarted."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/grafana/ for the Grafana UI."
	@echo "Go to http://localhost:8080/feature/ to toggle telemetrySchemaBreak."
	@echo "Run 'make demo-logs' to see Weaver live-check output."
	@echo "See WEAVER-DEMO.md for the full walkthrough."

# Stop the demo (including Weaver sidecar).
.PHONY: demo-stop
demo-stop:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(WEAVER_COMPOSE) down --remove-orphans --volumes
	@echo ""
	@echo "Weaver demo is stopped."

# Tail Weaver live-check logs.
.PHONY: demo-logs
demo-logs:
	$(DOCKER_COMPOSE_CMD) $(WEAVER_COMPOSE) logs -f weaver

# Live-check findings of the last 60s: one line per (telemetry item, violation),
# with how many samples showed it. The full per-sample report is 'make demo-logs'.
.PHONY: demo-livecheck
demo-livecheck:
	@$(DOCKER_CMD) logs --since 60s weaver 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' \
		| awk '/^(Metric|Span) /{h=$$1" "$$2} /\[violation\]/{sub(/^ *- \[violation\] /,""); print h": "$$0}' \
		| sort | uniq -c | sort -k2,2 -k1,1rn | sed -E 's/^ *([0-9]+) /\1x  /'

# Build the services this fork changes (telemetrySchemaBreak flag in payment
# and checkout, metric name fix in currency). `make demo-start` pulls upstream
# images otherwise, which have none of it. Run once before the demo.
.PHONY: demo-build
demo-build:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) build payment checkout currency

# Build only the payment service (useful after modifying charge.js).
.PHONY: demo-build-payment
demo-build-payment:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) build payment

# Restart payment after flipping telemetrySchemaBreak (simulates a deploy).
.PHONY: demo-restart-payment
demo-restart-payment:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) $(WEAVER_COMPOSE) restart payment

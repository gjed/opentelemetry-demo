# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0


# All documents to be used in spell check.
ALL_DOCS := $(shell find . -type f -name '*.md' -not -path './.github/*' -not -path '*/node_modules/*' -not -path '*/_build/*' -not -path '*/deps/*' -not -path */Pods/* -not -path */.expo/* | sort)
PWD := $(shell pwd)

TOOLS_DIR := ./internal/tools
MISSPELL_BINARY=bin/misspell
MISSPELL = $(TOOLS_DIR)/$(MISSPELL_BINARY)
ADDLICENSE_BINARY=bin/addlicense
ADDLICENSE = $(TOOLS_DIR)/$(ADDLICENSE_BINARY)

DOCKER_CMD ?= docker
DOCKER_COMPOSE_CMD ?= docker compose
DOCKER_COMPOSE_ENV=--env-file .env --env-file .env.override

# see https://github.com/open-telemetry/build-tools/releases for semconvgen updates
# Keep links in semantic_conventions/README.md and .vscode/settings.json in sync!
SEMCONVGEN_VERSION=0.11.0
YAMLLINT_VERSION=1.30.0

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
check: misspell markdownlint checklicense checklinks
	@echo "All checks complete"

# Attempt to fix issues / regenerate tables.
.PHONY: fix
fix: misspell-correction
	@echo "All autofixes complete"

.PHONY: install-tools
install-tools: $(MISSPELL) $(ADDLICENSE)
	npm install
	@echo "All tools installed"

.PHONY: build
build:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) build

.PHONY: build-and-push
build-and-push:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) build --push

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
	set -a; . ./.env.override; set +a && docker buildx bake -f docker-compose.yml --load --set "*.platform=linux/amd64,linux/arm64"

.PHONY: build-multiplatform-and-push
build-multiplatform-and-push:
    # Because buildx bake does not support --env-file yet, we need to load it into the environment first.
	set -a; . ./.env.override; set +a && docker buildx bake -f docker-compose.yml --push --set "*.platform=linux/amd64,linux/arm64"

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

.PHONY: run-tests
run-tests:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose-tests.yml run frontendTests
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose-tests.yml run traceBasedTests

.PHONY: run-tracetesting
run-tracetesting:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose-tests.yml run traceBasedTests ${SERVICES_TO_TEST}

.PHONY: generate-protobuf
generate-protobuf:
	./ide-gen-proto.sh

.PHONY: docker-generate-protobuf
docker-generate-protobuf:
	./docker-gen-proto.sh

.PHONY: clean
clean:
	rm -rf ./src/{checkout,product-catalog}/genproto/oteldemo/
	rm -rf ./src/recommendation/{demo_pb2,demo_pb2_grpc}.py
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
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) up --force-recreate --remove-orphans --detach
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
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose.minimal.yml up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo in minimal mode is running."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/jaeger/ui for the Jaeger UI."
	@echo "Go to http://localhost:8080/grafana/ for the Grafana UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to https://opentelemetry.io/docs/demo/feature-flags/ to learn how to change feature flags."

.PHONY: stop
stop:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) down --remove-orphans --volumes
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose-tests.yml down --remove-orphans --volumes
	@echo ""
	@echo "OpenTelemetry Demo is stopped."

# Use to restart a single service component
# Example: make restart service=frontend
.PHONY: restart
restart:
# work with `service` or `SERVICE` as input
ifdef SERVICE
	service := $(SERVICE)
endif

ifdef service
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) stop $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) rm --force $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) create $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) start $(service)
else
	@echo "Please provide a service name using `service=[service name]` or `SERVICE=[service name]`"
endif

# Use to rebuild and restart (redeploy) a single service component
# Example: make redeploy service=frontend
.PHONY: redeploy
redeploy:
# work with `service` or `SERVICE` as input
ifdef SERVICE
	service := $(SERVICE)
endif

ifdef service
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) build $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) stop $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) rm --force $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) create $(service)
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) start $(service)
else
	@echo "Please provide a service name using `service=[service name]` or `SERVICE=[service name]`"
endif

.PHONY: build-react-native-android
build-react-native-android:
	$(DOCKER_CMD) build -f src/react-native-app/android.Dockerfile --platform=linux/amd64 --output=. src/react-native-app

.PHONY: start-profiling
start-profiling:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) -f docker-compose.yml -f compose-profiling.yml up --force-recreate --remove-orphans --detach
	@echo ""
	@echo "OpenTelemetry Demo in profiling mode is running."
	@echo "Go to http://localhost:8080 for the demo UI."
	@echo "Go to http://localhost:8080/jaeger/ui for the Jaeger UI."
	@echo "Go to http://localhost:8080/grafana/ for the Grafana UI."
	@echo "Go to http://localhost:8080/loadgen/ for the Load Generator UI."
	@echo "Go to http://localhost:8080/profiles/ for the Firepit UI."
	@echo "Go to http://localhost:8080/telemetry/ for the Weaver generated telemetry documentation."
	@echo "Go to https://opentelemetry.io/docs/demo/feature-flags/ to learn how to change feature flags."

# ──────────────────────────────────────────────────────────────────────
# Weaver Observability-by-Design demo targets
# See WEAVER-DEMO.md for the full walkthrough.
# ──────────────────────────────────────────────────────────────────────

WEAVER_COMPOSE=-f docker-compose.yml -f docker-compose-weaver.yml

# Generate Grafana dashboard and alert rule from the telemetry schema.
.PHONY: demo-generate
demo-generate:
	weaver registry generate --registry telemetry-schema/ --templates weaver-templates --skip-policies --include-unreferenced grafana

# Copy generated artifacts from output/ to the Grafana provisioning directories.
# Uses cp --update to avoid clobbering unchanged files; never deletes existing
# non-generated files (alerts, dashboards placed by other means are safe).
.PHONY: demo-provision
demo-provision:
	cp -v --update output/weaver-apm-dashboard.json src/grafana/provisioning/dashboards/weaver/weaver-apm-dashboard.json
	cp -v --update output/weaver-comparison-dashboard.json src/grafana/provisioning/dashboards/weaver/weaver-comparison-dashboard.json
	cp -v --update output/weaver-comparison-alerting.yml src/grafana/provisioning/alerting/weaver-comparison-alerting.yml
	@echo ""
	@echo "Generated artifacts copied to Grafana provisioning directories."

# Remove generated Weaver artifacts (output dir + provisioned copies).
.PHONY: demo-clean
demo-clean:
	rm -rf output/
	rm -f src/grafana/provisioning/dashboards/weaver/weaver-apm-dashboard.json
	rm -f src/grafana/provisioning/dashboards/weaver/weaver-comparison-dashboard.json
	rm -f src/grafana/provisioning/alerting/weaver-comparison-alerting.yml
	@echo "Generated artifacts removed."

# Validate the telemetry schema is well-formed.
.PHONY: demo-check
demo-check:
	weaver registry check --registry telemetry-schema/

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

# Send /stop to the Weaver sidecar and follow the logs until it exits.
# NOTE: This stops the Weaver container — run 'make demo-start' to restart it.
.PHONY: demo-livecheck
demo-livecheck:
	@curl -sf -X POST http://localhost:4320/stop || { echo "ERROR: Could not reach Weaver admin port (is the demo running?). Try 'make demo-start' first."; exit 1; }
	@$(DOCKER_CMD) logs -f weaver

# Build only the payment service (useful after modifying charge.js).
.PHONY: demo-build-payment
demo-build-payment:
	$(DOCKER_COMPOSE_CMD) $(DOCKER_COMPOSE_ENV) build payment

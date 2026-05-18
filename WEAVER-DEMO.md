## Weaver Observability-by-Design Demo

This scenario demonstrates the full [OTel Weaver](https://github.com/open-telemetry/weaver)
Observability-by-Design lifecycle using the OpenTelemetry Demo. You generate
Grafana dashboards and alerts from a telemetry schema, validate live telemetry
with Weaver's live-check, then flip a feature flag to break instrumentation and
watch Weaver catch the drift in real time.

**Jump to:**
[Prerequisites](#prerequisites) · [Quick Start](#quick-start) · [Demo Walkthrough](#demo-walkthrough) · [How It Works](#how-it-works) · [What Weaver Caught](#what-weaver-caught--and-what-it-could-have) · [Key Files](#key-files) · [Troubleshooting](#troubleshooting)

______________________________________________________________________

## Prerequisites

- Docker and Docker Compose v2+
- ~8 GB RAM available for the full demo stack
- Ports 8080 (frontend proxy / Grafana) and 4320 (Weaver admin) available

## Quick Start

```bash
make demo-start
```

This starts the full OpenTelemetry Demo **plus** a Weaver sidecar that
live-checks all telemetry against the schema in `telemetry-schema/`.

Wait ~3 minutes for services to stabilize and metrics to populate.

### Make Targets

| Target                    | Description                                    |
| ------------------------- | ---------------------------------------------- |
| `make demo-start`         | Start the demo (idempotent, no-op if running)  |
| `make demo-restart`       | Restart the demo from scratch (force-recreate)  |
| `make demo-stop`          | Stop the demo (including Weaver)               |
| `make demo-logs`          | Tail Weaver live-check output                  |
| `make demo-generate`      | Regenerate dashboard and alert from the schema |
| `make demo-check`         | Validate the telemetry schema                  |
| `make demo-livecheck`     | Stop Weaver and print the live-check report    |
| `make demo-build-payment` | Rebuild the payment service after code changes |

## Demo Walkthrough

### Step 1 — See the Schema

Open `telemetry-schema/` and show the YAML definitions. This is the single
source of truth for every custom attribute and metric in the demo.

```
telemetry-schema/
├── attributes/   # Attribute definitions by business domain
├── metrics/      # Metric definitions per service
└── services/     # Service-specific attribute references
```

The payment service defines `app.payment.transactions` (a counter) with
attributes including `app.payment.currency`.

### Step 2 — See Generated Artifacts

Weaver codegen produced the dashboard and alert rule directly from the schema:

```bash
make demo-generate
```

The generated artifacts live at:

- **Dashboard**: `src/grafana/provisioning/dashboards/weaver/weaver-demo-dashboard.json`
- **Alert rule**: `src/grafana/provisioning/alerting/weaver-demo-alerting.yml`

These are already provisioned into Grafana. No hand-crafting needed — the schema
wrote them.

### Step 3 — Verify the Happy Path

1. Open Grafana: <http://localhost:8080/grafana>
1. Navigate to the **"Weaver - Observability by Design"** dashboard folder
1. Open the **Weaver Demo** dashboard
1. Confirm the **Payment Transactions Rate** panel shows live data
1. Check **Alerting** — the payment liveness alert shows Normal or Alerting
   (not NoData)

### Step 4 — Check Weaver Live-Check Conformance

```bash
make demo-logs
```

With the default configuration, Weaver reports no violations — the live
telemetry conforms to the schema.

### Step 5 — Break It

Enable the `telemetrySchemaBreak` feature flag:

1. Open the Feature Flag UI: <http://localhost:8080/feature>
1. Toggle **telemetrySchemaBreak** to **on**

This causes the payment service to:

- Rename `app.payment.transactions` → `app.payment.tx_count`
- Drop the `app.payment.currency` attribute

### Step 6 — Watch the Damage

Wait ~5 minutes for the 5-minute rate window to drain, then:

1. **Dashboard breaks** — the "Payment Transactions Rate" panel shows **No data**
1. **Alert breaks** — the payment liveness alert transitions to **NoData** state
1. **Weaver catches it** — check the logs:

```bash
make demo-logs
```

You see violation findings:

- Non-registry metric `app.payment.tx_count` detected
- Missing expected attribute `app.payment.currency`

### Step 7 — The Point

Without Weaver, this is a **silent failure**. Dashboards go blank, alerts stop
firing, and nobody knows why until an incident happens. With Weaver:

- **Live-check** catches the schema drift immediately
- **Codegen** ensures dashboards and alerts always match the schema
- The schema is the contract between instrumentation and observability tooling

## How It Works

```
┌─────────────────┐
│ telemetry-schema │──── weaver registry generate ───▶ dashboard.json
│   (YAML)        │                                    alerting.yml
└────────┬────────┘
         │
         │ mounted as /telemetry-schema
         ▼
┌─────────────────┐     OTLP fan-out      ┌──────────┐
│  OTel Collector  │ ──────────────────────▶│  Weaver  │
│                  │  otlp_grpc/weaver      │live-check│
└─────────────────┘  (metrics + traces)    └──────────┘
         ▲                                       │
         │                                  violations /
    OTLP from all                           conformance
    demo services                           findings
```

- The **OTel Collector** receives telemetry from all services as usual
- The weaver compose overlay adds a fan-out exporter (`otlp_grpc/weaver`) that
  copies metrics and traces to the Weaver sidecar
- **Weaver live-check** compares incoming telemetry against the mounted schema
  and reports violations
- The **feature flag** (`telemetrySchemaBreak`) introduces intentional drift in
  the payment service to demonstrate detection

## What Weaver Caught — and What It Could Have

The demo dashboards and alerts in `src/grafana/provisioning/` reveal a real-world
gap: several resources still reference outdated or misaligned metric names. An
audit of every dashboard and alert rule (excluding the APM Dashboard, which was
already updated) found two categories of drift.

### What is broken

**Spanmetrics Dashboard** (`spanmetrics-dashboard.json`) — every panel and both
template variables show errors. The entire dashboard is built on spanmetrics
connector output that is no longer being emitted:

| Panel                                            | Broken metric                                             |
| ------------------------------------------------ | --------------------------------------------------------- |
| Top 3x3 - Service Latency - quantile95           | `traces_span_metrics_duration_milliseconds_bucket`        |
| Top 7 Services Mean Rate over Range              | `traces_span_metrics_calls_total`                         |
| Top 7 Services Mean ERROR Rate over Range        | `traces_span_metrics_calls_total`                         |
| Top 7 span_names and Errors (APM Table)          | `traces_span_metrics_calls_total`                         |
| Top 3x3 - span_name Latency - quantile95         | `traces_span_metrics_duration_milliseconds_bucket`        |
| Top 7 Highest Endpoint Latencies Mean Over Range | `traces_span_metrics_duration_milliseconds_sum`, `_count` |
| Top 7 Latencies Over Range                       | `traces_span_metrics_duration_milliseconds_sum`, `_count` |
| Template variable `service`                      | sourced from `traces_span_metrics_calls_total`            |
| Template variable `span_name`                    | sourced from `traces_span_metrics_calls_total`            |

None of these metrics come from the OTel semantic conventions — they were
synthesized by the Collector's spanmetrics connector using its own naming
scheme and are no longer present.

The **Demo Dashboard** (`demo-dashboard.json`) also uses
`traces_span_metrics_*` metrics and legacy Python SDK runtime metrics
(`process_runtime_cpython_*`, `otel_trace_span_processor_spans`), but these
panels still render because the underlying data sources remain available. They
are not semconv-aligned but are not visibly broken today.

Everything else — the Exemplars, Linux, PostgreSQL, NGINX, and Collector
dashboards, plus all alert rules — uses either current semconv metrics or
infrastructure-specific metrics that are not subject to application-level semconv
changes.

### Why some APM panels work and others do not

The original **APM Dashboard** (`apm-dashboard.json`) queries both
`http_server_request_duration_seconds` (new HTTP semconv) and
`rpc_server_duration_milliseconds` (old RPC semconv). Whether a panel renders
depends on which OTel SDK each service uses — and different SDKs have migrated
to the new semconv metric names at different times.

The following data was verified by querying live Prometheus metrics. The
situation is worse than any single "old vs new" split — services emit **five
different metric names** across three naming conventions.

**`http_server_request_duration_seconds`** (new HTTP semconv, seconds):

| Service | Language  | SDK / Agent          |
| ------- | --------- | -------------------- |
| cart    | C# (.NET) | OTel .NET SDK 1.15.3 |

**`http_server_duration_milliseconds`** (old HTTP semconv, milliseconds):

| Service  | Language | SDK / Agent              |
| -------- | -------- | ------------------------ |
| frontend | Node.js  | OTel JS SDK-Node 0.217.0 |

**`http_server_duration_seconds`** (yet another variant, seconds):

| Service  | Language | SDK / Agent                      |
| -------- | -------- | -------------------------------- |
| shipping | Rust     | OTel Rust SDK 0.31.0 (actix-web) |

**`rpc_server_call_duration_seconds`** (new RPC semconv, seconds):

| Service         | Language | SDK / Agent     |
| --------------- | -------- | --------------- |
| checkout        | Go       | otelgrpc 0.68.0 |
| product-catalog | Go       | otelgrpc 0.68.0 |

**`rpc_server_duration_milliseconds`** (old RPC semconv, milliseconds):

| Service | Language | SDK / Agent       |
| ------- | -------- | ----------------- |
| ad      | Java     | Java Agent 2.25.0 |

**No server duration metrics emitted:**

| Service         | Reason                                                  |
| --------------- | ------------------------------------------------------- |
| payment         | Node.js gRPC — no server duration metrics in Prometheus |
| recommendation  | Python gRPC — no server duration metrics in Prometheus  |
| product-reviews | Python gRPC — no server duration metrics in Prometheus  |
| email           | Ruby HTTP — no server duration metrics in Prometheus    |
| quote           | PHP HTTP — no server duration metrics in Prometheus     |
| flagd-ui        | Elixir HTTP — no server duration metrics in Prometheus  |
| currency        | C++ — manual instrumentation only, no auto-metrics      |
| accounting      | Kafka consumer, no HTTP/gRPC server                     |
| fraud-detection | Kafka consumer, no HTTP/gRPC server                     |
| image-provider  | Nginx OTel module does tracing only, no metrics         |
| frontend-proxy  | Envoy native stats, not OTel SDK metrics                |
| llm             | No OTel instrumentation                                 |
| load-generator  | Client only (Locust)                                    |

**The result: neither APM dashboard covers all services.**

The **original APM Dashboard** (`apm-dashboard.json`) hardcodes
`http_server_request_duration_seconds` (new HTTP) and
`rpc_server_duration_milliseconds` (old RPC, with `/1000` divisor). This means:

- HTTP panels work for **cart** but not **frontend** (old naming) or
  **shipping** (different variant)
- RPC panels work for **ad** but not **checkout** or **product-catalog** (new
  naming)

The **Weaver-generated APM Dashboard** resolves `http.server.request.duration`
and `rpc.server.call.duration` from the semconv registry, producing the new
metric names. This means:

- HTTP panels work for **cart** only
- RPC panels work for **checkout** and **product-catalog** only

| Dashboard            | HTTP works for | HTTP broken for    | RPC works for             | RPC broken for            |
| -------------------- | -------------- | ------------------ | ------------------------- | ------------------------- |
| Original APM         | cart           | frontend, shipping | ad                        | checkout, product-catalog |
| Weaver-generated APM | cart           | frontend, shipping | checkout, product-catalog | ad                        |

This is exactly the kind of silent fragmentation that a schema-driven approach
prevents. Five different metric names for the same concept across six services
— because each OTel SDK implements the semconv migration on its own schedule.
If every SDK published a machine-readable registry declaring which metric names
it emits, the dashboard template could resolve the correct names at codegen
time instead of hardcoding assumptions.

### What Weaver already fixes

The **APM Dashboard Weaver template** (`apm-dashboard.json.j2`) resolves
canonical metric names from the semconv registry dependency declared in
`telemetry-schema/manifest.yaml`:

```yaml
dependencies:
  - name: otel
    registry_path: https://github.com/open-telemetry/semantic-conventions/archive/refs/tags/v1.40.0.zip[model]
```

At codegen time, the template looks up `http.server.request.duration`,
`rpc.server.call.duration`, and other semconv metrics, converts them to
Prometheus naming, and generates PromQL expressions that always match the
declared schema version. When the semconv version changes, re-running
`make demo-generate` produces dashboards with the correct metric names
automatically — no manual edits needed.

This replaces the RED metrics panels from both the Demo Dashboard and the
Spanmetrics Dashboard entirely.

### What Weaver could fix — if registries existed

The remaining broken metrics follow the same pattern: a component emits metrics,
but does not publish a machine-readable registry for them. If it did, the same
`dependencies` mechanism would catch drift at codegen time.

| Emitter                                  | Metrics                                                                | Registry exists?                                                       | Weaver would catch drift?               |
| ---------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------- |
| **OTel semconv**                         | `http.server.request.duration`, `rpc.server.call.duration`             | ✅ Yes                                                                 | ✅ Already working                      |
| **Application code**                     | `app.payment.transactions`, `app.cart.add_item.latency`                | ✅ Yes — `telemetry-schema/metrics/`                                   | ✅ Already working                      |
| **OTel SDK runtime metrics**             | `process.runtime.cpython.cpu_time`, `process.runtime.cpython.memory`   | ⚠️ Definitions exist in semconv but not as a clean standalone registry | ✅ Yes — if declared as a dependency    |
| **OTel SDK internal telemetry**          | `otel_trace_span_processor_spans`                                      | ❌ No published schema                                                 | ✅ Yes — if the SDK published one       |
| **OTel Collector spanmetrics connector** | `traces_span_metrics_duration_milliseconds_*`                          | ❌ Output names are per-config, no registry                            | ✅ Yes — if the connector published one |
| **OTel Collector internal telemetry**    | `otelcol_receiver_accepted_spans_total`, `otelcol_exporter_queue_size` | ❌ Documented in prose, no machine-readable registry                   | ✅ Yes — if the collector published one |

The principle is universal: **any component that emits metrics should publish a
machine-readable semconv registry for those metrics.** When it does, you declare
it as a dependency, Weaver resolves the correct names at codegen time, and
dashboards and alerts stay aligned across version upgrades automatically.

This is the end-to-end promise of Observability by Design — it works today for
application metrics and OTel semconv, and extends naturally to every telemetry
emitter in the pipeline as registries become available.

## Key Files

| File                                                                    | Purpose                                                                 |
| ----------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `telemetry-schema/`                                                     | Weaver-compatible YAML telemetry schema (attributes, metrics, services) |
| `weaver-templates/registry/grafana/`                                    | Jinja2 templates for codegen (dashboard + alerting)                     |
| `weaver-templates/registry/grafana/weaver.yaml`                         | Weaver codegen configuration                                            |
| `docker-compose-weaver.yml`                                             | Compose overlay adding the Weaver sidecar                               |
| `src/otel-collector/otelcol-config-weaver.yml`                          | Collector extras config for OTLP fan-out to Weaver                      |
| `src/grafana/provisioning/dashboards/weaver/weaver-demo-dashboard.json` | Generated Grafana dashboard                                             |
| `src/grafana/provisioning/alerting/weaver-demo-alerting.yml`            | Generated Grafana alert rule                                            |
| `src/grafana/provisioning/dashboards/weaver.yaml`                       | Grafana dashboard provisioning config                                   |
| `src/flagd/demo.flagd.json`                                             | Feature flags — includes `telemetrySchemaBreak`                         |
| `src/payment/charge.js`                                                 | Payment service — reads the flag, conditionally breaks telemetry        |
| `.env`                                                                  | Pins `WEAVER_IMAGE=otel/weaver:v0.23.0`                                 |

## Troubleshooting

### Weaver container exits immediately

Check that the `telemetry-schema/` directory is present and contains valid YAML:

```bash
make demo-check
```

### Dashboard shows "No data" even with flag OFF

Wait at least 3 minutes after startup for the load generator to produce payment
transactions. Verify metrics reach Prometheus:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=app_payment_transactions_total' | jq .
```

### Collector fails to start with the overlay

Ensure no other extras config conflicts. The overlay bind-mounts
`otelcol-config-weaver.yml` as `/etc/otelcol-config-extras.yml`, replacing any
existing extras config.

### Running without Weaver

The standard `docker compose up` (without `-f docker-compose-weaver.yml`) runs
the demo identically to upstream. The `telemetrySchemaBreak` flag defaults to
off, so the payment service behaves normally.

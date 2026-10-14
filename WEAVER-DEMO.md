# Weaver Observability-by-Design Demo

This scenario demonstrates the full [OTel Weaver](https://github.com/open-telemetry/weaver)
Observability-by-Design lifecycle using the OpenTelemetry Demo. You generate
Grafana dashboards and alerts from a telemetry schema, validate live telemetry
with Weaver's live-check, then flip a feature flag to break instrumentation and
watch Weaver catch the drift in real time.

**Jump to:**
[Prerequisites](#prerequisites) | [Quick Start](#quick-start) | [Demo Walkthrough](#demo-walkthrough) | [How It Works](#how-it-works) | [What Weaver Caught](#what-weaver-caught-and-what-it-could-have) | [Key Files](#key-files) | [Troubleshooting](#troubleshooting)

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

| Target                        | Description                                                                 |
| ----------------------------- | --------------------------------------------------------------------------- |
| `make demo-build`             | Build payment, checkout and currency from this fork (once, before the demo) |
| `make demo-start`             | Start the demo (idempotent, no-op if running)                               |
| `make demo-restart`           | Restart the demo from scratch (force-recreate)                              |
| `make demo-stop`              | Stop the demo (including Weaver)                                            |
| `make demo-check`             | Validate the telemetry schema                                               |
| `make demo-stats`             | Registry statistics (groups, attributes, metrics, incl. the semconv dependency) |
| `make demo-generate`          | Generate dashboard 02 and its alerts from `telemetry-schema/`               |
| `make demo-generate-baseline` | Generate dashboard 01 and its alerts from the schema with the legacy `paymentError` label (the dashboard the team wrote) |
| `make demo-provision`         | Copy generated artifacts into the Grafana provisioning dirs                 |
| `make demo-clean`             | Remove `output/` (the provisioned copies are kept)                          |
| `make demo-livecheck`         | Live-check findings of the last 10m, one line per item and violation        |
| `make demo-livecheck-raw`     | Raw live-check output of the last 10m; filter with `LIVECHECK_FILTER=rpc`   |
| `make demo-logs`              | Tail the full Weaver live-check output                                      |
| `make demo-build-payment`     | Rebuild the payment service after code changes                              |
| `make demo-restart-payment`   | Restart payment (needed after flipping the flag)                            |

## Demo Walkthrough

The `telemetrySchemaBreak` flag is **on by default**, together with
`paymentFailure` at 10%: about one payment in ten fails. The demo has no moving
parts: no flag flip, no restart, no Grafana reload. Everything is provisioned at
`make demo-start`, and the load generator keeps ~3 payments per second flowing.

The story: the payment service was fixed to follow the schema and records every
failure on `demo.payment.transactions` with the semconv attribute `error.type`.
The team's dashboard and alerts were written against the old label name
(`paymentError`), so they still show the payment rate and silently lost the error
rate. With the flag off the service emits `paymentError` again.

Checkout drifts the other way: it emits `orderAmount` and `orderItemsCount` on
the `PlaceOrder` span instead of `demo.order.amount` and `demo.order.items.count`.
Only live-check sees that one.

### Act 1 -- The schema

Open `telemetry-schema/` and show the YAML definitions. This is the single
source of truth for every custom attribute and metric in the demo:

```text
telemetry-schema/
+-- manifest.yaml  # registry id, semconv 1.44.0 as a dependency
+-- attributes/    # Attribute definitions by business domain
+-- metrics/       # Metric definitions per service
+-- services/      # Service-specific attribute references
```

`metrics/payment.yaml` declares `demo.payment.transactions` (counter) with the
required attribute `demo.payment.currency` and the conditionally required
semconv attribute `error.type` (set when the transaction failed). `make demo-stats` shows what the
registry resolves to once the semconv dependency is merged in.

### Act 2 -- Generate from the schema

```bash
make demo-generate   # weaver registry generate ... grafana
```

`weaver-templates/registry/grafana/*.j2` turn the registry into
`output/weaver-demo-dashboard.json` and `output/weaver-demo-alerting.yml`:
one panel per metric of the payment, cart and currency services, grouped by
the metric's attributes. Metrics with an error attribute get a second panel with
the error rate. The alerts are the ones a team would write by hand, with
thresholds taken from the metric annotations in the registry
(`alert_min_per_min`, `alert_max_error_pct`, `alert_max_p95_ms`):

- *Payment transaction counter: under 1 per minute*
- *Payment transaction counter: error rate over 2%*
- *Cart add item operation latency: p95 over 500 ms*
- *Cart retrieval operation latency: p95 over 500 ms*
- *Currency conversion counter: under 10 per minute*

Every alert is linked to the panel of its metric.

The same output is already provisioned as dashboard **02** (`make demo-provision`
copies it; `make demo-clean` removes `output/`).

### Act 3 -- The dashboard the team wrote

Open **01 - Baseline: the dashboard the team wrote**:
<http://localhost:8080/grafana/d/weaver-01-baseline>

Same template, generated from the schema with the error attribute under its old
name (`paymentError`, the `LEGACY(baseline)` block in `metrics/payment.yaml`).
The payment rate panel shows ~3 transactions per second in two currencies, cart
and currency have data, the **Schema alerts** column shows all five rules green.
The error rate panel reads **0%**, and the alert on it is green. Nothing here
says payments are failing.

### Act 4 -- The dashboard generated from the schema

Open **02 - Generated from the telemetry schema**:
<http://localhost:8080/grafana/d/weaver-02-schema>

Same panel titles, same alert titles, same thresholds. The payment rate panel is
identical, but the error rate panel queries `error.type` as declared in the
schema, and it reads **~10%**. *Payment transaction counter: error rate over 2%*
is red and linked to that panel. Cart and currency are identical to 01.

### Act 5 -- Live-check

```bash
make demo-livecheck
```

Weaver receives the payment and checkout telemetry (see *How It Works*) and
compares it with the registry. Payment is silent: it conforms to the schema,
which is exactly why dashboard 01 is the odd one out. Checkout is not:

```text
192x  Span oteldemo.CheckoutService/PlaceOrder: Attribute 'orderAmount' does not exist in the registry.
192x  Span oteldemo.CheckoutService/PlaceOrder: Attribute 'orderItemsCount' does not exist in the registry.
192x  Span oteldemo.CheckoutService/PlaceOrder: Attribute key 'orderAmount' does not match name formatting rules.
192x  Span oteldemo.CheckoutService/PlaceOrder: Attribute key 'orderItemsCount' does not match name formatting rules.
```

The rest of the list is deprecated semconv attributes (`rpc.system`,
`rpc.service`, `net.peer.name`, ...) still used by upstream instrumentation: a
second class of drift the registry catches for free.

### The point

Dashboards, alerts and live-check all came from one YAML. The dashboard the team
wrote (01) was correct on the day it was written and went blind when the label
changed: its alerts stay green while one payment in ten fails. The one generated
from the contract (02) shows the failures and pages on them, and Weaver names
the checkout attributes that left the registry.

To show the other direction (flag off, `make demo-restart-payment`): payment
goes back to `paymentError`, so within a minute 01 shows ~10% and goes red, and
02 reads 0%.

## How It Works

```text
+-----------------+
| telemetry-schema |---- weaver registry generate ---> dashboard.json
|   (YAML)        |                                    alerting.yml
+--------+--------+
         |
         | mounted as /telemetry-schema
         v
+-----------------+     OTLP fan-out      +----------+
|  OTel Collector  | ---------------------->|  Weaver  |
|                  |  otlp_grpc/weaver      |live-check|
+-----------------+  (metrics + traces)    +----------+
         ^                                       |
         |                                  violations /
     payment + checkout                      conformance
     demo services                           findings
```

- The **OTel Collector** receives telemetry from all services as usual
- The weaver compose overlay adds dedicated `traces/weaver` and
  `metrics/weaver` pipelines that copy only the payment and checkout telemetry
  to the Weaver sidecar (`filter/weaver`). Weaver live-check is single-threaded
  and prints a report per sample; fed the whole stack it falls behind, the
  exporter times out and the drift samples get dropped
- **Weaver live-check** compares incoming telemetry against the mounted schema
  and reports violations
- The **feature flag** (`telemetrySchemaBreak`) selects the name of the payment
  error attribute (`error.type` on, `paymentError` off) and makes checkout emit
  the drifted span attributes

## What Weaver Caught - and What It Could Have

The demo dashboards and alerts in `src/grafana/provisioning/` reveal a real-world
gap: several resources still reference outdated or misaligned metric names. An
audit of every dashboard and alert rule (excluding the APM Dashboard, which was
already updated) found two categories of drift.

### What is broken

**Spanmetrics Dashboard** (`spanmetrics-dashboard.json`)  -  every panel and both
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

None of these metrics come from the OTel semantic conventions  -  they were
synthesized by the Collector's spanmetrics connector using its own naming
scheme and are no longer present.

The **Demo Dashboard** (`demo-dashboard.json`) also uses
`traces_span_metrics_*` metrics and legacy Python SDK runtime metrics
(`process_runtime_cpython_*`, `otel_trace_span_processor_spans`), but these
panels still render because the underlying data sources remain available. They
are not semconv-aligned but are not visibly broken today.

Everything else  -  the Exemplars, Linux, PostgreSQL, NGINX, and Collector
dashboards, plus all alert rules  -  uses either current semconv metrics or
infrastructure-specific metrics that are not subject to application-level semconv
changes.

### Why some APM panels work and others do not

The original **APM Dashboard** (`apm-dashboard.json`) queries both
`http_server_request_duration_seconds` (new HTTP semconv) and
`rpc_server_duration_milliseconds` (old RPC semconv). Whether a panel renders
depends on which OTel SDK each service uses  -  and different SDKs have migrated
to the new semconv metric names at different times.

The following data was verified by querying live Prometheus metrics. The
situation is worse than any single "old vs new" split  -  services emit **five
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

| Service         | Reason                                                    |
| --------------- | --------------------------------------------------------- |
| payment         | Node.js gRPC: no server duration metrics in Prometheus   |
| recommendation  | Python gRPC: no server duration metrics in Prometheus    |
| product-reviews | Python gRPC: no server duration metrics in Prometheus    |
| email           | Ruby HTTP: no server duration metrics in Prometheus      |
| quote           | PHP HTTP: no server duration metrics in Prometheus       |
| flagd-ui        | Elixir HTTP: no server duration metrics in Prometheus    |
| currency        | C++: manual instrumentation only, no auto-metrics        |
| accounting      | Kafka consumer, no HTTP/gRPC server                       |
| fraud-detection | Kafka consumer, no HTTP/gRPC server                       |
| image-provider  | Nginx OTel module does tracing only, no metrics           |
| frontend-proxy  | Envoy native stats, not OTel SDK metrics                  |
| llm             | No OTel instrumentation                                   |
| load-generator  | Client only (Locust)                                      |

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
because each OTel SDK implements the semconv migration on its own schedule.
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
    registry_path: https://github.com/open-telemetry/semantic-conventions/archive/refs/tags/v1.44.0.zip[model]
```

At codegen time, the template looks up `http.server.request.duration`,
`rpc.server.call.duration`, and other semconv metrics, converts them to
Prometheus naming, and generates PromQL expressions that always match the
declared schema version. When the semconv version changes, re-running
`make demo-generate` produces dashboards with the correct metric names
automatically  -  no manual edits needed.

This replaces the RED metrics panels from both the Demo Dashboard and the
Spanmetrics Dashboard entirely.

### What Weaver could fix  -  if registries existed

The remaining broken metrics follow the same pattern: a component emits metrics,
but does not publish a machine-readable registry for them. If it did, the same
`dependencies` mechanism would catch drift at codegen time.

| Emitter                                  | Metrics                                                                | Registry exists?                                                       | Weaver would catch drift?                |
| ---------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------- |
| **OTel semconv**                         | `http.server.request.duration`, `rpc.server.call.duration`             | [YES] Yes                                                                | [YES] Already working                    |
| **Application code**                     | `demo.payment.transactions`, `demo.cart.add_item.latency`              | [YES] Yes: `telemetry-schema/metrics/`                                  | [YES] Already working                    |
| **OTel SDK runtime metrics**             | `process.runtime.cpython.cpu_time`, `process.runtime.cpython.memory`   | [WARNING] Definitions exist in semconv but not as a clean standalone registry | [YES] Yes: if declared as a dependency   |
| **OTel SDK internal telemetry**          | `otel_trace_span_processor_spans`                                      | [NO] No published schema                                                | [YES] Yes: if the SDK published one      |
| **OTel Collector spanmetrics connector** | `traces_span_metrics_duration_milliseconds_*`                          | [NO] Output names are per-config, no registry                           | [YES] Yes: if the connector published one |
| **OTel Collector internal telemetry**    | `otelcol_receiver_accepted_spans_total`, `otelcol_exporter_queue_size` | [NO] Documented in prose, no machine-readable registry                  | [YES] Yes: if the collector published one |

The principle is universal: **any component that emits metrics should publish a
machine-readable semconv registry for those metrics.** When it does, you declare
it as a dependency, Weaver resolves the correct names at codegen time, and
dashboards and alerts stay aligned across version upgrades automatically.

This is the end-to-end promise of Observability by Design: it works today for
application metrics and OTel semconv, and extends naturally to every telemetry
emitter in the pipeline as registries become available.

## Key Files

| File                                                                    | Purpose                                                                  |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `telemetry-schema/`                                                     | Weaver-compatible YAML telemetry schema (attributes, metrics, services)  |
| `weaver-templates/registry/grafana/`                                    | Jinja2 templates for codegen (dashboard + alerting)                      |
| `weaver-templates/registry/grafana/weaver.yaml`                         | Weaver codegen configuration                                             |
| `docker-compose-weaver.yml`                                             | Compose overlay adding the Weaver sidecar                                |
| `src/otel-collector/otelcol-config-weaver.yml`                          | Collector extras config for OTLP fan-out to Weaver                       |
| `src/grafana/provisioning/dashboards/weaver/weaver-demo-dashboard-0*.json` | Generated dashboards 01 (baseline) and 02 (schema)                   |
| `src/grafana/provisioning/alerting/weaver-demo-alerting-0*.yml`         | Generated alert rules, folders Weaver 01 / Weaver 02                     |
| `src/grafana/provisioning/dashboards/weaver.yaml`                       | Grafana dashboard provisioning config                                    |
| `src/flagd/demo.flagd.json`                                             | Feature flags: includes `telemetrySchemaBreak`                           |
| `src/payment/charge.js`                                                 | Payment service: reads the flag, conditionally breaks telemetry          |
| `.env`                                                                  | Pins `WEAVER_IMAGE=otel/weaver:v0.27.0`                                  |

## Troubleshooting

### Weaver container exits immediately

Check that the `telemetry-schema/` directory is present and contains valid YAML:

```bash
make demo-check
```

### Dashboard 01 shows flat zero lines or red alerts

Wait at least 2 minutes after startup for the load generator to produce
traffic. Any restart of the collector also starves every metric for ~20s and
trips all absence alerts; they clear within 30s. Verify samples reach
Prometheus:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=demo_payment_transactions_total' | jq .
```

### Collector fails to start with the overlay

Ensure no other extras config conflicts. The overlay bind-mounts
`otelcol-config-weaver.yml` as `/etc/otelcol-config-extras.yml`, replacing any
existing extras config.

### Running without Weaver

The standard `docker compose up` (without `-f docker-compose-weaver.yml`) runs
the demo identically to upstream. The `telemetrySchemaBreak` flag defaults to
off, so the payment service behaves normally.

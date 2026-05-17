## Weaver Observability-by-Design Demo

This scenario demonstrates the full [OTel Weaver](https://github.com/open-telemetry/weaver)
Observability-by-Design lifecycle using the OpenTelemetry Demo. You generate
Grafana dashboards and alerts from a telemetry schema, validate live telemetry
with Weaver's live-check, then flip a feature flag to break instrumentation and
watch Weaver catch the drift in real time.

**Jump to:**
[Prerequisites](#prerequisites) · [Quick Start](#quick-start) · [Demo Walkthrough](#demo-walkthrough) · [How It Works](#how-it-works) · [Key Files](#key-files) · [Troubleshooting](#troubleshooting)

---

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

| Target | Description |
|--------|-------------|
| `make demo-start` | Start the demo with Weaver live-check sidecar |
| `make demo-stop` | Stop the demo (including Weaver) |
| `make demo-logs` | Tail Weaver live-check output |
| `make demo-generate` | Regenerate dashboard and alert from the schema |
| `make demo-check` | Validate the telemetry schema |
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
2. Navigate to the **"Weaver - Observability by Design"** dashboard folder
3. Open the **Weaver Demo** dashboard
4. Confirm the **Payment Transactions Rate** panel shows live data
5. Check **Alerting** — the payment liveness alert shows Normal or Alerting
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
2. Toggle **telemetrySchemaBreak** to **on**

This causes the payment service to:

- Rename `app.payment.transactions` → `app.payment.tx_count`
- Drop the `app.payment.currency` attribute

### Step 6 — Watch the Damage

Wait ~5 minutes for the 5-minute rate window to drain, then:

1. **Dashboard breaks** — the "Payment Transactions Rate" panel shows **No data**
2. **Alert breaks** — the payment liveness alert transitions to **NoData** state
3. **Weaver catches it** — check the logs:

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

## Key Files

| File | Purpose |
|------|---------|
| `telemetry-schema/` | Weaver-compatible YAML telemetry schema (attributes, metrics, services) |
| `weaver-templates/registry/grafana/` | Jinja2 templates for codegen (dashboard + alerting) |
| `weaver-templates/registry/grafana/weaver.yaml` | Weaver codegen configuration |
| `docker-compose-weaver.yml` | Compose overlay adding the Weaver sidecar |
| `src/otel-collector/otelcol-config-weaver.yml` | Collector extras config for OTLP fan-out to Weaver |
| `src/grafana/provisioning/dashboards/weaver/weaver-demo-dashboard.json` | Generated Grafana dashboard |
| `src/grafana/provisioning/alerting/weaver-demo-alerting.yml` | Generated Grafana alert rule |
| `src/grafana/provisioning/dashboards/weaver.yaml` | Grafana dashboard provisioning config |
| `src/flagd/demo.flagd.json` | Feature flags — includes `telemetrySchemaBreak` |
| `src/payment/charge.js` | Payment service — reads the flag, conditionally breaks telemetry |
| `.env` | Pins `WEAVER_IMAGE=otel/weaver:v0.23.0` |

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

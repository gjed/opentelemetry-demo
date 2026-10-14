// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include "opentelemetry/exporters/otlp/otlp_grpc_metric_exporter_factory.h"
#include "opentelemetry/metrics/provider.h"
#include "opentelemetry/sdk/metrics/export/periodic_exporting_metric_reader.h"
#include "opentelemetry/sdk/metrics/meter.h"
#include "opentelemetry/sdk/metrics/meter_provider.h"

// namespaces
namespace common        = opentelemetry::common;
namespace metrics_api   = opentelemetry::metrics;
namespace metric_sdk    = opentelemetry::sdk::metrics;
namespace nostd         = opentelemetry::nostd;
namespace otlp_exporter = opentelemetry::exporter::otlp;

namespace
{
  std::shared_ptr<metric_sdk::MeterProvider> initMeter()
  {
    // Build MetricExporter
    otlp_exporter::OtlpGrpcMetricExporterOptions otlpOptions;
    auto exporter = otlp_exporter::OtlpGrpcMetricExporterFactory::Create(otlpOptions);

    // Build MeterProvider and Reader
    metric_sdk::PeriodicExportingMetricReaderOptions options;
    if (const char *interval = std::getenv("OTEL_METRIC_EXPORT_INTERVAL"))
    {
      options.export_interval_millis = std::chrono::milliseconds(std::atoi(interval));
      options.export_timeout_millis = std::min(options.export_timeout_millis, options.export_interval_millis / 2);
    }
    std::unique_ptr<metric_sdk::MetricReader> reader{
        new metric_sdk::PeriodicExportingMetricReader(std::move(exporter), options) };
    auto provider = std::make_shared<metric_sdk::MeterProvider>();
    provider->AddMetricReader(std::move(reader));
    std::shared_ptr<metrics_api::MeterProvider> api_provider = provider;
    metrics_api::Provider::SetMeterProvider(api_provider);
    return provider;
  }

  nostd::unique_ptr<metrics_api::Counter<uint64_t>> initIntCounter(std::string name, std::string version)
  {
    auto provider = metrics_api::Provider::GetMeterProvider();
    nostd::shared_ptr<metrics_api::Meter> meter = provider->GetMeter(name, version);
    auto int_counter = meter->CreateUInt64Counter(name);
    return int_counter;
  }
}

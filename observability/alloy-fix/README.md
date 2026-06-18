# Alloy receiver fix — OTLP signal routing

## Problem
The shared OTLP gateway `k8s-monitoring-alloy-receiver` (namespace `kube-monitor`) defined a single
OTLP destination `primary_otlp` pointing at **Tempo** and wired **all three** signals to it:

```
application_observability "feature" {
  metrics_destinations = [ otelcol.processor.attributes.primary_otlp.input ]  # -> Tempo
  logs_destinations    = [ otelcol.processor.attributes.primary_otlp.input ]  # -> Tempo
  traces_destinations  = [ otelcol.processor.attributes.primary_otlp.input ]  # -> Tempo
}
```

Tempo's OTLP endpoint only implements the **trace** service, so metrics and logs were rejected and
dropped, with the receiver logging every cycle:

```
Exporting failed. Dropping data. component_id=otelcol.exporter.otlp.primary_otlp
  error="… rpc error: code = Unimplemented desc = unknown service
         opentelemetry.proto.collector.metrics.v1.MetricsService"
```

## Fix (`config.alloy.new`)
Add OTLP/HTTP exporters for the correct backends and repoint each signal:

```
otelcol.exporter.otlphttp "mimir_metrics" { client { endpoint = "http://mimir-monolith.global-monitor-mimir.svc:9009/otlp"; headers = { "X-Scope-OrgID" = "anonymous" } } }
otelcol.exporter.otlphttp "loki_logs"     { client { endpoint = "http://loki-monolith.global-monitor-loki.svc:3100/otlp";   headers = { "X-Scope-OrgID" = "anonymous" } } }

metrics_destinations = [ otelcol.exporter.otlphttp.mimir_metrics.input ]  # -> Mimir
logs_destinations    = [ otelcol.exporter.otlphttp.loki_logs.input ]      # -> Loki
traces_destinations  = [ otelcol.processor.attributes.primary_otlp.input ] # -> Tempo (unchanged)
```

## Apply
```bash
kubectl -n kube-monitor patch cm k8s-monitoring-alloy-receiver --type merge \
  --patch-file <(python3 -c 'import json;print(json.dumps({"data":{"config.alloy":open("config.alloy.new").read()}}))')
kubectl -n kube-monitor rollout restart daemonset/k8s-monitoring-alloy-receiver
```

## Verify
- receiver logs: no more `Unimplemented … MetricsService`
- `sum(otelcol_exporter_sent_spans_total)` rising, `sum(otelcol_exporter_send_failed_spans_total)` = 0
- app spans in Tempo now carry `k8s.namespace.name` / `k8s.pod.name`

## Rollback
```bash
kubectl -n kube-monitor apply -f alloy-receiver.cm.backup.yaml
kubectl -n kube-monitor rollout restart daemonset/k8s-monitoring-alloy-receiver
```

> Note: the monlab observability stack appears to be externally managed (Salt). If a reconciler
> rewrites this ConfigMap, fold the same two exporters + destination repoints into the source of
> truth (the k8s-monitoring Helm values / Salt pillar).

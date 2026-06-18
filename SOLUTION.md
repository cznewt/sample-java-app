# Solution — full-observability deployment of the sample java app

This is the SRE-challenge write-up for deploying **Front → Kafka → Back → PostgreSQL → Reader** to
the `*.monlab.newt.cz` Kubernetes cluster. The deployment artifacts (Helm charts, dashboards, alert
rules, scripts) live in a separate working tree and are summarised here; the application sources in
this repo carry the observability instrumentation described below.

The goal beyond "it runs": wire every service into the cluster's **Grafana LGTM+ stack across all
four pillars** — metrics, logs, traces and continuous profiling — and harden the data paths with
**mTLS**.

---

## Telemetry instrumentation (in this repo, under `app/`)

Minimal, additive changes to make the apps first-class observability citizens:

* **Metrics** — added `io.micrometer:micrometer-registry-prometheus`; actuator exposes
  `/prometheus` on the management port (8081). Added `spring.application.name`, metric tag
  `application`, and HTTP server request **percentile histograms** for RED/latency panels.
* **Logs** — Spring Boot 3.5 **structured JSON** (`logging.structured.format.console=ecs`) to
  stdout. With the OpenTelemetry agent's MDC injection, every line carries `trace_id` / `span_id`,
  so logs are trace-correlated in Loki.
* **Traces** — the **OpenTelemetry Java agent** is attached at runtime (no code change) and
  auto-instruments Spring MVC, the Kafka client and JDBC. With the messaging *receive* span disabled
  the consumer span becomes a **child** of the producer, giving **one connected trace through Kafka**:
  `Front: POST /api/v1/command → testCommand publish → Back: testCommand process →
  TestRepository.save → INSERT appdb.test_entity → commit`.
* **Profiles** — the **Pyroscope** Java agent pushes continuous CPU profiles per service.

Traces and profiles are activated purely by env/agent flags from the Helm chart, so the image stays
generic. `OTEL_TRACES_EXPORTER=otlp`, `OTEL_METRICS/LOGS_EXPORTER=none` (metrics come from the
Prometheus scrape, logs from stdout).

---

## Composite Helm chart

A **composite (umbrella) chart** wraps a single reusable base chart instantiated three times:

```
chart/
  java-app/     # base chart: Deployment/Service/Ingress/HPA/PDB/SA/NetworkPolicy,
                #   all telemetry env + scrape annotations, hardened securityContext,
                #   generic extraVolumes/extraVolumeMounts (used for mTLS keystores)
  sre-apps/     # umbrella: depends on java-app THREE times via `alias`
    dependencies:
      - {name: java-app, alias: front,  condition: front.enabled}
      - {name: java-app, alias: back,   condition: back.enabled}
      - {name: java-app, alias: reader, condition: reader.enabled}
```

When aliased, `.Chart.Name` is the alias, so the base templates name objects `sre-front/back/reader`
automatically. Per-service config lives under `front:`/`back:`/`reader:`; `global:` is shared;
`<svc>.enabled` adds/removes a service. One set of templates, three composed instances — DRY.

---

## mTLS / TLS

* **Kafka — mutual TLS only.** The Strimzi listener is `tls` (9093) with `authentication: tls`; the
  **plaintext listener is removed**. A `KafkaUser` (`sre-app`) issues a client certificate; Front and
  Back mount the cluster CA (truststore `ca.p12`) and the user keystore (`user.p12`) and connect with
  `security.protocol=SSL`. Verified end-to-end (produce + consume over mTLS; 9092 gone).
* **PostgreSQL — TLS.** CloudNativePG serves TLS; Back and Reader connect with `sslmode=require`.
  (Client-certificate Postgres auth is a straightforward follow-up.)

---

## Data infrastructure

* **Kafka** — Strimzi, single-node **KRaft** (no ZooKeeper). Topic `testCommand`, **32 partitions,
  RF 1**. Broker JMX→Prometheus metrics + **kafka-exporter** (consumer-group lag) both annotated for
  scrape.
* **PostgreSQL 16** — CloudNativePG. Database `appdb`; the schema is created by Back on first run
  (Hibernate `ddl-auto=update`). CNPG metrics annotated for scrape.

---

## Dashboards, the JVM mixin, and the `monitor-tools` instance

* **JVM mixin** — the **grafana `jvm-observ-lib`** jsonnet library is rendered (metric source
  `java_micrometer`, selector `job=~"sre-.*"`) into a 30-panel **JVM** dashboard plus JVM alert rules.
* **monitor-tools instance** — a small Helm release whose post-install/upgrade **hook Job** pushes
  the dashboards into dedicated Grafana folders — **Kafka**, **PostgreSQL**, **Java apps** — and loads
  the alert rule groups into the **Mimir ruler** (→ Alertmanager). Idempotent, hardened non-root,
  no external dependencies.
* **Alerts** — app (down / 5xx / p99 latency), JVM (heap / deadlock), Kafka (consumer lag / no
  brokers / exporter down), Postgres (cluster down / connections).

---

## Backstage catalog

`catalog-info.yaml` (repo root) defines a **System** grouping the three **Components** (Front/Back/
Reader), the two **APIs** (ingest / read) and two **Resources** (Kafka, Postgres), with k8s/Grafana
annotations and Swagger links.

---

## Platform fix (bonus)

The shared `alloy-receiver` OTLP gateway routed **all** signals to Tempo, so metrics/logs were
dropped (`rpc error: Unimplemented … MetricsService`). It was fixed to route metrics→Mimir,
logs→Loki, traces→Tempo; apps then use it as the blessed path and spans gain `k8s.*` resource
attributes.

---

## Security & ops

Restricted-style pod security everywhere (non-root, dropped caps, `readOnlyRootFilesystem`, seccomp,
no SA token), PSA `baseline`/`restricted`. **NetworkPolicies enabled**: default-deny with only
app+management ports reachable and a tight egress allowlist (DNS, in-namespace Kafka/PG, Tempo/Alloy,
Pyroscope) — verified non-breaking.

Bring-up is a single `make all` (build → sideload images into cri-o → operators → Kafka/Postgres →
apps → dashboards/alerts); `make verify` asserts the pipeline plus all four telemetry pillars.

> The 2nd-iteration code-review / hardening backlog: client-cert Postgres mTLS, multi-broker Kafka /
> HA Postgres on a multi-node cluster, and external-secret management for the Grafana credentials.

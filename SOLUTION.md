# Solution — Secure and observable java application stack

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
  the dashboards into a **single Grafana folder**, split into nested **Kafka** / **PostgreSQL** /
  **Java apps** subfolders, and loads the alert rule
  groups into the **Mimir ruler** (→ Alertmanager). Idempotent, hardened non-root, no external deps.
* **Alerts** — 11 rules across app / JVM / Kafka / Postgres (see **Alerting** below).

---

## Alerting

11 Prometheus rules in 4 groups are loaded into the **Mimir ruler** (tenant `anonymous`, namespace
`sre-challenge`) by the monitor-tools Job; Mimir evaluates them and routes firing alerts to the
shared **Alertmanager**. Coverage is RED (rate / errors / duration) for the apps and availability /
saturation for the infrastructure — warnings are tuned to fire *before* the matching critical.

| Component | Alert | Severity | Fires when |
|---|---|---|---|
| Apps (front/back/reader) | `SreAppDown`              | critical | `up==0` for the service, 2m |
|                          | `SreAppHighErrorRate`     | warning  | 5xx ratio > 5% over 5m |
|                          | `SreAppHighLatencyP99`    | warning  | HTTP p99 > 1s for 10m |
| JVM (per app, `jvm-observ-lib` mixin) | `JvmMemoryFillingUp`    | warning  | heap > 80% for 5m |
|                          | `JvmThreadsDeadlocked`    | critical | deadlocked threads, 2m |
| Kafka                    | `KafkaConsumerLagHigh`    | warning  | `testCommand` consumer lag > 1000 for 5m (Back behind) |
|                          | `KafkaExporterDown`       | warning  | exporter `up==0`, 5m (lag blind spot) |
|                          | `KafkaNoBrokers`          | critical | `kafka_brokers < 1`, 2m |
| Postgres                 | `PostgresClusterDown`     | critical | `cnpg_collector_up==0`, 2m |
|                          | `PostgresTooManyConnections` | warning | backends / `max_connections` > 80% for 5m |

**4 critical** (hard-down / deadlock) + **7 warning** (degradation). Each alert maps to a panel in the
Grafana dashboards; the app/Kafka/Postgres rule sources ship with the deployment, the two JVM rules
are rendered from the mixin.

---

## Monitoring per component

Every component has its own board(s) and alert(s). The three apps share the **job-templated** JVM
mixin dashboard and the app/JVM alert groups (each rule evaluates per `job`, so Front/Back/Reader are
distinct series); Kafka and Postgres use the upstream Strimzi/CNPG boards. All dashboards are pinned
to the Mimir datasource and pushed into the nested assignment folders.

| Component | Boards (folder) | Alerts |
|---|---|---|
| **Front** (`sre-front`)  | SRE JVM overview · *Java apps* | SreAppDown, SreAppHighErrorRate, SreAppHighLatencyP99, JvmMemoryFillingUp, JvmThreadsDeadlocked |
| **Back** (`sre-back`)    | SRE JVM overview · *Java apps* | SreAppDown, JvmMemoryFillingUp, JvmThreadsDeadlocked — plus **KafkaConsumerLagHigh** (its consumer health) |
| **Reader** (`sre-reader`)| SRE JVM overview · *Java apps* | SreAppDown, SreAppHighErrorRate, SreAppHighLatencyP99, JvmMemoryFillingUp, JvmThreadsDeadlocked |
| **Kafka**                | Strimzi Kafka (broker JMX), Strimzi Kafka Exporter (consumer lag) · *Kafka* | KafkaConsumerLagHigh, KafkaExporterDown, KafkaNoBrokers |
| **Postgres**             | CloudNativePG · *PostgreSQL* | PostgresClusterDown, PostgresTooManyConnections |

The JVM board + its 2 alerts are rendered from the grafana **`jvm-observ-lib` mixin** (metric source
`java_micrometer`, selector `job=~"sre-.*"`); the app/Kafka/Postgres alert groups ship with the
deployment. Each board exists because its component exports the matching metrics — Micrometer JVM/HTTP
for the apps, kafka-exporter + broker JMX for Kafka, the CNPG metrics endpoint for Postgres.

---

## Backstage service catalog

`catalog-info.yaml` (repo root) registers the stack in the Backstage software catalog:

* **System** `sample-java-app` (in **Domain** `platform-observability`, owned by **Group** `team-sre`).
* **Components** (`type: service`): `sre-front`, `sre-back`, `sre-reader` — each carries a
  `backstage.io/kubernetes-label-selector` (lights up the Backstage Kubernetes plugin: pods/health),
  a source location and a Swagger link.
* **APIs** (`type: openapi`, inline specs): `sre-front-api` (provided by Front, consumed by Back) and
  `sre-reader-api` (provided by Reader).
* **Resources**: `kafka-cluster` (message-broker, mTLS) and `postgres-db` (database, TLS).
* **Relations** tie it together — Front `dependsOn` Kafka; Back `dependsOn` Kafka + Postgres; Reader
  `dependsOn` Postgres; all `partOf` the System — so Backstage renders the full dependency graph.

---

## Security — protecting the APIs

Defence-in-depth across the four API surfaces:

* **Public REST APIs** — Front `POST /api/v1/command`, Reader `GET /api/v1/testEntity` and Swagger
  are exposed only through the nginx **Ingress over HTTPS** (cert-manager / Let's Encrypt cert per
  host). Only the `http` port is internet-routed; **Back (consumer) has no ingress at all**.
  *Honest gap:* the challenge app ships no Spring Security, so these endpoints have **no
  application-level authn/authz** — anyone who can reach the hostname can post/read. This is the top
  item on the hardening backlog (API key / OAuth2 resource-server / mTLS at the ingress). Everything
  *around* the endpoint is locked down instead.
* **Management / actuator API** (port 8081 — health, metrics, `/prometheus`) — **not internet-
  exposed** (the Ingress backend points only at the `http` port; 8081 stays cluster-internal, reached
  only by Alloy scrape + kubelet probes) and **read-only + minimal**: `access.default: read_only`,
  exposure limited to `health,info,metrics,prometheus` (no `env` / `heapdump` / `shutdown` / `loggers`).
* **Kafka (messaging API)** — **mutual TLS only**: the plaintext 9092 listener is removed and the
  9093 listener requires a Strimzi-issued client certificate (`KafkaUser sre-app`). No cert ⇒ no
  connection.
* **Postgres (data API)** — connections use **TLS** (`sslmode=require`); credentials come from the
  CNPG-generated `sre-postgres-app` secret, never hard-coded.

Net: transport and network layers are locked down (HTTPS in, mTLS/TLS to backends, default-deny
east-west, minimal read-only ops endpoints); the remaining authentication gap is specifically at the
app's own HTTP handlers. The container / runtime / network controls behind this are detailed next.

## Container, runtime & network hardening

* **Image / build** — multi-stage build (Gradle builder → slim `eclipse-temurin:21-jre` runtime) with
  a baked-in non-root user (uid 10001) and the jar at `/app.jar`. The OTel + Pyroscope agents are
  baked in but **inert** (activated only via env), so the image stays generic and no agent runs
  unless the chart asks for it.
* **Container `securityContext`** — `runAsNonRoot` (10001/10001), **`readOnlyRootFilesystem`**
  (writable `/tmp` is an `emptyDir`), **all Linux capabilities dropped** (`drop: [ALL]`),
  `allowPrivilegeEscalation: false`, **seccomp `RuntimeDefault`**, and **`automountServiceAccountToken:
  false`** (no API-server token to steal if the process is popped).
* **Pod / namespace** — CPU/memory requests+limits, container-aware heap (`-XX:MaxRAMPercentage=75`),
  liveness / readiness / startup probes on the management port, and `fsGroup` so the non-root process
  can read the mounted mTLS keystores. The namespace **enforces PSA `baseline`** (Strimzi/CNPG
  compatible) and **audits/warns at `restricted`**; the same hardened context is applied to the
  monitor-tools and load-generator Jobs.
* **Network** — a **default-deny `NetworkPolicy`** per app: ingress only on the `http` + `management`
  ports (every other port dropped), and an **egress allowlist** to exactly DNS (kube-system),
  in-namespace Kafka/Postgres, the Tempo/Alloy OTLP receiver and Pyroscope. A compromised app
  therefore can't reach the Kubernetes API server, other namespaces, or the internet.
* **Runtime / supply chain** — images are built locally and **sideloaded into the node's cri-o**
  (`containers-storage`) over SSH, so nothing transits a third-party registry; pods run
  `imagePullPolicy: IfNotPresent` against the vetted local image.

## Ops

Bring-up is a single `make all` (build → sideload images into cri-o → operators → Kafka/Postgres →
apps → dashboards/alerts); `make verify` asserts the pipeline plus all four telemetry pillars.

Local development needs no cluster — **`docker compose up --build`** (root `docker-compose.yml` +
`Dockerfile`) runs Kafka (KRaft) + PostgreSQL + the three services, with the `testCommand` topic
pre-created at 32 partitions. Front on `:8080`, Reader on `:8084`, Swagger + `/health` on each.

> Hardening backlog: app-level authn/authz on the REST endpoints, client-cert Postgres mTLS,
> multi-broker Kafka / HA Postgres on a multi-node cluster, and external-secret management for the
> Grafana credentials.

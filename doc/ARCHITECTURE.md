# Architecture

## 1. Cluster & topology
Single-node kubeadm cluster `ales-komarek-mon-lab` (`*.monlab.newt.cz`, API `91.99.85.170:6443`),
**cri-o** runtime, **flannel** CNI, `local-path` storage, nginx ingress, cert-manager (letsencrypt).
The node also runs the shared **Grafana LGTM+ stack** (Prometheus, Mimir, Loki, Tempo, Pyroscope,
Parca, Alloy, Grafana, Alertmanager, Pyrra).

Everything for this solution lives in three namespaces: `sre-challenge` (apps + Kafka + Postgres),
`cnpg-system` (CNPG operator), `monitor-tools` (dashboard/alert pusher). Strimzi runs in
`sre-challenge` watching all namespaces.

## 2. Application flow
`Front (REST :8080)` → produces JSON `TestCommand` to Kafka topic `testCommand` (32 partitions,
RF 1) → `Back (@KafkaListener, concurrency=2)` runs the tan/atan load loop and persists `TestEntity`
to Postgres via JPA (`ddl-auto=update`, so Back **creates the schema**) → `Reader (REST :8084)`
serves a paginated read (`ddl-auto=validate`). Management/actuator on `:8081` for all three.

## 3. Helm: umbrella + aliased base chart
The requested shape — a top chart with parametric, enable-gated subcharts built from **one**
templated base chart:

```
chart/java-app     # type: application — Deployment/Service/Ingress/HPA/PDB/SA/NetworkPolicy,
                   #   all telemetry env + scrape annotations, hardened securityContext.
chart/sre-apps     # umbrella — depends on java-app THREE times via alias:
  dependencies:
    - {name: java-app, alias: front,  condition: front.enabled,  repository: file://../java-app}
    - {name: java-app, alias: back,   condition: back.enabled,   repository: file://../java-app}
    - {name: java-app, alias: reader, condition: reader.enabled, repository: file://../java-app}
```

When aliased, `.Chart.Name` is the alias, so the base templates name objects `sre-front/back/reader`
automatically. Per-service config (ports, image repo, ingress, env, secret refs) lives under the
`front:`/`back:`/`reader:` keys; `global:` is shared. Flipping `<svc>.enabled=false` removes a
service. This is strictly DRY — one set of templates, three instances — versus the prior solutions'
per-app value files or `{{- if .enabled }}` blocks.

## 4. Images & delivery
`docker/Dockerfile` is multi-stage: **(1)** `gradle:8.5-jdk21` builds all three boot jars (one
cached layer); **(2)** `curlimages/curl` fetches the **OpenTelemetry** and **Pyroscope** Java
agents; **(3)** `eclipse-temurin:21-jre` runtime — non-root uid 10001, agents under `/opt/agents`,
`ENTRYPOINT ["java",…,"-jar","/app.jar"]`. Agents are **baked in but inert**; the Helm chart turns
them on via `JAVA_TOOL_OPTIONS`/`OTEL_*`/`PYROSCOPE_*`.

No JDK on the workstation and no registry on the node, so images are **sideloaded**: `docker save`
→ stream over SSH → `skopeo copy docker-archive:… containers-storage:localhost/sre-*:0.1.0`, run
with `imagePullPolicy: IfNotPresent`.

## 5. Telemetry pipeline (per pillar)
Collection mechanisms were read from the live stack and matched exactly:

* **Metrics** — apps add `micrometer-registry-prometheus` exposing `/prometheus` on :8081. Pods are
  annotated `k8s.grafana.com/scrape:"true"`, `…/metrics.portNumber:"8081"`, `…/metrics.path:"/prometheus"`,
  which the **Alloy "annotation autodiscovery"** keeps and scrapes → Prometheus + Mimir. Kafka
  (kafka-exporter :9404 + broker JMX) and Postgres (CNPG :9187 via `inheritedMetadata.annotations`)
  use the same annotations.
* **Logs** — Spring Boot 3.5 `logging.structured.format.console=ecs` emits ECS JSON to stdout; the
  OTel agent injects `trace_id`/`span_id` into MDC, so every line is trace-correlated. Promtail/Alloy
  tail the container → Loki.
* **Traces** — the **OpenTelemetry Java agent** auto-instruments Spring MVC, the Kafka client and
  JDBC with **no code changes**. `OTEL_TRACES_EXPORTER=otlp`, `…_METRICS/_LOGS=none` (metrics/logs go
  the routes above). Context propagates through Kafka headers; with the messaging *receive* span
  disabled the consumer span becomes a **child** of the producer → a single connected trace
  `Front → testCommand publish → Back → INSERT → commit`. Exported to the **Alloy receiver**
  (`k8s-monitoring-alloy-receiver.kube-monitor:4317`), which enriches spans with k8s resource
  attributes and forwards to Tempo. (We fixed that receiver — see §8 — it previously misrouted all
  signals to Tempo.)
* **Profiles** — the **Pyroscope** Java agent (async-profiler, JFR) pushes CPU profiles to
  `pyroscope:4040`, labelled per service.

## 6. Dashboards & alerts (`monitor-tools`)
`scripts/assemble-dashboards.sh` normalises dashboards (pins `${DS_PROMETHEUS}`/`${datasource}` to
the **Mimir** UID, `${DS_EXPRESSION}`→`__expr__`, strips `__inputs`) and stages the alert rule
groups. The `monitor-tools` Helm release carries them in ConfigMaps and a **post-install/upgrade
hook Job** (hardened non-root curl) that ensures a Grafana folder, pushes the dashboards via
`/api/dashboards/db`, and loads the rule groups into the **Mimir ruler** (`/prometheus/config/v1/rules`,
tenant `anonymous`). Idempotent and re-runnable.

The JVM dashboard + 2 of the alerts are rendered from the **grafana `jvm-observ-lib`** jsonnet mixin
(`observability/mixin/`, reproducible build documented there).

## 7. Security posture
Restricted-style pod security on every app and Job: `runAsNonRoot`, dropped capabilities, no
privilege escalation, `readOnlyRootFilesystem` (+ emptyDir `/tmp`), `seccompProfile: RuntimeDefault`,
`automountServiceAccountToken: false`. Namespace enforces PSA `baseline` (Strimzi/CNPG compatible)
with `restricted` audit/warn. **NetworkPolicies are enabled** per service: default-deny, only the
app + management ports reachable (broad source so kubelet probes + Alloy scrape + hostNetwork
ingress survive), and a tight egress allowlist (DNS, in-namespace Kafka/PG, Tempo/Alloy receiver,
Pyroscope). Verified to preserve all four telemetry signals.

## 8. Platform fix: Alloy receiver signal routing
The shared `k8s-monitoring-alloy-receiver` (OTLP gateway in `kube-monitor`) had a single OTLP
destination (`primary_otlp` → Tempo) wired for **metrics, logs and traces**. Tempo's OTLP endpoint
only implements the trace service, so metrics/logs were rejected
(`rpc error: code = Unimplemented … MetricsService`) and dropped. `observability/alloy-fix/` adds
`otelcol.exporter.otlphttp` destinations for **Mimir** (`:9009/otlp`) and **Loki** (`:3100/otlp`),
each with `X-Scope-OrgID: anonymous`, and repoints `metrics_destinations`/`logs_destinations`
accordingly while leaving `traces_destinations` → Tempo. The original configmap is backed up next to
the patched config for one-command rollback.

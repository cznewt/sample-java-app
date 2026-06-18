# SRE Coding Challenge — monlab solution (full-observability edition)

Deploys the three Spring Boot apps (**Front → Kafka → Back → PostgreSQL → Reader**) to the
`*.monlab.newt.cz` Kubernetes cluster with **Helm**, on top of **Strimzi Kafka** and
**CloudNativePG**, and wires every service into the cluster's **Grafana LGTM+ stack across all
four observability pillars** — metrics, logs, traces and continuous profiling.

The brief asked for a working Helm deployment of the apps + Kafka + Postgres. The three previous
contestant solutions (`../sre-challenge-gke-terraform`, `../sre-challenge-k3s-on-prem`,
`../sre-challenge-solution`) all delivered that — and all three shipped **zero observability**
(metrics endpoints exposed but never scraped, no dashboards, no logs/traces/alerts). This solution
treats observability as the product.

---

## 1. What runs, and how data flows

```
            ┌──────────── monlab node: ales-komarek-mon-lab (kubeadm · cri-o · flannel) ────────────┐
 POST /api/v1/command          ┌────────┐  produce   ┌──────────────────────────┐  consume  ┌────────┐
 ───────────────────────────▶  │ Front  │ ─────────▶ │ Kafka  testCommand        │ ────────▶ │  Back  │
                               └────────┘            │ 32 partitions · RF 1·KRaft│           └───┬────┘
 GET /api/v1/testEntity        ┌────────┐   read     ┌──────────────────────────┐   persist     │ JPA
 ◀───────────────────────────  │ Reader │ ◀───────── │ PostgreSQL 16 (CloudNativePG, appdb) ◀────┘
                               └────────┘            └──────────────────────────┘
            └───────────────────────────────────────────────────────────────────────────────────────┘
   Every JVM emits 4 signals:   metrics (/prometheus)   logs (stdout JSON)   traces (OTLP)   profiles (JFR)
                                       │                      │                   │                │
                              Alloy annotation-scrape    Promtail/Alloy      Tempo (OTLP)     Pyroscope agent
                                       ▼                      ▼                   ▼                ▼
                                  Prometheus + Mimir         Loki              Tempo           Pyroscope
                                       └──────────────────── Grafana ─────────────────────────────┘
                                            Mimir ruler ──evaluates rules──▶ Alertmanager
```

* **Front** (`8080`) — REST ingest, Kafka **producer** to `testCommand`.
* **Back** (`8082`) — Kafka **consumer**, runs the load calc, **persists** to Postgres, **owns the
  schema** (Hibernate `ddl-auto=update` on first boot).
* **Reader** (`8084`) — paginated REST **read** over the persisted entities.
* All three expose actuator/management on `8081`.

Verified end-to-end: a POST to Front results in rows readable from Reader, and produces a single
**connected distributed trace** `Front → testCommand publish → Back → INSERT appdb.test_entity →
commit` (see §6).

---

## 2. Repository layout

```
sre-challenge-monlab/
├── docker/Dockerfile               # multi-stage build; OTel + Pyroscope agents baked in
├── chart/
│   ├── java-app/                   # reusable base chart (the "templated basic one")
│   └── sre-apps/                   # umbrella: java-app aliased x3 (front/back/reader), enable-gated
├── k8s/
│   ├── kafka/                      # Strimzi KRaft cluster + KafkaTopic(testCommand) + JMX metrics
│   └── postgres/                   # CloudNativePG cluster (PG16, appdb)
├── observability/
│   ├── mixin/                      # grafana jvm-observ-lib rendered -> JVM dashboard + alerts
│   ├── dashboards/                 # upstream Kafka (Strimzi) + Postgres (CNPG) dashboards
│   └── alerts/                     # app / kafka / postgres Mimir rule groups
├── monitor-tools/                  # the "monitor-tools" instance: pushes dashboards + rules
├── catalog-info.yaml               # Backstage: System + 3 Components + 2 APIs + 2 Resources
├── scripts/                        # build / sideload / assemble helpers
└── Makefile                        # one-command reproducible deploy
```

---

## 3. Design decisions (and why they beat the prior solutions)

| Concern | This solution | The 3 prior solutions |
|---|---|---|
| **Metrics** | `micrometer-registry-prometheus` added; `/prometheus` scraped via `k8s.grafana.com/scrape` annotations → Mimir | endpoint exposed, **never scraped** |
| **Logs** | Spring Boot 3.5 **ECS structured JSON** to stdout → Promtail → Loki, with `trace_id`/`span_id` | plain text, no aggregation |
| **Traces** | **OpenTelemetry Java agent** (zero code) → Tempo; **one connected trace through Kafka** | none |
| **Profiles** | **Pyroscope** Java agent (JFR/async) → continuous profiling | none |
| **Dashboards** | JVM (grafana `jvm-observ-lib` mixin) + Kafka + Postgres, pushed to a Grafana folder | none |
| **Alerts** | 11 rules (app/JVM/Kafka/Postgres) loaded into the **Mimir ruler** → Alertmanager | none |
| **Helm shape** | umbrella + **one templated base chart aliased 3×**, `*.enabled` gated | per-app value files / `if .enabled` blocks |
| **Images** | multi-stage, **non-root, readOnlyRootFs, seccomp**, agents baked in, toggled by env | distroless/Semeru, no agents |
| **Catalog** | **Backstage** System/Components/Resources/APIs | none |

The prior solutions invested heavily in infra plumbing (GKE/Terraform, k3s/Ansible, Vault/ESO,
mTLS, NetworkPolicies). That work is real — but for an *SRE* challenge the glaring gap was that you
could not answer "why is Back slow?" because nothing was observable. This solution closes exactly
that gap and integrates natively with the monlab platform instead of bolting on a parallel stack.

---

## 4. Observability wiring (the important part)

Discovered from the live cluster and used verbatim:

| Signal | Mechanism | Target |
|---|---|---|
| Metrics | pod annotations `k8s.grafana.com/scrape:"true"`, `…/metrics.portNumber:"8081"`, `…/metrics.path:"/prometheus"` → Grafana **Alloy annotation-autodiscovery** | `prometheus-server` + **Mimir** (`global-monitor-mimir-server`) |
| Logs | container stdout (ECS JSON) tailed by **Promtail/Alloy** | **Loki** (`global-monitor-loki-server`) |
| Traces | OTel agent `OTEL_EXPORTER_OTLP_ENDPOINT` → **Alloy receiver** (adds k8s attrs) → Tempo | `k8s-monitoring-alloy-receiver.kube-monitor:4317` |
| Profiles | Pyroscope agent `PYROSCOPE_SERVER_ADDRESS` | `pyroscope.global-monitor-pyroscope:4040` |
| Alerts | rule groups POSTed to the **Mimir ruler** config API (tenant `anonymous`) | Alertmanager |

Kafka and Postgres are observable too: the Strimzi **kafka-exporter** (consumer-group lag per
partition) and broker **JMX→Prometheus** exporter, and the **CloudNativePG** metrics endpoint, are
all annotated for the same Alloy autodiscovery.

> **A real platform bug found & fixed.** The shared `alloy-receiver` routed **all three** OTLP
> signals to its single Tempo destination, so metrics/logs hit Tempo's OTLP endpoint —
> which only implements the trace service — and were dropped (`rpc error: Unimplemented … MetricsService`,
> `otelcol_exporter_send_failed_spans` climbing). The fix (`observability/alloy-fix/`) adds OTLP
> exporters for **Mimir** (metrics) and **Loki** (logs) and repoints each signal to its correct
> backend (metrics→Mimir, logs→Loki, traces→Tempo). After the fix the receiver exports cleanly
> (`sent_spans` rising, `0` failed) and our apps use it as the blessed path — spans are now
> enriched with `k8s.namespace.name` / `k8s.pod.name`. A pre-fix backup of the config is kept
> alongside the patched version for rollback.

### The JVM mixin
`observability/mixin/` renders the **grafana `jvm-observ-lib`** jsonnet library
(`metricsSource: java_micrometer`, selector `job=~"sre-.*"`) into the **"SRE JVM overview"**
dashboard (30 panels incl. Hikari pools + Logback) and 2 JVM alert rules. Fully reproducible —
see `observability/mixin/README.md`.

### The `monitor-tools` instance
A self-contained Helm release (namespace `monitor-tools`) whose post-install/upgrade **hook Job**:
1. ensures the Grafana folder **"SRE Challenge — Boerse"**,
2. pushes the JVM + Kafka + Postgres dashboards (datasources pinned to Mimir) via the Grafana API,
3. loads the 4 alert rule groups into the **Mimir ruler** via its config API.

It runs as a hardened non-root curl Job (no jq/registry dependency) and is **idempotent** — re-run
it any time with `helm upgrade`.

---

## 5. Deploy from zero

Prereqs on the workstation: `kubectl`, `helm` v3+, `docker` (buildx), `jq`, `yq`, plus SSH access to
the node. The cluster kubeconfig is fetched to `_solution/.kube/config`.

```bash
make all          # build → sideload → operators → kafka/postgres → apps → dashboards/alerts
```

…or step by step (see the `Makefile`):

```bash
make images          # multi-stage build of front/back/reader (agents baked in)
make sideload        # stream images into the node's cri-o (no registry needed)
make operators       # Strimzi + CloudNativePG operators
make data            # Kafka (testCommand 32/RF1) + Postgres 16
make apps            # helm install the umbrella chart (front/back/reader)
make observability   # render mixin + helm install monitor-tools (dashboards + alerts)
make verify          # exercise the pipeline and assert all 4 pillars have data
```

**Image delivery:** the node runs cri-o with no registry, and the workstation has no JDK. Images are
built with Docker (multi-stage Gradle→JRE) and **sideloaded** into the node's `containers-storage`
via `skopeo` over SSH, then run with `imagePullPolicy: IfNotPresent`. No registry, DNS or pull
secret required — ideal for a single-node lab. (A registry-based flow is a drop-in alternative;
see `scripts/`.)

---

## 6. Verification (what "done" looks like)

```bash
# pipeline: POST to Front, read back from Reader
kubectl -n sre-challenge run t --image=curlimages/curl --rm -i --restart=Never -- sh -c '
  curl -s -XPOST http://sre-front:8080/api/v1/command -H "Content-Type: application/json" \
    -d "{\"message\":\"hi\",\"loadFront\":2,\"loadBack\":40}";
  sleep 6; curl -s "http://sre-reader:8084/api/v1/testEntity?size=5"'
```

Confirmed live on the cluster:

* **Metrics** — jobs `sre-front/back/reader`, `integrations/kafka`, `integrations/kafka-exporter`,
  `integrations/postgres` all scraped; `jvm_*`, `http_server_requests_*`, `kafka_consumergroup_lag`
  (×32 partitions), `cnpg_*` (400+ series) present in Mimir.
* **Logs** — `{namespace="sre-challenge"}` in Loki, ECS JSON carrying `trace_id`/`span_id`.
* **Traces** — connected trace in Tempo:
  `sre-front: POST /api/v1/command → testCommand publish → sre-back: testCommand process →
  TestRepository.save → INSERT appdb.test_entity → Transaction.commit`.
* **Profiles** — Pyroscope `render` returns CPU flamegraph data for `sre-back`.
* **Dashboards** — 4 in folder **SRE Challenge — Boerse** (Grafana, admin login).
* **Alerts** — 11 rules in 4 groups evaluating in the Mimir ruler.

Grafana: <https://grafana.monlab.newt.cz> · Front/Reader Swagger via the `*.monlab.newt.cz` ingresses.

---

## 7. Known limitations / hardening backlog

Honest about what remains:

* **NetworkPolicies** are **enabled and verified** (`networkPolicy.enabled: true`): default-deny with
  only the app + management ports reachable, and an explicit egress allowlist (DNS, in-namespace
  Kafka/PG, Tempo/Alloy receiver, Pyroscope). Confirmed not to break kubelet probes, Alloy scrape,
  ingress, or any of the four telemetry signals (`make verify` passes with them on).
* **Kafka mTLS / Postgres TLS** are not enabled (a plaintext internal listener is used). The prior
  solutions did enforce mTLS; here the pipeline + observability were the priority. Strimzi `tls`
  listener and CNPG SSL are one-flag follow-ups.
* **Grafana admin credentials** live in `monitor-tools/values.yaml` (lab default `admin/CHANGEME`).
  Use `--set` or an external/sealed secret in anything real.
* **Single replica** everywhere (single-node lab). HPA/PDB are templated and ready; multi-broker
  Kafka / HA Postgres need a multi-node cluster.

See `doc/RUNBOOK.md` for day-2 operations and troubleshooting.

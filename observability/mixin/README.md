# JVM observability mixin (Spring Boot / Micrometer)

Rendered artifacts from the Grafana
[`jvm-observ-lib`](https://github.com/grafana/jsonnet-libs/tree/master/jvm-observ-lib)
jsonnet mixin, targeted at the SRE-challenge Spring Boot apps.

## What this targets

The apps (`sre-front`, `sre-back`, `sre-reader`) expose **Micrometer Prometheus**
metrics via `micrometer-registry-prometheus`. The mixin is therefore configured
with the `java_micrometer` metric source (NOT `jmx_exporter`, NOT `otel`):

| Config key          | Value                                          |
| ------------------- | ---------------------------------------------- |
| `metricsSource`     | `java_micrometer`                              |
| `filteringSelector` | `job=~"sre-.*", namespace="sre-challenge"`     |
| `groupLabels`       | `['job']`  (one group per app)                 |
| `instanceLabels`    | `['instance']`  (one instance per pod/replica) |
| `uid`               | `sre-jvm`                                       |
| `dashboardTags`     | `java, jvm, sre-challenge, spring-boot`         |
| `alertHeapWarning`  | `80` (%)                                         |

Using the `java_micrometer` source also enables the **Hikari connection-pool**
and **Logback** dashboard rows, which are Spring-Boot-specific.

## Artifacts

```
mixin/
├── dashboards/
│   └── jvm-dashboard.json      # Grafana dashboard object (title: "SRE JVM overview")
├── alerts.yaml                 # Prometheus alerting rules (2 alerts)
├── mixin.libsonnet             # mixin config (imports jvm-observ-lib)
├── render-dashboards.jsonnet   # multi-file output wrapper for dashboards
├── render-alerts.jsonnet       # YAML wrapper for alerts
├── jsonnetfile.json            # jb manifest (jvm-observ-lib@master)
├── jsonnetfile.lock.json       # pinned commit hashes (reproducible)
└── README.md                   # this file
```

The dashboard JSON is a bare Grafana dashboard object (`title`, `panels`,
`templating`, `schemaVersion`, …) — i.e. the thing that goes under the
`dashboard` field when pushing via the Grafana HTTP API. The datasource is a
**template variable** (`datasource`, type `prometheus`); no datasource UID is
hardcoded — panels reference `${datasource}`.

## Pinned versions (from `jsonnetfile.lock.json`)

| Library              | Commit                                     |
| -------------------- | ------------------------------------------ |
| `jvm-observ-lib`     | `31e47dee035b00326c8c35ab571e93ae7d756351` |
| `process-observ-lib` | `31e47dee035b00326c8c35ab571e93ae7d756351` |
| `common-lib`         | `31e47dee035b00326c8c35ab571e93ae7d756351` |
| `grafonnet` (v11.0 / v11.4) | `7380c9c64fb973f34c3ec46265621a2b0dee0058` |

## How it was rendered (exact, reproducible commands)

No local jsonnet toolchain is required — everything runs in Docker. `jsonnet`
and `jb` are built once into `./bin` from a `golang:1.24` container (the
upstream `grafana/jsonnet-build:master` image was not pullable, and
go-jsonnet `v0.22.0` needs Go ≥ 1.24.5).

```sh
# 0) work in a scratch dir
mkdir -p /tmp/jvmmixin && cd /tmp/jvmmixin

# 1) build jsonnet + jb into ./bin (one-off)
docker run --rm -v "$PWD":/work -w /work golang:1.24 bash -c '
  export GOBIN=/work/bin && mkdir -p /work/bin
  go install github.com/google/go-jsonnet/cmd/jsonnet@latest
  go install github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest'

# 2) jb init + install the lib (pulls grafonnet, common-lib, process-observ-lib, ... transitively)
docker run --rm -v "$PWD":/work -w /work golang:1.24 bash -c '
  export PATH=/work/bin:$PATH
  jb init
  jb install github.com/grafana/jsonnet-libs/jvm-observ-lib@master'

# 3) drop mixin.libsonnet, render-dashboards.jsonnet, render-alerts.jsonnet here
#    (see the copies committed alongside this README)

# 4) render dashboards -> one JSON file per dashboard (multi-file output)
docker run --rm -v "$PWD":/work -w /work golang:1.24 bash -c '
  export PATH=/work/bin:$PATH
  mkdir -p /work/out/dashboards
  jsonnet -J vendor -S -m /work/out/dashboards render-dashboards.jsonnet'

# 5) render alerts -> JSON (then converted to clean block YAML on the host)
docker run --rm -v "$PWD":/work -w /work golang:1.24 bash -c '
  export PATH=/work/bin:$PATH
  jsonnet -J vendor -e "(import \"mixin.libsonnet\").prometheusAlerts" > /work/out/alerts.json'
# alerts.yaml is produced from alerts.json with PyYAML (block style, unquoted);
# std.manifestYamlDoc also works but double-quotes every key.
```

### Verification

```sh
# dashboard is valid JSON + has a sensible title
jq -e .     out/dashboards/jvm-dashboard.json   # exits 0
jq -r .title out/dashboards/jvm-dashboard.json   # -> "SRE JVM overview"

# datasource is a template variable, not a hardcoded UID
jq '.templating.list[] | select(.name=="datasource")' out/dashboards/jvm-dashboard.json
#   -> { "name":"datasource", "type":"datasource", "query":"prometheus", ... }

# alert rules validate
docker run --rm -v "$PWD"/out:/data --entrypoint promtool \
  prom/prometheus:latest check rules /data/alerts.yaml      # -> SUCCESS: 2 rules found
```

## Pushing to Grafana / Prometheus

* **Dashboard**: `POST /api/dashboards/db` with body
  `{"dashboard": <contents of jvm-dashboard.json>, "overwrite": true}`.
  Grafana will prompt for / map the `datasource` template variable.
* **Alerts**: load `alerts.yaml` via Prometheus `rule_files:`, or wrap it in a
  `PrometheusRule` CR's `spec` (the `groups:` block drops straight in).

## Re-rendering after a lib bump

Re-run steps 2, 4, 5 (delete `out/` first). To pin to a newer upstream commit,
bump the `version` in `jsonnetfile.json` and re-run `jb update`, then re-render.

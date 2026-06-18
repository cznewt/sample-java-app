# Runbook — SRE challenge (monlab)

Day-2 operations and troubleshooting. Namespace `sre-challenge` unless noted.
`export KUBECONFIG=_solution/.kube/config` first.

## Access
- Grafana: <https://grafana.monlab.newt.cz> (`admin` / `CHANGEME`) → folder **"SRE Challenge — Boerse"**.
- Front API / Swagger: `https://sre-front.monlab.newt.cz/swagger-ui.html`
- Reader API / Swagger: `https://sre-reader.monlab.newt.cz/swagger-ui.html`
- Node (root): `ssh -i ~/.ssh/id_ed25519 root@kube.monlab.newt.cz`

## Generate traffic
```bash
kubectl -n sre-challenge run load --image=curlimages/curl --rm -i --restart=Never -- sh -c '
  for i in $(seq 1 50); do
    curl -s -o /dev/null -XPOST http://sre-front:8080/api/v1/command \
      -H "Content-Type: application/json" \
      -d "{\"message\":\"run-$i\",\"loadFront\":2,\"loadBack\":60}"; done; echo sent'
```
`loadBack`/`loadFront` (×200 000 iterations) drive CPU on Back/Front — visible in the JVM dashboard,
traces and Pyroscope flamegraphs.

## Inspect each pillar
- **Metrics:** Grafana → *SRE JVM overview* / *Strimzi Kafka Exporter* / *CloudNativePG*.
- **Logs:** Grafana Explore → Loki → `{namespace="sre-challenge", app="sre-back"} | json`.
- **Traces:** Grafana Explore → Tempo → TraceQL `{ resource.service.name="sre-front" }` (expand to
  see the Kafka→Back→Postgres spans). Service graph: *Tempo Service Graph* dashboard.
- **Profiles:** Grafana Explore → Pyroscope → service `sre-back`, profile `process_cpu`.
- **Alerts:** Mimir ruler / Alertmanager (`alertmanager.monlab.newt.cz` or `karma`).

`make verify` runs an automated check of all of the above.

## Common tasks
| Task | Command |
|---|---|
| Rebuild + redeploy an app | `make images sideload && kubectl -n sre-challenge rollout restart deploy/sre-back` |
| Re-push dashboards/alerts | `make observability` (idempotent hook Job) |
| Scale a service | `kubectl -n sre-challenge scale deploy/sre-reader --replicas=2` |
| Toggle a service off | `helm upgrade sre chart/sre-apps -n sre-challenge --set reader.enabled=false` |
| Enable NetworkPolicy | `helm upgrade … --set reader.networkPolicy.enabled=true` (then verify probes) |
| Inspect Kafka topic | `kubectl -n sre-challenge exec sre-kafka-kafka-0 -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic testCommand` |
| Postgres psql | `kubectl -n sre-challenge exec -it sre-postgres-1 -- psql -U appuser -d appdb` |

## Troubleshooting
- **App pod not Ready / CrashLoop**
  `kubectl -n sre-challenge logs deploy/sre-back | tail` (logs are JSON — pipe to `jq`). Reader uses
  `ddl-auto=validate`, so it needs Back to have created `test_entity` first; it self-heals via
  restarts on a fresh cluster.
- **No metrics for a service** — check the pod has `k8s.grafana.com/scrape=true` and
  `…/metrics.portNumber=8081`; confirm `curl <pod>:8081/prometheus` returns text; check
  `count(up{namespace="sre-challenge"})` in Mimir.
- **No traces in Tempo** — the shared `alloy-receiver`→Tempo export is broken; the agent must point
  at `tempo-monolith.global-monitor-tempo:4317` directly (see `chart/java-app/values.yaml`
  `telemetry.traces.endpoint`). Verify: `otelcol`/agent logs show no export errors and
  `{ resource.service.name="sre-front" }` returns traces.
- **High consumer lag** — `KafkaConsumerLagHigh` fires; check Back is Running and the
  `kafka_consumergroup_lag{topic="testCommand"}` series; Back uses `concurrency=2` consumers.
- **Dashboards show "No data"** — datasource must be Mimir (`global-monitor-mimir-server`); the
  `assemble-dashboards.sh` step pins it. Re-run `make observability`.

## Teardown
```bash
make clean     # remove the apps + monitor-tools (keep operators/data)
make destroy   # remove everything incl. operators and the namespace
```

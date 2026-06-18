#!/usr/bin/env bash
# Exercise the pipeline and assert that all four observability pillars have data.
set -uo pipefail
NS="${NS:-sre-challenge}"
G="${GRAFANA_URL:-https://grafana.monlab.newt.cz}"
GA="${GRAFANA_AUTH:-admin:CHANGEME}"
DS_MIMIR=global-monitor-mimir-server; DS_LOKI=global-monitor-loki-server; DS_TEMPO=global-monitor-tempo-server
pass(){ echo "  ✓ $*"; }; fail(){ echo "  ✗ $*"; }
gq(){ curl -s -u "$GA" -G "$G/api/datasources/proxy/uid/$1/api/v1/query" --data-urlencode "query=$2" | jq -r "${3:-.data.result[0].value[1] // \"0\"}"; }

echo "== pipeline (Front -> Kafka -> Back -> Postgres -> Reader) =="
kubectl -n "$NS" run verify-load --image=curlimages/curl:8.11.0 --restart=Never --rm -i --quiet \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"v","image":"curlimages/curl:8.11.0","command":["sh","-c","for i in 1 2 3 4 5; do curl -s -o /dev/null -XPOST http://sre-front:8080/api/v1/command -H \"Content-Type: application/json\" -d \"{\\\"message\\\":\\\"verify-$i\\\",\\\"loadFront\\\":1,\\\"loadBack\\\":20}\"; done; sleep 6; curl -s \"http://sre-reader:8084/api/v1/testEntity?size=1\" | head -c 200"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' 2>/dev/null | grep -q totalElements && pass "Reader returns persisted rows" || fail "Reader returned no data"
sleep 8

echo "== metrics (Mimir) =="
[ "$(gq $DS_MIMIR 'count(count by (job)(up{namespace="'"$NS"'"}))')" -ge 4 ] 2>/dev/null && pass "apps+kafka+postgres jobs scraped" || fail "metrics jobs missing"
[ "$(gq $DS_MIMIR 'count(jvm_memory_used_bytes{namespace="'"$NS"'"})')" -gt 0 ] 2>/dev/null && pass "JVM metrics present" || fail "no JVM metrics"
[ "$(gq $DS_MIMIR 'count(kafka_consumergroup_lag)')" -gt 0 ] 2>/dev/null && pass "kafka consumer-lag metrics present" || fail "no kafka lag metrics"

echo "== logs (Loki) =="
curl -s -u "$GA" "$G/api/datasources/proxy/uid/$DS_LOKI/loki/api/v1/label/namespace/values" | jq -e '.data | index("'"$NS"'")' >/dev/null 2>&1 && pass "logs indexed for namespace" || fail "no logs in Loki"

echo "== traces (Tempo) =="
TID=$(curl -s -u "$GA" -G "$G/api/datasources/proxy/uid/$DS_TEMPO/api/search" --data-urlencode 'q={ resource.service.name="sre-front" } >> { resource.service.name="sre-back" }' --data-urlencode 'limit=1' | jq -r '.traces[0].traceID // empty')
[ -n "$TID" ] && pass "connected Front->Kafka->Back trace ($TID)" || fail "no connected trace"

echo "== profiles (Pyroscope) =="
kubectl -n "$NS" run verify-prof --image=curlimages/curl:8.11.0 --restart=Never --rm -i --quiet \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"v","image":"curlimages/curl:8.11.0","command":["sh","-c","curl -s -G http://pyroscope.global-monitor-pyroscope:4040/pyroscope/render --data-urlencode \"query=process_cpu:cpu:nanoseconds:cpu:nanoseconds{service_name=\\\"sre-back\\\"}\" --data-urlencode from=now-30m --data-urlencode until=now"],"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' 2>/dev/null | grep -q flamebearer && pass "Pyroscope has CPU profiles for sre-back" || fail "no profiles"

echo "done."

#!/usr/bin/env bash
# Normalise dashboards (pin datasource placeholders to the monlab Mimir/__expr__
# UIDs, strip grafana.com __inputs) and stage them into the monitor-tools chart.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_COMMUNITY="$ROOT/observability/dashboards"
RAW_MIXIN="$ROOT/observability/mixin/dashboards"
OUT="$ROOT/monitor-tools/dashboards"
DS_PROM="${DS_PROM:-global-monitor-mimir-server}"   # Mimir (prometheus) datasource uid
DS_EXPR="__expr__"                                   # Grafana built-in expression ds
mkdir -p "$OUT"; rm -f "$OUT"/*.json

norm() {  # $1=src $2=dst  -> pin datasources, drop __inputs, compact
  sed -e "s/\${DS_PROMETHEUS}/$DS_PROM/g" \
      -e "s/\${DS_EXPRESSION}/$DS_EXPR/g" \
      -e "s/\${datasource}/$DS_PROM/g" \
      -e "s/\${DS_LOKI}/global-monitor-loki-server/g" \
      "$1" \
  | jq -c 'del(.__inputs,.__requires) | .id=null
           | (.templating.list[]? | select(.type=="datasource") | .current)
               |= {text:"mimir-monolith", value:"'"$DS_PROM"'", selected:true}' \
  > "$2"
  jq -e . "$2" >/dev/null && echo "  staged $(basename "$2") ($(jq -r .title "$2"))"
}

# Filenames are prefixed "<folder>__" so the push Job can fan them into per-folder
# Grafana folders (kafka / postgres / javaapp).
echo "== community dashboards =="
[ -f "$RAW_COMMUNITY/kafka-exporter.json" ] && norm "$RAW_COMMUNITY/kafka-exporter.json" "$OUT/kafka__kafka-exporter.json"
[ -f "$RAW_COMMUNITY/kafka-broker.json" ]   && norm "$RAW_COMMUNITY/kafka-broker.json"   "$OUT/kafka__kafka-broker.json"
[ -f "$RAW_COMMUNITY/postgres-cnpg.json" ]  && norm "$RAW_COMMUNITY/postgres-cnpg.json"  "$OUT/postgres__postgres-cnpg.json"

echo "== jvm mixin dashboards =="
if [ -d "$RAW_MIXIN" ]; then
  for f in "$RAW_MIXIN"/*.json; do
    [ -f "$f" ] && norm "$f" "$OUT/javaapp__$(basename "$f")"
  done
else
  echo "  (mixin not rendered yet)"
fi
echo "staged $(ls -1 "$OUT"/*.json 2>/dev/null | wc -l) dashboards into $OUT"

# ---- alert rules (one Mimir rule-group per file) ----
RULES_OUT="$ROOT/monitor-tools/rules"
mkdir -p "$RULES_OUT"; rm -f "$RULES_OUT"/*.yaml
echo "== alert rule groups =="
for f in "$ROOT"/observability/alerts/*-alerts.yaml; do
  [ -f "$f" ] && cp "$f" "$RULES_OUT/" && echo "  staged $(basename "$f") (group=$(yq '.name' "$f"))"
done
# Convert the jvm-observ-lib mixin alerts (groups: format) into a single-group file.
MIXIN_ALERTS="$ROOT/observability/mixin/alerts.yaml"
if [ -f "$MIXIN_ALERTS" ]; then
  yq '.groups[0]' "$MIXIN_ALERTS" > "$RULES_OUT/jvm-alerts.yaml"
  echo "  staged jvm-alerts.yaml (group=$(yq '.name' "$RULES_OUT/jvm-alerts.yaml"))"
fi
echo "staged $(ls -1 "$RULES_OUT"/*.yaml 2>/dev/null | wc -l) rule groups into $RULES_OUT"

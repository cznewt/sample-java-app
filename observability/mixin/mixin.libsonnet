// JVM observability mixin for the SRE-challenge Spring Boot apps.
//
// The apps (sre-front, sre-back, sre-reader) expose Micrometer Prometheus
// metrics via micrometer-registry-prometheus, so the metric source is
// `java_micrometer`. Each app is identified by the `job` label and lives in
// namespace="sre-challenge".
//
// This file imports the upstream grafana/jsonnet-libs/jvm-observ-lib, configures
// it for the metrics context above and exposes both the Grafana dashboards and
// the Prometheus alert rules.
local jvmlib = import 'jvm-observ-lib/main.libsonnet';

local jvm =
  jvmlib.new()
  + jvmlib.withConfigMixin(
    {
      // Scope every query / alert to the SRE-challenge Spring Boot apps.
      filteringSelector: 'job=~"sre-.*", namespace="sre-challenge"',
      // Each app is one "group" (sre-front / sre-back / sre-reader).
      groupLabels: ['job'],
      // Each replica/pod is one "instance".
      instanceLabels: ['instance'],
      // Dashboard uid prefix + tags.
      uid: 'sre-jvm',
      dashboardNamePrefix: 'SRE ',
      dashboardTags: ['java', 'jvm', 'sre-challenge', 'spring-boot'],
      // Micrometer Prometheus registry (Spring Boot). NOT jmx_exporter, NOT otel.
      // Passed as a string so the lib's string-equality checks (which gate the
      // Hikari connection-pool and Logback rows) are satisfied as well.
      metricsSource: 'java_micrometer',
      // Warn when JVM heap is >80% full.
      alertHeapWarning: 80,
    }
  );

{
  // Map of "<name>.json" -> Grafana dashboard object.
  grafanaDashboards:: jvm.grafana.dashboards,
  // Prometheus alerting rules ({ groups: [...] }).
  prometheusAlerts:: jvm.prometheus.alerts,
  // Convenience: the full monitoring-mixin shape.
  mixin:: jvm.asMonitoringMixin(),
}

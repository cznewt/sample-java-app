// Renders the Prometheus alert rules as YAML.
// `jsonnet -S` emits the resulting string verbatim, so we manifest the
// alerts object ({ groups: [...] }) to YAML here.
std.manifestYamlDoc((import 'mixin.libsonnet').prometheusAlerts)

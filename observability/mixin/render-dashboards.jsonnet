// Multi-file output wrapper for `jsonnet -S -m <outdir>`.
// Emits one entry per dashboard: key = output filename, value = pretty JSON
// string of the Grafana dashboard object. With `-S -m <dir>` jsonnet writes
// each string value to <dir>/<key>.
local dashboards = (import 'mixin.libsonnet').grafanaDashboards;
{
  [name]: std.manifestJsonEx(dashboards[name], '  ')
  for name in std.objectFields(dashboards)
}

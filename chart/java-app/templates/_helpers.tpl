{{/* When used as an aliased subchart, .Chart.Name is the alias (front/back/reader). */}}
{{- define "java-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "java-app.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "java-app.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "java-app.labels" -}}
app.kubernetes.io/name: {{ include "java-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .Values.appName | quote }}
app.kubernetes.io/part-of: sre-challenge
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "java-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "java-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "java-app.image" -}}
{{- $reg := .Values.image.registry | default .Values.global.image.registry -}}
{{- $tag := .Values.image.tag | default .Values.global.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" $reg .Values.image.repository $tag -}}
{{- end -}}

{{- define "java-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- include "java-app.fullname" . -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{- define "meshmart.labels" -}}
app.kubernetes.io/part-of: meshmart
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Labels on every object's metadata. The first two are what kustomization.yaml
added; the rest are Helm's standard set.
*/}}
{{- define "mini-app-service.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/part-of: mini-apps
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
Selector labels. Exactly the pre-Helm `app: <name>` and nothing more:
spec.selector is immutable, so adding a label here would make every upgrade of
an adopted Deployment fail.
*/}}
{{- define "mini-app-service.selectorLabels" -}}
app: {{ .Release.Name }}
{{- end }}

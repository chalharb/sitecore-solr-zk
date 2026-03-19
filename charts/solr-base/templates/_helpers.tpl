{{/*
Common helpers for sitecore-solr charts.
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "solr-base.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully qualified release name.
We truncate at 63 chars because some Kubernetes name fields are limited to this.
*/}}
{{- define "solr-base.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "solr-base.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: sitecore-solr
helm.sh/chart: {{ include "solr-base.name" . }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
ZooKeeper resource name.
*/}}
{{- define "solr-base.zookeeperName" -}}
{{- printf "%s-zookeeper" (include "solr-base.fullname" .) }}
{{- end }}

{{/*
SolrCloud resource name.
*/}}
{{- define "solr-base.solrcloudName" -}}
{{- printf "%s-solr" (include "solr-base.fullname" .) }}
{{- end }}

{{/*
ZooKeeper client service DNS name (created by the ZK operator).
Pattern: <zkcluster-name>-client.<namespace>.svc.cluster.local
*/}}
{{- define "solr-base.zkConnectionString" -}}
{{- printf "%s-client:2181" (include "solr-base.zookeeperName" .) }}
{{- end }}

{{/*
Namespace to deploy into.
*/}}
{{- define "solr-base.namespace" -}}
{{- default .Release.Namespace .Values.global.namespace }}
{{- end }}

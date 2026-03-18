{{/*
Expand the chart name.
*/}}
{{- define "sitecore-solr.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "sitecore-solr.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: sitecore-solr
{{- end }}

{{/*
ZooKeeper headless service FQDN list for ZOO_SERVERS.
Produces one entry per replica:
  server.1=<release>-zookeeper-0.<release>-zookeeper.<ns>.svc.cluster.local:2888:3888;2181
*/}}
{{- define "sitecore-solr.zkServers" -}}
{{- $releaseName := .Release.Name -}}
{{- $ns := .Values.namespace -}}
{{- $servers := list -}}
{{- range $i, $e := until (int .Values.zookeeper.replicaCount) -}}
  {{- $id := add $i 1 -}}
  {{- $host := printf "%s-zookeeper-%d.%s-zookeeper.%s.svc.cluster.local" $releaseName $i $releaseName $ns -}}
  {{- $servers = append $servers (printf "server.%d=%s:2888:3888;2181" $id $host) -}}
{{- end -}}
{{- join " " $servers }}
{{- end }}

{{/*
ZooKeeper client connection string (all nodes, comma-separated).
*/}}
{{- define "sitecore-solr.zkHost" -}}
{{- $releaseName := .Release.Name -}}
{{- $ns := .Values.namespace -}}
{{- $hosts := list -}}
{{- range $i, $e := until (int .Values.zookeeper.replicaCount) -}}
  {{- $host := printf "%s-zookeeper-%d.%s-zookeeper.%s.svc.cluster.local:2181" $releaseName $i $releaseName $ns -}}
  {{- $hosts = append $hosts $host -}}
{{- end -}}
{{- join "," $hosts }}
{{- end }}

{{/*
Solr endpoint used by the init job.
*/}}
{{- define "sitecore-solr.solrEndpoint" -}}
{{- printf "http://%s-solr.%s.svc.cluster.local:8983/solr" .Release.Name .Values.namespace }}
{{- end }}

{{/*
ConfigMap for collections.yml.
The collections file is read from the wrapper chart's files/ via .Files.Get.
*/}}

{{- define "solr-base.collectionsConfigMap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "solr-base.fullname" . }}-collections
  namespace: {{ include "solr-base.namespace" . }}
  labels:
    {{- include "solr-base.labels" . | nindent 4 }}
data:
  collections.yml: |
    {{- .Files.Get "settings/collections.yml" | nindent 4 }}
{{- end }}

{{/*
ConfigMaps for configset files.
Creates one ConfigMap per configset directory found under settings/configsets/.
Each ConfigMap contains all conf/ files for that configset.

This template must be called from the wrapper chart (not the library) because
.Files only has access to files within the calling chart's directory.
*/}}

{{- define "solr-base.configsetConfigMaps" -}}
{{- $root := . -}}
{{- $configsets := dict -}}
{{/* Discover configsets by globbing all files under settings/configsets/ */}}
{{- range $path, $_ := .Files.Glob "settings/configsets/*/conf/*" }}
  {{- $parts := splitList "/" $path -}}
  {{/* parts: [settings, configsets, <name>, conf, <filename>] */}}
  {{- $csName := index $parts 2 -}}
  {{- $fileName := index $parts 4 -}}
  {{- if not (hasKey $configsets $csName) }}
    {{- $_ := set $configsets $csName (dict) -}}
  {{- end }}
  {{- $_ := set (index $configsets $csName) $fileName $path -}}
{{- end }}
{{- range $csName, $files := $configsets }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "solr-base.fullname" $root }}-configset-{{ $csName }}
  namespace: {{ include "solr-base.namespace" $root }}
  labels:
    {{- include "solr-base.labels" $root | nindent 4 }}
    app.kubernetes.io/component: configset
    solr.configset: {{ $csName }}
data:
  {{- range $fileName, $filePath := $files }}
  {{ $fileName }}: |
    {{- $root.Files.Get $filePath | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}

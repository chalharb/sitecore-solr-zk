{{/*
ZookeeperCluster custom resource.
Deployed as a standalone CR managed by the Pravega ZooKeeper Operator.
*/}}

{{- define "solr-base.zookeeperCluster" -}}
apiVersion: zookeeper.pravega.io/v1beta1
kind: ZookeeperCluster
metadata:
  name: {{ include "solr-base.zookeeperName" . }}
  namespace: {{ include "solr-base.namespace" . }}
  labels:
    {{- include "solr-base.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.zookeeper.replicas }}
  image:
    repository: {{ .Values.zookeeper.image.repository }}
    tag: {{ .Values.zookeeper.image.tag | quote }}
    pullPolicy: {{ .Values.zookeeper.image.pullPolicy }}
  {{- if .Values.zookeeper.storage.storageClass }}
  storageType: persistence
  persistence:
    reclaimPolicy: {{ .Values.zookeeper.storage.reclaimPolicy }}
    spec:
      storageClassName: {{ .Values.zookeeper.storage.storageClass | quote }}
      resources:
        requests:
          storage: {{ .Values.zookeeper.storage.size }}
  {{- else }}
  storageType: persistence
  persistence:
    reclaimPolicy: {{ .Values.zookeeper.storage.reclaimPolicy }}
    spec:
      resources:
        requests:
          storage: {{ .Values.zookeeper.storage.size }}
  {{- end }}
  pod:
    resources:
      requests:
        cpu: {{ .Values.zookeeper.resources.requests.cpu | quote }}
        memory: {{ .Values.zookeeper.resources.requests.memory | quote }}
      limits:
        cpu: {{ .Values.zookeeper.resources.limits.cpu | quote }}
        memory: {{ .Values.zookeeper.resources.limits.memory | quote }}
  config:
    initLimit: 10
    tickTime: 2000
    syncLimit: 5
{{- end }}

{{/*
SolrCloud custom resource.
Managed by the Apache Solr Operator. Connects to the standalone ZookeeperCluster
via connectionInfo.
*/}}

{{- define "solr-base.solrCloud" -}}
apiVersion: solr.apache.org/v1beta1
kind: SolrCloud
metadata:
  name: {{ include "solr-base.solrcloudName" . }}
  namespace: {{ include "solr-base.namespace" . }}
  labels:
    {{- include "solr-base.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.solr.replicas }}
  solrImage:
    repository: {{ .Values.solr.image.repository }}
    tag: {{ .Values.solr.image.tag | quote }}
    pullPolicy: {{ .Values.solr.image.pullPolicy }}
  solrJavaMem: {{ .Values.solr.javaMem | quote }}

  # Connect to the standalone ZookeeperCluster
  zookeeperRef:
    connectionInfo:
      externalConnectionString: {{ include "solr-base.zkConnectionString" . | quote }}
      chroot: "/solr"

  # Basic auth — operator bootstraps security.json automatically.
  # Credentials are stored in secret: <solrcloud-name>-solrcloud-security-bootstrap
  # The setup Job changes the admin password post-bootstrap.
  solrSecurity:
    authenticationType: Basic
    probesRequireAuth: false

  # Data storage
  dataStorage:
    persistent:
      reclaimPolicy: {{ .Values.solr.storage.reclaimPolicy }}
      pvcTemplate:
        spec:
          {{- if .Values.solr.storage.storageClass }}
          storageClassName: {{ .Values.solr.storage.storageClass | quote }}
          {{- end }}
          resources:
            requests:
              storage: {{ .Values.solr.storage.size }}

  # Pod resources
  customSolrKubeOptions:
    podOptions:
      resources:
        requests:
          cpu: {{ .Values.solr.resources.requests.cpu | quote }}
          memory: {{ .Values.solr.resources.requests.memory | quote }}
        limits:
          cpu: {{ .Values.solr.resources.limits.cpu | quote }}
          memory: {{ .Values.solr.resources.limits.memory | quote }}

  # Update strategy
  updateStrategy:
    method: Managed
    managed:
      maxPodsUnavailable: 1

  # Addressability
  solrAddressability:
    podPort: 8983
    commonServicePort: 80
{{- end }}

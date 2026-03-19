{{/*
Kubernetes Job that uploads configsets to ZooKeeper and creates collections
in Solr. Runs once after both ZK and SolrCloud are deployed.

The Job uses the solr:8.11.2 image which includes the `solr zk` CLI and curl.

Authentication: The Solr Operator bootstraps security.json and stores the
generated admin password in a secret. This Job reads that password to
authenticate API calls, then optionally changes it to the desired password.
*/}}

{{- define "solr-base.setupJob" -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "solr-base.fullname" . }}-setup
  namespace: {{ include "solr-base.namespace" . }}
  labels:
    {{- include "solr-base.labels" . | nindent 4 }}
    app.kubernetes.io/component: setup
  annotations:
    # Allow re-running: delete the old Job first, then helm upgrade
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  backoffLimit: 10
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        {{- include "solr-base.labels" . | nindent 8 }}
        app.kubernetes.io/component: setup
    spec:
      restartPolicy: OnFailure
      serviceAccountName: {{ include "solr-base.fullname" . }}-setup
      containers:
        - name: setup
          image: "{{ .Values.setupJob.image.repository }}:{{ .Values.setupJob.image.tag }}"
          command: ["/bin/bash", "/scripts/setup.sh"]
          env:
            - name: ZK_HOST
              value: {{ include "solr-base.zkConnectionString" . | quote }}
            - name: SOLR_HOST
              value: "http://{{ include "solr-base.solrcloudName" . }}-solrcloud-common"
            - name: SOLR_ADMIN_USER
              value: "admin"
            - name: SOLR_BOOTSTRAP_SECRET
              value: {{ include "solr-base.solrcloudName" . }}-solrcloud-security-bootstrap
            - name: DESIRED_ADMIN_PASSWORD
              value: {{ .Values.solr.auth.adminPassword | quote }}
            - name: REPLICA_OVERRIDE
              value: {{ .Values.collections.replicaOverride | quote }}
            - name: CONFIGSETS_DIR
              value: "/configsets"
            - name: COLLECTIONS_FILE
              value: "/collections/collections.yml"
          volumeMounts:
            - name: setup-script
              mountPath: /scripts
              readOnly: true
            - name: collections
              mountPath: /collections
              readOnly: true
            {{- range .Values.configsetNames }}
            - name: configset-{{ . }}
              mountPath: /configsets/{{ . }}/conf
              readOnly: true
            {{- end }}
      volumes:
        - name: setup-script
          configMap:
            name: {{ include "solr-base.fullname" . }}-setup-script
            defaultMode: 0755
        - name: collections
          configMap:
            name: {{ include "solr-base.fullname" . }}-collections
        {{- range .Values.configsetNames }}
        - name: configset-{{ . }}
          configMap:
            name: {{ include "solr-base.fullname" $ }}-configset-{{ . }}
        {{- end }}
{{- end }}

{{/*
ConfigMap containing the setup.sh script.
*/}}
{{- define "solr-base.setupScriptConfigMap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "solr-base.fullname" . }}-setup-script
  namespace: {{ include "solr-base.namespace" . }}
  labels:
    {{- include "solr-base.labels" . | nindent 4 }}
data:
  setup.sh: |
    {{- .Files.Get "scripts/setup.sh" | nindent 4 }}
{{- end }}

{{/*
ServiceAccount and RBAC for the setup Job.
Needs permission to read the bootstrap secret created by the Solr Operator.
*/}}
{{- define "solr-base.setupRbac" -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "solr-base.fullname" . }}-setup
  namespace: {{ include "solr-base.namespace" . }}
  labels:
    {{- include "solr-base.labels" . | nindent 4 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "solr-base.fullname" . }}-setup
  namespace: {{ include "solr-base.namespace" . }}
  labels:
    {{- include "solr-base.labels" . | nindent 4 }}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["{{ include "solr-base.solrcloudName" . }}-solrcloud-security-bootstrap"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "solr-base.fullname" . }}-setup
  namespace: {{ include "solr-base.namespace" . }}
  labels:
    {{- include "solr-base.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "solr-base.fullname" . }}-setup
subjects:
  - kind: ServiceAccount
    name: {{ include "solr-base.fullname" . }}-setup
    namespace: {{ include "solr-base.namespace" . }}
{{- end }}

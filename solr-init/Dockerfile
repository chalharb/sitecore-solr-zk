# solr-init — one-shot container that runs as a Kubernetes Job after SolrCloud
# is ready. It uploads configsets (zipped at build time) to Solr via the Config
# Sets API, then creates all collections defined in collections.yml (mounted as
# a ConfigMap at runtime). Configsets are baked into the image so each build is
# a versioned, reproducible artifact. The job is fully idempotent — existing
# configsets and collections are skipped.
#
# Build from repo root:  docker build -f solr-init/Dockerfile -t solr-init:local .

FROM alpine:3.19

RUN apk add --no-cache curl bash zip yq

WORKDIR /init

# Copy configset source (stays unzipped in repo for readability/diffs)
COPY settings/configsets/sitecore ./configsets/sitecore
COPY settings/configsets/hut      ./configsets/hut

# Zip at build time — Solr Config Sets API requires a zip
RUN zip -r /init/sitecore.zip ./configsets/sitecore/conf \
 && zip -r /init/hut.zip      ./configsets/hut/conf

COPY solr-init/init.sh /init/init.sh
RUN chmod +x /init/init.sh

ENTRYPOINT ["/init/init.sh"]

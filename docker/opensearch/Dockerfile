# OpenSearch + analysis-ik plugin for the OCTO message-search pipeline
# (octo-deployment search profile). The es-indexer index mapping uses the IK
# analyzers (ik_max_word on the index side, ik_smart on the query side), so the
# plugin MUST be installed in the OpenSearch image, and its version MUST match
# the OpenSearch version. Both are pinned via the build arg below; keep them in
# lockstep with octo-search-indexer/harness/opensearch-ik.Dockerfile.
ARG OPENSEARCH_VERSION=2.17.0
FROM opensearchproject/opensearch:${OPENSEARCH_VERSION}

ARG OPENSEARCH_VERSION=2.17.0
# infinilabs hosts analysis-ik builds for OpenSearch.
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch \
    https://release.infinilabs.com/analysis-ik/stable/opensearch-analysis-ik-${OPENSEARCH_VERSION}.zip

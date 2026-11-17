ARG RUNNER_VERSION=2.338.2
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

# Tools ubuntu-latest has that the base image lacks.
# build-essential: cgo for `go test -race`; make: Makefile targets; xz-utils: setup-node tarballs;
# iptables: the in-container dockerd (the base image already ships dockerd/containerd/runc).
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential make xz-utils zstd ca-certificates iptables \
 && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 entrypoint.sh cleanup.sh /

USER runner
ENTRYPOINT ["/entrypoint.sh"]

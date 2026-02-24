# -----------------------------
# Stage 1 — Build UI
# -----------------------------
FROM node:20-bookworm AS ui-build
WORKDIR /src

COPY ui-svelte/package*.json ./ui-svelte/
RUN cd ui-svelte && npm install

COPY ui-svelte/ ./ui-svelte/
RUN cd ui-svelte && npm run build && ls -la && pwd && ls -la ../proxy/ui_dist/ 

# Find UI output directory by locating index.html (Vite/Svelte/etc.)
# Store it in /ui_out for easy copying later.
# RUN set -eux; \
#     # Common candidates first (fast path)
#     for d in dist build public out .svelte-kit/output/client .output/public; do \
#       if [ -f "ui-svelte/$d/index.html" ]; then \
#         mkdir -p /ui_out; \
#         cp -a "ui-svelte/$d/." /ui_out/; \
#         exit 0; \
#       fi; \
#     done; \
#     # Generic fallback: search for index.html (ignore node_modules)
#     out_dir="$(find ui-svelte -type f -name index.html -not -path '*/node_modules/*' -print -quit | xargs -r dirname)"; \
#     if [ -n "${out_dir:-}" ] && [ -d "$out_dir" ]; then \
#       mkdir -p /ui_out; \
#       cp -a "$out_dir/." /ui_out/; \
#       exit 0; \
#     fi; \
#     echo "ERROR: Could not locate UI build output (index.html not found)."; \
#     echo "Top-level of ui-svelte:"; ls -la ui-svelte; \
#     echo "Dirs (depth 3, excluding node_modules):"; find ui-svelte -maxdepth 3 -type d -not -path '*/node_modules*' -print; \
#     exit 1


# -----------------------------
# Stage 2 — Build Go binaries (Ubuntu, runs on BUILDPLATFORM)
# -----------------------------
FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS go-build
WORKDIR /src

ARG DEBIAN_FRONTEND=noninteractive
ARG GO_VERSION=1.25.4

# buildx args (or defaults for classic build)
ARG BUILDARCH
ARG TARGETOS=linux
ARG TARGETARCH=arm64

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl git && \
    rm -rf /var/lib/apt/lists/*

# Install Go for BUILD architecture (must execute during build)
RUN set -eux; \
    arch="${BUILDARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64) GOARCH_DL=amd64 ;; \
      arm64) GOARCH_DL=arm64 ;; \
      *) echo "Unsupported BUILDARCH=$arch"; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH_DL}.tar.gz" -o /tmp/go.tgz; \
    rm -rf /usr/local/go; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm -f /tmp/go.tgz

ENV PATH="/usr/local/go/bin:${PATH}"

ARG COMMIT=unknown
ARG VERSION=local
ARG BUILD_DATE=unknown

COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Copy detected UI output into proxy/ui_dist
COPY --from=ui-build /src/proxy/ui_dist ./proxy/ui_dist

# Build llama-swap
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -ldflags="-s -w \
        -X main.date=${BUILD_DATE}" \
      -o /out/llama-swap \
      .

# Build simple-responder (optional)
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -ldflags="-s -w" \
      -o /out/simple-responder \
      ./cmd/simple-responder/simple-responder.go


# -----------------------------
# Stage 3 — Runtime (Ubuntu)
# -----------------------------
FROM ghcr.io/pontostroy/llama.cpp:full-cuda13
WORKDIR /app

COPY --from=go-build /out/llama-swap /usr/local/bin/llama-swap
COPY --from=go-build /out/simple-responder /usr/local/bin/simple-responder

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/llama-swap"]

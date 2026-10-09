# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh): build the whole monorepo from source, then keep the
# prepared workspace (sources + node_modules + built artifacts) in a runtime
# image that boots the Web profile.
#
#   docker build -t dsh-docker --build-arg DSH_REF=<branch|tag|sha> .
#   docker run --rm --network host -v dsh-home:/data ghcr.io/<owner>/dsh-docker

# ---------------------------------------------------------------------------
# Stage 1 — builder
# ---------------------------------------------------------------------------
FROM node:24-bookworm AS builder

# node:24-bookworm is based on buildpack-deps and already ships git, gcc, make
# and python3 — everything `pnpm install` and the native addon build need.
ARG DSH_REPOSITORY=https://github.com/deepseek-ai/deepseek-harness.git
ARG DSH_REF=master

ENV CI=1 \
    PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH

# package.json pins "packageManager": "pnpm@11.7.0".
RUN npm install --global pnpm@11.7.0 && pnpm --version

WORKDIR /src

# Fetch exactly the requested ref (branch, tag or full SHA). The workflow passes
# a commit SHA so a scheduled build is pinned to the commit it resolved.
RUN set -eux; \
    git init -q; \
    git remote add origin "${DSH_REPOSITORY}"; \
    git fetch --depth 1 origin "${DSH_REF}"; \
    git checkout -q --detach FETCH_HEAD

# BuildKit cache mount so daily rebuilds reuse the pnpm store.
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --store-dir=/pnpm/store

# build:official = native-system + host tsc/tsdown + client tsc/tsdown + web frontend.
RUN pnpm run build:official

# ---------------------------------------------------------------------------
# Stage 2 — runtime
# ---------------------------------------------------------------------------
FROM node:24-bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git tini \
    && rm -rf /var/lib/apt/lists/*

# Keep the whole prepared workspace: the CLI runs the TypeScript entry through
# tsx and resolves workspace packages through node_modules.
COPY --from=builder /src /app

WORKDIR /app

ENV DSH_HOME=/data
RUN mkdir -p /data
VOLUME ["/data"]

# Loopback-only listener inside the container; use `--network host` to reach it.
EXPOSE 3080

ENTRYPOINT ["tini", "--", "node", "--import", "tsx/esm", "apps/cli/src/bin.ts"]
CMD ["web", "--no-open"]

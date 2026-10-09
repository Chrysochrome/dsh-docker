# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh): build the whole monorepo from source, then keep the
# prepared workspace (sources + node_modules + built artifacts) in a runtime
# image that boots the Web profile.
#
#   docker build -t dsh-docker --build-arg DSH_REF=<branch|tag|sha> .
#   docker run --rm -p 127.0.0.1:3080:3080 -v "$PWD/dsh-home:/data" -v "$PWD/projects:/workspace" ghcr.io/<owner>/dsh-docker

# ---------------------------------------------------------------------------
# Stage 1 — builder
# ---------------------------------------------------------------------------
FROM node:24-bookworm AS builder

# node:24-bookworm is based on buildpack-deps and already ships git, gcc, make
# and python3 — everything `pnpm install` and the native addon build need.
ARG DSH_REPOSITORY=https://github.com/deepseek-ai/deepseek-harness.git
ARG DSH_REF=master

ENV CI=1

WORKDIR /src

# Fetch exactly the requested ref (branch, tag or full SHA). The workflow passes
# a commit SHA so a scheduled build is pinned to the commit it resolved.
RUN set -eux; \
    git init -q; \
    git remote add origin "${DSH_REPOSITORY}"; \
    git fetch --depth 1 origin "${DSH_REF}"; \
    git checkout -q --detach FETCH_HEAD

# The webserver supports all-interface binding, but the upstream CLI rejects
# that address. Container users control exposure through Docker port mapping.
# Remove only this CLI guard; fail the build if upstream changes its shape.
RUN node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
const path = 'packages/bundle/web-app/src/startup.ts';
const source = readFileSync(path, 'utf8');
const guard = /    if \(options\.host === '0\.0\.0\.0'\) \{\r?\n      program\.error\('error: --host 0\.0\.0\.0 is intentionally not supported yet for safety: it would expose remote code execution to the network; use 127\.0\.0\.1 instead'\)\r?\n    \}\r?\n/g;
if ([...source.matchAll(guard)].length !== 1) {
  throw new Error('Upstream --host guard changed; review the Docker listener patch');
}
writeFileSync(path, source.replace(guard, ''));
JS

# Install the *exact* pnpm the repo pins in its "packageManager" field. This
# mirrors upstream CI, which lets pnpm/action-setup read the same field. Using
# the pinned version matters: the workspace uses version-sensitive config
# (allowBuilds, minimumReleaseAge/minimumReleaseAgeExclude, lockfile format)
# that older pnpm releases do not understand.
RUN set -eux; \
    version="$(node -p "require('./package.json').packageManager.replace(/^pnpm@/, '').split('+')[0]")"; \
    echo "installing pnpm@${version} (from package.json packageManager)"; \
    npm install --global "pnpm@${version}"; \
    pnpm --version

# BuildKit cache mount so daily rebuilds reuse the pnpm store.
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile --store-dir=/pnpm/store

# build:official = native-system + host tsc/tsdown + client tsc/tsdown + web frontend.
RUN pnpm run build:official

# ---------------------------------------------------------------------------
# Stage 2 — runtime
# ---------------------------------------------------------------------------
FROM node:24-bookworm-slim AS runtime

# libstdc++6: the prebuilt `node-addon-require-builtin` binding is a C++ addon
# whose release pipeline verifies a `GLIBCXX_3.4.25` floor and a declared
# `libstdc++.so.6` dependency. The slim image keeps it only because Node itself
# links it, so install it explicitly rather than relying on that.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git tini libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# Keep the whole prepared workspace: the CLI runs the TypeScript entry through
# tsx and resolves workspace packages through node_modules.
COPY --from=builder /src /app

WORKDIR /app

# DSH_HOME is dsh's state root (credentials, profiles, settings, sessions,
# attachments). It defaults to ~/.dsh; here it is /data, declared as a volume so
# you can bind-mount a host directory onto it.
ENV DSH_HOME=/data
# The addon otherwise copies its binding to /tmp before dlopen(). A host may
# mount /tmp with noexec, which prevents loading that cached shared object.
# Load the installed, immutable prebuild directly from /app instead.
ENV NARB_DISABLE_NATIVE_CACHE=1
# The agent *workspace* is separate from DSH_HOME and is chosen in the Web UI.
# Bind-mount one in (e.g. -v /host/projects:/workspace) and add it in the UI.
# Keep the process rooted at /app so `tsx` resolves from /app/node_modules.
RUN mkdir -p /data /workspace
VOLUME ["/data"]

# Listen on the container interfaces so Docker can publish port 3080.
EXPOSE 3080

# Readiness probe. Any HTTP response means "up" — the startup URL carries a
# process token, so a 401/403 is still a healthy listener. If you launch with a
# non-default `--port`, export DSH_PORT to match so the probe keeps working.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.DSH_PORT||3080)+'/').then(()=>process.exit(0)).catch(()=>process.exit(1))"

# `web` is the documented shorthand for `--profile web`; `--no-open` skips the
# browser handoff (there is none in a container).
ENTRYPOINT ["tini", "--", "node", "--import", "tsx/esm", "/app/apps/cli/src/bin.ts"]
CMD ["web", "--host", "0.0.0.0", "--no-open"]

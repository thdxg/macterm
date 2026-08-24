# syntax=docker/dockerfile:1

# Container image for the marketing site and docs (see website/README.md).
#
# IMPORTANT: the build context is the REPOSITORY ROOT, not website/ —
#
#     docker build -f website/Dockerfile -t macterm-website .
#
# because website/public/assets is a symlink to the repo-root assets/ dir. A
# context rooted at website/ would copy that symlink dangling; the build stage
# below materializes it as real files instead. Dockerfile.dockerignore, beside
# this file, keeps the context to just website/ and assets/ — its patterns are
# relative to that root context, not to website/.
#
# Bun builds, Caddy serves. The site is static once `bun run build` has
# rendered the docs and compiled the CSS, so the runtime stage carries no
# JavaScript at all — no Bun, no node_modules, just Caddy and public/.

ARG BUN_IMAGE=oven/bun:1.3-alpine
ARG CADDY_IMAGE=caddy:2-alpine

# ---- deps: resolved once, cached until the lockfile moves -------------------
FROM ${BUN_IMAGE} AS deps
WORKDIR /app
COPY website/package.json website/bun.lock ./
RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install --frozen-lockfile

# ---- build: render docs/pages/*.md and compile Tailwind --------------------
FROM ${BUN_IMAGE} AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY website/ ./
# Replace the public/assets symlink (dangling in the image) with real files.
RUN rm -rf public/assets
COPY assets/ ./public/assets/
RUN bun run build

# ---- runtime ---------------------------------------------------------------
FROM ${CADDY_IMAGE} AS runtime

COPY website/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/public /srv

ENV PORT=3000 \
    SITE_ROOT=/srv

# Nothing is written at runtime: TLS is terminated upstream, and the Caddyfile
# turns off the admin API and config persistence.
USER 1000:1000
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -qO- "http://127.0.0.1:${PORT}/healthz" || exit 1

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]

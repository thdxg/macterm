# Container image for the marketing site and docs (see website/README.md).
#
# IMPORTANT: the build context is the REPOSITORY ROOT, not website/ —
#
#     podman build --format docker -f website/Containerfile -t macterm-website .
#
# because website/public/assets is a symlink to the repo-root assets/ dir. A
# context rooted at website/ would copy that symlink dangling; the build stage
# below materializes it as real files instead. The repo-root .containerignore
# keeps the context to just website/ and assets/.
#
# `--format docker` because the OCI image format has no HEALTHCHECK: podman's
# default would build the image and silently drop the one below.
#
# Bun builds, Caddy serves. The site is static once `bun run build` has
# rendered the docs and compiled the CSS, so the runtime stage carries no
# JavaScript at all — no Bun, no node_modules, just Caddy and public/.

# The base images are written out in each FROM, never passed through an ARG:
# Dependabot reads only literal `FROM image:tag` lines, so an image named by a
# variable is never tracked. They are fully qualified because podman resolves
# a short name through registries.conf, which errors without a TTY when more
# than one search registry is configured; Dependabot treats `docker.io/` as
# Docker Hub, so the qualification costs it nothing.

# ---- deps: resolved once, cached until the lockfile moves -------------------
FROM docker.io/oven/bun:1.3-alpine AS deps
WORKDIR /app
COPY website/package.json website/bun.lock ./
RUN --mount=type=cache,target=/root/.bun/install/cache \
    bun install --frozen-lockfile

# ---- build: render docs/pages/*.md and compile Tailwind --------------------
FROM docker.io/oven/bun:1.3-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY website/ ./
# Replace the public/assets symlink (dangling in the image) with real files.
RUN rm -rf public/assets
COPY assets/ ./public/assets/
RUN bun run build

# ---- runtime ---------------------------------------------------------------
FROM docker.io/library/caddy:2-alpine AS runtime

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

# syntax=docker/dockerfile:1.9
# ──────────────────────────────────────────────────────────────────────────────
# MiroFish image — multi-stage, slim, CPU-only Python/Node runtime.
#
# Stage 1 (backend-builder): resolve + download Python deps via uv into a
#   self-contained .venv. Uses the full python:3.11 image for toolchain parity.
# Stage 2 (frontend-builder): npm-install root + frontend deps on a tiny Node
#   image. Produces node_modules trees ready to copy.
# Stage 3 (runtime): python:3.11-slim, node/npm via apt (~50 MB), copy only the
#   .venv + node_modules + source. Runs dev-mode backend + frontend.
#
# Expected total size: ~1.5 GB (vs ~14 GB for the flat build). Savings come
# from:
#   - CPU-only torch wheels (see backend/pyproject.toml [[tool.uv.index]]) —
#     drops 4.3 GB of nvidia/* + shrinks torch from 1.7 GB → ~200 MB.
#   - python:3.11-slim replaces the 1.1 GB build-toolchain base.
#   - Builder stages aren't in the final image, so apt-get libssl-dev / g++ /
#     libpq-dev etc. don't get shipped.
# ──────────────────────────────────────────────────────────────────────────────

# ── Stage 1 — backend builder ────────────────────────────────────────────────
FROM python:3.11 AS backend-builder

COPY --from=ghcr.io/astral-sh/uv:0.9.26 /uv /uvx /bin/

WORKDIR /build/backend

# Copy lockfile + manifest first for build-cache reuse
COPY backend/pyproject.toml backend/uv.lock ./

# Resolve + download into /build/backend/.venv; frozen forbids lock drift.
# UV_COMPILE_BYTECODE=1 pre-compiles .pyc at install time so the runtime image
# doesn't pay that cost on every first-run.
ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy
RUN uv sync --frozen --no-install-project

# Copy the app package and install it (hatchling wheel of mirofish-backend)
COPY backend/app ./app
RUN uv sync --frozen

# ── Stage 2 — frontend builder ───────────────────────────────────────────────
FROM node:20-slim AS frontend-builder

WORKDIR /build

# Root workspace (concurrently, dev orchestration scripts)
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# Frontend app (Vite)
COPY frontend/package.json frontend/package-lock.json ./frontend/
RUN cd frontend && npm ci --no-audit --no-fund

# ── Stage 3 — runtime ────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

# Minimal runtime system libs:
#   - curl: healthcheck (curl -sf http://localhost:5001/health)
#   - nodejs + npm: run root `npm run dev` orchestrator + vite frontend
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        nodejs \
        npm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy Python venv (pre-resolved, pre-compiled) from backend builder
COPY --from=backend-builder /build/backend/.venv /app/backend/.venv
# Make `python` and installed scripts resolve from the venv without needing
# `uv run` at CMD time.
ENV PATH="/app/backend/.venv/bin:${PATH}"
ENV VIRTUAL_ENV="/app/backend/.venv"

# Copy Node dependency trees from frontend builder
COPY --from=frontend-builder /build/node_modules /app/node_modules
COPY --from=frontend-builder /build/frontend/node_modules /app/frontend/node_modules

# Finally copy the source tree (done last to maximize layer cache hits on dep
# stages during iterative dev).
COPY . .

EXPOSE 3000 5001

CMD ["npm", "run", "dev"]

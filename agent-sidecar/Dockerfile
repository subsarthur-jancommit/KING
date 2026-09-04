FROM python:3.11-slim

# System tools the MCP `vps_exec` shell needs to be worth anything: without
# git, curl and a docker client, a shell on this box can neither inspect the
# repo, reach the gateway, nor touch a container.
#
# `docker-cli` and not `docker.io`: the latter drags in the daemon and
# containerd for a container that only ever talks to a mounted socket. Version
# pinned rather than floating, per the same rule that pins every image tag in
# this repo — and placed before the dependency copy so the layer cache is not
# invalidated by a source edit.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git=1:2.* \
        curl=8.* \
        docker-cli=26.1.5+dfsg1-9+deb13u1 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

# Run as a non-root user. This image executes model-generated Python via
# smolagents' CodeAgent (see src/agent_sidecar/smol_runner.py), so the process
# should not hold root inside the container even though the container is the
# only thing it can reach. Created before the dependency sync so the virtualenv
# and uv's cache are owned by the user that will actually run them.
RUN useradd --create-home --uid 10001 app
ENV HOME=/home/app \
    UV_CACHE_DIR=/home/app/.cache/uv \
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app
# uv.lock is committed but was previously not copied in, so every image build
# re-resolved dependencies from scratch and the lockfile had no effect on what
# actually shipped. Copying it and syncing --frozen makes the image match the
# lockfile that is reviewed in git, and fails loudly if the two ever drift.
COPY --chown=app:app pyproject.toml uv.lock ./
COPY --chown=app:app src/ ./src/
COPY --chown=app:app tests/ ./tests/
RUN chown app:app /app

USER app

RUN uv sync --no-dev --frozen

ENV OMNIROUTE_BASE_URL=http://omniroute-base:20128
ENV AGENT_SIDECAR_MODEL_ID=opencode/big-pickle

# No default CMD — this image is a library of two runners (smol_runner,
# pydantic_runner), invoked explicitly:
#   docker compose run agent-sidecar uv run python -m agent_sidecar.smol_runner "..."
#   docker compose run agent-sidecar uv run python -m agent_sidecar.pydantic_runner "..."
# or `docker compose run agent-sidecar uv run pytest tests/` to smoke-test.
CMD ["uv", "run", "pytest", "tests/", "-v"]

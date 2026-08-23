FROM python:3.11-slim

RUN pip install --no-cache-dir uv

WORKDIR /app
COPY pyproject.toml ./
COPY src/ ./src/
COPY tests/ ./tests/

RUN uv sync --no-dev

ENV OMNIROUTE_BASE_URL=http://omniroute-base:20128
ENV AGENT_SIDECAR_MODEL_ID=opencode/big-pickle

# No default CMD — this image is a library of two runners (smol_runner,
# pydantic_runner), invoked explicitly:
#   docker compose run agent-sidecar uv run python -m agent_sidecar.smol_runner "..."
#   docker compose run agent-sidecar uv run python -m agent_sidecar.pydantic_runner "..."
# or `docker compose run agent-sidecar uv run pytest tests/` to smoke-test.
CMD ["uv", "run", "pytest", "tests/", "-v"]

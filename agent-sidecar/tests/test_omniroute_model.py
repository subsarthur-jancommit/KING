"""The model client factory, which had no tests at all.

Thirty lines, and every agent run goes through them. If the base URL loses its
`/v1` or the key handling changes, nothing in this service works — and the
failure surfaces as an opaque client error a long way from the cause.

No network: constructing an OpenAI client does not call anything.
"""

from __future__ import annotations

from dataclasses import replace

import pytest

from agent_sidecar.config import load_settings
from agent_sidecar.omniroute_model import smolagents_model


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for var in ("OMNIROUTE_BASE_URL", "OMNIROUTE_API_KEY", "AGENT_SIDECAR_MODEL_ID"):
        monkeypatch.delenv(var, raising=False)


def test_the_client_points_at_the_v1_surface_of_the_gateway(monkeypatch):
    monkeypatch.setenv("OMNIROUTE_BASE_URL", "http://omniroute-base:20128")
    model = smolagents_model(load_settings())

    # `/v1` is what makes it the OpenAI-compatible surface rather than the
    # management API. Losing it turns every run into a 404 whose message says
    # nothing about the cause.
    assert str(model.client.base_url).rstrip("/").endswith("/v1")
    assert "omniroute-base:20128" in str(model.client.base_url)


def test_a_trailing_slash_on_the_base_url_does_not_double_up(monkeypatch):
    """Compose interpolation and hand-edited .env files both produce these."""
    monkeypatch.setenv("OMNIROUTE_BASE_URL", "http://omniroute-base:20128/")
    model = smolagents_model(load_settings())

    assert "//v1" not in str(model.client.base_url).replace("http://", "")


def test_the_model_id_reaches_the_client(monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_MODEL_ID", "agy/claude-sonnet-4-6")
    model = smolagents_model(load_settings())

    assert model.model_id == "agy/claude-sonnet-4-6"


def test_a_per_call_model_overrides_the_environment_default(monkeypatch):
    """Choosing the model per request is the whole reason `/run` accepts one."""
    monkeypatch.setenv("AGENT_SIDECAR_MODEL_ID", "opencode/big-pickle")
    settings = replace(load_settings(), model_id="agy/claude-opus-4-6-thinking-high")

    assert smolagents_model(settings).model_id == "agy/claude-opus-4-6-thinking-high"


def test_an_unset_key_becomes_a_placeholder_rather_than_none():
    """Deliberate, and easy to 'tidy' into a bug.

    The OpenAI client rejects `api_key=None` at construction, so an unset key
    would fail before any request — and the gateway's keyless providers would
    become unreachable for the one deployment that has no key configured yet.
    The placeholder keeps that path working and lets the gateway decide.
    """
    settings = load_settings()
    assert settings.omniroute_api_key is None

    model = smolagents_model(settings)

    # On the client, not the model: smolagents passes the key straight through
    # to the OpenAI SDK and keeps no copy. Asserting `model.api_key` raises
    # AttributeError, which CI caught the first time this was written.
    assert model.client.api_key == "unused"


def test_a_real_key_is_passed_through_untouched(monkeypatch):
    monkeypatch.setenv("OMNIROUTE_API_KEY", "sk-a-real-looking-key")
    model = smolagents_model(load_settings())

    assert model.client.api_key == "sk-a-real-looking-key"

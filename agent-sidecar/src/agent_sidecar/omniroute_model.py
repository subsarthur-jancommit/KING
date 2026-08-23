"""Model client factories pointed at OmniRoute's OpenAI-compatible gateway
(http://<OMNIROUTE_BASE_URL>/v1) instead of any third-party provider directly.
"""

from __future__ import annotations

from smolagents import OpenAIServerModel

from .config import Settings


def smolagents_model(settings: Settings) -> OpenAIServerModel:
    return OpenAIServerModel(
        model_id=settings.model_id,
        api_base=f"{settings.omniroute_base_url}/v1",
        api_key=settings.omniroute_api_key or "unused",
    )


def pydantic_ai_model(settings: Settings):
    # Imported lazily: pydantic_ai.models.openai pulls in `openai`, which
    # isn't needed by callers that only use the smolagents runner.
    from pydantic_ai.models.openai import OpenAIChatModel
    from pydantic_ai.providers.openai import OpenAIProvider

    provider = OpenAIProvider(
        base_url=f"{settings.omniroute_base_url}/v1",
        api_key=settings.omniroute_api_key or "unused",
    )
    return OpenAIChatModel(settings.model_id, provider=provider)

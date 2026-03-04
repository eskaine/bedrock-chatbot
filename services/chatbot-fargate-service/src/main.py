import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

from lib.config import config
from lib.pipeline import stream_chat_response
from lib.invoker import invoke_session

logging.basicConfig(level=logging.INFO, format='%(levelname)s %(name)s %(message)s')
logger = logging.getLogger(__name__)

logger.info("Region: %s, Streaming Lambda: %s", config.region, config.streaming_lambda_arn)

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.cors_allowed_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "X-Session-Id"],
)

logger.info("Fargate service initialization complete")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/session")
async def session(request: Request) -> dict:
    session_id: str | None = request.headers.get("x-session-id")
    return invoke_session(session_id)


@app.post("/chat")
async def chat(request: Request) -> StreamingResponse:
    body = await request.json()
    user_message: str = body.get("message", "")
    category: str | None = body.get("category")
    session_id: str | None = request.headers.get("x-session-id")

    forwarded_for = request.headers.get("x-forwarded-for", "")
    client_ip: str | None = forwarded_for.split(",")[0].strip() if forwarded_for else None

    return StreamingResponse(
        stream_chat_response(user_message, category, client_ip, session_id),
        media_type="application/x-ndjson",
    )

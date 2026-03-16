import base64
import logging

from fastapi import FastAPI, Request, Cookie, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse

from lib.config import config
from lib.jwt import sign_jwt, verify_jwt
from lib.pipeline import stream_chat_response, stream_voice_response
from lib.invoker import invoke_session
from lib.transcribe import transcribe_pcm

logging.basicConfig(level=logging.INFO, format='%(levelname)s %(name)s %(message)s')
logger = logging.getLogger(__name__)

logger.info("Region: %s, Streaming Lambda: %s", config.region, config.streaming_lambda_arn)

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=config.cors_allowed_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["Content-Type"],
)

logger.info("Fargate service initialization complete")

_COOKIE_NAME = "jwt"
_COOKIE_MAX_AGE = 15 * 60


def _set_jwt_cookie(response: Response, session_id: str) -> None:
    response.set_cookie(
        key=_COOKIE_NAME,
        value=sign_jwt(session_id),
        httponly=True,
        secure=config.jwt_cookie_secure,
        samesite="strict",
        domain=config.jwt_cookie_domain,
        max_age=_COOKIE_MAX_AGE,
    )


def _client_ip(request: Request) -> str | None:
    # The ALB appends the real client IP as the rightmost entry in X-Forwarded-For.
    # Using the leftmost would allow clients to spoof the header upstream.
    forwarded_for = request.headers.get("x-forwarded-for", "")
    return forwarded_for.split(",")[-1].strip() if forwarded_for else None



@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/session")
async def session(jwt: str | None = Cookie(default=None)) -> Response:
    session_id = verify_jwt(jwt) if jwt else None

    if session_id:
        # Valid JWT — fetch history without touching the cookie
        data = invoke_session(session_id)
        return JSONResponse(content=data)

    # No JWT or invalid — create/resume session and issue a fresh cookie
    data = invoke_session(None)
    response = JSONResponse(content=data)
    _set_jwt_cookie(response, data["sessionId"])
    return response


@app.post("/chat")
async def chat(request: Request, jwt: str | None = Cookie(default=None)) -> StreamingResponse:
    session_id = verify_jwt(jwt) if jwt else None

    if not session_id:
        return JSONResponse(status_code=401, content={"error": "Unauthorized"})

    body = await request.json()
    user_message: str = body.get("message", "")

    response = StreamingResponse(
        stream_chat_response(user_message, _client_ip(request), session_id),
        media_type="application/x-ndjson",
    )
    _set_jwt_cookie(response, session_id)
    return response


@app.post("/voice-chat")
async def voice_chat(request: Request, jwt: str | None = Cookie(default=None)) -> Response:
    """Voice pipeline: PCM audio → Transcribe → LLM stream → Polly per sentence → NDJSON stream.

    Request body:
        audio        str   base64-encoded raw 16-bit little-endian PCM
        sample_rate  int   actual browser AudioContext sample rate (default 16000)

    Response NDJSON stream:
        {"type": "transcription", "text": "..."}
        {"type": "audio", "text": "...", "audio": "<base64 MP3>"}
        {"type": "done"}
    """
    session_id = verify_jwt(jwt) if jwt else None
    if not session_id:
        return JSONResponse(status_code=401, content={"error": "Unauthorized"})

    body = await request.json()
    audio_b64: str = body.get("audio", "")
    if not audio_b64:
        return JSONResponse(status_code=400, content={"error": "Audio data is required"})

    _MAX_AUDIO_B64_LEN = 5 * 1024 * 1024  # 5 MB — covers ~3 min of 16kHz mono PCM
    if len(audio_b64) > _MAX_AUDIO_B64_LEN:
        return JSONResponse(status_code=413, content={"error": "Audio exceeds maximum allowed size"})

    try:
        sample_rate = int(body.get("sample_rate", 16000))
    except (ValueError, TypeError):
        sample_rate = 16000

    try:
        pcm_bytes = base64.b64decode(audio_b64)
    except Exception:
        return JSONResponse(status_code=400, content={"error": "Invalid audio data"})

    try:
        transcription = await transcribe_pcm(pcm_bytes, sample_rate)
    except Exception:
        logger.exception("Transcription failed")
        return JSONResponse(status_code=500, content={"error": "Transcription failed"})

    if not transcription:
        return JSONResponse(status_code=422, content={"error": "No speech detected"})

    response = StreamingResponse(
        stream_voice_response(transcription, _client_ip(request), session_id),
        media_type="application/x-ndjson",
    )
    _set_jwt_cookie(response, session_id)
    return response


@app.delete("/session")
async def reset_session() -> Response:
    """Clear the existing session and issue a new one."""
    data = invoke_session(None)
    response = JSONResponse(content=data)
    _set_jwt_cookie(response, data["sessionId"])
    return response

import asyncio
import logging

from amazon_transcribe.client import TranscribeStreamingClient
from amazon_transcribe.handlers import TranscriptResultStreamHandler
from amazon_transcribe.model import TranscriptEvent

from lib.config import config

logger = logging.getLogger(__name__)

_CHUNK_SIZE = 16 * 1024  # 16 KB chunks sent to Transcribe


async def transcribe_pcm(pcm_bytes: bytes, sample_rate: int = 16000) -> str:
    """Transcribe raw PCM audio (16-bit, mono) to text via Transcribe Streaming.

    Args:
        pcm_bytes:   Raw 16-bit little-endian PCM samples.
        sample_rate: Actual sample rate captured by the browser AudioContext.

    Returns:
        Transcribed text, or empty string if no speech was detected.
    """
    client = TranscribeStreamingClient(region=config.region)

    stream = await client.start_stream_transcription(
        language_code="en-US",
        media_sample_rate_hz=sample_rate,
        media_encoding="pcm",
    )

    transcript_parts: list[str] = []

    class Handler(TranscriptResultStreamHandler):
        async def handle_transcript_event(self, event: TranscriptEvent) -> None:
            for result in event.transcript.results:
                if not result.is_partial:
                    for alt in result.alternatives:
                        transcript_parts.append(alt.transcript)

    async def write_audio() -> None:
        for i in range(0, len(pcm_bytes), _CHUNK_SIZE):
            await stream.input_stream.send_audio_event(
                audio_chunk=pcm_bytes[i : i + _CHUNK_SIZE]
            )
        await stream.input_stream.end_stream()

    handler = Handler(stream.output_stream)
    await asyncio.gather(write_audio(), handler.handle_events())

    return " ".join(transcript_parts).strip()

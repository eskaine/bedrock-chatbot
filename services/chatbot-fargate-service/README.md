# chatbot-fargate-service

FastAPI service running on ECS Fargate. Acts as the public-facing API gateway between the browser and the internal orchestration Lambda.

---

## Responsibilities

- Issues and verifies JWT for anonymous session authentication
- Validates and sanitises user input (length, character allow-list, injection detection)
- Applies in-memory IP-based rate limiting
- Proxies validated requests to the streaming Lambda via AWS SDK

---

## Endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/health` | None | Health check |
| `GET` | `/session` | Optional JWT cookie | Bootstrap or resume a session |
| `POST` | `/chat` | Required JWT cookie | Send a message, receive a streaming NDJSON response |

---

## Authentication — JWT (HttpOnly Cookie)

JWT is issued by Fargate and delivered as an `HttpOnly` cookie. It is never accessible to browser JavaScript.

### Why JWT over a plain session ID

The previous `X-Session-Id` header was an opaque string — easy to forge and offered no cryptographic guarantee. JWT adds a signed proof that the session ID was issued by this server. The browser cannot read or tamper with it.

### Why HttpOnly cookie over Authorization header storage

Storing a JWT in `sessionStorage` or `localStorage` exposes it to XSS attacks. An `HttpOnly` cookie is inaccessible to JavaScript entirely. Since Fargate and the frontend are served under the same domain (via CloudFront path-based routing), `SameSite=Strict` cookies work without CORS credential complexity.

### Token claims

| Claim | Value |
|---|---|
| `sub` | `sessionId` — DynamoDB UUID v4 |
| `iat` | Issued-at timestamp |
| `exp` | 24-hour fixed expiry |

JWT expiry is fixed at 24 hours. Actual session liveness is determined by DynamoDB's **sliding 15-minute TTL** — a session expires when idle for 15 minutes regardless of the JWT. The JWT is re-issued on every `GET /session` call, so a page refresh always gets a fresh token.

### Session bootstrap flow

```
GET /session  (browser always calls this on page load)
     │
     ├── JWT cookie present + valid
     │       └── verify signature → extract sessionId
     │           → fetch history from DynamoDB (via Lambda)
     │           → return { status, sessionId, history }
     │           (no new JWT — existing cookie is still valid)
     │
     └── JWT cookie missing or invalid
             └── invoke Lambda: get_or_create_session
                 → issue new JWT → set HttpOnly cookie
                 → return { status: "new", sessionId, history: [] }
```

History is only returned when a valid JWT is present. An unauthenticated request can only ever produce a new empty session.

### Chat auth flow

```
POST /chat  (JWT cookie required)
     │
     ├── JWT valid  →  extract sessionId  →  invoke streaming Lambda
     └── JWT missing or invalid  →  401 Unauthorized
```

---

## Request Pipeline (`POST /chat`)

```
Incoming request
    ↓
JWT middleware — verify cookie signature, extract sessionId
    ↓
Rate limiter — in-memory IP-based (10 req / 60 s)
    ↓
Input validation — length, character allow-list
    ↓
Prompt injection detection — regex pattern matching
    ↓
invoke_streaming(message, category, sessionId)
    ↓
StreamingResponse (NDJSON)  →  browser
```

---

## File Structure

```
src/
├── main.py             — FastAPI app, route handlers, CORS middleware
└── lib/
    ├── config.py       — Environment variable bindings (frozen dataclass)
    ├── constants.py    — Shared constants (limits, rate limit config)
    ├── invoker.py      — Lambda invocation: invoke_session, invoke_streaming
    ├── jwt.py          — JWT sign / verify helpers (PyJWT, HS256)
    ├── pipeline.py     — Chat pipeline: validate → inject-check → invoke → stream
    ├── session.py      — DynamoDB session read (history load for Fargate-side reads)
    └── validators.py   — validate_user_input, check_rate_limit, detect_prompt_injection
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `AWS_REGION` | AWS region |
| `STREAMING_LAMBDA_ARN` | ARN of the orchestration Lambda |
| `CORS_ALLOWED_ORIGINS` | Comma-separated list of allowed origins |
| `SESSIONS_TABLE` | DynamoDB table name for session storage |
| `JWT_SECRET` | HMAC secret for signing JWTs (load from Secrets Manager) |
| `JWT_COOKIE_DOMAIN` | Cookie domain (e.g. `.yourdomain.com`) |
| `JWT_COOKIE_SECURE` | Set to `true` in production (HTTPS only) |

---

## Deployment

```bash
./scripts/deploy-ecs.sh <environment>
# e.g. ./scripts/deploy-ecs.sh dev
```

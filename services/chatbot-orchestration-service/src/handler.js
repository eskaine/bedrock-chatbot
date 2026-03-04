const { ERROR_MESSAGE, MAX_MESSAGE_LENGTH, MIN_MESSAGE_LENGTH, CATEGORY_RE } = require('./lib/constants')
const { REGION, MODEL_ID, POSTGRES_HOST, POSTGRES_DB } = require('./lib/config')
const { getLogger } = require('./lib/logger')
const { systemPromptPromise } = require('./lib/llm')
const { runChatPipeline } = require('./lib/pipeline')

const logger = getLogger('handler')

logger.info('Starting Lambda initialization')
logger.info('Startup config', { region: REGION, model: MODEL_ID })
logger.debug('DB config', { host: POSTGRES_HOST, db: POSTGRES_DB })
logger.info('Lambda initialization complete')

exports.handler = awslambda.streamifyResponse(async (event, responseStream) => {
  logger.debug('Received event', { event: JSON.stringify(event).slice(0, 500) })

  // --- Parse body ---------------------------------------------------------

  let body
  try {
    body = JSON.parse(event.body || '{}')
  } catch {
    responseStream.write(JSON.stringify({ error: ERROR_MESSAGE }) + '\n')
    responseStream.end()
    return
  }

  // --- Validate and sanitize inputs ---------------------------------------
  // The Lambda Function URL is publicly accessible (auth-type NONE).
  // Fargate validates requests before invoking this Lambda, but the URL can
  // be called directly, so we apply the same guards here as a second layer.

  const userMessage = typeof body.message === 'string' ? body.message.trim() : ''
  const rawCategory = typeof body.category === 'string' ? body.category : null
  const sessionId   = event.headers?.['x-session-id'] || null

  if (!userMessage) {
    responseStream.write(JSON.stringify({ error: 'Message cannot be empty' }) + '\n')
    responseStream.end()
    return
  }

  if (userMessage.length < MIN_MESSAGE_LENGTH) {
    responseStream.write(JSON.stringify({ error: 'Message too short' }) + '\n')
    responseStream.end()
    return
  }

  if (userMessage.length > MAX_MESSAGE_LENGTH) {
    responseStream.write(JSON.stringify({ error: `Message exceeds ${MAX_MESSAGE_LENGTH} characters` }) + '\n')
    responseStream.end()
    return
  }

  const category = rawCategory && CATEGORY_RE.test(rawCategory) ? rawCategory : null
  if (rawCategory && !category) {
    logger.warn('Invalid category in request — ignoring', { rawCategory })
  }

  logger.info('Request received', { message: userMessage.slice(0, 200), category, sessionId })

  // --- Run pipeline -------------------------------------------------------

  try {
    const systemPrompt = await systemPromptPromise

    for await (const text of runChatPipeline(userMessage, category, sessionId, systemPrompt)) {
      responseStream.write(JSON.stringify({ chunk: text }) + '\n')
    }
  } catch (err) {
    logger.error('Unhandled error', { error: err.message, stack: err.stack })
    responseStream.write(JSON.stringify({ error: ERROR_MESSAGE }) + '\n')
  }

  responseStream.end()
})

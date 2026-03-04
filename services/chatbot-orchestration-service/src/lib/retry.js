/**
 * retry.js — exponential backoff for throttled AWS SDK calls.
 *
 * Only retries on transient AWS throttling errors. All other errors
 * are re-thrown immediately so the caller can handle them.
 *
 * Usage:
 *   const result = await withRetry(() => client.send(command), { label: 'embedQuery' })
 */

const { getLogger } = require('./logger')

const logger = getLogger('retry')

const RETRYABLE_CODES = new Set([
  'ThrottlingException',
  'TooManyRequestsException',
  'ServiceUnavailableException',
  'RequestTimeout',
  'RequestThrottled',
])

async function withRetry(fn, { maxAttempts = 3, baseDelayMs = 1000, label = 'operation' } = {}) {
  let lastError

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await fn()
    } catch (err) {
      if (!RETRYABLE_CODES.has(err.name)) throw err

      lastError = err

      if (attempt < maxAttempts - 1) {
        const delay = baseDelayMs * Math.pow(2, attempt)
        logger.warn(`AWS throttled [${label}], retrying`, {
          code: err.name,
          attempt: attempt + 1,
          maxAttempts,
          delayMs: delay,
        })
        await new Promise(resolve => setTimeout(resolve, delay))
      }
    }
  }

  throw lastError
}

module.exports = { withRetry }

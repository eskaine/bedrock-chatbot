/**
 * session.js — DynamoDB conversation history store.
 *
 * DynamoDB table: chatbot-sessions-{env}   (PAY_PER_REQUEST billing)
 * ┌─────────────────────────────────────────────────────────────────────────┐
 * │ sessionId    String   HASH key — client-generated UUID v4               │
 * │ messages     List     Bedrock-format conversation history                │
 * │ ttl          Number   Unix timestamp — DynamoDB TTL (sliding, 24 h)      │
 * │ createdAt    String   ISO 8601 — set once on first write                 │
 * │ updatedAt    String   ISO 8601 — updated on every write                  │
 * │ messageCount Number   Count of stored messages (for quick inspection)    │
 * └─────────────────────────────────────────────────────────────────────────┘
 *
 * TTL behaviour: every save resets ttl to now + SESSION_TTL_SECONDS, giving
 * a sliding expiry window. An idle session expires 24 h after the last message.
 *
 * Concurrency: sessions are single-user and single-threaded per Lambda
 * invocation, so last-write-wins on UpdateItem is acceptable.
 */

const { DynamoDBClient } = require('@aws-sdk/client-dynamodb')
const { DynamoDBDocumentClient, GetCommand, UpdateCommand } = require('@aws-sdk/lib-dynamodb')
const { REGION, SESSIONS_TABLE } = require('./config')
const { SESSION_TTL_SECONDS, SESSION_ID_RE } = require('./constants')
const { getLogger } = require('./logger')

const logger = getLogger('session')

const dynamo = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION, requestTimeout: 5000 }))

function isValidSessionId(sessionId) {
  return typeof sessionId === 'string' && SESSION_ID_RE.test(sessionId)
}

async function loadHistory(sessionId) {
  if (!SESSIONS_TABLE || !isValidSessionId(sessionId)) return []
  try {
    const result = await dynamo.send(new GetCommand({
      TableName: SESSIONS_TABLE,
      Key: { sessionId },
    }))
    return result.Item?.messages ?? []
  } catch (err) {
    logger.error('Failed to load history', { error: err.message })
    return []
  }
}

async function saveHistory(sessionId, messages) {
  if (!SESSIONS_TABLE || !isValidSessionId(sessionId)) return
  try {
    const now = new Date().toISOString()
    const ttl = Math.floor(Date.now() / 1000) + SESSION_TTL_SECONDS

    await dynamo.send(new UpdateCommand({
      TableName: SESSIONS_TABLE,
      Key: { sessionId },
      // createdAt uses if_not_exists so it is only written on the first save.
      // #ttl aliases the reserved word "ttl".
      UpdateExpression: `
        SET messages      = :messages,
            #ttl          = :ttl,
            updatedAt     = :now,
            messageCount  = :count,
            createdAt     = if_not_exists(createdAt, :now)
      `,
      ExpressionAttributeNames: { '#ttl': 'ttl' },
      ExpressionAttributeValues: {
        ':messages': messages,
        ':ttl':      ttl,
        ':now':      now,
        ':count':    messages.length,
      },
    }))
  } catch (err) {
    logger.error('Failed to save history', { error: err.message })
  }
}

module.exports = { loadHistory, saveHistory }

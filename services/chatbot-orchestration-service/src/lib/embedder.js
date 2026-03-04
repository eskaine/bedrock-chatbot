/**
 * embedder.js — Bedrock embedding for query vectors.
 *
 * This is the swap point for the embedding model. To use a different
 * provider or model, only this module needs to change.
 */

const { BedrockRuntimeClient, InvokeModelCommand } = require('@aws-sdk/client-bedrock-runtime')
const { EMBED_MODEL_ID } = require('./constants')
const { REGION } = require('./config')
const { getLogger } = require('./logger')
const { withRetry } = require('./retry')

const logger = getLogger('embedder')

const bedrock = new BedrockRuntimeClient({ region: REGION })

async function embedQuery(query) {
  return withRetry(
    async () => {
      const response = await bedrock.send(new InvokeModelCommand({
        modelId: EMBED_MODEL_ID,
        body: JSON.stringify({ texts: [query], input_type: 'search_query' }),
      }))

      const result = JSON.parse(Buffer.from(response.body).toString())
      const vector = result.embeddings?.[0]

      if (!Array.isArray(vector) || vector.length === 0) {
        throw new Error(`Unexpected embedding response from ${EMBED_MODEL_ID}`)
      }

      logger.debug('Query embedded', { model: EMBED_MODEL_ID, dimension: vector.length })
      return vector
    },
    { label: 'embedQuery' },
  )
}

module.exports = { embedQuery }

/**
 * llm.js — Bedrock LLM integration.
 *
 * This is the primary swap point for the underlying language model.
 * To use a different provider (OpenAI, Vertex AI, local model), only
 * this module needs to change — handler.js, pipeline.js, and retrieval.js
 * are unaffected.
 */

const { BedrockRuntimeClient, ConverseStreamCommand } = require('@aws-sdk/client-bedrock-runtime')
const { BedrockAgentClient, GetPromptCommand } = require('@aws-sdk/client-bedrock-agent')
const { REGION, MODEL_ID, GUARDRAIL_ID, GUARDRAIL_VERSION, PROMPT_ARN, PROMPT_VERSION } = require('./config')
const { MAX_TOKENS, TEMPERATURE } = require('./constants')
const { getLogger } = require('./logger')

const logger = getLogger('llm')

const bedrock      = new BedrockRuntimeClient({ region: REGION })
const bedrockAgent = new BedrockAgentClient({ region: REGION })

// Fetched once at cold start — cached for the Lambda instance lifetime
const systemPromptPromise = (PROMPT_ARN && PROMPT_VERSION)
  ? bedrockAgent.send(new GetPromptCommand({
      promptIdentifier: PROMPT_ARN,
      promptVersion: PROMPT_VERSION,
    }))
      .then(res => {
        const text = res.variants?.[0]?.templateConfiguration?.text?.text
        if (!text) throw new Error('Prompt variant text not found in response')
        logger.info('System prompt fetched from Bedrock Prompt Management')
        return text
      })
      .catch(err => {
        logger.error('Failed to fetch system prompt', { name: err.name, error: err.message })
        return null
      })
  : Promise.resolve(null)

/**
 * Stream a completion from the configured LLM.
 * Yields text chunks as they arrive from the model.
 *
 * Replace this function's implementation to swap the LLM provider.
 *
 * @param {Array}       messages     Bedrock-format messages array
 * @param {string|null} systemPrompt Optional system prompt text
 */
async function* streamCompletion(messages, systemPrompt) {
  const params = {
    modelId: MODEL_ID,
    messages,
    inferenceConfig: { maxTokens: MAX_TOKENS, temperature: TEMPERATURE },
  }

  if (systemPrompt) {
    params.system = [{ text: systemPrompt }]
  }

  if (GUARDRAIL_ID && GUARDRAIL_VERSION) {
    params.guardrailConfig = {
      guardrailIdentifier: GUARDRAIL_ID,
      guardrailVersion: GUARDRAIL_VERSION,
    }
  }

  const response = await bedrock.send(new ConverseStreamCommand(params))

  for await (const chunk of response.stream) {
    if (chunk.contentBlockDelta?.delta?.text) {
      yield chunk.contentBlockDelta.delta.text
    }
  }
}

module.exports = { systemPromptPromise, streamCompletion }

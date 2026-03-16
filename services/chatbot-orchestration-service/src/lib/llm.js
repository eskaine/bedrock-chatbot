/**
 * llm.js — Bedrock LLM integration.
 *
 * This is the primary swap point for the underlying language model.
 * To use a different provider (OpenAI, Vertex AI, local model), only
 * this module needs to change — handler.js, pipeline.js, and retrieval.js
 * are unaffected.
 */

const { BedrockRuntimeClient, ConverseCommand, ConverseStreamCommand } = require('@aws-sdk/client-bedrock-runtime')
const { BedrockAgentClient, GetPromptCommand } = require('@aws-sdk/client-bedrock-agent')
const { REGION, MODEL_ID, GUARDRAIL_ID, GUARDRAIL_VERSION, PROMPT_ARN, PROMPT_VERSION, CLASSIFIER_PROMPT_ARN, CLASSIFIER_PROMPT_VERSION } = require('./config')
const { MAX_TOKENS, TEMPERATURE, MAX_CLASSIFIER_HISTORY, STREAM_TIMEOUT_MS } = require('./constants')
const { getLogger } = require('./logger')
const { withRetry } = require('./retry')

const logger = getLogger('llm')

const bedrock      = new BedrockRuntimeClient({ region: REGION })
const bedrockAgent = new BedrockAgentClient({ region: REGION })

function _fetchPrompt(arn, version, label) {
  return (arn && version)
    ? withRetry(
        () => bedrockAgent.send(new GetPromptCommand({ promptIdentifier: arn, promptVersion: version })),
        { label }
      )
        .then(res => {
          const text = res.variants?.[0]?.templateConfiguration?.text?.text
          if (!text) throw new Error(`Prompt variant text not found for ${label}`)
          logger.info(`${label} fetched from Bedrock Prompt Management`)
          return text
        })
        .catch(err => {
          logger.error(`Failed to fetch ${label}`, { name: err.name, error: err.message })
          throw err
        })
    : Promise.resolve(null)
}

// Fetched once at cold start — cached for the Lambda instance lifetime
const systemPromptPromise     = _fetchPrompt(PROMPT_ARN, PROMPT_VERSION, 'systemPrompt')
const classifierPromptPromise = _fetchPrompt(CLASSIFIER_PROMPT_ARN, CLASSIFIER_PROMPT_VERSION, 'classifierPrompt')

/**
 * Classify the topic and rewrite the user query using a non-streaming Bedrock call.
 *
 * Returns:
 *   { topic: string, cleanedQuery: string }              — topic matched
 *   { topic: null,   clarification: string }             — no topic matched
 *
 * @param {string}      userMessage       Raw user input
 * @param {string[]}    categories        Valid topics fetched from DB
 * @param {Array}       history           Current session history (Bedrock format)
 * @param {string|null} classifierPrompt  System prompt for classification
 */
async function classifyAndClean(userMessage, categories, history, classifierPrompt) {
  const categoryList = categories.join(', ')
  const content = `Available topics: ${categoryList}\n\nUser message: "${userMessage}"`

  const messages = [
    ...history.slice(-MAX_CLASSIFIER_HISTORY),
    { role: 'user', content: [{ text: content }] },
  ]

  const params = {
    modelId: MODEL_ID,
    messages,
    inferenceConfig: { maxTokens: 256, temperature: 0 },
  }

  if (classifierPrompt) {
    params.system = [{ text: classifierPrompt }]
  }

  const response = await withRetry(
    () => bedrock.send(new ConverseCommand(params)),
    { label: 'classifyAndClean' }
  )

  const text = response.output?.message?.content?.[0]?.text ?? ''
  const match = text.match(/\{[\s\S]*\}/)

  if (!match) {
    logger.warn('Classifier returned no JSON', { text })
    return { topic: null, clarification: 'Could you clarify which product you are asking about?' }
  }

  try {
    const parsed = JSON.parse(match[0])
    return {
      topic:        parsed.topic        ?? null,
      cleanedQuery: parsed.cleanedQuery ?? userMessage,
      clarification: parsed.clarification ?? null,
    }
  } catch {
    logger.warn('Classifier JSON parse failed', { text })
    return { topic: null, clarification: 'Could you clarify which product you are asking about?' }
  }
}

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

  const response = await withRetry(
    () => bedrock.send(new ConverseStreamCommand(params)),
    { label: 'streamCompletion' }
  )

  // Race each chunk read against a sliding deadline so a stalled stream
  // does not hold the Lambda until the hard 120 s function timeout.
  const deadline = Date.now() + STREAM_TIMEOUT_MS
  const iterator = response.stream[Symbol.asyncIterator]()

  while (true) {
    const remaining = deadline - Date.now()
    if (remaining <= 0) throw new Error('Bedrock stream timed out')

    const result = await Promise.race([
      iterator.next(),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error('Bedrock stream timed out')), remaining)
      ),
    ])

    if (result.done) break
    if (result.value.contentBlockDelta?.delta?.text) {
      yield result.value.contentBlockDelta.delta.text
    }
  }
}

module.exports = { systemPromptPromise, classifierPromptPromise, classifyAndClean, streamCompletion }

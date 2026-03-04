const { MAX_HISTORY_MESSAGES } = require('./constants')
const { MODEL_ID } = require('./config')
const { loadHistory, saveHistory } = require('./session')
const { streamCompletion } = require('./llm')
const { getVectorContext } = require('./retrieval')
const { getLogger } = require('./logger')

const logger = getLogger('pipeline')

function buildPrompt(userMessage, category, context) {
  const categoryLine = category ? `Selected product: ${category}\n\n` : ''
  return context
    ? `${categoryLine}Context: ${context}\n\nQuestion: ${userMessage}`
    : `${categoryLine}Question: ${userMessage}`
}

function buildMessages(history, context, prompt) {
  const currentContent = context
    ? [
        { guardContent: { text: { text: context, qualifiers: ['grounding_source'] } } },
        { text: prompt },
      ]
    : [{ text: prompt }]

  const trimmedHistory = history.slice(-MAX_HISTORY_MESSAGES)
  return { messages: [...trimmedHistory, { role: 'user', content: currentContent }], trimmedHistory }
}

/**
 * Orchestrate the full chat pipeline: retrieve → build prompt → stream → persist.
 *
 * Yields text chunks suitable for writing directly to the Lambda response stream.
 *
 * @param {string}      userMessage  Raw user input
 * @param {string|null} category     Optional product/topic filter
 * @param {string|null} sessionId    DynamoDB session key
 * @param {string|null} systemPrompt Pre-fetched system prompt text
 */
async function* runChatPipeline(userMessage, category, sessionId, systemPrompt) {
  const history = await loadHistory(sessionId)
  const context = await getVectorContext(userMessage, category)

  const prompt = buildPrompt(userMessage, category, context)
  const { messages, trimmedHistory } = buildMessages(history, context, prompt)

  logger.info('Calling LLM', { model: MODEL_ID, grounding: !!context, historyLength: trimmedHistory.length })

  let assistantResponse = ''
  for await (const text of streamCompletion(messages, systemPrompt)) {
    assistantResponse += text
    yield text
  }

  if (assistantResponse) {
    const updatedHistory = [
      ...trimmedHistory,
      { role: 'user', content: [{ text: userMessage }] },
      { role: 'assistant', content: [{ text: assistantResponse }] },
    ].slice(-MAX_HISTORY_MESSAGES)
    await saveHistory(sessionId, updatedHistory)
  }
}

module.exports = { runChatPipeline }

const { MAX_HISTORY_MESSAGES, CATEGORIES } = require('./constants')
const { MODEL_ID } = require('./config')
const { loadHistory, saveHistory } = require('./session')
const { streamCompletion, classifyAndClean } = require('./llm')
const { getVectorContext, categoriesPromise } = require('./retrieval')
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
 * Orchestrate the full chat pipeline: classify → retrieve → build prompt → stream → persist.
 *
 * Yields text chunks suitable for writing directly to the Lambda response stream.
 *
 * @param {string}      userMessage       Raw user input
 * @param {string|null} sessionId         DynamoDB session key
 * @param {string|null} systemPrompt      Pre-fetched system prompt text
 * @param {string|null} classifierPrompt  Pre-fetched classifier prompt text
 */
async function* runChatPipeline(userMessage, sessionId, systemPrompt, classifierPrompt) {
  const history = await loadHistory(sessionId)
  if (history === null) {
    const err = new Error('Session has expired')
    err.code = 'SESSION_EXPIRED'
    throw err
  }

  // Map DB keys to display names for the classifier prompt.
  // Only include categories that exist in both the DB and the CATEGORIES map.
  const dbCategories = await categoriesPromise
  const displayCategories = dbCategories
    .filter(key => CATEGORIES[key])
    .map(key => CATEGORIES[key])

  // Reverse map: display name → DB key for retrieval filtering
  const displayToKey = Object.fromEntries(
    Object.entries(CATEGORIES).map(([key, display]) => [display, key])
  )

  const { topic, cleanedQuery: rawCleanedQuery, clarification } = await classifyAndClean(
    userMessage, displayCategories, history, classifierPrompt
  )

  // Validate LLM-generated cleanedQuery: must be a non-empty string within a
  // reasonable length. Fall back to the original validated userMessage if not.
  const cleanedQuery = (
    typeof rawCleanedQuery === 'string' &&
    rawCleanedQuery.trim().length > 0 &&
    rawCleanedQuery.length <= userMessage.length * 3
  ) ? rawCleanedQuery.trim() : userMessage

  // topic is a display name — resolve back to DB key
  const topicKey = topic ? (displayToKey[topic] ?? null) : null

  if (!topicKey) {
    const clarificationText = clarification ?? 'Could you clarify which product you are asking about?'
    logger.info('No topic detected — returning clarification', { sessionId })
    yield clarificationText

    const updatedHistory = [
      ...history.slice(-MAX_HISTORY_MESSAGES),
      { role: 'user',      content: [{ text: userMessage }] },
      { role: 'assistant', content: [{ text: clarificationText }] },
    ].slice(-MAX_HISTORY_MESSAGES)
    await saveHistory(sessionId, updatedHistory)
    return
  }

  logger.info('Topic classified', { topic, topicKey, cleanedQuery })

  const context = await getVectorContext(cleanedQuery, topicKey)

  if (context === null) {
    const clarificationText = `I couldn't find specific documentation on that. Could you rephrase your question or provide more detail about what you're looking for?`
    logger.info('No context found — returning clarification', { sessionId, topicKey })
    yield clarificationText

    const updatedHistory = [
      ...history.slice(-MAX_HISTORY_MESSAGES),
      { role: 'user',      content: [{ text: cleanedQuery }] },
      { role: 'assistant', content: [{ text: clarificationText }] },
    ].slice(-MAX_HISTORY_MESSAGES)
    await saveHistory(sessionId, updatedHistory)
    return
  }

  const prompt = buildPrompt(cleanedQuery, topicKey, context)
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
      { role: 'user',      content: [{ text: cleanedQuery }] },
      { role: 'assistant', content: [{ text: assistantResponse }] },
    ].slice(-MAX_HISTORY_MESSAGES)
    await saveHistory(sessionId, updatedHistory)
  }
}

module.exports = { runChatPipeline }

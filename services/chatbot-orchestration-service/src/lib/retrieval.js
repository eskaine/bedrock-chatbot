const { Client } = require('pg')
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager')
const { REGION, DB_SECRET_ARN, POSTGRES_HOST, POSTGRES_DB } = require('./config')
const { DB_PORT, DB_CONNECT_TIMEOUT_MS, RRF_TOP_N, SECTIONS_TABLE } = require('./constants')
const { embedQuery } = require('./embedder')
const { denseRetriever, sparseRetriever, headerRetriever, applyRRF } = require('./retrievers')
const { getLogger } = require('./logger')
const { withRetry } = require('./retry')

const logger = getLogger('retrieval')

const secretsManager = new SecretsManagerClient({ region: REGION })

// Fetched once at cold start — cached for the Lambda instance lifetime
const dbCredsPromise = DB_SECRET_ARN
  ? withRetry(
      () => secretsManager.send(new GetSecretValueCommand({ SecretId: DB_SECRET_ARN }))
        .then(res => JSON.parse(res.SecretString)),
      { label: 'fetchDbCreds' }
    ).catch(err => {
      logger.error('Failed to fetch DB credentials', { name: err.name, error: err.message })
      return null
    })
  : Promise.resolve(null)

// Fetched once at cold start — distinct category keys from the DB
const categoriesPromise = dbCredsPromise.then(async dbCreds => {
  if (!dbCreds) return []
  const client = new Client({
    host: POSTGRES_HOST,
    database: POSTGRES_DB,
    user: dbCreds.username,
    password: dbCreds.password,
    port: dbCreds.port || DB_PORT,
    connectionTimeoutMillis: DB_CONNECT_TIMEOUT_MS,
    ssl: { rejectUnauthorized: false },
  })
  try {
    await client.connect()
    const result = await client.query(
      'SELECT DISTINCT category FROM document_sections ORDER BY category'
    )
    const categories = result.rows.map(r => r.category)
    logger.info('Categories fetched from DB', { categories })
    return categories
  } catch (err) {
    logger.error('Failed to fetch categories', { error: err.message })
    return []
  } finally {
    await client.end().catch(() => {})
  }
})

async function getVectorContext(query, category) {
  const dbCreds = await dbCredsPromise
  if (!dbCreds) {
    logger.info('DB credentials not available, skipping retrieval')
    return null
  }

  const client = new Client({
    host: POSTGRES_HOST,
    database: POSTGRES_DB,
    user: dbCreds.username,
    password: dbCreds.password,
    port: dbCreds.port || DB_PORT,
    connectionTimeoutMillis: DB_CONNECT_TIMEOUT_MS,
    // Within a private VPC the connection never leaves AWS infrastructure.
    // rejectUnauthorized: false avoids bundling the Amazon RDS CA into the Lambda.
    ssl: { rejectUnauthorized: false },
  })

  try {
    await client.connect()

    const embeddingQuery = category ? `${category}: ${query}` : query
    const vector = await embedQuery(embeddingQuery)

    const [denseResults, sparseResults, headerResults] = await Promise.all([
      denseRetriever(client, vector, category),
      sparseRetriever(client, query, category),
      headerRetriever(client, vector, category),
    ])

    logger.info('Retriever results', { dense: denseResults.length, sparse: sparseResults.length, header: headerResults.length })

    const fused = applyRRF([denseResults, sparseResults, headerResults])
    const topSectionIds = fused.slice(0, RRF_TOP_N).map(r => r.section_id)
    logger.info('RRF fusion complete', { topN: topSectionIds.length })

    if (!topSectionIds.length) return null

    const sections = await fetchParentSections(client, topSectionIds)
    logger.info('Parent sections fetched', { count: sections.length })

    return sections.length ? sections.map(s => s.content).join('\n\n') : null
  } catch (err) {
    logger.error('Retrieval error', { name: err.name, error: err.message, metadata: err.$metadata })
    return null
  } finally {
    await client.end().catch(() => {})
  }
}

async function fetchParentSections(client, sectionIds) {
  const result = await client.query(
    `SELECT id, content
     FROM ${SECTIONS_TABLE}
     WHERE id = ANY($1)
     ORDER BY category`,
    [sectionIds]
  )
  return result.rows
}

module.exports = { categoriesPromise, getVectorContext }

const { CHUNKS_TABLE, SECTIONS_TABLE, DENSE_LIMIT, SPARSE_LIMIT, HEADER_LIMIT, RRF_K } = require('./constants')

// Dense retriever — ANN vector search on child chunk embeddings (HNSW)
async function denseRetriever(client, vector, category) {
  const vectorStr = '[' + vector.join(',') + ']'

  const result = category
    ? await client.query(
        `SELECT dc.section_id
         FROM ${CHUNKS_TABLE} dc
         WHERE dc.metadata->>'category' = $2
         ORDER BY dc.embedding <=> $1::vector
         LIMIT $3`,
        [vectorStr, category, DENSE_LIMIT]
      )
    : await client.query(
        `SELECT dc.section_id
         FROM ${CHUNKS_TABLE} dc
         ORDER BY dc.embedding <=> $1::vector
         LIMIT $2`,
        [vectorStr, DENSE_LIMIT]
      )

  return result.rows
}

// Sparse retriever — BM25 keyword search on child chunk tsvectors (GIN)
async function sparseRetriever(client, query, category) {
  const result = category
    ? await client.query(
        `SELECT dc.section_id
         FROM ${CHUNKS_TABLE} dc
         WHERE dc.content_tsvector @@ plainto_tsquery($1)
           AND dc.metadata->>'category' = $2
         ORDER BY ts_rank(dc.content_tsvector, plainto_tsquery($1)) DESC
         LIMIT $3`,
        [query, category, SPARSE_LIMIT]
      )
    : await client.query(
        `SELECT dc.section_id
         FROM ${CHUNKS_TABLE} dc
         WHERE dc.content_tsvector @@ plainto_tsquery($1)
         ORDER BY ts_rank(dc.content_tsvector, plainto_tsquery($1)) DESC
         LIMIT $2`,
        [query, SPARSE_LIMIT]
      )

  return result.rows
}

// Header retriever — ANN vector search on section header embeddings (HNSW)
async function headerRetriever(client, vector, category) {
  const vectorStr = '[' + vector.join(',') + ']'

  const result = category
    ? await client.query(
        `SELECT ds.id AS section_id
         FROM ${SECTIONS_TABLE} ds
         WHERE ds.category = $2
           AND ds.header_embedding IS NOT NULL
         ORDER BY ds.header_embedding <=> $1::vector
         LIMIT $3`,
        [vectorStr, category, HEADER_LIMIT]
      )
    : await client.query(
        `SELECT ds.id AS section_id
         FROM ${SECTIONS_TABLE} ds
         WHERE ds.header_embedding IS NOT NULL
         ORDER BY ds.header_embedding <=> $1::vector
         LIMIT $2`,
        [vectorStr, HEADER_LIMIT]
      )

  return result.rows
}

// Reciprocal Rank Fusion — fuses multiple ranked lists into a single ranking.
// score(d) = Σ 1 / (k + rank_i(d)) across all retrievers that returned d.
// Higher score = more retrievers ranked this section highly.
function applyRRF(rankedLists) {
  const scores = new Map()

  for (const list of rankedLists) {
    list.forEach((item, rank) => {
      const id = item.section_id
      scores.set(id, (scores.get(id) || 0) + 1 / (RRF_K + rank + 1))
    })
  }

  return [...scores.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([section_id]) => ({ section_id }))
}

module.exports = { denseRetriever, sparseRetriever, headerRetriever, applyRRF }

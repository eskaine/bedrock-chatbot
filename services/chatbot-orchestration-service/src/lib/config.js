/**
 * config.js — single source of truth for all environment variables.
 *
 * Required variables throw at cold start if missing, so misconfiguration
 * surfaces immediately in Lambda init logs rather than as a cryptic runtime error.
 *
 * Optional variables are documented with the behaviour when absent.
 */

function _require(name) {
  const value = process.env[name]
  if (!value) throw new Error(`Required environment variable '${name}' is not set`)
  return value
}

// Always injected by the Lambda runtime
const REGION = process.env.AWS_REGION

// Required — Lambda init fails immediately if any of these are missing
const MODEL_ID      = _require('MODEL_ID')
const DB_SECRET_ARN = _require('DB_SECRET_ARN')
const POSTGRES_HOST = _require('POSTGRES_HOST')
const POSTGRES_DB   = _require('POSTGRES_DB')

// Optional — guardrails disabled if either is absent
const GUARDRAIL_ID      = process.env.GUARDRAIL_ID
const GUARDRAIL_VERSION = process.env.GUARDRAIL_VERSION

// Required — Lambda init fails immediately if either is missing
const PROMPT_ARN     = _require('PROMPT_ARN')
const PROMPT_VERSION = _require('PROMPT_VERSION')

// Required — classifier prompt for topic detection and query rewriting
const CLASSIFIER_PROMPT_ARN     = _require('CLASSIFIER_PROMPT_ARN')
const CLASSIFIER_PROMPT_VERSION = _require('CLASSIFIER_PROMPT_VERSION')

// Optional — conversation history disabled if absent
const SESSIONS_TABLE = process.env.SESSIONS_TABLE

module.exports = {
  REGION,
  MODEL_ID,
  GUARDRAIL_ID,
  GUARDRAIL_VERSION,
  DB_SECRET_ARN,
  PROMPT_ARN,
  PROMPT_VERSION,
  CLASSIFIER_PROMPT_ARN,
  CLASSIFIER_PROMPT_VERSION,
  SESSIONS_TABLE,
  POSTGRES_HOST,
  POSTGRES_DB,
}

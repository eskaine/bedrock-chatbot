/**
 * logger.js — structured JSON logger for CloudWatch.
 *
 * Each log line is a JSON object queryable in CloudWatch Insights:
 *   fields @timestamp, level, logger, message, error
 *   | filter logger = "retrieval" and level = "ERROR"
 *
 * Log level is controlled by the LOG_LEVEL environment variable (default: INFO).
 * Valid values: DEBUG, INFO, WARN, ERROR
 *
 * Usage:
 *   const { getLogger } = require('./logger')
 *   const logger = getLogger('my-module')
 *   logger.info('Something happened', { key: 'value' })
 *   logger.error('Something failed', { error: err.message })
 */

const LEVELS = { DEBUG: 0, INFO: 1, WARN: 2, ERROR: 3 }

const CURRENT_LEVEL = LEVELS[(process.env.LOG_LEVEL || 'INFO').toUpperCase()] ?? LEVELS.INFO

function log(level, name, message, extra = {}) {
  if (LEVELS[level] < CURRENT_LEVEL) return

  const entry = {
    timestamp: new Date().toISOString(),
    level,
    logger: name,
    message,
    ...extra,
  }

  const line = JSON.stringify(entry) + '\n'
  level === 'ERROR' || level === 'WARN'
    ? process.stderr.write(line)
    : process.stdout.write(line)
}

function getLogger(name) {
  return {
    debug: (message, extra) => log('DEBUG', name, message, extra),
    info:  (message, extra) => log('INFO',  name, message, extra),
    warn:  (message, extra) => log('WARN',  name, message, extra),
    error: (message, extra) => log('ERROR', name, message, extra),
  }
}

module.exports = { getLogger }

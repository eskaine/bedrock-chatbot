import { useState, useEffect } from 'react'
import { flushSync } from 'react-dom'
import type { Message } from '@typings/interfaces'
import { ERROR_LINE, OPENING_LINE, SERVER_ERROR_LINE, SESSION_EXPIRED_LINE } from '@typings/constants'
import { environment } from '@config/env'
import { ChatRole } from '@typings/enums'

const API_URL = environment.VITE_LAMBDA_API_URL
const SESSION_KEY = 'chatSessionId'
const TOPIC_KEY = 'chatTopic'

const OPENING_MESSAGE: Message = {
    id: '0',
    content: OPENING_LINE,
    role: ChatRole.Assistant,
    timestamp: new Date(),
}

function processNdjsonLine(
    line: string,
    appendChunk: (chunk: string) => void,
    applyContent: (content: string) => void,
) {
    if (!line.trim()) return
    try {
        const data = JSON.parse(line)
        if (data.chunk) appendChunk(data.chunk)
        else if (data.response) applyContent(data.response)
        else if (data.error) applyContent(data.error === 'Internal server error' ? SERVER_ERROR_LINE : ERROR_LINE)
    } catch {
        // skip malformed line
    }
}

export function useChat() {
    const [sessionId, setSessionId] = useState<string | null>(null)
    const [isExpired, setIsExpired] = useState(false)
    const [messages, setMessages] = useState<Message[]>([OPENING_MESSAGE])
    const [isLoading, setIsLoading] = useState(false)
    const [selectedTopic, setSelectedTopic] = useState<string | null>(
        () => sessionStorage.getItem(TOPIC_KEY)
    )

    useEffect(() => {
        const controller = new AbortController()
        const storedId = sessionStorage.getItem(SESSION_KEY)
        const headers: Record<string, string> = {}
        if (storedId) headers['X-Session-Id'] = storedId

        const onError = () => {
            setMessages(prev => [...prev, {
                id: Date.now().toString(),
                content: SERVER_ERROR_LINE,
                role: ChatRole.Assistant,
                timestamp: new Date(),
            }])
        }

        fetch(`${API_URL}/session`, { headers, signal: controller.signal })
            .then(res => res.ok ? res.json() : null)
            .then(data => {
                if (!data) { onError(); return }
                if (data.status === 'expired') {
                    sessionStorage.removeItem(TOPIC_KEY)
                    setIsExpired(true)
                    setSelectedTopic(null)
                    setMessages(prev => [...prev, {
                        id: Date.now().toString(),
                        content: SESSION_EXPIRED_LINE,
                        role: ChatRole.Assistant,
                        timestamp: new Date(),
                    }])
                    return
                }
                if (data.status === 'new') {
                    sessionStorage.removeItem(TOPIC_KEY)
                    setSelectedTopic(null)
                }
                sessionStorage.setItem(SESSION_KEY, data.sessionId)
                setSessionId(data.sessionId)
                if (data.history?.length) {
                    const history: Message[] = data.history.map(
                        (m: { role: string; content: string }, i: number) => ({
                            id: String(i + 1),
                            content: m.content,
                            role: m.role as ChatRole,
                            timestamp: new Date(),
                        })
                    )

                    console.log({history})
                    setMessages([OPENING_MESSAGE, ...history])
                }
            })
            .catch((err) => {
                if (err?.name === 'AbortError') return
                onError()
            })
        return () => controller.abort()
    }, [])

    const onTopicChange = (topic: string | null) => {
        if (topic) sessionStorage.setItem(TOPIC_KEY, topic)
        else sessionStorage.removeItem(TOPIC_KEY)
        setSelectedTopic(topic)
    }

    const streamResponse = async (body: ReadableStream<Uint8Array>, botId: string) => {
        const reader = body.getReader()
        const decoder = new TextDecoder()
        let buffer = ''
        let botMessageAdded = false

        const applyContent = (content: string) => {
            if (!botMessageAdded) {
                setIsLoading(false)
                botMessageAdded = true
                setMessages(prev => [...prev, { id: botId, content, role: ChatRole.Assistant, timestamp: new Date() }])
            } else {
                setMessages(prev => prev.map(m => m.id === botId ? { ...m, content } : m))
            }
        }

        const appendChunk = (chunk: string) => {
            if (!botMessageAdded) {
                setIsLoading(false)
                botMessageAdded = true
                setMessages(prev => [...prev, { id: botId, content: chunk, role: ChatRole.Assistant, timestamp: new Date() }])
            } else {
                flushSync(() => {
                    setMessages(prev => prev.map(m => m.id === botId ? { ...m, content: m.content + chunk } : m))
                })
            }
        }

        while (true) {
            const { done, value } = await reader.read()
            if (done) break
            buffer += decoder.decode(value, { stream: true })
            const lines = buffer.split('\n')
            buffer = lines.pop() ?? ''
            for (const line of lines) processNdjsonLine(line, appendChunk, applyContent)
        }

        if (buffer.trim()) processNdjsonLine(buffer, appendChunk, applyContent)
        if (!botMessageAdded) applyContent(SERVER_ERROR_LINE)
    }

    const sendMessage = async (content: string, topic: string | null) => {
        if (!sessionId) return

        const botId = (Date.now() + 1).toString()
        setMessages(prev => [...prev, {
            id: Date.now().toString(),
            content,
            role: ChatRole.User,
            timestamp: new Date(),
        }])
        setIsLoading(true)

        try {
            const response = await fetch(`${API_URL}/chat`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Session-Id': sessionId },
                body: JSON.stringify({ message: content, category: topic }),
            })

            if (!response.ok) {
                setMessages(prev => [...prev, {
                    id: botId,
                    content: response.status >= 500 ? SERVER_ERROR_LINE : ERROR_LINE,
                    role: ChatRole.Assistant,
                    timestamp: new Date(),
                }])
                return
            }

            if (!response.body) throw new Error()
            await streamResponse(response.body, botId)
        } catch {
            setMessages(prev => {
                const hasBotMsg = prev.some(m => m.id === botId)
                if (hasBotMsg) return prev.map(m => m.id === botId ? { ...m, content: SERVER_ERROR_LINE } : m)
                return [...prev, { id: botId, content: SERVER_ERROR_LINE, role: ChatRole.Assistant, timestamp: new Date() }]
            })
        } finally {
            setIsLoading(false)
        }
    }

    return { messages, isLoading, isExpired, selectedTopic, onTopicChange, sendMessage }
}

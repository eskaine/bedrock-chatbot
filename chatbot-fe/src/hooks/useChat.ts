import { useState, useEffect, useRef, useCallback } from 'react'
import type { Message } from '@typings/interfaces'
import { ERROR_LINE, OPENING_LINE, SERVER_ERROR_LINE, SESSION_EXPIRED_LINE } from '@typings/constants'
import { environment } from '@config/env'
import { ChatRole } from '@typings/enums'

const API_URL = environment.VITE_LAMBDA_API_URL
const MESSAGES_KEY = 'chatMessages'
const TAB_KEY = 'tabSession'

const OPENING_MESSAGE: Message = {
    id: '0',
    content: OPENING_LINE,
    role: ChatRole.Assistant,
    timestamp: new Date(),
}

function loadCachedMessages(): Message[] {
    try {
        const raw = sessionStorage.getItem(MESSAGES_KEY)
        if (!raw) return []
        const parsed = JSON.parse(raw)
        return parsed.map((m: { id: string; content: string; role: string; timestamp: string }) => ({
            ...m,
            role: m.role as ChatRole,
            timestamp: new Date(m.timestamp),
        }))
    } catch {
        return []
    }
}

function processNdjsonLine(
    line: string,
    appendChunk: (chunk: string) => void,
    applyContent: (content: string) => void,
    onSessionExpired?: () => void,
) {
    if (!line.trim()) return
    try {
        const data = JSON.parse(line)
        if (data.chunk) appendChunk(data.chunk)
        else if (data.response) applyContent(data.response)
        else if (data.error === 'session_expired') onSessionExpired?.()
else if (data.error) applyContent(data.error === 'Internal server error' ? SERVER_ERROR_LINE : ERROR_LINE)
    } catch {
        // skip malformed line
    }
}

export function useChat() {
    const [sessionId, setSessionId] = useState<string | null>(null)
    const [isExpired, setIsExpired] = useState(false)
    const [isInitializing, setIsInitializing] = useState(true)
    const [messages, setMessages] = useState<Message[]>([OPENING_MESSAGE])
    const [isLoading, setIsLoading] = useState(false)
    const [isVoiceProcessing, setIsVoiceProcessing] = useState(false)
    const [isVoiceResponding, setIsVoiceResponding] = useState(false)
    const [isAudioPlaying, setIsAudioPlaying] = useState(false)
    const audioRef = useRef<HTMLAudioElement | null>(null)
    const audioQueueRef = useRef<string[]>([])
    const isPlayingQueueRef = useRef(false)
    const voiceStoppedRef = useRef(false)
    const [sessionTrigger, setSessionTrigger] = useState(0)

    useEffect(() => {
        if (isInitializing) return
        const toCache = messages.filter(m => m.id !== OPENING_MESSAGE.id && m.role !== ChatRole.System)
        if (toCache.length > 0) sessionStorage.setItem(MESSAGES_KEY, JSON.stringify(toCache))
    }, [messages, isInitializing])

    const onNewSession = async () => {
        sessionStorage.removeItem(MESSAGES_KEY)
        setSessionId(null)
        setIsExpired(false)
        setIsInitializing(true)
        setMessages([OPENING_MESSAGE])
        try {
            await fetch(`${API_URL}/session`, { method: 'DELETE', credentials: 'include' })
        } catch {
            // non-blocking — session effect will handle any resulting error
        }
        setSessionTrigger(t => t + 1)
    }

    useEffect(() => {
        const controller = new AbortController()

        // New tab: force a fresh session before proceeding
        if (!sessionStorage.getItem(TAB_KEY)) {
            sessionStorage.setItem(TAB_KEY, '1')
            sessionStorage.removeItem(MESSAGES_KEY)
            fetch(`${API_URL}/session`, { method: 'DELETE', credentials: 'include' })
                .catch(() => {})
                .finally(() => setSessionTrigger(t => t + 1))
            return () => controller.abort()
        }

        const onError = () => {
            setMessages(prev => [...prev, {
                id: crypto.randomUUID(),
                content: SERVER_ERROR_LINE,
                role: ChatRole.Assistant,
                timestamp: new Date(),
            }])
            setIsInitializing(false)
        }

        fetch(`${API_URL}/session`, { credentials: 'include', signal: controller.signal })
            .then(res => res.ok ? res.json() : null)
            .then(data => {
                if (!data) { onError(); return }
                if (data.status === 'new') {
                    sessionStorage.removeItem(MESSAGES_KEY)
                }

                const history: Message[] = data.history?.length
                    ? data.history.map((m: { role: string; content: string }, i: number) => ({
                        id: String(i + 1),
                        content: m.content,
                        role: m.role as ChatRole,
                        timestamp: new Date(),
                    }))
                    : []

                if (data.status === 'expired') {
                    setIsExpired(true)
                    const displayHistory = history.length ? history : loadCachedMessages()
                    setMessages([OPENING_MESSAGE, ...displayHistory, {
                        id: crypto.randomUUID(),
                        content: SESSION_EXPIRED_LINE,
                        role: ChatRole.System,
                        timestamp: new Date(),
                    }])
                    setIsInitializing(false)
                    return
                }

                setSessionId(data.sessionId)
                if (history.length) {
                    setMessages([OPENING_MESSAGE, ...history])
                }
                setIsInitializing(false)
            })
            .catch((err) => {
                if (err?.name === 'AbortError') return
                onError()
            })
        return () => controller.abort()
    }, [sessionTrigger])

    const streamResponse = async (body: ReadableStream<Uint8Array>, botId: string, onSessionExpired: () => void) => {
        const reader = body.getReader()
        const decoder = new TextDecoder()
        let buffer = ''
        let botMessageAdded = false
        let sessionExpiredSignal = false

        const handleSessionExpired = () => {
            sessionExpiredSignal = true
            onSessionExpired()
        }

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
                setMessages(prev => prev.map(m => m.id === botId ? { ...m, content: m.content + chunk } : m))
            }
        }

        while (true) {
            const { done, value } = await reader.read()
            if (done) break
            buffer += decoder.decode(value, { stream: true })
            const lines = buffer.split('\n')
            buffer = lines.pop() ?? ''
            for (const line of lines) processNdjsonLine(line, appendChunk, applyContent, handleSessionExpired)
        }

        if (buffer.trim()) processNdjsonLine(buffer, appendChunk, applyContent, handleSessionExpired)
        if (!botMessageAdded && !sessionExpiredSignal) applyContent(SERVER_ERROR_LINE)
    }

    const playNext = useCallback(() => {
        if (voiceStoppedRef.current || audioQueueRef.current.length === 0) {
            setIsVoiceResponding(false)
            setIsAudioPlaying(false)
            audioRef.current = null
            isPlayingQueueRef.current = false
            return
        }
        isPlayingQueueRef.current = true
        const b64 = audioQueueRef.current.shift()!
        const audioBytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0))
        const blob = new Blob([audioBytes], { type: 'audio/mpeg' })
        const url = URL.createObjectURL(blob)
        const audio = new Audio(url)
        audioRef.current = audio
        audio.addEventListener('ended', () => {
            URL.revokeObjectURL(url)
            playNext()
        })
        setIsVoiceResponding(false)
        setIsAudioPlaying(true)
        audio.play().catch(() => {
            setIsVoiceResponding(false)
            setIsAudioPlaying(false)
            isPlayingQueueRef.current = false
        })
    }, [])

    const sendMessage = async (content: string) => {
        if (!sessionId || isExpired) {
            if (isExpired) {
                setMessages(prev => {
                    const userMsg = { id: crypto.randomUUID(), content, role: ChatRole.User, timestamp: new Date() }
                    const expiredMsg = { id: crypto.randomUUID(), content: SESSION_EXPIRED_LINE, role: ChatRole.System, timestamp: new Date() }
                    return [...prev.filter(m => m.role !== ChatRole.System), userMsg, expiredMsg]
                })
            }
            return
        }

        const userMsgId = crypto.randomUUID()
        const botId = crypto.randomUUID()
        setMessages(prev => [...prev, {
            id: userMsgId,
            content,
            role: ChatRole.User,
            timestamp: new Date(),
        }])
        setIsLoading(true)

        try {
            const response = await fetch(`${API_URL}/chat`, {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ message: content }),
            })

            if (response.status === 401) {
                setIsExpired(true)
                setMessages(prev => [
                    ...prev,
                    { id: botId, content: SESSION_EXPIRED_LINE, role: ChatRole.System, timestamp: new Date() },
                ])
                return
            }

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
            const handleSessionExpired = () => {
                setIsExpired(true)
                setMessages(prev => [
                    ...prev,
                    { id: botId, content: SESSION_EXPIRED_LINE, role: ChatRole.System, timestamp: new Date() },
                ])
            }
            await streamResponse(response.body, botId, handleSessionExpired)
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

    const sendVoiceMessage = async (pcm: ArrayBuffer, sampleRate: number) => {
        if (!sessionId || isExpired) return

        setIsVoiceProcessing(true)
        audioQueueRef.current = []
        isPlayingQueueRef.current = false
        voiceStoppedRef.current = false

        try {
            const bytes = new Uint8Array(pcm)
            let binary = ''
            const chunkSize = 8192
            for (let i = 0; i < bytes.length; i += chunkSize) {
                binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize))
            }

            const response = await fetch(`${API_URL}/voice-chat`, {
                method: 'POST',
                credentials: 'include',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ audio: btoa(binary), sample_rate: sampleRate }),
            })

            if (response.status === 401) {
                setIsExpired(true)
                setMessages(prev => [...prev, {
                    id: crypto.randomUUID(),
                    content: SESSION_EXPIRED_LINE,
                    role: ChatRole.System,
                    timestamp: new Date(),
                }])
                return
            }

            if (!response.ok || !response.body) throw new Error()

            const reader = response.body.getReader()
            const decoder = new TextDecoder()
            let buffer = ''
            const botId = crypto.randomUUID()
            let botMessageAdded = false

            while (true) {
                const { done, value } = await reader.read()
                if (done) break
                buffer += decoder.decode(value, { stream: true })
                const lines = buffer.split('\n')
                buffer = lines.pop() ?? ''
                for (const line of lines) {
                    if (!line.trim()) continue
                    try {
                        const data = JSON.parse(line)
                        if (data.type === 'transcription') {
                            // User message appears — switch from button spinner to chat loading
                            setMessages(prev => [...prev, {
                                id: crypto.randomUUID(),
                                content: data.text,
                                role: ChatRole.User,
                                timestamp: new Date(),
                            }])
                            setIsVoiceProcessing(false)
                            setIsVoiceResponding(true)
                        } else if (data.type === 'chunk') {
                            // Raw LLM text — stream into bot message in real time
                            if (!botMessageAdded) {
                                botMessageAdded = true
                                setMessages(prev => [...prev, { id: botId, content: data.text, role: ChatRole.Assistant, timestamp: new Date() }])
                            } else {
                                setMessages(prev => prev.map(m => m.id === botId ? { ...m, content: m.content + data.text } : m))
                            }
                        } else if (data.type === 'audio') {
                            // Audio chunk — queue and play (text already shown via chunk events)
                            if (!voiceStoppedRef.current) {
                                audioQueueRef.current.push(data.audio)
                                if (!isPlayingQueueRef.current) playNext()
                            }
                        } else if (data.type === 'error') {
                            if (!botMessageAdded) {
                                botMessageAdded = true
                                setMessages(prev => [...prev, { id: botId, content: SERVER_ERROR_LINE, role: ChatRole.Assistant, timestamp: new Date() }])
                            }
                        }
                    } catch { }
                }
            }

            if (!botMessageAdded) {
                setMessages(prev => [...prev, { id: botId, content: SERVER_ERROR_LINE, role: ChatRole.Assistant, timestamp: new Date() }])
            }
        } catch {
            setMessages(prev => [...prev, {
                id: crypto.randomUUID(),
                content: SERVER_ERROR_LINE,
                role: ChatRole.Assistant,
                timestamp: new Date(),
            }])
        } finally {
            setIsVoiceProcessing(false)
            setIsVoiceResponding(false)
        }
    }

    const stopAudio = () => {
        voiceStoppedRef.current = true
        audioQueueRef.current = []
        isPlayingQueueRef.current = false
        audioRef.current?.pause()
        audioRef.current = null
        setIsAudioPlaying(false)
    }

    return { messages, isLoading, isVoiceProcessing, isVoiceResponding, isAudioPlaying, isExpired, isInitializing, sendMessage, sendVoiceMessage, stopAudio, onNewSession }
}

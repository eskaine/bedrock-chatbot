import { useState, useEffect } from 'react'
import { flushSync } from 'react-dom'
import './App.css'
import { ChatDialog } from './components/ChatDialog'
import type { Message } from "@typings/interfaces"
import { ERROR_LINE, OPENING_LINE, SERVER_ERROR_LINE } from "@typings/constants"
import { environment } from '@config/env'
import { ChatRole } from '@typings/enums'

const LAMBDA_API_URL = environment.VITE_LAMBDA_API_URL

function getSessionId(): string {
  const key = 'chatSessionId'
  const existing = sessionStorage.getItem(key)
  if (existing) return existing
  const id = crypto.randomUUID()
  sessionStorage.setItem(key, id)
  return id
}

const sessionId = getSessionId()

function App() {
  const [messages, setMessages] = useState<Message[]>([{
    id: '0',
    content: OPENING_LINE,
    role: ChatRole.Assistant,
    timestamp: new Date()
  }])
  const [isLoading, setIsLoading] = useState(false)
  const [selectedTopic, setSelectedTopic] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    fetch(`${LAMBDA_API_URL}/history`, {
      headers: { 'X-Session-Id': sessionId },
      signal: controller.signal,
    })
      .then(res => res.ok ? res.json() : null)
      .then(data => {
        if (!data?.messages?.length) return
        const history: Message[] = data.messages.map(
          (m: { role: string; content: string }, i: number) => ({
            id: String(i + 1),
            content: m.content,
            role: m.role as ChatRole,
            timestamp: new Date(),
          })
        )
        setMessages([
          { id: '0', content: OPENING_LINE, role: ChatRole.Assistant, timestamp: new Date() },
          ...history,
        ])
      })
      .catch(() => {})
    return () => controller.abort()
  }, [])

  const sendMessage = async (content: string) => {
    const userMessage: Message = {
      id: Date.now().toString(),
      content,
      role: ChatRole.User,
      timestamp: new Date(),
    }
    const botId = (Date.now() + 1).toString()

    setMessages((prev) => [...prev, userMessage])
    setIsLoading(true)

    try {
      const response = await fetch(`${LAMBDA_API_URL}/chat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Session-Id': sessionId },
        body: JSON.stringify({ message: content, category: selectedTopic }),
      })

      if (!response.ok) {
        setMessages((prev) => [...prev, {
          id: botId,
          content: response.status >= 500 ? SERVER_ERROR_LINE : ERROR_LINE,
          role: ChatRole.Assistant,
          timestamp: new Date(),
        }])
        return
      }

      if (!response.body) throw new Error()

      const reader = response.body.getReader()
      const decoder = new TextDecoder()

      let buffer = ''
      let botMessageAdded = false

      const applyContent = (content: string) => {
        if (!botMessageAdded) {
          setIsLoading(false)
          botMessageAdded = true
          setMessages((prev) => [...prev, {
            id: botId,
            content,
            role: ChatRole.Assistant,
            timestamp: new Date(),
          }])
        } else {
          setMessages((prev) => prev.map((m) =>
            m.id === botId ? { ...m, content } : m
          ))
        }
      }

      const appendChunk = (chunk: string) => {
        if (!botMessageAdded) {
          setIsLoading(false)
          botMessageAdded = true
          setMessages((prev) => [...prev, {
            id: botId,
            content: chunk,
            role: ChatRole.Assistant,
            timestamp: new Date(),
          }])
        } else {
          flushSync(() => {
            setMessages((prev) => prev.map((m) =>
              m.id === botId ? { ...m, content: m.content + chunk } : m
            ))
          })
        }
      }

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
            if (data.chunk) {
              appendChunk(data.chunk)
            } else if (data.response) {
              applyContent(data.response)
            } else if (data.error) {
              applyContent(data.error === 'Internal server error' ? SERVER_ERROR_LINE : ERROR_LINE)
            }
          } catch {
            // skip malformed lines
          }
        }
      }

      if (buffer.trim()) {
        try {
          const data = JSON.parse(buffer)
          if (data.chunk) {
            appendChunk(data.chunk)
          } else if (data.response) {
            applyContent(data.response)
          } else if (data.error) {
            applyContent(data.error === 'Internal server error' ? SERVER_ERROR_LINE : ERROR_LINE)
          }
        } catch {
          // skip malformed final chunk
        }
      }
    } catch {
      setMessages((prev) => {
        const hasBotMsg = prev.some((m) => m.id === botId)
        if (hasBotMsg) {
          return prev.map((m) => m.id === botId ? { ...m, content: SERVER_ERROR_LINE } : m)
        }
        return [...prev, {
          id: botId,
          content: SERVER_ERROR_LINE,
          role: ChatRole.Assistant,
          timestamp: new Date(),
        }]
      })
    } finally {
      setIsLoading(false)
    }
  }

  return (
    <div className="h-screen flex items-center justify-center">
      <div className='flex flex-col gap-5 items-center'>
        <div className="text-4xl font-bold">AI Chatbot</div>
        <ChatDialog
          messages={messages}
          onSendMessage={sendMessage}
          isLoading={isLoading}
          selectedTopic={selectedTopic}
          onTopicChange={setSelectedTopic}
        />
      </div>
    </div>
  )
}

export default App

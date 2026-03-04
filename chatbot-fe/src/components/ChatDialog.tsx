import { useState, useEffect, useRef } from "react"
import Markdown from "react-markdown"
import remarkGfm from "remark-gfm"
import { messageSchema } from "@schemas/message"
import { ALLOWED_CHARS_REGEX, MAX_MESSAGE_LENGTH } from "@typings/constants"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from "@components/ui/dialog"
import { Input } from "@components/ui/input"
import { Button } from "@components/ui/button"
import { ScrollArea } from "@components/ui/scroll-area"
import { Avatar, AvatarFallback, AvatarImage } from '@components/ui/avatar'
import { MessageLoading } from "./MessageLoading"
import type { Message } from "@typings/interfaces"

const TOPICS = [
    { label: 'Aegis', value: 'aegis' },
    { label: 'QualiFly', value: 'qualifly' },
]

interface ChatDialogProps {
    messages: Message[]
    onSendMessage: (content: string) => void
    isLoading?: boolean
    selectedTopic: string | null
    onTopicChange: (topic: string | null) => void
}

export function ChatDialog({ messages, onSendMessage, isLoading, selectedTopic, onTopicChange }: ChatDialogProps) {
    const [inputValue, setInputValue] = useState("")
    const bottomRef = useRef<HTMLDivElement>(null)
    const hasUserMessage = messages.some((m) => m.role === 'user')

    useEffect(() => {
        bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
    }, [messages])

    const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
        const value = e.target.value.replace(ALLOWED_CHARS_REGEX, '').slice(0, MAX_MESSAGE_LENGTH)
        setInputValue(value)
    }

    const handleSend = () => {
        const result = messageSchema.safeParse(inputValue.trim())
        if (result.success && !isLoading) {
            onSendMessage(result.data)
            setInputValue("")
        }
    }

    const handleKeyDown = (e: React.KeyboardEvent) => {
        if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault()
            handleSend()
        }
    }

    return (
        <Dialog modal={false}>
            <DialogTrigger asChild>
                <Avatar className='w-20 h-20 border-5 border-solid border-primary cursor-pointer'>
                    <AvatarImage
                        src="https://github.com/shadcn.png"
                        alt="@shadcn"
                    />
                    <AvatarFallback>RB</AvatarFallback>
                </Avatar>
            </DialogTrigger>
            <DialogContent className="h-[calc(100dvh-4rem)] max-h-[750px] sm:max-w-sm flex flex-col gap-0 p-0 text-sm">
                <DialogHeader className="px-6 py-4 border-b">
                    <DialogTitle>Chat</DialogTitle>
                    <DialogDescription className="sr-only">Chat assistant</DialogDescription>
                </DialogHeader>
                <ScrollArea className="flex-1 px-6 py-0 overflow-y-auto">
                    <div className="space-y-4 py-6">
                        {messages.map((message, index) => (
                            <div key={message.id}>
                                <div className={`flex ${message.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                                    <div
                                        className={`rounded-lg px-4 py-2 max-w-[80%] ${message.role === 'user'
                                                ? 'bg-primary text-primary-foreground'
                                                : 'bg-muted'
                                            }`}
                                    >
                                        <Markdown
                                            remarkPlugins={[remarkGfm]}
                                            components={{
                                                p: ({ children }) => <p className="mb-2 last:mb-0">{children}</p>,
                                                ul: ({ children }) => <ul className="list-disc pl-4 mb-2 space-y-1">{children}</ul>,
                                                ol: ({ children }) => <ol className="list-decimal pl-4 mb-2 space-y-1">{children}</ol>,
                                                li: ({ children }) => <li className="leading-snug">{children}</li>,
                                                strong: ({ children }) => <strong className="font-semibold">{children}</strong>,
                                            }}
                                        >{message.content}</Markdown>
                                    </div>
                                </div>
                                {index === 0 && (
                                    hasUserMessage && selectedTopic ? (
                                        <div className="flex justify-start mt-2">
                                            <div className="rounded-lg px-4 py-2 max-w-[80%] bg-muted">
                                                You have selected <span className="font-semibold">{TOPICS.find(t => t.value === selectedTopic)?.label}</span>.
                                            </div>
                                        </div>
                                    ) : (
                                        <div className="mt-8 border-2 overflow-hidden w-48 mx-auto rounded-sm">
                                            {TOPICS.map((topic, i) => (
                                                <button
                                                    key={topic.value}
                                                    onClick={() => onTopicChange(selectedTopic === topic.value ? null : topic.value)}
                                                    className={`w-full text-center px-4 py-1.5 text-sm transition-colors ${i > 0 ? 'border-t' : ''} ${
                                                        selectedTopic === topic.value
                                                            ? 'bg-primary text-primary-foreground'
                                                            : 'bg-background text-foreground hover:bg-muted'
                                                    }`}
                                                >
                                                    {topic.label}
                                                </button>
                                            ))}
                                        </div>
                                    )
                                )}
                            </div>
                        ))}
                        {isLoading && (
                            <MessageLoading />
                        )}
                        <div ref={bottomRef} />
                    </div>
                </ScrollArea>

                <div className="p-4 border-t flex gap-2">
                    <Input
                        placeholder="Type a message..."
                        value={inputValue}
                        onChange={handleChange}
                        onKeyDown={handleKeyDown}
                        disabled={isLoading || !selectedTopic}
                        maxLength={MAX_MESSAGE_LENGTH}
                    />
                    <Button variant="default" onClick={handleSend} disabled={isLoading || !inputValue.trim() || !selectedTopic}>
                        Send
                    </Button>
                </div>
            </DialogContent>
        </Dialog>
    )
}

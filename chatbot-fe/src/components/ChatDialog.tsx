import { useState, useEffect, useRef } from "react"
import Markdown from "react-markdown"
import remarkGfm from "remark-gfm"
import { Mic, Square, Send, VolumeX, ChevronDown } from "lucide-react"
import { messageSchema } from "@schemas/message"
import { ALLOWED_CHARS_REGEX, MAX_MESSAGE_LENGTH } from "@typings/constants"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from "@components/ui/dialog"
import { Input } from "@components/ui/input"
import { Button } from "@components/ui/button"
import { Avatar, AvatarFallback, AvatarImage } from '@components/ui/avatar'
import { MessageLoading } from "./MessageLoading"
import { Spinner } from "@components/ui/spinner"
import { ChatRole } from "@typings/enums"
import type { Message } from "@typings/interfaces"
import { useVoiceRecorder } from "@hooks/useVoiceRecorder"

interface ChatDialogProps {
    messages: Message[]
    onSendMessage: (content: string) => void
    onSendVoiceMessage: (pcm: ArrayBuffer, sampleRate: number) => void
    isLoading?: boolean
    isVoiceProcessing?: boolean
    isVoiceResponding?: boolean
    isAudioPlaying?: boolean
    onStopAudio?: () => void
    isExpired?: boolean
    isInitializing?: boolean
    onNewSession: () => void
}

export function ChatDialog({ messages, onSendMessage, onSendVoiceMessage, isLoading, isVoiceProcessing, isVoiceResponding, isAudioPlaying, onStopAudio, isExpired, isInitializing, onNewSession }: ChatDialogProps) {
    const [inputValue, setInputValue] = useState("")
    const [showScrollButton, setShowScrollButton] = useState(false)
    const scrollRef = useRef<HTMLDivElement>(null)
    const { isRecording, startRecording, stopAndSend } = useVoiceRecorder(onSendVoiceMessage)
    const isBusy = isLoading || isVoiceProcessing || isVoiceResponding || isExpired

    useEffect(() => {
        const el = scrollRef.current
        if (el) el.scrollTop = el.scrollHeight
    }, [messages])

    const handleScroll = () => {
        const el = scrollRef.current
        if (!el) return
        setShowScrollButton(el.scrollHeight - el.scrollTop - el.clientHeight > 100)
    }

    const scrollToBottom = () => {
        const el = scrollRef.current
        if (!el) return
        el.scrollTop = el.scrollHeight
    }

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
                <div className="relative flex-1 overflow-hidden">
                <div ref={scrollRef} onScroll={handleScroll} className="h-full px-6 overflow-y-auto">
                    {isInitializing && (
                        <div className="flex items-center justify-center h-full">
                            <Spinner className="size-6" />
                        </div>
                    )}
                    <div className={`space-y-4 py-6 ${isInitializing ? 'hidden' : ''}`}>
                        {messages.map((message) => (
                            <div key={message.id}>
                                {message.role === ChatRole.System ? (
                                    <div className="text-center text-muted-foreground text-xs py-2">
                                        {message.content}
                                    </div>
                                ) : (
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
                                )}
                                </div>
                        ))}
                        {(isLoading || isVoiceResponding) && (
                            <MessageLoading />
                        )}
                        {isExpired && (
                            <div className="text-center text-xs py-2">
                                <button onClick={onNewSession} className="text-primary underline underline-offset-2 cursor-pointer">
                                    Start a new session
                                </button>
                            </div>
                        )}
                    </div>
                </div>
                {showScrollButton && (
                    <Button
                        variant="secondary"
                        size="icon"
                        className="absolute bottom-3 right-6 rounded-full shadow-md"
                        onClick={scrollToBottom}
                    >
                        <ChevronDown className="size-4" />
                    </Button>
                )}
                </div>

                <div className="p-4 border-t flex gap-2">
                    {isRecording ? (
                        <div className="flex flex-1 items-center gap-3 px-3 py-2 rounded-md border bg-muted">
                            <span className="size-2 rounded-full bg-red-500 animate-pulse" />
                            <span className="text-sm text-muted-foreground flex-1">Recording...</span>
                        </div>
                    ) : (
                        <Input
                            placeholder="Type a message..."
                            value={inputValue}
                            onChange={handleChange}
                            onKeyDown={handleKeyDown}
                            disabled={isBusy}
                            maxLength={MAX_MESSAGE_LENGTH}
                        />
                    )}
                    {isRecording ? (
                        <Button variant="destructive" size="icon" onClick={stopAndSend}>
                            <Square className="size-4 fill-current" />
                        </Button>
                    ) : isAudioPlaying ? (
                        <Button variant="destructive" size="icon" onClick={onStopAudio}>
                            <VolumeX className="size-4" />
                        </Button>
                    ) : inputValue.trim() ? (
                        <Button variant="default" size="icon" onClick={handleSend} disabled={isBusy}>
                            <Send className="size-4" />
                        </Button>
                    ) : (
                        <Button variant="outline" size="icon" onClick={startRecording} disabled={isBusy || isVoiceProcessing}>
                            {(isVoiceProcessing || isVoiceResponding) ? <Spinner className="size-4" /> : <Mic className="size-4" />}
                        </Button>
                    )}
                </div>
            </DialogContent>
        </Dialog>
    )
}

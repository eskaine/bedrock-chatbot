export const ChatRole = {
    User: 'user',
    Assistant: 'assistant',
    System: 'system',
} as const

export type ChatRole = typeof ChatRole[keyof typeof ChatRole]

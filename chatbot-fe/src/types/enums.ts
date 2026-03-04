export const ChatRole = {
    User: 'user',
    Assistant: 'assistant'
} as const

export type ChatRole = typeof ChatRole[keyof typeof ChatRole]

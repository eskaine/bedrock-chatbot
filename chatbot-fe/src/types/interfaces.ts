import type { ChatRole } from '@typings/enums'

export interface Message {
    id: string
    content: string
    role: ChatRole
    timestamp: Date
}

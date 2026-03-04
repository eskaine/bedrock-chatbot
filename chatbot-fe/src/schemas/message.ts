import { z } from "zod"
import { MAX_MESSAGE_LENGTH, ALLOWED_CHARS_PATTERN } from "@/types/constants"

export const messageSchema = z.string()
    .min(1, "Message is required")
    .max(MAX_MESSAGE_LENGTH, `Message must be under ${MAX_MESSAGE_LENGTH} characters`)
    .regex(ALLOWED_CHARS_PATTERN)

import { envSchema } from "@schemas/env"

const parsed = envSchema.safeParse(import.meta.env)

if (!parsed.success) {
    console.error("Invalid environment variables:", parsed.error.flatten().fieldErrors)
    throw new Error("Invalid environment variables")
}

export const environment = parsed.data

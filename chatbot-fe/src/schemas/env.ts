import z from "zod";

export const envSchema = z.object({
    VITE_LAMBDA_API_URL: z.string().url("VITE_LAMBDA_API_URL must be a valid URL"),
})

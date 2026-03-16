import { useState, useRef, useCallback } from 'react'

function float32ToInt16(samples: Float32Array): Int16Array {
    const out = new Int16Array(samples.length)
    for (let i = 0; i < samples.length; i++) {
        const s = Math.max(-1, Math.min(1, samples[i]))
        out[i] = s < 0 ? s * 0x8000 : s * 0x7FFF
    }
    return out
}

export function useVoiceRecorder(onComplete: (pcm: ArrayBuffer, sampleRate: number) => void) {
    const [isRecording, setIsRecording] = useState(false)
    const contextRef = useRef<AudioContext | null>(null)
    const workletNodeRef = useRef<AudioWorkletNode | null>(null)
    const streamRef = useRef<MediaStream | null>(null)
    const chunksRef = useRef<Int16Array[]>([])
    const sampleRateRef = useRef(16000)
    const onCompleteRef = useRef(onComplete)
    onCompleteRef.current = onComplete

    const startRecording = useCallback(async () => {
        try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false })
            const context = new AudioContext()
            sampleRateRef.current = context.sampleRate

            const workletCode = `
                class AudioProcessor extends AudioWorkletProcessor {
                    process(inputs) {
                        const input = inputs[0]
                        if (input && input[0]) this.port.postMessage(input[0].slice())
                        return true
                    }
                }
                registerProcessor('audio-processor', AudioProcessor)
            `
            const blob = new Blob([workletCode], { type: 'application/javascript' })
            const workletUrl = URL.createObjectURL(blob)
            await context.audioWorklet.addModule(workletUrl)
            URL.revokeObjectURL(workletUrl)
            const workletNode = new AudioWorkletNode(context, 'audio-processor')
            const source = context.createMediaStreamSource(stream)

            workletNode.port.onmessage = (e: MessageEvent<Float32Array>) => {
                chunksRef.current.push(float32ToInt16(e.data))
            }

            source.connect(workletNode)
            workletNode.connect(context.destination)

            contextRef.current = context
            workletNodeRef.current = workletNode
            streamRef.current = stream
            chunksRef.current = []
            setIsRecording(true)
        } catch {
            // mic permission denied or unavailable
        }
    }, [])

    const stopAndSend = useCallback(async () => {
        if (!contextRef.current) return

        const chunks = [...chunksRef.current]
        const sampleRate = sampleRateRef.current

        workletNodeRef.current?.disconnect()
        streamRef.current?.getTracks().forEach(t => t.stop())
        await contextRef.current.close()
        contextRef.current = null
        workletNodeRef.current = null
        streamRef.current = null
        chunksRef.current = []
        setIsRecording(false)

        if (chunks.length === 0) return

        const totalLength = chunks.reduce((acc, c) => acc + c.length, 0)
        const pcm = new Int16Array(totalLength)
        let offset = 0
        for (const chunk of chunks) {
            pcm.set(chunk, offset)
            offset += chunk.length
        }

        onCompleteRef.current(pcm.buffer, sampleRate)
    }, [])

    return { isRecording, startRecording, stopAndSend }
}

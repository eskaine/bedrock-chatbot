import './App.css'
import { ChatDialog } from './components/ChatDialog'
import { useChat } from '@hooks/useChat'

function App() {
  const { messages, isLoading, isVoiceProcessing, isVoiceResponding, isAudioPlaying, isExpired, isInitializing, sendMessage, sendVoiceMessage, stopAudio, onNewSession } = useChat()

  return (
    <div className="h-screen flex items-center justify-center">
      <div className='flex flex-col gap-5 items-center'>
        <div className="text-4xl font-bold">Ask Hock Ming</div>
        <ChatDialog
          messages={messages}
          onSendMessage={sendMessage}
          onSendVoiceMessage={sendVoiceMessage}
          isLoading={isLoading}
          isVoiceProcessing={isVoiceProcessing}
          isVoiceResponding={isVoiceResponding}
          isAudioPlaying={isAudioPlaying}
          onStopAudio={stopAudio}
          isExpired={isExpired}
          isInitializing={isInitializing}
          onNewSession={onNewSession}
        />
      </div>
    </div>
  )
}

export default App

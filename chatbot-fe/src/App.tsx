import './App.css'
import { ChatDialog } from './components/ChatDialog'
import { useChat } from '@hooks/useChat'

function App() {
  const { messages, isLoading, isExpired, selectedTopic, onTopicChange, sendMessage } = useChat()

  return (
    <div className="h-screen flex items-center justify-center">
      <div className='flex flex-col gap-5 items-center'>
        <div className="text-4xl font-bold">Ask Chatbot</div>
        <ChatDialog
          messages={messages}
          onSendMessage={(content) => sendMessage(content, selectedTopic)}
          isLoading={isLoading}
          isExpired={isExpired}
          selectedTopic={selectedTopic}
          onTopicChange={onTopicChange}
        />
      </div>
    </div>
  )
}

export default App

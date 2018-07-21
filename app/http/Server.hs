{-# LANGUAGE NamedFieldPuns #-}
module Server where

import           Control.Concurrent
import           Control.Monad.Logger
import           Control.Monad.State.Strict hiding (state)
import           Data.Map.Strict            (Map)
import qualified Data.Text                  as T
import           Data.Time.Clock            (getCurrentTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime,
                                             iso8601DateFormat)
import           Raft
import           Raft.Log                   (RequestId)
import           Raft.Server                (ServerState (..))

data Config a b machine = Config { state :: MVar (ServerState a, machine)
                                 , queue :: Chan (Message a b)
                                 , apply :: a -> StateT machine (LoggingT IO) b
                                 , requests :: MVar (Map RequestId (MVar (Message a b)))
                                 }

logState :: (Show a, Show machine) => Config a b machine -> LoggingT IO ()
logState Config { state } = do
  liftIO $ threadDelay 2000000
  (ServerState { _role, _serverTerm, _electionTimer, _electionTimeout }, m) <- liftIO $ readMVar state
  (logInfoN . T.pack . show) (_role, _serverTerm, m)

-- Apply a Raft message to the state
processMessage :: Config a b machine -> Message a b -> LoggingT IO ()
processMessage Config { state, queue, apply } msg = do
  (s, m) <- liftIO $ takeMVar state
  (msgs, server', machine') <- handleMessage_ s m msg apply
  liftIO $ putMVar state (server', machine')
  liftIO $ writeList2Chan queue msgs

processTick :: Config a b machine -> LoggingT IO ()
processTick config = processMessage config (Tick 0)

handleMessage_ :: MonadIO m => ServerState a -> machine -> Message a b -> (a -> StateT machine (LoggingT m) b) -> LoggingT m ([Message a b], ServerState a, machine)
handleMessage_ server machine msg apply = do
  ((msgs, server'), machine') <- runStateT (runStateT (handleMessage apply msg) server) machine
  pure (msgs, server', machine')

printLog :: T.Text -> IO ()
printLog msg = do
  time <- getCurrentTime
  let format = iso8601DateFormat (Just "%H:%M:%S:%Q")
      timestamp = formatTime defaultTimeLocale format time
  putStrLn $ timestamp ++ " " ++ show msg

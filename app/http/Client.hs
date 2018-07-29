module Client where

import           Data.Maybe          (fromMaybe)
import           Network.HTTP.Client (Manager, defaultManagerSettings,
                                      newManager)
import           Servant
import           Servant.Client
import           System.Random

import           Api
import           Raft.Log            (RequestId (RequestId))
import           Raft.Rpc            (ClientReq (..), ClientRes (..))
import           Raft.Server         (ServerId (..))

runClient :: [String] -> IO ()
runClient args = do
  reqId <- RequestId <$> randomIO
  let serverUrl = head args
      cmd = case args of
          [_, "get"]    -> Get
          [_, "set", n] -> Set (read n)
      req = ClientReq { _requestPayload = cmd, _clientRequestId = reqId }
  manager <- newManager defaultManagerSettings
  url <- parseBaseUrl serverUrl
  let env = ClientEnv { manager = manager, baseUrl = url, cookieJar = Nothing }
  res <- runClientM (sendClientRequest req) env
  case res of
    Left err -> print err
    Right ClientRes { _responsePayload = p } -> case p of
                                                  Left err -> print err
                                                  Right r  -> print r

-- N.B: also duplicated in Server.hs
serverAddrs :: [ServerId]
serverAddrs = [ ServerId "http://localhost:10501"
              , ServerId "http://localhost:10502"
              , ServerId "http://localhost:10503"
              ]


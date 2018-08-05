module Client where

import           Data.Maybe          (fromMaybe)
import qualified Data.Text.IO        as T (putStrLn)
import           Network.HTTP.Client (Manager, defaultManagerSettings,
                                      newManager)
import           Servant
import           Servant.Client
import           System.Random

import           Api
import           Raft.Log            (RequestId (RequestId))
import           Raft.Rpc            (ClientReq (..), ClientRes (..))
import           Raft.Server         (ServerId (..))

runClient :: String -> Command -> IO ()
runClient serverUrl cmd = do
  reqId <- RequestId <$> randomIO
  let req = ClientReq { _requestPayload = cmd, _clientRequestId = reqId }
  manager <- newManager defaultManagerSettings
  url <- parseBaseUrl serverUrl
  let env = ClientEnv { manager = manager, baseUrl = url, cookieJar = Nothing }
  res <- runClientM (sendClientRequest req) env
  case res of
    Left (ConnectionError e)                        -> T.putStrLn e
    Left err                                        -> print err
    Right ClientResFailure { _responseError = err } -> T.putStrLn err
    Right ClientResSuccess { _responsePayload = p } -> print p

-- N.B: also duplicated in Server.hs
serverAddrs :: [ServerId]
serverAddrs = [ ServerId "http://localhost:10501"
              , ServerId "http://localhost:10502"
              , ServerId "http://localhost:10503"
              ]


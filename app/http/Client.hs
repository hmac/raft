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
  let (serverId, cmd) =
        case args of
          [sid, "get"]    -> (ServerId (read sid), Get)
          [sid, "set", n] -> (ServerId (read sid), Set (read n))
      req reqId = ClientReq { _requestPayload = cmd, _clientRequestId = reqId }
  reqId <- RequestId <$> randomIO
  manager <- newManager defaultManagerSettings
  let url = fromMaybe (error "no address found") (lookup serverId serverAddrs)
      env = ClientEnv manager url
  res <- runClientM (sendClientRequest (req reqId)) env
  case res of
    Left err -> print err
    Right ClientRes { _responsePayload = p } -> case p of
                                                  Left err -> print err
                                                  Right r  -> print r

-- N.B: also duplicated in Server.hs
serverAddrs :: [(ServerId, BaseUrl)]
serverAddrs =  [(1, BaseUrl Http "localhost" 10501 "")
              , (2, BaseUrl Http "localhost" 10502 "")
              , (3, BaseUrl Http "localhost" 10503 "")]


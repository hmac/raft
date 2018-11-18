{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving         #-}

module Raft.Log where

import           Data.Aeson    (FromJSON, ToJSON)
import           Data.Binary   (Binary)
import           Data.Hashable (Hashable)
import           Data.Typeable (Typeable)
import           GHC.Generics  (Generic)

newtype ServerId = ServerId
  { unServerId :: String
  } deriving (Eq, Ord, Generic, Hashable, Typeable, Binary)
instance ToJSON ServerId
instance FromJSON ServerId

instance Show ServerId where
  show ServerId { unServerId = i } = show i

newtype Term = Term
  { unTerm :: Integer
  } deriving (Eq, Ord, Generic, Num)

instance Binary Term
instance ToJSON Term
instance FromJSON Term

instance Show Term where
  show Term {unTerm = t} = show t

-- needs to be 1-indexed - maybe use something other than a list?
type Log a = [LogEntry a]

type LogIndex = Integer

-- The ID of a client request
newtype RequestId = RequestId
  { unRequestId :: Integer
  } deriving (Eq, Ord, Num, Show, Generic, Typeable, Binary, Hashable)
instance ToJSON RequestId
instance FromJSON RequestId

data LogEntry a
  = LogEntry { _index     :: LogIndex
             , _term      :: Term
             , _payload   :: LogPayload a
             , _requestId :: RequestId }
  deriving (Generic)

instance Binary a => Binary (LogEntry a)
instance ToJSON a => ToJSON (LogEntry a)
instance FromJSON a => FromJSON (LogEntry a)

data LogPayload a
  = LogCommand a
  | LogConfig [ServerId]
  deriving (Generic, Show, Eq)

instance Binary a => Binary (LogPayload a)
instance ToJSON a => ToJSON (LogPayload a)
instance FromJSON a => FromJSON (LogPayload a)

deriving instance (Show a) => Show (LogEntry a)

deriving instance (Eq a) => Eq (LogEntry a)

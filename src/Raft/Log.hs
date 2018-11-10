{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}

module Raft.Log where

import           Control.Lens
import           Data.Binary   (Binary)
import           Data.Hashable (Hashable)
import           Data.Typeable (Typeable)
import           GHC.Generics  (Generic)

newtype ServerId = ServerId
  { unServerId :: String
  } deriving (Eq, Ord, Generic, Hashable, Typeable, Binary)

instance Show ServerId where
  show ServerId { unServerId = i } = show i

newtype Term = Term
  { unTerm :: Integer
  } deriving (Eq, Ord, Generic, Num)

instance Binary Term

instance Show Term where
  show Term {unTerm = t} = show t

-- needs to be 1-indexed - maybe use something other than a list?
type Log a = [LogEntry a]

type LogIndex = Integer

-- The ID of a client request
newtype RequestId = RequestId
  { unRequestId :: Integer
  } deriving (Eq, Ord, Num, Show, Generic, Typeable, Binary, Hashable)

newtype Config = Config [ServerId]
  deriving (Eq, Show, Generic)

instance Binary Config

-- TODO: rename command to payload
data LogEntry a
  = LogEntry { _index     :: LogIndex
             , _term      :: Term
             , _payload   :: LogPayload a
             , _requestId :: RequestId }
  deriving (Generic)

instance Binary a => Binary (LogEntry a)

data LogPayload a
  = LogCommand a
  | LogConfig Config
  deriving (Generic, Show, Eq)

instance Binary a => Binary (LogPayload a)

deriving instance (Show a) => Show (LogEntry a)

deriving instance (Eq a) => Eq (LogEntry a)

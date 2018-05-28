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

newtype Term = Term { unTerm :: Integer } deriving (Eq, Ord, Generic, Num)

instance Binary Term

instance Show Term where
  show Term { unTerm = t } = show t

-- needs to be 1-indexed - maybe use something other than a list?
type Log a = [LogEntry a]
type LogIndex = Integer

-- The ID of a client request
newtype RequestId = RequestId
  { unRequestId :: Integer
  } deriving (Eq, Num, Show, Typeable, Binary, Hashable)

data LogEntry a = LogEntry
  { _Index     :: LogIndex
  , _Term      :: Term
  , _Command   :: a
  , _RequestId :: RequestId
  } deriving (Generic)

instance Binary a => Binary (LogEntry a)
deriving instance (Show a) => Show (LogEntry a)
deriving instance (Eq a) => Eq (LogEntry a)

makeLenses ''LogEntry

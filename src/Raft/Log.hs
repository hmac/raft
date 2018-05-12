{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell    #-}

module Raft.Log where

import           Control.Lens
import           Data.Binary  (Binary)
import           GHC.Generics (Generic)

-- TODO: derive Num for Term
newtype Term = Term { unTerm :: Int } deriving (Eq, Ord, Generic)

instance Binary Term

instance Show Term where
  show Term { unTerm = t } = show t

incTerm :: Term -> Term
incTerm Term { unTerm = t } = Term { unTerm = t + 1 }

-- needs to be 1-indexed - maybe use something other than a list?
type Log a = [LogEntry a]
type LogIndex = Int

data LogEntry a = LogEntry
  { _Index   :: LogIndex
  , _Term    :: Term
  , _Command :: a
  } deriving (Generic)

instance Binary a => Binary (LogEntry a)
deriving instance (Show a) => Show (LogEntry a)
deriving instance (Eq a) => Eq (LogEntry a)

makeLenses ''LogEntry

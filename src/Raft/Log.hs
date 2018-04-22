{-# LANGUAGE StandaloneDeriving #-}

module Raft.Log where

newtype Term = Term { unTerm :: Int } deriving (Eq, Ord)

instance Show Term where
  show Term { unTerm = t } = show t

incTerm :: Term -> Term
incTerm Term { unTerm = t } = Term { unTerm = t + 1 }

data LogEntry a = LogEntry
  { eIndex   :: LogIndex
  , eTerm    :: Term
  , eCommand :: a
  }

deriving instance (Show a) => Show (LogEntry a)

-- needs to be 1-indexed - maybe use something other than a list?
type Log a = [LogEntry a]
type LogIndex = Int

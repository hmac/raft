{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TypeSynonymInstances   #-}

module Raft.Lens (module Raft.Lens, (^.)) where
import           Control.Lens

import           Raft.Log
import           Raft.Rpc
import           Raft.Server

makeFields ''AppendEntries
makeFields ''AppendEntriesResponse
makeFields ''RequestVote
makeFieldsNoPrefix ''RequestVoteResponse
makeFieldsNoPrefix ''ClientReq
makeFieldsNoPrefix ''ClientResponse

makeFields ''LogEntry
makeLenses ''ServerState

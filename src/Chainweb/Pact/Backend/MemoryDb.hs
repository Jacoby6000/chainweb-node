{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module: Chainweb.Pact.Backend.MemoryDb
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Mark Nichols <mark@kadena.io>
-- Stability: experimental
--
module Chainweb.Pact.Backend.MemoryDb where

import qualified Data.Map.Strict as M

import qualified Pact.Interpreter as P
import qualified Pact.Persist.Pure as P
import qualified Pact.PersistPactDb as P
import Pact.Types.Server as P

-- internal modules
import Chainweb.Pact.Types

-- mkPureState :: P.PactDbEnv (P.DbEnv P.PureDb) -> P.CommandConfig -> IO PactDbState
mkPureState :: P.PactDbEnv (P.DbEnv P.PureDb) -> IO PactDbState
mkPureState env = do
    P.initSchema env
    return $
        PactDbState
            { _pdbsDbEnv = Env' env
            , _pdbsState = P.CommandState P.initRefStore M.empty
            }

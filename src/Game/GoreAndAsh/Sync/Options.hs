{-|
Module      : Game.GoreAndAsh.Sync.Options
Description : Options of synchronization module
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX
-}
{-# LANGUAGE TemplateHaskell #-}
module Game.GoreAndAsh.Sync.Options(
    SyncRole(..)
  , SyncOptions
  , syncOptionsRole
  , syncOptionsNext
  , defaultSyncOptions
  ) where

import Control.Lens (makeLenses)
import GHC.Generics

-- | Defines internal strategy of synchronization, whether the node is
-- allowed to register objects by itself or not.
data SyncRole =
    SyncSlave -- ^ Cannot register new objects, ask server for id
  | SyncMaster -- ^ Allowed to register new objects
  deriving (Generic, Show, Eq, Enum, Bounded)

-- | Startup options of the sync module
data SyncOptions s = SyncOptions {
  -- | Defines role of the node (use slave for clients, and master for servers)
  _syncOptionsRole :: SyncRole
  -- | Options of next underlying module
, _syncOptionsNext :: s
} deriving (Generic, Show)

makeLenses ''SyncOptions

-- | Define default synchronization options for module.
--
-- @
-- SyncOptions {
--   _syncOptionsRole = SyncSlave
-- , _syncOptionsNext = s
-- }
-- @
defaultSyncOptions :: s -> SyncOptions s
defaultSyncOptions s = SyncOptions {
    _syncOptionsRole = SyncSlave
  , _syncOptionsNext = s
  }
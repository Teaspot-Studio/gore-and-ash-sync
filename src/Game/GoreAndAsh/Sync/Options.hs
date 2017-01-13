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
  , syncOptionsChannel
  , syncOptionsCollectionsChannel
  , syncOptionsResolveDelay
  , syncOptionsNext
  , defaultSyncOptions
  ) where

import Control.Lens (makeLenses)
import Data.Time
import Game.GoreAndAsh.Network (ChannelId(..))
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
  _syncOptionsRole               :: SyncRole
  -- | Network channel to use for synchronization messages
  --
  -- Note: that option must be the same for all nodes.
, _syncOptionsChannel            :: ChannelId
  -- | Network channel to use for synchronization of remote collections.
  --
  -- Note: that option must be the same for all nodes.
, _syncOptionsCollectionsChannel :: ChannelId
  -- | Delays between messages for resolving a name of sync object
, _syncOptionsResolveDelay       :: NominalDiffTime
  -- | Options of next underlying module
, _syncOptionsNext               :: s
} deriving (Generic, Show)

makeLenses ''SyncOptions

-- | Define default synchronization options for module.
--
-- @
-- SyncOptions {
--   _syncOptionsRole = SyncSlave
-- , _syncOptionsChannel = ChannelId 1
-- , _syncOptionsCollectionsChannel = ChannelId 2
-- , _syncOptionsResolveDelay = realToFrac (5 :: Double)
-- , _syncOptionsNext = s
-- }
-- @
defaultSyncOptions :: s -> SyncOptions s
defaultSyncOptions s = SyncOptions {
    _syncOptionsRole = SyncSlave
  , _syncOptionsChannel = ChannelId 1
  , _syncOptionsCollectionsChannel = ChannelId 2
  , _syncOptionsResolveDelay = realToFrac (5 :: Double)
  , _syncOptionsNext = s
  }
{-# OPTIONS_GHC -fno-warn-unused-imports #-}
{-|
Module      : Game.GoreAndAsh.Sync
Description : Gore&Ash high-level networking core module
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX

The core module contains high-level networking API for Gore&Ash. It allows to perform
automatic synchronzation of states on clients and server using a special EDSL.

Example of embedding:
TODO ADD THIS

Important note, the system tries to use channel id 1 for service messages, but fallbacks
to default channel if there is only one channel allocated in network module. Check initalization
of network module, client and server allocated channels count must match.
-}
module Game.GoreAndAsh.Sync(
    SyncT
  , runSyncT
  -- * Options
  , SyncRole(..)
  , SyncOptions
  , syncOptionsRole
  , syncOptionsChannel
  , syncOptionsCollectionsChannel
  , syncOptionsResolveDelay
  , defaultSyncOptions
  -- * API
  , SyncName
  , SyncItemId
  , SyncMonad(..)
  , ClientSynced(..)
  , serverRejected
  , conditional
  , syncWithNameWith
  , syncWithName
  , syncUnregisterName
  , syncUnregisterNames
  -- ** Server side
  , syncToClientManual
  , syncToClient
  , syncToClientsManual
  , syncToClients
  , syncToAllClients
  , sendToClient
  , sendToClients
  , sendToAllClients
  , sendToClientMany
  , sendToClientsMany
  , sendToAllClientsMany
  , syncFromClient
  , syncFromClients
  , syncFromAllClients
  , receiveFromClient
  , receiveFromClients
  , receiveFromAllClients
  -- ** Client side
  , syncToServer
  , syncFromServerWith
  , syncFromServer
  , sendToServer
  , sendToServerMany
  , receiveFromServer
  -- ** Prediction
  , predict
  , predictMaybe
  , predictM
  , predictMaybeM
  , predictInterpolateM
  -- * Collections
  , hostCollection
  , hostSimpleCollection
  , remoteCollection
  ) where

import Game.GoreAndAsh.Sync.API as X
import Game.GoreAndAsh.Sync.Collection as X
import Game.GoreAndAsh.Sync.Module as X
import Game.GoreAndAsh.Sync.Options as X
import Game.GoreAndAsh.Sync.Predict as X

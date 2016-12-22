{-|
Module      : Game.GoreAndAsh.Sync.Collection
Description : Synchronisation of remote collections.
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX
-}
module Game.GoreAndAsh.Sync.Collection(
    hostCollection
  , remoteCollection
  ) where

import Data.Store
import GHC.Generics
import Data.ByteString (ByteString)

import Game.GoreAndAsh
import Game.GoreAndAsh.Sync
import Game.GoreAndAsh.Sync.Collection.Message
import Game.GoreAndAsh.Network

hostCollection :: (Ord k, MonadAppHost t m, NetworkServer t m)
  => SyncItemId -- ^ ID of collection in current scope
  -> Map k v -- ^ Initial set of components
  -> Event t (Map k (Maybe v)) -- ^ Nothing entries delete component, Just ones create or replace
  -> (k -> v -> m a) -- ^ Constructor of widget
  -> m (Dynamic t (Map k a)) -- ^ Collected output of components

remoteCollection :: (Ord k, MonadAppHost t m, NetworkClient t m)
  => SyncItemId -- ^ ID of collection in current scope
  -> (k -> v -> m a) -- ^ Contructor of client widget
  -> m (Dynamic t (Map k a))
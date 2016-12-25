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

import Control.Lens
import Data.Bifunctor
import Data.Map (Map)
import Data.Monoid
import Data.Store

import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Foldable as F

import Game.GoreAndAsh
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync.API
import Game.GoreAndAsh.Sync.Collection.Message
import Game.GoreAndAsh.Sync.Options

-- | Make collection that infroms clients about component creation/removing
hostCollection :: forall k v v' a t m .
    ( Ord k, Store k, Store v', MonadAppHost t m
    , NetworkServer t m, SyncMonad t m)
  => SyncItemId -- ^ ID of collection in current scope
  -> Dynamic t (S.Set Peer) -- ^ Set of peers that are allowed to get info about collection and that receives incremental updates.
  -> Map k v -- ^ Initial set of components
  -> Event t (Map k (Maybe v)) -- ^ Nothing entries delete component, Just ones create or replace
  -> (Peer -> v -> v') -- ^ Transform creation value to which is sent to remote clients
  -> (k -> v -> m a) -- ^ Constructor of widget
  -> m (Dynamic t (Map k a)) -- ^ Collected output of components
hostCollection itemId peersDyn initialMap addDelMap toClientVal makeComponent = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  -- resolve scope name
  i <- makeSyncName =<< syncCurrentName
  -- collect contents of (key, start value) to send to remote peer with request
  rec kvMapDyn <- holdDyn initialMap $ flip pushAlways addDelMap $ \diffMap -> do
        kvMap <- sample . current $ kvMapDyn
        let addRemove m k Nothing  = M.delete k m
            addRemove m k (Just v) = M.insert k v m
        return $ M.foldlWithKey' addRemove kvMap diffMap
  -- listen messages from client about the remote collections
  msgE :: Event t (Peer, RemoteCollectionMsg k v') <- listenCollectionMsg chan
  -- filter requests for current content of collection
  let reqE = flip push msgE $ \msg -> do
        peers <- sample . current $ peersDyn
        return $ case msg of
          (peer, RemoteComponentsRequest{..}) ->
            if   remoteComponentSyncId == i
              && remoteComponentItemId == itemId
              && peer `S.member` peers -- only peers that are in allowed set
              then Just peer
              else Nothing
          _ -> Nothing
  -- when client wants to know current content of send the accummulated kvMapDyn
  _ <- msgSendMany $ flip pushAlways reqE $ \peer -> do
    kvMap <- sample . current $ kvMapDyn
    let mkMsg k v = (peer, chan, encodeComponentCreateMsg i itemId k $ toClientVal peer v)
    return $ M.mapWithKey mkMsg kvMap
  -- send deletion and incremental addition of elements
  let updMsgsE = flip pushAlways addDelMap $ \m -> do
        peers <- sample . current $ peersDyn
        let makeMsg peer k Nothing  = (peer, chan, encodeComponentDeleteMsg i itemId k)
            makeMsg peer k (Just v) = (peer, chan, encodeComponentCreateMsg i itemId k $ toClientVal peer v)
        return $ flip F.foldMap peers $ \peer -> M.elems $ M.mapWithKey (makeMsg peer) m
  msgSendMany updMsgsE
  -- local collection
  holdKeyCollection initialMap addDelMap makeComponent

-- | Make a client-side version of 'hostCollection' receive messages when
-- server adds-removes components and mirror them localy by local component.
remoteCollection :: (Ord k, MonadAppHost t m, NetworkClient t m)
  => SyncItemId -- ^ ID of collection in current scope
  -> (k -> v -> m a) -- ^ Contructor of client widget
  -> m (Dynamic t (Map k a))
remoteCollection itemId makeComponent = do
  holdKeyCollection mempty never makeComponent

-- | Listen for collection message
listenCollectionMsg :: (NetworkMonad t m, LoggingMonad t m, Store k, Store v)
  => ChannelID -- ^ Channel that is used for collection messages
  -> m (Event t (Peer, RemoteCollectionMsg k v))
listenCollectionMsg chan = do
  e <- networkMessage
  let e' = fforMaybe e $ \(peer, chan', bs) -> if chan == chan'
        then Just $ (peer,) <$> decodeRemoteCollectionMsg bs
        else Nothing
      printDecodeError de = "Failed to decode remote collection msg: " <> showl de
  logEitherWarn $ first printDecodeError <$> e'
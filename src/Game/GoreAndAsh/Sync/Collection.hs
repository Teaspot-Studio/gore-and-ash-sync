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
  , hostSimpleCollection
  , remoteCollection
  ) where

import Control.Lens
import Control.Monad (join)
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
import Game.GoreAndAsh.Sync.Message
import Game.GoreAndAsh.Sync.Options

-- | Make collection that infroms clients about component creation/removing
hostCollection :: forall k v v' a b t m .
    ( Ord k, Store k, Store v', MonadAppHost t m
    , NetworkServer t b m, SyncMonad t b m)
  => SyncItemId -- ^ ID of collection in current scope
  -> Dynamic t (S.Set (Peer b)) -- ^ Set of peers that are allowed to get info about collection and that receives incremental updates.
  -> Map k v -- ^ Initial set of components
  -> Event t (Map k (Maybe v)) -- ^ Nothing entries delete component, Just ones create or replace
  -> (Peer b -> v -> v') -- ^ Transform creation value to which is sent to remote clients
  -> (k -> v -> m a) -- ^ Constructor of widget
  -> m (Dynamic t (Map k a)) -- ^ Collected output of components
hostCollection itemId peersDyn initialMap addDelMap toClientVal makeComponent = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsCollectionsChannel
  -- resolve scope name
  i <- makeSyncName =<< syncCurrentName
  -- collect contents of (key, start value) to send to remote peer with request
  rec kvMapDyn <- holdDyn initialMap $ flip pushAlways addDelMap $ \diffMap -> do
        kvMap <- sample . current $ kvMapDyn
        let addRemove m k Nothing  = M.delete k m
            addRemove m k (Just v) = M.insert k v m
        return $ M.foldlWithKey' addRemove kvMap diffMap
  -- listen messages from client about the remote collections
  msgE :: Event t (Peer b, RemoteCollectionMsg k v') <- listenCollectionMsg chan i itemId
  -- filter requests for current content of collection
  let reqE = flip push msgE $ \msg -> do
        peers <- sample . current $ peersDyn
        return $ case msg of
          (peer, RemoteComponentsRequest{..}) ->
            if peer `S.member` peers -- only peers that are in allowed set
              then Just peer
              else Nothing
          _ -> Nothing
  -- when client wants to know current content of send the accummulated kvMapDyn
  _ <- msgSendMany $ flip pushAlways reqE $ \peer -> do
    kvMap <- sample . current $ kvMapDyn
    let mkMsg k v = (peer, chan, ReliableMessage, encodeComponentCreateMsg i itemId k $ toClientVal peer v)
    return $ M.mapWithKey mkMsg kvMap
  -- send deletion and incremental addition of elements
  let updMsgsE = flip pushAlways addDelMap $ \m -> do
        peers <- sample . current $ peersDyn
        let makeMsg peer k Nothing  = (peer, chan, ReliableMessage, encodeComponentDeleteMsg i itemId k)
            makeMsg peer k (Just v) = (peer, chan, ReliableMessage, encodeComponentCreateMsg i itemId k $ toClientVal peer v)
        return $ flip F.foldMap peers $ \peer -> M.elems $ M.mapWithKey (makeMsg peer) m
  _ <- msgSendMany updMsgsE
  -- local collection
  holdKeyCollection initialMap addDelMap makeComponent

-- | Make collection that infroms clients about component creation/removing
--
-- Simplified version of 'hostCollection' which doesn't provide control
-- over peers and start value projection for clients.
hostSimpleCollection :: forall k v a b t m .
    ( Ord k, Store k, Store v, MonadAppHost t m
    , NetworkServer t b m, SyncMonad t b m)
  => SyncItemId -- ^ ID of collection in current scope
  -> Map k v -- ^ Initial set of components
  -> Event t (Map k (Maybe v)) -- ^ Nothing entries delete component, Just ones create or replace
  -> (k -> v -> m a) -- ^ Constructor of widget
  -> m (Dynamic t (Map k a)) -- ^ Collected output of components
hostSimpleCollection itemId initialMap updatesE makeComponent = do
  peers <- networkPeers
  hostCollection itemId peers initialMap updatesE (const id) makeComponent

-- | Make a client-side version of 'hostCollection' receive messages when
-- server adds-removes components and mirror them localy by local component.
remoteCollection :: (Ord k, Store k, Store v, MonadAppHost t m, NetworkClient t b m, SyncMonad t b m)
  => SyncItemId -- ^ ID of collection in current scope
  -> (k -> v -> m a) -- ^ Contructor of client widget
  -- | Returns resulted collected outputs from components and update map.
  -> m (Dynamic t (Map k a), Event t (Map k (Maybe v)))
remoteCollection itemId makeComponent = fmap joinPair $ whenConnected (pure mempty) $ \server -> do
  -- read options
  opts <- syncOptions
  let chan = opts ^. syncOptionsCollectionsChannel
  -- resolve scope
  name <- syncCurrentName
  fmap joinPair $ resolveSyncName server name (pure mempty) $ \i -> do
    -- at creation send request to server for full list of items
    buildE <- getPostBuild
    let reqMsgE = const (ReliableMessage, encodeComponentsRequestMsg i itemId) <$> buildE
    _ <- peerChanSend server chan reqMsgE
    -- listen to server messages
    msgE <- listenPeerCollectionMsg server chan i itemId
    let updMapE = fforMaybe msgE $ \msg -> case msg of
          RemoteComponentCreate{..} -> Just $ M.singleton remoteComponentKey (Just remoteComponentValue)
          RemoteComponentDelete{..} -> Just $ M.singleton remoteComponentKey Nothing
          _ -> Nothing
    -- local collection
    cmpsDyn <- holdKeyCollection mempty updMapE makeComponent
    return (cmpsDyn, updMapE)
  where
    joinPair dp = (join $ fst <$> dp, switchPromptlyDyn $ snd <$> dp)

-- | Listen for collection message
listenCollectionMsg :: (NetworkMonad t b m, Store k, Store v)
  => ChannelId -- ^ Channel that is used for collection messages
  -> SyncId -- ^ ID of scope
  -> SyncItemId -- ^ ID of item in scope
  -> m (Event t (Peer b, RemoteCollectionMsg k v))
listenCollectionMsg chan i itemId = do
  e <- networkMessage
  let e' = fforMaybe e $ \(peer, chan', bs) -> if chan == chan'
        then sequence $ fmap (peer,) <$> decodeRemoteCollectionMsg bs i itemId
        else Nothing
      printDecodeError de = "Failed to decode remote collection msg: " <> showl de
  logEitherWarn $ first printDecodeError <$> e'

-- | Listen for collection messages from particular peer
listenPeerCollectionMsg :: (NetworkMonad t b m, Store k, Store v)
  => Peer b -- ^ Peer that is listened
  -> ChannelId -- ^ Channel that is used for collection messages
  -> SyncId -- ^ ID of scoped
  -> SyncItemId -- ^ ID of sync object
  -> m (Event t (RemoteCollectionMsg k v))
listenPeerCollectionMsg peer chan i itemId = do
  msgE <- listenCollectionMsg chan i itemId
  return $ fforMaybe msgE $ \(peer', msg) -> if peer == peer'
    then Just msg
    else Nothing

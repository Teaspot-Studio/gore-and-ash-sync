{-|
Module      : Game.GoreAndAsh.Sync.API
Description : API of synchronization module
Copyright   : (c) Anton Gushcha, 2015-2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX
-}
{-# LANGUAGE LambdaCase #-}
module Game.GoreAndAsh.Sync.API(
  -- * API
    SyncName
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
  -- * Internal API
  , NameMap
  , syncService
  , makeSyncName
  , resolveSyncName
  ) where

import Control.Lens ((^.))
import Control.Monad
import Control.Monad.Catch
import Control.Monad.Trans
import Control.Monad.Trans.Control
import Data.Bifunctor
import Data.Map.Strict (Map)
import Data.Monoid
import Data.Store
import Data.Word
import Game.GoreAndAsh.Core
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync.Message
import Game.GoreAndAsh.Sync.Options
import Game.GoreAndAsh.Time
import GHC.Generics

import qualified Data.Foldable as F
import qualified Data.HashMap.Strict as H
import qualified Data.Map.Strict as M

-- | Bijection between name and id of synchronized object
type NameMap = H.HashMap SyncName SyncId

class (MonadGame t m, LoggingMonad t m)
  => SyncMonad t b m | m -> t, m -> b where
    -- | Get settings of the module
    syncOptions :: m SyncOptions
    -- | Get map of known names on the node
    syncKnownNames :: m (Dynamic t NameMap)
    -- | Return current scope sync object of synchronization object
    syncCurrentName :: m SyncName

    -- | Set current scope name without resolving or generation id for the name.
    --
    -- It is low-level operation, you probably want to see 'syncWithName'.
    syncScopeName :: SyncName -- ^ Name to use for scope
      -> m a -- ^ Scope that will see the name in 'syncCurrentName' call
      -> m a

    -- | Register new id for given name (overwrites existing ids).
    --
    -- Used by server to generate id for name.
    syncUnsafeRegId :: SyncName -> m SyncId
    -- | Register new id for given name (overwrites existing ids).
    --
    -- Used by client to register id requested from server.
    syncUnsafeAddId :: SyncName -> SyncId -> m ()
    -- | Forget about given sync name to free memory when sync object is not
    -- neded anymore.
    syncUnsafeDelId :: SyncName -> m ()

    -- | Increase per peer message counter and return its value
    syncIncSendCounter :: Peer b -> m Word16

    -- | If it returns 'True', the package with the counter value is not too late.
    -- Updates maximum value of internal counter.
    syncCheckReceiveCounter :: Peer b -> Word16 -> m Bool

-- | Execute nested action with given scope name and restore it after
--
-- Instead of 'syncWithName' uses dynamic for initial values, that is important
-- for aligning states of initial value and values of generated dynamic in future
-- after scope is resolved.
syncWithNameWith :: (SyncMonad t b m, NetworkClient t b m)
  => SyncName     -- ^ Name to use for scope
  -> Dynamic t a  -- ^ Initial value (before the name is resolved)
  -> m a          -- ^ Scope
  -> m (Dynamic t a) -- ^ Result of scope execution
syncWithNameWith name initDyn m =  do
  let m' = syncScopeName name m
  opts <- syncOptions
  let role = opts ^. syncOptionsRole
  case role of
    SyncSlave -> do
      fmap join $ whenConnected (return initDyn) $ \peer -> do
        resolveSyncName peer name (sample . current $ initDyn) (const m')
    SyncMaster -> makeSyncName name >> fmap pure m'

-- | Execute nested action with given scope name and restore it after
syncWithName :: (SyncMonad t b m, NetworkClient t b m)
  => SyncName -- ^ Name to use for scope
  -> a   -- ^ Initial value (before the name is resolved)
  -> m a -- ^ Scope
  -> m (Dynamic t a) -- ^ Result of scope execution
syncWithName name a0 = syncWithNameWith name (pure a0)

-- | Delete synchronisation name by event
syncUnregisterName :: (SyncMonad t b m)
  => Event t SyncName -- ^ Fires when you want to delete a synchronization object
  -> m (Event t SyncName) -- ^ Return the event that fires after deletion of given name
syncUnregisterName e = performNetwork $ ffor e $ \name -> do
  syncUnsafeDelId name
  return name

-- | Delete synchronisation name by event
syncUnregisterNames :: (SyncMonad t b m, Foldable f)
  => Event t (f SyncName) -- ^ Fires when you want to delete a batch of synchronization objects
  -> m (Event t (f SyncName)) -- ^ Return the event that fires after deletion of given names
syncUnregisterNames e = performNetwork $ ffor e $ \names -> do
  mapM_ syncUnsafeDelId names
  return names

instance {-# OVERLAPPABLE #-} (MonadTrans mt, MonadTransControl mt, MonadGame t (mt m), MonadMask (mt m), SyncMonad t b m, LoggingMonad t m)
  => SyncMonad t b (mt m) where
    syncOptions = lift syncOptions
    {-# INLINE syncOptions #-}
    syncKnownNames = lift syncKnownNames
    {-# INLINE syncKnownNames #-}
    syncCurrentName = lift syncCurrentName
    {-# INLINE syncCurrentName #-}
    syncScopeName name ma = do
      res <- liftWith $ \run -> syncScopeName name $ run ma
      restoreT $ pure res
    {-# INLINE syncScopeName #-}
    syncUnsafeRegId = lift . syncUnsafeRegId
    {-# INLINE syncUnsafeRegId #-}
    syncUnsafeAddId a b = lift $ syncUnsafeAddId a b
    {-# INLINE syncUnsafeAddId #-}
    syncUnsafeDelId a = lift $ syncUnsafeDelId a
    {-# INLINE syncUnsafeDelId #-}
    syncIncSendCounter p = lift $ syncIncSendCounter p
    {-# INLINE syncIncSendCounter #-}
    syncCheckReceiveCounter p c = lift $ syncCheckReceiveCounter p c
    {-# INLINE syncCheckReceiveCounter #-}

-- | Start streaming given dynamic value to specific client.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
--
-- You can group 'syncToClient' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
syncToClientManual :: (SyncMonad t b m, NetworkServer t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Dynamic t a
  -- ^ Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Event t ()
  -- ^ Manual send event. Send contents of dynamics to client only when the
  -- event fires.
  -> Peer b
  -- ^ Client that is target of synchronisation.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
syncToClientManual itemId mt da manualE peer = do
  buildE <- getPostBuild
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- listen for requests
  reqE <- syncRequestMessage peer i itemId
  let respE = tagPromptlyDyn da reqE
  logVerboseE $ ffor respE $ const $ "Sync: Got request for initial value of " <> showl itemId
  -- send updates
  let initialE = tagPromptlyDyn da buildE
      manualE' = tagPromptlyDyn da manualE
      updatedE = leftmost [manualE', respE, initialE]
  sendSyncPayload peer chan mt i itemId updatedE

-- | Send payload of synced value
sendSyncPayload :: forall t m a b . (SyncMonad t b m, NetworkMonad t b m, Store a)
  => Peer b -- ^ Peer to send payload to
  -> ChannelId -- ^ Channel ID to send over
  -> MessageType -- ^ Type of messaage, reliability
  -> SyncId -- ^ Scope id
  -> SyncItemId -- ^ id of item in scope
  -> Event t a -- ^ Payload
  -> m (Event t ())
sendSyncPayload peer chan mt i itemId ea = do
  msgE <- performNetwork $ ffor ea $ \a -> do
    c <- syncIncSendCounter peer
    return (mt, encodeSyncMessage i itemId c a)
  peerChanSend peer chan msgE

-- | Start streaming given dynamic value to specific client.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
--
-- You can group 'syncToClient' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
syncToClient :: (SyncMonad t b m, NetworkServer t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Dynamic t a
  -- ^ Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Peer b
  -- ^ Client that is target of synchronisation.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
syncToClient itemId mt da peer = syncToClientManual itemId mt da (const () <$> updated da) peer

-- | Start streaming given dynamic value to all connected clients.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToClientsManual :: (SyncMonad t b m, NetworkServer t b m, Store a, Foldable f)
  => Dynamic t (f (Peer b))
  -- ^ Set of clients that should be informed about chages of the value
  -> SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Dynamic t a
  -- ^ Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Event t ()
  -- ^ Manual send event. Send contents of dynamics to client only when the
  -- event fires.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
syncToClientsManual peers itemId mt da manualE = networkView $ mapM_ (syncToClientManual itemId mt da manualE) <$> peers

-- | Start streaming given dynamic value to all connected clients.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToClients :: (SyncMonad t b m, NetworkServer t b m, Store a, Foldable f)
  => Dynamic t (f (Peer b))
  -- ^ Set of clients that should be informed about chages of the value
  -> SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Dynamic t a
  -- ^ Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
syncToClients peers itemId mt da = networkView $ mapM_ (syncToClient itemId mt da) <$> peers

-- | Start streaming given dynamic value to all connected clients.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToAllClients :: (SyncMonad t b m, NetworkServer t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Dynamic t a
  -- ^ Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
syncToAllClients itemId mt da = do
  peers <- networkPeers
  syncToClients peers itemId mt da

-- | Send given high-level message to given peer.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
--
-- You can group 'sendToClient' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
sendToClient :: (SyncMonad t b m, NetworkServer t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Event t a
  -- ^ Each time the event fires the content in sended to remote peer.
  -> Peer b
  -- ^ Client that is target of synchronisation.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
sendToClient itemId mt ea peer = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- send updates
  let msgE = fmap (\msg -> (mt, encodeSyncCommand i itemId msg)) ea
  peerChanSend peer chan msgE

-- | Send given high-level message to given peers.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
--
-- You can group 'sendToClients' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
sendToClients :: (SyncMonad t b m, NetworkServer t b m, Store a, Foldable f)
  => Dynamic t (f (Peer b))
  -- ^ Collection of peers to sync the message to
  -> SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Event t a
  -- ^ Each time the event fires the content in sended to remote peer.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
sendToClients peers itemId mt ea = networkView $ mapM_ (sendToClient itemId mt ea) <$> peers

-- | Send given high-level message to all connected peers.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
sendToAllClients :: (SyncMonad t b m, NetworkServer t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Event t a
  -- ^ Each time the event fires the content in sended to remote peer.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
sendToAllClients itemId mt ea = do
  peers <- networkPeers
  sendToClients peers  itemId mt ea

-- | Send given high-level message to given peer.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
--
-- You can group 'sendToClient' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
sendToClientMany :: (SyncMonad t b m, NetworkServer t b m, Store a, Foldable f, Functor f)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Event t (f a)
  -- ^ Each time the event fires the content in sended to remote peer.
  -> Peer b
  -- ^ Client that is target of synchronisation.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
sendToClientMany itemId mt eas peer = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- send updates
  let msgsE = fmap (\msg -> (mt, encodeSyncCommand i itemId msg)) <$> eas
  peerChanSendMany peer chan msgsE


-- | Send given high-level message to given peers.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
--
-- You can group 'sendToClients' calls within a single set of peers (see 'networkPeers')
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
sendToClientsMany :: (SyncMonad t b m, NetworkServer t b m, Store a, Foldable f1, Foldable f2, Functor f2)
  => Dynamic t (f1 (Peer b))
  -- ^ Collection of peers to sync the message to
  -> SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Event t (f2 a)
  -- ^ Each time the event fires the content in sended to remote peer.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
sendToClientsMany peers itemId mt eas = networkView $ mapM_ (sendToClientMany itemId mt eas) <$> peers

-- | Send given high-level message to all connected peers.
--
-- Intended to be called on server side and a corresponding 'receiveFromServer'
-- call is needed on client side.
sendToAllClientsMany :: (SyncMonad t b m, NetworkServer t b m, Store a, Foldable f, Functor f)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Event t (f a)
  -- ^ Each time the event fires the content in sended to remote peer.
  -> m (Event t ())
  -- ^ Returns event that fires when a value was synced to given peers
sendToAllClientsMany itemId mt eas = do
  peers <- networkPeers
  sendToClientsMany peers itemId mt eas

-- | Synchronisation from client to server. Server can reject values and send actuall value.
--
-- Server has to call corresponding 'syncToServer' function to receive updates.
--
-- You probably want to group 'syncFromClient' calls within one scope of 'processPeers'
-- or 'peersCollection' as it more efficient than multiple calls for 'syncFromClients'
-- or 'syncFromAllClients'.
syncFromClient :: (SyncMonad t b m, NetworkServer t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> m a
  -- ^ Make initial value
  -> Event t a
  -- ^ When the event fires, client side info is rejected and payload replaces
  -- dynamic contents.
  -> Peer b
  -- ^ Peer that is listened for values.
  -> m (Dynamic t a, Event t (a, a))
  -- ^ Dynamic with respect to rejects and event that fires with old and new value
  -- when server rejects client side value.
syncFromClient itemId mkInit rejectE peer = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- listen for state
  msgE <- syncPeerMessage peer i itemId
  -- check whether we want to reject value
  rec
    let rejectsE = attachWith (,) (current updatedDyn) rejectE
    _ <- peerChanSend peer chan $ (ReliableMessage,) . encodeSyncCommand i itemId <$> rejectE
    -- collect state on server side
    initVal <- mkInit
    updatedDyn <- holdDyn initVal $ leftmost [rejectE, msgE]
  return (updatedDyn, rejectsE)

-- | Synchronisation from clients to server. Server can reject values and send actuall value.
--
-- Server has to call corresponding 'syncToServer' function to receive updates.
syncFromClients :: forall t m a b f . (SyncMonad t b m, NetworkServer t b m, Store a, Foldable f)
  => Dynamic t (f (Peer b))
  -- ^ Collection of peers to receive from
  -> SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> (Peer b -> m a)
  -- ^ Make initial value
  -> Event t (Map (Peer b) a)
  -- ^ When the event fires, client side info is rejected and payload replaces
  -- dynamic contents.
  -> m (Dynamic t (Map (Peer b) a), Event t (Map (Peer b) (a, a)))
  -- ^ Collected state for each Peer with respect of rejections. The second event
  -- contains info which values were rejected and which values replaced them.
  --
  -- Note: see 'syncFromClient' result type.
syncFromClients peersDyn itemId mkInit rejectE = do
  switchedMap :: Event t (Dynamic t (Map (Peer b) a), Event t (Map (Peer b) (a, a))) <- networkView $ go <$> peersDyn
  dynPair <- holdDyn (pure mempty, never) switchedMap
  return (join . fmap fst $ dynPair, switchPromptlyDyn . fmap snd $ dynPair)
  where
    go :: f (Peer b) -> m (Dynamic t (Map (Peer b) a), Event t (Map (Peer b) (a, a)))
    go peers = do
      es <- mapM goPeer $ F.toList peers
      let dmap = sequence $ M.fromList $ (\(a, b, _) -> (a, b)) <$> es
      let emap = mergeMap $ M.fromList $ (\(a, _, c) -> (a, c)) <$> es
      return (dmap, emap)
    goPeer :: Peer b -> m (Peer b, Dynamic t a, Event t (a, a))
    goPeer peer = do
      let rejectE' = fforMaybe rejectE $ M.lookup peer
      (da, ea) <- syncFromClient itemId (mkInit peer) rejectE' peer
      return (peer, da, ea)

-- | Synchronisation from client to server. Server can reject values and send actuall value.
--
-- Server has to call corresponding 'syncToServer' function to receive updates.
syncFromAllClients :: (SyncMonad t b m, NetworkServer t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> (Peer b -> m a)
  -- ^ Make initial value
  -> Event t (Map (Peer b) a)
  -- ^ When the event fires, client side info is rejected and payload replaces
  -- dynamic contents.
  -> m (Dynamic t (Map (Peer b) a), Event t (Map (Peer b) (a, a)))
  -- ^ Collected state for each Peer.
syncFromAllClients itemId initial rejectE = do
  peers <- networkPeers
  syncFromClients peers itemId initial rejectE

-- | Receiving high-level message from client to server.
--
-- Server has to call corresponding 'sendToServer' function to receive updates.
--
-- You probably want to group 'receiveFromClient' calls within one scope of peers
-- (see 'networkPeers') as it more efficient than multiple calls for 'receiveFromAllClients'.
receiveFromClient :: (SyncMonad t b m, NetworkServer t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> Peer b
  -- ^ Peer that is listened for values.
  -> m (Event t a)
  -- ^ Collected state for each Peer.
receiveFromClient itemId peer = do
  i <- makeSyncName =<< syncCurrentName
  syncPeerCommand peer i itemId

-- | Receiving high-level message from client to server.
--
-- Server has to call corresponding 'sendToServer' function to receive updates.
--
-- You probably want to group 'receiveFromClient' calls within one scope of peers
-- (see 'networkPeers') as it more efficient than multiple calls for 'receiveFromAllClients'.
receiveFromClients :: forall t m a b f . (SyncMonad t b m, NetworkServer t b m, Store a, Foldable f)
  => Dynamic t (f (Peer b))
  -- ^ Collection of peers to receive from
  -> SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> m (Event t (Map (Peer b) a))
  -- ^ Collected state for each Peer.
receiveFromClients peersDyn itemId = do
  switchE <- networkView $ go <$> peersDyn
  switchHold never switchE
  where
    go :: f (Peer b) -> m (Event t (Map (Peer b) a))
    go peers = do
      es <- mapM goPeer $ F.toList peers
      return $ mergeMap $ M.fromList es

    goPeer :: Peer b -> m (Peer b, Event t a)
    goPeer peer = do
      a <- receiveFromClient itemId peer
      return (peer, a)

-- | Receiving high-level message from client to server.
--
-- Server has to call corresponding 'sendToServer' function to receive updates.
--
-- You probably want to group 'receiveFromClient' calls within one scope of peers
-- (see 'networkPeers') as it more efficient than multiple calls for 'receiveFromAllClients'.
receiveFromAllClients :: (SyncMonad t b m, NetworkServer t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> m (Event t (Map (Peer b) a))
  -- ^ Collected state for each Peer.
receiveFromAllClients itemId = do
  peers <- networkPeers
  receiveFromClients peers itemId

-- | Update dynamic value only if given predicate returns 'True'.
--
-- The helper is intended to be used with 'syncToClients' to create
-- conditional synchronisation.
conditional :: (Reflex t, MonadHold t m)
  => Dynamic t a -- ^ Original dynamic
  -> (a -> PushM t Bool) -- ^ Predicate, return 'True' to pass value into new dynamic
  -> m (Dynamic t a) -- ^ Filtered dynamic
conditional da predicate = do
  ai <- sample . current $ da
  let ae = push predicate' . updated $ da
  holdDyn ai ae
  where
    predicate' a = do
      res <- predicate a
      return $ if res then Just a else Nothing

-- | Receive stream of values from remote server. With explicit value to use for
-- initial values that are used until connected to server and until scope name
-- is resolved.
--
-- Matches to call of 'syncToClient', should be called on client side.
syncFromServerWith :: (SyncMonad t b m, NetworkClient t b m, Store a)
  => SyncItemId -- ^ Unique name of synchronization value withing current scope
  -> Dynamic t a -- ^ Which dynamic to use for initial value
  -> m (Dynamic t a)
syncFromServerWith itemId initDyn = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  name <- syncCurrentName
  fmap join $ whenConnected (return initDyn) $ \peer -> do -- first wait until connected
    fmap join $ resolveSyncName peer name (return initDyn) $ \i -> do -- wait for id
      -- send initial request to inform client of initial value for rarely changing values
      buildE <- getPostBuild
      let reqE = const (ReliableMessage, encodeSyncRequest i itemId) <$> buildE
      logVerboseE $ ffor buildE $ const $ "Sync: Sending request for initial value of " <> showl itemId <> " for scope " <> showl name
      _ <- peerChanSend peer chan reqE
      -- listen for responds of server
      msgE <- syncPeerMessage peer i itemId
      a <- sample . current $ initDyn
      holdDyn a msgE -- here collect updates in dynamic

-- | Receive stream of values from remote server.
--
-- Matches to call of 'syncToClient', should be called on client side.
syncFromServer :: (SyncMonad t b m, NetworkClient t b m, Store a)
  => SyncItemId -- ^ Unique name of synchronization value withing current scope
  -> a -- ^ Initial value
  -> m (Dynamic t a)
syncFromServer itemId initVal = syncFromServerWith itemId (pure initVal)

-- | Receive message from remote server.
--
-- Matches to call of 'sendToClient', should be called on client side.
receiveFromServer :: (SyncMonad t b m, NetworkClient t b m, Store a)
  => SyncItemId -- ^ Unique name of synchronization value withing current scope
  -> m (Event t a)
receiveFromServer itemId = do
  name <- syncCurrentName
  fmap switchPromptlyDyn $ whenConnected (pure never) $ \peer -> do -- first wait until connected
    fmap switchPromptlyDyn $ resolveSyncName peer name (pure never) $ \i -> do -- wait for id
      -- listen for responds of server
      syncPeerCommand peer i itemId

-- | Result of execution of 'syncToServer'
data ClientSynced a =
    ClientSentToServer -- ^ Client sent state to server
  | ServerRejected a -- ^ Server rejected last state and returned valid one
  deriving (Generic, Show, Read)

-- | Pass only rejected-by-server messages
serverRejected :: Reflex t => Event t (ClientSynced a) -> Event t a
serverRejected = fmapMaybe $ \case
  ServerRejected a -> Just a
  _ -> Nothing

-- | Synchronisation from client to server. Server can reject values and send actual state.
--
-- Server has to call corresponding 'syncFromClients' function to receive updates.
syncToServer :: (SyncMonad t b m, NetworkClient t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Dynamic t a
  -- ^ Source of data to transfer to server. Note that updates to server
  -- are sent each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> m (Event t (ClientSynced a))
  -- ^ Event that fires each time a new message is passed to server or server
  -- rejected client state.
  --
  -- Note: that you might like to update input dynamic with corrected values via
  -- mfix cycle.
syncToServer itemId mt da = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  name <- syncCurrentName
  dynEv <- whenConnected (pure never) $ \peer -> do -- first wait until connected
    dynEv <- resolveSyncName peer name (pure never) $ \i -> do -- wait for id
      -- we need to send initial request to inform client of initial value for rarely changing values
      buildE <- getPostBuild
      sendedE <- sendSyncPayload peer chan mt i itemId $ leftmost [updated da, tagPromptlyDyn da buildE]
      -- listen for responds of server
      msgE <- syncPeerCommand peer i itemId
      -- we can either inform about rejected value or that we synced to server
      return $ leftmost [
          ServerRejected <$> msgE
        , const ClientSentToServer <$> sendedE
        ]
    return $ switchPromptlyDyn dynEv
  return $ switchPromptlyDyn dynEv

-- | Synchronisation from client to server. Server can reject values and send actual state.
--
-- Server has to call corresponding 'syncFromClients' function to receive updates.
sendToServer :: (SyncMonad t b m, NetworkClient t b m, Store a)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Event t a
  -- ^ Source of data to transfer to server.
  -> m (Event t ())
  -- ^ Event that fires each time a new message is passed to server
sendToServer itemId mt ea = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  name <- syncCurrentName
  fmap switchPromptlyDyn $ whenConnected (pure never) $ \peer -> do -- first wait until connected
    fmap switchPromptlyDyn $ resolveSyncName peer name (pure never) $ \i -> do -- wait for id
      let msgE = (\msg -> (mt, encodeSyncCommand i itemId msg)) <$> ea
      peerChanSend peer chan msgE

-- | Synchronisation from client to server. Server can reject values and send actual state.
--
-- Server has to call corresponding 'syncFromClients' function to receive updates.
sendToServerMany :: (SyncMonad t b m, NetworkClient t b m, Store a, Foldable f, Functor f)
  => SyncItemId
  -- ^ Unique name of synchronization value withing current scope
  -> MessageType
  -- ^ Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> Event t (f a)
  -- ^ Source of data to transfer to server.
  -> m (Event t ())
  -- ^ Event that fires each time a new message is passed to server
sendToServerMany itemId mt eas = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  name <- syncCurrentName
  fmap switchPromptlyDyn $ whenConnected (pure never) $ \peer -> do -- first wait until connected
    fmap switchPromptlyDyn $ resolveSyncName peer name (pure never) $ \i -> do -- wait for id
      let msgsE = fmap (\msg -> (mt, encodeSyncCommand i itemId msg)) <$> eas
      peerChanSendMany peer chan msgsE

-- | Helper that fires when a synchronization message in interest arrives
syncMessage :: (SyncMonad t b m, NetworkMonad t b m)
  => (Peer b -> SyncMessage -> Maybe a) -> m (Event t a)
syncMessage predicate = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  msgE <- chanMessage chan
  --logInfoE $ fmap (const "!") msgE
  logEitherWarn $ fforMaybe msgE $ \(peer, bs) -> moveEither $ do
    msg <- decodeSyncMessage bs
    return $ predicate peer msg
  where
    moveEither :: Either PeekException (Maybe a) -> Maybe (Either LogStr a)
    moveEither e = case e of
      Left er -> Just . Left $ showl er
      Right ma -> Right <$> ma

-- | Helper that fires when a sync request arrives
syncRequestMessage :: (SyncMonad t b m, NetworkMonad t b m)
  => Peer b -- ^ Expected peer as source of message
  -> SyncId -- ^ Id of scope that is expected
  -> SyncItemId -- ^ Id of synch item that is expected
  -> m (Event t ())
syncRequestMessage peer i ii = syncMessage $ \peer' msg -> case msg of
  SyncRequestMessage i' ii' -> if peer' == peer && i' == i && ii' == ii
    then Just ()
    else Nothing
  _ -> Nothing

-- | Helper, fires when a synchronization message arrived
syncServiceMessage :: (SyncMonad t b m, NetworkMonad t b m)
  => m (Event t (Peer b, SyncServiceMessage))
syncServiceMessage = syncMessage $ \peer msg -> case msg of
  SyncServiceMessage smsg -> Just (peer, smsg)
  _ -> Nothing

-- | Helper, fires when a synchronization message arrived
syncPeerMessage :: (SyncMonad t b m, NetworkMonad t b m, Store a)
  => Peer b -- ^ Peer that should send the message
  -> SyncId -- ^ Scope id that is expected
  -> SyncItemId -- ^ Sync item id in scope
  -> m (Event t a)
syncPeerMessage peer i itemId = do
  msgE <- syncMessage $ \peer' msg -> case msg of
    SyncPayloadMessage i' itemId' c bs -> if peer == peer' && i == i' && itemId == itemId'
      then Just (c, bs)
      else Nothing
    _ -> Nothing
  notLateE <- fmap (fmapMaybe id) $ performNetwork $ ffor msgE $ \(c, bs) -> do
    notLate <- syncCheckReceiveCounter peer c
    return $ if notLate then Just bs else Nothing
  logEitherWarn $ ffor notLateE $ first mkDecodeFailMsg . decode
  where
    mkDecodeFailMsg e = "Sync: Failed to decode payload for scope: "
      <> showl i <> ", with item id: "
      <> showl itemId <> ", error: "
      <> showl e

-- | Helper, fires when a synchronization command arrived
syncPeerCommand :: (SyncMonad t b m, NetworkMonad t b m, Store a)
  => Peer b -- ^ Peer that should send the message
  -> SyncId -- ^ Scope id that is expected
  -> SyncItemId -- ^ Sync item id in scope
  -> m (Event t a)
syncPeerCommand peer i itemId = do
  msgE <- syncMessage $ \peer' msg -> case msg of
    SyncCommandMessage i' itemId' bs -> if peer == peer' && i == i' && itemId == itemId'
      then Just bs
      else Nothing
    _ -> Nothing
  logEitherWarn $ ffor msgE $ first mkDecodeFailMsg . decode
  where
    mkDecodeFailMsg e = "Sync: Failed to decode command for scope: "
      <> showl i <> ", with item id: "
      <> showl itemId <> ", error: "
      <> showl e

-- | Helper that finds id for name or create new id for the name.
makeSyncName :: SyncMonad t b m
  => SyncName -- ^ Name to get id for
  -> m SyncId
makeSyncName name = do
  namesDyn <- syncKnownNames
  startNames <- sample . current $ namesDyn
  case H.lookup name startNames of
    Just i -> return i
    Nothing -> syncUnsafeRegId name

-- | Helper that tries to get an id for given sync name and then switch into
-- given handler.
resolveSyncName :: forall t m a b . (SyncMonad t b m, NetworkMonad t b m)
  => Peer b -- ^ Where to ask the name id
  -> SyncName -- ^ Name to resolve
  -> m a -- ^ Initial value
  -> (SyncId -> m a) -- ^ Next component to switch in when id of the name is acquired
  -> m (Dynamic t a) -- ^ Fired when the function finally resolve the name
resolveSyncName peer name im m = do
  namesDyn <- syncKnownNames
  startNames <- sample . current $ namesDyn
  case H.lookup name startNames of
    Just i -> do
      a <- m i
      return $ pure a
    Nothing -> do
      opts <- syncOptions
      buildE <- getPostBuild
      let resolvedEMany = fforMaybe (updated namesDyn) $ H.lookup name
      resolvedE <- headE resolvedEMany
      tickE <- tickEveryUntil (opts ^. syncOptionsResolveDelay) resolvedE
      let chan = opts ^. syncOptionsChannel
          requestE = leftmost [tickE, buildE]
      _ <- requestSyncId peer chan $ const name <$> requestE
      networkHold im $ fmap m resolvedE

-- | Helper that sends message to server with request to send back id of given
-- sync object.
--
-- Return event that fires when the request message is sent.
requestSyncId :: (LoggingMonad t m, NetworkMonad t b m)
  => Peer b -> ChannelId -> Event t SyncName -> m (Event t ())
requestSyncId peer chan ename = peerChanSend peer chan $ fmap mkMessage ename
  where
    mkMessage = (ReliableMessage,) . encodeSyncServiceMsg . ServiceAskId

-- | Helper that listens for all requests for sync ids and sends responds to them.
-- Also registers all ids from master nodes if respond is arrived to the local node.
--
-- The component is included in all implementations of the sync module.
syncService :: forall t m b . (SyncMonad t b m, NetworkMonad t b m) => m ()
syncService = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
      role = opts ^. syncOptionsRole
  -- Filter messages
  msgE <- syncServiceMessage
  let reqE = fforMaybe msgE $ \(peer, msg) -> case msg of
        ServiceAskId name -> Just (peer, name)
        _ -> Nothing
      respE = fforMaybe msgE $ \(_, msg) -> case msg of
        ServiceTellId i name -> Just (name, i)
        _ -> Nothing
  -- Responses to request
  namesDyn <- syncKnownNames
  logVerboseE $ ffor reqE $ \(_, name) -> "Sync: got request for id of '" <> showl name <> "'"
  _ <- msgSend $ flip push reqE $ \(peer, name) -> do
    names <- sample . current $ namesDyn
    let makeMsg i = (peer, chan, ReliableMessage,) . encodeSyncServiceMsg $ ServiceTellId i name
    return $ makeMsg <$> H.lookup name names
  -- Update cache for responses
  case role of
    SyncSlave -> do
      logVerboseE $ ffor respE $ \(name, i) -> "Sync: registering '"
        <> showl name <> "' <=> '"
        <> showl i <> "'"
      void $ performNetwork $ ffor respE $ uncurry syncUnsafeAddId
    SyncMaster -> return () -- not interested in on server

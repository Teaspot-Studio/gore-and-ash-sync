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
  , syncWithName
  -- ** Server side
  , syncToClient
  , syncToClients
  , syncToAllClients
  , syncFromClient
  , syncFromClients
  , syncFromAllClients
  -- ** Client side
  , syncToServer
  , syncFromServer
  -- ** Prediction
  , predict
  , predictMaybe
  , predictM
  , predictMaybeM
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
import Data.Bifunctor
import Data.Monoid
import Data.Store
import Game.GoreAndAsh.Core
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync.Message
import Game.GoreAndAsh.Sync.Options
import Game.GoreAndAsh.Time
import GHC.Generics

import qualified Data.HashMap.Strict as H
import qualified Data.Map.Strict as M

-- TODO, what is left to finish the module:
-- 1. Remote collections.

-- | Bijection between name and id of synchronized object
type NameMap = H.HashMap SyncName SyncId

class (MonadAppHost t m, TimerMonad t m, LoggingMonad t m, MonadMask m)
  => SyncMonad t m | m -> t where
    -- | Get settings of the module
    syncOptions :: m (SyncOptions ())
    -- | Get map of known names on the node
    syncKnownNames :: m (Dynamic t NameMap)
    -- | Return current scope sync object of synchronization object
    syncCurrentName :: m SyncName
    -- | Set current scope sync object. Unsafe as change of scope name have to
    -- occur only at a scope border. See 'syncWithName'.
    --
    -- Need this as cannot implement automatic lifting with 'syncWithName' as
    -- primitive operation.
    syncUnsafeSetName :: SyncName -> m ()
    -- | Register new id for given name (overwrites existing ids).
    --
    -- Used by server to generate id for name.
    syncUnsafeRegId :: SyncName -> m SyncId
    -- | Register new id for given name (overwrites existing ids).
    --
    -- Used by client to register id requested from server.
    syncUnsafeAddId :: SyncName -> SyncId -> m ()

-- | Execute nested action with given scope name and restore it after
syncWithName :: SyncMonad t m => SyncName -> m a -> m a
syncWithName name = bracket setName syncUnsafeSetName . const
  where
  setName = do
    oldName <- syncCurrentName
    syncUnsafeSetName name
    return oldName

instance {-# OVERLAPPABLE #-} (MonadAppHost t (mt m), MonadMask (mt m), MonadTrans mt, SyncMonad t m, TimerMonad t m, LoggingMonad t m)
  => SyncMonad t (mt m) where
    syncOptions = lift syncOptions
    {-# INLINE syncOptions #-}
    syncKnownNames = lift syncKnownNames
    {-# INLINE syncKnownNames #-}
    syncCurrentName = lift syncCurrentName
    {-# INLINE syncCurrentName #-}
    syncUnsafeSetName = lift . syncUnsafeSetName
    {-# INLINE syncUnsafeSetName #-}
    syncUnsafeRegId = lift . syncUnsafeRegId
    {-# INLINE syncUnsafeRegId #-}
    syncUnsafeAddId a b = lift $ syncUnsafeAddId a b
    {-# INLINE syncUnsafeAddId #-}

-- | Start streaming given dynamic value to specific client.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
--
-- You can group 'syncToClient' calls within single 'processPeers' or 'peersCollection'
-- as it more efficient than calling 'syncToAllClients' for each dynamic for the
-- same set of peers.
syncToClient :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Client that is target of synchronisation.
  -> Peer
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t ())
syncToClient itemId mt da peer = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- listen for requests
  reqE <- syncRequestMessage peer i itemId
  let respE = tagPromptlyDyn da reqE
  -- send updates
  buildE <- getPostBuild
  let initialE = tagPromptlyDyn da buildE
      updatedE = leftmost [updated da, respE, initialE]
      msgE = fmap (encodeSyncMessage mt i itemId) updatedE
  peerChanSend peer chan msgE

-- | Start streaming given dynamic value to all connected clients.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Fires when user wants to add/remove peers from set of receives of the value
  => Event t (M.Map Peer PeerAction)
  -- | Filter peers that is connected at the first time. Return 'False' at
  -- connected peer will not be placed in the
  -> (Peer -> PushM t Bool)
  -- | Unique name of synchronization value withing current scope
  -> SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t [Peer])
syncToClients peerManual checkPeer itemId mt da = do
  dynSended <- peersCollection peerManual checkPeer $
    syncToClient itemId mt da
  pure . switchPromptlyDyn $ fmap (fmap M.keys . mergeMap) dynSended

-- | Start streaming given dynamic value to all connected clients.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToAllClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t [Peer])
syncToAllClients = syncToClients never (const $ pure True)

-- | Synchronisation from client to server. Server can reject values and send actuall value.
--
-- Server has to call corresponding 'syncToServer' function to receive updates.
--
-- You probably want to group 'syncFromClient' calls within one scope of 'processPeers'
-- or 'peersCollection' as it more efficient than multiple calls for 'syncFromClients'
-- or 'syncFromAllClients'.
syncFromClient :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Make initial value
  -> m a
  -- | Function that checks state from client is actually valid, if the predicate
  -- returns 'Just', server will send actual local state to client.
  -> (a -> PushM t (Maybe a))
  -- | Peer that is listened for values.
  -> Peer
  -- | Collected state for each Peer.
  -> m (Dynamic t a)
syncFromClient itemId mkInit predicate peer = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  -- listen for state
  msgE <- syncPeerMessage peer i itemId
  -- check whether we want to reject value
  let rejectE = push predicate msgE
      rejectMsgE = encodeSyncMessage ReliableMessage i itemId <$> rejectE
  _ <- peerChanSend peer chan rejectMsgE
  -- collect state on server side
  initVal <- mkInit
  holdDyn initVal $ leftmost [rejectE, msgE]

-- | Synchronisation from clients to server. Server can reject values and send actuall value.
--
-- Server has to call corresponding 'syncToServer' function to receive updates.
syncFromClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Fires when user wants to add/remove peers from set of receives of the value
  => Event t (M.Map Peer PeerAction)
  -- | Filter peers that is connected at the first time. Return 'False' at
  -- connected peer will not be placed in the
  -> (Peer -> PushM t Bool)
  -- | Unique name of synchronization value withing current scope
  -> SyncItemId
  -- | Make initial value
  -> (Peer -> m a)
  -- | Function that checks state from client is actually valid, if the predicate
  -- returns 'Just', server will send actual local state to client.
  -> (Peer -> a -> PushM t (Maybe a))
  -- | Collected state for each Peer.
  -> m (Dynamic t (M.Map Peer a))
syncFromClients peerManual checkPeer itemId mkInit predicate = do
  dynResults <- peersCollection peerManual checkPeer $ \peer ->
    syncFromClient itemId (mkInit peer) (predicate peer) peer
  return $ joinDynThroughMap dynResults

-- | Synchronisation from client to server. Server can reject values and send actuall value.
--
-- Server has to call corresponding 'syncToServer' function to receive updates.
syncFromAllClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Make initial value
  -> (Peer -> m a)
  -- | Function that checks state from client is actually valid, if the predicate
  -- returns 'Just', server will send actual local state to client.
  -> (Peer -> a -> PushM t (Maybe a))
  -- | Collected state for each Peer.
  -> m (Dynamic t (M.Map Peer a))
syncFromAllClients = syncFromClients never (const $ pure True)

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

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predict :: (MonadAppHost t m)
  -- | Original dynamic. Common case is dynamic from 'syncFromServer' function.
  => Dynamic t a
  -- | Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> Event t b
  -- | Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> (b -> a -> a)
  -- | Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
  -> m (Dynamic t a)
predict origDyn tickE predictFunc = do
  dynDyn <- holdAppHost (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDyn predictFunc a tickE

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictMaybe :: (MonadAppHost t m)
  -- | Original dynamic. Common case is dynamic from 'syncFromServer' function.
  => Dynamic t a
  -- | Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> Event t b
  -- | Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> (b -> a -> Maybe a)
  -- | Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
  -> m (Dynamic t a)
predictMaybe origDyn tickE predictFunc = do
  dynDyn <- holdAppHost (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDynMaybe predictFunc a tickE

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictM :: (MonadAppHost t m)
  -- | Original dynamic. Common case is dynamic from 'syncFromServer' function.
  => Dynamic t a
  -- | Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> Event t b
  -- | Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> (b -> a -> PushM t a)
  -- | Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
  -> m (Dynamic t a)
predictM origDyn tickE predictFunc = do
  dynDyn <- holdAppHost (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDynM predictFunc a tickE

-- | Make predictions about next value of dynamic. This helper should be handy
-- for implementing client side prediction of values from server.
predictMaybeM :: (MonadAppHost t m)
  -- | Original dynamic. Common case is dynamic from 'syncFromServer' function.
  => Dynamic t a
  -- | Event that fires when we need to calculate next prediction. That can be
  -- timer tick or any other event that fires between updates of original dynamic.
  -> Event t b
  -- | Prediction function that builds new 'a' value from prediction event value
  -- and current dynamic value or value from previous prediction step.
  -> (b -> a -> PushM t (Maybe a))
  -- | Resulted predicted dynamic value. Each time original event fires, all
  -- predicted values are substituted with the new one.
  -> m (Dynamic t a)
predictMaybeM origDyn tickE predictFunc = do
  dynDyn <- holdAppHost (pure origDyn) (predict' <$> updated origDyn)
  return $ join dynDyn
  where
    predict' a = foldDynMaybeM predictFunc a tickE

-- | Receive stream of values from remote server.
--
-- Matches to call of 'syncToClients', should be called on client side.
syncFromServer :: (SyncMonad t m, NetworkClient t m, Store a)
  => SyncItemId -- ^ Unique name of synchronization value withing current scope
  -> a -- ^ Initial value
  -> m (Dynamic t a)
syncFromServer itemId initVal = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  let pureInitVal = return $ pure initVal
  name <- syncCurrentName
  fmap join $ whenConnected pureInitVal $ \peer -> do -- first wait until connected
    fmap join $ resolveSyncName name pureInitVal $ \i -> do -- wait for id
      -- send initial request to inform client of initial value for rarely changing values
      buildE <- getPostBuild
      let reqE = const (encodeSyncRequest ReliableMessage i itemId) <$> buildE
      _ <- peerChanSend peer chan reqE
      -- listen for responds of server
      msgE <- syncPeerMessage peer i itemId
      holdDyn initVal msgE -- here collect updates in dynamic

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
syncToServer :: (SyncMonad t m, NetworkClient t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to server. Note that updates to server
  -- are sent each time the dynamic fires event the current value of
  -- internal behavior isn't changed.
  -> Dynamic t a
  -- | Event that fires each time a new message is passed to server or server
  -- rejected client state.
  --
  -- Note: that you might like to update input dynamic with corrected values via
  -- mfix cycle.
  -> m (Event t (ClientSynced a))
syncToServer itemId mt da = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  name <- syncCurrentName
  dynEv <- whenConnected (pure never) $ \peer -> do -- first wait until connected
    dynEv <- resolveSyncName name (pure never) $ \i -> do -- wait for id
      -- we need to send initial request to inform client of initial value for rarely changing values
      buildE <- getPostBuild
      let initialE = encodeSyncMessage mt i itemId <$> tagPromptlyDyn da buildE
          updatedE = encodeSyncMessage mt i itemId <$> updated da
      sendedE <- peerChanSend peer chan $ leftmost [updatedE, initialE]
      -- listen for responds of server
      msgE <- syncPeerMessage peer i itemId
      -- we can either inform about rejected value or that we synced to server
      return $ leftmost [
          ServerRejected <$> msgE
        , const ClientSentToServer <$> sendedE
        ]
    return $ switchPromptlyDyn dynEv
  return $ switchPromptlyDyn dynEv

-- | Helper that fires when a synchronization message in interest arrives
syncMessage :: (SyncMonad t m, NetworkMonad t m)
  => (Peer -> SyncMessage -> Maybe a) -> m (Event t a)
syncMessage predicate = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  msgE <- chanMessage chan
  logEitherWarn $ fforMaybe msgE $ \(peer, bs) -> moveEither $ do
    msg <- decodeSyncMessage bs
    return $ predicate peer msg
  where
    moveEither :: Either PeekException (Maybe a) -> Maybe (Either LogStr a)
    moveEither e = case e of
      Left er -> Just . Left $ showl er
      Right ma -> Right <$> ma

-- | Helper that fires when a sync request arrives
syncRequestMessage :: (SyncMonad t m, NetworkMonad t m)
  => Peer -- ^ Expected peer as source of message
  -> SyncId -- ^ Id of scope that is expected
  -> SyncItemId -- ^ Id of synch item that is expected
  -> m (Event t ())
syncRequestMessage peer i ii = syncMessage $ \peer' msg -> case msg of
  SyncRequestMessage i' ii' -> if peer' == peer && i' == i && ii' == ii
    then Just ()
    else Nothing
  _ -> Nothing

-- | Helper, fires when a synchronization message arrived
syncServiceMessage :: (SyncMonad t m, NetworkMonad t m)
  => m (Event t (Peer, SyncServiceMessage))
syncServiceMessage = syncMessage $ \peer msg -> case msg of
  SyncServiceMessage smsg -> Just (peer, smsg)
  _ -> Nothing

-- | Helper, fires when a synchronization message arrived
syncPeerMessage :: (SyncMonad t m, NetworkMonad t m, Store a)
  => Peer -- ^ Peer that should send the message
  -> SyncId -- ^ Scope id that is expected
  -> SyncItemId -- ^ Sync item id in scope
  -> m (Event t a)
syncPeerMessage peer i itemId = do
  msgE <- syncMessage $ \peer' msg -> case msg of
    SyncPayloadMessage i' itemId' bs -> if peer == peer' && i == i' && itemId == itemId'
      then Just bs
      else Nothing
    _ -> Nothing
  logEitherWarn $ ffor msgE $ first mkDecodeFailMsg . decode
  where
    mkDecodeFailMsg e = "Sync: Failed to decode payload for scope: "
      <> showl i <> ", with item id: "
      <> showl itemId <> ", error: "
      <> showl e

-- | Helper that finds id for name or create new id for the name.
makeSyncName :: SyncMonad t m
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
resolveSyncName :: forall t m a . (SyncMonad t m, NetworkClient t m)
  => SyncName -- ^ Name to resolve
  -> m a -- ^ Initial value
  -> (SyncId -> m a) -- ^ Next component to switch in when id of the name is acquired
  -> m (Dynamic t a) -- ^ Fired when the function finally resolve the name
resolveSyncName name im m = do
  namesDyn <- syncKnownNames
  startNames <- sample . current $ namesDyn
  case H.lookup name startNames of
    Just i -> cachedName i
    Nothing -> join <$> chain (resolveStep namesDyn)
  where
    cachedName :: SyncId -> m (Dynamic t a)
    cachedName i = do
      a <- m i
      return $ pure a

    resolveStep :: Dynamic t NameMap -> m (Dynamic t a, Chain t m (Dynamic t a))
    resolveStep namesDyn = do
      opts <- syncOptions
      buildE <- getPostBuild
      let resolvedE = fforMaybe (updated namesDyn) $ H.lookup name
      tickE <- tickEveryUntil (opts ^. syncOptionsResolveDelay) resolvedE
      let chan = opts ^. syncOptionsChannel
          requestE = leftmost [tickE, buildE]
      _ <- requestSyncId chan $ const name <$> requestE
      initVal <- im
      return (pure initVal, Chain $ fmap calcStep resolvedE)

    calcStep :: SyncId -> m (Dynamic t a, Chain t m (Dynamic t a))
    calcStep i = do
      a <- m i
      return (pure a, Chain never)

-- | Helper that sends message to server with request to send back id of given
-- sync object.
--
-- Return event that fires when the request message is sent.
requestSyncId :: (LoggingMonad t m, NetworkClient t m)
  => ChannelID -> Event t SyncName -> m (Event t ())
requestSyncId chan ename = do
  dynSent <- whenConnected (pure never) $ \server ->
    peerChanSend server chan $ fmap mkMessage ename
  return $ switchPromptlyDyn dynSent
  where
    mkMessage = encodeSyncServiceMsg ReliableMessage . ServiceAskId

-- | Helper that listens for all requests for sync ids and sends responds to them.
-- Also registers all ids from master nodes if respond is arrived to the local node.
--
-- The component is included in all implementations of the sync module.
syncService :: forall t m . (SyncMonad t m, NetworkMonad t m) => m ()
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
    let makeMsg i = (peer, chan,) . encodeSyncServiceMsg ReliableMessage $ ServiceTellId i name
    return $ makeMsg <$> H.lookup name names
  -- Update cache for responses
  case role of
    SyncSlave -> do
      logVerboseE $ ffor respE $ \(name, i) -> "Sync: registering '"
        <> showl name <> "' <=> '"
        <> showl i <> "'"
      void $ performAppHost $ ffor respE $ uncurry syncUnsafeAddId
    SyncMaster -> return () -- not interested in on server

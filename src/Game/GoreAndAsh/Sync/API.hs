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
    SyncName
  , SyncItemId
  , SyncMonad(..)
  , syncWithName
  , syncToClients
  , syncToClientsUniq
  , syncFromServer
  -- * Internal
  , NameMap
  , syncService
  ) where

import Control.Lens ((^.))
import Control.Monad
import Control.Monad.Catch
import Control.Monad.Trans
import Data.Monoid
import Data.Store
import Game.GoreAndAsh.Core
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync.Message
import Game.GoreAndAsh.Sync.Options
import Game.GoreAndAsh.Time

import qualified Data.HashMap.Strict as H
import qualified Data.Map.Strict as M

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

-- TODO: Idea to make named dynamic NDynamic t a = (SyncName, Dynamic t a)

-- | Start streaming given dynamic value to all connected clients.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToClients :: (SyncMonad t m, NetworkServer t m, Store a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed each time the dynamic fires event the current value of
  -- internal behavior isn't changed. See also: 'syncToClientsUniq'.
  -> Dynamic t a
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t [Peer])
syncToClients itemId mt da = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  i <- makeSyncName =<< syncCurrentName
  dynSended <- processPeers $ \peer -> do
    buildE <- getPostBuild
    let updatedE = leftmost [updated da, tagPromptlyDyn da buildE]
        msgE = fmap (encodeSyncMessage mt i itemId) updatedE
    peerChanSend peer chan msgE
  pure . switchPromptlyDyn $ fmap (fmap M.keys . mergeMap) dynSended

-- | Start streaming given dynamic value to all connected clients only if given
-- dynamic is acturally changed.
--
-- Intended to be called on server side and a corresponding 'syncFromServer'
-- call is needed on client side.
syncToClientsUniq :: (SyncMonad t m, NetworkServer t m, Store a, Eq a)
  -- | Unique name of synchronization value withing current scope
  => SyncItemId
  -- | Underlying message type for sending, you can set unrelable delivery if
  -- the data rapidly changes.
  -> MessageType
  -- | Source of data to transfer to clients. Note that updated to clients
  -- are performed only when new value of the dynamic is actually different
  -- from previous one.
  -> UniqDynamic t a
  -- | Returns event that fires when a value was synced to given peers
  -> m (Event t [Peer])
syncToClientsUniq itemId mt = syncToClients itemId mt . fromUniqDynamic

-- | Receive stream of values from remote server.
--
-- Matches to call of 'syncToClients', should be called on client side.
syncFromServer :: (SyncMonad t m, NetworkClient t m, Store a)
  => SyncItemId -- ^ Unique name of synchronization value withing current scope
  -> a -- ^ Initial value
  -> m (Dynamic t a)
syncFromServer itemId initVal = do
  name <- syncCurrentName
  let pureInitVal = return $ pure initVal
  fmap join $ whenConnected pureInitVal $ \peer -> do -- first wait until connected
    fmap join $ resolveSyncName name pureInitVal $ \i -> do -- wait for id
      msgE <- syncPeerMessage peer
      let neededMsgE = fforMaybe msgE $ \(i', itemId', a) -> if i == i' && itemId == itemId'
            then Just a
            else Nothing
      holdDyn initVal neededMsgE -- here collect updates in dynamic

-- syncToServer :: (SyncMonad t m, NetworkClient t m, Store a)
--   => SyncName -- ^ Unique name of synchronization object
--   ->

-- | Helper that fires when a synchronization message arrives
syncMessage :: (SyncMonad t m, NetworkMonad t m, Store a)
  => m (Event t (Peer, SyncId, SyncItemId, a))
syncMessage = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  msgE <- chanMessage chan
  logEitherWarn $ fforMaybe msgE $ \(peer, bs) -> moveEither $ do
    msg <- decodeSyncMessage bs
    case msg of
      SyncPayloadMessage i itemId bs' -> do
        msg' <- decode bs'
        return $ Just (peer, i, itemId, msg')
      _ -> return Nothing
  where
    moveEither :: Either PeekException (Maybe a) -> Maybe (Either LogStr a)
    moveEither e = case e of
      Left er -> Just . Left $ showl er
      Right ma -> Right <$> ma

-- | Helper, fires when a synchronization message arrived
syncServiceMessage :: (SyncMonad t m, NetworkMonad t m)
  => m (Event t (Peer, SyncServiceMessage))
syncServiceMessage = do
  opts <- syncOptions
  let chan = opts ^. syncOptionsChannel
  msgE <- chanMessage chan
  logEitherWarn $ fforMaybe msgE $ \(peer, bs) -> moveEither $ do
    msg <- decodeSyncMessage bs
    case msg of
      SyncServiceMessage smsg -> return $ Just (peer, smsg)
      _ -> return Nothing
  where
    moveEither :: Either PeekException (Maybe a) -> Maybe (Either LogStr a)
    moveEither e = case e of
      Left er -> Just . Left $ showl er
      Right ma -> Right <$> ma

-- | Helper, fires when a synchronization message arrived
syncPeerMessage :: (SyncMonad t m, NetworkMonad t m, Store a)
  => Peer -> m (Event t (SyncId, SyncItemId, a))
syncPeerMessage peer = do
  msgE <- syncMessage
  return $ fforMaybe msgE $ \(peer', i, itemId, msg) -> if peer == peer'
    then Just (i, itemId, msg)
    else Nothing

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

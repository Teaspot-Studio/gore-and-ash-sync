-- | Demonstrate synchronisation of collection. Server starts five counters in
-- a collection and dynamically adds-removes additional counters. Clients
-- automatically receives updates including creation/removing of counters.
--
-- Usage:
--
-- * Start server: `gore-and-ash-sync-example06 server 5656`
--
-- * Start client: `gore-and-ash-sync-example06 client localhost 5656`
{-# LANGUAGE RecursiveDo #-}
module Main where

import Control.Lens
import Control.Monad.IO.Class
import Data.Map.Strict (Map)
import Data.Monoid
import Data.Ord
import Game.GoreAndAsh
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync
import Game.GoreAndAsh.Time
import Network.Socket
import System.Environment
import Text.Read

import qualified Data.List as L
import qualified Data.Map.Strict as M

-- | Application monad that is used for implementation of game API
type AppMonad = SyncT Spider (TimerT Spider (NetworkT Spider (LoggingT Spider(GameMonad Spider))))

-- | ID of collection object that is same on clients and server
collectionId :: SyncItemId
collectionId = 0

-- | Number of dynamic counters that is created initially both on client and server
countersCount :: Int
countersCount = 0

-- | Map that holds id of counter and it initial value
type CounterMap = Map Int Int

-- | Map that contains addition or deletion request for counter
type CounterUpdateMap = Map Int (Maybe Int)

-- | Convert map of dynamic ints to flat list
flattenCountersMap :: Reflex t => Map Int (Dynamic t Int) -> Dynamic t [Int]
flattenCountersMap = sequence . fmap snd . L.sortBy (comparing fst) . M.toList

-- | Server behavior
serverLogic :: forall t m . (LoggingMonad t m, NetworkServer t m, SyncMonad t m)
  => m ()
serverLogic = do
  let initalCnts = initialCounters countersCount
  rec
    updatesE <- makeRandomCounters countersCountDyn
    countersMapDyn <- hostSimpleCollection collectionId initalCnts updatesE makeSharedCounter
    let countersCountDyn = fmap length countersMapDyn
  let countersDyn = flattenCountersMap =<< countersMapDyn
  logInfoE $ ffor (updated $ uniqDyn countersDyn) $ \ns -> "Counters state: " <> showl ns
  where
  initialCounters :: Int -> CounterMap
  initialCounters n = M.fromList $ ffor [0 .. n-1] $ \i -> (i, i)

  makeSharedCounter :: Int -> Int -> m (Dynamic t Int)
  makeSharedCounter i v0 = do
    ref <- newExternalRef v0
    tickE <- tickEvery (fromIntegral $ i + 1)
    performEvent_ $ ffor tickE $ const $ modifyExternalRef ref $ \n -> (n+1, ())
    dynCnt <- externalRefDynamic ref
    _ <- syncToAllClients (fromIntegral i) UnreliableMessage dynCnt
    return dynCnt

  makeRandomCounters :: Dynamic t Int -> m (Event t CounterUpdateMap)
  makeRandomCounters lengthDyn = do
    addTickE <- tickEvery (fromIntegral (3 :: Int))
    delTickE <- tickEvery (fromIntegral (4 :: Int))
    let addE = flip pushAlways addTickE $ const $ do
          n <- sample . current $ lengthDyn
          return $ M.singleton n (Just n)
        delE = flip pushAlways delTickE $ const $ do
          n <- sample . current $ lengthDyn
          return $ M.singleton (n-1) Nothing
    return $ addE <> delE

-- Server application.
-- The application should be generic in the host monad that is used
appServer :: forall t m . (LoggingMonad t m, NetworkServer t m, SyncMonad t m)
  => PortNumber -> m ()
appServer p = do
  e <- getPostBuild
  loggingSetDebugFlag False
  listenE <- dontCare =<< (serverListen $ ffor e $ const $ ServerListen {
      listenAddress = SockAddrInet p 0
    , listenMaxConns = 100
    , listenChanns = 3
    , listenIncoming = 0
    , listenOutcoming = 0
    })
  logInfoE $ ffor listenE $ const $ "Started to listen port " <> showl p <> " ..."

  connE <- peerConnected
  logInfoE $ ffor connE $ const $ "Peer is connected..."

  discE <- peerDisconnected
  logInfoE $ ffor discE $ const $ "Peer is disconnected..."

  serverLogic

-- | Find server address by host name or IP
resolveServer :: MonadIO m => HostName -> ServiceName -> m SockAddr
resolveServer host serv = do
  info <- liftIO $ getAddrInfo Nothing (Just host) (Just serv)
  case info of
    [] -> fail $ "Cannot resolve server address: " <> host
    (a : _) -> return $ addrAddress a

-- | Client side logic of application
clientLogic :: forall t m . (LoggingMonad t m, SyncMonad t m, NetworkClient t m) => m ()
clientLogic = do
  countersMapDyn <- remoteCollection collectionId makeSharedCounter
  let countersDyn = flattenCountersMap =<< countersMapDyn
  logInfoE $ ffor (updated $ uniqDyn countersDyn) $ \ns -> "Counters state: " <> showl ns
  where
  makeSharedCounter :: Int -> Int -> m (Dynamic t Int)
  makeSharedCounter i = syncFromServer (fromIntegral i)

-- Client application.
-- The application should be generic in the host monad that is used
appClient :: (LoggingMonad t m, SyncMonad t m, NetworkClient t m) => HostName -> ServiceName -> m ()
appClient host serv = do
  addr <- resolveServer host serv
  e <- getPostBuild
  connectedE <- dontCare =<< (clientConnect $ ffor e $ const $ ClientConnect {
      clientAddrr = addr
    , clientChanns = 3
    , clientIncoming = 0
    , clientOutcoming = 0
    })
  logInfoE $ ffor connectedE $ const "Connected to server!"
  clientLogic

data Mode = Client HostName ServiceName | Server PortNumber

readArgs :: IO Mode
readArgs = do
  args <- getArgs
  case args of
    ["client", host, serv] -> return $ Client host serv
    ["server", ps] -> case readMaybe ps of
      Nothing -> fail $ "Failed to parse port!"
      Just p -> return $ Server p
    _ -> fail $ "Expected arguments: client <host> <port> | server <port>"

main :: IO ()
main = do
  mode <- readArgs
  let app :: AppMonad ()
      app = case mode of
        Client host serv -> appClient host serv
        Server port -> appServer port
      opts = case mode of
        Client _ _ -> defaultSyncOptions netopts & syncOptionsRole .~ SyncSlave
        Server _ -> defaultSyncOptions netopts & syncOptionsRole .~ SyncMaster
      netopts = (defaultNetworkOptions ()) {
          networkDetailedLogging = False
        }
  runSpiderHost $ hostApp $ runModule opts (app :: AppMonad ())
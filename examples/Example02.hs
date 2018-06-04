-- | Demonstrate dynamic scoping. Server starts five different counters that tick
-- at different time and have different synchronisation scopes. A client have to
-- resolve scope id before it can sync.
--
-- Usage:
--
-- * Start server: `gore-and-ash-sync-example02 server 5656`
--
-- * Start client: `gore-and-ash-sync-example02 client localhost 5656`
module Main where

import Control.Lens
import Control.Monad
import Data.Monoid
import Game.GoreAndAsh
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Network.Backend.TCP
import Game.GoreAndAsh.Sync
import Game.GoreAndAsh.Time
import System.Environment

-- | Application monad that is used for implementation of game API
type AppMonad = SyncT Spider TCPBackend (NetworkT Spider TCPBackend (LoggingT Spider GMSpider))

-- | ID of counter object that is same on clients and server
counterId :: SyncItemId
counterId = 0

-- | Number of dynamic counters that is created both on client and server
countersCount :: Int
countersCount = 5

-- | Number of network channels, the second channel is used
channelCount :: Word
channelCount = 2

-- Server application.
-- The application should be generic in the host monad that is used
appServer :: forall t backend m . (LoggingMonad t m, NetworkClient t backend m, NetworkServer t backend m, SyncMonad t backend m)
  => ServiceName -> m ()
appServer p = do
  loggingSetDebugFlag True
  e <- getPostBuild
  logInfoE $ ffor e $ const $ "Started to listen port " <> showl p <> " ..."

  connE <- peerConnected
  logInfoE $ ffor connE $ const $ "Peer is connected..."

  discE <- peerDisconnected
  logInfoE $ ffor discE $ const $ "Peer is disconnected..."

  someErrorE <- networkSomeError
  sendErrorE <- networkSendError
  logWarnE $ ffor someErrorE $ \er -> "Network error: " <> showl er
  logWarnE $ ffor sendErrorE $ \er -> "Network send error: " <> showl er

  counterDyns <- makeSharedCounters countersCount
  let countersDyn = sequence counterDyns
  logInfoE $ ffor (updated countersDyn) $ \ns -> "Counters state: " <> showl ns
  return ()
  where
  makeSharedCounters :: Int -> m [Dynamic t Int]
  makeSharedCounters n = mapM makeSharedCounter [0 .. n-1]

  makeSharedCounter :: Int -> m (Dynamic t Int)
  makeSharedCounter i = fmap join $ syncWithName ("counter" <> show i) (pure 0) $ do
    ref <- newExternalRef (0 :: Int)
    tickE <- tickEvery (fromIntegral $ i + 1)
    performEvent_ $ ffor tickE $ const $ modifyExternalRef ref $ \n -> (n+1, ())
    dynCnt <- externalRefDynamic ref
    _ <- syncToAllClients counterId UnreliableMessage dynCnt
    return dynCnt

-- | Client side logic of application
clientLogic :: forall t m . (LoggingMonad t m, SyncMonad t TCPBackend m, NetworkClient t TCPBackend m) => m ()
clientLogic = do
  counterDyns <- makeSharedCounters countersCount
  let countersDyn = sequence counterDyns
  logInfoE $ ffor (updated countersDyn) $ \ns -> "Counters state: " <> showl ns
  where
  makeSharedCounters :: Int -> m [Dynamic t Int]
  makeSharedCounters n = mapM makeSharedCounter [0 .. n-1]

  makeSharedCounter :: Int -> m (Dynamic t Int)
  makeSharedCounter i = fmap join $ syncWithName ("counter" <> show i) (pure 0) $ syncFromServer counterId 0

-- Client application.
-- The application should be generic in the host monad that is used
appClient :: (LoggingMonad t m, SyncMonad t TCPBackend m, NetworkClient t TCPBackend m) => HostName -> ServiceName -> m ()
appClient host serv = do
  e <- getPostBuild
  let EndPointAddress addr = encodeEndPointAddress host serv 0
  connectedE <- clientConnect $ ffor e $ const (addr, defaultConnectHints)
  conErrorE <- networkConnectionError
  logInfoE $ ffor connectedE $ const "Connected to server!"
  logErrorE $ ffor conErrorE $ \er -> "Failed to connect: " <> showl er
  clientLogic

data Mode = Client HostName ServiceName | Server ServiceName

readArgs :: IO Mode
readArgs = do
  args <- getArgs
  case args of
    ["client", host, serv] -> return $ Client host serv
    ["server", p] -> return $ Server p
    _ -> fail $ "Expected arguments: client <host> <port> | server <port>"

main :: IO ()
main = do
  mode <- readArgs
  let app :: AppMonad ()
      app = case mode of
        Client host serv -> appClient host serv
        Server port -> appServer port
      opts = case mode of
        Client _ _ -> defaultSyncOptions & syncOptionsRole .~ SyncSlave
        Server _ -> defaultSyncOptions & syncOptionsRole .~ SyncMaster
      tcpOpts = TCPBackendOpts {
          tcpHostName = "127.0.0.1"
        , tcpServiceName = case mode of
             Client _ _ -> ""
             Server port -> port
        , tcpParameters = defaultTCPParameters
        , tcpDuplexHints = defaultConnectHints
        }
      netopts = (defaultNetworkOptions tcpOpts) { networkOptsDetailedLogging = False }
  mres <- runGM $ runLoggerT $ runNetworkT netopts $ runSyncT opts (app :: AppMonad ())
  case mres of
    Left er -> print $ renderNetworkError er
    Right _ -> pure ()

-- | Show client to server sync. Clients have local counter and server tracks
-- all the counters of clients.
--
-- Usage:
--
-- * Start server: `gore-and-ash-sync-example04 server 5656`
--
-- * Start client: `gore-and-ash-sync-example04 client localhost 5656`
module Main where

import Control.Lens
import Data.Monoid
import Game.GoreAndAsh
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Network.Backend.TCP
import Game.GoreAndAsh.Sync
import Game.GoreAndAsh.Time
import System.Environment

import qualified Data.Foldable as F

-- | Application monad that is used for implementation of game API
type AppMonad = SyncT Spider TCPBackend (NetworkT Spider TCPBackend (LoggingT Spider GMSpider))

-- | ID of counter object that is same on clients and server
counterId :: SyncItemId
counterId = 0

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

  countersDyn <- makeSharedCounters
  logInfoE $ ffor (updated countersDyn) $ \ns -> "Counters state: " <> showl ns
  return ()
  where
  makeSharedCounters :: m (Dynamic t [Int])
  makeSharedCounters = do
    let makeInitial = const $ pure 0
    dynMap <- fst <$> syncFromAllClients counterId makeInitial never
    return $ F.toList <$> dynMap

-- | Client side logic of application
clientLogic :: forall t m . (LoggingMonad t m, SyncMonad t TCPBackend m, NetworkClient t TCPBackend m) => m ()
clientLogic = do
  counterDyn <- makeSharedCounter
  logInfoE $ ffor (updated counterDyn) $ \n -> "Counter state: " <> showl n
  where
  makeSharedCounter :: m (Dynamic t Int)
  makeSharedCounter = do
    ref <- newExternalRef (0 :: Int)
    tickE <- tickEvery (realToFrac (1 :: Double))
    performEvent_ $ ffor tickE $ const $ modifyExternalRef ref $ \n -> (n+1, ())
    dynCnt <- externalRefDynamic ref
    _ <- syncToServer counterId UnreliableMessage dynCnt
    return dynCnt

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

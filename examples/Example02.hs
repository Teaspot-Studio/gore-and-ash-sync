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
import Control.Monad.IO.Class
import Data.Monoid
import Game.GoreAndAsh
import Game.GoreAndAsh.Logging
import Game.GoreAndAsh.Network
import Game.GoreAndAsh.Sync
import Game.GoreAndAsh.Time
import Network.Socket
import System.Environment
import Text.Read

-- | Application monad that is used for implementation of game API
type AppMonad = SyncT Spider (TimerT Spider (NetworkT Spider (LoggingT Spider(GameMonad Spider))))

-- | ID of counter object that is same on clients and server
counterId :: SyncItemId
counterId = 0

-- | Number of dynamic counters that is created both on client and server
countersCount :: Int
countersCount = 5

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
    , listenChanns = 2
    , listenIncoming = 0
    , listenOutcoming = 0
    })
  logInfoE $ ffor listenE $ const $ "Started to listen port " <> showl p <> " ..."

  connE <- peerConnected
  logInfoE $ ffor connE $ const $ "Peer is connected..."

  discE <- peerDisconnected
  logInfoE $ ffor discE $ const $ "Peer is disconnected..."

  counterDyns <- makeSharedCounters countersCount
  let countersDyn = sequence counterDyns
  logInfoE $ ffor (updated countersDyn) $ \ns -> "Counters state: " <> showl ns
  return ()
  where
  makeSharedCounters :: Int -> m [Dynamic t Int]
  makeSharedCounters n = mapM makeSharedCounter [0 .. n-1]

  makeSharedCounter :: Int -> m (Dynamic t Int)
  makeSharedCounter i = syncWithName ("counter" <> show i) $ do
    ref <- newExternalRef (0 :: Int)
    tickE <- tickEvery (fromIntegral $ i + 1)
    performEvent_ $ ffor tickE $ const $ modifyExternalRef ref $ \n -> (n+1, ())
    dynCnt <- externalRefDynamic ref
    _ <- syncToAllClients counterId UnreliableMessage dynCnt
    return dynCnt

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
  counterDyns <- makeSharedCounters countersCount
  let countersDyn = sequence counterDyns
  logInfoE $ ffor (updated countersDyn) $ \ns -> "Counters state: " <> showl ns
  where
  makeSharedCounters :: Int -> m [Dynamic t Int]
  makeSharedCounters n = mapM makeSharedCounter [0 .. n-1]

  makeSharedCounter :: Int -> m (Dynamic t Int)
  makeSharedCounter i = syncWithName ("counter" <> show i) $ syncFromServer counterId 0

-- Client application.
-- The application should be generic in the host monad that is used
appClient :: (LoggingMonad t m, SyncMonad t m, NetworkClient t m) => HostName -> ServiceName -> m ()
appClient host serv = do
  addr <- resolveServer host serv
  e <- getPostBuild
  connectedE <- dontCare =<< (clientConnect $ ffor e $ const $ ClientConnect {
      clientAddrr = addr
    , clientChanns = 2
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
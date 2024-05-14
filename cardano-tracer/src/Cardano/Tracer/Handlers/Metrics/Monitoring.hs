{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Tracer.Handlers.Metrics.Monitoring
  ( runMonitoringServer
  ) where

import           Cardano.Tracer.Configuration
import           Cardano.Tracer.Environment
#if RTVIEW
import           Cardano.Tracer.Handlers.SSL.Certs
#endif
import           Cardano.Tracer.MetaTrace
import           Cardano.Tracer.Types

import           Control.Concurrent (ThreadId)
import           Control.Concurrent.STM (atomically)
import           Control.Concurrent.STM.TMVar (TMVar, newEmptyTMVarIO, putTMVar, tryReadTMVar)
import           Control.Concurrent.STM.TVar (readTVarIO)
#if RTVIEW
import           Control.Monad (forM, void)
#endif
import           Control.Monad.Extra (whenJust)
import           Control.Monad.IO.Class (liftIO)
#if !RTVIEW
import           Data.Foldable
import           Data.Function ((&))
#endif
import qualified Data.Map.Strict as M
import qualified Data.Set as S
#if !RTVIEW
import           Data.String
#endif
import qualified Data.Text as T
import           Data.Text.Encoding (encodeUtf8)
import           System.Remote.Monitoring (forkServerWith, serverThreadId)
import           System.Time.Extra (sleep)
#if !RTVIEW
import           System.IO.Unsafe (unsafePerformIO)
import           Text.Blaze.Html5 hiding (title)
import           Text.Blaze.Html5.Attributes
#endif

#if RTVIEW
import qualified Graphics.UI.Threepenny as UI
import           Graphics.UI.Threepenny.Core (Element, UI, set, (#), (#+))
#else
import           Snap.Blaze (blaze)
import           Snap.Core (Snap, route)
import           Snap.Http.Server (Config, ConfigLog (..), defaultConfig, setAccessLog, setBind,
                   setErrorLog, setPort, simpleHttpServe)
#endif

-- | 'ekg' package allows to run only one EKG server, to display only one web page
--   for particular EKG.Store. Since 'cardano-tracer' can be connected to any number
--   of nodes, we display their list on the first web page (the first 'Endpoint')
--   as a list of hrefs. After clicking on the particular href, the user will be
--   redirected to the monitoring web page (the second 'Endpoint') built by 'ekg' package.
--   This page will display the metrics received from that node.
--
--   If the user returns to the first web page and clicks to another node's href,
--   the EKG server will be restarted and the monitoring page will display the metrics
--   received from that node.
runMonitoringServer
  :: TracerEnv
  -> (Endpoint, Endpoint) -- ^ (web page with list of connected nodes, EKG web page).
  -> IO ()
#if RTVIEW
runMonitoringServer tracerEnv (endpoint@(Endpoint listHost listPort), monitorEP) = do
  -- Pause to prevent collision between "Listening"-notifications from servers.
  sleep 0.2
  (certFile, keyFile) <- placeDefaultSSLFiles tracerEnv
  traceWith (teTracer tracerEnv) TracerStartedMonitoring
    { ttMonitoringEndpoint = endpoint
    , ttMonitoringType     = "list"
    }
  UI.startGUI (config certFile keyFile) \window -> do
    void $ return window # set UI.title "EKG Monitoring Nodes"
    void $ mkPageBody window tracerEnv monitorEP
 where
  config cert key =
    UI.defaultConfig
      { UI.jsLog    = const $ return ()
      , UI.jsUseSSL =
          Just $ UI.ConfigSSL
            { UI.jsSSLBind = encodeUtf8 $ T.pack listHost
            , UI.jsSSLPort = fromIntegral listPort
            , UI.jsSSLCert = cert
            , UI.jsSSLKey  = key
            , UI.jsSSLChainCert = False
            }
      }
#else
runMonitoringServer tracerEnv (endpoint@(Endpoint listHost listPort), monitorEP) = do
  -- Pause to prevent collision between "Listening"-notifications from servers.
  sleep 0.2
  traceWith (teTracer tracerEnv) TracerStartedMonitoring
    { ttMonitoringEndpoint = endpoint
    , ttMonitoringType     = "list"
    }
  simpleHttpServe config do
    route 
      [ ("/", renderEkg)
      ]
 where
  TracerEnv{teConnectedNodes} = tracerEnv

  config :: Config Snap ()
  config = defaultConfig
    & setErrorLog ConfigNoLog
    & setAccessLog ConfigNoLog
    & setBind (encodeUtf8 (T.pack listHost))
    & setPort (fromIntegral listPort)

  renderEkg :: Snap ()
  renderEkg = do
    nodes <- liftIO $ S.toList <$> readTVarIO teConnectedNodes

    -- HACK
    case nodes of
      [] ->
        pure ()
      nodeId:_nodes -> liftIO do
        restartEKGServer tracerEnv nodeId monitorEP currentServerHack
    blaze do
      docTypeHtml do
        ekgHtml monitorEP nodes

{-# NOINLINE currentServerHack #-}
currentServerHack :: CurrentEKGServer
currentServerHack = unsafePerformIO newEmptyTMVarIO

ekgHtml
  :: Endpoint
  -> [NodeId]
  -> Html
ekgHtml (Endpoint monitorHost monitorPort) = \case
  [] ->
    toHtml @T.Text "ekgHtml: There are no connected nodes yet"
  connectedNodes -> do
    li do toHtml @T.Text "OKAY"
    for_ connectedNodes \(NodeId anId) ->
      li do
        a ! href (fromString ("http://" <> monitorHost <> ":" <> show monitorPort))
          ! target "_blank"
          ! title "Open EKG monitor page for this node"
          $ toHtml anId
#endif

type CurrentEKGServer = TMVar (NodeId, ThreadId)
#if RTVIEW
-- | The first web page contains only the list of hrefs
--   corresponding to currently connected nodes.
mkPageBody
  :: UI.Window
  -> TracerEnv
  -> Endpoint
  -> UI Element
mkPageBody window tracerEnv mEP@(Endpoint monitorHost monitorPort) = do
  nodes <- liftIO $ S.toList <$> readTVarIO teConnectedNodes
  nodesHrefs <-
    if null nodes
      then UI.string "There are no connected nodes yet"
      else do
        currentServer :: CurrentEKGServer <- liftIO newEmptyTMVarIO
        nodesLinks <-
          forM nodes \nodeId@(NodeId anId) -> do
            nodeLink <-
              UI.li #+
                [ UI.anchor # set UI.href ("http://" <> monitorHost <> ":" <> show monitorPort)
                            # set UI.target "_blank"
                            # set UI.title__ "Open EKG monitor page for this node"
                            # set UI.text (T.unpack anId)
                ]
            void $ UI.on UI.click nodeLink $ const do
              liftIO do
                restartEKGServer
                  tracerEnv nodeId mEP currentServer
            return $ UI.element nodeLink
        UI.ul #+ nodesLinks
  UI.getBody window #+ [ UI.element nodesHrefs ]
 where
  TracerEnv{teConnectedNodes} = tracerEnv
#endif

-- | After clicking on the node's href, the user will be redirected to the monitoring page
--   which is rendered by 'ekg' package. But before, we have to check if EKG server is
--   already launched, and if so, restart the server if needed.
restartEKGServer
  :: TracerEnv
  -> NodeId
  -> Endpoint
  -> CurrentEKGServer
  -> IO ()
restartEKGServer TracerEnv{teAcceptedMetrics, teTracer} newNodeId
                 endpoint@(Endpoint monitorHost monitorPort) currentServer = do
  metrics <- readTVarIO teAcceptedMetrics
  whenJust (metrics M.!? newNodeId) \(storeForSelectedNode, _) ->
    atomically (tryReadTMVar currentServer) >>= \case
      Just (_curNodeId, _sThread) ->
        -- TODO: Currently we cannot restart EKG server,
        -- please see https://github.com/tibbe/ekg/issues/87
        return ()
        -- unless (newNodeId == curNodeId) do
        --   killThread sThread
        --   runEKGAndSave storeForSelectedNode
      Nothing ->
        -- Current server wasn't stored yet, it's a first click on the href.
        runEKGAndSave storeForSelectedNode
 where
  runEKGAndSave store = do
    traceWith teTracer TracerStartedMonitoring
      { ttMonitoringEndpoint = endpoint
      , ttMonitoringType     = "monitor"
      }
    ekgServer <- forkServerWith store
                   (encodeUtf8 . T.pack $ monitorHost)
                   (fromIntegral monitorPort)
    atomically do
      putTMVar currentServer (newNodeId, serverThreadId ekgServer)

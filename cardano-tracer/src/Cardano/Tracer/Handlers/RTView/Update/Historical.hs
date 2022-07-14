{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Tracer.Handlers.RTView.Update.Historical
  ( restoreHistoryFromBackup
  , runHistoricalBackup
  , runHistoricalUpdater
  ) where

import           Control.Concurrent.Async (forConcurrently_)
import           Control.Concurrent.Extra (Lock)
import           Control.Concurrent.STM (atomically)
import           Control.Concurrent.STM.TVar (modifyTVar', readTVar, readTVarIO)
import           Control.Exception.Extra (ignore, try_)
import           Control.Monad (forM, forM_, forever)
import           Control.Monad.Extra (ifM, whenJust)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Csv as CSV
import qualified Data.Map.Strict as M
import           Data.Maybe (mapMaybe)
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Data.Text.Read (decimal, double)
import           Data.Time.Clock.System (getSystemTime, systemToUTCTime)
import qualified Data.Vector as V
import           System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import           System.Directory.Extra (listFiles)
import           System.FilePath ((</>), takeBaseName)
import           System.Time.Extra (sleep)
import           Text.Read (readMaybe)

import           Cardano.Node.Startup (NodeInfo (..))

import           Cardano.Tracer.Handlers.Metrics.Utils
import           Cardano.Tracer.Handlers.RTView.State.Historical
import           Cardano.Tracer.Handlers.RTView.State.Last
import           Cardano.Tracer.Handlers.RTView.State.TraceObjects
import           Cardano.Tracer.Handlers.RTView.System
import           Cardano.Tracer.Handlers.RTView.Update.Chain
import           Cardano.Tracer.Handlers.RTView.Update.Leadership
import           Cardano.Tracer.Handlers.RTView.Update.Resources
import           Cardano.Tracer.Handlers.RTView.Update.Transactions
import           Cardano.Tracer.Handlers.RTView.Update.Utils
import           Cardano.Tracer.Types

-- | A lot of information received from the node is useful as historical data.
--   It means that such an information should be displayed on time charts,
--   where X axis is a time in UTC. An example: resource metrics, chain information,
--   tx information, etc.
--
--   This information is extracted both from 'TraceObject's and 'EKG.Metrics' and then
--   it will be saved as chart coords '[(ts, v)]', where 'ts' is a timestamp
--   and 'v' is a value. Later, when the user will open RTView web-page, this
--   saved data will be used to render historical charts.
--
--   It allows to collect historical data even when RTView web-page is closed.
--
runHistoricalUpdater
  :: SavedTraceObjects
  -> AcceptedMetrics
  -> ResourcesHistory
  -> LastResources
  -> BlockchainHistory
  -> TransactionsHistory
  -> IO ()
runHistoricalUpdater _savedTO acceptedMetrics resourcesHistory
                     lastResources chainHistory txHistory = forever $ do
  sleep 1.0 -- TODO: should it be configured?
  now <- systemToUTCTime <$> getSystemTime
  allMetrics <- readTVarIO acceptedMetrics
  forM_ (M.toList allMetrics) $ \(nodeId, (ekgStore, _)) -> do
    metrics <- getListOfMetrics ekgStore
    forM_ metrics $ \(metricName, metricValue) -> do
      updateTransactionsHistory nodeId txHistory metricName metricValue now
      updateResourcesHistory nodeId resourcesHistory lastResources metricName metricValue now
      updateBlockchainHistory nodeId chainHistory metricName metricValue now
      updateLeadershipHistory nodeId chainHistory metricName metricValue now

runHistoricalBackup
  :: ConnectedNodes
  -> BlockchainHistory
  -> ResourcesHistory
  -> TransactionsHistory
  -> DataPointRequestors
  -> Lock
  -> IO ()
runHistoricalBackup connectedNodes
                    (ChainHistory chainHistory)
                    (ResHistory resourcesHistory)
                    (TXHistory txHistory)
                    dpRequestors currentDPLock = forever $ do
  sleep 300.0 -- TODO: 5 minutes, should it be changed?
  backupAllHistory . S.toList =<< readTVarIO connectedNodes
 where
  backupAllHistory [] = return ()
  backupAllHistory connected = do
    nodesIdsWithNames <- getNodesIdsWithNames connected dpRequestors currentDPLock
    backupDir <- getPathToBackupDir
    (cHistory, rHistory, tHistory) <- atomically $ (,,)
      <$> readTVar chainHistory
      <*> readTVar resourcesHistory
      <*> readTVar txHistory
    -- We can safely work with files for different nodes concurrently.
    forConcurrently_ nodesIdsWithNames $ \(nodeId, nodeName) -> do
      backupHistory backupDir cHistory nodeId nodeName
      backupHistory backupDir rHistory nodeId nodeName
      backupHistory backupDir tHistory nodeId nodeName
    -- Now we can remove historical points from histories,
    -- to prevent big memory consumption.
    cleanupHistoryPoints chainHistory
    cleanupHistoryPoints resourcesHistory
    cleanupHistoryPoints txHistory

  backupHistory backupDir history nodeId nodeName =
    whenJust (M.lookup nodeId history) $ \historyData -> ignore $ do
      let nodeSubdir = backupDir </> T.unpack nodeName
      createDirectoryIfMissing True nodeSubdir
      forM_ (M.toList historyData) $ \(historyDataName, historyPoints) -> do
        let historyDataFile = nodeSubdir </> show historyDataName
        ifM (doesFileExist historyDataFile)
          (BSL.appendFile historyDataFile $ pointsToBS historyPoints)
          (BSL.writeFile  historyDataFile $ pointsToBS historyPoints)

  pointsToBS = CSV.encode . S.toAscList

  -- Remove sets of historical points only, because they are already backed up.
  cleanupHistoryPoints history = atomically $
    modifyTVar' history $ M.map (M.map (const S.empty))

restoreHistoryFromBackup
  :: ConnectedNodes
  -> BlockchainHistory
  -> ResourcesHistory
  -> TransactionsHistory
  -> DataPointRequestors
  -> Lock
  -> IO ()
restoreHistoryFromBackup connectedNodes
                         (ChainHistory _chainHistory)
                         (ResHistory _resourcesHistory)
                         (TXHistory _txHistory)
                         dpRequestors currentDPLock = ignore $ do
  -- We restore historical data only for connected nodes.
  connected <- S.toList <$> readTVarIO connectedNodes
  nodesIdsWithNames <- getNodesIdsWithNames connected dpRequestors currentDPLock
  backupDir <- getPathToBackupDir
  forM_ nodesIdsWithNames $ \(_nodeId, nodeName) -> do
    let nodeSubdir = backupDir </> T.unpack nodeName
    doesDirectoryExist nodeSubdir >>= \case
      False -> return () -- There is no backup for this node.
      True -> do
        backupFiles <- listFiles nodeSubdir
        _dataNamesWithPoints <-
          forM backupFiles $ extractNamesWithHistoricalPoints nodeSubdir
        
        return ()
 where
   extractNamesWithHistoricalPoints nodeSubdir bFile = do
    let pureFile = takeBaseName bFile
    case readMaybe pureFile of
      Nothing -> return (Nothing, S.empty)
      Just (dataName :: DataName) ->
        -- Ok, this file contains historical points for 'dataName', extract them...
        try_ (BSL.readFile (nodeSubdir </> pureFile)) >>= \case
          Left _ -> return (Nothing, S.empty)
          Right rawPoints ->
            case CSV.decode CSV.NoHeader rawPoints of
              Left _ -> return (Nothing, S.empty)
              Right (points :: Vector HistoricalPoint) -> return
                ( Just dataName
                , S.fromList $ V.toList points
                )

getNodesIdsWithNames
  :: [NodeId]
  -> DataPointRequestors
  -> Lock
  -> IO [(NodeId, T.Text)]
getNodesIdsWithNames [] _ _ = return []
getNodesIdsWithNames connected dpRequestors currentDPLock =
  forM connected $ \nodeId@(NodeId anId) ->
    askDataPoint dpRequestors currentDPLock nodeId "NodeInfo" >>= \case
      Nothing -> return (nodeId, anId)
      Just ni -> return (nodeId, niName ni)

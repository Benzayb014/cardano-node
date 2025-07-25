{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wno-orphans  #-}

module Cardano.Node.Tracing.Tracers.P2P
  () where

import           Cardano.Logging
import           Cardano.Network.PeerSelection.PeerTrustable (PeerTrustable)
import           Cardano.Node.Configuration.TopologyP2P ()
import           Cardano.Node.Tracing.Tracers.NodeToNode ()
import           Cardano.Node.Tracing.Tracers.NonP2P ()
import           Cardano.Tracing.OrphanInstances.Network ()
import qualified Ouroboros.Cardano.Network.PeerSelection.Governor.PeerSelectionState as Cardano
import qualified Ouroboros.Cardano.Network.PeerSelection.Governor.Types as Cardano
import qualified Ouroboros.Cardano.Network.PublicRootPeers as Cardano.PublicRootPeers
import           Ouroboros.Network.ConnectionHandler (ConnectionHandlerTrace (..))
import           Ouroboros.Network.ConnectionId (ConnectionId (..))
import           Ouroboros.Network.ConnectionManager.ConnMap (ConnMap (..))
import           Ouroboros.Network.ConnectionManager.Core as ConnectionManager (Trace (..))
import           Ouroboros.Network.ConnectionManager.Types (ConnectionManagerCounters (..))
import qualified Ouroboros.Network.ConnectionManager.Types as ConnectionManager
import           Ouroboros.Network.InboundGovernor as InboundGovernor (Trace (..))
import qualified Ouroboros.Network.InboundGovernor as InboundGovernor
import           Ouroboros.Network.InboundGovernor.State as InboundGovernor (Counters (..))
import qualified Ouroboros.Network.NodeToNode as NtN
import           Ouroboros.Network.PeerSelection.Churn (ChurnCounters (..))
import           Ouroboros.Network.PeerSelection.Governor (DebugPeerSelection (..),
                   DebugPeerSelectionState (..), PeerSelectionCounters, PeerSelectionState (..),
                   PeerSelectionTargets (..), PeerSelectionView (..), TracePeerSelection (..),
                   peerSelectionStateToCounters)
import           Ouroboros.Network.PeerSelection.Governor.Types (DemotionTimeoutException)
import           Ouroboros.Network.PeerSelection.PeerStateActions (PeerSelectionActionsTrace (..))
import           Ouroboros.Network.PeerSelection.RelayAccessPoint (RelayAccessPoint)
import           Ouroboros.Network.PeerSelection.RootPeersDNS.LocalRootPeers
                   (TraceLocalRootPeers (..))
import           Ouroboros.Network.PeerSelection.RootPeersDNS.PublicRootPeers
                   (TracePublicRootPeers (..))
import qualified Ouroboros.Network.PeerSelection.State.KnownPeers as KnownPeers
import           Ouroboros.Network.PeerSelection.Types ()
import           Ouroboros.Network.Protocol.PeerSharing.Type (PeerSharingAmount (..))
import           Ouroboros.Network.RethrowPolicy (ErrorCommand (..))
import           Ouroboros.Network.Server2 as Server
import           Ouroboros.Network.Snocket (LocalAddress (..))

import           Control.Exception (displayException, fromException)
import           Data.Aeson (Object, ToJSON, ToJSONKey, Value (..), object, toJSON, toJSONList,
                   (.=))
import           Data.Aeson.Types (listValue)
import           Data.Bifunctor (Bifunctor (..))
import           Data.Foldable (Foldable (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import           Data.Text (pack)
import           Network.Socket (SockAddr (..))



--------------------------------------------------------------------------------
-- LocalRootPeers Tracer
--------------------------------------------------------------------------------

instance
  ( ToJSONKey ntnAddr
  , ToJSON ntnAddr
  , ToJSONKey RelayAccessPoint
  , Show ntnAddr
  , Show exception
  ) => LogFormatting (TraceLocalRootPeers PeerTrustable ntnAddr exception) where
  forMachine _dtal (TraceLocalRootDomains groups) =
    mconcat [ "kind" .= String "LocalRootDomains"
             , "localRootDomains" .= toJSON groups
             ]
  forMachine _dtal (TraceLocalRootWaiting d dt) =
    mconcat [ "kind" .= String "LocalRootWaiting"
             , "domainAddress" .= toJSON d
             , "diffTime" .= show dt
             ]
  forMachine _dtal (TraceLocalRootResult d res) =
    mconcat [ "kind" .= String "LocalRootResult"
             , "domainAddress" .= toJSON d
             , "result" .= toJSONList res
             ]
  forMachine _dtal (TraceLocalRootGroups groups) =
    mconcat [ "kind" .= String "LocalRootGroups"
             , "localRootGroups" .= toJSON groups
             ]
  forMachine _dtal (TraceLocalRootFailure d exception) =
    mconcat [ "kind" .= String "LocalRootFailure"
             , "domainAddress" .= toJSON d
             , "reason" .= show exception
             ]
  forMachine _dtal (TraceLocalRootError d exception) =
    mconcat [ "kind" .= String "LocalRootError"
             , "domainAddress" .= toJSON d
             , "reason" .= show exception
             ]
  forMachine _dtal (TraceLocalRootReconfigured d exception) =
    mconcat [ "kind" .= String "LocalRootReconfigured"
             , "domainAddress" .= toJSON d
             , "reason" .= show exception
             ]
  forMachine _dtal (TraceLocalRootDNSMap dnsMap) =
    mconcat
      [ "kind" .= String "TraceLocalRootDNSMap"
      , "dnsMap" .= dnsMap
      ]
  forHuman = pack . show

instance MetaTrace (TraceLocalRootPeers ntnAddr extraFlags exception) where
  namespaceFor = \case
    TraceLocalRootDomains {}      -> Namespace [] ["LocalRootDomains"]
    TraceLocalRootWaiting {}      -> Namespace [] ["LocalRootWaiting"]
    TraceLocalRootResult {}       -> Namespace [] ["LocalRootResult"]
    TraceLocalRootGroups {}       -> Namespace [] ["LocalRootGroups"]
    TraceLocalRootFailure {}      -> Namespace [] ["LocalRootFailure"]
    TraceLocalRootError {}        -> Namespace [] ["LocalRootError"]
    TraceLocalRootReconfigured {} -> Namespace [] ["LocalRootReconfigured"]
    TraceLocalRootDNSMap {}       -> Namespace [] ["LocalRootDNSMap"]

  severityFor (Namespace [] ["LocalRootDomains"]) _ = Just Info
  severityFor (Namespace [] ["LocalRootWaiting"]) _ = Just Info
  severityFor (Namespace [] ["LocalRootResult"]) _ = Just Info
  severityFor (Namespace [] ["LocalRootGroups"]) _ = Just Info
  severityFor (Namespace [] ["LocalRootFailure"]) _ = Just Info
  severityFor (Namespace [] ["LocalRootError"]) _ = Just Info
  severityFor (Namespace [] ["LocalRootReconfigured"]) _ = Just Info
  severityFor (Namespace [] ["LocalRootDNSMap"]) _ = Just Info
  severityFor _ _ = Nothing

  documentFor (Namespace [] ["LocalRootDomains"]) = Just
    ""
  documentFor (Namespace [] ["LocalRootWaiting"]) = Just
    ""
  documentFor (Namespace [] ["LocalRootResult"]) = Just
    ""
  documentFor (Namespace [] ["LocalRootGroups"]) = Just
    ""
  documentFor (Namespace [] ["LocalRootFailure"]) = Just
    ""
  documentFor (Namespace [] ["LocalRootError"]) = Just
    ""
  documentFor (Namespace [] ["LocalRootReconfigured"]) = Just
    ""
  documentFor (Namespace [] ["LocalRootDNSMap"]) = Just
    ""
  documentFor _ = Nothing

  allNamespaces =
    [ Namespace [] ["LocalRootDomains"]
    , Namespace [] ["LocalRootWaiting"]
    , Namespace [] ["LocalRootResult"]
    , Namespace [] ["LocalRootGroups"]
    , Namespace [] ["LocalRootFailure"]
    , Namespace [] ["LocalRootError"]
    , Namespace [] ["LocalRootReconfigured"]
    , Namespace [] ["LocalRootDNSMap"]
    ]

--------------------------------------------------------------------------------
-- PublicRootPeers Tracer
--------------------------------------------------------------------------------

instance LogFormatting TracePublicRootPeers where
  forMachine _dtal (TracePublicRootRelayAccessPoint relays) =
    mconcat [ "kind" .= String "PublicRootRelayAddresses"
             , "relayAddresses" .= toJSON relays
             ]
  forMachine _dtal (TracePublicRootDomains domains) =
    mconcat [ "kind" .= String "PublicRootDomains"
             , "domainAddresses" .= toJSONList domains
             ]
  forMachine _dtal (TracePublicRootResult b res) =
    mconcat [ "kind" .= String "PublicRootResult"
             , "domain" .= show b
             , "result" .= toJSONList res
             ]
  forMachine _dtal (TracePublicRootFailure b d) =
    mconcat [ "kind" .= String "PublicRootFailure"
             , "domain" .= show b
             , "reason" .= show d
             ]
  forHuman = pack . show

instance MetaTrace TracePublicRootPeers where
  namespaceFor TracePublicRootRelayAccessPoint {} = Namespace [] ["PublicRootRelayAccessPoint"]
  namespaceFor TracePublicRootDomains {} = Namespace [] ["PublicRootDomains"]
  namespaceFor TracePublicRootResult {} = Namespace [] ["PublicRootResult"]
  namespaceFor TracePublicRootFailure {} = Namespace [] ["PublicRootFailure"]

  severityFor (Namespace [] ["PublicRootRelayAccessPoint"]) _ = Just Info
  severityFor (Namespace [] ["PublicRootDomains"]) _ = Just Info
  severityFor (Namespace [] ["PublicRootResult"]) _ = Just Info
  severityFor (Namespace [] ["PublicRootFailure"]) _ = Just Info
  severityFor _ _ = Nothing

  documentFor (Namespace [] ["PublicRootRelayAccessPoint"]) = Just
    ""
  documentFor (Namespace [] ["PublicRootDomains"]) = Just
    ""
  documentFor (Namespace [] ["PublicRootResult"]) = Just
    ""
  documentFor (Namespace [] ["PublicRootFailure"]) = Just
    ""
  documentFor _ = Nothing

  allNamespaces = [
      Namespace [] ["PublicRootRelayAccessPoint"]
    , Namespace [] ["PublicRootDomains"]
    , Namespace [] ["PublicRootResult"]
    , Namespace [] ["PublicRootFailure"]
    ]

--------------------------------------------------------------------------------
-- PeerSelection Tracer
--------------------------------------------------------------------------------

instance LogFormatting (TracePeerSelection Cardano.DebugPeerSelectionState PeerTrustable (Cardano.PublicRootPeers.ExtraPeers SockAddr) SockAddr) where
  forMachine _dtal (TraceLocalRootPeersChanged lrp lrp') =
    mconcat [ "kind" .= String "LocalRootPeersChanged"
             , "previous" .= toJSON lrp
             , "current" .= toJSON lrp'
             ]
  forMachine _dtal (TraceTargetsChanged pst pst') =
    mconcat [ "kind" .= String "TargetsChanged"
             , "previous" .= toJSON pst
             , "current" .= toJSON pst'
             ]
  forMachine _dtal (TracePublicRootsRequest tRootPeers nRootPeers) =
    mconcat [ "kind" .= String "PublicRootsRequest"
             , "targetNumberOfRootPeers" .= tRootPeers
             , "numberOfRootPeers" .= nRootPeers
             ]
  forMachine _dtal (TracePublicRootsResults res group dt) =
    mconcat [ "kind" .= String "PublicRootsResults"
             , "result" .= toJSON res
             , "group" .= group
             , "diffTime" .= dt
             ]
  forMachine _dtal (TracePublicRootsFailure err group dt) =
    mconcat [ "kind" .= String "PublicRootsFailure"
             , "reason" .= show err
             , "group" .= group
             , "diffTime" .= dt
             ]
  forMachine _dtal (TraceForgetColdPeers targetKnown actualKnown sp) =
    mconcat [ "kind" .= String "ForgetColdPeers"
             , "targetKnown" .= targetKnown
             , "actualKnown" .= actualKnown
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TraceBigLedgerPeersRequest tRootPeers nRootPeers) =
    mconcat [ "kind" .= String "BigLedgerPeersRequest"
             , "targetNumberOfBigLedgerPeers" .= tRootPeers
             , "numberOfBigLedgerPeers" .= nRootPeers
             ]
  forMachine _dtal (TraceBigLedgerPeersResults res group dt) =
    mconcat [ "kind" .= String "BigLedgerPeersResults"
             , "result" .= toJSONList (toList res)
             , "group" .= group
             , "diffTime" .= dt
             ]
  forMachine _dtal (TraceBigLedgerPeersFailure err group dt) =
    mconcat [ "kind" .= String "BigLedgerPeersFailure"
             , "reason" .= show err
             , "group" .= group
             , "diffTime" .= dt
             ]
  forMachine _dtal (TraceForgetBigLedgerPeers targetKnown actualKnown sp) =
    mconcat [ "kind" .= String "ForgetColdBigLedgerPeers"
             , "targetKnown" .= targetKnown
             , "actualKnown" .= actualKnown
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TracePeerShareRequests targetKnown actualKnown (PeerSharingAmount numRequested) aps sps) =
    mconcat [ "kind" .= String "PeerShareRequests"
             , "targetKnown" .= targetKnown
             , "actualKnown" .= actualKnown
             , "numRequested" .= numRequested
             , "availablePeers" .= toJSONList (toList aps)
             , "selectedPeers" .= toJSONList (toList sps)
             ]
  forMachine _dtal (TracePeerShareResults res) =
    mconcat [ "kind" .= String "PeerShareResults"
             , "result" .= toJSONList (map (first show <$>) res)
             ]
  forMachine _dtal (TracePeerShareResultsFiltered res) =
    mconcat [ "kind" .= String "PeerShareResultsFiltered"
             , "result" .= toJSONList res
             ]
  forMachine _dtal (TracePromoteColdPeers targetKnown actualKnown sp) =
    mconcat [ "kind" .= String "PromoteColdPeers"
             , "targetEstablished" .= targetKnown
             , "actualEstablished" .= actualKnown
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TracePromoteColdLocalPeers tLocalEst sp) =
    mconcat [ "kind" .= String "PromoteColdLocalPeers"
             , "targetLocalEstablished" .= tLocalEst
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TracePromoteColdFailed tEst aEst p d err) =
    mconcat [ "kind" .= String "PromoteColdFailed"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "peer" .= toJSON p
             , "delay" .= toJSON d
             , "reason" .= show err
             ]
  forMachine _dtal (TracePromoteColdDone tEst aEst p) =
    mconcat [ "kind" .= String "PromoteColdDone"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TracePromoteColdBigLedgerPeers targetKnown actualKnown sp) =
    mconcat [ "kind" .= String "PromoteColdBigLedgerPeers"
             , "targetEstablished" .= targetKnown
             , "actualEstablished" .= actualKnown
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TracePromoteColdBigLedgerPeerFailed tEst aEst p d err) =
    mconcat [ "kind" .= String "PromoteColdBigLedgerPeerFailed"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "peer" .= toJSON p
             , "delay" .= toJSON d
             , "reason" .= show err
             ]
  forMachine _dtal (TracePromoteColdBigLedgerPeerDone tEst aEst p) =
    mconcat [ "kind" .= String "PromoteColdBigLedgerPeerDone"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TracePromoteWarmPeers tActive aActive sp) =
    mconcat [ "kind" .= String "PromoteWarmPeers"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TracePromoteWarmLocalPeers taa sp) =
    mconcat [ "kind" .= String "PromoteWarmLocalPeers"
             , "targetActualActive" .= toJSONList taa
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TracePromoteWarmFailed tActive aActive p err) =
    mconcat [ "kind" .= String "PromoteWarmFailed"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             , "reason" .= show err
             ]
  forMachine _dtal (TracePromoteWarmDone tActive aActive p) =
    mconcat [ "kind" .= String "PromoteWarmDone"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TracePromoteWarmAborted tActive aActive p) =
    mconcat [ "kind" .= String "PromoteWarmAborted"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TracePromoteWarmBigLedgerPeers tActive aActive sp) =
    mconcat [ "kind" .= String "PromoteWarmBigLedgerPeers"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TracePromoteWarmBigLedgerPeerFailed tActive aActive p err) =
    mconcat [ "kind" .= String "PromoteWarmBigLedgerPeerFailed"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             , "reason" .= show err
             ]
  forMachine _dtal (TracePromoteWarmBigLedgerPeerDone tActive aActive p) =
    mconcat [ "kind" .= String "PromoteWarmBigLedgerPeerDone"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TracePromoteWarmBigLedgerPeerAborted tActive aActive p) =
    mconcat [ "kind" .= String "PromoteWarmBigLedgerPeerAborted"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TraceDemoteWarmPeers tEst aEst sp) =
    mconcat [ "kind" .= String "DemoteWarmPeers"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TraceDemoteWarmFailed tEst aEst p err) =
    mconcat [ "kind" .= String "DemoteWarmFailed"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "peer" .= toJSON p
             , "reason" .= show err
             ]
  forMachine _dtal (TraceDemoteWarmDone tEst aEst p) =
    mconcat [ "kind" .= String "DemoteWarmDone"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TraceDemoteWarmBigLedgerPeers tEst aEst sp) =
    mconcat [ "kind" .= String "DemoteWarmBigLedgerPeers"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TraceDemoteWarmBigLedgerPeerFailed tEst aEst p err) =
    mconcat [ "kind" .= String "DemoteWarmBigLedgerPeerFailed"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "peer" .= toJSON p
             , "reason" .= show err
             ]
  forMachine _dtal (TraceDemoteWarmBigLedgerPeerDone tEst aEst p) =
    mconcat [ "kind" .= String "DemoteWarmBigLedgerPeerDone"
             , "targetEstablished" .= tEst
             , "actualEstablished" .= aEst
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TraceDemoteHotPeers tActive aActive sp) =
    mconcat [ "kind" .= String "DemoteHotPeers"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TraceDemoteLocalHotPeers taa sp) =
    mconcat [ "kind" .= String "DemoteLocalHotPeers"
             , "targetActualActive" .= toJSONList taa
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TraceDemoteHotFailed tActive aActive p err) =
    mconcat [ "kind" .= String "DemoteHotFailed"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             , "reason" .= show err
             ]
  forMachine _dtal (TraceDemoteHotDone tActive aActive p) =
    mconcat [ "kind" .= String "DemoteHotDone"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TraceDemoteHotBigLedgerPeers tActive aActive sp) =
    mconcat [ "kind" .= String "DemoteHotBigLedgerPeers"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "selectedPeers" .= toJSONList (toList sp)
             ]
  forMachine _dtal (TraceDemoteHotBigLedgerPeerFailed tActive aActive p err) =
    mconcat [ "kind" .= String "DemoteHotBigLedgerPeerFailed"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             , "reason" .= show err
             ]
  forMachine _dtal (TraceDemoteHotBigLedgerPeerDone tActive aActive p) =
    mconcat [ "kind" .= String "DemoteHotBigLedgerPeerDone"
             , "targetActive" .= tActive
             , "actualActive" .= aActive
             , "peer" .= toJSON p
             ]
  forMachine _dtal (TraceDemoteAsynchronous msp) =
    mconcat [ "kind" .= String "DemoteAsynchronous"
             , "state" .= toJSON msp
             ]
  forMachine _dtal (TraceDemoteLocalAsynchronous msp) =
    mconcat [ "kind" .= String "DemoteLocalAsynchronous"
             , "state" .= toJSON msp
             ]
  forMachine _dtal (TraceDemoteBigLedgerPeersAsynchronous msp) =
    mconcat [ "kind" .= String "DemoteBigLedgerPeerAsynchronous"
             , "state" .= toJSON msp
             ]
  forMachine _dtal TraceGovernorWakeup =
    mconcat [ "kind" .= String "GovernorWakeup"
             ]
  forMachine _dtal (TraceChurnWait dt) =
    mconcat [ "kind" .= String "ChurnWait"
             , "diffTime" .= toJSON dt
             ]
  forMachine _dtal (TraceChurnMode c) =
    mconcat [ "kind" .= String "ChurnMode"
             , "event" .= show c ]
  forMachine _dtal (TracePickInboundPeers targetNumberOfKnownPeers numberOfKnownPeers selected available) =
    mconcat [ "kind" .= String "PickInboundPeers"
            , "targetKnown" .= targetNumberOfKnownPeers
            , "actualKnown" .= numberOfKnownPeers
            , "selected" .= selected
            , "available" .= available
            ]
  forMachine _dtal (TraceLedgerStateJudgementChanged new) =
    mconcat [ "kind" .= String "LedgerStateJudgementChanged"
            , "new" .= show new ]
  forMachine _dtal TraceOnlyBootstrapPeers =
    mconcat [ "kind" .= String "LedgerStateJudgementChanged" ]
  forMachine _dtal (TraceUseBootstrapPeersChanged ubp) =
    mconcat [ "kind" .= String "UseBootstrapPeersChanged"
            , "useBootstrapPeers" .= toJSON ubp ]
  forMachine _dtal TraceBootstrapPeersFlagChangedWhilstInSensitiveState =
    mconcat [ "kind" .= String "BootstrapPeersFlagChangedWhilstInSensitiveState"
            ]
  forMachine _dtal (TraceVerifyPeerSnapshot result) =
    mconcat [ "kind" .= String "VerifyPeerSnapshot"
            , "result" .= toJSON result ]
  forMachine _dtal (TraceOutboundGovernorCriticalFailure err) =
    mconcat [ "kind" .= String "OutboundGovernorCriticalFailure"
            , "reason" .= show err
            ]
  forMachine _dtal (TraceChurnAction duration action counter) =
    mconcat [ "kind" .= String "ChurnAction"
            , "action" .= show action
            , "counter" .= counter
            , "duration" .= duration
            ]
  forMachine _dtal (TraceChurnTimeout duration action counter) =
    mconcat [ "kind" .= String "ChurnTimeout"
            , "action" .= show action
            , "counter" .= counter
            , "duration" .= duration
            ]
  forMachine _dtal (TraceDebugState mtime ds) =
    mconcat [ "kind" .= String "DebugState"
            , "monotonicTime" .= show mtime
            , "targets" .= peerSelectionTargetsToObject (dpssTargets ds)
            , "localRootPeers" .= dpssLocalRootPeers ds
            , "publicRootPeers" .= dpssPublicRootPeers ds
            , "knownPeers" .= KnownPeers.allPeers (dpssKnownPeers ds)
            , "establishedPeers" .= dpssEstablishedPeers ds
            , "activePeers" .= dpssActivePeers ds
            , "publicRootBackoffs" .= dpssPublicRootBackoffs ds
            , "publicRootRetryTime" .= dpssPublicRootRetryTime ds
            , "bigLedgerPeerBackoffs" .= dpssBigLedgerPeerBackoffs ds
            , "bigLedgerPeerRetryTime" .= dpssBigLedgerPeerRetryTime ds
            , "inProgressBigLedgerPeersReq" .= dpssInProgressBigLedgerPeersReq ds
            , "inProgressPeerShareReqs" .= dpssInProgressPeerShareReqs ds
            , "inProgressPromoteCold" .= dpssInProgressPromoteCold ds
            , "inProgressPromoteWarm" .= dpssInProgressPromoteWarm ds
            , "inProgressDemoteWarm" .= dpssInProgressDemoteWarm ds
            , "inProgressDemoteHot" .= dpssInProgressDemoteHot ds
            , "inProgressDemoteToCold" .= dpssInProgressDemoteToCold ds
            , "upstreamyness" .= dpssUpstreamyness ds
            , "fetchynessBlocks" .= dpssFetchynessBlocks ds
            ]

  forHuman = pack . show

  asMetrics (TraceChurnAction duration action _) =
    [ DoubleM ("peerSelection.churn" <> pack (show action) <> ".duration")
              (realToFrac duration)
    ]
  asMetrics _ = []

instance MetaTrace (TracePeerSelection extraDebugState extraFlags extraPeers SockAddr) where
    namespaceFor TraceLocalRootPeersChanged {} =
      Namespace [] ["LocalRootPeersChanged"]
    namespaceFor TraceTargetsChanged {}        =
      Namespace [] ["TargetsChanged"]
    namespaceFor TracePublicRootsRequest {}    =
      Namespace [] ["PublicRootsRequest"]
    namespaceFor TracePublicRootsResults {}    =
      Namespace [] ["PublicRootsResults"]
    namespaceFor TracePublicRootsFailure {}    =
      Namespace [] ["PublicRootsFailure"]
    namespaceFor TraceForgetColdPeers {}       =
      Namespace [] ["ForgetColdPeers"]
    namespaceFor TraceBigLedgerPeersRequest {}    =
      Namespace [] ["BigLedgerPeersRequest"]
    namespaceFor TraceBigLedgerPeersResults {}    =
      Namespace [] ["BigLedgerPeersResults"]
    namespaceFor TraceBigLedgerPeersFailure {}    =
      Namespace [] ["BigLedgerPeersFailure"]
    namespaceFor TraceForgetBigLedgerPeers {}       =
      Namespace [] ["ForgetBigLedgerPeers"]
    namespaceFor TracePeerShareRequests {}     =
      Namespace [] ["PeerShareRequests"]
    namespaceFor TracePeerShareResults {}      =
      Namespace [] ["PeerShareResults"]
    namespaceFor TracePeerShareResultsFiltered {} =
      Namespace [] ["PeerShareResultsFiltered"]
    namespaceFor TracePromoteColdPeers {}      =
      Namespace [] ["PromoteColdPeers"]
    namespaceFor TracePromoteColdLocalPeers {} =
      Namespace [] ["PromoteColdLocalPeers"]
    namespaceFor TracePromoteColdFailed {}     =
      Namespace [] ["PromoteColdFailed"]
    namespaceFor TracePromoteColdDone {}       =
      Namespace [] ["PromoteColdDone"]
    namespaceFor TracePromoteColdBigLedgerPeers {}      =
      Namespace [] ["PromoteColdBigLedgerPeers"]
    namespaceFor TracePromoteColdBigLedgerPeerFailed {}     =
      Namespace [] ["PromoteColdBigLedgerPeerFailed"]
    namespaceFor TracePromoteColdBigLedgerPeerDone {}       =
      Namespace [] ["PromoteColdBigLedgerPeerDone"]
    namespaceFor TracePromoteWarmPeers {}      =
      Namespace [] ["PromoteWarmPeers"]
    namespaceFor TracePromoteWarmLocalPeers {} =
      Namespace [] ["PromoteWarmLocalPeers"]
    namespaceFor TracePromoteWarmFailed {}     =
      Namespace [] ["PromoteWarmFailed"]
    namespaceFor TracePromoteWarmDone {}       =
      Namespace [] ["PromoteWarmDone"]
    namespaceFor TracePromoteWarmAborted {}    =
      Namespace [] ["PromoteWarmAborted"]
    namespaceFor TracePromoteWarmBigLedgerPeers {}      =
      Namespace [] ["PromoteWarmBigLedgerPeers"]
    namespaceFor TracePromoteWarmBigLedgerPeerFailed {}     =
      Namespace [] ["PromoteWarmBigLedgerPeerFailed"]
    namespaceFor TracePromoteWarmBigLedgerPeerDone {}       =
      Namespace [] ["PromoteWarmBigLedgerPeerDone"]
    namespaceFor TracePromoteWarmBigLedgerPeerAborted {}    =
      Namespace [] ["PromoteWarmBigLedgerPeerAborted"]
    namespaceFor TraceDemoteWarmPeers {}       =
      Namespace [] ["DemoteWarmPeers"]
    namespaceFor (TraceDemoteWarmFailed _ _ _ e) =
      case fromException e :: Maybe DemotionTimeoutException of
        Just _  -> Namespace [] ["DemoteWarmFailed", "CoolingToColdTimeout"]
        Nothing -> Namespace [] ["DemoteWarmFailed"]
    namespaceFor TraceDemoteWarmDone {}        =
      Namespace [] ["DemoteWarmDone"]
    namespaceFor TraceDemoteWarmBigLedgerPeers {}       =
      Namespace [] ["DemoteWarmBigLedgerPeers"]
    namespaceFor (TraceDemoteWarmBigLedgerPeerFailed _ _ _ e) =
      case fromException e :: Maybe DemotionTimeoutException of
        Just _  -> Namespace [] ["DemoteWarmBigLedgerPeerFailed", "CoolingToColdTimeout"]
        Nothing -> Namespace [] ["DemoteWarmBigLedgerPeerFailed"]
    namespaceFor TraceDemoteWarmBigLedgerPeerDone {}        =
      Namespace [] ["DemoteWarmBigLedgerPeerDone"]
    namespaceFor TraceDemoteHotPeers {}        =
      Namespace [] ["DemoteHotPeers"]
    namespaceFor TraceDemoteLocalHotPeers {}   =
      Namespace [] ["DemoteLocalHotPeers"]
    namespaceFor (TraceDemoteHotFailed _ _ _ e)  =
      case fromException e :: Maybe DemotionTimeoutException of
        Just _  -> Namespace [] ["DemoteHotFailed", "CoolingToColdTimeout"]
        Nothing -> Namespace [] ["DemoteHotFailed"]
    namespaceFor TraceDemoteHotDone {}         =
      Namespace [] ["DemoteHotDone"]
    namespaceFor TraceDemoteHotBigLedgerPeers {}        =
      Namespace [] ["DemoteHotBigLedgerPeers"]
    namespaceFor (TraceDemoteHotBigLedgerPeerFailed _ _ _ e)  =
      case fromException e :: Maybe DemotionTimeoutException of
        Just _  -> Namespace [] ["DemoteHotBigLedgerPeerFailed", "CoolingToColdTimeout"]
        Nothing -> Namespace [] ["DemoteHotBigLedgerPeerFailed"]
    namespaceFor TraceDemoteHotBigLedgerPeerDone {}         =
      Namespace [] ["DemoteHotBigLedgerPeerDone"]
    namespaceFor TraceDemoteAsynchronous {}    =
      Namespace [] ["DemoteAsynchronous"]
    namespaceFor TraceDemoteLocalAsynchronous {} =
      Namespace [] ["DemoteLocalAsynchronous"]
    namespaceFor TraceDemoteBigLedgerPeersAsynchronous {} =
      Namespace [] ["DemoteBigLedgerPeersAsynchronous"]
    namespaceFor TraceGovernorWakeup {}        =
      Namespace [] ["GovernorWakeup"]
    namespaceFor TraceChurnWait {}             =
      Namespace [] ["ChurnWait"]
    namespaceFor TraceChurnMode {}             =
      Namespace [] ["ChurnMode"]
    namespaceFor TracePickInboundPeers {} =
      Namespace [] ["PickInboundPeers"]
    namespaceFor TraceLedgerStateJudgementChanged {} =
      Namespace [] ["LedgerStateJudgementChanged"]
    namespaceFor TraceOnlyBootstrapPeers {} =
      Namespace [] ["OnlyBootstrapPeers"]
    namespaceFor TraceUseBootstrapPeersChanged {} =
      Namespace [] ["UseBootstrapPeersChanged"]
    namespaceFor TraceVerifyPeerSnapshot {} =
      Namespace [] ["VerifyPeerSnapshot"]
    namespaceFor TraceBootstrapPeersFlagChangedWhilstInSensitiveState =
      Namespace [] ["BootstrapPeersFlagChangedWhilstInSensitiveState"]
    namespaceFor TraceOutboundGovernorCriticalFailure {} =
      Namespace [] ["OutboundGovernorCriticalFailure"]
    namespaceFor TraceChurnAction {} =
      Namespace [] ["ChurnAction"]
    namespaceFor TraceChurnTimeout {} =
      Namespace [] ["ChurnTimeout"]
    namespaceFor TraceDebugState {} =
      Namespace [] ["DebugState"]

    severityFor (Namespace [] ["LocalRootPeersChanged"]) _ = Just Notice
    severityFor (Namespace [] ["TargetsChanged"]) _ = Just Notice
    severityFor (Namespace [] ["PublicRootsRequest"]) _ = Just Info
    severityFor (Namespace [] ["PublicRootsResults"]) _ = Just Info
    severityFor (Namespace [] ["PublicRootsFailure"]) _ = Just Error
    severityFor (Namespace [] ["ForgetColdPeers"]) _ = Just Info
    severityFor (Namespace [] ["BigLedgerPeersRequest"]) _ = Just Info
    severityFor (Namespace [] ["BigLedgerPeersResults"]) _ = Just Info
    severityFor (Namespace [] ["BigLedgerPeersFailure"]) _ = Just Info
    severityFor (Namespace [] ["ForgetBigLedgerPeers"]) _ = Just Info
    severityFor (Namespace [] ["PeerShareRequests"]) _ = Just Debug
    severityFor (Namespace [] ["PeerShareResults"]) _ = Just Debug
    severityFor (Namespace [] ["PeerShareResultsFiltered"]) _ = Just Info
    severityFor (Namespace [] ["PromoteColdPeers"]) _ = Just Info
    severityFor (Namespace [] ["PromoteColdLocalPeers"]) _ = Just Info
    severityFor (Namespace [] ["PromoteColdFailed"]) _ = Just Info
    severityFor (Namespace [] ["PromoteColdDone"]) _ = Just Info
    severityFor (Namespace [] ["PromoteColdBigLedgerPeers"]) _ = Just Info
    severityFor (Namespace [] ["PromoteColdBigLedgerPeerFailed"]) _ = Just Info
    severityFor (Namespace [] ["PromoteColdBigLedgerPeerDone"]) _ = Just Info
    severityFor (Namespace [] ["PromoteWarmPeers"]) _ = Just Info
    severityFor (Namespace [] ["PromoteWarmLocalPeers"]) _ = Just Info
    severityFor (Namespace [] ["PromoteWarmFailed"]) _ = Just Info
    severityFor (Namespace [] ["PromoteWarmDone"]) _ = Just Info
    severityFor (Namespace [] ["PromoteWarmAborted"]) _ = Just Info
    severityFor (Namespace [] ["PromoteWarmBigLedgerPeers"]) _ = Just Info
    severityFor (Namespace [] ["PromoteWarmBigLedgerPeerFailed"]) _ = Just Info
    severityFor (Namespace [] ["PromoteWarmBigLedgerPeerDone"]) _ = Just Info
    severityFor (Namespace [] ["PromoteWarmBigLedgerPeerAborted"]) _ = Just Info
    severityFor (Namespace [] ["DemoteWarmPeers"]) _ = Just Info
    severityFor (Namespace [] ["DemoteWarmFailed"]) _ = Just Info
    severityFor (Namespace [] ["DemoteWarmFailed", "CoolingToColdTimeout"]) _ = Just Error
    severityFor (Namespace [] ["DemoteWarmDone"]) _ = Just Info
    severityFor (Namespace [] ["DemoteWarmBigLedgerPeers"]) _ = Just Info
    severityFor (Namespace [] ["DemoteWarmBigLedgerPeerFailed"]) _ = Just Info
    severityFor (Namespace [] ["DemoteWarmBigLedgerPeerFailed", "CoolingToColdTimeout"]) _ = Just Error
    severityFor (Namespace [] ["DemoteWarmBigLedgerPeerDone"]) _ = Just Info
    severityFor (Namespace [] ["DemoteHotPeers"]) _ = Just Info
    severityFor (Namespace [] ["DemoteLocalHotPeers"]) _ = Just Info
    severityFor (Namespace [] ["DemoteHotFailed"]) _ = Just Info
    severityFor (Namespace [] ["DemoteHotFailed", "CoolingToColdTimeout"]) _ = Just Error
    severityFor (Namespace [] ["DemoteHotDone"]) _ = Just Info
    severityFor (Namespace [] ["DemoteHotBigLedgerPeers"]) _ = Just Info
    severityFor (Namespace [] ["DemoteHotBigLedgerPeerFailed"]) _ = Just Info
    severityFor (Namespace [] ["DemoteHotBigLedgerPeerFailed", "CoolingToColdTimeout"]) _ = Just Error
    severityFor (Namespace [] ["DemoteHotBigLedgerPeerDone"]) _ = Just Info
    severityFor (Namespace [] ["DemoteAsynchronous"]) _ = Just Info
    severityFor (Namespace [] ["DemoteLocalAsynchronous"]) _ = Just Warning
    severityFor (Namespace [] ["DemoteBigLedgerPeersAsynchronous"]) _ = Just Info
    severityFor (Namespace [] ["GovernorWakeup"]) _ = Just Info
    severityFor (Namespace [] ["ChurnWait"]) _ = Just Info
    severityFor (Namespace [] ["ChurnMode"]) _ = Just Info
    severityFor (Namespace [] ["PickInboundPeers"]) _ = Just Info
    severityFor (Namespace [] ["LedgerStateJudgementChanged"]) _ = Just Info
    severityFor (Namespace [] ["OnlyBootstrapPeers"]) _ = Just Info
    severityFor (Namespace [] ["UseBootstrapPeersChanged"]) _ = Just Notice
    severityFor (Namespace [] ["VerifyPeerSnapshot"]) _ = Just Error
    severityFor (Namespace [] ["BootstrapPeersFlagChangedWhilstInSensitiveState"]) _ = Just Warning
    severityFor (Namespace [] ["OutboundGovernorCriticalFailure"]) _ = Just Error
    severityFor (Namespace [] ["ChurnAction"]) _ = Just Info
    severityFor (Namespace [] ["ChurnTimeout"]) _ = Just Notice
    severityFor (Namespace [] ["DebugState"]) _ = Just Info
    severityFor _ _ = Nothing

    documentFor (Namespace [] ["LocalRootPeersChanged"]) = Just  ""
    documentFor (Namespace [] ["TargetsChanged"]) = Just  ""
    documentFor (Namespace [] ["PublicRootsRequest"]) = Just  ""
    documentFor (Namespace [] ["PublicRootsResults"]) = Just  ""
    documentFor (Namespace [] ["PublicRootsFailure"]) = Just  ""
    documentFor (Namespace [] ["PeerShareRequests"]) = Just $ mconcat
      [ "target known peers, actual known peers, peers available for gossip,"
      , " peers selected for gossip"
      ]
    documentFor (Namespace [] ["PeerShareResults"]) = Just  ""
    documentFor (Namespace [] ["ForgetColdPeers"]) = Just
      "target known peers, actual known peers, selected peers"
    documentFor (Namespace [] ["PromoteColdPeers"]) = Just
      "target established, actual established, selected peers"
    documentFor (Namespace [] ["PromoteColdLocalPeers"]) = Just
      "target local established, actual local established, selected peers"
    documentFor (Namespace [] ["PromoteColdFailed"]) = Just $ mconcat
      [ "target established, actual established, peer, delay until next"
      , " promotion, reason"
      ]
    documentFor (Namespace [] ["PromoteColdDone"]) = Just
      "target active, actual active, selected peers"
    documentFor (Namespace [] ["PromoteWarmPeers"]) = Just
      "target active, actual active, selected peers"
    documentFor (Namespace [] ["PromoteWarmLocalPeers"]) = Just
      "local per-group (target active, actual active), selected peers"
    documentFor (Namespace [] ["PromoteWarmFailed"]) = Just
      "target active, actual active, peer, reason"
    documentFor (Namespace [] ["PromoteWarmDone"]) = Just
      "target active, actual active, peer"
    documentFor (Namespace [] ["PromoteWarmAborted"]) = Just ""
    documentFor (Namespace [] ["DemoteWarmPeers"]) = Just
      "target established, actual established, selected peers"
    documentFor (Namespace [] ["DemoteWarmFailed"]) = Just
      "target established, actual established, peer, reason"
    documentFor (Namespace [] ["DemoteWarmFailed", "CoolingToColdTimeout"]) =
      Just "Impossible asynchronous demotion timeout"
    documentFor (Namespace [] ["DemoteWarmBigLedgerPeerFailed", "CoolingToColdTimeout"]) =
      Just "Impossible asynchronous demotion timeout"
    documentFor (Namespace [] ["DemoteWarmDone"]) = Just
      "target established, actual established, peer"
    documentFor (Namespace [] ["DemoteHotPeers"]) = Just
      "target active, actual active, selected peers"
    documentFor (Namespace [] ["DemoteLocalHotPeers"]) = Just
      "local per-group (target active, actual active), selected peers"
    documentFor (Namespace [] ["DemoteHotFailed"]) = Just
      "target active, actual active, peer, reason"
    documentFor (Namespace [] ["DemoteHotFailed", "CoolingToColdTimeout"]) =
      Just "Impossible asynchronous demotion timeout"
    documentFor (Namespace [] ["DemoteHotBigLedgerPeerFailed", "CoolingToColdTimeout"]) =
      Just "Impossible asynchronous demotion timeout"
    documentFor (Namespace [] ["DemoteHotDone"]) = Just
      "target active, actual active, peer"
    documentFor (Namespace [] ["DemoteAsynchronous"]) = Just  ""
    documentFor (Namespace [] ["DemoteLocalAsynchronous"]) = Just  ""
    documentFor (Namespace [] ["GovernorWakeup"]) = Just  ""
    documentFor (Namespace [] ["ChurnWait"]) = Just  ""
    documentFor (Namespace [] ["ChurnMode"]) = Just  ""
    documentFor (Namespace [] ["PickInboundPeers"]) = Just
      "An inbound connection was added to known set of outbound governor"
    documentFor (Namespace [] ["OutboundGovernorCriticalFailure"]) = Just
      "Outbound Governor was killed unexpectedly"
    documentFor (Namespace [] ["DebugState"]) = Just
      "peer selection internal state"
    documentFor (Namespace [] ["VerifyPeerSnapshot"]) = Just
      "Verification outcome of big ledger peer snapshot"
    documentFor _ = Nothing

    metricsDocFor (Namespace [] ["ChurnAction"]) =
     [ ("peerSelection.churn.DecreasedActivePeers.duration", "")
     , ("peerSelection.churn.DecreasedActiveBigLedgerPeers.duration", "")
     , ("peerSelection.churn.DecreasedEstablishedPeers.duration", "")
     , ("peerSelection.churn.DecreasedEstablishedBigLedgerPeers.duration", "")
     , ("peerSelection.churn.DecreasedKnownPeers.duration", "")
     , ("peerSelection.churn.DecreasedKnownBigLedgerPeers.duration", "")
     ]
    metricsDocFor _ = []

    allNamespaces = [
        Namespace [] ["LocalRootPeersChanged"]
      , Namespace [] ["TargetsChanged"]
      , Namespace [] ["PublicRootsRequest"]
      , Namespace [] ["PublicRootsResults"]
      , Namespace [] ["PublicRootsFailure"]
      , Namespace [] ["ForgetColdPeers"]
      , Namespace [] ["BigLedgerPeersRequest"]
      , Namespace [] ["BigLedgerPeersResults"]
      , Namespace [] ["BigLedgerPeersFailure"]
      , Namespace [] ["ForgetBigLedgerPeers"]
      , Namespace [] ["PeerShareRequests"]
      , Namespace [] ["PeerShareResults"]
      , Namespace [] ["PeerShareResultsFiltered"]
      , Namespace [] ["PromoteColdPeers"]
      , Namespace [] ["PromoteColdLocalPeers"]
      , Namespace [] ["PromoteColdFailed"]
      , Namespace [] ["PromoteColdDone"]
      , Namespace [] ["PromoteColdBigLedgerPeers"]
      , Namespace [] ["PromoteColdBigLedgerPeerFailed"]
      , Namespace [] ["PromoteColdBigLedgerPeerDone"]
      , Namespace [] ["PromoteWarmPeers"]
      , Namespace [] ["PromoteWarmLocalPeers"]
      , Namespace [] ["PromoteWarmFailed"]
      , Namespace [] ["PromoteWarmDone"]
      , Namespace [] ["PromoteWarmAborted"]
      , Namespace [] ["PromoteWarmBigLedgerPeers"]
      , Namespace [] ["PromoteWarmBigLedgerPeerFailed"]
      , Namespace [] ["PromoteWarmBigLedgerPeerDone"]
      , Namespace [] ["PromoteWarmBigLedgerPeerAborted"]
      , Namespace [] ["DemoteWarmPeers"]
      , Namespace [] ["DemoteWarmFailed"]
      , Namespace [] ["DemoteWarmFailed", "CoolingToColdTimeout"]
      , Namespace [] ["DemoteWarmDone"]
      , Namespace [] ["DemoteWarmBigLedgerPeers"]
      , Namespace [] ["DemoteWarmBigLedgerPeerFailed"]
      , Namespace [] ["DemoteWarmBigLedgerPeerFailed", "CoolingToColdTimeout"]
      , Namespace [] ["DemoteWarmBigLedgerPeerDone"]
      , Namespace [] ["DemoteHotPeers"]
      , Namespace [] ["DemoteLocalHotPeers"]
      , Namespace [] ["DemoteHotFailed"]
      , Namespace [] ["DemoteHotFailed", "CoolingToColdTimeout"]
      , Namespace [] ["DemoteHotDone"]
      , Namespace [] ["DemoteHotBigLedgerPeers"]
      , Namespace [] ["DemoteHotBigLedgerPeerFailed"]
      , Namespace [] ["DemoteHotBigLedgerPeerFailed", "CoolingToColdTimeout"]
      , Namespace [] ["DemoteHotBigLedgerPeerDone"]
      , Namespace [] ["DemoteAsynchronous"]
      , Namespace [] ["DemoteLocalAsynchronous"]
      , Namespace [] ["DemoteBigLedgerPeersAsynchronous"]
      , Namespace [] ["GovernorWakeup"]
      , Namespace [] ["ChurnWait"]
      , Namespace [] ["ChurnMode"]
      , Namespace [] ["PickInboundPeers"]
      , Namespace [] ["LedgerStateJudgementChanged"]
      , Namespace [] ["OnlyBootstrapPeers"]
      , Namespace [] ["UseBootstrapPeersChanged"]
      , Namespace [] ["VerifyPeerSnapshot"]
      , Namespace [] ["BootstrapPeersFlagChangedWhilstInSensitiveState"]
      , Namespace [] ["OutboundGovernorCriticalFailure"]
      , Namespace [] ["ChurnAction"]
      , Namespace [] ["ChurnTimeout"]
      , Namespace [] ["DebugState"]
      ]

--------------------------------------------------------------------------------
-- DebugPeerSelection Tracer
--------------------------------------------------------------------------------

instance LogFormatting (DebugPeerSelection Cardano.ExtraState PeerTrustable (Cardano.PublicRootPeers.ExtraPeers SockAddr) SockAddr) where
  forMachine dtal@DNormal (TraceGovernorState blockedAt wakeupAfter
                   st@PeerSelectionState { targets }) =
    mconcat [ "kind" .= String "DebugPeerSelection"
             , "blockedAt" .= String (pack $ show blockedAt)
             , "wakeupAfter" .= String (pack $ show wakeupAfter)
             , "targets" .= peerSelectionTargetsToObject targets
             , "counters" .= forMachine dtal (peerSelectionStateToCounters Cardano.PublicRootPeers.toSet Cardano.cardanoPeerSelectionStatetoCounters st)
             ]
  forMachine _ (TraceGovernorState blockedAt wakeupAfter ev) =
    mconcat [ "kind" .= String "DebugPeerSelection"
             , "blockedAt" .= String (pack $ show blockedAt)
             , "wakeupAfter" .= String (pack $ show wakeupAfter)
             , "peerSelectionState" .= String (pack $ show ev)
             ]
  forHuman = pack . show

peerSelectionTargetsToObject :: PeerSelectionTargets -> Value
peerSelectionTargetsToObject
  PeerSelectionTargets { targetNumberOfRootPeers,
                         targetNumberOfKnownPeers,
                         targetNumberOfEstablishedPeers,
                         targetNumberOfActivePeers,
                         targetNumberOfKnownBigLedgerPeers,
                         targetNumberOfEstablishedBigLedgerPeers,
                         targetNumberOfActiveBigLedgerPeers
                       } =
    Object $
      mconcat [ "roots" .= targetNumberOfRootPeers
               , "knownPeers" .= targetNumberOfKnownPeers
               , "established" .= targetNumberOfEstablishedPeers
               , "active" .= targetNumberOfActivePeers
               , "knownBigLedgerPeers" .= targetNumberOfKnownBigLedgerPeers
               , "establishedBigLedgerPeers" .= targetNumberOfEstablishedBigLedgerPeers
               , "activeBigLedgerPeers" .= targetNumberOfActiveBigLedgerPeers
               ]

instance MetaTrace (DebugPeerSelection extraState extraFlags extraPeers SockAddr) where
    namespaceFor TraceGovernorState {} = Namespace [] ["GovernorState"]

    severityFor (Namespace _ ["GovernorState"]) _ = Just Debug
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["GovernorState"]) = Just ""
    documentFor _ = Nothing

    allNamespaces = [
      Namespace [] ["GovernorState"]
      ]


--------------------------------------------------------------------------------
-- PeerSelectionCounters
--------------------------------------------------------------------------------

instance LogFormatting (PeerSelectionCounters (Cardano.ExtraPeerSelectionSetsWithSizes addr)) where
  forMachine _dtal PeerSelectionCounters {..} =
    mconcat [ "kind" .= String "PeerSelectionCounters"

            , "knownPeers" .= numberOfKnownPeers
            , "rootPeers" .= numberOfRootPeers
            , "coldPeersPromotions" .= numberOfColdPeersPromotions
            , "establishedPeers" .= numberOfEstablishedPeers
            , "warmPeersDemotions" .= numberOfWarmPeersDemotions
            , "warmPeersPromotions" .= numberOfWarmPeersPromotions
            , "activePeers" .= numberOfActivePeers
            , "activePeersDemotions" .= numberOfActivePeersDemotions

            , "knownBigLedgerPeers" .= numberOfKnownBigLedgerPeers
            , "coldBigLedgerPeersPromotions" .= numberOfColdBigLedgerPeersPromotions
            , "establishedBigLedgerPeers" .= numberOfEstablishedBigLedgerPeers
            , "warmBigLedgerPeersDemotions" .= numberOfWarmBigLedgerPeersDemotions
            , "warmBigLedgerPeersPromotions" .= numberOfWarmBigLedgerPeersPromotions
            , "activeBigLedgerPeers" .= numberOfActiveBigLedgerPeers
            , "activeBigLedgerPeersDemotions" .= numberOfActiveBigLedgerPeersDemotions

            , "knownLocalRootPeers" .= numberOfKnownLocalRootPeers
            , "establishedLocalRootPeers" .= numberOfEstablishedLocalRootPeers
            , "warmLocalRootPeersPromotions" .= numberOfWarmLocalRootPeersPromotions
            , "activeLocalRootPeers" .= numberOfActiveLocalRootPeers
            , "activeLocalRootPeersDemotions" .= numberOfActiveLocalRootPeersDemotions

            , "knownNonRootPeers" .= numberOfKnownNonRootPeers
            , "coldNonRootPeersPromotions" .= numberOfColdNonRootPeersPromotions
            , "establishedNonRootPeers" .= numberOfEstablishedNonRootPeers
            , "warmNonRootPeersDemotions" .= numberOfWarmNonRootPeersDemotions
            , "warmNonRootPeersPromotions" .= numberOfWarmNonRootPeersPromotions
            , "activeNonRootPeers" .= numberOfActiveNonRootPeers
            , "activeNonRootPeersDemotions" .= numberOfActiveNonRootPeersDemotions

            , "knownBootstrapPeers" .= snd (Cardano.viewKnownBootstrapPeers extraCounters)
            , "coldBootstrapPeersPromotions" .= snd (Cardano.viewColdBootstrapPeersPromotions extraCounters)
            , "establishedBootstrapPeers" .= snd (Cardano.viewEstablishedBootstrapPeers extraCounters)
            , "warmBootstrapPeersDemotions" .= snd (Cardano.viewWarmBootstrapPeersDemotions extraCounters)
            , "warmBootstrapPeersPromotions" .= snd (Cardano.viewWarmBootstrapPeersPromotions extraCounters)
            , "activeBootstrapPeers" .= snd (Cardano.viewActiveBootstrapPeers extraCounters)
            , "ActiveBootstrapPeersDemotions" .= snd (Cardano.viewActiveBootstrapPeersDemotions extraCounters)
            ]
  forHuman = forHumanFromMachine
  asMetrics psc =
    case psc of
      PeerSelectionCountersHWC {..} ->
        -- Deprecated metrics; they will be removed in a future version.
        [ IntM
            "peerSelection.Cold"
            (fromIntegral numberOfColdPeers)
        , IntM
            "peerSelection.Warm"
            (fromIntegral numberOfWarmPeers)
        , IntM
            "peerSelection.Hot"
            (fromIntegral numberOfHotPeers)
        , IntM
            "peerSelection.ColdBigLedgerPeers"
            (fromIntegral numberOfColdBigLedgerPeers)
        , IntM
            "peerSelection.WarmBigLedgerPeers"
            (fromIntegral numberOfWarmBigLedgerPeers)
        , IntM
            "peerSelection.HotBigLedgerPeers"
            (fromIntegral numberOfHotBigLedgerPeers)

        , IntM
            "peerSelection.WarmLocalRoots"
            (fromIntegral $ numberOfActiveLocalRootPeers psc)
        , IntM
            "peerSelection.HotLocalRoots"
            (fromIntegral $ numberOfEstablishedLocalRootPeers psc
                          - numberOfActiveLocalRootPeers psc)
        ]
    ++
    case psc of
      PeerSelectionCounters {..} ->
        [ IntM "peerSelection.RootPeers" (fromIntegral numberOfRootPeers)

        , IntM "peerSelection.KnownPeers" (fromIntegral numberOfKnownPeers)
        , IntM "peerSelection.ColdPeersPromotions" (fromIntegral numberOfColdPeersPromotions)
        , IntM "peerSelection.EstablishedPeers" (fromIntegral numberOfEstablishedPeers)
        , IntM "peerSelection.WarmPeersDemotions" (fromIntegral numberOfWarmPeersDemotions)
        , IntM "peerSelection.WarmPeersPromotions" (fromIntegral numberOfWarmPeersPromotions)
        , IntM "peerSelection.ActivePeers" (fromIntegral numberOfActivePeers)
        , IntM "peerSelection.ActivePeersDemotions" (fromIntegral numberOfActivePeersDemotions)

        , IntM "peerSelection.KnownBigLedgerPeers" (fromIntegral numberOfKnownBigLedgerPeers)
        , IntM "peerSelection.ColdBigLedgerPeersPromotions" (fromIntegral numberOfColdBigLedgerPeersPromotions)
        , IntM "peerSelection.EstablishedBigLedgerPeers" (fromIntegral numberOfEstablishedBigLedgerPeers)
        , IntM "peerSelection.WarmBigLedgerPeersDemotions" (fromIntegral numberOfWarmBigLedgerPeersDemotions)
        , IntM "peerSelection.WarmBigLedgerPeersPromotions" (fromIntegral numberOfWarmBigLedgerPeersPromotions)
        , IntM "peerSelection.ActiveBigLedgerPeers" (fromIntegral numberOfActiveBigLedgerPeers)
        , IntM "peerSelection.ActiveBigLedgerPeersDemotions" (fromIntegral numberOfActiveBigLedgerPeersDemotions)

        , IntM "peerSelection.KnownLocalRootPeers" (fromIntegral numberOfKnownLocalRootPeers)
        , IntM "peerSelection.EstablishedLocalRootPeers" (fromIntegral numberOfEstablishedLocalRootPeers)
        , IntM "peerSelection.WarmLocalRootPeersPromotions" (fromIntegral numberOfWarmLocalRootPeersPromotions)
        , IntM "peerSelection.ActiveLocalRootPeers" (fromIntegral numberOfActiveLocalRootPeers)
        , IntM "peerSelection.ActiveLocalRootPeersDemotions" (fromIntegral numberOfActiveLocalRootPeersDemotions)


        , IntM "peerSelection.KnownNonRootPeers" (fromIntegral numberOfKnownNonRootPeers)
        , IntM "peerSelection.ColdNonRootPeersPromotions" (fromIntegral numberOfColdNonRootPeersPromotions)
        , IntM "peerSelection.EstablishedNonRootPeers" (fromIntegral numberOfEstablishedNonRootPeers)
        , IntM "peerSelection.WarmNonRootPeersDemotions" (fromIntegral numberOfWarmNonRootPeersDemotions)
        , IntM "peerSelection.WarmNonRootPeersPromotions" (fromIntegral numberOfWarmNonRootPeersPromotions)
        , IntM "peerSelection.ActiveNonRootPeers" (fromIntegral numberOfActiveNonRootPeers)
        , IntM "peerSelection.ActiveNonRootPeersDemotions" (fromIntegral numberOfActiveNonRootPeersDemotions)

        , IntM "peerSelection.KnownBootstrapPeers" (fromIntegral $ snd $ Cardano.viewKnownBootstrapPeers extraCounters)
        , IntM "peerSelection.ColdBootstrapPeersPromotions" (fromIntegral $ snd $ Cardano.viewColdBootstrapPeersPromotions extraCounters)
        , IntM "peerSelection.EstablishedBootstrapPeers" (fromIntegral $ snd $ Cardano.viewEstablishedBootstrapPeers extraCounters)
        , IntM "peerSelection.WarmBootstrapPeersDemotions" (fromIntegral $ snd $ Cardano.viewWarmBootstrapPeersDemotions extraCounters)
        , IntM "peerSelection.WarmBootstrapPeersPromotions" (fromIntegral $ snd $ Cardano.viewWarmBootstrapPeersPromotions extraCounters)
        , IntM "peerSelection.ActiveBootstrapPeers" (fromIntegral $ snd $ Cardano.viewActiveBootstrapPeers extraCounters)
        , IntM "peerSelection.ActiveBootstrapPeersDemotions" (fromIntegral $ snd $ Cardano.viewActiveBootstrapPeersDemotions extraCounters)
        ]

instance MetaTrace (PeerSelectionCounters extraCounters) where
    namespaceFor PeerSelectionCounters {} = Namespace [] ["Counters"]

    severityFor (Namespace _ ["Counters"]) _ = Just Debug
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["Counters"]) = Just
      "Counters of selected peers"
    documentFor _ = Nothing

    metricsDocFor (Namespace _ ["Counters"]) =
     [ ("peerSelection.Cold", "Number of cold peers")
     , ("peerSelection.Warm", "Number of warm peers")
     , ("peerSelection.Hot", "Number of hot peers")
     , ("peerSelection.ColdBigLedgerPeers", "Number of cold big ledger peers")
     , ("peerSelection.WarmBigLedgerPeers", "Number of warm big ledger peers")
     , ("peerSelection.HotBigLedgerPeers", "Number of hot big ledger peers")
     , ("peerSelection.LocalRoots", "Numbers of warm & hot local roots")

     , ("peerSelection.RootPeers", "Number of root peers")
      , ("peerSelection.KnownPeers", "Number of known peers")
      , ("peerSelection.ColdPeersPromotions", "Number of cold peers promotions")
      , ("peerSelection.EstablishedPeers", "Number of established peers")
      , ("peerSelection.WarmPeersDemotions", "Number of warm peers demotions")
      , ("peerSelection.WarmPeersPromotions", "Number of warm peers promotions")
      , ("peerSelection.ActivePeers", "Number of active peers")
      , ("peerSelection.ActivePeersDemotions", "Number of active peers demotions")

      , ("peerSelection.KnownBigLedgerPeers", "Number of known big ledger peers")
      , ("peerSelection.ColdBigLedgerPeersPromotions", "Number of cold big ledger peers promotions")
      , ("peerSelection.EstablishedBigLedgerPeers", "Number of established big ledger peers")
      , ("peerSelection.WarmBigLedgerPeersDemotions", "Number of warm big ledger peers demotions")
      , ("peerSelection.WarmBigLedgerPeersPromotions", "Number of warm big ledger peers promotions")
      , ("peerSelection.ActiveBigLedgerPeers", "Number of active big ledger peers")
      , ("peerSelection.ActiveBigLedgerPeersDemotions", "Number of active big ledger peers demotions")

      , ("peerSelection.KnownLocalRootPeers", "Number of known local root peers")
      , ("peerSelection.EstablishedLocalRootPeers", "Number of established local root peers")
      , ("peerSelection.WarmLocalRootPeersPromotions", "Number of warm local root peers promotions")
      , ("peerSelection.ActiveLocalRootPeers", "Number of active local root peers")
      , ("peerSelection.ActiveLocalRootPeersDemotions", "Number of active local root peers demotions")

      , ("peerSelection.KnownNonRootPeers", "Number of known non root peers")
      , ("peerSelection.ColdNonRootPeersPromotions", "Number of cold non root peers promotions")
      , ("peerSelection.EstablishedNonRootPeers", "Number of established non root peers")
      , ("peerSelection.WarmNonRootPeersDemotions", "Number of warm non root peers demotions")
      , ("peerSelection.WarmNonRootPeersPromotions", "Number of warm non root peers promotions")
      , ("peerSelection.ActiveNonRootPeers", "Number of active non root peers")
      , ("peerSelection.ActiveNonRootPeersDemotions", "Number of active non root peers demotions")

      , ("peerSelection.KnownBootstrapPeers", "Number of known bootstrap peers")
      , ("peerSelection.ColdBootstrapPeersPromotions", "Number of cold bootstrap peers promotions")
      , ("peerSelection.EstablishedBootstrapPeers", "Number of established bootstrap peers")
      , ("peerSelection.WarmBootstrapPeersDemotions", "Number of warm bootstrap peers demotions")
      , ("peerSelection.WarmBootstrapPeersPromotions", "Number of warm bootstrap peers promotions")
      , ("peerSelection.ActiveBootstrapPeers", "Number of active bootstrap peers")
      , ("peerSelection.ActiveBootstrapPeersDemotions", "Number of active bootstrap peers demotions")

     ]
    metricsDocFor _ = []

    allNamespaces =[
      Namespace [] ["Counters"]
      ]


--------------------------------------------------------------------------------
-- ChurnCounters Tracer
--------------------------------------------------------------------------------


instance LogFormatting ChurnCounters where
  forMachine _dtal (ChurnCounter action c) =
    mconcat [ "kind" .= String "ChurnCounter"
            , "action" .= String (pack $ show action)
            , "counter" .= c
            ]
  asMetrics (ChurnCounter action c) =
    [ IntM
        ("peerSelection.churn." <> pack (show action))
        (fromIntegral c)
    ]

instance MetaTrace ChurnCounters where
    namespaceFor ChurnCounter {} = Namespace [] ["ChurnCounters"]

    severityFor (Namespace _ ["ChurnCounters"]) _ = Just Info
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["ChurnCounters"]) = Just
      "churn counters"
    documentFor _ = Nothing

    metricsDocFor (Namespace _ ["ChurnCounters"]) =
     [ ("peerSelection.churn.DecreasedActivePeers", "number of decreased active peers")
     , ("peerSelection.churn.IncreasedActivePeers", "number of increased active peers")
     , ("peerSelection.churn.DecreasedActiveBigLedgerPeers", "number of decreased active big ledger peers")
     , ("peerSelection.churn.IncreasedActiveBigLedgerPeers", "number of increased active big ledger peers")
     , ("peerSelection.churn.DecreasedEstablishedPeers", "number of decreased established peers")
     , ("peerSelection.churn.IncreasedEstablishedPeers", "number of increased established peers")
     , ("peerSelection.churn.IncreasedEstablishedBigLedgerPeers", "number of increased established big ledger peers")
     , ("peerSelection.churn.DecreasedEstablishedBigLedgerPeers", "number of decreased established big ledger peers")
     , ("peerSelection.churn.DecreasedKnownPeers", "number of decreased known peers")
     , ("peerSelection.churn.IncreasedKnownPeers", "number of increased known peers")
     , ("peerSelection.churn.DecreasedKnownBigLedgerPeers", "number of decreased known big ledger peers")
     , ("peerSelection.churn.IncreasedKnownBigLedgerPeers", "number of increased known big ledger peers")
     ]
    metricsDocFor _ = []

    allNamespaces =[
      Namespace [] ["ChurnCounters"]
      ]


--------------------------------------------------------------------------------
-- PeerSelectionActions Tracer
--------------------------------------------------------------------------------

-- TODO: Write PeerStatusChangeType ToJSON at ouroboros-network
-- For that an export is needed at ouroboros-network
instance Show lAddr => LogFormatting (PeerSelectionActionsTrace SockAddr lAddr) where
  forMachine _dtal (PeerStatusChanged ps) =
    mconcat [ "kind" .= String "PeerStatusChanged"
             , "peerStatusChangeType" .= show ps
             ]
  forMachine _dtal (PeerStatusChangeFailure ps f) =
    mconcat [ "kind" .= String "PeerStatusChangeFailure"
             , "peerStatusChangeType" .= show ps
             , "reason" .= show f
             ]
  forMachine _dtal (PeerMonitoringError connId s) =
    mconcat [ "kind" .= String "PeerMonitoringError"
             , "connectionId" .= toJSON connId
             , "reason" .= show s
             ]
  forMachine _dtal (PeerMonitoringResult connId wf) =
    mconcat [ "kind" .= String "PeerMonitoringResult"
             , "connectionId" .= toJSON connId
             , "withProtocolTemp" .= show wf
             ]
  forMachine _dtal (AcquireConnectionError exception) =
    mconcat [ "kind" .= String "AcquireConnectionError"
            , "error" .= displayException exception
            ]
  forHuman = pack . show

instance MetaTrace (PeerSelectionActionsTrace SockAddr lAddr) where
    namespaceFor PeerStatusChanged {} = Namespace [] ["StatusChanged"]
    namespaceFor PeerStatusChangeFailure {} = Namespace [] ["StatusChangeFailure"]
    namespaceFor PeerMonitoringError {} = Namespace [] ["MonitoringError"]
    namespaceFor PeerMonitoringResult {} = Namespace [] ["MonitoringResult"]
    namespaceFor AcquireConnectionError {} = Namespace [] ["ConnectionError"]

    severityFor (Namespace _ ["StatusChanged"]) _ = Just Info
    severityFor (Namespace _ ["StatusChangeFailure"]) _ = Just Error
    severityFor (Namespace _ ["MonitoringError"]) _ = Just Error
    severityFor (Namespace _ ["MonitoringResult"]) _ = Just Debug
    severityFor (Namespace _ ["ConnectionError"]) _ = Just Error
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["StatusChanged"]) = Just
      ""
    documentFor (Namespace _ ["StatusChangeFailure"]) = Just
      ""
    documentFor (Namespace _ ["MonitoringError"]) = Just
      ""
    documentFor (Namespace _ ["MonitoringResult"]) = Just
      ""
    documentFor (Namespace _ ["ConnectionError"]) = Just
      ""
    documentFor _ = Nothing

    allNamespaces = [
        Namespace [] ["StatusChanged"]
      , Namespace [] ["StatusChangeFailure"]
      , Namespace [] ["MonitoringError"]
      , Namespace [] ["MonitoringResult"]
      , Namespace [] ["ConnectionError"]
      ]

--------------------------------------------------------------------------------
-- Connection Manager Tracer
--------------------------------------------------------------------------------

instance (Show addr, Show versionNumber, Show agreedOptions, LogFormatting addr,
          ToJSON addr, ToJSON versionNumber, ToJSON agreedOptions)
      => LogFormatting (ConnectionManager.Trace addr (ConnectionHandlerTrace versionNumber agreedOptions)) where
    forMachine dtal (TrIncludeConnection prov peerAddr) =
        mconcat $ reverse
          [ "kind" .= String "IncludeConnection"
          , "remoteAddress" .= forMachine dtal peerAddr
          , "provenance" .= String (pack . show $ prov)
          ]
    forMachine _dtal (TrReleaseConnection prov connId) =
        mconcat $ reverse
          [ "kind" .= String "UnregisterConnection"
          , "remoteAddress" .= toJSON connId
          , "provenance" .= String (pack . show $ prov)
          ]
    forMachine _dtal (TrConnect (Just localAddress) remoteAddress diffusionMode) =
        mconcat
          [ "kind" .= String "Connect"
          , "connectionId" .= toJSON ConnectionId { localAddress, remoteAddress }
          , "diffusionMode" .= toJSON diffusionMode
          ]
    forMachine dtal (TrConnect Nothing remoteAddress diffusionMode) =
        mconcat
          [ "kind" .= String "Connect"
          , "remoteAddress" .= forMachine dtal remoteAddress
          , "diffusionMode" .= toJSON diffusionMode
          ]
    forMachine _dtal (TrConnectError (Just localAddress) remoteAddress err) =
        mconcat
          [ "kind" .= String "ConnectError"
          , "connectionId" .= toJSON ConnectionId { localAddress, remoteAddress }
          , "reason" .= String (pack . show $ err)
          ]
    forMachine dtal (TrConnectError Nothing remoteAddress err) =
        mconcat
          [ "kind" .= String "ConnectError"
          , "remoteAddress" .= forMachine dtal remoteAddress
          , "reason" .= String (pack . show $ err)
          ]
    forMachine _dtal (TrTerminatingConnection prov connId) =
        mconcat
          [ "kind" .= String "TerminatingConnection"
          , "provenance" .= String (pack . show $ prov)
          , "connectionId" .= toJSON connId
          ]
    forMachine dtal (TrTerminatedConnection prov remoteAddress) =
        mconcat
          [ "kind" .= String "TerminatedConnection"
          , "provenance" .= String (pack . show $ prov)
          , "remoteAddress" .= forMachine dtal remoteAddress
          ]
    forMachine dtal (TrConnectionHandler connId a) =
        mconcat
          [ "kind" .= String "ConnectionHandler"
          , "connectionId" .= toJSON connId
          , "connectionHandler" .= forMachine dtal a
          ]
    forMachine _dtal TrShutdown =
        mconcat
          [ "kind" .= String "Shutdown"
          ]
    forMachine dtal (TrConnectionExists prov remoteAddress inState) =
        mconcat
          [ "kind" .= String "ConnectionExists"
          , "provenance" .= String (pack . show $ prov)
          , "remoteAddress" .= forMachine dtal remoteAddress
          , "state" .= toJSON inState
          ]
    forMachine _dtal (TrForbiddenConnection connId) =
        mconcat
          [ "kind" .= String "ForbiddenConnection"
          , "connectionId" .= toJSON connId
          ]
    forMachine _dtal (TrConnectionFailure connId) =
        mconcat
          [ "kind" .= String "ConnectionFailure"
          , "connectionId" .= toJSON connId
          ]
    forMachine dtal (TrConnectionNotFound prov remoteAddress) =
        mconcat
          [ "kind" .= String "ConnectionNotFound"
          , "remoteAddress" .= forMachine dtal remoteAddress
          , "provenance" .= String (pack . show $ prov)
          ]
    forMachine dtal (TrForbiddenOperation remoteAddress connState) =
        mconcat
          [ "kind" .= String "ForbiddenOperation"
          , "remoteAddress" .= forMachine dtal remoteAddress
          , "connectionState" .= toJSON connState
          ]
    forMachine _dtal (TrPruneConnections pruningSet numberPruned chosenPeers) =
        mconcat
          [ "kind" .= String "PruneConnections"
          , "prunedPeers" .= toJSON pruningSet
          , "numberPrunedPeers" .= toJSON numberPruned
          , "choiceSet" .= toJSON (toJSON `Set.map` chosenPeers)
          ]
    forMachine _dtal (TrConnectionCleanup connId) =
        mconcat
          [ "kind" .= String "ConnectionCleanup"
          , "connectionId" .= toJSON connId
          ]
    forMachine _dtal (TrConnectionTimeWait connId) =
        mconcat
          [ "kind" .= String "ConnectionTimeWait"
          , "connectionId" .= toJSON connId
          ]
    forMachine _dtal (TrConnectionTimeWaitDone connId) =
        mconcat
          [ "kind" .= String "ConnectionTimeWaitDone"
          , "connectionId" .= toJSON connId
          ]
    forMachine _dtal (TrConnectionManagerCounters cmCounters) =
        mconcat
          [ "kind"  .= String "ConnectionManagerCounters"
          , "state" .= toJSON cmCounters
          ]
    forMachine _dtal (TrState cmState) =
        mconcat
          [ "kind"  .= String "ConnectionManagerState"
          , "state" .= listValue (\(remoteAddr, inner) ->
                                         object
                                           [ "connections" .=
                                             listValue (\(localAddr, connState) ->
                                                object
                                                  [ "localAddress" .= localAddr
                                                  , "state" .= toJSON connState
                                                  ]
                                             )
                                             (Map.toList inner)
                                           , "remoteAddress" .= toJSON remoteAddr
                                           ]
                                 )
                                 (Map.toList (getConnMap cmState))
          ]
    forMachine _dtal (ConnectionManager.TrUnexpectedlyFalseAssertion info) =
        mconcat
          [ "kind" .= String "UnexpectedlyFalseAssertion"
          , "info" .= String (pack . show $ info)
          ]
    forHuman = pack . show
    asMetrics (TrConnectionManagerCounters ConnectionManagerCounters {..}) =
          [ IntM
              "connectionManager.fullDuplexConns"
              (fromIntegral fullDuplexConns)
          , IntM
              "connectionManager.duplexConns"
              (fromIntegral duplexConns)
          , IntM
              "connectionManager.unidirectionalConns"
              (fromIntegral unidirectionalConns)
          , IntM
              "connectionManager.inboundConns"
              (fromIntegral inboundConns)
          , IntM
              "connectionManager.outboundConns"
              (fromIntegral outboundConns)
            ]
    asMetrics _ = []

instance (Show versionNumber, ToJSON versionNumber, ToJSON agreedOptions)
  => LogFormatting (ConnectionHandlerTrace versionNumber agreedOptions) where
    forMachine _dtal (TrHandshakeSuccess versionNumber agreedOptions) =
      mconcat
        [ "kind" .= String "HandshakeSuccess"
        , "versionNumber" .= toJSON versionNumber
        , "agreedOptions" .= toJSON agreedOptions
        ]
    forMachine _dtal (TrHandshakeQuery vMap) =
      mconcat
        [ "kind" .= String "HandshakeQuery"
        , "versions" .= toJSON ((\(k,v) -> object [
            "versionNumber" .= k
          , "options" .= v
          ]) <$> Map.toList vMap)
        ]
    forMachine _dtal (TrHandshakeClientError err) =
      mconcat
        [ "kind" .= String "HandshakeClientError"
        , "reason" .= toJSON err
        ]
    forMachine _dtal (TrHandshakeServerError err) =
      mconcat
        [ "kind" .= String "HandshakeServerError"
        , "reason" .= toJSON err
        ]
    forMachine _dtal (TrConnectionHandlerError e err cerr) =
      mconcat
        [ "kind" .= String "Error"
        , "context" .= show e
        , "reason" .= show err
        , "command" .= show cerr
        ]

instance MetaTrace (ConnectionManager.Trace addr
                      (ConnectionHandlerTrace versionNumber agreedOptions)) where
    namespaceFor TrIncludeConnection {}  = Namespace [] ["IncludeConnection"]
    namespaceFor TrReleaseConnection {}  = Namespace [] ["UnregisterConnection"]
    namespaceFor TrConnect {}  = Namespace [] ["Connect"]
    namespaceFor TrConnectError {}  = Namespace [] ["ConnectError"]
    namespaceFor TrTerminatingConnection {}  = Namespace [] ["TerminatingConnection"]
    namespaceFor TrTerminatedConnection {}  = Namespace [] ["TerminatedConnection"]
    namespaceFor TrConnectionHandler {}  = Namespace [] ["ConnectionHandler"]
    namespaceFor TrShutdown {}  = Namespace [] ["Shutdown"]
    namespaceFor TrConnectionExists {}  = Namespace [] ["ConnectionExists"]
    namespaceFor TrForbiddenConnection {}  = Namespace [] ["ForbiddenConnection"]
    namespaceFor TrConnectionFailure {}  = Namespace [] ["ConnectionFailure"]
    namespaceFor TrConnectionNotFound {}  = Namespace [] ["ConnectionNotFound"]
    namespaceFor TrForbiddenOperation {}  = Namespace [] ["ForbiddenOperation"]
    namespaceFor TrPruneConnections {}  = Namespace [] ["PruneConnections"]
    namespaceFor TrConnectionCleanup {}  = Namespace [] ["ConnectionCleanup"]
    namespaceFor TrConnectionTimeWait {}  = Namespace [] ["ConnectionTimeWait"]
    namespaceFor TrConnectionTimeWaitDone {}  = Namespace [] ["ConnectionTimeWaitDone"]
    namespaceFor TrConnectionManagerCounters {}  = Namespace [] ["ConnectionManagerCounters"]
    namespaceFor TrState {}  = Namespace [] ["State"]
    namespaceFor ConnectionManager.TrUnexpectedlyFalseAssertion {}  =
      Namespace [] ["UnexpectedlyFalseAssertion"]

    severityFor (Namespace _  ["IncludeConnection"]) _ = Just Debug
    severityFor (Namespace _  ["UnregisterConnection"]) _ = Just Debug
    severityFor (Namespace _  ["Connect"]) _ = Just Debug
    severityFor (Namespace _  ["ConnectError"]) _ = Just Info
    severityFor (Namespace _  ["TerminatingConnection"]) _ = Just Debug
    severityFor (Namespace _  ["TerminatedConnection"]) _ = Just Debug
    severityFor (Namespace _  ["ConnectionHandler"])
      (Just (TrConnectionHandler _ ev')) = Just $
        case ev' of
          TrHandshakeSuccess {}     -> Info
          TrHandshakeQuery {}       -> Info
          TrHandshakeClientError {} -> Notice
          TrHandshakeServerError {} -> Info
          TrConnectionHandlerError _ _ ShutdownNode  -> Critical
          TrConnectionHandlerError _ _ ShutdownPeer  -> Info
    severityFor (Namespace _  ["ConnectionHandler"]) _ = Just Info
    severityFor (Namespace _  ["Shutdown"]) _ = Just Info
    severityFor (Namespace _  ["ConnectionExists"]) _ = Just Info
    severityFor (Namespace _  ["ForbiddenConnection"]) _ = Just Info
    severityFor (Namespace _  ["ImpossibleConnection"]) _ = Just Info
    severityFor (Namespace _  ["ConnectionFailure"]) _ = Just Info
    severityFor (Namespace _  ["ConnectionNotFound"]) _ = Just Debug
    severityFor (Namespace _  ["ForbiddenOperation"]) _ = Just Info
    severityFor (Namespace _  ["PruneConnections"]) _ = Just Notice
    severityFor (Namespace _  ["ConnectionCleanup"]) _ = Just Debug
    severityFor (Namespace _  ["ConnectionTimeWait"]) _ = Just Debug
    severityFor (Namespace _  ["ConnectionTimeWaitDone"]) _ = Just Info
    severityFor (Namespace _  ["ConnectionManagerCounters"]) _ = Just Debug
    severityFor (Namespace _  ["State"]) _ = Just Info
    severityFor (Namespace _  ["UnexpectedlyFalseAssertion"]) _ = Just Error
    severityFor _ _ = Nothing

    documentFor (Namespace _  ["IncludeConnection"]) = Just ""
    documentFor (Namespace _  ["UnregisterConnection"]) = Just ""
    documentFor (Namespace _  ["Connect"]) = Just ""
    documentFor (Namespace _  ["ConnectError"]) = Just ""
    documentFor (Namespace _  ["TerminatingConnection"]) = Just ""
    documentFor (Namespace _  ["TerminatedConnection"]) = Just ""
    documentFor (Namespace _  ["ConnectionHandler"]) = Just ""
    documentFor (Namespace _  ["Shutdown"]) = Just ""
    documentFor (Namespace _  ["ConnectionExists"]) = Just ""
    documentFor (Namespace _  ["ForbiddenConnection"]) = Just ""
    documentFor (Namespace _  ["ImpossibleConnection"]) = Just ""
    documentFor (Namespace _  ["ConnectionFailure"]) = Just ""
    documentFor (Namespace _  ["ConnectionNotFound"]) = Just ""
    documentFor (Namespace _  ["ForbiddenOperation"]) = Just ""
    documentFor (Namespace _  ["PruneConnections"]) = Just ""
    documentFor (Namespace _  ["ConnectionCleanup"]) = Just ""
    documentFor (Namespace _  ["ConnectionTimeWait"]) = Just ""
    documentFor (Namespace _  ["ConnectionTimeWaitDone"]) = Just ""
    documentFor (Namespace _  ["ConnectionManagerCounters"]) = Just ""
    documentFor (Namespace _  ["State"]) = Just ""
    documentFor (Namespace _  ["UnexpectedlyFalseAssertion"]) = Just ""
    documentFor _ = Nothing

    metricsDocFor (Namespace _  ["ConnectionManagerCounters"]) =
      [("connectionManager.fullDuplexConns","")
      ,("connectionManager.duplexConns","")
      ,("connectionManager.unidirectionalConns","")
      ,("connectionManager.inboundConns","")
      ,("connectionManager.outboundConns","")
      ,("connectionManager.prunableConns","")
      ]
    metricsDocFor _ = []

    allNamespaces = [
        Namespace [] ["IncludeConnection"]
      , Namespace [] ["UnregisterConnection"]
      , Namespace [] ["Connect"]
      , Namespace [] ["ConnectError"]
      , Namespace [] ["TerminatingConnection"]
      , Namespace [] ["TerminatedConnection"]
      , Namespace [] ["ConnectionHandler"]
      , Namespace [] ["Shutdown"]
      , Namespace [] ["ConnectionExists"]
      , Namespace [] ["ForbiddenConnection"]
      , Namespace [] ["ImpossibleConnection"]
      , Namespace [] ["ConnectionFailure"]
      , Namespace [] ["ConnectionNotFound"]
      , Namespace [] ["ForbiddenOperation"]
      , Namespace [] ["PruneConnections"]
      , Namespace [] ["ConnectionCleanup"]
      , Namespace [] ["ConnectionTimeWait"]
      , Namespace [] ["ConnectionTimeWaitDone"]
      , Namespace [] ["ConnectionManagerCounters"]
      , Namespace [] ["State"]
      , Namespace [] ["UnexpectedlyFalseAssertion"]
      ]

--------------------------------------------------------------------------------
-- Connection Manager Transition Tracer
--------------------------------------------------------------------------------

instance (Show peerAddr, ToJSON peerAddr)
      => LogFormatting (ConnectionManager.AbstractTransitionTrace peerAddr) where
    forMachine _dtal (ConnectionManager.TransitionTrace peerAddr tr) =
      mconcat $ reverse
        [ "kind"    .= String "ConnectionManagerTransition"
        , "address" .= toJSON peerAddr
        , "from"    .= toJSON (ConnectionManager.fromState tr)
        , "to"      .= toJSON (ConnectionManager.toState   tr)
        ]
    forHuman = pack . show
    asMetrics _ = []

instance MetaTrace (ConnectionManager.AbstractTransitionTrace peerAddr) where
    namespaceFor ConnectionManager.TransitionTrace {} =
      Namespace [] ["Transition"]

    severityFor (Namespace _  ["Transition"]) _ = Just Debug
    severityFor _ _ = Nothing

    documentFor (Namespace _  ["Transition"]) = Just ""
    documentFor _ = Nothing

    allNamespaces = [Namespace [] ["Transition"]]

--------------------------------------------------------------------------------
-- Server Tracer
--------------------------------------------------------------------------------

instance (Show addr, LogFormatting addr, ToJSON addr)
      => LogFormatting (Server.Trace addr) where
  forMachine _dtal (TrAcceptConnection connId)     =
    mconcat [ "kind" .= String "AcceptConnection"
             , "address" .= toJSON connId
             ]
  forMachine _dtal (TrAcceptError exception)         =
    mconcat [ "kind" .= String "AcceptErroor"
             , "reason" .= show exception
             ]
  forMachine dtal (TrAcceptPolicyTrace policyTrace) =
    mconcat [ "kind" .= String "AcceptPolicyTrace"
             , "policy" .= forMachine dtal policyTrace
             ]
  forMachine dtal (TrServerStarted peerAddrs)       =
    mconcat [ "kind" .= String "AcceptPolicyTrace"
             , "addresses" .= toJSON (forMachine dtal `map` peerAddrs)
             ]
  forMachine _dtal TrServerStopped                   =
    mconcat [ "kind" .= String "ServerStopped"
             ]
  forMachine _dtal (TrServerError exception)         =
    mconcat [ "kind" .= String "ServerError"
             , "reason" .= show exception
             ]
  forHuman = pack . show

instance MetaTrace (Server.Trace addr) where
    namespaceFor TrAcceptConnection {} = Namespace [] ["AcceptConnection"]
    namespaceFor TrAcceptError {} = Namespace [] ["AcceptError"]
    namespaceFor TrAcceptPolicyTrace {} = Namespace [] ["AcceptPolicy"]
    namespaceFor TrServerStarted {} = Namespace [] ["Started"]
    namespaceFor TrServerStopped {} = Namespace [] ["Stopped"]
    namespaceFor TrServerError {} = Namespace [] ["Error"]

    severityFor (Namespace _ ["AcceptConnection"]) _ = Just Debug
    severityFor (Namespace _ ["AcceptError"]) _ = Just Error
    severityFor (Namespace _ ["AcceptPolicy"]) _ = Just Notice
    severityFor (Namespace _ ["Started"]) _ = Just Notice
    severityFor (Namespace _ ["Stopped"]) _ = Just Notice
    severityFor (Namespace _ ["Error"]) _ = Just Critical
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["AcceptConnection"]) = Just ""
    documentFor (Namespace _ ["AcceptError"]) = Just ""
    documentFor (Namespace _ ["AcceptPolicy"]) = Just ""
    documentFor (Namespace _ ["Started"]) = Just ""
    documentFor (Namespace _ ["Stopped"]) = Just ""
    documentFor (Namespace _ ["Error"]) = Just ""
    documentFor _ = Nothing

    allNamespaces = [
        Namespace [] ["AcceptConnection"]
      , Namespace [] ["AcceptError"]
      , Namespace [] ["AcceptPolicy"]
      , Namespace [] ["Started"]
      , Namespace [] ["Stopped"]
      , Namespace [] ["Error"]
      ]

--------------------------------------------------------------------------------
-- InboundGovernor Tracer
--------------------------------------------------------------------------------

instance LogFormatting (InboundGovernor.Trace SockAddr) where
  forMachine = forMachineGov
  forHuman = pack . show
  asMetrics (TrInboundGovernorCounters InboundGovernor.Counters {..}) =
            [ IntM
                "inboundGovernor.idle"
                (fromIntegral idlePeersRemote)
            , IntM
                "inboundGovernor.cold"
                (fromIntegral coldPeersRemote)
            , IntM
                "inboundGovernor.warm"
                (fromIntegral warmPeersRemote)
            , IntM
                "inboundGovernor.hot"
                (fromIntegral hotPeersRemote)
              ]
  asMetrics _ = []

instance LogFormatting (InboundGovernor.Trace LocalAddress) where
  forMachine = forMachineGov
  forHuman = pack . show
  asMetrics (TrInboundGovernorCounters InboundGovernor.Counters {..}) =
            [ IntM
                "localInboundGovernor.idle"
                (fromIntegral idlePeersRemote)
            , IntM
                "localInboundGovernor.cold"
                (fromIntegral coldPeersRemote)
            , IntM
                "localInboundGovernor.warm"
                (fromIntegral warmPeersRemote)
            , IntM
                "localInboundGovernor.hot"
                (fromIntegral hotPeersRemote)
              ]
  asMetrics _ = []


forMachineGov :: (ToJSON adr, Show adr) => DetailLevel -> InboundGovernor.Trace adr -> Object
forMachineGov _dtal (TrNewConnection p connId)            =
  mconcat [ "kind" .= String "NewConnection"
            , "provenance" .= show p
            , "connectionId" .= toJSON connId
            ]
forMachineGov _dtal (TrResponderRestarted connId m)       =
  mconcat [ "kind" .= String "ResponderStarted"
            , "connectionId" .= toJSON connId
            , "miniProtocolNum" .= toJSON m
            ]
forMachineGov _dtal (TrResponderStartFailure connId m s)  =
  mconcat [ "kind" .= String "ResponderStartFailure"
            , "connectionId" .= toJSON connId
            , "miniProtocolNum" .= toJSON m
            , "reason" .= show s
            ]
forMachineGov _dtal (TrResponderErrored connId m s)       =
  mconcat [ "kind" .= String "ResponderErrored"
            , "connectionId" .= toJSON connId
            , "miniProtocolNum" .= toJSON m
            , "reason" .= show s
            ]
forMachineGov _dtal (TrResponderStarted connId m)         =
  mconcat [ "kind" .= String "ResponderStarted"
            , "connectionId" .= toJSON connId
            , "miniProtocolNum" .= toJSON m
            ]
forMachineGov _dtal (TrResponderTerminated connId m)      =
  mconcat [ "kind" .= String "ResponderTerminated"
            , "connectionId" .= toJSON connId
            , "miniProtocolNum" .= toJSON m
            ]
forMachineGov _dtal (TrPromotedToWarmRemote connId opRes) =
  mconcat [ "kind" .= String "PromotedToWarmRemote"
            , "connectionId" .= toJSON connId
            , "result" .= toJSON opRes
            ]
forMachineGov _dtal (TrPromotedToHotRemote connId)        =
  mconcat [ "kind" .= String "PromotedToHotRemote"
            , "connectionId" .= toJSON connId
            ]
forMachineGov _dtal (TrDemotedToColdRemote connId od)     =
  mconcat [ "kind" .= String "DemotedToColdRemote"
            , "connectionId" .= toJSON connId
            , "result" .= show od
            ]
forMachineGov _dtal (TrDemotedToWarmRemote connId)     =
  mconcat [ "kind" .= String "DemotedToWarmRemote"
            , "connectionId" .= toJSON connId
            ]
forMachineGov _dtal (TrWaitIdleRemote connId opRes) =
  mconcat [ "kind" .= String "WaitIdleRemote"
            , "connectionId" .= toJSON connId
            , "result" .= toJSON opRes
            ]
forMachineGov _dtal (TrMuxCleanExit connId)               =
  mconcat [ "kind" .= String "MuxCleanExit"
            , "connectionId" .= toJSON connId
            ]
forMachineGov _dtal (TrMuxErrored connId s)               =
  mconcat [ "kind" .= String "MuxErrored"
            , "connectionId" .= toJSON connId
            , "reason" .= show s
            ]
forMachineGov _dtal (TrInboundGovernorCounters counters) =
  mconcat [ "kind" .= String "InboundGovernorCounters"
            , "idlePeers" .= idlePeersRemote counters
            , "coldPeers" .= coldPeersRemote counters
            , "warmPeers" .= warmPeersRemote counters
            , "hotPeers" .= hotPeersRemote counters
            ]
forMachineGov _dtal (TrRemoteState st) =
  mconcat [ "kind" .= String "RemoteState"
            , "remoteSt" .= toJSON st
            ]
forMachineGov _dtal (InboundGovernor.TrUnexpectedlyFalseAssertion info) =
  mconcat [ "kind" .= String "UnexpectedlyFalseAssertion"
            , "remoteSt" .= String (pack . show $ info)
            ]
forMachineGov _dtal (InboundGovernor.TrInboundGovernorError err) =
  mconcat [ "kind" .= String "InboundGovernorError"
            , "remoteSt" .= String (pack . show $ err)
            ]
forMachineGov _dtal (InboundGovernor.TrMaturedConnections matured fresh) =
  mconcat [ "kind" .= String "MaturedConnections"
          , "matured" .= toJSON matured
          , "fresh" .= toJSON fresh
          ]
forMachineGov _dtal (InboundGovernor.TrInactive fresh) =
  mconcat [ "kind" .= String "Inactive"
          , "fresh" .= toJSON fresh
          ]

instance MetaTrace (InboundGovernor.Trace addr) where
    namespaceFor TrNewConnection {}         = Namespace [] ["NewConnection"]
    namespaceFor TrResponderRestarted {}    = Namespace [] ["ResponderRestarted"]
    namespaceFor TrResponderStartFailure {} = Namespace [] ["ResponderStartFailure"]
    namespaceFor TrResponderErrored {}      = Namespace [] ["ResponderErrored"]
    namespaceFor TrResponderStarted {}      = Namespace [] ["ResponderStarted"]
    namespaceFor TrResponderTerminated {}   = Namespace [] ["ResponderTerminated"]
    namespaceFor TrPromotedToWarmRemote {}  = Namespace [] ["PromotedToWarmRemote"]
    namespaceFor TrPromotedToHotRemote {}   = Namespace [] ["PromotedToHotRemote"]
    namespaceFor TrDemotedToColdRemote {}   = Namespace [] ["DemotedToColdRemote"]
    namespaceFor TrDemotedToWarmRemote {}   = Namespace [] ["DemotedToWarmRemote"]
    namespaceFor TrWaitIdleRemote {}        = Namespace [] ["WaitIdleRemote"]
    namespaceFor TrMuxCleanExit {}          = Namespace [] ["MuxCleanExit"]
    namespaceFor TrMuxErrored {}            = Namespace [] ["MuxErrored"]
    namespaceFor TrInboundGovernorCounters {} = Namespace [] ["InboundGovernorCounters"]
    namespaceFor TrRemoteState {}            = Namespace [] ["RemoteState"]
    namespaceFor InboundGovernor.TrUnexpectedlyFalseAssertion {} =
                                Namespace [] ["UnexpectedlyFalseAssertion"]
    namespaceFor InboundGovernor.TrInboundGovernorError {} =
                                Namespace [] ["InboundGovernorError"]
    namespaceFor InboundGovernor.TrMaturedConnections {} =
                                Namespace [] ["MaturedConnections"]
    namespaceFor InboundGovernor.TrInactive {} =
                                Namespace [] ["Inactive"]

    severityFor (Namespace _ ["NewConnection"]) _ = Just Debug
    severityFor (Namespace _ ["ResponderRestarted"]) _ = Just Debug
    severityFor (Namespace _ ["ResponderStartFailure"]) _ = Just Info
    severityFor (Namespace _ ["ResponderErrored"]) _ = Just Info
    severityFor (Namespace _ ["ResponderStarted"]) _ = Just Debug
    severityFor (Namespace _ ["ResponderTerminated"]) _ = Just Debug
    severityFor (Namespace _ ["PromotedToWarmRemote"]) _ = Just Info
    severityFor (Namespace _ ["PromotedToHotRemote"]) _ = Just Info
    severityFor (Namespace _ ["DemotedToColdRemote"]) _ = Just Info
    severityFor (Namespace _ ["DemotedToWarmRemote"]) _ = Just Info
    severityFor (Namespace _ ["WaitIdleRemote"]) _ = Just Debug
    severityFor (Namespace _ ["MuxCleanExit"]) _ = Just Debug
    severityFor (Namespace _ ["MuxErrored"]) _ = Just Info
    severityFor (Namespace _ ["InboundGovernorCounters"]) _ = Just Info
    severityFor (Namespace _ ["RemoteState"]) _ = Just Debug
    severityFor (Namespace _ ["UnexpectedlyFalseAssertion"]) _ = Just Error
    severityFor (Namespace _ ["InboundGovernorError"]) _ = Just Error
    severityFor (Namespace _ ["MaturedConnections"]) _ = Just Info
    severityFor (Namespace _ ["Inactive"]) _ = Just Debug
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["NewConnection"]) = Just ""
    documentFor (Namespace _ ["ResponderRestarted"]) = Just ""
    documentFor (Namespace _ ["ResponderStartFailure"]) = Just ""
    documentFor (Namespace _ ["ResponderErrored"]) = Just ""
    documentFor (Namespace _ ["ResponderStarted"]) = Just ""
    documentFor (Namespace _ ["ResponderTerminated"]) = Just ""
    documentFor (Namespace _ ["PromotedToWarmRemote"]) = Just ""
    documentFor (Namespace _ ["PromotedToHotRemote"]) = Just ""
    documentFor (Namespace _ ["DemotedToColdRemote"]) = Just $ mconcat
      [ "All mini-protocols terminated.  The boolean is true if this connection"
      , " was not used by p2p-governor, and thus the connection will be terminated."
      ]
    documentFor (Namespace _ ["DemotedToWarmRemote"]) = Just $ mconcat
      [ "All mini-protocols terminated.  The boolean is true if this connection"
      , " was not used by p2p-governor, and thus the connection will be terminated."
      ]
    documentFor (Namespace _ ["WaitIdleRemote"]) = Just ""
    documentFor (Namespace _ ["MuxCleanExit"]) = Just ""
    documentFor (Namespace _ ["MuxErrored"]) = Just ""
    documentFor (Namespace _ ["InboundGovernorCounters"]) = Just ""
    documentFor (Namespace _ ["RemoteState"]) = Just ""
    documentFor (Namespace _ ["UnexpectedlyFalseAssertion"]) = Just ""
    documentFor (Namespace _ ["InboundGovernorError"]) = Just ""
    documentFor (Namespace _ ["MaturedConnections"]) = Just ""
    documentFor (Namespace _ ["Inactive"]) = Just ""
    documentFor _ = Nothing

    metricsDocFor (Namespace ons ["InboundGovernorCounters"])
      | null ons -- docu generation
        =
              [("localInboundGovernor.idle","")
              ,("localInboundGovernor.cold","")
              ,("localInboundGovernor.warm","")
              ,("localInboundGovernor.hot","")
              ,("inboundGovernor.Idle","")
              ,("inboundGovernor.Cold","")
              ,("inboundGovernor.Warm","")
              ,("inboundGovernor.Hot","")
              ]
      | last ons == "Local"
        =
              [("localInboundGovernor.idle","")
              ,("localInboundGovernor.cold","")
              ,("localInboundGovernor.warm","")
              ,("localInboundGovernor.hot","")
              ]
      | otherwise
        =
              [("inboundGovernor.Idle","")
              ,("inboundGovernor.Cold","")
              ,("inboundGovernor.Warm","")
              ,("inboundGovernor.Hot","")
              ]
    metricsDocFor _ = []

    allNamespaces = [
        Namespace [] ["NewConnection"]
      , Namespace [] ["ResponderRestarted"]
      , Namespace [] ["ResponderStartFailure"]
      , Namespace [] ["ResponderErrored"]
      , Namespace [] ["ResponderStarted"]
      , Namespace [] ["ResponderTerminated"]
      , Namespace [] ["PromotedToWarmRemote"]
      , Namespace [] ["PromotedToHotRemote"]
      , Namespace [] ["DemotedToColdRemote"]
      , Namespace [] ["DemotedToWarmRemote"]
      , Namespace [] ["WaitIdleRemote"]
      , Namespace [] ["MuxCleanExit"]
      , Namespace [] ["MuxErrored"]
      , Namespace [] ["InboundGovernorCounters"]
      , Namespace [] ["RemoteState"]
      , Namespace [] ["UnexpectedlyFalseAssertion"]
      , Namespace [] ["InboundGovernorError"]
      , Namespace [] ["MaturedConnections"]
      , Namespace [] ["Inactive"]
      ]

--------------------------------------------------------------------------------
-- InboundGovernor Transition Tracer
--------------------------------------------------------------------------------


instance (Show peerAddr, ToJSON peerAddr)
      => LogFormatting (InboundGovernor.RemoteTransitionTrace peerAddr) where
    forMachine _dtal (InboundGovernor.TransitionTrace peerAddr tr) =
      mconcat $ reverse
        [ "kind"    .= String "ConnectionManagerTransition"
        , "address" .= toJSON peerAddr
        , "from"    .= toJSON (ConnectionManager.fromState tr)
        , "to"      .= toJSON (ConnectionManager.toState   tr)
        ]
    forHuman = pack . show
    asMetrics _ = []

instance MetaTrace (InboundGovernor.RemoteTransitionTrace peerAddr) where
    namespaceFor InboundGovernor.TransitionTrace {} = Namespace [] ["Transition"]

    severityFor  (Namespace [] ["Transition"]) _ = Just Debug
    severityFor _ _ = Nothing

    documentFor  (Namespace [] ["Transition"]) = Just ""
    documentFor _ = Nothing

    allNamespaces = [Namespace [] ["Transition"]]


--------------------------------------------------------------------------------
-- AcceptPolicy Tracer
--------------------------------------------------------------------------------

instance LogFormatting NtN.AcceptConnectionsPolicyTrace where
    forMachine _dtal (NtN.ServerTraceAcceptConnectionRateLimiting delay numOfConnections) =
      mconcat [ "kind" .= String "ServerTraceAcceptConnectionRateLimiting"
               , "delay" .= show delay
               , "numberOfConnection" .= show numOfConnections
               ]
    forMachine _dtal (NtN.ServerTraceAcceptConnectionHardLimit softLimit) =
      mconcat [ "kind" .= String "ServerTraceAcceptConnectionHardLimit"
               , "softLimit" .= show softLimit
               ]
    forMachine _dtal (NtN.ServerTraceAcceptConnectionResume numOfConnections) =
      mconcat [ "kind" .= String "ServerTraceAcceptConnectionResume"
               , "numberOfConnection" .= show numOfConnections
               ]
    forHuman   = showT

instance MetaTrace NtN.AcceptConnectionsPolicyTrace where
    namespaceFor NtN.ServerTraceAcceptConnectionRateLimiting {} =
      Namespace [] ["ConnectionRateLimiting"]
    namespaceFor NtN.ServerTraceAcceptConnectionHardLimit {} =
      Namespace [] ["ConnectionHardLimit"]
    namespaceFor NtN.ServerTraceAcceptConnectionResume {} =
      Namespace [] ["ConnectionLimitResume"]

    severityFor (Namespace _ ["ConnectionRateLimiting"]) _ = Just Info
    severityFor (Namespace _ ["ConnectionHardLimit"]) _ = Just Warning
    severityFor (Namespace _ ["ConnectionLimitResume"]) _ = Just Info
    severityFor _ _ = Nothing

    documentFor (Namespace _ ["ConnectionRateLimiting"]) = Just $ mconcat
      [ "Rate limiting accepting connections,"
      , " delaying next accept for given time, currently serving n connections."
      ]
    documentFor (Namespace _ ["ConnectionHardLimit"]) = Just $ mconcat
      [ "Hard rate limit reached,"
      , " waiting until the number of connections drops below n."
      ]
    documentFor (Namespace _ ["ConnectionLimitResume"]) = Just
      ""
    documentFor _ = Nothing

    allNamespaces = [
        Namespace [] ["ConnectionRateLimiting"]
      , Namespace [] ["ConnectionHardLimit"]
      , Namespace [] ["ConnectionLimitResume"]
      ]

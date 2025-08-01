{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}
{-# OPTIONS_GHC -Wno-all-missed-specialisations #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Benchmarking.GeneratorTx.SubmissionClient
  ( SubmissionThreadStats(..)
  , TxSource(..)
  , txSubmissionClient
  ) where

import           Cardano.Api hiding (Active)

import           Cardano.Benchmarking.LogTypes
import           Cardano.Benchmarking.Types
import qualified Cardano.Ledger.Core as Ledger
import           Cardano.Logging
import           Cardano.Prelude hiding (ByteString, atomically, retry, state, threadDelay)
import           Cardano.Tracing.OrphanInstances.Byron ()
import           Cardano.Tracing.OrphanInstances.Common ()
import           Cardano.Tracing.OrphanInstances.Consensus ()
import           Cardano.Tracing.OrphanInstances.Network ()
import           Cardano.Tracing.OrphanInstances.Shelley ()
import qualified Ouroboros.Consensus.Cardano as Consensus (CardanoBlock)
import qualified Ouroboros.Consensus.Cardano.Block as Block
                   (TxId (GenTxIdAllegra, GenTxIdAlonzo, GenTxIdBabbage, GenTxIdConway, GenTxIdMary, GenTxIdShelley))
import           Ouroboros.Consensus.Ledger.SupportsMempool (GenTxId)
import qualified Ouroboros.Consensus.Ledger.SupportsMempool as Mempool
import           Ouroboros.Consensus.Shelley.Eras (StandardCrypto)
import qualified Ouroboros.Consensus.Shelley.Ledger.Mempool as Mempool (TxId (ShelleyTxId))
import           Ouroboros.Network.Protocol.TxSubmission2.Client (ClientStIdle (..),
                   ClientStTxIds (..), ClientStTxs (..), TxSubmissionClient (..))
import           Ouroboros.Network.Protocol.TxSubmission2.Type (BlockingReplyList (..),
                   NumTxIdsToAck (..), NumTxIdsToReq (..), SingBlockingStyle (..))
import           Ouroboros.Network.SizeInBytes

import           Prelude (error, fail)

import           Control.Arrow ((&&&))
import qualified Data.List as L
import qualified Data.List.Extra as L
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import           Lens.Micro ((^.))

type CardanoBlock    = Consensus.CardanoBlock  StandardCrypto

data SubmissionThreadStats
  = SubmissionThreadStats
      { stsAcked       :: {-# UNPACK #-} !Ack
      , stsSent        :: {-# UNPACK #-} !Sent
      , stsUnavailable :: {-# UNPACK #-} !Unav
      }

data TxSource era
  = Exhausted
  | Active (ProduceNextTxs era)

type ProduceNextTxs era = (forall m blocking . MonadIO m => SingBlockingStyle blocking -> Req -> m (TxSource era, [Tx era]))

produceNextTxs :: forall m blocking era . MonadIO m => SingBlockingStyle blocking -> Req -> LocalState era -> m (LocalState era, [Tx era])
produceNextTxs blocking req (txProducer, unack, stats) = do
  (newTxProducer, txList) <- produceNextTxs' blocking req txProducer
  return ((newTxProducer, unack, stats), txList)

produceNextTxs' :: forall m blocking era . MonadIO m => SingBlockingStyle blocking -> Req -> TxSource era -> m (TxSource era, [Tx era])
produceNextTxs' _ _ Exhausted = return (Exhausted, [])
produceNextTxs' blocking req (Active callback) = callback blocking req

type LocalState era = (TxSource era, UnAcked (Tx era), SubmissionThreadStats)
type EndOfProtocolCallback m = SubmissionThreadStats -> m ()

txSubmissionClient
  :: forall m era.
     ( MonadIO m, MonadFail m
     , IsShelleyBasedEra era
     )
  => Trace m NodeToNodeSubmissionTrace
  -> Trace m (TraceBenchTxSubmit TxId)
  -> TxSource era
  -> EndOfProtocolCallback m
  -> TxSubmissionClient (GenTxId CardanoBlock) (GenTx CardanoBlock) m ()
txSubmissionClient tr bmtr initialTxSource endOfProtocolCallback =
  TxSubmissionClient $
    pure $ client (initialTxSource, UnAcked [], SubmissionThreadStats 0 0 0)
 where
  discardAcknowledged :: SingBlockingStyle a -> Ack -> LocalState era -> m (LocalState era)
  discardAcknowledged blocking (Ack ack) (txSource, UnAcked unAcked, stats) = do
    when (tokIsBlocking blocking && ack /= length unAcked) $ do
      let err = "decideAnnouncement: SingBlocking, but length unAcked != ack"
      traceWith bmtr (TraceBenchTxSubError err)
      fail (T.unpack err)
    let (stillUnacked, acked) = L.splitAtEnd ack unAcked
    let newStats = stats { stsAcked = stsAcked stats + Ack ack }
    traceWith bmtr $ SubmissionClientDiscardAcknowledged  (getTxId . getTxBody <$> acked)
    return (txSource, UnAcked stillUnacked, newStats)

  queueNewTxs :: [Tx era] -> LocalState era -> LocalState era
  queueNewTxs newTxs (txSource, UnAcked unAcked, stats)
    = (txSource, UnAcked (newTxs <> unAcked), stats)

  client :: LocalState era -> ClientStIdle (GenTxId CardanoBlock) (GenTx CardanoBlock) m ()

  client localState = ClientStIdle
    { recvMsgRequestTxIds = requestTxIds localState
    , recvMsgRequestTxs = requestTxs localState
    }

  requestTxIds :: forall blocking.
       LocalState era
    -> SingBlockingStyle blocking
    -> NumTxIdsToAck
    -> NumTxIdsToReq
    -> m (ClientStTxIds blocking (GenTxId CardanoBlock) (GenTx CardanoBlock) m ())
  requestTxIds state blocking (NumTxIdsToAck ackNum) (NumTxIdsToReq reqNum) = do
    let ack = Ack $ fromIntegral ackNum
        req = Req $ fromIntegral reqNum
    traceWith tr $ reqIdsTrace ack req blocking
    stateA <- discardAcknowledged blocking ack state
    (stateB, newTxs) <- produceNextTxs blocking req stateA
    let stateC@(_, UnAcked outs , stats) = queueNewTxs newTxs stateB

    traceWith tr $ idListTrace (ToAnnce newTxs) blocking
    traceWith bmtr $ SubmissionClientReplyTxIds (getTxId . getTxBody <$> newTxs)
    traceWith bmtr $ SubmissionClientUnAcked (getTxId . getTxBody <$> outs)

    case blocking of
      SingBlocking -> case NE.nonEmpty newTxs of
        Nothing -> do
          traceWith tr EndOfProtocol
          endOfProtocolCallback stats
          pure $ SendMsgDone ()
        (Just txs) -> pure $ SendMsgReplyTxIds
                              (BlockingReply $ txToIdSize <$> txs)
                              (client stateC)
      SingNonBlocking ->  pure $ SendMsgReplyTxIds
                             (NonBlockingReply $ txToIdSize <$> newTxs)
                             (client stateC)

  requestTxs ::
       LocalState era
    -> [GenTxId CardanoBlock]
    -> m (ClientStTxs (GenTxId CardanoBlock) (GenTx CardanoBlock) m ())
  requestTxs (txSource, unAcked, stats) txIds = do
    let  reqTxIds :: [TxId]
         reqTxIds = fmap fromGenTxId txIds
    traceWith tr $ ReqTxs (length reqTxIds)
    let UnAcked ua = unAcked
        uaIds = getTxId . getTxBody <$> ua
        (toSend, _retained) = L.partition ((`L.elem` reqTxIds) . getTxId . getTxBody) ua
        missIds = reqTxIds L.\\ uaIds

    traceWith tr $ TxList (length toSend)
    traceWith bmtr $ SubmissionClientUnAcked (getTxId . getTxBody <$> ua)
    traceWith bmtr $ TraceBenchTxSubServReq reqTxIds
    unless (L.null missIds) $
      traceWith bmtr $ TraceBenchTxSubServUnav missIds
    pure $ SendMsgReplyTxs (toGenTx <$> toSend)
      (client (txSource, unAcked,
        stats { stsSent =
                stsSent stats + Sent (length toSend)
              , stsUnavailable =
                stsUnavailable stats + Unav (length missIds)}))

  txToIdSize :: Tx era -> (GenTxId CardanoBlock, SizeInBytes)
  txToIdSize = (Mempool.txId . toGenTx) &&& (SizeInBytes . fromInteger . getTxSize)
    where
      getTxSize :: Tx era -> Integer
      getTxSize (ShelleyTx sbe tx) =
        shelleyBasedEraConstraints sbe $ tx ^. Ledger.sizeTxF

  toGenTx :: Tx era -> GenTx CardanoBlock
  toGenTx tx = toConsensusGenTx $ TxInMode shelleyBasedEra tx

  fromGenTxId :: GenTxId CardanoBlock -> TxId
  fromGenTxId (Block.GenTxIdShelley (Mempool.ShelleyTxId i)) = fromShelleyTxId i
  fromGenTxId (Block.GenTxIdAllegra (Mempool.ShelleyTxId i)) = fromShelleyTxId i
  fromGenTxId (Block.GenTxIdMary    (Mempool.ShelleyTxId i)) = fromShelleyTxId i
  fromGenTxId (Block.GenTxIdAlonzo  (Mempool.ShelleyTxId i)) = fromShelleyTxId i
  fromGenTxId (Block.GenTxIdBabbage (Mempool.ShelleyTxId i)) = fromShelleyTxId i
  fromGenTxId (Block.GenTxIdConway  (Mempool.ShelleyTxId i)) = fromShelleyTxId i
  fromGenTxId _ = error "TODO: fix incomplete match"

  tokIsBlocking :: SingBlockingStyle a -> Bool
  tokIsBlocking = \case
    SingBlocking    -> True
    SingNonBlocking -> False

  reqIdsTrace :: Ack -> Req -> SingBlockingStyle a -> NodeToNodeSubmissionTrace
  reqIdsTrace ack req = \case
     SingBlocking    -> ReqIdsBlocking ack req
     SingNonBlocking -> ReqIdsNonBlocking ack req

  idListTrace :: ToAnnce tx -> SingBlockingStyle a -> NodeToNodeSubmissionTrace
  idListTrace (ToAnnce toAnn) = \case
     SingBlocking    -> IdsListBlocking $ length toAnn
     SingNonBlocking -> IdsListNonBlocking $ length toAnn

{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE OverloadedStrings #-}

--------------------------------------------------------------------------------

module Cardano.Benchmarking.Profile.Builtin.Miniature (
  base
, benchDuration
, profilesNoEraMiniature
) where

--------------------------------------------------------------------------------

import           Prelude
import           Data.Function ((&))
-- Package: self.
import qualified Cardano.Benchmarking.Profile.Primitives as P
import qualified Cardano.Benchmarking.Profile.Types as Types
import qualified Cardano.Benchmarking.Profile.Vocabulary as V

--------------------------------------------------------------------------------

base :: Types.Profile -> Types.Profile
base =
    P.fixedLoaded
  . V.datasetMiniature
  . V.fundsDefault
  . V.timescaleCompressed
  . P.initCooldown 5
  . P.analysisStandard
  . P.desc "Miniature dataset, CI-friendly duration, bench scale"

benchDuration :: Types.Profile -> Types.Profile
benchDuration =
    P.shutdownOnBlock 15
  -- TODO: dummy "generator.epochs" ignored in favor of "--shutdown-on".
  --       Create a "time.epochs" or "time.blocks" or similar, IDK!
  -- This applies to all profiles!
  . P.generatorEpochs 3

duration30 :: Types.Profile -> Types.Profile
duration30 =
    P.shutdownOnSlot 1800
  -- TODO: dummy "generator.epochs" ignored in favor of "--shutdown-on".
  --       Create a "time.epochs" or "time.blocks" or similar, IDK!
  -- This applies to all profiles!
  . P.generatorEpochs 3

duration60 :: Types.Profile -> Types.Profile
duration60 =
    P.shutdownOnSlot 3600
  -- TODO: dummy "generator.epochs" ignored in favor of "--shutdown-on".
  --       Create a "time.epochs" or "time.blocks" or similar, IDK!
  -- This applies to all profiles!
  . P.generatorEpochs 6

duration240 :: Types.Profile -> Types.Profile
duration240 =
    P.shutdownOnSlot 14400
  -- TODO: dummy "generator.epochs" ignored in favor of "--shutdown-on".
  --       Create a "time.epochs" or "time.blocks" or similar, IDK!
  -- This applies to all profiles!
  . P.generatorEpochs 24

--------------------------------------------------------------------------------

profilesNoEraMiniature :: [Types.Profile]
profilesNoEraMiniature =
  ------------------------------------------------------------------------------
  -- ci-bench: 2|10 nodes, FixedLoaded and "--shutdown-on-block-synced 15"
  ------------------------------------------------------------------------------
  let ciBench =
          P.empty & base
        . P.uniCircle . P.loopback
        . benchDuration
        . V.clusterDefault -- TODO: "cluster" should be "null" here.
      -- Helpers by size:
      ciBench02  = ciBench & V.hosts  2
      ciBench10  = ciBench & V.hosts 10
      -- Helpers by workload:
      ciBench02Value  = ciBench02 & V.genesisVariant300
      ciBench02Plutus = ciBench02 & V.genesisVariantLast
      ciBench10Value  = ciBench10 & V.genesisVariant300
      ciBench10Plutus = ciBench10 & V.genesisVariant300
      loop     = V.plutusSaturation     . V.plutusTypeLoop
      loop2024 = V.plutusSaturation     . V.plutusTypeLoop2024
      ecdsa    = V.plutusSecpSaturation . V.plutusTypeECDSA
      schnorr  = V.plutusSecpSaturation . V.plutusTypeSchnorr
      blst     = V.plutusBlstSaturation . V.plutusTypeBLST     . P.v9Preview
  in [
  -- 2 nodes, local
    ciBench02Value  & P.name "ci-bench"                      . V.valueLocal . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOff
  , ciBench02Value  & P.name "ci-bench-lmdb"                 . V.valueLocal . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOn  . P.lmdb . P.ssdDirectory "/tmp"
  , ciBench02Value  & P.name "ci-bench-rtview"               . V.valueLocal . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOff . P.tracerRtview
  , ciBench02Value  & P.name "ci-bench-p2p"                  . V.valueLocal . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOn 
  , ciBench02Value  & P.name "ci-bench-notracer"             . V.valueLocal . P.dreps  0 . P.traceForwardingOff . P.newTracing . P.p2pOff
  , ciBench02Value  & P.name "ci-bench-drep"                 . V.valueLocal . P.dreps 10 . P.traceForwardingOn  . P.newTracing . P.p2pOff
  , ciBench02Plutus & P.name "ci-bench-plutus"               . loop         . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOff
  , ciBench02Plutus & P.name "ci-bench-plutus24"             . loop2024     . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOff
  , ciBench02Plutus & P.name "ci-bench-plutus-secp-ecdsa"    . ecdsa        . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOff
  , ciBench02Plutus & P.name "ci-bench-plutus-secp-schnorr"  . schnorr      . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOff
  , ciBench02Plutus & P.name "ci-bench-plutusv3-blst"        . blst         . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOff
  -- 10 nodes, local
  , ciBench10Value  & P.name "10"                            . V.valueLocal . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOff
  , ciBench10Value  & P.name "10-p2p"                        . V.valueLocal . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOn
  , ciBench10Value  & P.name "10-notracer"                   . V.valueLocal . P.dreps  0 . P.traceForwardingOff . P.newTracing . P.p2pOff
  , ciBench10Plutus & P.name "10-plutus"                     . loop         . P.dreps  0 . P.traceForwardingOn  . P.newTracing . P.p2pOff
  ]
  ++
  -------------------------------------------------------------------------------------
  -- 6 nodes in dense topology, reduced blocksize, miniature dataset and 30mins runtime
  -------------------------------------------------------------------------------------
  let dense =
          P.empty & base
        . P.torusDense . V.hosts 6 . P.loopback
        . V.genesisVariantLatest . P.blocksize64k . P.v9Preview . P.v8Preview
        . P.dreps 0
        . P.p2pOn
        . P.analysisSizeFull . P.analysisUnitary
        . V.clusterDefault -- TODO: "cluster" should be "null" here.
  in [
    dense & P.name "6-dense"            . V.valueCloud . duration30  . P.traceForwardingOn . P.newTracing
  , dense & P.name "6-dense-rtsprof"    . V.valueCloud . duration30  . P.traceForwardingOn . P.newTracing . P.rtsHeapProf . P.rtsEventlogged
  , dense & P.name "6-dense-1h"         . V.valueCloud . duration60  . P.traceForwardingOn . P.newTracing
  , dense & P.name "6-dense-1h-rtsprof" . V.valueCloud . duration60  . P.traceForwardingOn . P.newTracing . P.rtsHeapProf . P.rtsEventlogged
  , dense & P.name "6-dense-4h"         . V.valueCloud . duration240 . P.traceForwardingOn . P.newTracing
  , dense & P.name "6-dense-4h-rtsprof" . V.valueCloud . duration240 . P.traceForwardingOn . P.newTracing . P.rtsHeapProf . P.rtsEventlogged
  ]

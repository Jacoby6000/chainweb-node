{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

-- |
-- Module: Main
-- Copyright: Copyright © 2019 Kadena LLC.
-- License: MIT
-- Maintainer: Colin Woodbury <colin@kadena.io>
-- Stability: experimental
--
-- The fast "inner loop" of the mining process. Sits idle upon startup until
-- work is submitted.
--

module Main ( main ) where

import BasePrelude
import Control.Concurrent.Async (race)
import Control.Concurrent.STM.TMVar
import Control.Concurrent.STM.TVar (modifyTVar')
import Control.Scheduler (Comp(..), replicateWork, terminateWith, withScheduler)
import Crypto.Hash.Algorithms (SHA512t_256)
import Crypto.Hash.IO
import qualified Data.ByteArray as BA
import Data.Bytes.Put
import qualified Data.ByteString as B
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Tuple.Strict (T2(..))
import Foreign.Marshal.Alloc (allocaBytes)

-- internal modules
import Chainweb.BlockHeader
import Chainweb.Difficulty (HashTarget, encodeHashTarget)
import Chainweb.Time (Micros, Time, encodeTimeToWord64, getCurrentTimeIntegral)
import Chainweb.Utils (int, runGet)
import Chainweb.Version (ChainId, ChainwebVersion(..))

---

{- OPERATIONS

SUBMIT - Submit a hash to mine upon. Result is stored in a `TVar` (or queue?)
when finished. If the miner is currently running when SUBMIT is called, its old
job is cancelled.

POLL - Fetch the mining result of some given job (keyed by hash). Errors (with
Nothing?) if the given key has no stored result.

HALT - stop active mining. No-op if already stopped.

There's probably something elegant I can do with STM to hook in the Submit/Halt
logic. Just passing an `Async` around and killing it when new work comes in
seems dirty. Would there also be memory issues if certain low-level things are
freed correctly?

If `mine` finishes before polling occurs, the mining thread should be closed anyway.

Use `scheduler` to enable CPU-pinning and easy multicore mining? Recall
`terminateWith` which allows us to cancel other running threads when we've found
what we're looking for.

-}

data Env = Env
    { cores :: Word16
    , version :: ChainwebVersion
    , work :: TMVar BlockHeader
    , results :: TVar (HashMap (T2 ChainId BlockHeight) BlockHeader)
    }

main :: IO ()
main = pure ()

-- | Submit a new `BlockHeader` to mine (i.e. to determine a valid `Nonce`).
--
submit :: Env -> BlockHeader -> IO ()
submit (work -> w) bh = atomically $
    isEmptyTMVar w >>= bool (void $ swapTMVar w bh) (putTMVar w bh)

-- | For some `ChainId` and `BlockHeight`, have we mined a result?
--
poll :: Env -> T2 ChainId BlockHeight -> IO (Maybe BlockHeader)
poll (results -> tm) k = HM.lookup k <$> readTVarIO tm

-- | Cease mining until another `submit` call is made.
--
-- halt :: IO ()
-- halt = undefined

-- | A supervisor thread that listens for new work and supervises mining threads.
--
mining :: Env -> IO ()
mining e = do
    bh <- atomically . takeTMVar $ work e
    race newWork (go bh) >>= traverse_ miningSuccess
    mining e
  where
    -- | Wait for new work to come in from a `poll` call. `readTMVar` has the
    -- effect of "waiting patiently" and will not cook the CPU.
    newWork :: IO ()
    newWork = void . atomically . readTMVar $ work e

    -- | If the `go` call won the `race`, this functions saves the result of
    -- that successful mining. If `newWork` won the race instead, then the `go`
    -- call is automatically cancelled.
    miningSuccess :: BlockHeader -> IO ()
    miningSuccess new = do
        let key = T2 (_blockChainId new) (_blockHeight new)
        atomically $ modifyTVar' (results e) (HM.insert key new)

    comp :: Comp
    comp = case cores e of
        1 -> Seq
        n -> ParN n

    -- This `head` should be safe, since `withScheduler` can only exit if it
    -- found some legal result.
    go :: BlockHeader -> IO BlockHeader
    go bh = fmap head . withScheduler comp $ \sch ->
        replicateWork (int $ cores e) sch $
            usePowHash (version e) mine bh >>= terminateWith sch

-- | Select a hashing algorithm.
--
usePowHash :: ChainwebVersion -> (forall a. HashAlgorithm a => Proxy a -> f) -> f
usePowHash Test{} f = f $ Proxy @SHA512t_256
usePowHash TimedConsensus{} f = f $ Proxy @SHA512t_256
usePowHash PowConsensus{} f = f $ Proxy @SHA512t_256
usePowHash TimedCPM{} f = f $ Proxy @SHA512t_256
usePowHash Testnet00{} f = f $ Proxy @SHA512t_256
usePowHash Testnet01{} f = f $ Proxy @SHA512t_256

-- | This Miner makes low-level assumptions about the chainweb protocol. It may
-- break if the protocol changes.
--
-- TODO: Check the chainweb version to make sure this function can handle the
-- respective version.
--
-- TODO: Remove the `Proxy`.
--
mine :: forall a. HashAlgorithm a => Proxy a -> BlockHeader -> IO BlockHeader
mine _ h = BA.withByteArray initialTargetBytes $ \trgPtr -> do
    !ctx <- hashMutableInit @a
    bytes <- BA.copy initialBytes $ \buf ->
        allocaBytes (powSize :: Int) $ \pow -> do

            -- inner mining loop
            --
            -- We do 100000 hashes before we update the creation time.
            --
            let go 100000 !n = do
                    -- update the block creation time
                    ct <- getCurrentTimeIntegral
                    injectTime ct buf
                    go 0 n

                go !i !n = do
                    -- Compute POW hash for the nonce
                    injectNonce n buf
                    hash ctx buf pow

                    -- check whether the nonce meets the target
                    fastCheckTarget trgPtr (castPtr pow) >>= \case
                        True -> return ()
                        False -> go (succ i) (succ n)

            -- Start inner mining loop
            go (0 :: Int) $ _blockNonce h

    -- On success: deserialize and return the new BlockHeader
    runGet decodeBlockHeaderWithoutHash bytes
  where
    initialBytes :: B.ByteString
    !initialBytes = runPutS $ encodeBlockHeaderWithoutHash h

    initialTargetBytes :: B.ByteString
    !initialTargetBytes = runPutS $ encodeHashTarget target

    bufSize :: Int
    !bufSize = B.length initialBytes

    target :: HashTarget
    !target = _blockTarget h

    powSize :: Int
    !powSize = int $ hashDigestSize @a undefined

    --  Compute POW hash
    hash :: MutableContext a -> Ptr Word8 -> Ptr Word8 -> IO ()
    hash ctx buf pow = do
        hashMutableReset ctx
        BA.withByteArray ctx $ \ctxPtr -> do
            hashInternalUpdate @a ctxPtr buf (int bufSize)
            hashInternalFinalize ctxPtr (castPtr pow)
    {-# INLINE hash #-}

    -- | `injectTime` and `injectNonce` make low-level assumptions about the
    -- byte layout of a hashed `BlockHeader`. If that layout changes, these
    -- functions need to be updated. The assumption allows us to iterate on new
    -- nonces quickly.
    --
    injectTime :: Time Micros -> Ptr Word8 -> IO ()
    injectTime t buf = pokeByteOff buf 8 $ encodeTimeToWord64 t
    {-# INLINE injectTime #-}

    injectNonce :: Nonce -> Ptr Word8 -> IO ()
    injectNonce n buf = poke (castPtr buf) $ encodeNonceToWord64 n
    {-# INLINE injectNonce #-}

    -- | `PowHashNat` interprets POW hashes as unsigned 256 bit integral numbers
    -- in little endian encoding.
    --
    fastCheckTarget :: Ptr Word64 -> Ptr Word64 -> IO Bool
    fastCheckTarget !trgPtr !powPtr =
        fastCheckTargetN 3 trgPtr powPtr >>= \case
            LT -> return False
            GT -> return True
            EQ -> fastCheckTargetN 2 trgPtr powPtr >>= \case
                LT -> return False
                GT -> return True
                EQ -> fastCheckTargetN 1 trgPtr powPtr >>= \case
                    LT -> return False
                    GT -> return True
                    EQ -> fastCheckTargetN 0 trgPtr powPtr >>= \case
                        LT -> return False
                        GT -> return True
                        EQ -> return True
    {-# INLINE fastCheckTarget #-}

    fastCheckTargetN :: Int -> Ptr Word64 -> Ptr Word64 -> IO Ordering
    fastCheckTargetN n trgPtr powPtr = compare
        <$> peekElemOff trgPtr n
        <*> peekElemOff powPtr n
    {-# INLINE fastCheckTargetN #-}

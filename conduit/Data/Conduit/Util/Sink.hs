{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE CPP #-}
-- | Utilities for constructing 'Sink's. Please see "Data.Conduit.Types.Sink"
-- for more information on the base types.
module Data.Conduit.Util.Sink
    ( sinkState
    , sinkIO
    , transSink
    ) where

import Control.Monad.Trans.Resource
import Control.Monad.Trans.Class (lift)
import Data.Conduit.Types.Sink
import Control.Monad (liftM)

-- | Construct a 'Sink' with some stateful functions. This function address
-- all mutable state for you.
sinkState
    :: Resource m
    => state -- ^ initial state
    -> (state -> input -> ResourceT m (state, SinkResult input output)) -- ^ push
    -> (state -> ResourceT m output) -- ^ Close. Note that the state is not returned, as it is not needed.
    -> Sink input m output
sinkState state0 push close = Sink $ do
    istate <- newRef state0
#if DEBUG
    iclosed <- newRef False
#endif
    return SinkData
        { sinkPush = \input -> do
#if DEBUG
            False <- readRef iclosed
#endif
            state <- readRef istate
            (state', res) <- push state input
            writeRef istate state'
#if DEBUG
            case res of
                Done{} -> writeRef iclosed True
                Processing -> return ()
#endif
            return res
        , sinkClose = do
#if DEBUG
            False <- readRef iclosed
            writeRef iclosed True
#endif
            readRef istate >>= close
        }

-- | Construct a 'Sink'. Note that your push and close functions need not
-- explicitly perform any cleanup.
sinkIO :: ResourceIO m
        => IO state -- ^ resource and/or state allocation
        -> (state -> IO ()) -- ^ resource and/or state cleanup
        -> (state -> input -> m (SinkResult input output)) -- ^ push
        -> (state -> m output) -- ^ close
        -> Sink input m output
sinkIO alloc cleanup push close = Sink $ do
    (key, state) <- withIO alloc cleanup
#if DEBUG
    iclosed <- newRef False
#endif
    return SinkData
        { sinkPush = \input -> do
#if DEBUG
            False <- readRef iclosed
#endif
            res <- lift $ push state input
            case res of
                Done{} -> do
                    release key
#if DEBUG
                    writeRef iclosed True
#endif
                Processing -> return ()
            return res
        , sinkClose = do
#if DEBUG
            False <- readRef iclosed
            writeRef iclosed True
#endif
            res <- lift $ close state
            release key
            return res
        }

-- | Transform the monad a 'Sink' lives in.
transSink :: (Base m ~ Base n, Monad m)
           => (forall a. m a -> n a)
           -> Sink input m output
           -> Sink input n output
transSink f (Sink mc) =
    Sink (transResourceT f (liftM go mc))
  where
    go c = c
        { sinkPush = transResourceT f . sinkPush c
        , sinkClose = transResourceT f (sinkClose c)
        }

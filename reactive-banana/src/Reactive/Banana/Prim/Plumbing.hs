{-----------------------------------------------------------------------------
    reactive-banana
------------------------------------------------------------------------------}
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
module Reactive.Banana.Prim.Plumbing where

import           Control.Monad
import           Control.Monad.Fix
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.RWS
import qualified Control.Monad.Trans.State as State
import           Data.Function
import           Data.Functor
import           Data.Functor.Identity
import           Data.List
import           Data.Monoid
import           Data.Unique.Really
import qualified Data.Vault.Lazy           as Lazy
import           System.IO.Unsafe                  (unsafePerformIO)

import           Reactive.Banana.Prim.Cached                (HasCache(..))
import qualified Reactive.Banana.Prim.Dated        as Dated
import qualified Reactive.Banana.Prim.Dependencies as Deps
import           Reactive.Banana.Prim.Types

{-----------------------------------------------------------------------------
    Build primitive pulses and latches
------------------------------------------------------------------------------}
-- | Make 'Pulse' from evaluation function
newPulse :: String -> EvalP (Maybe a) -> Build (Pulse a)
newPulse name eval = newPulseResultP name (f <$> eval)
    where
    f Nothing  = Done
    f (Just a) = Pure a

newPulseResultP :: String -> EvalP (ResultP a) -> Build (Pulse a)
newPulseResultP name eval = unsafePerformIO $ do
    key <- Lazy.newKey
    uid <- newUnique
    return $ do
        return $ Pulse
            { evaluateP = eval
            , getValueP = Lazy.lookup key
            , writeP    = Lazy.insert key
            , uidP      = uid
            , nameP     = name
            }

-- | 'Pulse' that never fires.
neverP :: Build (Pulse a)
neverP = unsafePerformIO $ do
    uid <- newUnique
    return $ return $ Pulse
        { evaluateP = return Done
        , getValueP = const Nothing
        , writeP    = const id
        , uidP      = uid
        , nameP     = "neverP"
        }

-- | Make new 'Latch' that can be updated.
newLatch :: a -> Build (Pulse a -> Build (), Latch a)
newLatch a = unsafePerformIO $ do
    key <- Dated.newKey
    uid <- newUnique
    return $ do
        let
            write        = maybe (const mempty) (\a -> Endo . Dated.update' key a)
            latchWrite p = LatchWrite
                { evaluateL = {-# SCC evaluateL #-} write <$> readPulseP p
                , uidL      = uid
                }
            updateOn p   = P p `addChild` L (latchWrite p)
        return
            (updateOn, Latch { getValueL = Dated.findWithDefault a key })

-- | Make a new 'Latch' that caches a previous computation
cachedLatch :: Dated.Dated (Dated.Box a) -> Latch a
cachedLatch eval = unsafePerformIO $ do
    key <- Dated.newKey
    return $ Latch { getValueL = {-# SCC getValueL #-} Dated.cache key eval }

-- | Add a new output that depends on a 'Pulse'.
--
-- TODO: Return function to unregister the output again.
addOutput :: Pulse EvalO -> Build ()
addOutput p = unsafePerformIO $ do
    uid <- newUnique
    return $ do
        pos <- grOutputCount . nGraph <$> get
        let o = Output
                { evaluateO = {-# SCC evaluateO #-} maybe nop id <$> readPulseP p
                , uidO      = uid
                , positionO = pos
                }
        modify $ updateGraph $ updateOutputCount $ (+1)
        P p `addChild` O o

{-----------------------------------------------------------------------------
    Build monad - add and delete nodes from the graph
------------------------------------------------------------------------------}
runBuildIO :: Network -> BuildIO a -> IO (a, Network)
runBuildIO s1 m = {-# SCC runBuildIO #-} do
    (a,s2,liftIOLaters) <- runRWST m () s1
    sequence_ liftIOLaters          -- execute late IOs
    return (a,s2)

-- Lift a pure  Build  computation into any monad.
-- See note [BuildT]
liftBuild :: Monad m => Build a -> BuildT m a
liftBuild m = RWST $ \r s -> return . runIdentity $ runRWST m r s

readLatchB :: Latch a -> Build a
readLatchB latch = state $ \network ->
    let (a,v) = Dated.runDated (getValueL latch) (nLatchValues network)
    in  (Dated.unBox a, network { nLatchValues = v } )

readLatchBIO :: Latch a -> BuildIO a
readLatchBIO = liftBuild . readLatchB

alwaysP :: Build (Pulse ())
alwaysP = grAlwaysP . nGraph <$> get

instance (MonadFix m, Functor m) => HasCache (BuildT m) where
    retrieve key = Lazy.lookup key . grCache . nGraph <$> get
    write key a  = modify $ updateGraph $ updateCache $ Lazy.insert key a

dependOn :: Pulse child -> Pulse parent -> Build ()
dependOn child parent = (P parent) `addChild` (P child)

changeParent :: Pulse child -> Pulse parent -> Build ()
changeParent child parent =
    modify . updateGraph . updateDeps $ Deps.changeParent (P child) (P parent)

addChild :: SomeNode -> SomeNode -> Build ()
addChild parent child =
    modify . updateGraph . updateDeps $ Deps.addChild parent child

liftIOLater :: IO () -> Build ()
liftIOLater x = tell [x]

{-----------------------------------------------------------------------------
    EvalP - evaluate pulses
------------------------------------------------------------------------------}
readLatchFutureP :: Latch a -> EvalP (Future a)
readLatchFutureP latch = return $ Dated.unBox <$> getValueL latch

readPulseP :: Pulse a -> EvalP (Maybe a)
readPulseP = getValueP



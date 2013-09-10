{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
module SAWScript.REPL.Monad ( REPLState, withInitialState
                            , REP, runREP
                            , REPResult(..), successExit, failure
                            , getModulesInScope, getNamesInScope, getSharedContext, getEnvironment
                            , putNamesInScope, putEnvironment
                            , modifyNamesInScope, modifyEnvironment
                            , io, haskeline, err) where

import Prelude hiding (maybe)

import Control.Applicative (Applicative)
import Control.Monad.Trans (lift, MonadIO, liftIO)
import Control.Monad.State (StateT, runStateT, gets, modify)
import Control.Monad.Trans.Maybe (MaybeT, runMaybeT)
import Data.Foldable (foldrM)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import System.Console.Haskeline (InputT, runInputT)
import qualified System.Console.Haskeline as Haskeline

import SAWScript.AST (ModuleName,
                      Name,
                      ValidModule)
import SAWScript.BuildModules (buildModules)
import SAWScript.Builtins (BuiltinContext(..))
import SAWScript.Compiler (ErrT, runErrT', mapErrT, runCompiler)
import SAWScript.Import (preludeLoadedModules)
import SAWScript.Interpreter (InterpretEnv, buildInterpretEnv)
import SAWScript.Options (Options)
import SAWScript.ProcessFile (checkModuleWithDeps)
import SAWScript.REPL.GenerateModule as Generate
import Verifier.SAW (SharedContext)


--------------------------------- REPL state ----------------------------------

data REPLState s = REPLState { modulesInScope :: Map ModuleName ValidModule
                             , namesInScope :: Set Name
                             , sharedContext :: SharedContext s
                             , environment :: InterpretEnv s
                             }

withInitialState :: Options -> (REPLState s -> IO ()) -> IO ()
withInitialState opts f = do
  -- Build a prototype (empty) scratchpad module.
  preludeEtc <- preludeLoadedModules
  runCompiler buildModules preludeEtc $ \built ->
    runCompiler (foldrM checkModuleWithDeps Map.empty) built $ \modulesInScope -> do
      let namesInScope = Set.empty
      let scratchpadModule = Generate.scratchpad modulesInScope
      (biContext, environment) <- buildInterpretEnv opts scratchpadModule
      let sharedContext = biSharedContext biContext
      f $ REPLState { .. }


-------------------------------- REPL results ---------------------------------

data REPResult s = Success (REPLState s)
                 | SuccessExit
                 | Failure


-------------------------------- The REP monad --------------------------------

{-| The 'REP' ("read-eval-print") monad encapsulates one iteration of the
read-eval-print loop. -}
newtype REP s a =
  REP { extractInner :: MaybeT (StateT (REPLState s)
                                       (ErrT (InputT IO))) a }
  deriving (Functor, Applicative, Monad)

runREP :: forall s a.
          Haskeline.Settings IO
          -> REPLState s
          -> REP s a
          -> IO (REPResult s)
runREP haskelineSettings initialState computation = do
  unwrapped :: Either String (Maybe a, REPLState s)
            <- runInputT haskelineSettings .
                 runErrT' .
                   flip runStateT initialState .
                     runMaybeT .
                       extractInner $ computation
  case unwrapped of
    Right (Just _, finalState) -> return $ Success finalState
    Right (Nothing, _) -> return SuccessExit
    Left msg -> do
      runInputT haskelineSettings $ Haskeline.outputStrLn msg
      return Failure


-- Monadic primitives --

successExit :: REP s a
successExit = maybe $ fail "Exiting" -- message should be ignored

failure :: String -> REP s a
failure msg = REP $ lift $ lift $ fail msg

getModulesInScope :: REP s (Map ModuleName ValidModule)
getModulesInScope = state $ gets modulesInScope

getNamesInScope :: REP s (Set Name)
getNamesInScope = state $ gets namesInScope

getSharedContext :: REP s (SharedContext s)
getSharedContext = state $ gets sharedContext

getEnvironment :: REP s (InterpretEnv s)
getEnvironment = state $ gets environment

putNamesInScope :: Set Name -> REP s ()
putNamesInScope = modifyNamesInScope . const

putEnvironment :: InterpretEnv s -> REP s ()
putEnvironment = modifyEnvironment . const

modifyNamesInScope :: (Set Name -> Set Name) -> REP s ()
modifyNamesInScope f = state $ modify $ \current ->
  current { namesInScope = f (namesInScope current) }

modifyEnvironment :: (InterpretEnv s -> InterpretEnv s) -> REP s ()
modifyEnvironment f = state $ modify $ \current ->
  current { environment = f (environment current) }


-- Lifting computations --
{- 'REP' isn't a monad transformer, but inner monads can still be lifted to
it. -}

io :: IO a -> REP s a
io = REP . lift . lift . lift . liftIO

haskeline :: InputT IO a -> REP s a
haskeline = REP . lift . lift . lift

err :: ErrT IO a -> REP s a
err = REP . lift . lift . mapErrT liftIO

state :: StateT (REPLState s) (ErrT (InputT IO)) a -> REP s a
state = REP . lift

maybe :: MaybeT (StateT (REPLState s) (ErrT (InputT IO))) a -> REP s a
maybe = REP
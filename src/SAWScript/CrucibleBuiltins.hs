{-# LANGUAGE FlexibleContexts, FlexibleInstances, TypeSynonymInstances, MultiParamTypeClasses#-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-orphans #-}

{- |
Module      : $Header$
Description : Implementations of Crucible-related SAW-Script primitives.
License     : BSD3
Maintainer  : atomb
Stability   : provisional
-}
module SAWScript.CrucibleBuiltins where

import           Control.Lens
import           Control.Monad.ST
import           Control.Monad.State
import qualified Control.Monad.Trans.State.Strict as SState
import           Control.Applicative
import           Data.Foldable (for_, toList, find)
import           Data.Function
import           Data.IORef
import           Data.List
import           Data.Maybe (fromMaybe)
import           Data.String
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Text as Text
import qualified Data.Vector as V
import           Numeric.Natural
import           System.IO

import qualified Text.LLVM.AST as L
import qualified Text.LLVM.PP as L (ppType, ppSymbol)
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))
import qualified Control.Monad.Trans.Maybe as MaybeT

import qualified Data.Parameterized.Nonce as Crucible

import qualified Lang.Crucible.Config as Crucible
import qualified Lang.Crucible.CFG.Core as Crucible
  (AnyCFG(..), SomeCFG(..), TypeRepr(..), cfgHandle,
   UnitType, EmptyCtx, asBaseType, AsBaseType(..), IntrinsicType, GlobalVar,
   SymbolRepr, knownSymbol, freshGlobalVar)
import qualified Lang.Crucible.FunctionHandle as Crucible
import qualified Lang.Crucible.Simulator.ExecutionTree as Crucible
import qualified Lang.Crucible.Simulator.GlobalState as Crucible
import qualified Lang.Crucible.Simulator.OverrideSim as Crucible
import qualified Lang.Crucible.Simulator.RegMap as Crucible
import qualified Lang.Crucible.Simulator.SimError as Crucible
import qualified Lang.Crucible.Solver.Interface as Crucible hiding (mkStruct)
import qualified Lang.Crucible.Solver.SAWCoreBackend as Crucible
import qualified Lang.Crucible.Solver.SimpleBuilder as Crucible

import qualified Lang.Crucible.LLVM as Crucible
import qualified Lang.Crucible.LLVM.DataLayout as Crucible
import qualified Lang.Crucible.LLVM.MemType as Crucible
import qualified Lang.Crucible.LLVM.LLVMContext as TyCtx
import qualified Lang.Crucible.LLVM.Translation as Crucible
import qualified Lang.Crucible.LLVM.MemModel as Crucible
import qualified Lang.Crucible.LLVM.MemModel.Common as Crucible

import Lang.Crucible.Utils.MonadST
import qualified Data.Parameterized.TraversableFC as Ctx
import qualified Data.Parameterized.Context as Ctx

import Verifier.SAW.Prelude
import Verifier.SAW.SharedTerm
import Verifier.SAW.TypedAST
import Verifier.SAW.Recognizer

import SAWScript.Builtins
import SAWScript.Options
import SAWScript.Proof
import SAWScript.SolverStats
import SAWScript.TypedTerm
import SAWScript.TopLevel
import SAWScript.Value

import SAWScript.CrucibleMethodSpecIR
import SAWScript.CrucibleOverride
import SAWScript.CrucibleResolveSetupValue


type MemImpl = Crucible.MemImpl Sym Crucible.PtrWidth

show_cfg :: Crucible.AnyCFG -> String
show_cfg (Crucible.AnyCFG cfg) = show cfg


ppAbortedResult :: CrucibleContext
                -> Crucible.AbortedResult Sym
                -> Doc
ppAbortedResult cc (Crucible.AbortedExec err gp) = do
  Crucible.ppSimError err <$$> ppGlobalPair cc gp
ppAbortedResult _ (Crucible.AbortedBranch _ _ _) =
  text "Aborted branch"
ppAbortedResult _ Crucible.AbortedInfeasible =
  text "Infeasible branch"
ppAbortedResult _ (Crucible.AbortedExit ec) =
  text "Branch exited:" <+> text (show ec)

crucible_llvm_verify ::
  BuiltinContext         ->
  Options                ->
  LLVMModule             ->
  String                 ->
  [CrucibleMethodSpecIR] ->
  Bool                   ->
  CrucibleSetup ()       ->
  ProofScript SatResult  ->
  TopLevel CrucibleMethodSpecIR
crucible_llvm_verify bic opts lm nm lemmas checkSat setup tactic =
  do cc <- setupCrucibleContext bic opts lm
     let sym = ccBackend cc
     let ?lc = Crucible.llvmTypeCtx (ccLLVMContext cc)
     let nm' = fromString nm
     let llmod = ccLLVMModule cc
     def <- case find (\d -> L.defName d == nm') (L.modDefines llmod) of
                    Nothing -> fail ("Could not find function named" ++ show nm)
                    Just decl -> return decl
     let st0 = initialCrucibleSetupState cc def
     -- execute commands of the method spec
     methodSpec <- view csMethodSpec <$> execStateT setup st0
     let globals = ccGlobals cc
     let memOps = Crucible.memModelOps (ccLLVMContext cc)
     mem0 <- case Crucible.lookupGlobal (Crucible.llvmMemVar memOps) globals of
       Nothing -> fail "internal error: LLVM Memory global not found"
       Just mem0 -> return mem0
     let globals1 = Crucible.llvmGlobals (ccLLVMContext cc) mem0
     -- construct the initial state for verifications
     (args, assumes, env, globals2) <- io $ verifyPrestate cc methodSpec globals1
     -- save initial path condition
     pathstate <- io $ Crucible.getCurrentState sym
     -- run the symbolic execution
     (ret, globals3)
        <- io $ verifySimulate cc methodSpec args assumes lemmas globals2 checkSat
     -- collect the proof obligations
     asserts <- io $ verifyPoststate (biSharedContext bic) cc
                       methodSpec env globals3 ret
     -- restore initial path condition
     io $ Crucible.resetCurrentState sym pathstate
     -- attempt to verify the proof obligations
     stats <- verifyObligations cc methodSpec tactic assumes asserts
     return (methodSpec & csSolverStats .~ stats)

crucible_llvm_unsafe_assume_spec ::
  BuiltinContext   ->
  Options          ->
  LLVMModule       ->
  String          {- ^ Name of the function -} ->
  CrucibleSetup () {- ^ Boundary specification -} ->
  TopLevel CrucibleMethodSpecIR
crucible_llvm_unsafe_assume_spec bic opts lm nm setup = do
  cc <- setupCrucibleContext bic opts lm
  let ?lc = Crucible.llvmTypeCtx (ccLLVMContext cc)
  let nm' = fromString nm
  let llmod = ccLLVMModule cc
  st0 <- case initialCrucibleSetupState cc     <$> find (\d -> L.defName d == nm') (L.modDefines  llmod) <|>
              initialCrucibleSetupStateDecl cc <$> find (\d -> L.decName d == nm') (L.modDeclares llmod) of
                 Nothing -> fail ("Could not find function named" ++ show nm)
                 Just st0 -> return st0
  (view csMethodSpec) <$> execStateT setup st0

verifyObligations :: CrucibleContext
                  -> CrucibleMethodSpecIR
                  -> ProofScript SatResult
                  -> [Term]
                  -> [(String, Term)]
                  -> TopLevel SolverStats
verifyObligations cc mspec tactic assumes asserts = do
  let sym = ccBackend cc
  st     <- io $ readIORef $ Crucible.sbStateManager sym
  let sc  = Crucible.saw_ctx st
  assume <- io $ scAndList sc assumes
  let nm  = show (L.ppSymbol (mspec^.csName))
  stats <- forM asserts $ \(msg, assert) -> do
    goal   <- io $ scImplies sc assume assert
    goal'  <- io $ scAbstractExts sc (getAllExts goal) goal
    let goalname = concat [nm, " (", takeWhile (/= '\n') msg, ")"]
    r      <- evalStateT tactic (startProof (ProofGoal Universal goalname goal'))
    case r of
      Unsat stats -> return stats
      SatMulti stats vals -> do
        io $ putStrLn $ unwords ["Subgoal failed:", nm, msg]
        io $ print stats
        io $ mapM_ print vals
        io $ fail "Proof failed." -- Mirroring behavior of llvm_verify
  io $ putStrLn $ unwords ["Proof succeeded!", nm]
  return (mconcat stats)

-- | Evaluate the precondition part of a Crucible method spec:
--
-- * Allocate heap space for each 'crucible_alloc' statement.
--
-- * Record an equality precondition for each 'crucible_equal'
-- statement.
--
-- * Write to memory for each 'crucible_points_to' statement. (Writes
-- to already-initialized locations are transformed into equality
-- preconditions.)
--
-- * Evaluate the function arguments from the 'crucible_execute_func'
-- statement.
--
-- Returns a tuple of (arguments, preconditions, pointer values,
-- memory).
verifyPrestate ::
  CrucibleContext ->
  CrucibleMethodSpecIR ->
  Crucible.SymGlobalState Sym ->
  IO ([(Crucible.MemType, LLVMVal)],
      [Term],
      Map AllocIndex LLVMPtr,
      Crucible.SymGlobalState Sym)
verifyPrestate cc mspec globals = do
  let ?lc = Crucible.llvmTypeCtx (ccLLVMContext cc)

  let lvar = Crucible.llvmMemVar (Crucible.memModelOps (ccLLVMContext cc))
  let Just mem = Crucible.lookupGlobal lvar globals

  let Just memtypes = traverse TyCtx.asMemType (mspec^.csPreState.csAllocs)
  -- Allocate LLVM memory for each 'crucible_alloc'
  (env1, mem') <- runStateT (traverse (doAlloc cc) memtypes) mem
  env2 <- Map.traverseWithKey
            (\k _ -> executeFreshPointer cc k)
            (mspec^.csPreState.csFreshPointers)
  let env = Map.union env1 env2

  mem'' <- setupPrePointsTos mspec cc env (mspec^.csPreState.csPointsTos) mem'
  let globals1 = Crucible.insertGlobal lvar mem'' globals
  (globals2,cs) <- setupPrestateConditions mspec cc env globals1 (mspec^.csPreState.csConditions)
  args <- resolveArguments cc mspec env
  return (args, cs, env, globals2)


resolveArguments ::
  (?lc :: TyCtx.LLVMContext) =>
  CrucibleContext            ->
  CrucibleMethodSpecIR       ->
  Map AllocIndex LLVMPtr     ->
  IO [(Crucible.MemType, LLVMVal)]
resolveArguments cc mspec env = mapM resolveArg [0..(nArgs-1)]
  where
    nArgs = toInteger (length (mspec^.csArgs))
    tyenv = mspec^.csPreState.csAllocs
    resolveArg i =
      case Map.lookup i (mspec^.csArgBindings) of
        Just (tp, sv) -> do
          let mt = fromMaybe (error ("Expected memory type:" ++ show tp)) (TyCtx.asMemType tp)
          v <- resolveSetupVal cc env tyenv sv
          return (mt, v)
        Nothing -> fail $ unwords ["Argument", show i, "unspecified"]

--------------------------------------------------------------------------------

-- | For each points-to constraint in the pre-state section of the
-- function spec, write the given value to the address of the given
-- pointer.
setupPrePointsTos ::
  (?lc :: TyCtx.LLVMContext) =>
  CrucibleMethodSpecIR       ->
  CrucibleContext            ->
  Map AllocIndex LLVMPtr     ->
  [PointsTo]                 ->
  MemImpl                    ->
  IO MemImpl
setupPrePointsTos mspec cc env pts mem0 = foldM go mem0 pts
  where
    tyenv = mspec^.csPreState.csAllocs

    go :: MemImpl -> PointsTo -> IO MemImpl
    go mem (PointsTo ptr val) =
      do val' <- resolveSetupVal cc env tyenv val
         ptr' <- resolveSetupVal cc env tyenv ptr
         ptr'' <- case ptr' of
           Crucible.LLVMValPtr blk end off -> return (Crucible.LLVMPtr blk end off)
           _ -> fail "Non-pointer value found in points-to assertion"
         -- In case the types are different (from crucible_points_to_untyped)
         -- then the store type should be determined by the rhs.
         memTy <- typeOfSetupValue cc tyenv val
         storTy <- Crucible.toStorableType memTy
         let sym = ccBackend cc
         mem' <- Crucible.storeRaw sym mem ptr'' storTy val'
         return mem'

setupPrestateConditions ::
  (?lc :: TyCtx.LLVMContext)  =>
  CrucibleMethodSpecIR        ->
  CrucibleContext             ->
  Map AllocIndex LLVMPtr      ->
  Crucible.SymGlobalState Sym ->
  [SetupCondition]            ->
  IO (Crucible.SymGlobalState Sym, [Term])
setupPrestateConditions mspec cc env = aux []
  where
    tyenv = mspec^.csPreState.csAllocs

    aux acc globals [] = return (globals, acc)

    aux acc globals (SetupCond_Equal val1 val2 : xs) =
      do val1' <- resolveSetupVal cc env tyenv val1
         val2' <- resolveSetupVal cc env tyenv val2
         t     <- assertEqualVals cc val1' val2'
         aux (t:acc) globals xs

    aux acc globals (SetupCond_Pred tm : xs) =
      aux (ttTerm tm : acc) globals xs

    aux acc globals (SetupCond_Ghost var val : xs) =
      aux acc (Crucible.insertGlobal var val globals) xs

--------------------------------------------------------------------------------

-- | Create a SAWCore formula asserting that two 'LLVMVal's are equal.
assertEqualVals ::
  CrucibleContext ->
  LLVMVal ->
  LLVMVal ->
  IO Term
assertEqualVals cc v1 v2 =
  Crucible.toSC (ccBackend cc) =<< equalValsPred cc v1 v2

--------------------------------------------------------------------------------

asSAWType :: SharedContext
          -> Crucible.Type
          -> IO Term
asSAWType sc t = case Crucible.typeF t of
  Crucible.Bitvector bytes -> scBitvector sc (fromInteger (Crucible.bytesToBits bytes))
  Crucible.Float           -> scGlobalDef sc (fromString "Prelude.Float")  -- FIXME??
  Crucible.Double          -> scGlobalDef sc (fromString "Prelude.Double") -- FIXME??
  Crucible.Array sz s ->
    do s' <- asSAWType sc s
       sz_tm <- scNat sc (fromIntegral sz)
       scVecType sc sz_tm s'
  Crucible.Struct flds ->
    do flds' <- mapM (asSAWType sc . (^. Crucible.fieldVal)) $ V.toList flds
       scTupleType sc flds'

memTypeToType :: Crucible.MemType -> Maybe Crucible.Type
memTypeToType mt = Crucible.mkType <$> go mt
  where
  go (Crucible.IntType w) = Just (Crucible.Bitvector (Crucible.bitsToBytes w))
  -- Pointers can't be converted to SAWCore, so no need to translate
  -- their types.
  go (Crucible.PtrType _) = Nothing
  go Crucible.FloatType = Just Crucible.Float
  go Crucible.DoubleType = Just Crucible.Double
  go (Crucible.ArrayType n et) = Crucible.Array (fromIntegral n) <$> memTypeToType et
  go (Crucible.VecType n et) = Crucible.Array (fromIntegral n) <$> memTypeToType et
  go (Crucible.StructType si) =
    Crucible.Struct <$> mapM goField (Crucible.siFields si)
  go Crucible.MetadataType  = Nothing
  goField f =
    Crucible.mkField (Crucible.toBytes (Crucible.fiOffset f)) <$>
                     memTypeToType (Crucible.fiType f) <*>
                     pure (Crucible.toBytes (Crucible.fiPadding f))

--------------------------------------------------------------------------------

-- | Allocate space on the LLVM heap to store a value of the given
-- type. Returns the pointer to the allocated memory.
doAlloc ::
  (?lc :: TyCtx.LLVMContext) =>
  CrucibleContext            ->
  Crucible.MemType           ->
  StateT MemImpl IO LLVMPtr
doAlloc cc tp = StateT $ \mem ->
  do let sym = ccBackend cc
     let dl = TyCtx.llvmDataLayout ?lc
     sz <- Crucible.bvLit sym Crucible.ptrWidth (fromIntegral (Crucible.memTypeSize dl tp))
     Crucible.mallocRaw sym mem sz

--------------------------------------------------------------------------------

ppGlobalPair :: CrucibleContext
             -> Crucible.GlobalPair Sym a
             -> Doc
ppGlobalPair cc gp =
  let memOps = Crucible.memModelOps (ccLLVMContext cc)
      sym = ccBackend cc
      globals = gp ^. Crucible.gpGlobals in
  case Crucible.lookupGlobal (Crucible.llvmMemVar memOps) globals of
    Nothing -> text "LLVM Memory global variable not initialized"
    Just mem -> Crucible.ppMem sym mem


--------------------------------------------------------------------------------

registerOverride ::
  (?lc :: TyCtx.LLVMContext) =>
  CrucibleContext            ->
  Crucible.SimContext Crucible.SAWCruciblePersonality Sym  ->
  [CrucibleMethodSpecIR]     ->
  Crucible.OverrideSim Crucible.SAWCruciblePersonality Sym rtp args ret ()
registerOverride cc _ctx cs = do
  let sym = ccBackend cc
      cfg = Crucible.simConfig (ccSimContext cc)
  sc <- Crucible.saw_ctx <$> liftIO (readIORef (Crucible.sbStateManager sym))
  let s@(L.Symbol fsym) = (head cs)^.csName
      llvmctx = ccLLVMContext cc
  liftIO $ do
    verb <- Crucible.getConfigValue Crucible.verbosity cfg
    when (verb >= 2) $ putStrLn $ "Registering override for `" ++ fsym ++ "`"
  case Map.lookup s (llvmctx ^. Crucible.symbolMap) of
    -- LLVMHandleInfo constructor has two existential type arguments,
    -- which are bound here. h :: FnHandle args' ret'
    Just (Crucible.LLVMHandleInfo _decl' h) -> do
      -- TODO: check that decl' matches (csDefine cs)
      let retType = Crucible.handleReturnType h
      Crucible.bindFnHandle h
        $ Crucible.UseOverride
        $ Crucible.mkOverride'
            (Crucible.handleName h)
            retType
            (methodSpecHandler sc cc cs retType)
    Nothing -> fail $ "Can't find declaration for `" ++ fsym ++ "`."

--------------------------------------------------------------------------------

verifySimulate ::
  (?lc :: TyCtx.LLVMContext)    =>
  CrucibleContext               ->
  CrucibleMethodSpecIR          ->
  [(Crucible.MemType, LLVMVal)] ->
  [Term]                        ->
  [CrucibleMethodSpecIR]        ->
  Crucible.SymGlobalState Sym   ->
  Bool                          ->
  IO (Maybe (Crucible.MemType, LLVMVal), Crucible.SymGlobalState Sym)
verifySimulate cc mspec args assumes lemmas globals checkSat =
  do let nm = mspec^.csName
     case Map.lookup nm (Crucible.cfgMap (ccLLVMModuleTrans cc)) of
       Nothing -> fail $ unwords ["function", show nm, "not found"]
       Just (Crucible.AnyCFG cfg) ->
         do let h   = Crucible.cfgHandle cfg
                rty = Crucible.handleReturnType h
            args' <- prepareArgs (Crucible.handleArgTypes h) (map snd args)
            let simCtx = ccSimContext cc
                conf = Crucible.simConfig simCtx
            simCtx' <- flip SState.execStateT simCtx $
                       Crucible.setConfigValue Crucible.sawCheckPathSat conf checkSat
            let simSt = Crucible.initSimState simCtx' globals Crucible.defaultErrorHandler
            res <-
              Crucible.runOverrideSim simSt rty $
                do mapM_ (registerOverride cc simCtx')
                         (groupOn (view csName) lemmas)
                   liftIO $ do
                     preds <- mapM (resolveSAWPred cc) assumes
                     mapM_ (Crucible.addAssumption sym) preds
                   Crucible.regValue <$> (Crucible.callCFG cfg args')
            case res of
              Crucible.FinishedExecution _ pr ->
                do Crucible.GlobalPair retval globals1 <-
                     case pr of
                       Crucible.TotalRes gp -> return gp
                       Crucible.PartialRes _ gp _ ->
                         do putStrLn "Symbolic simulation failed along some paths!"
                            return gp
                   let ret_ty = mspec^.csRet
                   let ret_ty' = fromMaybe (error ("Expected return type:" ++ show ret_ty))
                                 (TyCtx.liftRetType ret_ty)
                   retval' <- case ret_ty' of
                     Nothing -> return Nothing
                     Just ret_mt ->
                       do v <- Crucible.packMemValue sym
                                 (fromMaybe (error ("Expected storable type:" ++ show ret_ty))
                                      (Crucible.toStorableType ret_mt))
                                 (Crucible.regType  retval)
                                 (Crucible.regValue retval)
                          return (Just (ret_mt, v))

                   return (retval', globals1)

              Crucible.AbortedResult _ ar ->
                do let resultDoc = ppAbortedResult cc ar
                   fail $ unlines [ "Symbolic execution failed."
                                  , show resultDoc
                                  ]

  where
    sym = ccBackend cc
    prepareArgs ::
      Ctx.Assignment Crucible.TypeRepr xs ->
      [LLVMVal] ->
      IO (Crucible.RegMap Sym xs)
    prepareArgs ctx x =
      Crucible.RegMap <$>
      Ctx.traverseWithIndex (\idx tr ->
        do a <- Crucible.unpackMemValue sym (x !! Ctx.indexVal idx)
           v <- Crucible.coerceAny sym tr a
           return (Crucible.RegEntry tr v))
      ctx

--------------------------------------------------------------------------------

processPostconditions ::
  (?lc :: TyCtx.LLVMContext) =>
  CrucibleContext                 {- ^ simulator context         -} ->
  Map AllocIndex Crucible.SymType {- ^ type env                  -} ->
  Map AllocIndex LLVMPtr          {- ^ pointer environment       -} ->
  Crucible.SymGlobalState Sym     {- ^ final global variables    -} ->
  [SetupCondition]                {- ^ postconditions            -} ->
  IO [(String, Term)]
processPostconditions cc tyenv env globals = traverse verifyPostCond
  where
    verifyPostCond :: SetupCondition -> IO (String, Term)
    verifyPostCond (SetupCond_Equal val1 val2) =
      do val1' <- resolveSetupVal cc env tyenv val1
         val2' <- resolveSetupVal cc env tyenv val2
         g <- assertEqualVals cc val1' val2'
         return ("equality assertion", g)
    verifyPostCond (SetupCond_Pred tm) =
      return ("predicate assertion", ttTerm tm)
    verifyPostCond (SetupCond_Ghost var val) =
      do sc <- Crucible.saw_ctx <$> readIORef (Crucible.sbStateManager (ccBackend cc))
         v  <- case Crucible.lookupGlobal var globals of
                 Nothing   -> scBool sc False
                 Just term -> scEq sc (ttTerm term) (ttTerm val)
         return ("ghost assertion", v)


------------------------------------------------------------------------

-- | For each points-to statement from the postcondition section of a
-- function spec, read the memory value through the given pointer
-- (lhs) and match the value against the given pattern (rhs).
-- Statements are processed in dependency order: a points-to statement
-- cannot be executed until bindings for any/all lhs variables exist.
processPostPointsTos ::
  (?lc :: TyCtx.LLVMContext) =>
  SharedContext                   {- ^ term construction context -} ->
  CrucibleContext                 {- ^ simulator context         -} ->
  Map AllocIndex Crucible.SymType {- ^ type env                  -} ->
  Map AllocIndex LLVMPtr          {- ^ pointer environment       -} ->
  MemImpl                         {- ^ LLVM heap                 -} ->
  [PointsTo]                      {- ^ points-to postconditions  -} ->
  IO [(String, Term)]             {- ^ equality constraints      -}
processPostPointsTos sc cc tyenv env0 mem conds0 =
  evalStateT (go False [] conds0) env0
  where
    sym = ccBackend cc

    go ::
      Bool       {- progress indicator -} ->
      [PointsTo] {- delayed conditions -} ->
      [PointsTo] {- queued conditions  -} ->
      StateT (Map AllocIndex LLVMPtr) IO [(String, Term)]

    -- all conditions processed, success
    go _ [] [] = return []

    -- not all conditions processed, no progress, failure
    go False _delayed [] = fail "processPostconditions: unprocessed conditions"

    -- not all conditions processed, progress made, resume delayed conditions
    go True delayed [] = go False [] delayed

    -- progress the next precondition in the work queue
    go progress delayed (c:cs) =
      do ready <- checkPointsTo c
         if ready then
           do goals1 <- verifyPostCond c
              goals2 <- go True delayed cs
              return (goals1 ++ goals2)
           else go progress (c:delayed) cs

    -- determine if a precondition is ready to be checked
    checkPointsTo :: PointsTo -> StateT (Map AllocIndex LLVMPtr) IO Bool
    checkPointsTo (PointsTo p _) = checkSetupValue p

    checkSetupValue :: SetupValue -> StateT (Map AllocIndex LLVMPtr) IO Bool
    checkSetupValue v =
      do m <- get
         return (all (`Map.member` m) (setupVars v))

    -- Compute the set of variable identifiers in a 'SetupValue'
    setupVars :: SetupValue -> Set AllocIndex
    setupVars v =
      case v of
        SetupVar    i  -> Set.singleton i
        SetupStruct xs -> foldMap setupVars xs
        SetupArray  xs -> foldMap setupVars xs
        SetupElem x _  -> setupVars x
        SetupField x _ -> setupVars x
        SetupTerm   _  -> Set.empty
        SetupNull      -> Set.empty
        SetupGlobal _  -> Set.empty

    verifyPostCond :: PointsTo -> StateT (Map AllocIndex LLVMPtr) IO [(String, Term)]
    verifyPostCond (PointsTo lhs val) =
      do env <- get
         lhs' <- liftIO $ resolveSetupVal cc env tyenv lhs
         ptr <- case lhs' of
           Crucible.LLVMValPtr blk end off -> return (Crucible.LLVMPtr blk end off)
           _ -> fail "Non-pointer value found in points-to assertion"
         -- In case the types are different (from crucible_points_to_untyped)
         -- then the load type should be determined by the rhs.
         memTy <- liftIO $ typeOfSetupValue cc tyenv val
         storTy <- Crucible.toStorableType memTy
         x <- liftIO $ Crucible.loadRaw sym mem ptr storTy
         gs <- match sc cc tyenv x val
         return [ ("points-to assertion", g) | g <- gs ]

--------------------------------------------------------------------------------

-- | Match an 'LLVMVal' with a 'SetupValue', producing a list of
-- equality constraints, and accumulating bindings for
-- previously-unbound 'SetupVar's on the right-hand side.
match ::
  SharedContext   {- ^ term construction context -} ->
  CrucibleContext {- ^ simulator context         -} ->
  Map AllocIndex Crucible.SymType {- ^ type env  -} ->
  LLVMVal       ->
  SetupValue    ->
  StateT (Map AllocIndex LLVMPtr) IO [Term]
match _sc cc _tyenv x@(Crucible.LLVMValPtr blk off end) (SetupVar i) =
  do env <- get
     case Map.lookup i env of
       Just y  -> do t <- liftIO $ assertEqualVals cc x (ptrToVal y)
                     return [t]
       Nothing -> do put (Map.insert i (Crucible.LLVMPtr blk off end) env)
                     return []
match sc cc tyenv (Crucible.LLVMValStruct fields) (SetupStruct vs) =
  matchList sc cc tyenv (map snd (V.toList fields)) vs
match sc cc tyenv (Crucible.LLVMValArray _ty xs) (SetupArray vs) =
  matchList sc cc tyenv (V.toList xs) vs
match sc cc _tyenv x (SetupTerm tm) =
  do tVal <- liftIO $ valueToSC (ccBackend cc) x
     g <- liftIO $ scEq sc tVal (ttTerm tm)
     return [g]
match _sc cc tyenv x v =
  do env <- get
     v' <- liftIO $ resolveSetupVal cc env tyenv v
     g <- liftIO $ assertEqualVals cc x v'
     return [g]

matchList ::
  SharedContext   {- ^ term construction context -} ->
  CrucibleContext {- ^ simulator context         -} ->
  Map AllocIndex Crucible.SymType {- ^ type env  -} ->
  [LLVMVal]                                         ->
  [SetupValue]                                      ->
  StateT (Map AllocIndex LLVMPtr) IO [Term]
matchList sc cc tyenv xs vs = -- precondition: length xs = length vs
  do gs <- concat <$> sequence [ match sc cc tyenv x v | (x, v) <- zip xs vs ]
     g <- liftIO $ scAndList sc gs
     return (if null gs then [] else [g])

-- | Build a conjunction from a list of boolean terms.
scAndList :: SharedContext -> [Term] -> IO Term
scAndList sc []       = scBool sc True
scAndList sc (x : xs) = foldM (scAnd sc) x xs

--------------------------------------------------------------------------------

verifyPoststate ::
  (?lc :: TyCtx.LLVMContext) =>
  SharedContext                     {- ^ saw core context                             -} ->
  CrucibleContext                   {- ^ crucible context                             -} ->
  CrucibleMethodSpecIR              {- ^ specification                                -} ->
  Map AllocIndex LLVMPtr            {- ^ allocation substitution                      -} ->
  Crucible.SymGlobalState Sym       {- ^ global variables                             -} ->
  Maybe (Crucible.MemType, LLVMVal) {- ^ optional return value                        -} ->
  IO [(String, Term)]               {- ^ generated labels and verification conditions -}
verifyPoststate sc cc mspec env0 globals ret =

  do let terms0 = Map.fromList
           [ (ecVarIndex ec, ttTerm tt)
           | tt <- mspec^.csPreState.csFreshVars
           , let Just ec = asExtCns (ttTerm tt) ]

     let initialFree = Set.fromList (map (termId . ttTerm)
                                    (view (csPostState.csFreshVars) mspec))
     matchPost <-
          runOverrideMatcher sym globals env0 terms0 initialFree $
           do matchResult
              learnCond sc cc mspec PostState (mspec ^. csPostState)

     st <- case matchPost of
             Left err      -> fail (show err)
             Right (_, st) -> return st
     for_ (view osAsserts st) $ \(p, r) ->
       Crucible.sbAddAssertion (ccBackend cc) p r

     obligations <- Crucible.getProofObligations (ccBackend cc)
     Crucible.setProofObligations (ccBackend cc) []
     mapM verifyObligation obligations

  where
    sym = ccBackend cc

    verifyObligation (_, (Crucible.Assertion _ _ Nothing)) =
      fail "Found an assumption in final proof obligation list"
    verifyObligation (hyps, (Crucible.Assertion _ concl (Just err))) = do
      hypTerm    <- scAndList sc =<< mapM (Crucible.toSC sym) hyps
      conclTerm  <- Crucible.toSC sym concl
      obligation <- scImplies sc hypTerm conclTerm
      return ("safety assertion: " ++ Crucible.simErrorReasonMsg err, obligation)

    matchResult =
      case (ret, mspec ^. csRetValue) of
        (Nothing     , Just _ )     -> fail "verifyPoststate: unexpected crucible_return specification"
        (Just _      , Nothing)     -> fail "verifyPoststate: missing crucible_return specification"
        (Nothing     , Nothing)     -> return ()
        (Just (rty,r), Just expect) -> matchArg sc cc PostState r rty expect


--------------------------------------------------------------------------------

setupCrucibleContext :: BuiltinContext -> Options -> LLVMModule -> TopLevel CrucibleContext
setupCrucibleContext bic opts (LLVMModule _ llvm_mod) = do
  halloc <- getHandleAlloc
  io $ do
      (ctx, mtrans) <- stToIO $ Crucible.translateModule halloc llvm_mod
      let gen = Crucible.globalNonceGenerator
      let sc  = biSharedContext bic
      let verbosity = simVerbose opts
      cfg <- Crucible.initialConfig verbosity Crucible.sawOptions
      sym <- Crucible.newSAWCoreBackend sc gen cfg
      let bindings = Crucible.fnBindingsFromList []
      let simctx   = Crucible.initSimContext sym intrinsics cfg halloc stdout
                        bindings Crucible.SAWCruciblePersonality
      mem <- Crucible.initializeMemory sym ctx llvm_mod
      let globals  = Crucible.llvmGlobals ctx mem

      let setupMem :: Crucible.OverrideSim Crucible.SAWCruciblePersonality Sym
                       (Crucible.RegEntry Sym Crucible.UnitType)
                       Crucible.EmptyCtx Crucible.UnitType (Crucible.RegValue Sym Crucible.UnitType)
          setupMem = do
             -- register the callable override functions
             _llvmctx' <- execStateT Crucible.register_llvm_overrides ctx

             -- initialize LLVM global variables
             _ <- case Crucible.initMemoryCFG mtrans of
                     Crucible.SomeCFG initCFG ->
                       Crucible.callCFG initCFG Crucible.emptyRegMap

             -- register all the functions defined in the LLVM module
             mapM_ Crucible.registerModuleFn $ Map.toList $ Crucible.cfgMap mtrans

      let simSt = Crucible.initSimState simctx globals Crucible.defaultErrorHandler
      res <- Crucible.runOverrideSim simSt Crucible.UnitRepr setupMem
      (globals', simctx') <-
          case res of
            Crucible.FinishedExecution st (Crucible.TotalRes gp) -> return (gp^.Crucible.gpGlobals, st)
            Crucible.FinishedExecution st (Crucible.PartialRes _ gp _) -> return (gp^.Crucible.gpGlobals, st)
            Crucible.AbortedResult _ _ -> fail "Memory initialization failed!"
      return $
         CrucibleContext{ ccLLVMContext = ctx
                        , ccLLVMModuleTrans = mtrans
                        , ccLLVMModule = llvm_mod
                        , ccBackend = sym
                        , ccEmptyMemImpl = mem
                        , ccSimContext = simctx'
                        , ccGlobals = globals'
                        }

--------------------------------------------------------------------------------

setupArg :: SharedContext
         -> Sym
         -> IORef (Seq (ExtCns Term))
         -> Crucible.TypeRepr tp
         -> IO (Crucible.RegEntry Sym tp)
setupArg sc sym ecRef tp =
  case Crucible.asBaseType tp of
    Crucible.AsBaseType btp -> do
       sc_tp <- Crucible.baseSCType sc btp
       i     <- scFreshGlobalVar sc
       ecs   <- readIORef ecRef
       let len = Seq.length ecs
       let ec = EC i ("arg_"++show len) sc_tp
       writeIORef ecRef (ecs Seq.|> ec)
       t     <- scFlatTermF sc (ExtCns ec)
       elt   <- Crucible.bindSAWTerm sym btp t
       return (Crucible.RegEntry tp elt)

    Crucible.NotBaseType ->
      fail $ unwords ["Crucible extraction currently only supports Crucible base types", show tp]

setupArgs :: SharedContext
          -> Sym
          -> Crucible.FnHandle init ret
          -> IO (Seq (ExtCns Term), Crucible.RegMap Sym init)
setupArgs sc sym fn = do
  ecRef  <- newIORef Seq.empty
  regmap <- Crucible.RegMap <$> Ctx.traverseFC (setupArg sc sym ecRef) (Crucible.handleArgTypes fn)
  ecs    <- readIORef ecRef
  return (ecs, regmap)

--------------------------------------------------------------------------------

extractFromCFG :: SharedContext -> CrucibleContext -> Crucible.AnyCFG -> IO TypedTerm
extractFromCFG sc cc (Crucible.AnyCFG cfg) = do
  let sym = ccBackend cc
  let h   = Crucible.cfgHandle cfg
  (ecs, args) <- setupArgs sc sym h
  let simCtx = ccSimContext cc
  let globals = ccGlobals cc
  let simSt = Crucible.initSimState simCtx globals Crucible.defaultErrorHandler
  res  <- Crucible.runOverrideSim simSt (Crucible.handleReturnType h)
             (Crucible.regValue <$> (Crucible.callCFG cfg args))
  case res of
    Crucible.FinishedExecution _ pr -> do
        gp <- case pr of
                Crucible.TotalRes gp -> return gp
                Crucible.PartialRes _ gp _ -> do
                  putStrLn "Symbolic simulation failed along some paths!"
                  return gp
        t <- Crucible.asSymExpr
                   (gp^.Crucible.gpValue)
                   (Crucible.toSC sym)
                   (fail $ unwords ["Unexpected return type:", show (Crucible.regType (gp^.Crucible.gpValue))])
        t' <- scAbstractExts sc (toList ecs) t
        tt <- mkTypedTerm sc t'
        return tt
    Crucible.AbortedResult _ ar -> do
      let resultDoc = ppAbortedResult cc ar
      fail $ unlines [ "Symbolic execution failed."
                     , show resultDoc
                     ]

--------------------------------------------------------------------------------

extract_crucible_llvm :: BuiltinContext -> Options -> LLVMModule -> String -> TopLevel TypedTerm
extract_crucible_llvm bic opts lm fn_name = do
  cc <- setupCrucibleContext bic opts lm
  case Map.lookup (fromString fn_name) (Crucible.cfgMap (ccLLVMModuleTrans cc)) of
    Nothing  -> fail $ unwords ["function", fn_name, "not found"]
    Just cfg -> io $ extractFromCFG (biSharedContext bic) cc cfg

load_llvm_cfg :: BuiltinContext -> Options -> LLVMModule -> String -> TopLevel Crucible.AnyCFG
load_llvm_cfg bic opts lm fn_name = do
  cc <- setupCrucibleContext bic opts lm
  case Map.lookup (fromString fn_name) (Crucible.cfgMap (ccLLVMModuleTrans cc)) of
    Nothing  -> fail $ unwords ["function", fn_name, "not found"]
    Just cfg -> return cfg

--------------------------------------------------------------------------------

diffMemTypes ::
  Crucible.MemType ->
  Crucible.MemType ->
  [([Maybe Int], Crucible.MemType, Crucible.MemType)]
diffMemTypes x0 y0 =
  case (x0, y0) of
    (Crucible.IntType x, Crucible.IntType y) | x == y -> []
    (Crucible.FloatType, Crucible.FloatType) -> []
    (Crucible.DoubleType, Crucible.DoubleType) -> []
    (Crucible.PtrType{}, Crucible.PtrType{}) -> []
    (Crucible.IntType 64, Crucible.PtrType{}) -> []
    (Crucible.PtrType{}, Crucible.IntType 64) -> []
    (Crucible.ArrayType xn xt, Crucible.ArrayType yn yt)
      | xn == yn ->
        [ (Nothing : path, l , r) | (path, l, r) <- diffMemTypes xt yt ]
    (Crucible.VecType xn xt, Crucible.VecType yn yt)
      | xn == yn ->
        [ (Nothing : path, l , r) | (path, l, r) <- diffMemTypes xt yt ]
    (Crucible.StructType x, Crucible.StructType y)
      | Crucible.siIsPacked x == Crucible.siIsPacked y
        && V.length (Crucible.siFields x) == V.length (Crucible.siFields y) ->
          let xts = Crucible.siFieldTypes x
              yts = Crucible.siFieldTypes y
          in diffMemTypesList 1 (V.toList (V.zip xts yts))
    _ -> [([], x0, y0)]

diffMemTypesList ::
  Int ->
  [(Crucible.MemType, Crucible.MemType)] ->
  [([Maybe Int], Crucible.MemType, Crucible.MemType)]
diffMemTypesList _ [] = []
diffMemTypesList i ((x, y) : ts) =
  [ (Just i : path, l , r) | (path, l, r) <- diffMemTypes x y ]
  ++ diffMemTypesList (i+1) ts

showMemTypeDiff :: ([Maybe Int], Crucible.MemType, Crucible.MemType) -> String
showMemTypeDiff (path, l, r) = showPath path
  where
    showStep Nothing  = "element type"
    showStep (Just i) = "field " ++ show i
    showPath []       = ""
    showPath [x]      = unlines [showStep x ++ ":", "  " ++ show l, "  " ++ show r]
    showPath (x : xs) = showStep x ++ " -> " ++ showPath xs

-- | Succeed if the types have compatible memory layouts. Otherwise,
-- fail with a detailed message indicating how the types differ.
checkMemTypeCompatibility ::
  Crucible.MemType ->
  Crucible.MemType ->
  CrucibleSetup ()
checkMemTypeCompatibility t1 t2 =
  case diffMemTypes t1 t2 of
    [] -> return ()
    diffs ->
      fail $ unlines $
      ["types not memory-compatible:", show t1, show t2]
      ++ map showMemTypeDiff diffs

--------------------------------------------------------------------------------
-- Setup builtins

getCrucibleContext :: CrucibleSetup CrucibleContext
getCrucibleContext = view csCrucibleContext <$> get

currentState :: Lens' CrucibleSetupState StateSpec
currentState f x = case x^.csPrePost of
  PreState  -> csMethodSpec (csPreState f) x
  PostState -> csMethodSpec (csPostState f) x
  
addPointsTo :: PointsTo -> CrucibleSetup ()
addPointsTo pt = currentState.csPointsTos %= (pt : )

addCondition :: SetupCondition
             -> CrucibleSetup ()
addCondition cond = currentState.csConditions %= (cond : )

-- | Returns logical type of actual type if it is an array or primitive
-- type, or an appropriately-sized bit vector for pointer types.
logicTypeOfActual :: Crucible.DataLayout -> SharedContext -> Crucible.MemType
                  -> IO (Maybe Term)
logicTypeOfActual _ sc (Crucible.IntType w) = Just <$> logicTypeForInt sc w
logicTypeOfActual _ sc Crucible.FloatType = Just <$> scPrelude_Float sc
logicTypeOfActual _ sc Crucible.DoubleType = Just <$> scPrelude_Double sc
logicTypeOfActual dl sc (Crucible.ArrayType n ty) = do
  melTyp <- logicTypeOfActual dl sc ty
  case melTyp of
    Just elTyp -> do
      lTm <- scNat sc (fromIntegral n)
      Just <$> scVecType sc lTm elTyp
    Nothing -> return Nothing
logicTypeOfActual dl sc (Crucible.PtrType _) = do
  bType <- scBoolType sc
  lTm <- scNat sc (fromIntegral (Crucible.ptrBitwidth dl))
  Just <$> scVecType sc lTm bType
logicTypeOfActual dl sc (Crucible.StructType si) = do
  let memtypes = V.toList (Crucible.siFieldTypes si)
  melTyps <- traverse (logicTypeOfActual dl sc) memtypes
  case sequence melTyps of
    Just elTyps -> Just <$> scTupleType sc elTyps
    Nothing -> return Nothing
logicTypeOfActual _ _ _ = return Nothing


logicTypeForInt :: SharedContext -> Natural -> IO Term
logicTypeForInt sc w =
  do bType <- scBoolType sc
     lTm <- scNat sc (fromIntegral w)
     scVecType sc lTm bType


-- | Generate a fresh variable term. The name will be used when
-- pretty-printing the variable in debug output.
crucible_fresh_var ::
  BuiltinContext          {- ^ context          -} ->
  Options                 {- ^ options          -} ->
  String                  {- ^ variable name    -} ->
  L.Type                  {- ^ variable type    -} ->
  CrucibleSetup TypedTerm {- ^ fresh typed term -}
crucible_fresh_var bic _opts name lty = do
  lty' <- memTypeForLLVMType bic lty
  cctx <- getCrucibleContext
  let sc = biSharedContext bic
  let lc = ccLLVMContext cctx
  let dl = TyCtx.llvmDataLayout (Crucible.llvmTypeCtx lc)
  mty <- liftIO $ logicTypeOfActual dl sc lty'
  case mty of
    Nothing -> fail $ "Unsupported type in crucible_fresh_var: " ++ show (L.ppType lty)
    Just ty -> freshVariable sc name ty

-- | Allocated a fresh variable and record this allocation in the
-- setup state.
freshVariable ::
  SharedContext {- ^ shared context -} ->
  String        {- ^ variable name  -} ->
  Term          {- ^ variable type  -} ->
  CrucibleSetup TypedTerm
freshVariable sc name ty =
  do tt <- liftIO (mkTypedTerm sc =<< scFreshGlobal sc name ty)
     currentState . csFreshVars %= cons tt
     return tt


-- | Use the given LLVM type to compute a setup value that
-- covers expands all of the struct, array, and pointer
-- components of the LLVM type. Only the primitive types
-- suitable for import as SAW core terms will be matched
-- against fresh variables.
crucible_fresh_expanded_val ::
  BuiltinContext {- ^ context                -} ->
  Options        {- ^ options                -} ->
  L.Type         {- ^ variable type          -} ->
  CrucibleSetup SetupValue
                 {- ^ elaborated setup value -}
crucible_fresh_expanded_val bic _opts lty =
  do cctx <- getCrucibleContext
     let sc = biSharedContext bic
         lc = ccLLVMContext cctx
     let ?lc = Crucible.llvmTypeCtx lc
     lty' <- memTypeForLLVMType bic lty
     constructExpandedSetupValue sc lty'


memTypeForLLVMType :: BuiltinContext -> L.Type -> CrucibleSetup Crucible.MemType
memTypeForLLVMType _bic lty =
  do cctx <- getCrucibleContext
     let lc = ccLLVMContext cctx
     let ?lc = Crucible.llvmTypeCtx lc
     case TyCtx.liftMemType lty of
       Just m -> return m
       Nothing -> fail ("unsupported type: " ++ show (L.ppType lty))

symTypeForLLVMType :: BuiltinContext -> L.Type -> CrucibleSetup Crucible.SymType
symTypeForLLVMType _bic lty =
  do cctx <- getCrucibleContext
     let lc = ccLLVMContext cctx
     let ?lc = Crucible.llvmTypeCtx lc
     case TyCtx.liftType lty of
       Just m -> return m
       Nothing -> fail ("unsupported type: " ++ show (L.ppType lty))

-- | See 'crucible_fresh_expanded_val'
--
-- This is the recursively-called worker function.
constructExpandedSetupValue ::
  (?lc::TyCtx.LLVMContext) =>
  SharedContext    {- ^ shared context             -} ->
  Crucible.MemType {- ^ LLVM mem type              -} ->
  CrucibleSetup SetupValue
                   {- ^ fresh expanded setup value -}
constructExpandedSetupValue sc t =
  case t of
    Crucible.IntType w ->
      do ty <- liftIO (logicTypeForInt sc w)
         SetupTerm <$> freshVariable sc "" ty

    Crucible.StructType si ->
       SetupStruct . toList <$> traverse (constructExpandedSetupValue sc) (Crucible.siFieldTypes si)

    Crucible.PtrType symTy ->
      case TyCtx.asMemType symTy of
        Just memTy ->  constructFreshPointer (Crucible.MemType memTy)
        Nothing    -> fail ("lhs not a valid pointer type: " ++ show symTy)

    Crucible.ArrayType n memTy ->
       SetupArray <$> replicateM n (constructExpandedSetupValue sc memTy)

    Crucible.FloatType    -> fail "crucible_fresh_expanded_var: Float not supported"
    Crucible.DoubleType   -> fail "crucible_fresh_expanded_var: Double not supported"
    Crucible.MetadataType -> fail "crucible_fresh_expanded_var: Metadata not supported"
    Crucible.VecType{}    -> fail "crucible_fresh_expanded_var: Vec not supported"

crucible_alloc :: BuiltinContext
               -> Options
               -> L.Type
               -> CrucibleSetup SetupValue
crucible_alloc _bic _opt lty =
  do cctx <- getCrucibleContext
     let lc  = Crucible.llvmTypeCtx (ccLLVMContext cctx)
     let ?dl = TyCtx.llvmDataLayout lc
     let ?lc = lc
     symTy <- case TyCtx.liftType lty of
       Just s -> return s
       Nothing -> fail ("unsupported type in crucible_alloc: " ++ show (L.ppType lty))
     n <- csVarCounter <<%= nextAllocIndex
     currentState.csAllocs.at n ?= symTy
     return (SetupVar n)


crucible_fresh_pointer ::
  BuiltinContext ->
  Options        ->
  L.Type         ->
  CrucibleSetup SetupValue
crucible_fresh_pointer bic _opt lty =
  do symTy <- symTypeForLLVMType bic lty
     constructFreshPointer symTy

constructFreshPointer :: Crucible.SymType -> CrucibleSetup SetupValue
constructFreshPointer symTy =
  do n <- csVarCounter <<%= nextAllocIndex
     currentState.csFreshPointers.at n ?= symTy
     return (SetupVar n)

crucible_points_to ::
  Bool {- ^ whether to check type compatibility -} ->
  BuiltinContext ->
  Options        ->
  SetupValue     ->
  SetupValue     ->
  CrucibleSetup ()
crucible_points_to typed _bic _opt ptr val =
  do cc <- getCrucibleContext
     let ?lc = Crucible.llvmTypeCtx (ccLLVMContext cc)
     st <- get
     let rs = st^.csResolvedState
     if st^.csPrePost == PreState && testResolved ptr rs
       then fail "Multiple points-to preconditions on same pointer"
       else csResolvedState %= markResolved ptr
     let env = csAllocations (st^.csMethodSpec)
     ptrTy <- typeOfSetupValue cc env ptr
     lhsTy <- case ptrTy of
       Crucible.PtrType symTy ->
         case TyCtx.asMemType symTy of
           Just lhsTy -> return lhsTy
           Nothing -> fail $ "lhs not a valid pointer type: " ++ show ptrTy
       _ -> fail $ "lhs not a pointer type: " ++ show ptrTy
     valTy <- typeOfSetupValue cc env val
     when typed (checkMemTypeCompatibility lhsTy valTy)
     addPointsTo (PointsTo ptr val)

crucible_equal ::
  BuiltinContext ->
  Options        ->
  SetupValue     ->
  SetupValue     ->
  CrucibleSetup ()
crucible_equal _bic _opt val1 val2 =
  do cc <- getCrucibleContext
     st <- get
     let env = csAllocations (st^.csMethodSpec)
     ty1 <- typeOfSetupValue cc env val1
     ty2 <- typeOfSetupValue cc env val2
     checkMemTypeCompatibility ty1 ty2
     addCondition (SetupCond_Equal val1 val2)

crucible_precond ::
  TypedTerm      ->
  CrucibleSetup ()
crucible_precond p = do
  st <- get
  when (st^.csPrePost == PostState) $
    fail "attempt to use `crucible_precond` in post state"
  addCondition (SetupCond_Pred p)

crucible_postcond ::
  TypedTerm      ->
  CrucibleSetup ()
crucible_postcond p = do
  st <- get
  when (st^.csPrePost == PreState) $
    fail "attempt to use `crucible_postcond` in pre state"
  addCondition (SetupCond_Pred p)

crucible_execute_func :: BuiltinContext
                      -> Options
                      -> [SetupValue]
                      -> CrucibleSetup ()
crucible_execute_func _bic _opt args = do
  cctx <- getCrucibleContext
  let ?lc   = Crucible.llvmTypeCtx (ccLLVMContext cctx)
  let ?dl   = TyCtx.llvmDataLayout ?lc
  tps <- use (csMethodSpec.csArgs)
  case traverse TyCtx.liftType tps of
    Just tps' -> do
      csPrePost .= PostState
      csMethodSpec.csArgBindings .= Map.fromList [ (i, (t,a))
                                                 | i <- [0..]
                                                 | a <- args
                                                 | t <- tps'
                                                 ]

    _ -> fail $ unlines ["Function signature not supported:", show tps]


crucible_return :: BuiltinContext
                -> Options
                -> SetupValue
                -> CrucibleSetup ()
crucible_return _bic _opt retval = do
  ret <- use (csMethodSpec.csRetValue)
  case ret of
    Just _ -> fail "crucible_return: duplicate return value specification"
    Nothing -> csMethodSpec.csRetValue .= Just retval


crucible_declare_ghost_state ::
  BuiltinContext ->
  Options        ->
  String         ->
  TopLevel Value
crucible_declare_ghost_state _bic _opt name =
  do allocator <- getHandleAlloc
     global <- liftIO (liftST (Crucible.freshGlobalVar allocator (Text.pack name)
                                  (Crucible.IntrinsicRepr
                                     (Crucible.knownSymbol :: Crucible.SymbolRepr GhostValue))))
     return (VGhostVar global)


crucible_ghost_value ::
  BuiltinContext                      ->
  Options                             ->
  Crucible.GlobalVar (Crucible.IntrinsicType GhostValue) ->
  TypedTerm                           ->
  CrucibleSetup ()
crucible_ghost_value _bic _opt ghost val =
  addCondition (SetupCond_Ghost ghost val)

crucible_spec_solvers :: CrucibleMethodSpecIR -> [String]
crucible_spec_solvers = Set.toList . solverStatsSolvers . (view csSolverStats)

crucible_spec_size :: CrucibleMethodSpecIR -> Integer
crucible_spec_size = solverStatsGoalSize . (view csSolverStats)

crucible_setup_val_to_typed_term :: BuiltinContext -> Options -> SetupValue -> TopLevel TypedTerm
crucible_setup_val_to_typed_term bic _opt sval = do
  mtt <- io $ MaybeT.runMaybeT $ setupToTypedTerm (biSharedContext bic) sval
  case mtt of
    Nothing -> fail $ "Could not convert a setup value to a term: " ++ show sval
    Just tt -> return tt

--------------------------------------------------------------------------------

-- | Sort a list of things and group them into equivalence classes.
groupOn ::
  Ord b =>
  (a -> b) {- ^ equivalence class projection -} ->
  [a] -> [[a]]
groupOn f = groupBy ((==) `on` f) . sortBy (compare `on` f)

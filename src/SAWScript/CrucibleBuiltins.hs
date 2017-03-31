{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module           : $Header$
Description      :
License          : BSD3
Stability        : provisional
Point-of-contact : atomb
-}
module SAWScript.CrucibleBuiltins where

import Control.Lens
import Control.Monad.ST
import Control.Monad.State
import Data.Maybe (fromMaybe, fromJust)
import Data.Foldable (toList, find)
import Data.IORef
import Data.String
import Data.Word (Word64)
import System.IO
import           Data.Map (Map)
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Vector as V

import qualified Data.LLVM.BitCode as L
import qualified Text.LLVM.AST as L
import qualified Text.LLVM.PP as L (ppType, ppSymbol)
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import qualified Cryptol.Eval.Type as Cryptol (TValue(..), tValTy, evalValType)
import qualified Cryptol.TypeCheck.AST as Cryptol (Schema(..))

import qualified Data.Parameterized.Nonce as Crucible
import qualified Lang.Crucible.Config as Crucible
import qualified Lang.Crucible.Core as Crucible
import qualified Lang.Crucible.FunctionHandle as Crucible
--import qualified Lang.Crucible.FunctionName as Crucible
import qualified Lang.Crucible.Simulator.CallFns as Crucible
import qualified Lang.Crucible.Simulator.ExecutionTree as Crucible
import qualified Lang.Crucible.Simulator.MSSim as Crucible
import qualified Lang.Crucible.Simulator.RegMap as Crucible
import qualified Lang.Crucible.Simulator.SimError as Crucible
import qualified Lang.Crucible.Solver.Interface as Crucible hiding (mkStruct)
import qualified Lang.Crucible.Solver.SimpleBuilder as Crucible
import qualified Lang.Crucible.Utils.Arithmetic as Crucible

import qualified Lang.Crucible.LLVM as Crucible
import qualified Lang.Crucible.LLVM.DataLayout as Crucible
import qualified Lang.Crucible.LLVM.MemType as Crucible
import qualified Lang.Crucible.LLVM.LLVMContext as TyCtx
import qualified Lang.Crucible.LLVM.Translation as Crucible
import qualified Lang.Crucible.LLVM.MemModel as Crucible
import qualified Lang.Crucible.LLVM.MemModel.Common as Crucible
import qualified Lang.Crucible.Solver.SAWCoreBackend as Crucible
-- import           Lang.Crucible.Utils.MonadST
import qualified Data.Parameterized.TraversableFC as Ctx
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.NatRepr as NatRepr
import qualified Data.Parameterized.Map as MapF

import qualified Language.Go.Parser as Go
import qualified Language.Go.AST    as Go
import qualified Lang.Crucible.Go.Translation as GT
import Data.List.NonEmpty (NonEmpty(..))
import           Data.Generics.Uniplate.Data

import Lang.Crucible.Analysis.Taint (cfgTaintAnalysis, Tainted (..))

import Verifier.SAW.Prelude
import Verifier.SAW.SharedTerm
import Verifier.SAW.TypedAST
import Verifier.SAW.Cryptol (importType, emptyEnv)

import SAWScript.Builtins
import SAWScript.Options
import SAWScript.Proof
import SAWScript.TypedTerm
import SAWScript.TopLevel
import SAWScript.Value

import SAWScript.CrucibleMethodSpecIR
--import SAWScript.LLVMExpr
import SAWScript.LLVMUtils

--import qualified SAWScript.LLVMBuiltins as LB

show_cfg :: Crucible.AnyCFG -> String
show_cfg (Crucible.AnyCFG cfg) = show cfg


-- | Abort the current execution.
abortTree :: Crucible.SimError
          -> Crucible.MSS_State  sym rtp f args
          -> IO (Crucible.SimResult  sym rtp)
abortTree e s = do
  -- Switch to new frame.
  Crucible.isSolverProof (s^.Crucible.stateContext) $ do
    Crucible.abortExec e s


errorHandler :: Crucible.ErrorHandler Crucible.SimContext sym rtp
errorHandler = Crucible.EH abortTree

ppAbortedResult :: CrucibleContext
                -> Crucible.AbortedResult (Crucible.MSS_State Sym)
                -> IO Doc
ppAbortedResult cc (Crucible.AbortedExec err gp) = do
  memDoc <- ppGlobalPair cc gp
  return (Crucible.ppSimError err <$$> memDoc)
ppAbortedResult _ (Crucible.AbortedBranch _ _ _) =
    return (text "Aborted branch")

verifyCrucible
           :: BuiltinContext
           -> Options
           -> String
           -> [CrucibleMethodSpecIR]
           -> CrucibleSetup ()
           -> TopLevel CrucibleMethodSpecIR
verifyCrucible bic _opts nm lemmas setup = do
  let _sc = biSharedContext bic
  cc <- io $ readIORef (biCrucibleContext bic) >>= \case
           Nothing -> fail "No Crucible LLVM module loaded"
           Just cc -> return cc
  let ?lc = Crucible.llvmTypeCtx (ccLLVMContext cc)
  let nm' = fromString nm
  let llmod = ccLLVMModule cc
  def <- case find (\d -> L.defName d == nm') (L.modDefines llmod) of
                 Nothing -> fail ("Could not find function named" ++ show nm)
                 Just decl -> return decl
  let st0 = initialCrucibleSetupState def
  st <- execStateT setup st0
  let methodSpec = csMethodSpec st
  --io $ putStrLn $ unlines [ "Method Spec:", show methodSpec]
  (args, assumes, prestate) <- verifyPrestate cc methodSpec
  ret <- verifySimulate cc methodSpec prestate args assumes lemmas
  asserts <- verifyPoststate cc methodSpec prestate ret
  verifyObligations cc methodSpec assumes asserts
  return methodSpec

verifyObligations :: CrucibleContext
                  -> CrucibleMethodSpecIR
                  -> [Term]
                  -> [Term]
                  -> TopLevel ()
verifyObligations cc mspec assumes asserts = do
  let sym = ccBackend cc
  st     <- io $ readIORef $ Crucible.sbStateManager sym
  let sc  = Crucible.saw_ctx st
  t      <- io $ scBool sc True
  assume <- io $ foldM (scAnd sc) t assumes
  assert <- io $ foldM (scAnd sc) t asserts
  goal   <- io $ scImplies sc assume assert
  goal'  <- io $ scAbstractExts sc (getAllExts goal) goal
  --let prf = satZ3 -- FIXME
  let prf = satABC
  let nm  = show (L.ppSymbol (L.defName (csDefine mspec)))
  r      <- evalStateT (prf sc) (startProof (ProofGoal Universal nm goal'))
  case r of
    Unsat _stats -> do
      io $ putStrLn $ unwords ["Proof succeeded!", nm]
    SatMulti _stats _vals ->
      io $ putStrLn $ unwords ["Proof failed!", nm]

verifyPrestate :: CrucibleContext
               -> CrucibleMethodSpecIR
               -> TopLevel ([(Crucible.MemType, Crucible.LLVMVal Sym Crucible.PtrWidth)], [Term], ResolvedState)
verifyPrestate cc mspec = do
  let ?lc = Crucible.llvmTypeCtx (ccLLVMContext cc)
  prestate <- setupVerifyPrestate cc (csSetupBindings mspec)
  (cs, prestate') <- setupPrestateConditions mspec cc prestate (csConditions mspec)
  args <- resolveArguments cc mspec prestate'
  return (args, cs, prestate')

resolveArguments :: (?lc :: TyCtx.LLVMContext)
                 => CrucibleContext
                 -> CrucibleMethodSpecIR
                 -> ResolvedState
                 -> TopLevel [(Crucible.MemType, Crucible.LLVMVal Sym Crucible.PtrWidth)]
resolveArguments cc mspec rs = mapM resolveArg [0..(nArgs-1)]
 where
  nArgs = toInteger (length (L.defArgs (csDefine mspec)))
  resolveArg i =
    case Map.lookup i (csArgBindings mspec) of
      Just (tp, sv) -> do
        let mt = fromMaybe (error ("Expected memory type:" ++ show tp)) (TyCtx.asMemType tp)
        v <- io $ resolveSetupVal cc rs sv
        return (mt, v)
      Nothing -> fail $ unwords ["Argument", show i, "unspecified"]


data ResolvedState =
  ResolvedState
  { resolvedArgMap   :: Map Integer (Crucible.LLVMVal Sym Crucible.PtrWidth)
  , resolvedVarMap   :: Map Integer (Crucible.LLVMVal Sym Crucible.PtrWidth)
  , resolvedRetVal   :: Maybe (Crucible.LLVMVal Sym Crucible.PtrWidth)
  , resolvedPointers :: Set Integer
  }

initialResolvedState :: ResolvedState
initialResolvedState =
  ResolvedState
  { resolvedArgMap = Map.empty
  , resolvedVarMap = Map.empty
  , resolvedRetVal = Nothing
  , resolvedPointers = Set.empty
  }

setupPrestateConditions
              :: (?lc :: TyCtx.LLVMContext)
              => CrucibleMethodSpecIR
              -> CrucibleContext
              -> ResolvedState
              -> [(PrePost, SetupCondition)]
              -> TopLevel ([Term], ResolvedState)
setupPrestateConditions mspec cc rs0 conds =
  foldM go ([],rs0) [ cond | (PreState, cond) <- conds ]
  where
  go (cs,rs) (SetupCond_PointsTo (SetupVar v) val)
    | Just (Crucible.LLVMValPtr blk end off) <- Map.lookup v (resolvedVarMap rs)
    , Just (BP _ (VarBind_Alloc tp)) <- Map.lookup v (setupBindings (csSetupBindings mspec))
    = let ptr = Crucible.LLVMPtr blk end off in
      let tp' = fromMaybe
                   (error ("Expected memory type:" ++ show tp))
                   (Crucible.toStorableType =<< TyCtx.asMemType tp) in
      if Set.member v (resolvedPointers rs) then do
           io $ withMem cc $ \sym mem -> do
              x <- Crucible.loadRaw sym mem ptr tp'
              val' <- resolveSetupVal cc rs val
              c <- assertEqualVals cc x val'
              return ((c:cs,rs), mem)
         else do
           io $ withMem cc $ \sym mem -> do
              val' <- resolveSetupVal cc rs val
              mem' <- Crucible.storeRaw sym mem ptr tp' val'
              let rs' = rs{ resolvedPointers = Set.insert v (resolvedPointers rs)
                          , resolvedVarMap   = Map.insert v (Crucible.LLVMValPtr blk end off) (resolvedVarMap rs)
                          }
              return ((cs,rs'), mem')

  go (cs,rs) (SetupCond_PointsTo (SetupGlobal name) val) =
    io $ withMem cc $ \sym mem -> do
      r <- Crucible.doResolveGlobal sym mem (L.Symbol name)
      let dl = TyCtx.llvmDataLayout (Crucible.llvmTypeCtx (ccLLVMContext cc))
      let ptrType = Crucible.bitvectorType (dl^.Crucible.ptrSize)
      Crucible.LLVMValPtr blk end off <- Crucible.packMemValue sym ptrType Crucible.llvmPointerRepr r
      let ptr = Crucible.LLVMPtr blk end off
      val' <- resolveSetupVal cc rs val
      let tp' = typeOfLLVMVal dl val'
      mem' <- Crucible.storeRaw sym mem ptr tp' val'
      return ((cs,rs), mem')

  go _ (SetupCond_PointsTo _ _) = fail "Non-pointer value found in points-to assertion"

  go (cs,rs) (SetupCond_Equal _tp val1 val2) = io $ do
    val1' <- resolveSetupVal cc rs val1
    val2' <- resolveSetupVal cc rs val2
    c <- assertEqualVals cc val1' val2'
    return (c:cs,rs)

assertEqualVals :: CrucibleContext
                -> Crucible.LLVMVal Sym Crucible.PtrWidth
                -> Crucible.LLVMVal Sym Crucible.PtrWidth
                -> IO Term
assertEqualVals cc v1 v2 = Crucible.toSC sym =<< go (v1, v2)
 where
  go :: (Crucible.LLVMVal Sym Crucible.PtrWidth, Crucible.LLVMVal Sym Crucible.PtrWidth) -> IO (Crucible.Pred Sym)

  go (Crucible.LLVMValPtr blk1 _end1 off1, Crucible.LLVMValPtr blk2 _end2 off2)
       = do blk_eq <- Crucible.natEq sym blk1 blk2
            off_eq <- Crucible.bvEq sym off1 off2
            Crucible.andPred sym blk_eq off_eq
  go (Crucible.LLVMValFunPtr _ _ _fn1, Crucible.LLVMValFunPtr _ _ _fn2)
       = fail "Cannot compare function pointers for equality FIXME"
  go (Crucible.LLVMValInt wx x, Crucible.LLVMValInt wy y)
       | Just Crucible.Refl <- Crucible.testEquality wx wy
       = Crucible.bvEq sym x y
  go (Crucible.LLVMValReal x, Crucible.LLVMValReal y)
       = Crucible.realEq sym x y
  go (Crucible.LLVMValStruct xs, Crucible.LLVMValStruct ys)
       | V.length xs == V.length ys
       = do cs <- mapM go (zip (map snd (toList xs)) (map snd (toList ys)))
            foldM (Crucible.andPred sym) (Crucible.truePred sym) cs
  go (Crucible.LLVMValArray _tpx xs, Crucible.LLVMValArray _tpy ys)
       | V.length xs == V.length ys
       = do cs <- mapM go (zip (toList xs) (toList ys))
            foldM (Crucible.andPred sym) (Crucible.truePred sym) cs

  go _ = return (Crucible.falsePred sym)

  sym = ccBackend cc

resolveSetupVal :: CrucibleContext
                -> ResolvedState
                -> SetupValue
                -> IO (Crucible.LLVMVal Sym Crucible.PtrWidth)
resolveSetupVal cc rs val =
  case val of
    SetupReturn _ ->
      case resolvedRetVal rs of
        Nothing -> fail "return value not available"
        Just v  -> return v
    SetupVar i
      | Just val' <- Map.lookup i (resolvedVarMap rs) -> return val'
      | otherwise -> fail ("Unresolved prestate variable:" ++ show i)
    SetupTerm tm ->
      case ttSchema tm of
        Cryptol.Forall [] [] ty ->
          resolveSAWTerm (Cryptol.evalValType Map.empty ty) (ttTerm tm)
        _ -> fail "resolveSetupVal: expected monomorphic term"
    SetupStruct vs -> do
      vals <- mapM (resolveSetupVal cc rs) vs
      let tps = map (typeOfLLVMVal dl) vals
      let flds = case Crucible.typeF (Crucible.mkStruct (V.fromList (mkFields 0 0 tps))) of
            Crucible.Struct v -> v
            _ -> error "impossible"
      return $ Crucible.LLVMValStruct (V.zip flds (V.fromList vals))
    SetupArray [] -> fail "resolveSetupVal: invalid empty array"
    SetupArray vs -> do
      vals <- V.mapM (resolveSetupVal cc rs) (V.fromList vs)
      let tp = typeOfLLVMVal dl (V.head vals)
      return $ Crucible.LLVMValArray tp vals
    SetupNull ->
      Crucible.packMemValue sym ptrType Crucible.llvmPointerRepr =<< Crucible.mkNullPointer sym
    SetupGlobal name -> withMem cc $ \_sym impl -> do
      r <- Crucible.doResolveGlobal sym impl (L.Symbol name)
      v <- Crucible.packMemValue sym ptrType Crucible.llvmPointerRepr r
      return (v, impl)

  where
  sym = ccBackend cc
  dl = TyCtx.llvmDataLayout (Crucible.llvmTypeCtx (ccLLVMContext cc))
  ptrType = Crucible.bitvectorType (dl^.Crucible.ptrSize)

  resolveSAWTerm :: Cryptol.TValue -> Term -> IO (Crucible.LLVMVal Sym Crucible.PtrWidth)
  resolveSAWTerm tp tm =
    case tp of
      Cryptol.TVBit ->
        fail "resolveSAWTerm: unimplemented type Bit (FIXME)"
      Cryptol.TVSeq sz Cryptol.TVBit ->
        case Crucible.someNat sz of
          Just (Crucible.Some w)
            | Just Crucible.LeqProof <- Crucible.isPosNat w ->
              do v <- Crucible.bindSAWTerm sym (Crucible.BaseBVRepr w) tm
                 return (Crucible.LLVMValInt w v)
          _ -> fail ("Invalid bitvector width: " ++ show sz)
      Cryptol.TVSeq sz tp' ->
        do sc    <- Crucible.saw_ctx <$> (readIORef (Crucible.sbStateManager sym))
           sz_tm <- scNat sc (fromIntegral sz)
           tp_tm <- importType sc emptyEnv (Cryptol.tValTy tp')
           let f i = do i_tm <- scNat sc (fromIntegral i)
                        tm' <- scAt sc sz_tm tp_tm tm i_tm
                        resolveSAWTerm tp' tm'
           case toLLVMType tp' of
             Nothing -> fail "resolveSAWTerm: invalid type"
             Just mt -> do
               gt <- Crucible.toStorableType mt
               Crucible.LLVMValArray gt . V.fromList <$> mapM f [ 0 .. (sz-1) ]
      Cryptol.TVStream _tp' ->
        fail "resolveSAWTerm: invalid infinite stream type"
      Cryptol.TVTuple _tps ->
        fail "resolveSAWTerm: unimplemented tuple type (FIXME)"
      Cryptol.TVRec _flds ->
        fail "resolveSAWTerm: unimplemented record type (FIXME)"
      Cryptol.TVFun _ _ ->
        fail "resolveSAWTerm: invalid function type"

  toLLVMType :: Cryptol.TValue -> Maybe Crucible.MemType
  toLLVMType tp =
    case tp of
      Cryptol.TVBit -> Nothing -- FIXME
      Cryptol.TVSeq n Cryptol.TVBit
        | n > 0 -> Just (Crucible.IntType (fromInteger n))
        | otherwise -> Nothing
      Cryptol.TVSeq n t -> do
        t' <- toLLVMType t
        let n' = fromIntegral n
        Just (Crucible.ArrayType n' t')
      Cryptol.TVStream _tp' -> Nothing
      Cryptol.TVTuple tps -> do
        tps' <- mapM toLLVMType tps
        let si = Crucible.mkStructInfo dl False tps'
        return (Crucible.StructType si)
      Cryptol.TVRec _flds -> Nothing -- FIXME
      Cryptol.TVFun _ _ -> Nothing

  mkFields :: Crucible.Alignment -> Word64
           -> [Crucible.Type] -> [(Crucible.Type, Word64)]
  mkFields _ _ [] = []
  mkFields a off (ty : tys) = (ty, pad) : mkFields a' off' tys
    where
      end = off + Crucible.typeSize ty
      off' = Crucible.nextPow2Multiple end (fromIntegral nextAlign)
      pad = off' - end
      a' = max a (typeAlignment dl ty)
      nextAlign = case tys of
        [] -> a'
        (ty' : _) -> typeAlignment dl ty'

typeAlignment :: Crucible.DataLayout -> Crucible.Type -> Crucible.Alignment
typeAlignment dl ty =
  case Crucible.typeF ty of
    Crucible.Bitvector bytes -> Crucible.integerAlignment dl (fromIntegral (bytes*8))
    Crucible.Float           -> fromJust (Crucible.floatAlignment dl 32)
    Crucible.Double          -> fromJust (Crucible.floatAlignment dl 64)
    Crucible.Array _sz ty'   -> typeAlignment dl ty'
    Crucible.Struct flds     -> V.foldl max 0 (fmap (typeAlignment dl . (^. Crucible.fieldVal)) flds)

asSAWType :: SharedContext
          -> Crucible.Type
          -> IO Term
asSAWType sc t = case Crucible.typeF t of
  Crucible.Bitvector bytes -> scBitvector sc (fromIntegral (bytes*8))
  Crucible.Float           -> scGlobalDef sc (fromString "Prelude.Float")  -- FIXME??
  Crucible.Double          -> scGlobalDef sc (fromString "Prelude.Double") -- FIXME??
  Crucible.Array sz s ->
    do s' <- asSAWType sc s
       sz_tm <- scNat sc (fromIntegral sz)
       scVecType sc sz_tm s'
  Crucible.Struct flds ->
    do flds' <- mapM (asSAWType sc . (^. Crucible.fieldVal)) $ V.toList flds
       scTupleType sc flds'


setupVerifyPrestate :: (?lc :: TyCtx.LLVMContext)
                    => CrucibleContext
                    -> SetupBindings
                    -> TopLevel ResolvedState
setupVerifyPrestate cc bnds = foldM resolveOne initialResolvedState . Map.assocs . setupBindings $ bnds
 where
  resolveOne rs (i, BP tp bnd)
    | Just _ <- Map.lookup i (resolvedVarMap rs) = return rs
    | otherwise = case bnd of
          VarBind_Alloc alloc_tp
            | Just alloc_mtp <- TyCtx.asMemType alloc_tp -> do
                 ptr <- doAlloc alloc_mtp
                 return $ rs{ resolvedVarMap = Map.insert i ptr (resolvedVarMap rs) }
            | otherwise ->
                 fail $ unwords ["Not a valid memory type:", show alloc_tp]
          VarBind_Value v -> do
            resolveValue rs i tp v

  dl = TyCtx.llvmDataLayout ?lc

  doAlloc tp = io $
    withMem cc $ \sym mem -> do
      sz <- Crucible.bvLit sym Crucible.ptrWidth (fromIntegral (Crucible.memTypeSize dl tp))
      (Crucible.LLVMPtr blk end x, mem') <- Crucible.mallocRaw sym mem sz
      return (Crucible.LLVMValPtr blk end x, mem')

  resolveValue _rs _i _tp _v =
    fail "resolveValue"

withMem :: CrucibleContext
        -> (Sym -> Crucible.MemImpl Sym Crucible.PtrWidth -> IO (a, Crucible.MemImpl Sym Crucible.PtrWidth))
        -> IO a
withMem cc f = do
  let sym = ccBackend cc
  let memOps = Crucible.memModelOps (ccLLVMContext cc)
  globals <- readIORef (ccGlobals cc)
  case Crucible.lookupGlobal (Crucible.llvmMemVar memOps) globals of
    Nothing -> fail "LLVM Memory global variable not initialized"
    Just mem -> do
      (x, mem') <- f sym mem
      let globals' = Crucible.insertGlobal (Crucible.llvmMemVar memOps) mem' globals
      writeIORef (ccGlobals cc) globals'
      return x

ppGlobalPair :: CrucibleContext
             -> Crucible.GlobalPair (Crucible.MSS_State Sym) a
             -> IO Doc
ppGlobalPair cc gp =
  let memOps = Crucible.memModelOps (ccLLVMContext cc)
      sym = ccBackend cc
      globals = gp ^. Crucible.gpGlobals in
  case Crucible.lookupGlobal (Crucible.llvmMemVar memOps) globals of
    Nothing -> return (text "LLVM Memory global variable not initialized")
    Just mem -> Crucible.ppMem sym mem

methodSpecHandler :: CrucibleMethodSpecIR
                  -> Crucible.MSS_State Sym rtp (Crucible.OverrideLang args ret) 'Nothing
                  -> IO (Crucible.SimResult Sym rtp)
methodSpecHandler cs _s = do
  let (L.Symbol fsym) = L.defName (csDefine cs)
  putStrLn $ "Executing override for `" ++ fsym ++ "` (TODO)"
  return undefined

registerOverride :: CrucibleContext
                 -> Crucible.SimContext Sym
                 -> CrucibleMethodSpecIR
                 -> Crucible.OverrideSim Sym rtp args ret ()
registerOverride cc _ctx cs = do
  let s@(L.Symbol fsym) = L.defName (csDefine cs)
      llvmctx = ccLLVMContext cc
  liftIO $ putStrLn $ "Registering override for `" ++ fsym ++ "`"
  case Map.lookup s (llvmctx ^. Crucible.symbolMap) of
    Just (Crucible.LLVMHandleInfo _decl' h) -> do
      -- TODO: check that decl' matches (csDefine cs)
      let o = Crucible.Override
              { Crucible.overrideName = Crucible.handleName h
              , Crucible.overrideHandler = methodSpecHandler cs
              }
      Crucible.registerFnBinding h (Crucible.UseOverride o)
    Nothing -> fail $ "Can't find declaration for `" ++ fsym ++ "`."

verifySimulate :: (?lc :: TyCtx.LLVMContext)
               => CrucibleContext
               -> CrucibleMethodSpecIR
               -> ResolvedState
               -> [(Crucible.MemType, Crucible.LLVMVal Sym Crucible.PtrWidth)]
               -> [Term]
               -> [CrucibleMethodSpecIR]
               -> TopLevel (Maybe (Crucible.LLVMVal Sym Crucible.PtrWidth))
verifySimulate cc mspec _prestate args _assumes lemmas = do
   let nm = L.defName (csDefine mspec)
   case Map.lookup nm (Crucible.cfgMap (ccLLVMModuleTrans cc)) of
      Nothing  -> fail $ unwords ["function", show nm, "not found"]
      Just (Crucible.AnyCFG cfg) -> io $ do
        let h   = Crucible.cfgHandle cfg
            rty = Crucible.handleReturnType h
        args' <- prepareArgs (Crucible.handleArgTypes h) (map snd args)
        simCtx  <- readIORef (ccSimContext cc)
        globals <- readIORef (ccGlobals cc)
        res  <- Crucible.run simCtx globals errorHandler rty $ do
                  mapM_ (registerOverride cc simCtx) lemmas
                  Crucible.regValue <$> (Crucible.callCFG cfg args')
        case res of
          Crucible.FinishedExecution st pr -> do
             gp <- case pr of
                     Crucible.TotalRes gp -> return gp
                     Crucible.PartialRes _ gp _ -> do
                       putStrLn "Symbolic simulation failed along some paths!"
                       return gp
             writeIORef (ccSimContext cc) st
             writeIORef (ccGlobals cc) (gp^.Crucible.gpGlobals)
             let ret_ty = L.defRetType (csDefine mspec)
             let ret_ty' = fromMaybe (error ("Expected return type:" ++ show ret_ty))
                               (TyCtx.liftRetType ret_ty)
             case ret_ty' of
               Nothing -> return Nothing
               Just ret_mt -> Just <$>
                 Crucible.packMemValue (ccBackend cc)
                   (fromMaybe (error ("Expected storable type:" ++ show ret_ty))
                        (Crucible.toStorableType ret_mt))
                   (Crucible.regType  (gp^.Crucible.gpValue))
                   (Crucible.regValue (gp^.Crucible.gpValue))

          Crucible.AbortedResult _ ar -> do
            resultDoc <- ppAbortedResult cc ar
            fail $ unlines [ "Symbolic execution failed."
                           , show resultDoc
                           ]

 where
  prepareArgs :: Ctx.Assignment Crucible.TypeRepr xs
              -> [Crucible.LLVMVal Sym Crucible.PtrWidth]
              -> IO (Crucible.RegMap Sym xs)
  prepareArgs ctx x = Crucible.RegMap <$>
    Ctx.traverseWithIndex (\idx tr -> do
      a <- Crucible.unpackMemValue (ccBackend cc) (x !! Ctx.indexVal idx)
      v <- Crucible.coerceAny (ccBackend cc) tr a
      return (Crucible.RegEntry tr v))
    ctx

verifyPoststate :: (?lc :: TyCtx.LLVMContext)
                => CrucibleContext
                -> CrucibleMethodSpecIR
                -> ResolvedState
                -> Maybe (Crucible.LLVMVal Sym Crucible.PtrWidth)
                -> TopLevel [Term]
verifyPoststate cc mspec prestate ret = do
  let poststate = prestate{ resolvedRetVal = ret }
  io $ mapM (verifyPostCond poststate) [ c | (PostState, c) <- csConditions mspec ]

  where
    dl = TyCtx.llvmDataLayout (Crucible.llvmTypeCtx (ccLLVMContext cc))
    verifyPostCond rs (SetupCond_PointsTo lhs val) = do
      lhs' <- resolveSetupVal cc rs lhs
      ptr <- case lhs' of
        Crucible.LLVMValPtr blk end off -> return (Crucible.LLVMPtr blk end off)
        _ -> fail "Non-pointer value found in points-to assertion"
      val' <- resolveSetupVal cc rs val
      let tp' = typeOfLLVMVal dl val'
      withMem cc $ \sym mem -> do
         x <- Crucible.loadRaw sym mem ptr tp'
         c <- assertEqualVals cc x val'
         return (c, mem)

    verifyPostCond rs (SetupCond_Equal _tp val1 val2) = do
      val1' <- resolveSetupVal cc rs val1
      val2' <- resolveSetupVal cc rs val2
      assertEqualVals cc val1' val2'

typeOfLLVMVal :: Crucible.DataLayout -> Crucible.LLVMVal Sym Crucible.PtrWidth -> Crucible.Type
typeOfLLVMVal dl val =
  case val of
    Crucible.LLVMValPtr {}      -> ptrType
    Crucible.LLVMValFunPtr {}   -> ptrType
    Crucible.LLVMValInt w _bv   -> Crucible.bitvectorType (Crucible.intWidthSize (fromIntegral (NatRepr.natValue w)))
    Crucible.LLVMValReal _      -> error "FIXME: typeOfLLVMVal LLVMValReal"
    Crucible.LLVMValStruct flds -> Crucible.mkStruct (fmap fieldType flds)
    Crucible.LLVMValArray tp vs -> Crucible.arrayType (fromIntegral (V.length vs)) tp
  where
    ptrType = Crucible.bitvectorType (dl^.Crucible.ptrSize)
    fieldType (f, _) = (f ^. Crucible.fieldVal, Crucible.fieldPad f)

load_crucible_llvm_module :: BuiltinContext -> Options -> String -> TopLevel ()
load_crucible_llvm_module bic _opts bc_file = do
  halloc <- getHandleAlloc
  let r = biCrucibleContext bic
  io (L.parseBitCodeFromFile bc_file) >>= \case
    Left err -> fail (L.formatError err)
    Right llvm_mod -> io $ do
      (ctx, mtrans) <- stToIO $ Crucible.translateModule halloc llvm_mod
      let gen = Crucible.globalNonceGenerator
      let sc  = biSharedContext bic
      sym <- Crucible.newSAWCoreBackend sc gen
      let verbosity = 10
      cfg <- Crucible.initialConfig verbosity []
      let bindings = Crucible.fnBindingsFromList []
      let simctx   = Crucible.initSimContext sym Crucible.llvmIntrinsicTypes cfg halloc stdout
                        bindings
      mem <- Crucible.initalizeMemory sym ctx llvm_mod
      let globals  = Crucible.llvmGlobals ctx mem

      let setupMem :: Crucible.OverrideSim Sym
                       (Crucible.RegEntry Sym Crucible.UnitType)
                       Crucible.EmptyCtx Crucible.UnitType (Crucible.RegValue Sym Crucible.UnitType)
          setupMem = do
             -- register the callable override functions
             _llvmctx' <- execStateT Crucible.register_llvm_overrides ctx

             -- initalize LLVM global variables
             _ <- case Crucible.initMemoryCFG mtrans of
                     Crucible.SomeCFG initCFG ->
                       Crucible.callCFG initCFG Crucible.emptyRegMap

             -- register all the functions defined in the LLVM module
             mapM_ Crucible.registerModuleFn $ Map.toList $ Crucible.cfgMap mtrans

      res <- Crucible.run simctx globals errorHandler Crucible.UnitRepr setupMem
      (globals',simctx') <-
          case res of
            Crucible.FinishedExecution st (Crucible.TotalRes gp) -> return (gp^.Crucible.gpGlobals, st)
            Crucible.FinishedExecution st (Crucible.PartialRes _ gp _) -> return (gp^.Crucible.gpGlobals, st)
            Crucible.AbortedResult _ _ -> fail "Memory initialization failed!"
      globRef <- newIORef globals'
      simRef  <- newIORef simctx'
      writeIORef r $ Just
         CrucibleContext{ ccLLVMContext = ctx
                        , ccLLVMModuleTrans = mtrans
                        , ccLLVMModule = llvm_mod
                        , ccBackend = sym
                        , ccSimContext = simRef
                        , ccGlobals = globRef
                        }

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

extractFromCFG :: SharedContext -> CrucibleContext -> Crucible.AnyCFG -> IO TypedTerm
extractFromCFG sc cc (Crucible.AnyCFG cfg) = do
  let sym = ccBackend cc
  let h   = Crucible.cfgHandle cfg
  (ecs, args) <- setupArgs sc sym h
  simCtx  <- readIORef (ccSimContext cc)
  globals <- readIORef (ccGlobals cc)
  res  <- Crucible.run simCtx globals errorHandler (Crucible.handleReturnType h)
             (Crucible.regValue <$> (Crucible.callCFG cfg args))
  case res of
    Crucible.FinishedExecution st pr -> do
        gp <- case pr of
                Crucible.TotalRes gp -> return gp
                Crucible.PartialRes _ gp _ -> do
                  putStrLn "Symbolic simulation failed along some paths!"
                  return gp
        writeIORef (ccSimContext cc) st
        writeIORef (ccGlobals cc) (gp^.Crucible.gpGlobals)
        t <- extractReturnValue sym sc(gp^.Crucible.gpValue)
          -- Crucible.asSymExpr
          --          (gp^.Crucible.gpValue)
          --          (Crucible.toSC sym)
          --          (fail $ unwords ["Unexpected return type:", show (Crucible.regType (gp^.Crucible.gpValue))])
        t' <- scAbstractExts sc (toList ecs) t
        tt <- mkTypedTerm sc t'
        return tt
    Crucible.AbortedResult _ ar -> do
      resultDoc <- ppAbortedResult cc ar
      fail $ unlines [ "Symbolic execution failed."
                     , show resultDoc
                     ]

extractReturnValue :: forall tp. Sym -> SharedContext -> Crucible.RegEntry Sym tp -> IO Term
extractReturnValue sym shctx v0@(Crucible.RegEntry tp v) =
  case tp of
    Crucible.StructRepr ctx -> do terms <- sequence $ Ctx.toListFC (extractReturnValue sym shctx :: forall tp''. Crucible.RegEntry Sym tp'' -> IO Term) $ Ctx.zipWith (\x (Crucible.RV y) -> Crucible.RegEntry x y) ctx v
                                  scTuple shctx terms
    _                       -> Crucible.asSymExpr v0 (Crucible.toSC sym)
                               (fail $ unwords ["Unexpected return type:", show tp])

extract_crucible_llvm :: BuiltinContext -> Options -> String -> TopLevel TypedTerm
extract_crucible_llvm bic _opts fn_name = do
  let r  = biCrucibleContext bic
  let sc = biSharedContext bic
  io (readIORef r) >>= \case
    Nothing -> fail "No Crucible LLVM module loaded"
    Just cc ->
      case Map.lookup (fromString fn_name) (Crucible.cfgMap (ccLLVMModuleTrans cc)) of
        Nothing  -> fail $ unwords ["function", fn_name, "not found"]
        Just cfg -> io $ do
           extractFromCFG sc cc cfg

load_llvm_cfg :: BuiltinContext -> Options -> String -> TopLevel Crucible.AnyCFG
load_llvm_cfg bic _opts fn_name = do
  let r = biCrucibleContext bic
  io (readIORef r) >>= \case
    Nothing -> fail "No Crucible LLVM module loaded"
    Just cc ->
      case Map.lookup (fromString fn_name) (Crucible.cfgMap (ccLLVMModuleTrans cc)) of
        Nothing  -> fail $ unwords ["function", fn_name, "not found"]
        Just cfg -> return cfg


--------------------------------------------------------------------------------
-- Setup builtins

getCrucibleContext :: BuiltinContext -> CrucibleSetup CrucibleContext
getCrucibleContext bic =
  lift (io (readIORef (biCrucibleContext bic))) >>= maybe (fail "No Crucible LLVM module loaded") return

freshBinding :: (?dl :: Crucible.DataLayout)
             => Crucible.SymType
             -> VarBinding
             -> CrucibleSetup SetupValue
freshBinding tp vb = do
  st <- get
  let n  = csVarCounter st
      n' = n + 1
      spec  = csMethodSpec st
      spec' = spec{ csSetupBindings = SetupBindings (Map.insert n (BP tp vb) (setupBindings (csSetupBindings spec))) }
  put st{ csVarCounter = n'
        , csMethodSpec = spec'
        }
  return (SetupVar n)

addCondition :: SetupCondition
             -> CrucibleSetup ()
addCondition cond = do
  st <- get
  let spec = csMethodSpec st
      spec' = spec{ csConditions = (csPrePost st,cond) : csConditions spec }
  put st{ csMethodSpec = spec' }

-- | Returns logical type of actual type if it is an array or primitive
-- type, or an appropriately-sized bit vector for pointer types.
logicTypeOfActual :: Crucible.DataLayout -> SharedContext -> Crucible.MemType
                  -> IO (Maybe Term)
logicTypeOfActual _ sc (Crucible.IntType w) = do
  bType <- scBoolType sc
  lTm <- scNat sc (fromIntegral w)
  Just <$> scVecType sc lTm bType
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
logicTypeOfActual _ _ _ = return Nothing


crucible_fresh_var :: BuiltinContext
                   -> Options
                   -> String
                   -> L.Type
                   -> CrucibleSetup TypedTerm
crucible_fresh_var bic _opts name lty = do
  cctx <- lift (io (readIORef (biCrucibleContext bic))) >>= maybe (fail "No Crucible LLVM module loaded") return
  let sc = biSharedContext bic
  let lc = ccLLVMContext cctx
  let ?lc = Crucible.llvmTypeCtx lc
  let dl = TyCtx.llvmDataLayout (Crucible.llvmTypeCtx lc)
  lty' <- case TyCtx.liftMemType lty of
            Just m -> return m
            Nothing -> fail ("unsupported type in crucible_fresh_var: " ++ show (L.ppType lty))
  mty <- liftIO $ logicTypeOfActual dl sc lty'
  case mty of
    Just ty -> liftIO $ scLLVMValue sc ty name >>= mkTypedTerm sc
    Nothing -> fail $ "Unsupported type in crucible_fresh_var: " ++ show (L.ppType lty)

  --freshBinding lty (VarBind_Value (SetupFresh name))


crucible_alloc :: BuiltinContext
               -> Options
               -> L.Type
               -> CrucibleSetup SetupValue
crucible_alloc bic _opt lty = do
  cctx <- getCrucibleContext bic
  let lc  = Crucible.llvmTypeCtx (ccLLVMContext cctx)
  let ?dl = TyCtx.llvmDataLayout lc
  let ?lc = lc
  lty' <- case TyCtx.liftType lty of
            Just m -> return m
            Nothing -> fail ("unsupported type in crucible_alloc: " ++ show (L.ppType lty))
  freshBinding (Crucible.MemType (Crucible.PtrType lty')) (VarBind_Alloc lty')

crucible_points_to :: BuiltinContext
                   -> Options
                   -> SetupValue
                   -> SetupValue
                   -> CrucibleSetup ()
crucible_points_to _bic _opt ptr val = do
  addCondition (SetupCond_PointsTo ptr val)

crucible_equal :: BuiltinContext
                   -> Options
                   -> L.Type
                   -> SetupValue
                   -> SetupValue
                   -> CrucibleSetup ()
crucible_equal bic _opt lty val1 val2 = do
  cctx <- getCrucibleContext bic
  let lc  = Crucible.llvmTypeCtx (ccLLVMContext cctx)
  let ?dl = TyCtx.llvmDataLayout lc
  let ?lc = lc
  lty' <- case TyCtx.liftType lty of
            Just m -> return m
            Nothing -> fail ("unsupported type in crucible_equal: " ++ show (L.ppType lty))
  addCondition (SetupCond_Equal lty' val1 val2)


crucible_execute_func :: BuiltinContext
                      -> Options
                      -> [SetupValue]
                      -> CrucibleSetup SetupValue
crucible_execute_func bic _opt args = do
  cctx <- lift (io (readIORef (biCrucibleContext bic))) >>= maybe (fail "No Crucible LLVM module loaded") return
  st <- get
  let ?lc   = Crucible.llvmTypeCtx (ccLLVMContext cctx)
  let ?dl   = TyCtx.llvmDataLayout ?lc
  let def   = csDefine (csMethodSpec st)
  let tps   = map L.typedType (L.defArgs def)
  let retTy = L.defRetType def
  let spec  = csMethodSpec st
  case (traverse TyCtx.liftType tps, TyCtx.liftRetType retTy) of
    (Just tps', Just retTy') -> do
      let spec' = spec{ csArgBindings =
                          Map.fromList $
                            [ (i, (t,a))
                            | i <- [0..]
                            | a <- args
                            | t <- tps'
                            ]
                      }
      put st{ csPrePost = PostState
            , csMethodSpec = spec'
            }
      return (SetupReturn retTy')

    _ -> fail $ unlines ["Function signature not supported:", show def]

load_go_file :: BuiltinContext -> Options -> String -> TopLevel GoPackage
load_go_file _ _ file = do
  efile <- io $ Go.parseFile file
  case efile of
    Left err -> fail $ "Error loading " ++ file ++ ": " ++ err
    Right f@(Go.File a _ pname _ _) -> return $ Go.Package a pname $ f :| []

load_go_package :: BuiltinContext -> Options -> String -> TopLevel GoPackage
load_go_package _ _ dir = do
  epkg <- io $ Go.parsePackage dir
  case epkg of
    Left err -> fail $ "Error loading package from " ++ dir ++ ": " ++ err
    Right pkg -> return pkg

make_go_cfg :: BuiltinContext -> Options -> Int -> GoPackage -> String -> TopLevel Crucible.AnyCFG
make_go_cfg _ _ mww pkg fname =
  let ?machineWordWidth = mww in
  case lookup_go_function pkg fname of
    Nothing -> fail $ "Can't find a definition for a function named " ++ fname
    Just (fid, params, returns, body) -> return $ runST $ GT.translateFunction fid params returns body

lookup_go_function :: GoPackage -> String -> Maybe (Go.Id Go.SourceRange, Go.ParameterList Go.SourceRange, Go.ReturnList Go.SourceRange, [Go.Statement Go.SourceRange])
lookup_go_function pkg name =
  find (\((Go.Id _ _ fname), _, _, _) -> Text.unpack fname == name) [(ident, params, returns, body)|(Go.FunctionDecl _ ident params returns (Just body)) <- universeBi pkg]

symexec_cfg :: BuiltinContext -> Options -> Crucible.AnyCFG -> TopLevel TypedTerm
symexec_cfg bic _ cfg = do cc <- mkSimpleCrucibleContext bic
                           io $ extractFromCFG (biSharedContext bic) cc cfg

mkSimpleCrucibleContext :: BuiltinContext -> TopLevel CrucibleContext
mkSimpleCrucibleContext bic = 
  do halloc <- getHandleAlloc
     io$ do let gen = Crucible.globalNonceGenerator
            let sc  = biSharedContext bic
            sym <- Crucible.newSAWCoreBackend sc gen
            let verbosity = 10
            cfg <- Crucible.initialConfig verbosity []
            let bindings = Crucible.fnBindingsFromList []
            let simctx   = Crucible.initSimContext sym MapF.empty cfg halloc stdout bindings
            let globals  = Crucible.emptyGlobals
            refSimctx <- newIORef simctx
            refGlobals <- newIORef globals
            return $ CrucibleContext { ccBackend = sym
                                     , ccSimContext = refSimctx
                                     , ccGlobals = refGlobals
                                     , ccLLVMContext = undefined
                                     , ccLLVMModule = undefined
                                     , ccLLVMModuleTrans = undefined
                                     }
              
taint_flow_cfg :: BuiltinContext -> Options -> [Bool] -> Crucible.AnyCFG -> TopLevel Bool
taint_flow_cfg _ _ taints (Crucible.AnyCFG cfg) =
  let argCtxRepr     = Crucible.handleArgTypes $ Crucible.cfgHandle cfg in
    do argTaintAssign <- if length taints == Ctx.sizeInt (Ctx.size argCtxRepr) then
                         return $ Ctx.generate (Ctx.size argCtxRepr)
                         (\ind -> taintedFromBool (taints !! Ctx.indexVal ind))
                         else fail "The number of taint values does not match the number of function arguments"
       return $ taintedToBool $ cfgTaintAnalysis argTaintAssign cfg

taintedToBool :: Tainted tp -> Bool
taintedToBool Tainted = True
taintedToBool Untainted = False

taintedFromBool :: Bool -> Tainted tp
taintedFromBool True = Tainted
taintedFromBool False = Untainted

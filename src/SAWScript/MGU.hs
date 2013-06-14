{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators #-}

module SAWScript.MGU where

import qualified SAWScript.AST as A
import qualified TestRenamer as SS
import SAWScript.AST (Bind)

import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Identity
import Data.Function (on)
import Data.List (sortBy)
import Data.Maybe (mapMaybe)
import qualified Data.Map as M
import qualified Data.Set as S

-- Types {{{

-- Type Level

type Name = String

data Type
  = TyCon TyCon [Type]
  | TyRecord [Bind Type]
  | TyVar TyVar
 deriving (Eq,Show) 

data TyVar
  = FreeVar Integer
  | BoundVar Name
 deriving (Eq,Ord,Show) 

data TyCon
 = TupleCon Integer
 | ArrayCon
 | FunCon
 | StringCon
 | BoolCon
 | ZCon
 | NumCon Integer
 | BlockCon
 | ContextCon A.Context
 deriving (Eq,Show) 

data Schema = Forall [Name] Type deriving (Show)

-- Expr Level

data Expr
  -- Constants
  = Unit
  | Bit Bool
  | String String
  | Z Integer
  -- Structures
  | Array  [Expr]
  | Block  [BlockStmt]
  | Tuple  [Expr]
  | Record [Bind Expr]
  -- Accessors
  | Index  Expr Expr
  | Lookup Expr Name
  -- LC
  | Var A.ResolvedName
  | Function    Name (Maybe Type) Expr
  | Application Expr Expr
  -- Sugar
  | Let [Bind Expr] Expr
  | TSig Expr Schema
  deriving (Show)

data BlockStmt
  = Bind          (Maybe Name) (Maybe Type) Expr
  -- | BlockTypeDecl Name             typeT  
  | BlockLet      [Bind Expr]
  deriving (Show)

-- }}}

-- Type Constructors {{{

tMono :: Type -> Schema
tMono = Forall []
  
tTuple :: [Type] -> Type
tTuple ts = TyCon (TupleCon $ fromIntegral $ length ts) ts

tUnit = tTuple []

tArray :: Type -> Type -> Type
tArray l t = TyCon ArrayCon [l,t]

tFun :: Type -> Type -> Type
tFun f v = TyCon FunCon [f,v]

tString :: Type
tString = TyCon StringCon []

tBool :: Type
tBool = TyCon BoolCon []

tZ :: Type
tZ = TyCon ZCon []

tNum :: Integral a => a -> Type
tNum n = TyCon (NumCon $ toInteger n) []

tBlock :: Type -> Type -> Type
tBlock c t = TyCon BlockCon [c,t]

-- }}}

-- Subst {{{

newtype Subst = Subst { unSubst :: M.Map TyVar Type }

(@@) :: Subst -> Subst -> Subst
s2@(Subst m2) @@ (Subst m1) = Subst $ m1' `M.union` m2
  where
  m1' = fmap (appSubst s2) m1

emptySubst :: Subst
emptySubst = Subst M.empty

singletonSubst :: TyVar -> Type -> Subst
singletonSubst tv t = Subst $ M.singleton tv t

listSubst :: [(TyVar,Type)] -> Subst
listSubst = Subst . M.fromList

-- }}}

-- mgu {{{

mgu :: Type -> Type -> Maybe Subst
mgu (TyVar tv) t2 = bindVar tv t2
mgu t1 (TyVar tv) = bindVar tv t1
mgu (TyRecord ts1) (TyRecord ts2) = do
  guard (map fst ts1' == map fst ts2')
  mgus (map snd ts1') (map snd ts2')
  where
  ts1' = sortBy (compare `on` fst) ts1
  ts2' = sortBy (compare `on` fst) ts2
mgu (TyCon tc1 ts1) (TyCon tc2 ts2) = do
  guard (tc1 == tc2)
  mgus ts1 ts2
mgu _ _ = fail "type mismatch"

mgus :: [Type] -> [Type] -> Maybe Subst
mgus [] [] = return emptySubst
mgus (t1:ts1) (t2:ts2) = do
  s <- mgu t1 t2
  s' <- mgus (map (appSubst s) ts1) (map (appSubst s) ts2)
  return (s' @@ s)
mgus _ _ = fail "type mismatch"

bindVar :: TyVar -> Type -> Maybe Subst
bindVar (FreeVar i) (TyVar (FreeVar j))
  | i == j    = return emptySubst
bindVar tv@(FreeVar _) t
  | tv `S.member` freeVars t = fail "occurs check fails"
  | otherwise                = return $ singletonSubst tv t

bindVar (BoundVar n) (TyVar (BoundVar m))
  | n == m  = return emptySubst

bindVar _ _ = fail "generality mismatch"

-- }}}

-- FreeVars {{{

class FreeVars t where
  freeVars :: t -> S.Set TyVar

instance (FreeVars a) => FreeVars [a] where
  freeVars = S.unions . map freeVars

instance FreeVars Type where
  freeVars t = case t of
    TyCon tc ts -> freeVars ts
    TyRecord nts  -> freeVars $ map snd nts
    TyVar tv    -> S.singleton tv

instance FreeVars Schema where
  freeVars (Forall ns t) = freeVars t S.\\ (S.fromList $ map BoundVar ns)

-- }}}

-- TI Monad {{{

newtype TI a = TI { unTI :: ReaderT RO (StateT RW Identity) a } deriving (Functor,Monad)

data RO = RO
  { typeEnv :: M.Map A.ResolvedName Schema
  }

emptyRO :: RO
emptyRO = RO M.empty

data RW = RW
  { nameGen :: Integer
  , subst :: Subst
  , errors :: [String]
  }

emptyRW :: RW
emptyRW = RW 0 emptySubst []

newType :: TI Type
newType = do
  rw <- TI get
  TI $ put $ rw { nameGen = nameGen rw + 1 }
  return $ TyVar $ FreeVar $ nameGen rw

appSubstM :: AppSubst t => t -> TI t
appSubstM t = do
  s <- TI $ gets subst
  return $ appSubst s t

recordError :: String -> TI ()
recordError err = TI $ modify $ \rw ->
  rw { errors = err : errors rw }

unify :: Type -> Type -> TI ()
unify t1 t2 = do
  t1' <- appSubstM t1
  t2' <- appSubstM t2
  case mgu t1' t2' of
    Just s -> TI $ modify $ \rw -> rw { subst = s @@ subst rw }
    Nothing -> recordError $ "type mismatch: " ++ show t1 ++ " and " ++ show t2

bindSchema :: Name -> Schema -> TI a -> TI a
bindSchema n s m = TI $ local (\ro -> ro { typeEnv = M.insert (A.LocalName n) s $ typeEnv ro })
  $ unTI m

lookupVar :: A.ResolvedName -> TI Type
lookupVar n = do
  env <- TI $ asks typeEnv
  case M.lookup n env of
    Nothing -> do recordError $ "unbound variable: " ++ show n
                  newType
    Just (Forall as t) -> do ats <- forM as $ \a ->
                               do t <- newType
                                  return (BoundVar a,t)
                             let s = listSubst ats
                             return $ appSubst s t

freeVarsInEnv :: TI (S.Set TyVar)
freeVarsInEnv = do
  env <- TI $ asks typeEnv
  let ss = M.elems env
  ss' <- mapM appSubstM ss
  return $ freeVars ss'

-- }}}

-- AppSubst {{{

class AppSubst t where
  appSubst :: Subst -> t -> t

instance (AppSubst t) => AppSubst [t] where
  appSubst s = map $ appSubst s

instance (AppSubst t) => AppSubst (Maybe t) where
  appSubst s = fmap $ appSubst s

instance AppSubst Type where
  appSubst s t = case t of
    TyCon tc ts -> TyCon tc $ appSubst s ts
    TyRecord nts  -> TyRecord $ appSubstBinds s nts
    TyVar tv    -> case M.lookup tv $ unSubst s of
                     Just t' -> t'
                     Nothing -> t

instance AppSubst Schema where
  appSubst s (Forall ns t) = Forall ns $ appSubst s t

instance AppSubst Expr where
  appSubst s expr = case expr of
    TSig e t           -> TSig (appSubst s e) (appSubst s t)

    Unit               -> Unit
    Bit b              -> Bit b
    String str         -> String str
    Z i                -> Z i
    Array es           -> Array $ appSubst s es
    Block bs           -> Block $ appSubst s bs
    Tuple es           -> Tuple $ appSubst s es
    Record nes         -> Record $ appSubstBinds s nes
    Index ar ix        -> Index (appSubst s ar) (appSubst s ix)
    Lookup rec fld     -> Lookup (appSubst s rec) fld
    Var x              -> Var x
    Function x xt body -> Function x (appSubst s xt) (appSubst s body)
    Application f v    -> Application (appSubst s f) (appSubst s v)
    Let nes e          -> Let (appSubstBinds s nes) (appSubst s e)

instance AppSubst BlockStmt where
  appSubst s bst = case bst of
    Bind mn ctx e -> Bind mn ctx e
    BlockLet bs   -> BlockLet $ appSubstBinds s bs

appSubstBinds :: (AppSubst a) => Subst -> [Bind a] -> [Bind a]
appSubstBinds s bs = [ (n,appSubst s a) | (n,a) <- bs ]

-- }}}

-- Expr translation {{{

translateExpr :: A.Expr A.ResolvedName A.ResolvedT -> Expr
translateExpr expr = case expr of
  A.Unit t               -> sig t $ Unit
  A.Bit b t              -> sig t $ Bit b
  A.Quote s t            -> sig t $ String s
  A.Z i t                -> sig t $ Z i
  A.Array es t           -> sig t $ Array $ map translateExpr es
  A.Block bs t           -> sig t $ Block $ map translateBStmt bs
  A.Tuple es t           -> sig t $ Tuple $ map translateExpr es
  A.Record nes t         -> sig t $ Record $ map translateField nes
  A.Index ar ix t        -> sig t $ Index (translateExpr ar) (translateExpr ix)
  A.Lookup rec fld t     -> sig t $ Lookup (translateExpr rec) fld
  A.Var x t              -> sig t $ Var x
  A.Function x xt body t -> sig t $ Function x (translateType `fmap` xt) $
                                      translateExpr body
  A.Application f v t    -> sig t $ Application (translateExpr f) (translateExpr v)
  A.LetBlock nes e       ->         Let (map translateField nes) (translateExpr e)
  where
  sig :: A.ResolvedT -> Expr -> Expr
  sig Nothing e = e
  sig (Just t) e = TSig e $ translateTypeS t

translateBStmt :: A.BlockStmt A.ResolvedName A.ResolvedT -> BlockStmt
translateBStmt bst = case bst of
  A.Bind mn ctx e -> Bind mn (translateType `fmap` ctx) (translateExpr e)
  A.BlockLet bs   -> BlockLet (map translateField bs)
  --BlockTypeDecl Name             typeT  

translateField :: (a,A.Expr A.ResolvedName A.ResolvedT) -> (a,Expr)
translateField (n,e) = (n,translateExpr e)

translateTypeS :: A.FullT -> Schema
translateTypeS = error "TODO: translateType"

translateType :: A.FullT -> Type
translateType typ = case translateTypeS typ of
  Forall [] t -> t
  _ -> error "my brain exploded: translateType"

-- }}}

-- Type Inference {{{

inferE :: Expr -> TI (Expr,Type)
inferE expr = case expr of
  Unit     -> return (expr,tUnit)
  Bit b    -> return (expr,tBool)
  String s -> return (expr,tString)
  Z i      -> return (expr,tZ)

  Array  [] -> do a <- newType
                  let at = tArray (tNum (0 :: Int)) a
                  return (TSig expr $ tMono at, at)
  Array (e:es) -> do (e',t) <- inferE e
                     es' <- mapM (`checkE` t) es
                     let at = tArray (tNum $ length es + 1) t
                     return (Array (e':es'),at)
  Block bs -> do ctx <- newType
                 (bs',t') <- inferStmts ctx bs
                 return (Block bs', tBlock ctx t')
  Tuple  es -> do (es',ts) <- unzip `fmap` mapM inferE es
                  return (Tuple es',tTuple ts)
  Record nes -> do (nes',nts) <- unzip `fmap` mapM inferField nes
                   return (Record nes', TyRecord nts)
  Index ar ix -> do (ar',at) <- inferE ar
                    ix' <- checkE ix tZ
                    l <- newType
                    t <- newType
                    unify (tArray l t) at
                    return (Index ar' ix',t)
  TSig e (Forall [] t) -> do t' <- checkKind t
                             e' <- checkE e t'
                             return (TSig e' $ tMono t', t')
  TSig e (Forall _ _) -> do recordError "TODO: TSig with Schema"
                            inferE e
  Function x Nothing body -> do a <- newType
                                (body',t) <- bindSchema x (tMono a) $
                                               inferE body
                                return (Function x (Just a) body', tFun a t)
  Application f v -> do (v',fv) <- inferE v
                        t <- newType
                        let ft = tFun fv t
                        f' <- checkE f ft
                        return (Application f' v',t)
                        
  Var x -> do t <- lookupVar x
              return (Var x,t)
  Let bs body -> inferDecls bs $ \bs' -> do
                   (body',t) <- inferE body
                   return (Let bs' body',t)
  {-
  Lookup Expr Name
  -}

checkE :: Expr -> Type -> TI Expr
checkE e t = do
  (e',t') <- inferE e
  unify t t'
  return e'

inferField :: Bind Expr -> TI (Bind Expr,Bind Type)
inferField (n,e) = do
  (e',t) <- inferE e
  return ((n,e'),(n,t))

inferDecls :: [Bind Expr] -> ([Bind Expr] -> TI a) -> TI a
inferDecls bs nextF = do
  (bs',ss) <- unzip `fmap` mapM inferDecl bs
  foldr (uncurry bindSchema) (nextF bs') ss

inferStmts :: Type -> [BlockStmt] -> TI ([BlockStmt],Type)
inferStmts ctx [Bind Nothing mc e] = do
  t <- newType
  e' <- checkE e (tBlock ctx t)
  mc' <- case mc of
    Nothing -> return Nothing
    Just t  -> do t' <- checkKind t
                  unify t ctx
                  return $ Just t'
  return ([Bind Nothing mc' e'],t)
inferStmts _ [_] = do
  recordError "do block must end with expression"
  t <- newType
  return ([],t)
inferStmts ctx (Bind mn mc e : more) = do
  t <- newType
  e' <- checkE e (tBlock ctx t)
  mc' <- case mc of
    Nothing -> return Nothing
    Just t  -> do t' <- checkKind t
                  unify t ctx
                  return $ Just t'
  let f = case mn of
        Nothing -> id
        Just n  -> bindSchema n (tMono t)
  (more',t) <- f $ inferStmts ctx more
  return (Bind mn mc' e' : more', t)
inferStmts ctx (BlockLet bs : more) = inferDecls bs $ \bs' -> do
  (more',t) <- inferStmts ctx more
  return (BlockLet bs' : more', t)

inferDecl :: Bind Expr -> TI (Bind Expr,Bind Schema)
inferDecl (n,e) = do
  (e',t) <- inferE e
  t' <- appSubstM t
  let fvt = freeVars t'
  fvs <- freeVarsInEnv
  let (ns,gvs) = unzip $ mapMaybe toBound $ S.toList $ fvt S.\\ fvs
  let s = listSubst gvs
  let sc = Forall ns $ appSubst s t'
  return ((n,TSig (appSubst s e') sc),(n,sc))
  where
  toBound :: TyVar -> Maybe (Name,(TyVar,Type))
  toBound v@(FreeVar i) = let nm = "a." ++ show i in
                                Just (nm,(v,TyVar (BoundVar nm)))
  toBound _ = Nothing

checkKind :: Type -> TI Type
checkKind = return

-- }}}

-- Main interface {{{

-- TODO: incorporate into Compiler

typeCheck :: A.Module A.ResolvedName A.ResolvedT A.ResolvedT -> IO () -- (A.Module A.ResolvedName A.Type)
typeCheck (A.Module nm ee te ds) = case runTI m of
  (a,s,[]) -> let a' = appSubstBinds s a in do
    putStrLn "No errors"
    print a'
  (_,_,es) -> do
    putStrLn "Bogus"
    mapM_ putStrLn es
  where
  m = typeCheckExprEnv ee

typeCheckExprEnv :: A.Env (A.Expr A.ResolvedName A.ResolvedT) -> TI [Bind Expr]
typeCheckExprEnv env = inferDecls nes return -- TEMPORARY
  where
  nes = [ (n,translateExpr e) | (n,e) <- M.assocs $ env ]

runTI :: TI a -> (a,Subst,[String])
runTI m = (a,subst rw, errors rw)
  where
  m' = runReaderT (unTI m) emptyRO
  (a,rw) = runState m' emptyRW

-- }}}

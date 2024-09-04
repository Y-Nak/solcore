module Solcore.Desugarer.LambdaLifting where 

import Control.Monad.Except 
import Control.Monad.Identity
import Control.Monad.State
import Data.List 
import Solcore.Frontend.Pretty.SolcorePretty 
import Solcore.Frontend.Syntax
import Solcore.Frontend.TypeInference.NameSupply


-- lambda lifting transformation top level function 

lambdaLifting :: CompUnit Name -> Either String (CompUnit Name)
lambdaLifting unit 
  = case runLiftM (liftLambda unit) of 
      Left err -> Left err 
      Right (CompUnit imps ds, env) ->
       Right (CompUnit imps (generated env ++ ds))  

-- lifting lambdas

class LiftLambda a where 
  liftLambda :: a -> LiftM a 

instance LiftLambda a => LiftLambda [a] where 
  liftLambda = mapM liftLambda

instance LiftLambda a => LiftLambda (Maybe a) where 
  liftLambda Nothing = pure Nothing 
  liftLambda (Just x) = Just <$> liftLambda x

instance LiftLambda (CompUnit Name) where 
  liftLambda (CompUnit imps ds) 
    = CompUnit imps <$> liftLambda ds 

instance LiftLambda (TopDecl Name) where 
  liftLambda (TContr c) 
    = TContr <$> liftLambda c 
  liftLambda (TFunDef fd) 
    = TFunDef <$> liftLambda fd
  liftLambda (TInstDef ids)
    = TInstDef <$> liftLambda ids
  liftLambda (TMutualDef tds)
    = TMutualDef <$> liftLambda tds 
  liftLambda d = pure d 

instance LiftLambda (Contract Name) where 
  liftLambda (Contract n vs ds) 
    = Contract n vs <$> liftLambda ds

instance LiftLambda (ContractDecl Name) where 
  liftLambda (CFunDecl fd)
    = CFunDecl <$> liftLambda fd
  liftLambda (CMutualDecl cs)
    = CMutualDecl <$> liftLambda cs 
  liftLambda (CFieldDecl fd)
    = CFieldDecl <$> liftLambda fd 
  liftLambda (CConstrDecl cd)
    = CConstrDecl <$> liftLambda cd 
  liftLambda d = pure d 

instance LiftLambda (Instance Name) where 
  liftLambda (Instance ctx n ts t fs) 
    = Instance ctx n ts t <$> liftLambda fs 

instance LiftLambda (Constructor Name) where 
  liftLambda (Constructor ps bd) 
    = Constructor ps <$> liftLambda bd

instance LiftLambda (Field Name) where 
  liftLambda (Field n t me) 
    = Field n t <$> liftLambda me

instance LiftLambda (FunDef Name) where 
  liftLambda (FunDef sig bd) 
    = FunDef sig <$> liftLambda bd

instance LiftLambda (Stmt Name) where 
  liftLambda (e1 := e2) 
    = (:=) <$> liftLambda e1 <*> liftLambda e2
  liftLambda (Let n t me)
    = Let n t <$> liftLambda me 
  liftLambda (StmtExp e) 
    = StmtExp <$> liftLambda e 
  liftLambda (Return e) 
    = Return <$> liftLambda e 
  liftLambda (Match es eqns) 
    = Match <$> liftLambda es <*> liftLambda eqns
  liftLambda d = pure d

instance LiftLambda (Equation Name) where 
  liftLambda (ps , bd) 
    = (ps,) <$> liftLambda bd 

instance LiftLambda (Exp Name) where 
  liftLambda (Con n es) 
    = Con n <$> liftLambda es 
  liftLambda (FieldAccess e n) 
    = flip FieldAccess n <$> liftLambda e 
  liftLambda (Call me n es)
    = Call <$> liftLambda me <*> pure n <*> liftLambda es 
  liftLambda e@(Lam ps bd mt) 
    = do  
        let free = vars bd \\ vars ps 
        debugInfoLambda e free 
        (e,d) <- createLambdaType free
        createFunction free d ps bd mt 
        pure e
  liftLambda d = pure d 

createLambdaType :: [Name] -> LiftM (Exp Name, DataTy)
createLambdaType ns 
  = do 
      n <- freshName "LambdaTy"
      let vs = map TVar ns 
          d = DataTy n vs [Constr n (TyVar <$> vs)]
      debugCreateLambdaType d
      addDecl (TDataDef d)
      pure (Con n (Var <$> ns), d)

createFunction :: [Name] -> 
                  DataTy -> 
                  [Param Name] -> 
                  Body Name -> 
                  Maybe Ty -> LiftM ()
createFunction ns (DataTy n vs [(Constr m ts)]) ps bd mt 
  = do 
      f <- freshName "lambda_impl"
      let (np, pool') = newName (namePool \\ vars ps)
          t = TyCon n (TyVar <$> vs) 
          ps' = Typed np t : ps 
          bd' = [Match [Var np] [([PCon m pats], bd)]]
          pats = map PVar ns 
          sig = Signature f [] ps' mt
          fd = FunDef sig bd' 
      debugCreateFunction fd 
      addDecl (TFunDef fd)
createFunction _ dt _ _ _ 
  = throwError $ unlines [ "Impossible! Closure type does not have one constructor:"
                         , pretty dt 
                         ]

debugCreateFunction :: FunDef Name -> LiftM ()
debugCreateFunction fd 
  = do 
      let s = unlines [ "Creating function:"
                      , pretty fd 
                      ]
      addDebugInfo s 

debugCreateLambdaType :: DataTy -> LiftM () 
debugCreateLambdaType d 
  = do 
      let s = unlines [ "Creating data type: "
                      , pretty d 
                      ]
      addDebugInfo s 

debugInfoLambda :: Exp Name -> [Name] -> LiftM () 
debugInfoLambda e ns 
  = do 
      let s = unlines [ "Processing lambda:"
                      , pretty e 
                      , "free variables:"
                      , unwords $ map pretty ns 
                      ]
      addDebugInfo s 

-- monad definition

data Env 
  = Env {
      generated :: [TopDecl Name]
    , fresh :: Int 
    , debugInfo :: [String]
    }

type LiftM a = StateT Env (ExceptT String Identity) a

runLiftM :: LiftM a -> Either String (a, Env)
runLiftM m = runIdentity (runExceptT (runStateT m initEnv))
    where 
      initEnv = Env [] 0 []

freshName :: String -> LiftM Name 
freshName s 
  = do 
      n <- gets fresh 
      modify (\ env -> env {fresh = n + 1})
      pure $ Name (s ++ show n)

addDecl :: TopDecl Name -> LiftM () 
addDecl d 
  = modify (\ env -> env{ generated = d : generated env })

addDebugInfo :: String -> LiftM ()
addDebugInfo s 
  = modify (\env -> env{ debugInfo = s : debugInfo env })

-- determining free variables 

class Vars a where 
  vars :: a -> [Name]

instance Vars a => Vars [a] where 
  vars = foldr (union . vars) []

instance Vars (Pat Name) where 
  vars (PVar v) = [v]
  vars (PCon _ ps) = vars ps 
  vars _ = []

instance Vars (Param Name) where 
  vars (Typed n _) = [n]
  vars (Untyped n) = [n]

instance Vars (Stmt Name) where 
  vars (e1 := e2) = vars [e1,e2]
  vars (Let _ _ (Just e)) = vars e
  vars (Let _ _ _) = []
  vars (StmtExp e) = vars e 
  vars (Return e) = vars e 
  vars (Match e eqns) = vars e `union` vars eqns 

instance Vars (Equation Name) where 
  vars (_, ss) = vars ss 

instance Vars (Exp Name) where 
  vars (Var n) = [n]
  vars (Con _ es) = vars es 
  vars (FieldAccess e _) = vars e
  vars (Call (Just e) n es) = [n] `union` vars (e : es)
  vars (Call Nothing n es) = [n] `union` vars es 
  vars (Lam ps bd _) = vars bd \\ vars ps
  vars _ = []
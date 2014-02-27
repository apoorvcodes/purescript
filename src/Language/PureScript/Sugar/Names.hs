-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.Sugar.Names
-- Copyright   :  (c) 2013-14 Phil Freeman, (c) 2014 Gary Burgess, and other contributors
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

module Language.PureScript.Sugar.Names (
  rename
) where

import Control.Applicative ((<$>))
import Control.Monad (foldM, liftM)
import Data.Generics (extM, mkM, everywhereM)
import qualified Data.Map as M
import qualified Data.Set as S
import Language.PureScript.Declarations
import Language.PureScript.Names
import Language.PureScript.Types
import Language.PureScript.Values
import Debug.Trace

data ExportEnvironment = ExportEnvironment
    { exportedTypes :: M.Map ModuleName (S.Set ProperName)
    , exportedDataConstructors :: M.Map ModuleName (S.Set ProperName)
    , exportedTypeClasses :: M.Map ModuleName (S.Set ProperName)
    } deriving (Show)
    
data ImportEnvironment = ImportEnvironment
    { importedTypes :: M.Map ProperName (Qualified ProperName)
    , importedDataConstructors :: M.Map ProperName (Qualified ProperName)
    , importedTypeClasses :: M.Map ProperName (Qualified ProperName)
    } deriving (Show)

nullEnv = ExportEnvironment M.empty M.empty M.empty

addType :: ExportEnvironment -> ModuleName -> ProperName -> ExportEnvironment
addType env mn id = env { exportedTypes = M.insertWith addExport mn (S.singleton id) (exportedTypes env) }

addDataConstructor :: ExportEnvironment -> ModuleName -> ProperName -> ExportEnvironment
addDataConstructor env mn id = env { exportedDataConstructors = M.insertWith addExport mn (S.singleton id) (exportedDataConstructors env) }

addTypeclass :: ExportEnvironment -> ModuleName -> ProperName -> ExportEnvironment
addTypeclass env mn id = env { exportedTypeClasses = M.insertWith addExport mn (S.singleton id) (exportedTypeClasses env) }

-- TODO: do this properly with Either
addExport :: (Ord s, Show s) => S.Set s -> S.Set s -> S.Set s
addExport new old =
    if null overlap
    then S.union new old
    else error $ (show $ head overlap) ++ " has already been defined"
    where overlap = S.toList $ S.intersection new old

rename :: [Module] -> Either String [Module]
rename modules = mapM renameInModule' modules
    where
    exports = findExports modules
    renameInModule' m = do
        imports <- resolveImports exports m
        renameInModule imports m

renameInModule :: ImportEnvironment -> Module -> Either String Module
renameInModule imports (Module mn decls) =
    Module mn <$> mapM updateDecl decls >>= everywhereM (mkM updateType) >>= everywhereM (mkM updateValue) >>= everywhereM (mkM updateBinder)
    where
    updateDecl (TypeInstanceDeclaration cs (Qualified Nothing cn) ts ds) = do
      cn' <- updateClassName cn
      cs' <- updateConstraints cs
      return $ TypeInstanceDeclaration cs' cn' ts ds
    updateDecl d = return d
    updateValue (Constructor (Qualified Nothing nm)) = liftM Constructor $ updateDataConstructorName nm
    updateValue v = return v
    updateBinder (ConstructorBinder (Qualified Nothing nm) b) = liftM (`ConstructorBinder` b) $ updateDataConstructorName nm
    updateBinder v = return v
    updateType (TypeConstructor (Qualified Nothing nm)) = liftM TypeConstructor $ updateTypeName nm
    updateType (SaturatedTypeSynonym (Qualified Nothing nm) tys) = do
        nm' <- updateTypeName nm
        tys' <- mapM updateType tys
        return $ SaturatedTypeSynonym nm' tys'
    updateType (ConstrainedType cs t) = liftM (`ConstrainedType` t) $ updateConstraints cs
    updateType t = return t
    updateConstraints = mapM updateConstraint
    updateConstraint (Qualified Nothing nm, ts) = do
      nm' <- updateClassName nm
      return (nm', ts)
    updateConstraint other = return other
    updateTypeName = update "type" importedTypes
    updateClassName = update "typeclass" importedTypeClasses
    updateDataConstructorName = update "data constructor" importedDataConstructors
    update t get nm = maybe (Left $ "Unknown " ++ t ++ " '" ++ show nm ++ "' in module '" ++ show mn ++ "'") return $ M.lookup nm (get imports)
    
findExports :: [Module] -> ExportEnvironment
findExports = foldl addModule nullEnv
    where
    addModule env (Module mn ds) = foldl (addDecl mn) env ds
    addDecl mn env (TypeClassDeclaration tcn _ _) = addTypeclass env mn tcn
    addDecl mn env (DataDeclaration tn _ dcs) = addType (foldl (`addDataConstructor` mn) env (map fst dcs)) mn tn
    addDecl mn env (TypeSynonymDeclaration tn _ _) = addType env mn tn
    addDecl mn env (ExternDataDeclaration tn _) = addType env mn tn
    addDecl _  env _ = env

findImports :: [Declaration] -> [ModuleName]
findImports decls = [ mn | (ImportDeclaration mn Nothing) <- decls ]

resolveImports :: ExportEnvironment -> Module -> Either String ImportEnvironment
resolveImports env (Module currentModule decls) = do
    types <- resolve exportedTypes
    dataConstructors <- resolve exportedDataConstructors
    typeClasses <- resolve exportedTypeClasses
    return $ ImportEnvironment types dataConstructors typeClasses
    where
    scope = currentModule : findImports decls
    resolve get = foldM resolveDefs M.empty (M.toList $ get env)
    resolveDefs result (mn, names) | mn `elem` scope = foldM (resolveDef mn) result (S.toList names)
    resolveDefs result _ = return result
    resolveDef mn result name = case M.lookup name result of
        Nothing -> return $ M.insert name (Qualified (Just mn) name) result
        Just x@(Qualified (Just mn') _) -> Left $ "Module '" ++ show currentModule ++ if mn' == currentModule
            then "' defines '" ++ show name ++ "' which conflicts with imported definition '" ++ show (Qualified (Just mn) name) ++ "'"
            else "' has conflicting imports for '" ++ show name ++ "': '" ++ show x ++ "', '" ++ show (Qualified (Just mn) name) ++ "'"

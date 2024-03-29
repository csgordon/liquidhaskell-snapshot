{-# LANGUAGE TupleSections  #-}
{-# LANGUAGE CPP #-}


{-@ LIQUID "--cabaldir" @-}
{-@ LIQUID "--diff"     @-}

#if __GLASGOW_HASKELL__ < 710
import           Data.Monoid      (mconcat, mempty)
import           Control.Applicative ((<$>))
#endif

import           Data.Maybe
import           System.Exit
import           Control.DeepSeq
import           Text.PrettyPrint.HughesPJ
import           CoreSyn
import           Var
import           System.Console.CmdArgs.Verbosity (whenLoud)
import           System.Console.CmdArgs.Default

import qualified Language.Fixpoint.Config as FC
import qualified Language.Haskell.Liquid.DiffCheck as DC
import           Language.Fixpoint.Misc
import           Language.Fixpoint.Interface
import           Language.Fixpoint.Types (sinfo, Result (..))
import           Language.Haskell.Liquid.Types
import           Language.Haskell.Liquid.Errors
import           Language.Haskell.Liquid.CmdLine
import           Language.Haskell.Liquid.GhcInterface
import           Language.Haskell.Liquid.Constraint.Generate
import           Language.Haskell.Liquid.Constraint.ToFixpoint
import           Language.Haskell.Liquid.Constraint.Types
import           Language.Haskell.Liquid.TransformRec
import           Language.Haskell.Liquid.Annotate (mkOutput)

main :: IO b
main = do cfg0     <- getOpts
          res      <- mconcat <$> mapM (checkOne cfg0) (files cfg0)
          let ecode = resultExit $  {- traceShow "RESULT" $ -} o_result res
          -- putStrLn  $ "ExitCode: " ++ show ecode
          exitWith ecode

checkOne :: Config -> FilePath -> IO (Output Doc)
checkOne cfg0 t = getGhcInfo cfg0 t >>= either errOut (liquidOne t)
  where
    errOut r    = exitWithResult cfg0 t $ mempty { o_result = r}

liquidOne :: FilePath -> GhcInfo -> IO (Output Doc)
liquidOne target info =
  do donePhase Loud "Extracted Core using GHC"
     let cfg   = config $ spec info
     whenLoud  $ do putStrLn "**** Config **************************************************"
                    print cfg
     whenLoud  $ do putStrLn $ showpp info
                    putStrLn "*************** Original CoreBinds ***************************"
                    putStrLn $ showpp (cbs info)
     let cbs' = transformScope (cbs info)
     whenLoud  $ do donePhase Loud "transformRecExpr"
                    putStrLn "*************** Transform Rec Expr CoreBinds *****************"
                    putStrLn $ showpp cbs'
                    putStrLn "*************** Slicing Out Unchanged CoreBinds *****************"
     dc <- prune cfg cbs' target info
     let cbs'' = maybe cbs' DC.newBinds dc
     let info' = maybe info (\z -> info {spec = DC.newSpec z}) dc
     let cgi   = {-# SCC "generateConstraints" #-} generateConstraints $! info' {cbs = cbs''}
     cgi `deepseq` donePhase Loud "generateConstraints"
     out      <- solveCs cfg target cgi info' dc
     donePhase Loud "solve"
     let out'  = mconcat [maybe mempty DC.oldOutput dc, out]
     DC.saveResult target out'
     exitWithResult cfg target out'

checkedNames ::  Maybe DC.DiffCheck -> Maybe [String]
checkedNames dc          = concatMap names . DC.newBinds <$> dc
   where
     names (NonRec v _ ) = [showpp $ shvar v]
     names (Rec xs)      = map (shvar . fst) xs
     shvar               = showpp . varName

prune :: Config -> [CoreBind] -> FilePath -> GhcInfo -> IO (Maybe DC.DiffCheck)
prune cfg cbinds target info
  | not (null vs) = return . Just $ DC.DC (DC.thin cbinds vs) mempty sp
  | diffcheck cfg = DC.slice target cbinds sp
  | otherwise     = return Nothing
  where
    vs            = tgtVars sp
    sp            = spec info

solveCs :: Config -> FilePath -> CGInfo -> GhcInfo -> Maybe DC.DiffCheck -> IO (Output Doc)
solveCs cfg target cgi info dc
  = do finfo    <- cgInfoFInfo info cgi target
       Result r sol <- solve fx finfo
       let names = checkedNames dc
       let warns = logErrors cgi
       let annm  = annotMap cgi
       let res   = ferr sol r
       let out0  = mkOutput cfg res sol annm
       return    $ out0 { o_vars = names } { o_errors  = warns} { o_result = res }
    where
       fx        = def { FC.solver      = fromJust (smtsolver cfg)
                       , FC.real        = real        cfg
                       , FC.native      = native      cfg
                       , FC.srcFile     = target
                       , FC.cores       = cores       cfg
                       , FC.minPartSize = minPartSize cfg
                       , FC.maxPartSize = maxPartSize cfg
                       -- , FC.stats   = True
                       }
       ferr s r  = fmap (tidyError s) $ result $ sinfo <$> r


-- writeCGI tgt cgi = {-# SCC "ConsWrite" #-} writeFile (extFileName Cgi tgt) str
--   where
--     str          = {-# SCC "PPcgi" #-} showpp cgi

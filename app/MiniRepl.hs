{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TupleSections #-}
module Main where

import           Options.Applicative hiding (ParseError, (<|>))
import qualified Options.Applicative as O
import System.Console.Haskeline
import Text.Megaparsec
import Text.Megaparsec.Char

import SIL.Eval
import SIL.Parser
import SIL.RunTime
import SIL.TypeChecker
import SIL
import Naturals
import PrettyPrint

import qualified Control.Monad.State as State
import Control.Monad.IO.Class
import Data.List

import qualified Data.Map         as Map
import qualified System.IO.Strict as Strict

foreign import capi "gc.h GC_INIT" gcInit :: IO ()
foreign import ccall "gc.h GC_allow_register_threads" gcAllowRegisterThreads :: IO ()

-- Parsers for assignments/expressions within REPL
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
--   Things in the REPL behave slightly different
-- than in the compiler. For example it is possible.
-- to overwrite top-level bindings.
--


-- | Add a SIL expression to the ParserState.
addReplBound :: String -> Term1 -> ParserState -> ParserState
addReplBound name expr (ParserState bound) = ParserState (Map.insert name expr bound)

-- | Assignment parsing from the repl.
parseReplAssignment :: SILParser ()
parseReplAssignment = do
  var <- identifier
  annotation <- optional . try $ parseRefinementCheck
  reserved "=" <?> "assignment ="
  expr <- parseLongExpr
  let annoExp = case annotation of
        Just f -> f expr
        _ -> expr
      assign ps = addReplBound var annoExp ps 
  State.modify assign

-- | Parse only an expression
parseReplExpr :: SILParser ()
parseReplExpr = do
  expr <- parseLongExpr
  let assign ps = addReplBound "_tmp_" expr ps
  State.modify assign

-- | Information about what has the REPL parsed.
data ReplStep = ReplAssignment
              | ReplExpr

-- | Combination of `parseReplExpr` and `parseReplAssignment`
parseReplStep :: SILParser (ReplStep, Bindings)
parseReplStep =  step >>= (\x -> (x,) <$> (bound <$> State.get)) 
    where step = try (parseReplAssignment *> return ReplAssignment)
               <|> (parseReplExpr *> return ReplExpr)

-- | Try to parse the given string and update the bindings.
runReplParser :: Bindings -> String -> Either ErrorString (ReplStep, Bindings)
runReplParser prelude str = do
  let startState = ParserState prelude
      p          = State.runStateT parseReplStep startState
  case runParser p "" str of
    Right (a, s) -> Right a
    Left x       -> Left $ MkES $ errorBundlePretty x

-- Common functions 
-- ~~~~~~~~~~~~~~~~

-- | Obtain expression from the bindings 
-- and transform them into Term3.
resolveBinding' :: String -> Bindings -> Maybe Term3
resolveBinding' name bindings = Map.lookup name bindings >>=
  (fmap splitExpr . debruijinize [])



-- | Print last expression bound to 
-- the _tmp_ variable in the bindings
printLastExpr :: (MonadIO m)         
              => (String -> m ())    -- ^ Printing function
              -> (IExpr  -> m IExpr) -- ^ SIL backend
              -> Bindings           
              -> m ()
printLastExpr printer eval bindings = case Map.lookup "_tmp_" bindings of
    Nothing -> printer "Could not find _tmp_ in bindings"
    Just e  -> do
        let  m_iexpr = ((findChurchSize . splitExpr) <$> debruijinize [] e) >>= toSIL
        case m_iexpr of
            Nothing     -> printer "conversion error"
            Just iexpr' -> do
                iexpr <- eval (SetEnv (Pair (Defer iexpr') Zero))
                printer $ (show.PrettyIExpr) iexpr

-- REPL related logic
-- ~~~~~~~~~~~~~~~~~~

data ReplState = ReplState 
    { replBindings :: Bindings 
    , replEval     :: (IExpr -> IO IExpr)
    -- ^ Backend function used to compile IExprs.
    }

-- | Enter a single line assignment or expression.
replStep :: (IExpr -> IO IExpr) -> Bindings -> String -> InputT IO Bindings
replStep eval bindings s = do
    let e_new_bindings = runReplParser bindings s
    case e_new_bindings of
        Left err -> do 
            outputStrLn $ "Parse error: " ++ getErrorString err
            return bindings
        Right (ReplExpr,new_bindings) -> do  
            printLastExpr (outputStrLn) (liftIO.eval) new_bindings
            return bindings
        Right (ReplAssignment, new_bindings) -> do
            return new_bindings
            

-- | Obtain a multiline string.
replMultiline :: [String] -> InputT IO String
replMultiline buffer = do
    minput <- getInputLine ""
    case minput of
        Nothing -> return ""
        Just ":}" -> return $ concat $ intersperse "\n" $ reverse buffer
        Just s    -> replMultiline (s : buffer) 


-- | Main loop for the REPL.
replLoop :: ReplState -> InputT IO ()
replLoop (ReplState bs eval) = do 
    minput <- getInputLine "sil> "
    case minput of
        Nothing   -> return ()
        Just ":{" -> do
            new_bs <- replStep eval bs =<< replMultiline []
            replLoop $ ReplState new_bs eval 
        Just s | ":dn" `isPrefixOf` s -> do
                   liftIO $ case (runReplParser bs . dropWhile (== ' ')) <$> stripPrefix ":dn" s of
                     Just (Right (ReplExpr, new_bindings)) -> case resolveBinding "_tmp_" new_bindings of
                       Just iexpr -> do
                         putStrLn . showNExprs $ fromSIL iexpr
                         putStrLn . showNIE $ fromSIL iexpr
                       _ -> putStrLn "some sort of error?"
                     _ -> putStrLn "parse error"
                   replLoop $ ReplState bs eval
        Just s | ":d" `isPrefixOf` s -> do
                   liftIO $ case (runReplParser bs . dropWhile (== ' ')) <$> stripPrefix ":d" s of
                     Just (Right (ReplExpr, new_bindings)) -> case resolveBinding "_tmp_" new_bindings of
                       Just iexpr -> putStrLn $ showPIE iexpr
                       _ -> putStrLn "some sort of error?"
                     _ -> putStrLn "parse error"
                   replLoop $ ReplState bs eval
  {-
        Just s | ":tt" `isPrefixOf` s -> do
                   liftIO $ case (runReplParser bs . dropWhile (== ' ')) <$> stripPrefix ":tt" s of
                     Just (Right (ReplExpr, new_bindings)) -> case resolveBinding "_tmp_" new_bindings of
                       Just iexpr -> print . showTraceTypes $ iexpr
                       _ -> putStrLn "some sort of error?"
                     _ -> putStrLn "parse error"
                   replLoop $ ReplState bs eval
-}
        Just s | ":t" `isPrefixOf` s -> do
                   liftIO $ case (runReplParser bs . dropWhile (== ' ')) <$> stripPrefix ":t" s of
                     Just (Right (ReplExpr, new_bindings)) -> case resolveBinding' "_tmp_" new_bindings of
                       Just iexpr -> print $ PrettyPartialType <$> inferType iexpr
                       _ -> putStrLn "some sort of error?"
                     _ -> putStrLn "parse error"
                   replLoop $ ReplState bs eval
        Just s    -> do 
            new_bs <- replStep eval bs s
            replLoop $ (ReplState new_bs eval)

-- Command line settings
-- ~~~~~~~~~~~~~~~~~~~~~

data ReplBackend = SimpleBackend
                 | LLVMBackend 
                 | NaturalsBackend
                 deriving (Show, Eq, Ord)

data ReplSettings = ReplSettings {
      _backend :: ReplBackend
    , _expr    :: Maybe String
    } deriving (Show, Eq)

-- | Choose a backend option between Haskell, LLVM, Naturals. 
-- Haskell is default.
backendOpts :: Parser ReplBackend
backendOpts = flag'       LLVMBackend     (long "llvm"     <> help "LLVM Backend")
              O.<|> flag' SimpleBackend   (long "haskell"  <> help "Haskell Backend (default)")
              O.<|> flag' NaturalsBackend (long "naturals" <> help "Naturals Interpretation Backend")
              O.<|> pure SimpleBackend

-- | Process a given expression instead of entering the repl.
exprOpts :: Parser (Maybe String)
exprOpts = optional $ strOption ( long "expr" <> short 'e' <> help "Expression to be computed") 

-- | Combined options
opts :: ParserInfo ReplSettings
opts = info (settings <**> helper)
      ( fullDesc
      <> progDesc "Stand-in-language simple read-eval-print-loop")
    where settings = ReplSettings <$> backendOpts <*> exprOpts

-- Program
-- ~~~~~~~

-- | Start REPL loop.
startLoop :: ReplState -> IO ()
startLoop state = runInputT defaultSettings $ replLoop state

-- | Compile and output a SIL expression.
startExpr :: (IExpr -> IO IExpr)
          -> Bindings
          -> String
          -> IO ()
startExpr eval bindings s_expr = do
    case runReplParser bindings s_expr of
        Left err -> putStrLn $ "Parse error: " ++ getErrorString err
        Right (ReplAssignment, binds) -> putStrLn $ "Expression is an assignment"
        Right (ReplExpr      , binds) -> printLastExpr putStrLn eval binds

main = do
    e_prelude <- parsePrelude <$> Strict.readFile "Prelude.sil" 
    settings  <- execParser opts
    eval <- case _backend settings of
        SimpleBackend -> return simpleEval
        LLVMBackend   -> do 
            gcInit
            gcAllowRegisterThreads
            return optimizedEval
        NaturalsBackend -> return fastInterpretEval
    let bindings = case e_prelude of
            Left  _   -> Map.empty
            Right bds -> bds
    case _expr settings of
        Just  s -> startExpr eval bindings s
        Nothing -> startLoop (ReplState bindings eval)

module SIL.Serializer (
    serialize
  , deserialize
  , unsafeDeserialize
) where

import Data.Word

import           Data.Vector.Storable (Vector, fromList, (!))
import qualified Data.Vector.Storable         as S
import qualified Data.Vector.Storable.Mutable as SM

import SIL.Serializer.C
import SIL (IExpr(..))


serialize :: IExpr -> Vector Word8
serialize iexpr = S.create $ do 
    vec <- SM.new $ silSize iexpr
    serialize_loop 0 vec iexpr
    return vec

silSize :: IExpr -> Int
silSize iexpr = silSize' iexpr 0

silSize' :: IExpr -> Int -> Int
silSize' Zero         acc = acc + 1
silSize' (Pair e1 e2) acc = silSize' e1 (silSize' e2 (acc + 1)) 
silSize' Env          acc = acc + 1
silSize' (SetEnv  e)  acc = silSize' e (acc + 1)
silSize' (Defer   e)  acc = silSize' e (acc + 1)
silSize' Abort        acc = acc + 1
silSize' (Gate e1 e2) acc = silSize' e1 (silSize' e2 (acc + 1))
silSize' (PLeft   e)  acc = silSize' e (acc + 1)
silSize' (PRight  e)  acc = silSize' e (acc + 1)
silSize' Trace        acc = acc + 1


serialize_loop ix vec ie@Zero = SM.write vec ix (fromIntegral $ typeId ie) >> return ix
serialize_loop ix vec ie@(Pair e1 e2) = do
    SM.write vec ix (fromIntegral $ typeId ie)
    end_ix <- serialize_loop (ix+1) vec e1
    serialize_loop (end_ix+1) vec e2
serialize_loop ix vec ie@Env        = SM.write vec ix (fromIntegral $ typeId ie) >> return ix
serialize_loop ix vec ie@(SetEnv e) = SM.write vec ix (fromIntegral $ typeId ie) >> serialize_loop (ix+1) vec e
serialize_loop ix vec ie@(Defer e)  = SM.write vec ix (fromIntegral $ typeId ie) >> serialize_loop (ix+1) vec e
serialize_loop ix vec ie@Abort      = SM.write vec ix (fromIntegral $ typeId ie) >> return ix
serialize_loop ix vec ie@(Gate e1 e2) = do
    SM.write vec ix (fromIntegral $ typeId ie)
    end_ix <- serialize_loop (ix+1) vec e1
    serialize_loop (end_ix+1) vec e2
serialize_loop ix vec ie@(PLeft e)  = SM.write vec ix (fromIntegral $ typeId ie) >> serialize_loop (ix+1) vec e
serialize_loop ix vec ie@(PRight e) = SM.write vec ix (fromIntegral $ typeId ie) >> serialize_loop (ix+1) vec e
serialize_loop ix vec ie@Trace      = SM.write vec ix (fromIntegral $ typeId ie) >> return ix


-- | Safe deserialization. Will return Nothing for bad input arguments.
deserialize :: Vector Word8 -> Maybe IExpr
deserialize vec = if S.length vec == 0
    then Nothing
    else case S.foldl' deserializer_inside (Call1 id) vec of
        Call1 c -> Just $ c undefined
        CallN c -> Nothing 

-- | Unsafe deserialization. Throws runtime errors.
unsafeDeserialize :: Vector Word8 
                  -> IExpr
unsafeDeserialize vec = case S.foldl' deserializer_inside (Call1 id) vec of
    Call1 c -> c (error "SIL.Serializer.unsafeDeserialize: I'm being evaluated. That means I was called on an empty vector.")
    CallN c -> error "SIL.Serializer.unsafeDeserialize: Could not reduce the CPS stack. Possibly wrong input arguments."

-- | Continuation-passing-style function stack.
data FunStack = Call1 (IExpr -> IExpr)
              | CallN (IExpr -> FunStack)

deserializer_inside cont i | fromIntegral i == zero_type = case cont of
    Call1 c -> Call1 $ \_ -> c Zero
    CallN c -> c Zero 
deserializer_inside cont i | fromIntegral i == pair_type = case cont of
    Call1 c ->  CallN $ \e1 -> Call1 (\e2 -> c (Pair e1 e2))
    CallN c ->  CallN $ \e1 -> CallN (\e2 -> c (Pair e1 e2))
deserializer_inside cont i | fromIntegral i == env_type = case cont of
    Call1 c -> Call1 $ \_ -> c Env
    CallN c -> c Env
deserializer_inside cont i | fromIntegral i == setenv_type = case cont of
    Call1 c -> Call1 $ \e -> c (SetEnv e) 
    CallN c -> CallN $ \e -> c (SetEnv e)
deserializer_inside cont i | fromIntegral i == defer_type = case cont of
    Call1 c -> Call1 $ \e -> c (Defer e) 
    CallN c -> CallN $ \e -> c (Defer e)
deserializer_inside cont i | fromIntegral i == abort_type = case cont of
    Call1 c -> Call1 $ \_ -> c Abort
    CallN c -> c Abort
deserializer_inside cont i | fromIntegral i == gate_type = case cont of
    Call1 c ->  CallN $ \e1 -> Call1 (\e2 -> c (Gate e1 e2))
    CallN c ->  CallN $ \e1 -> CallN (\e2 -> c (Gate e1 e2))
deserializer_inside cont i | fromIntegral i == pleft_type = case cont of
    Call1 c -> Call1 $ \e -> c (PLeft e) 
    CallN c -> CallN $ \e -> c (PLeft e)
deserializer_inside cont i | fromIntegral i == pright_type = case cont of
    Call1 c -> Call1 $ \e -> c (PRight e) 
    CallN c -> CallN $ \e -> c (PRight e)
deserializer_inside cont i | fromIntegral i == trace_type = case cont of
    Call1 c -> Call1 $ \_ -> c Trace
    CallN c -> c Trace




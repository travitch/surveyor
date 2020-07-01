{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Crux.Debug.LLVM (
  debugLLVM
  ) where

import           Control.Lens ( (^.), (&), (%~) )
import           Control.Monad ( when, void )
import qualified Control.Monad.Catch as CMC
import qualified Control.Monad.State as CMS
import           Control.Monad.IO.Class ( liftIO )
import qualified Data.BitVector.Sized as BV
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.IORef as IOR
import qualified Data.LLVM.BitCode as DLB
import qualified Data.Map.Strict as Map
import           Data.Maybe ( fromMaybe )
import qualified Data.Parameterized.Classes as PC
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.NatRepr as NR
import           Data.Parameterized.Some ( Some(..) )
import           Data.Proxy ( Proxy(..) )
import           Data.String ( fromString )
import qualified Data.Text as T
import qualified System.Exit as SE
import qualified System.IO as IO
import qualified Text.LLVM as TL
import qualified What4.Expr.Builder as WEB
import qualified What4.ProgramLoc as WPL
import qualified What4.Solver as WS

import What4.SatResult(SatResult(..))
import What4.Solver.Adapter (solver_adapter_check_sat)
import What4.Solver.Yices (yicesAdapter)
import What4.Interface (bvIsNonzero, getCurrentProgramLoc, asBV)
import Lang.Crucible.Simulator.RegMap (regValue)

import qualified Crux as C
import qualified Crux.Types as C
import qualified Crux.LLVM.Overrides as CLO
import qualified Crux.Log as CL
import qualified Crux.Model as CM
import qualified Lang.Crucible.Backend as LCB
import qualified Lang.Crucible.CFG.Core as CCC
import qualified Lang.Crucible.FunctionHandle as CFH
import qualified Lang.Crucible.LLVM as LCL
import qualified Lang.Crucible.LLVM.QQ as LCLQ
import qualified Lang.Crucible.LLVM.Extension as CLE
import qualified Lang.Crucible.LLVM.Globals as CLG
import qualified Lang.Crucible.LLVM.Intrinsics as CLI
import qualified Lang.Crucible.LLVM.MemModel as CLM
import qualified Lang.Crucible.LLVM.Translation as CLT
import qualified Lang.Crucible.Simulator as LCS
import qualified Lang.Crucible.Simulator.ExecutionTree as LCSET
import qualified Lang.Crucible.Simulator.GlobalState as LCSG
import qualified Lang.Crucible.Simulator.Profiling as LCSP
import qualified Lang.Crucible.Types as LCT

import qualified Crux.Debug.Config as CDC
import qualified Surveyor.Brick as SB
import qualified Surveyor.Core as SC

breakpointOverrides :: ( LCB.IsSymInterface sym
                       , CLM.HasLLVMAnn sym
                       , CLM.HasPtrWidth wptr
                       , wptr ~ CLE.ArchWidth arch
                       , sym ~ (WEB.ExprBuilder t st fs)
                       , SC.Architecture arch' t
                       , SC.SymbolicArchitecture arch' t
                       , ext ~ CLI.LLVM arch
                       )
                    => SB.DebuggerConfig t ext arch'
                    -> [CLI.OverrideTemplate (SC.LLVMPersonality sym) sym arch rtp l a]
breakpointOverrides sconf =
  [ CLI.basic_llvm_override $ [LCLQ.llvmOvr| void @crucible_breakpoint(i8*, ...) |]
       do_breakpoint

  , CLI.basic_llvm_override $ [LCLQ.llvmOvr| void @crucible_debug_assert( i8, i8*, i32 ) |]
       (do_debug_assert sconf)
  ]


data LLVMException = BitcodeParseException FilePath DLB.Error
                   | MemoryMissingFromGlobalVars
                   | forall w. UnsupportedX86BitWidth (NR.NatRepr w)
                   | MissingEntryPoint String
                   | EntryPointHasArguments

deriving instance Show LLVMException

instance CMC.Exception LLVMException

parseLLVM :: FilePath -> IO TL.Module
parseLLVM bcFilePath = do
  eres <- DLB.parseBitCodeFromFile bcFilePath
  case eres of
    Right m -> return m
    Left err -> CMC.throwM (BitcodeParseException bcFilePath err)

setupSimCtx :: ( CLO.ArchOk arch
               , LCB.IsSymInterface sym
               , CLM.HasLLVMAnn sym
               )
            => IO.Handle
            -> CFH.HandleAllocator
            -> sym
            -> LCS.GlobalVar CLM.Mem
            -> CLM.MemOptions
            -> CLT.LLVMContext arch
            -> LCS.SimContext (SC.LLVMPersonality sym) sym (CLE.LLVM arch)
setupSimCtx outHdl halloc sym memGlobal memOpts llvmCtx =
  LCS.initSimContext sym
                     CLI.llvmIntrinsicTypes
                     halloc
                     outHdl
                     (LCS.fnBindingsFromList [])
                     (LCL.llvmExtensionImpl memOpts)
                     (SC.LLVMPersonality memGlobal CM.emptyModel)
     & LCS.profilingMetrics %~ Map.union (llvmMetrics llvmCtx)

debugLLVM :: (?outputConfig :: CL.OutputConfig) => C.CruxOptions -> CDC.DebugOptions -> FilePath -> IO SE.ExitCode
debugLLVM cruxOpts dbgOpts bcFilePath = do
  res <- C.runSimulator cruxOpts (simulateLLVMWithDebug cruxOpts dbgOpts bcFilePath)
  C.postprocessSimResult cruxOpts res

simulateLLVMWithDebug :: C.CruxOptions -> CDC.DebugOptions -> FilePath -> C.SimulatorCallback
simulateLLVMWithDebug _cruxOpts dbgOpts bcFilePath = C.SimulatorCallback $ \sym _maybeOnline -> do
  llvmModule <- parseLLVM bcFilePath
  halloc <- CFH.newHandleAllocator

  let ?laxArith = CDC.laxArithmetic dbgOpts
  Some translation <- CLT.translateModule halloc llvmModule

  let llvmCtx = translation ^. CLT.transContext

  CLT.llvmPtrWidth llvmCtx $ \ptrW -> CLM.withPtrWidth ptrW $ do
    bbMapRef <- IOR.newIORef Map.empty
    let ?lc = llvmCtx ^. CLT.llvmTypeCtx
    let ?badBehaviorMap = bbMapRef
    let outHdl = ?outputConfig ^. CL.outputHandle
    let simCtx = setupSimCtx outHdl halloc sym (CLT.llvmMemVar llvmCtx) (CDC.memoryOptions dbgOpts) llvmCtx
    mem <- CLG.populateAllGlobals sym (CLT.globalInitMap translation) =<< CLG.initializeAllMemory sym llvmCtx llvmModule
    let globSt = LCL.llvmGlobals llvmCtx mem
    case CLT.llvmArch llvmCtx of
      CLE.X86Repr rep
        | Just PC.Refl <- PC.testEquality rep (NR.knownNat @64) -> do
          let llvmCon ng nonce hdlAlloc =
                case SC.llvmAnalysisResultFromModule ng nonce hdlAlloc llvmModule (Some translation) of
                  SC.SomeResult ares -> return ares
          let debuggerConfig = SB.DebuggerConfig (Proxy @SC.LLVM) (Proxy @(SC.CrucibleExt SC.LLVM)) llvmCon
          let debugger = SB.debuggerFeature debuggerConfig (WEB.exprCounter sym)
          let initSt = LCS.InitialState simCtx globSt LCS.defaultAbortHandler LCT.UnitRepr $ do
                LCS.runOverrideSim LCT.UnitRepr $ do
                  registerFunctions debuggerConfig llvmModule translation
                  checkEntryPoint (fromMaybe "main" (CDC.entryPoint dbgOpts)) (CLT.cfgMap translation)
          return (C.RunnableStateWithExtensions initSt [debugger])
        | otherwise -> CMC.throwM (UnsupportedX86BitWidth rep)

do_breakpoint :: (wptr ~ CLE.ArchWidth arch)
              => LCS.GlobalVar CLM.Mem
              -> sym
              -> Ctx.Assignment (LCS.RegEntry sym) (Ctx.EmptyCtx Ctx.::> CLT.LLVMPointerType wptr Ctx.::> LCT.VectorType LCT.AnyType)
              -> LCS.OverrideSim (SC.LLVMPersonality sym) sym (CLI.LLVM arch) r args ret ()
do_breakpoint _gv _sym _ = return ()

lookupString :: (LCB.IsSymInterface sym, CLM.HasLLVMAnn sym, CLO.ArchOk arch)
             => LCS.GlobalVar CLM.Mem
             -> LCS.RegEntry sym (CLT.LLVMPointerType (CLE.ArchWidth arch))
             -> C.OverM personality sym (CLI.LLVM arch) String
lookupString mvar ptr =
  do sym <- LCS.getSymInterface
     mem <- LCS.readGlobal mvar
     bytes <- liftIO (CLM.loadString sym mem (regValue ptr) Nothing)
     return (BS8.unpack (BS.pack bytes))

do_debug_assert :: ( CLO.ArchOk arch
                  , LCB.IsSymInterface sym
                  , CLM.HasLLVMAnn sym
                  , sym ~ (WEB.ExprBuilder t st fs)
                  , SC.Architecture arch' t
                  , SC.SymbolicArchitecture arch' t
                  , ext ~ CLI.LLVM arch
                  )
                => SB.DebuggerConfig t ext arch'
                -> LCS.GlobalVar CLM.Mem
                -> sym
                -> Ctx.Assignment (LCS.RegEntry sym) (Ctx.EmptyCtx Ctx.::> LCT.BVType 8 Ctx.::> CLT.LLVMPointerType (CLE.ArchWidth arch) Ctx.::> LCT.BVType 32)
                -> C.OverM personality sym (CLI.LLVM arch) (LCS.RegValue sym LCT.UnitType)
do_debug_assert sconf mvar sym (Ctx.Empty Ctx.:> p Ctx.:> pFile Ctx.:> line) =
  do cond <- liftIO $ bvIsNonzero sym (regValue p)
     file <- lookupString mvar pFile
     l <- case asBV (regValue line) of
            Just (BV.BV l)  -> return (fromInteger l)
            Nothing -> return 0
     let pos = WPL.SourcePos (T.pack file) l 0
     loc <- liftIO $ getCurrentProgramLoc sym
     let loc' = loc{ WPL.plSourceLoc = pos }
     let msg = LCS.GenericSimError "crucible_debug_assert"
     ret <- liftIO $ LCB.addDurableAssertion sym (LCB.LabeledPred cond (LCS.SimError loc' msg))
     let adapter = yicesAdapter
     let logData = WS.defaultLogData
     satTest <- liftIO $ solver_adapter_check_sat adapter sym logData [cond] $ \satRes ->
       case satRes of
         Sat _ -> return True
         _ -> return False
     simState <- CMS.get
     let ng = WEB.exprCounter sym
     liftIO $ when (not satTest) . void $ SB.surveyorState sconf ng simState Nothing
     return ret

checkEntryPoint :: ( CLO.ArchOk arch
                  , CL.Logs
                  )
                => String
                -> CLT.ModuleCFGMap arch
                -> LCS.OverrideSim (SC.LLVMPersonality sym) sym (CLI.LLVM arch) r args ret ()
checkEntryPoint nm mp =
  case Map.lookup (fromString nm) mp of
    Nothing -> CMC.throwM (MissingEntryPoint nm)
    Just (_, CCC.AnyCFG anyCFG) ->
      case CCC.cfgArgTypes anyCFG of
        Ctx.Empty -> do
          liftIO $ CL.say "crux-dbg" ("Simulating from entry point " ++ show nm)
          _ <- LCS.callCFG anyCFG LCS.emptyRegMap
          return ()
        _ -> CMC.throwM EntryPointHasArguments

registerFunctions :: ( CLO.ArchOk arch
                    , LCB.IsSymInterface sym
                    , CLM.HasLLVMAnn sym
                    , sym ~ (WEB.ExprBuilder t st fs)
                    , SC.Architecture arch' t
                    , SC.SymbolicArchitecture arch' t
                    , ext ~ CLI.LLVM arch
                    )
                  => SB.DebuggerConfig t ext arch'
                  -> TL.Module
                  -> CLT.ModuleTranslation arch
                  -> LCS.OverrideSim (SC.LLVMPersonality sym) sym (CLI.LLVM arch) r args ret ()
registerFunctions sconf llvm_module mtrans =
  do let llvm_ctx = mtrans ^. CLT.transContext
     let ?lc = llvm_ctx ^. CLT.llvmTypeCtx

     -- register the callable override functions
     let overrides = concat [ CLO.cruxLLVMOverrides
                            , CLO.svCompOverrides
                            , CLO.cbmcOverrides
                            , breakpointOverrides sconf
                            ]
     CLI.register_llvm_overrides llvm_module [] overrides llvm_ctx

     -- register all the functions defined in the LLVM module
     mapM_ (LCL.registerModuleFn llvm_ctx) $ Map.elems $ CLT.cfgMap mtrans

llvmMetrics :: forall arch p sym ext
             . CLT.LLVMContext arch
            -> Map.Map T.Text (LCSP.Metric p sym ext)
llvmMetrics llvmCtxt =
  Map.fromList [ ("LLVM.allocs", allocs)
               , ("LLVM.writes", writes)
               ]
  where
    allocs = LCSP.Metric $ measureMemBy CLM.memAllocCount
    writes = LCSP.Metric $ measureMemBy CLM.memWriteCount

    measureMemBy :: (CLM.MemImpl sym -> Int)
                 -> LCS.SimState p sym ext r f args
                 -> IO Integer
    measureMemBy f st = do
      let globals = st ^. LCSET.stateGlobals
      case LCSG.lookupGlobal (CLT.llvmMemVar llvmCtxt) globals of
        Just mem -> return $ toInteger (f mem)
        Nothing -> CMC.throwM MemoryMissingFromGlobalVars

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
-- | The main event handler for the Brick UI
--
-- All of the state is hidden in this module.  The system can only modify state
-- by sending messages.  To facilitate this, no mutation functions are exported.
module Surveyor.Brick.Handlers (
  appHandleEvent,
  mkExtension,
  -- * State types
  BrickUIExtension,
  BrickUIState,
  -- * Lenses ('L.Getter's only)
  blockSelectorG,
  blockViewerG,
  contextG,
  functionSelectorG,
  functionViewerG,
  minibufferG
  ) where

import           GHC.Generics ( Generic )

import qualified Brick as B
import qualified Control.Lens as L
import           Control.Lens ( (&), (^.), (.~), (%~), (^?), _Just )
import           Control.Monad.IO.Class ( liftIO )
import qualified Control.NF as NF
import qualified Data.Foldable as F
import qualified Data.Generics.Product as GL
import           Data.Monoid
import           Data.Parameterized.Classes
import qualified Data.Parameterized.List as PL
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.Some ( Some(..) )
import           Data.Proxy ( Proxy(..) )
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import qualified Fmt as Fmt
import           Fmt ( (+|), (|+), (||+) )
import qualified Graphics.Vty as V
import           Text.Printf ( printf )

import           Prelude

import qualified Surveyor.Core as C
import           Surveyor.Brick.Attributes ( focusedListAttr )
import qualified Surveyor.Brick.Command as BC
import           Surveyor.Brick.Names ( Names(..) )
import qualified Surveyor.Brick.Widget.BlockSelector as BS
import qualified Surveyor.Brick.Widget.BlockViewer as BV
import qualified Surveyor.Brick.Widget.FunctionViewer as FV
import qualified Surveyor.Brick.Widget.FunctionSelector as FS
import qualified Surveyor.Brick.Widget.Minibuffer as MB

appHandleEvent :: C.State BrickUIExtension BrickUIState s -> B.BrickEvent Names (C.Events s (C.S BrickUIExtension BrickUIState)) -> B.EventM Names (B.Next (C.State BrickUIExtension BrickUIState s))
appHandleEvent (C.State s0) evt =
  case evt of
    B.AppEvent ae -> handleCustomEvent s0 ae
    B.VtyEvent vtyEvt -> handleVtyEvent (C.State s0) vtyEvt
    B.MouseDown {} -> B.continue (C.State s0)
    B.MouseUp {} -> B.continue (C.State s0)

handleVtyEvent :: C.State BrickUIExtension BrickUIState s -> V.Event -> B.EventM Names (B.Next (C.State BrickUIExtension BrickUIState s))
handleVtyEvent s0@(C.State s) evt
  | V.EvKey k mods <- evt
  , km <- s ^. C.lKeymap
  , Just (Some cmd) <- C.lookupKeyCommand (C.sUIMode s) (C.Key k mods) km
  , Just Refl <- testEquality (C.cmdArgTypes cmd) PL.Nil = do
      -- First, we try to consult the keymap.  For now, we can only handle
      -- commands that take no arguments.  Later, once we develop a notion of
      -- "current context", we can use that to call commands that take an
      -- argument.
      let sn = (C.SomeNonce . C.sNonce) <$> C.sArchState s
      liftIO (C.cmdFunc cmd (C.sEventChannel s) sn PL.Nil)
      B.continue (C.State s)
  | otherwise =
  case C.sUIMode s of
    C.SomeMiniBuffer (C.MiniBuffer oldMode)
      | mb <- s ^. C.lUIExtension . minibufferL -> do
          let sn = (C.SomeNonce . C.sNonce) <$> C.sArchState s
          mbs <- MB.handleMinibufferEvent evt (C.sEventChannel s) sn mb
          case mbs of
            MB.Canceled mb' -> do
              let s' = s & C.lUIMode .~ C.SomeUIMode oldMode
                         & C.lUIExtension . minibufferL .~ mb'
              B.continue $! C.State s'
            MB.Completed mb' -> do
              let s' = s & C.lUIExtension . minibufferL .~ mb'
              B.continue $! C.State s'
      | otherwise -> B.continue s0
    C.SomeUIMode C.BlockSelector
      | Just bsel <- s ^? C.lArchState . _Just . blockSelectorL -> do
          bsel' <- BS.handleBlockSelectorEvent evt bsel
          let s' = s & C.lArchState . _Just . blockSelectorL .~ bsel'
          B.continue $! C.State s'
      | otherwise -> B.continue s0
    C.SomeUIMode (C.BlockViewer archNonce (Some rep))
      | Just archState <- s ^. C.lArchState
      , Just Refl <- testEquality (archState ^. C.lNonce) archNonce
      , Just bview <- MapF.lookup rep (archState ^. blockViewersL) -> do
          cstk' <- BV.handleBlockViewerEvent evt bview (archState ^. contextL)
          let s' = s & C.lArchState . _Just . contextL .~ cstk'
          B.continue $! (C.State s')
      | otherwise -> B.continue s0
    C.SomeUIMode C.FunctionSelector
      | Just fsel <- s ^? C.lArchState . _Just . functionSelectorL -> do
          fsel' <- FS.handleFunctionSelectorEvent evt fsel
          let s' = s & C.lArchState . _Just . functionSelectorL .~ fsel'
          B.continue $! C.State s'
      | otherwise -> B.continue s0
    C.SomeUIMode C.FunctionViewer
      | Just fview <- s ^? C.lArchState . _Just . functionViewerL
      , Just cstk <- s ^? C.lArchState . _Just . contextL -> do
          cstk' <- FV.handleFunctionViewerEvent evt fview cstk
          let s' = s & C.lArchState . _Just . contextL .~ cstk'
          B.continue $! C.State s'
    C.SomeUIMode _m -> B.continue s0

handleCustomEvent :: (C.Architecture arch s)
                  => C.S BrickUIExtension BrickUIState arch s
                  -> C.Events s (C.S BrickUIExtension BrickUIState)
                  -> B.EventM Names (B.Next (C.State BrickUIExtension BrickUIState s))
handleCustomEvent s0 evt =
  case evt of
    C.AnalysisFinished (C.SomeResult bar) diags -> do
      let newDiags = map (\d -> T.pack ("Analysis: " ++ show d)) diags
          notification = "Finished loading file"
      s1 <- liftIO $ stateFromAnalysisResult s0 bar (Seq.fromList newDiags <> Seq.singleton notification) C.Ready (C.SomeUIMode C.Diags)
      B.continue (C.State s1)
    C.AnalysisProgress (C.SomeResult bar) -> do
      s1 <- liftIO $ stateFromAnalysisResult s0 bar Seq.empty C.Loading (C.sUIMode s0)
      B.continue (C.State s1)
    C.AnalysisFailure exn -> do
      liftIO (C.sEmitEvent s0 (C.LogDiagnostic (Just C.LogError) (Fmt.fmt ("Analysis failure: " +| exn ||+ ""))))
      B.continue $! C.State s0
    C.ErrorLoadingELFHeader off msg -> do
      let t = T.pack (printf "ELF Loading error at offset 0x%x: %s" off msg)
      let s1 = s0 & C.lDiagnosticLog %~ (Seq.|> (Just C.LogError, t))
      B.continue $! C.State s1
    C.ErrorLoadingELF errs -> do
      let newDiags = map (\d -> (Just C.LogError, Fmt.fmt ("ELF Loading error: " +| d ||+ ""))) errs
      let s1 = s0 & C.lDiagnosticLog %~ (<> Seq.fromList newDiags)
      B.continue $! C.State s1
    C.ErrorLoadingLLVM s -> do
      let t = Fmt.fmt ("Error loading LLVM bitcode: " +| s |+ "")
      let s1 = s0 & C.lDiagnosticLog %~ (Seq.|> (Just C.LogError, t))
      B.continue $! C.State s1
    C.LoadFile filename -> do
      liftIO (F.traverse_ C.cancelLoader (C.sLoader s0))
      loader <- liftIO $ C.asynchronouslyLoad (C.sNonceGenerator s0) (C.sEventChannel s0) filename
      let s1 = s0 & C.lLoader .~ Just loader
                  & C.lInputFile .~ Just filename
      B.continue $! C.State s1
    C.LoadELF filename -> do
      liftIO (F.traverse_ C.cancelLoader (C.sLoader s0))
      loader <- liftIO $ C.asynchronouslyLoadElf (C.sNonceGenerator s0) (C.sEventChannel s0) filename
      let s1 = s0 & C.lLoader .~ Just loader
                  & C.lInputFile .~ Just filename
      B.continue $! C.State s1
    C.LoadJAR filename -> do
      liftIO (F.traverse_ C.cancelLoader (C.sLoader s0))
      loader <- liftIO $ C.asynchronouslyLoadJAR (C.sNonceGenerator s0) (C.sEventChannel s0) filename
      let s1 = s0 & C.lLoader .~ Just loader
                  & C.lInputFile .~ Just filename
      B.continue $! C.State s1
    C.LoadLLVM filename -> do
      liftIO (F.traverse_ C.cancelLoader (C.sLoader s0))
      loader <- liftIO $ C.asynchronouslyLoadLLVM (C.sNonceGenerator s0) (C.sEventChannel s0) filename
      let s1 = s0 & C.lLoader .~ Just loader
                  & C.lInputFile .~ Just filename
      B.continue $! C.State s1
    C.ShowSummary -> B.continue $! C.State (s0 & C.lUIMode .~ C.SomeUIMode C.Summary)
    C.ShowDiagnostics -> B.continue $! C.State (s0 & C.lUIMode .~ C.SomeUIMode C.Diags)
    C.DescribeCommand (Some cmd) -> do
      let msg = T.pack (printf "%s: %s" (C.cmdName cmd) (C.cmdDocstring cmd))
      liftIO (C.sEmitEvent s0 (C.EchoText msg))
      let newMode =
            case C.sUIMode s0 of
              C.SomeMiniBuffer (C.MiniBuffer oldMode) -> oldMode
              C.SomeUIMode mode -> mode
      let s1 = s0 & C.lDiagnosticLog %~ (Seq.|> (Nothing, msg))
                  & C.lUIMode .~ C.SomeUIMode newMode
      B.continue $! C.State s1
    C.EchoText txt -> do
      ea' <- liftIO (C.setEchoAreaText (C.sEchoArea s0) txt)
      B.continue $! C.State (s0 & C.lEchoArea .~ ea')
    C.ResetEchoArea -> B.continue $! C.State (s0 & C.lEchoArea %~ C.resetEchoArea)
    C.OpenMinibuffer ->
      case C.sUIMode s0 of
        C.SomeMiniBuffer _ -> B.continue (C.State s0)
        C.SomeUIMode mode -> B.continue $! C.State (s0 & C.lUIMode .~ C.SomeMiniBuffer (C.MiniBuffer mode))

    C.ViewBlock archNonce rep
      | Just oldNonce <- s0 ^? C.lArchState . _Just . C.lNonce
      , Just Refl <- testEquality archNonce oldNonce -> do
          -- Set the current view to the block viewer (of the appropriate IR)
          --
          -- Note that this doesn't manipulate the context at all
          liftIO (C.sEmitEvent s0 (C.LogDiagnostic (Just C.LogDebug) (Fmt.fmt ("Viewing a block for repr " +| rep ||+ ""))))
          let s1 = s0 & C.lUIMode .~ C.SomeUIMode (C.BlockViewer archNonce (Some rep))
          B.continue $! C.State s1
      | otherwise -> B.continue (C.State s0)
    C.ViewFunction _archNonce -> do
      let s1 = s0 & C.lUIMode .~ C.SomeUIMode C.FunctionViewer
      B.continue $! C.State s1
    C.ViewInstructionSemantics _archNonce -> do
      let s1 = s0 & C.lUIMode .~ C.SomeUIMode C.SemanticsViewer
      B.continue $! C.State s1
    C.FindBlockContaining archNonce addr
      | Just archState <- s0 ^. C.lArchState
      , ares <- archState ^. C.lAnalysisResult
      , Just Refl <- testEquality (archState ^. C.lNonce) archNonce -> do
          liftIO (C.sEmitEvent s0 (C.LogDiagnostic (Just C.LogDebug) (Fmt.fmt ("Finding block at address " +| C.prettyAddress addr |+ ""))))
          case C.containingBlocks ares addr of
            [b] -> do
              liftIO (C.sEmitEvent s0 (C.PushContext archNonce b))
              liftIO (C.sEmitEvent s0 (C.ViewBlock archNonce C.BaseRepr))
              B.continue (C.State s0)
            blocks -> do
              liftIO (C.sEmitEvent s0 (C.ListBlocks archNonce blocks))
              B.continue (C.State s0)
      | otherwise -> B.continue (C.State s0)
    C.ListBlocks archNonce blocks
      | Just oldNonce <- s0 ^? C.lArchState . _Just . C.lNonce
      , Just Refl <- testEquality oldNonce archNonce -> do
          let callback b = do
                C.sEmitEvent s0 (C.PushContext archNonce b)
                C.logDiagnostic s0 C.LogDebug (Fmt.fmt ("Pushing a block to view: " +| C.blockAddress b ||+""))
                C.sEmitEvent s0 (C.ViewBlock archNonce C.BaseRepr)
          let s1 = s0 & C.lUIMode .~ C.SomeUIMode C.BlockSelector
                      & C.lArchState . _Just . blockSelectorL .~ BS.blockSelector callback focusedListAttr blocks
          B.continue $! C.State s1
      | otherwise -> B.continue (C.State s0)

    C.FindFunctionsContaining archNonce maddr
      | Just oldArchState <- s0 ^. C.lArchState
      , oldNonce <- oldArchState ^. C.lNonce
      , Just Refl <- testEquality oldNonce archNonce ->
        let ares = oldArchState ^. C.lAnalysisResult
        in case maddr of
            Nothing -> do
              liftIO (C.sEmitEvent s0 (C.ListFunctions archNonce (C.functions ares)))
              B.continue $! C.State s0
      | otherwise -> B.continue $! C.State s0

    C.ListFunctions archNonce funcs
      | Just archState <- s0 ^. C.lArchState
      , Just Refl <- testEquality (archState ^. C.lNonce) archNonce -> do
          let callback f = do
                case C.functionBlocks (archState ^. C.lAnalysisResult) f of
                  [] ->
                    C.sEmitEvent s0 (C.LogDiagnostic (Just C.LogWarning) (Fmt.fmt ("Failed to find blocks for function: " +| f ||+"")))
                  entryBlock : _ -> do
                    C.sEmitEvent s0 (C.LogDiagnostic (Just C.LogDebug) (Fmt.fmt ("Selecting function: " +| f ||+ "")))
                    C.sEmitEvent s0 (C.PushContext archNonce entryBlock)
                    C.sEmitEvent s0 (C.ViewFunction archNonce)
          let s1 = s0 & C.lUIMode .~ C.SomeUIMode C.FunctionSelector
                      & C.lArchState . _Just . functionSelectorL .~ FS.functionSelector callback focusedListAttr funcs
          B.continue (C.State s1)
      | otherwise -> B.continue (C.State s0)

    C.PushContext archNonce b
      | Just archState <- s0 ^. C.lArchState
      , Just Refl <- testEquality (archState ^. C.lNonce) archNonce -> do
          ctx <- liftIO $ C.makeContext (archState ^. irCacheL) (archState ^. C.lAnalysisResult) b
          let s1 = s0 & C.lArchState . _Just . contextL %~ C.pushContext ctx
          liftIO $ C.sEmitEvent s0 (C.LogDiagnostic (Just C.LogDebug) (Fmt.fmt ("Selecting block: " +| C.blockAddress b ||+ "")))
          liftIO $ C.logDiagnostic s0 C.LogDebug (Fmt.fmt ("from function " +| C.blockFunction b ||+ ""))
          B.continue (C.State s1)
      | otherwise -> do
        case s0 ^. C.lArchState of
          Nothing -> liftIO $ C.logDiagnostic s0 C.LogDebug "PushContext: no arch state"
          Just archState
            | Just Refl <- testEquality (archState ^. C.lNonce) archNonce ->
              return ()
            | otherwise ->
              liftIO $ C.logDiagnostic s0 C.LogDebug "PushContext: Nonce mismatch"
        B.continue (C.State s0)

    C.LogDiagnostic mLogLevel t ->
      case mLogLevel of
        Nothing -> B.continue $! C.State (s0 & C.lDiagnosticLog %~ (Seq.|> (mLogLevel, t)))
        Just logLevel
          | logLevel >= C.sDiagnosticLevel s0 ->
            B.continue $! C.State (s0 & C.lDiagnosticLog %~ (Seq.|> (Just logLevel, t)))
          | otherwise -> B.continue $! C.State s0

    -- We discard async state updates if the type of the state has changed in
    -- the interim (i.e., if another binary has been loaded)
    C.AsyncStateUpdate archNonce nfVal upd
      | Just oldNonce <- s0 ^? C.lArchState ._Just . C.lNonce
      , Just Refl <- testEquality oldNonce archNonce ->
          B.continue (C.State (upd (NF.getNF nfVal) s0))
      | otherwise -> B.continue (C.State s0)

    C.Exit -> do
      liftIO (F.traverse_ C.cancelLoader (C.sLoader s0))
      B.halt (C.State s0)

stateFromAnalysisResult :: forall arch0 arch s
                         . (C.Architecture arch s)
                        => C.S BrickUIExtension BrickUIState arch0 s
                        -> C.AnalysisResult arch s
                        -> Seq.Seq T.Text
                        -> C.AppState
                        -> C.SomeUIMode s
                        -> IO (C.S BrickUIExtension BrickUIState arch s)
stateFromAnalysisResult s0 ares newDiags state uiMode = do
  tcache <- C.newTranslationCache
  case () of
    () | Just oldArchState <- C.sArchState s0
       , Just Refl <- testEquality (C.sNonce oldArchState) (C.archNonce ares) -> return ()
       | otherwise -> do
           -- When we get a new binary (and have a fresh state), queue up a
           -- default function to view (the first function we found).
           --
           -- We have to do this in a separate thread, as constructing the
           -- function viewer can be a bit expensive (since we are translating
           -- the function on-demand).
           --
           -- If there is no function, then just don't do anything.
           case C.functions ares of
             [] -> return ()
             defFunc : _ -> do
               let pushContext newVal oldState = oldState & C.lArchState . _Just . contextL %~ C.pushContext newVal
               C.asynchronously (C.archNonce ares) (C.sEmitEvent s0) pushContext $ do
                 case C.functionBlocks ares defFunc of
                   b0 : _ -> C.makeContext tcache ares b0
                   _ -> error ("No blocks in function " ++ show defFunc)
  return C.S { C.sDiagnosticLog = C.sDiagnosticLog s0 <> fmap (Nothing,) newDiags
             , C.sDiagnosticLevel = C.sDiagnosticLevel s0
             , C.sUIMode = uiMode
             , C.sAppState = state
             , C.sEmitEvent = C.sEmitEvent s0
             , C.sEventChannel = C.sEventChannel s0
             , C.sNonceGenerator = C.sNonceGenerator s0
             , C.sEchoArea = C.sEchoArea s0
             , C.sInputFile = C.sInputFile s0
             , C.sLoader = C.sLoader s0
             , C.sKeymap = C.defaultKeymap
             , C.sUIExtension = uiExt
             , C.sArchState =
               case () of
                 () | Just oldArchState <- C.sArchState s0
                    , Just Refl <- testEquality (C.sNonce oldArchState) (C.archNonce ares) ->
                      Just (oldArchState { C.sAnalysisResult = ares })
                    | otherwise -> do
                        let blockViewers = (MapF.Pair C.BaseRepr (BV.blockViewer InteractiveBlockViewer C.BaseRepr))
                                         : [ MapF.Pair rep (BV.blockViewer InteractiveBlockViewer rep)
                                           | C.SomeIRRepr rep <- C.alternativeIRs (Proxy @(arch, s))
                                           ]
                        let funcViewerCallback b = do
                              C.sEmitEvent s0 (C.PushContext (C.archNonce ares) b)
                              C.sEmitEvent s0 (C.ViewBlock (C.archNonce ares) C.BaseRepr)
                        let uiState = BrickUIState { sBlockSelector = BS.emptyBlockSelector
                                                   , sBlockViewers = MapF.fromList blockViewers
                                                   , sFunctionViewer = FV.functionViewer funcViewerCallback FunctionCFGViewer
                                                   , sFunctionSelector = FS.functionSelector (const (return ())) focusedListAttr []
                                                   , sContext = C.emptyContextStack
                                                   , sIRCache = tcache
                                                   }
                        return C.ArchState { C.sAnalysisResult = ares
                                           , C.sNonce = C.archNonce ares
                                           , C.sUIState = uiState
                                           }
             }
  where
    addrParser s = C.SomeAddress (C.archNonce ares) <$> C.parseAddress s
    uiExt = BrickUIExtension { sMinibuffer = MB.minibuffer addrParser MinibufferEditor MinibufferCompletionList "M-x" (C.allCommands ++ BC.extraCommands)
                             }

-- | State specific to the Brick UI
--
-- This is mostly storage for widgets
data BrickUIState arch s =
  BrickUIState { sFunctionSelector :: !(FS.FunctionSelector arch s)
               -- ^ Functions available in the function selector
               , sBlockSelector :: !(BS.BlockSelector arch s)
               , sBlockViewers :: !(MapF.MapF (C.IRRepr arch) (BV.BlockViewer arch s))
               , sFunctionViewer :: !(FV.FunctionViewer arch s)
               , sContext :: !(C.ContextStack arch s)
               -- ^ A stack of the contexts that have been focused by the user.
               --
               -- For now, we are just looking at the most recent context (i.e.,
               -- each viewer will consult the most recent context to draw).
               -- Later, there will be context-manipulation commands to allow
               -- the user to explicitly manage the stack by popping things.
               --
               -- FIXME: Move this to the core state.
               , sIRCache :: C.TranslationCache arch s
               -- ^ A cache of blocks translated from the base architecture to
               -- alternative architectures.  We need a cache, as the
               -- translation can be expensive (and we don't want to have to
               -- re-do it for each block we need to access)
               }
  deriving (Generic)

-- | Extra UI extensions for the Brick UI
--
-- This differs from 'BrickUIState' in that it is not parameterized by the
-- architecture (@arch@).  That is important, as there is not always an active
-- architecture.  Objects in this extension state can always be available (e.g.,
-- the minibuffer).
data BrickUIExtension s =
  BrickUIExtension { sMinibuffer :: !(MB.Minibuffer (C.Events s (C.S BrickUIExtension BrickUIState)) (Maybe (C.SomeNonce s)) (C.Argument (C.Events s (C.S BrickUIExtension BrickUIState)) (Maybe (C.SomeNonce s)) s) C.TypeRepr T.Text Names)
                   -- ^ The persistent state of the minibuffer
                   }
  deriving (Generic)

mkExtension :: (String -> Maybe (C.SomeAddress s)) -> T.Text -> BrickUIExtension s
mkExtension addrParser prompt =
  BrickUIExtension { sMinibuffer = MB.minibuffer addrParser MinibufferEditor MinibufferCompletionList prompt (C.allCommands ++ BC.extraCommands)
                   }

minibufferL :: L.Lens' (BrickUIExtension s) (MB.Minibuffer (C.Events s (C.S BrickUIExtension BrickUIState)) (Maybe (C.SomeNonce s)) (C.Argument (C.Events s (C.S BrickUIExtension BrickUIState)) (Maybe (C.SomeNonce s)) s) C.TypeRepr T.Text Names)
minibufferL = GL.field @"sMinibuffer"

minibufferG :: L.Getter (BrickUIExtension s) (MB.Minibuffer (C.Events s (C.S BrickUIExtension BrickUIState)) (Maybe (C.SomeNonce s)) (C.Argument (C.Events s (C.S BrickUIExtension BrickUIState)) (Maybe (C.SomeNonce s)) s) C.TypeRepr T.Text Names)
minibufferG = L.to (^. minibufferL)

functionSelectorL :: L.Lens' (C.ArchState BrickUIState arch s) (FS.FunctionSelector arch s)
functionSelectorL = C.lUIState . GL.field @"sFunctionSelector"

functionSelectorG :: L.Getter (C.ArchState BrickUIState arch s) (FS.FunctionSelector arch s)
functionSelectorG = L.to (^. functionSelectorL)

blockSelectorL :: L.Lens' (C.ArchState BrickUIState arch s) (BS.BlockSelector arch s)
blockSelectorL = C.lUIState . GL.field @"sBlockSelector"

blockSelectorG :: L.Getter (C.ArchState BrickUIState arch s) (BS.BlockSelector arch s)
blockSelectorG = L.to (^. blockSelectorL)

blockViewersL :: L.Lens' (C.ArchState BrickUIState arch s) (MapF.MapF (C.IRRepr arch) (BV.BlockViewer arch s))
blockViewersL = C.lUIState . GL.field @"sBlockViewers"

blockViewerG :: C.IRRepr arch ir -> L.Getter (C.ArchState BrickUIState arch s) (Maybe (BV.BlockViewer arch s ir))
blockViewerG rep = L.to (\as -> MapF.lookup rep (as ^. blockViewersL))

functionViewerL :: L.Lens' (C.ArchState BrickUIState arch s) (FV.FunctionViewer arch s)
functionViewerL = C.lUIState . GL.field @"sFunctionViewer"

functionViewerG :: L.Getter (C.ArchState BrickUIState arch s) (FV.FunctionViewer arch s)
functionViewerG = L.to (^. functionViewerL)

contextL :: L.Lens' (C.ArchState BrickUIState arch s) (C.ContextStack arch s)
contextL = C.lUIState . GL.field @"sContext"

contextG :: L.Getter (C.ArchState BrickUIState arch s) (C.ContextStack arch s)
contextG = L.to (^. contextL)

irCacheL :: L.Lens' (C.ArchState BrickUIState arch s) (C.TranslationCache arch s)
irCacheL = C.lUIState . GL.field @"sIRCache"
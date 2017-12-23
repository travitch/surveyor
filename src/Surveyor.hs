{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
module Surveyor ( surveyor ) where

import qualified Brick as B
import qualified Brick.BChan as B
import qualified Brick.Widgets.List as B
import qualified Control.Lens as L
import qualified Data.Foldable as F
import qualified Data.Functor.Const as C
import           Data.Maybe ( fromMaybe )
import           Data.Monoid
import qualified Data.Parameterized.List as PL
import qualified Data.Parameterized.Nonce as PN
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import qualified Data.Text.Prettyprint.Doc as PP
import qualified Data.Traversable as T
import qualified Data.Vector as V
import qualified Graphics.Vty as V
import           Text.Printf ( printf )

import qualified Data.Macaw.Memory as MM
import qualified Renovate as R

import           Surveyor.Attributes
import           Surveyor.BinaryAnalysisResult
import           Surveyor.Events ( Events(..) )
import           Surveyor.Handlers ( appHandleEvent )
import           Surveyor.Loader ( asynchronouslyLoad )
import qualified Surveyor.Minibuffer as MB
import           Surveyor.Mode
import           Surveyor.State

drawSummary :: FilePath -> BinaryAnalysisResult s i a w arch -> B.Widget Names
drawSummary binFileName BinaryAnalysisResult { rBlockInfo = binfo } =
  B.vBox [ B.str ("Target binary: " ++ binFileName)
         , B.str ("Discovered functions: " ++ show (length (R.biFunctionEntries binfo)))
         , B.str ("Discovered blocks: " ++ show (length (R.biBlocks binfo)))
         ]

drawConcreteBlock :: (MM.MemWidth w) => R.ISA i a w -> R.ConcreteBlock i w -> B.Widget Names
drawConcreteBlock isa b =
  B.vBox [ B.str (printf "Block address: %s" (show (R.basicBlockAddress b)))
         , B.vBox [ B.str (R.isaPrettyInstruction isa i) | i <- R.basicBlockInstructions b ]
         ]

drawFunctionList :: (MM.MemWidth w) => S s i a w arch -> BinaryAnalysisResult s i a w arch -> B.Widget Names
drawFunctionList S { sFunctionList = flist }
                 BinaryAnalysisResult { rBlockInfo = binfo, rISA = isa } =
  B.renderList drawFunctionEntry True flist
  where
    drawFunctionEntry isFocused (FLE addr txt blockCount) =
      let focusedXfrm = if isFocused then B.withAttr focusedListAttr else id
      in focusedXfrm (B.hBox [B.str (printf "%s: %s (%d blocks)" (show (PP.pretty addr)) (T.unpack txt) blockCount)])

drawDiagnostics :: Seq.Seq T.Text -> B.Widget Names
drawDiagnostics diags = B.viewport DiagnosticView B.Vertical body
  where
    body = B.vBox [ B.txtWrap t | t <- F.toList diags ]

-- | Draw a status bar based on the current state
--
-- The status bar is a line at the bottom of the screen that reflects the
-- currently-loaded executable (if any) and includes an indicator of the
-- analysis progress.
drawStatusBar :: S s i a w arch -> B.Widget Names
drawStatusBar s =
  B.withAttr statusBarAttr (B.hBox [fileNameWidget, B.padLeft B.Max statusWidget])
  where
    fileNameWidget = B.str (fromMaybe "" (sInputFile s))
    statusWidget =
      case sAppState s of
        Loading -> B.str "Loading"
        Ready -> B.str "Ready"
        AwaitingFile -> B.str "Waiting for file"

drawEchoArea :: S s i a w arch -> B.Widget Names
drawEchoArea s =
  case Seq.viewr (sDiagnosticLog s) of
    Seq.EmptyR -> B.emptyWidget
    _ Seq.:> lastDiag -> B.txt lastDiag

drawBlockSelector :: (MM.MemWidth w) => S s i a w arch -> BinaryAnalysisResult s i a w arch -> B.Widget Names
drawBlockSelector s res =
  case V.toList (blockList L.^. B.listElementsL) of
    [] -> B.str (printf "No blocks found containing address %s" (show selectedAddr))
    [cb] -> drawConcreteBlock (rISA res) cb
    _ -> B.emptyWidget
  where
    (selectedAddr, blockList) = sBlockList s

drawAppShell :: S s i a w arch -> B.Widget Names -> [B.Widget Names]
drawAppShell s w = [B.vBox [ B.padBottom B.Max w
                           , drawStatusBar s
                           , bottomLine
                           ]
                   ]
  where
    bottomLine =
      case sUIMode s of
        SomeMiniBuffer (MiniBuffer _) -> MB.renderMinibuffer True (sMinibuffer s)
        _ ->  drawEchoArea s

appDraw :: State s -> [B.Widget Names]
appDraw (State s) =
  case sInputFile s of
    Nothing -> drawAppShell s B.emptyWidget
    Just binFileName ->
      case sBinaryInfo s of
        Nothing -> drawAppShell s B.emptyWidget
        Just binfo ->
          case sUIMode s of
            SomeMiniBuffer (MiniBuffer innerMode) ->
              drawUIMode binFileName binfo s innerMode
            SomeUIMode mode ->
              drawUIMode binFileName binfo s mode

drawUIMode :: (MM.MemWidth w)
           => FilePath
           -> BinaryAnalysisResult s i a w arch
           -> S s i a w arch
           -> UIMode NormalK
           -> [B.Widget Names]
drawUIMode binFileName binfo s uim =
  case uim of
    Diags -> drawAppShell s (drawDiagnostics (sDiagnosticLog s))
    Summary -> drawAppShell s (drawSummary binFileName binfo)
    ListFunctions -> drawAppShell s (drawFunctionList s binfo)
    BlockSelector -> drawAppShell s (drawBlockSelector s binfo)

appChooseCursor :: State s -> [B.CursorLocation Names] -> Maybe (B.CursorLocation Names)
appChooseCursor _ cursors =
  case cursors of
    [c] -> Just c
    _ -> Nothing

appAttrMap :: State s -> B.AttrMap
appAttrMap _ = B.attrMap V.defAttr [ (focusedListAttr, B.bg V.blue <> B.fg V.white)
                                   , (statusBarAttr, B.bg V.black <> B.fg V.white)
                                   ]

-- isListEventKey :: V.Key -> Bool
-- isListEventKey k =
--   case k of
--     V.KUp -> True
--     V.KDown -> True
--     V.KHome -> True
--     V.KEnd -> True
--     V.KPageDown -> True
--     V.KPageUp -> True
--     _ -> False


appStartEvent :: State s -> B.EventM Names (State s)
appStartEvent s0 = return s0

commands :: B.BChan (Events s) -> [MB.Command MB.Argument MB.TypeRepr]
commands customEventChan =
  [ MB.Command "summary" PL.Nil PL.Nil (\_ -> B.writeBChan customEventChan ShowSummary)
  , MB.Command "exit" PL.Nil PL.Nil (\_ -> B.writeBChan customEventChan Exit)
  , MB.Command "log" PL.Nil PL.Nil (\_ -> B.writeBChan customEventChan ShowDiagnostics)
  , findBlockCommand customEventChan
  ]

findBlockCommand :: B.BChan (Events s) -> MB.Command MB.Argument MB.TypeRepr
findBlockCommand customEventChan =
  MB.Command "find-block" names rep callback
  where
    names = C.Const "address" PL.:< PL.Nil
    rep = MB.AddressTypeRepr PL.:< PL.Nil
    callback = \(MB.AddressArgument addr PL.:< PL.Nil) ->
      B.writeBChan customEventChan (FindBlockContaining addr)

surveyor :: Maybe FilePath -> IO ()
surveyor mExePath = PN.withIONonceGenerator $ \ng -> do
  customEventChan <- B.newBChan 100
  let app = B.App { B.appDraw = appDraw
                  , B.appChooseCursor = appChooseCursor
                  , B.appHandleEvent = appHandleEvent
                  , B.appStartEvent = appStartEvent
                  , B.appAttrMap = appAttrMap
                  }
  _ <- T.traverse (asynchronouslyLoad ng customEventChan) mExePath
  let initialState = State S { sInputFile = mExePath
                             , sBinaryInfo = Nothing
                             , sDiagnosticLog = Seq.empty
                             , sFunctionList = B.list FunctionList (V.empty @(FunctionListEntry 64)) 1
                             , sBlockList = (MM.absoluteAddr 0, B.list BlockList V.empty 1)
                             , sUIMode = SomeUIMode Diags
                             , sAppState = maybe AwaitingFile (const Loading) mExePath
                             , sMinibuffer = MB.minibuffer MinibufferEditor MinibufferCompletionList "M-x" (commands customEventChan)
                             , sEmitEvent = B.writeBChan customEventChan
                             , sNonceGenerator = ng
                             }
  _finalState <- B.customMain (V.mkVty V.defaultConfig) (Just customEventChan) app initialState
  return ()


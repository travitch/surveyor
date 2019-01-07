{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module Surveyor.Core.Mode (
  UIMode(..),
  UIKind(..),
  NormalK,
  MiniBufferK,
  SomeUIMode(..),
  prettyMode
  ) where

import           Data.Maybe ( isJust )
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Nonce as PN
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.TH.GADT as PT
import qualified Data.Text as T
import qualified Fmt as Fmt
import           Fmt ( (+|), (||+) )

import           Surveyor.Core.IRRepr ( IRRepr )

data UIKind = MiniBufferK
            | NormalK

type MiniBufferK = 'MiniBufferK
type NormalK = 'NormalK

data UIMode s k where
  Diags :: UIMode s NormalK
  -- ^ A window containing the history of diagnostic information
  Summary :: UIMode s NormalK
  -- ^ Summary information returned by the binary analysis
  FunctionSelector :: UIMode s NormalK
  -- ^ A list of all of the discovered functions (which allows for
  -- drilling down and displaying blocks)
  BlockSelector :: UIMode s NormalK
  -- ^ A selector list for blocks that are the result of a search (based on the
  -- sBlockList in the State)
  BlockViewer :: PN.Nonce s arch -> Some (IRRepr arch) -> UIMode s NormalK
  -- ^ View a block
  FunctionViewer :: UIMode s NormalK
  -- ^ View a function
  SemanticsViewer :: UIMode s NormalK
  -- ^ View the semantics for an individual selected base IR instruction
  MiniBuffer :: UIMode s NormalK -> UIMode s MiniBufferK
  -- ^ An interactive widget that takes focus and accepts all
  -- keystrokes except for C-g

prettyMode :: UIMode s NormalK -> T.Text
prettyMode m =
  case m of
    Diags -> "Diagnostics"
    Summary -> "Summary"
    FunctionSelector -> "Function Selector"
    BlockSelector -> "Block Selector"
    BlockViewer _nonce repr -> Fmt.fmt ("Block Viewer[" +| repr ||+ "]")
    FunctionViewer -> "Function Viewer"
    SemanticsViewer -> "Semantics Viewer"

data SomeUIMode s where
  SomeMiniBuffer :: UIMode s MiniBufferK -> SomeUIMode s
  SomeUIMode :: UIMode s NormalK -> SomeUIMode s

$(return [])

instance TestEquality (UIMode s) where
  testEquality = $(PT.structuralTypeEquality [t| UIMode |]
                   [ (PT.TypeApp (PT.TypeApp (PT.ConType [t|PN.Nonce |]) PT.AnyType) PT.AnyType, [|testEquality|])
                   , (PT.TypeApp (PT.TypeApp (PT.ConType [t| UIMode |]) PT.AnyType) PT.AnyType, [|testEquality|])
                   ])

instance OrdF (UIMode s) where
  compareF = $(PT.structuralTypeOrd [t| UIMode |]
                   [ (PT.TypeApp (PT.TypeApp (PT.ConType [t|PN.Nonce |]) PT.AnyType) PT.AnyType, [|compareF|])
                   , (PT.TypeApp (PT.TypeApp (PT.ConType [t| UIMode |]) PT.AnyType) PT.AnyType, [|compareF|])
                   ])

deriving instance Eq (SomeUIMode s)
deriving instance Ord (SomeUIMode s)

instance Eq (UIMode s k) where
  u1 == u2 = isJust (testEquality u1 u2)

instance Ord (UIMode s k) where
  compare u1 u2 = toOrdering (compareF u1 u2)
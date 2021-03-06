{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
-- | The types of arguments for commands
module Surveyor.Core.Arguments (
  Argument(..),
  SomeAddress(..),
  Type(..),
  TypeRepr(..),
  IntType,
  WordType,
  AddressType,
  StringType,
  CommandType,
  FilePathType,
  ValueNonceType,
  showRepr,
  parseArgument,
  HasNonce(..),
  SomeState(..),
  SomeNonce(..),
  SurveyorCommand
  ) where

import qualified Data.Foldable as F
import qualified Data.Kind as K
import qualified Data.Map.Strict as M
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Nonce as PN
import qualified Data.Text as T
import qualified Data.Text.Zipper.Generic as Z
import           Numeric.Natural ( Natural )
import           Text.Read ( readMaybe )
import qualified What4.BaseTypes as WT

import qualified Surveyor.Core.Architecture as A
import qualified Surveyor.Core.Events as E
import qualified Surveyor.Core.Command as C

data SurveyorCommand (s :: K.Type ) (st :: K.Type  -> K.Type  -> K.Type )

class HasNonce st where
  getNonce :: SomeState st s -> SomeNonce s

data SomeState st s where
  SomeState :: (A.Architecture arch s) => st arch s -> SomeState st s

type instance C.ArgumentKind (SurveyorCommand s st) = Type

instance C.CommandLike (SurveyorCommand s st) where
  type EventType (SurveyorCommand s st) = E.Events s st
  type StateType (SurveyorCommand s st) = SomeState st s
  type ArgumentType (SurveyorCommand s st) = Argument s
  type ArgumentRepr (SurveyorCommand s st) = TypeRepr

-- | This is a separate wrapper (instead of the Some from parameterized-utils)
-- because we want to constrain it with a kind signature.
data SomeNonce s where
  SomeNonce :: forall (arch :: K.Type ) s . PN.Nonce s arch -> SomeNonce s

data Type where
  StringType :: Type
  AddressType :: Type
  IntType :: Type
  WordType :: Type
  CommandType :: Type
  FilePathType :: Type
  ValueNonceType :: Type

type StringType = 'StringType
type AddressType = 'AddressType
type IntType = 'IntType
type WordType = 'WordType
type CommandType = 'CommandType
type FilePathType = 'FilePathType
type ValueNonceType = 'ValueNonceType

data TypeRepr tp where
  CommandTypeRepr :: TypeRepr CommandType
  StringTypeRepr :: TypeRepr StringType
  AddressTypeRepr :: TypeRepr AddressType
  IntTypeRepr :: TypeRepr IntType
  WordTypeRepr :: TypeRepr WordType
  FilePathTypeRepr :: TypeRepr FilePathType
  ValueNonceTypeRepr :: TypeRepr ValueNonceType

instance TestEquality TypeRepr where
  testEquality CommandTypeRepr CommandTypeRepr = Just Refl
  testEquality StringTypeRepr StringTypeRepr = Just Refl
  testEquality AddressTypeRepr AddressTypeRepr = Just Refl
  testEquality IntTypeRepr IntTypeRepr = Just Refl
  testEquality WordTypeRepr WordTypeRepr = Just Refl
  testEquality FilePathTypeRepr FilePathTypeRepr = Just Refl
  testEquality ValueNonceTypeRepr ValueNonceTypeRepr = Just Refl
  testEquality _ _ = Nothing

data SomeAddress s where
  SomeAddress :: (A.Architecture arch s) => PN.Nonce s arch -> A.Address arch s -> SomeAddress s

data Argument s tp where
  CommandArgument :: C.SomeCommand (SurveyorCommand s st) -> Argument s CommandType
  StringArgument :: T.Text -> Argument s StringType
  AddressArgument :: SomeAddress s -> Argument s AddressType
  IntArgument :: Integer -> Argument s IntType
  WordArgument :: Natural -> Argument s WordType
  FilePathArgument :: FilePath -> Argument s FilePathType
  ValueNonceArgument :: PN.Nonce s (tp :: WT.BaseType) -> Argument s ValueNonceType

parseArgument :: (Z.GenericTextZipper t)
              => (String -> Maybe (SomeAddress s))
              -> [C.SomeCommand (SurveyorCommand s st)]
              -> t
              -> (TypeRepr tp -> Maybe (Argument s tp))
parseArgument parseAddress cmds =
  let indexCommand m (C.SomeCommand cmd) = M.insert (C.cmdName cmd) (C.SomeCommand cmd) m
      cmdIndex = F.foldl' indexCommand M.empty cmds
  in \(Z.toList -> txt) rep ->
    case rep of
      StringTypeRepr -> Just (StringArgument (T.pack txt))
      IntTypeRepr -> IntArgument <$> readMaybe txt
      WordTypeRepr -> WordArgument <$> readMaybe txt
      AddressTypeRepr -> AddressArgument <$> parseAddress txt
      CommandTypeRepr ->
        let t = T.pack txt
        in CommandArgument <$> M.lookup t cmdIndex
      FilePathTypeRepr -> Just (FilePathArgument txt)
      ValueNonceTypeRepr ->
        -- We can't read in nonces, since it would break the abstraction
        Nothing

showRepr :: TypeRepr tp -> T.Text
showRepr r =
  case r of
    StringTypeRepr -> "String"
    AddressTypeRepr -> "Address"
    IntTypeRepr -> "Int"
    WordTypeRepr -> "Word"
    CommandTypeRepr -> "Command"
    FilePathTypeRepr -> "FilePath"
    ValueNonceTypeRepr -> "Nonce"

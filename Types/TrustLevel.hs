{- git-annex trust levels
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Types.TrustLevel (
	TrustLevel(..),
	TrustMap,
	readTrustLevel,
	showTrustLevel,
) where

import qualified Data.Map as M

import Types.UUID

data TrustLevel = Trusted | SemiTrusted | UnTrusted | DeadTrusted
	deriving (Eq, Enum, Ord)

type TrustMap = M.Map UUID TrustLevel

readTrustLevel :: String -> Maybe TrustLevel
readTrustLevel "trusted" = Just Trusted
readTrustLevel "untrusted" = Just UnTrusted
readTrustLevel "semitrusted" = Just SemiTrusted
readTrustLevel "dead" = Just DeadTrusted
readTrustLevel _ = Nothing

showTrustLevel :: TrustLevel -> String
showTrustLevel Trusted = "trusted"
showTrustLevel UnTrusted = "untrusted"
showTrustLevel SemiTrusted = "semitrusted"
showTrustLevel DeadTrusted = "dead"

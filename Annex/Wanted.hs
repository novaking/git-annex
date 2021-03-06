{- git-annex control over whether content is wanted
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.Wanted where

import Common.Annex
import Logs.PreferredContent
import Annex.UUID
import Types.Remote

import qualified Data.Set as S

{- Check if a file is preferred content for the local repository. -}
wantGet :: AssociatedFile -> Annex Bool
wantGet Nothing = return True
wantGet (Just file) = isPreferredContent Nothing S.empty file

{- Check if a file is preferred content for a remote. -}
wantSend :: AssociatedFile -> UUID -> Annex Bool
wantSend Nothing _ = return True
wantSend (Just file) to = isPreferredContent (Just to) S.empty file

{- Check if a file can be dropped, maybe from a remote.
 - Don't drop files that are preferred content. -}
wantDrop :: Maybe UUID -> AssociatedFile -> Annex Bool
wantDrop _ Nothing = return True
wantDrop from (Just file) = do
	u <- maybe getUUID (return . id) from
	not <$> isPreferredContent (Just u) (S.singleton u) file

{- git-annex assistant webapp core
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE TypeFamilies, QuasiQuotes, MultiParamTypeClasses, TemplateHaskell, OverloadedStrings, RankNTypes #-}

module Assistant.WebApp where

import Assistant.WebApp.Types
import Assistant.Common
import Assistant.Alert
import Utility.NotificationBroadcaster
import Utility.Yesod
import Locations.UserConfig

import Yesod
import Text.Hamlet
import Data.Text (Text)
import Control.Concurrent.STM
import Control.Concurrent

data NavBarItem = DashBoard | Config | About
	deriving (Eq)

navBarName :: NavBarItem -> Text
navBarName DashBoard = "Dashboard"
navBarName Config = "Configuration"
navBarName About = "About"

navBarRoute :: NavBarItem -> Route WebApp
navBarRoute DashBoard = HomeR
navBarRoute Config = ConfigR
navBarRoute About = AboutR

defaultNavBar :: [NavBarItem]
defaultNavBar = [DashBoard, Config, About]

firstRunNavBar :: [NavBarItem]
firstRunNavBar = [Config, About]

selectNavBar :: Handler [NavBarItem]
selectNavBar = ifM (inFirstRun) (return firstRunNavBar, return defaultNavBar)

inFirstRun :: Handler Bool
inFirstRun = isNothing . relDir <$> getYesod

{- Used instead of defaultContent; highlights the current page if it's
 - on the navbar. -}
bootstrap :: Maybe NavBarItem -> Widget -> Handler RepHtml
bootstrap navbaritem content = do
	webapp <- getYesod
	navbar <- map navdetails <$> selectNavBar
	page <- widgetToPageContent $ do
		addStylesheet $ StaticR css_bootstrap_css
		addStylesheet $ StaticR css_bootstrap_responsive_css
		addScript $ StaticR jquery_full_js
		addScript $ StaticR js_bootstrap_dropdown_js
		addScript $ StaticR js_bootstrap_modal_js
		$(widgetFile "page")
	hamletToRepHtml $(hamletFile $ hamletTemplate "bootstrap")
  where
	navdetails i = (navBarName i, navBarRoute i, Just i == navbaritem)

newWebAppState :: IO (TMVar WebAppState)
newWebAppState = do
	otherrepos <- listOtherRepos
	atomically $ newTMVar $ WebAppState
		{ showIntro = True
		, otherRepos = otherrepos }

liftAssistant :: forall sub a. (Assistant a) -> GHandler sub WebApp a
liftAssistant a = liftIO . flip runAssistant a =<< assistantData <$> getYesod

getWebAppState :: forall sub. GHandler sub WebApp WebAppState
getWebAppState = liftIO . atomically . readTMVar =<< webAppState <$> getYesod

modifyWebAppState :: forall sub. (WebAppState -> WebAppState) -> GHandler sub WebApp ()
modifyWebAppState a = go =<< webAppState <$> getYesod
  where
	go s = liftIO $ atomically $ do
		v <- takeTMVar s
		putTMVar s $ a v

{- Runs an Annex action from the webapp.
 -
 - When the webapp is run outside a git-annex repository, the fallback
 - value is returned.
 -}
runAnnex :: forall sub a. a -> Annex a -> GHandler sub WebApp a
runAnnex fallback a = ifM (noAnnex <$> getYesod)
	( return fallback
	, liftAssistant $ liftAnnex a
	)

waitNotifier :: forall sub. (Assistant NotificationBroadcaster) -> NotificationId -> GHandler sub WebApp ()
waitNotifier getbroadcaster nid = liftAssistant $ do
	b <- getbroadcaster
	liftIO $ waitNotification $ notificationHandleFromId b nid

newNotifier :: forall sub. (Assistant NotificationBroadcaster) -> GHandler sub WebApp NotificationId
newNotifier getbroadcaster = liftAssistant $ do
	b <- getbroadcaster
	liftIO $ notificationHandleToId <$> newNotificationHandle b

{- Adds the auth parameter as a hidden field on a form. Must be put into
 - every form. -}
webAppFormAuthToken :: Widget
webAppFormAuthToken = do
	webapp <- lift getYesod
	[whamlet|<input type="hidden" name="auth" value="#{secretToken webapp}">|]

{- A button with an icon, and maybe label or tooltip, that can be
 - clicked to perform some action.
 - With javascript, clicking it POSTs the Route, and remains on the same
 - page.
 - With noscript, clicking it GETs the Route. -}
actionButton :: Route WebApp -> (Maybe String) -> (Maybe String) -> String -> String -> Widget
actionButton route label tooltip buttonclass iconclass = $(widgetFile "actionbutton")

type UrlRenderFunc = Route WebApp -> [(Text, Text)] -> Text
type UrlRenderer = MVar (UrlRenderFunc)

newUrlRenderer :: IO UrlRenderer
newUrlRenderer = newEmptyMVar

setUrlRenderer :: UrlRenderer -> (UrlRenderFunc) -> IO ()
setUrlRenderer = putMVar

{- Blocks until the webapp is running and has called setUrlRenderer. -}
renderUrl :: UrlRenderer -> Route WebApp -> [(Text, Text)] -> IO Text
renderUrl urlrenderer route params = do
	r <- readMVar urlrenderer
	return $ r route params

{- Redirects back to the referring page, or if there's none, HomeR -}
redirectBack :: Handler ()
redirectBack = do
	clearUltDest
	setUltDestReferer
	redirectUltDest HomeR

{- List of other known repsitories, and link to add a new one. -}
otherReposWidget :: Widget
otherReposWidget = do
	repolist <- lift $ otherRepos <$> getWebAppState
	$(widgetFile "otherrepos")

listOtherRepos :: IO [(String, String)]
listOtherRepos = do
	f <- autoStartFile
	dirs <- nub <$> ifM (doesFileExist f) ( lines <$> readFile f, return [])
	names <- mapM relHome dirs
	return $ sort $ zip names dirs

htmlIcon :: AlertIcon -> GWidget sub master ()
htmlIcon ActivityIcon = bootStrapIcon "refresh"
htmlIcon InfoIcon = bootStrapIcon "info-sign"
htmlIcon SuccessIcon = bootStrapIcon "ok"
htmlIcon ErrorIcon = bootStrapIcon "exclamation-sign"
-- utf-8 umbrella (utf-8 cloud looks too stormy)
htmlIcon TheCloud = [whamlet|&#9730;|]

bootStrapIcon :: Text -> GWidget sub master ()
bootStrapIcon name = [whamlet|<i .icon-#{name}></i>|]

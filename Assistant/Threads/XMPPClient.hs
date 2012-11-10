{- git-annex XMPP client
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Assistant.Threads.XMPPClient where

import Assistant.Common
import Assistant.XMPP
import Assistant.XMPP.Client
import Assistant.NetMessager
import Assistant.Types.NetMessager
import Assistant.Types.Buddies
import Assistant.XMPP.Buddies
import Assistant.Sync
import Assistant.DaemonStatus
import qualified Remote
import Utility.ThreadScheduler
import Assistant.WebApp (UrlRenderer, renderUrl)
import Assistant.WebApp.Types
import Assistant.Alert
import Assistant.Pairing
import Assistant.XMPP.Git
import Annex.UUID

import Network.Protocol.XMPP
import Control.Concurrent
import qualified Data.Text as T
import qualified Data.Set as S
import qualified Data.Map as M
import qualified Git.Branch
import Data.Time.Clock

xmppClientThread :: UrlRenderer -> NamedThread
xmppClientThread urlrenderer = NamedThread "XMPPClient" $
	restartableClient . xmppClient urlrenderer =<< getAssistant id

{- Runs the client, handing restart events. -}
restartableClient :: IO () -> Assistant ()
restartableClient a = forever $ do
	tid <- liftIO $ forkIO a
	waitNetMessagerRestart
	liftIO $ killThread tid

xmppClient :: UrlRenderer -> AssistantData -> IO ()
xmppClient urlrenderer d = do
	v <- liftAssistant $ liftAnnex getXMPPCreds
	case v of
		Nothing -> noop -- will be restarted once creds get configured
		Just c -> retry (runclient c) =<< getCurrentTime
  where
	liftAssistant = runAssistant d
	inAssistant = liftIO . liftAssistant

	{- When the client exits, it's restarted;
 	 - if it keeps failing, back off to wait 5 minutes before
	 - trying it again. -}
	retry client starttime = do
		e <- client
		now <- getCurrentTime
		if diffUTCTime now starttime > 300
			then do
				liftAssistant $ debug ["connection lost; reconnecting", show e]
				retry client now
			else do
				liftAssistant $ debug ["connection failed; will retry", show e]
				threadDelaySeconds (Seconds 300)
				retry client =<< getCurrentTime

	runclient c = liftIO $ connectXMPP c $ \jid -> do
		selfjid <- bindJID jid
		putStanza gitAnnexSignature

		inAssistant $ debug ["connected", show selfjid]
		{- The buddy list starts empty each time
		 - the client connects, so that stale info
		 - is not retained. -}
		void $ inAssistant $
			updateBuddyList (const noBuddies) <<~ buddyList

		xmppThread $ receivenotifications selfjid
		forever $ do
			a <- inAssistant $ relayNetMessage selfjid
			a

	receivenotifications selfjid = forever $ do
		l <- decodeStanza selfjid <$> getStanza
		-- inAssistant $ debug ["received:", show l]
		mapM_ (handle selfjid) l

	handle _ (PresenceMessage p) = void $ inAssistant $ 
		updateBuddyList (updateBuddies p) <<~ buddyList
	handle _ (GotNetMessage QueryPresence) = putStanza gitAnnexSignature
	handle _ (GotNetMessage (NotifyPush us)) = void $ inAssistant $ pull us
	handle selfjid (GotNetMessage (PairingNotification stage c u)) =
		maybe noop (inAssistant . pairMsgReceived urlrenderer stage u selfjid) (parseJID c)
	handle _ (GotNetMessage pushmsg)
		| isPushInitiationMessage pushmsg = inAssistant $
			unlessM (queueNetPushMessage pushmsg) $ 
				void $ forkIO <~> handlePushMessage pushmsg
		| otherwise = void $ inAssistant $ queueNetPushMessage pushmsg
	handle _ (Ignorable _) = noop
	handle _ (Unknown _) = noop
	handle _ (ProtocolError _) = noop


data XMPPEvent
	= GotNetMessage NetMessage
	| PresenceMessage Presence
	| Ignorable ReceivedStanza
	| Unknown ReceivedStanza
	| ProtocolError ReceivedStanza
	deriving Show

{- Decodes an XMPP stanza into one or more events. -}
decodeStanza :: JID -> ReceivedStanza -> [XMPPEvent]
decodeStanza selfjid s@(ReceivedPresence p)
	| presenceType p == PresenceError = [ProtocolError s]
	| presenceFrom p == Nothing = [Ignorable s]
	| presenceFrom p == Just selfjid = [Ignorable s]
	| otherwise = maybe [PresenceMessage p] decode (getGitAnnexAttrValue p)
  where
	decode (attr, v, _tag)
		| attr == pushAttr = impliedp $ GotNetMessage $ NotifyPush $
			decodePushNotification v
		| attr == queryAttr = impliedp $ GotNetMessage QueryPresence
		| otherwise = [Unknown s]
	{- Things sent via presence imply a presence message,
	 - along with their real meaning. -}
	impliedp v = [PresenceMessage p, v]
decodeStanza selfjid s@(ReceivedMessage m)
	| messageFrom m == Nothing = [Ignorable s]
	| messageFrom m == Just selfjid = [Ignorable s]
	| messageType m == MessageError = [ProtocolError s]
	| otherwise = maybe [Unknown s] decode (getGitAnnexAttrValue m)
  where
	decode (attr, v, tag)
		| attr == pairAttr = use $ decodePairingNotification v
		| attr == canPushAttr = use decodeCanPush
		| attr == pushRequestAttr = use decodePushRequest
		| attr == startingPushAttr = use decodeStartingPush
		| attr == receivePackAttr = use $ decodeReceivePackOutput tag
		| attr == sendPackAttr = use $ decodeSendPackOutput tag
		| attr == receivePackDoneAttr = use $ decodeReceivePackDone v
		| otherwise = [Unknown s]
	use v = [maybe (Unknown s) GotNetMessage (v m)]
decodeStanza _ s = [Unknown s]

{- Waits for a NetMessager message to be sent, and relays it to XMPP. -}
relayNetMessage :: JID -> Assistant (XMPP ())
relayNetMessage selfjid = convert =<< waitNetMessage
  where
	convert (NotifyPush us) = return $ putStanza $ pushNotification us
	convert QueryPresence = return $ putStanza presenceQuery
	convert (PairingNotification stage c u) = withclient c $ \tojid -> do
		changeBuddyPairing tojid True
		return $ putStanza $ pairingNotification stage u tojid selfjid
	convert (CanPush c) = sendclient c canPush
	convert (PushRequest c) = sendclient c pushRequest
	convert (StartingPush c) = sendclient c startingPush
	convert (ReceivePackOutput c b) = sendclient c $ receivePackOutput b
	convert (SendPackOutput c b) = sendclient c $ sendPackOutput b
	convert (ReceivePackDone c code) = sendclient c $ receivePackDone code

	sendclient c construct = withclient c $ \tojid ->
		return $ putStanza $ construct tojid selfjid
	withclient c a = case parseJID c of
		Nothing -> return noop
		Just tojid
			| tojid == selfjid -> return noop
			| otherwise -> a tojid

{- Runs a XMPP action in a separate thread, using a session to allow it
 - to access the same XMPP client. -}
xmppThread :: XMPP () -> XMPP ()
xmppThread a = do
	s <- getSession
	void $ liftIO $ forkIO $
		void $ runXMPP s a

{- We only pull from one remote out of the set listed in the push
 - notification, as an optimisation.
 -
 - Note that it might be possible (though very unlikely) for the push
 - notification to take a while to be sent, and multiple pushes happen
 - before it is sent, so it includes multiple remotes that were pushed
 - to at different times. 
 -
 - It could then be the case that the remote we choose had the earlier
 - push sent to it, but then failed to get the later push, and so is not
 - fully up-to-date. If that happens, the pushRetryThread will come along
 - and retry the push, and we'll get another notification once it succeeds,
 - and pull again. -}
pull :: [UUID] -> Assistant ()
pull [] = noop
pull us = do
	rs <- filter matching . syncRemotes <$> getDaemonStatus
	debug $ "push notification for" : map (fromUUID . Remote.uuid ) rs
	pullone rs =<< liftAnnex (inRepo Git.Branch.current)
  where
	matching r = Remote.uuid r `S.member` s
	s = S.fromList us

	pullone [] _ = noop
	pullone (r:rs) branch =
		unlessM (all id . fst <$> manualPull branch [r]) $
			pullone rs branch

pairMsgReceived :: UrlRenderer -> PairStage -> UUID -> JID -> JID -> Assistant ()
pairMsgReceived urlrenderer PairReq theiruuid selfjid theirjid
	-- PairReq from another client using our JID is automatically accepted.
	| baseJID selfjid == baseJID theirjid = do
		selfuuid <- liftAnnex getUUID
		sendNetMessage $
			PairingNotification PairAck (formatJID theirjid) selfuuid
		finishXMPPPairing theirjid theiruuid
	-- Show an alert to let the user decide if they want to pair.
	| otherwise = do
		let route = FinishXMPPPairR (PairKey theiruuid $ formatJID theirjid)
		url <- liftIO $ renderUrl urlrenderer route []
		close <- asIO1 removeAlert
		void $ addAlert $ pairRequestReceivedAlert (T.unpack $ buddyName theirjid)
			AlertButton
				{ buttonUrl = url
				, buttonLabel = T.pack "Respond"
				, buttonAction = Just close
				}

pairMsgReceived _ PairAck theiruuid _selfjid theirjid =
	{- PairAck must come from one of the buddies we are pairing with;
	 - don't pair with just anyone. -}
	whenM (isBuddyPairing theirjid) $ do
		changeBuddyPairing theirjid False
		selfuuid <- liftAnnex getUUID
		sendNetMessage $
			PairingNotification PairDone (formatJID theirjid) selfuuid
		finishXMPPPairing theirjid theiruuid

pairMsgReceived _ PairDone _theiruuid _selfjid theirjid =
	changeBuddyPairing theirjid False

isBuddyPairing :: JID -> Assistant Bool
isBuddyPairing jid = maybe False buddyPairing <$> 
	getBuddy (genBuddyKey jid) <<~ buddyList

changeBuddyPairing :: JID -> Bool -> Assistant ()
changeBuddyPairing jid ispairing =
	updateBuddyList (M.adjust set key) <<~ buddyList
  where
	key = genBuddyKey jid
	set b = b { buddyPairing = ispairing }
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad
import Control.Monad.Reader
import Data.Aeson
import Data.Default
import qualified Data.HashMap.Strict as HM
import Data.List (isSuffixOf)
import Language.Haskell.LSP.Control
import Language.Haskell.LSP.Core
import Language.Haskell.LSP.Types
import System.Directory
import System.FilePath
import UnliftIO
import UnliftIO.Concurrent

main = do
  handlerEnv <- HandlerEnv <$> newEmptyMVar <*> newEmptyMVar
  let initCbs =
        InitializeCallbacks
          { doInitialize = \env _req -> pure $ Right env,
            onConfigurationChange = const $ pure $ Right (),
            staticHandlers = handlers,
            interpretHandler = \env ->
              Iso
                (\m -> runLspT env (runReaderT m handlerEnv))
                liftIO
          }
      options = def {executeCommandCommands = Just ["doAnEdit"]}
  run initCbs options

data HandlerEnv = HandlerEnv
  { relRegToken :: MVar (RegistrationToken WorkspaceDidChangeWatchedFiles),
    absRegToken :: MVar (RegistrationToken WorkspaceDidChangeWatchedFiles)
  }

handlers :: Handlers (ReaderT HandlerEnv (LspM ()))
handlers =
  mconcat
    [ notificationHandler SInitialized $
        \_noti ->
          sendNotification SWindowLogMessage $
            LogMessageParams MtLog "initialized",
      requestHandler STextDocumentHover $
        \_req responder ->
          responder $
            Right $
              Just $
                Hover (HoverContents (MarkupContent MkPlainText "hello")) Nothing,
      requestHandler STextDocumentDocumentSymbol $
        \_req responder ->
          responder $
            Right $
              InL $
                List
                  [ DocumentSymbol
                      "foo"
                      Nothing
                      SkObject
                      Nothing
                      (mkRange 0 0 3 6)
                      (mkRange 0 0 3 6)
                      Nothing
                  ],
      notificationHandler STextDocumentDidOpen $
        \noti -> do
          let NotificationMessage _ _ (DidOpenTextDocumentParams doc) = noti
              TextDocumentItem uri _ _ _ = doc
              Just fp = uriToFilePath uri
              diag =
                Diagnostic
                  (mkRange 0 0 0 1)
                  (Just DsWarning)
                  (Just (InL 42))
                  (Just "dummy-server")
                  "Here's a warning"
                  Nothing
                  Nothing
          withRunInIO $
            \runInIO -> do
              when (".hs" `isSuffixOf` fp) $
                void $
                  forkIO $
                    do
                      threadDelay (2 * 10 ^ 6)
                      runInIO $
                        sendNotification STextDocumentPublishDiagnostics $
                          PublishDiagnosticsParams uri Nothing (List [diag])
              -- also act as a registerer for workspace/didChangeWatchedFiles
              when (".register" `isSuffixOf` fp) $
                do
                  let regOpts =
                        DidChangeWatchedFilesRegistrationOptions $
                          List
                            [ FileSystemWatcher
                                "*.watch"
                                (Just (WatchKind True True True))
                            ]
                  Just token <- runInIO $
                    registerCapability SWorkspaceDidChangeWatchedFiles regOpts $
                      \_noti ->
                        sendNotification SWindowLogMessage $
                          LogMessageParams MtLog "got workspace/didChangeWatchedFiles"
                  runInIO $ asks relRegToken >>= \v -> putMVar v token
              when (".register.abs" `isSuffixOf` fp) $
                do
                  curDir <- getCurrentDirectory
                  let regOpts =
                        DidChangeWatchedFilesRegistrationOptions $
                          List
                            [ FileSystemWatcher
                                (curDir </> "*.watch")
                                (Just (WatchKind True True True))
                            ]
                  Just token <- runInIO $
                    registerCapability SWorkspaceDidChangeWatchedFiles regOpts $
                      \_noti ->
                        sendNotification SWindowLogMessage $
                          LogMessageParams MtLog "got workspace/didChangeWatchedFiles"
                  runInIO $ asks absRegToken >>= \v -> putMVar v token
              -- also act as an unregisterer for workspace/didChangeWatchedFiles
              when (".unregister" `isSuffixOf` fp) $
                do
                  Just token <- runInIO $ asks relRegToken >>= tryReadMVar
                  runInIO $ unregisterCapability token
              when (".unregister.abs" `isSuffixOf` fp) $
                do
                  Just token <- runInIO $ asks absRegToken >>= tryReadMVar
                  runInIO $ unregisterCapability token,
      requestHandler SWorkspaceExecuteCommand $ \req resp -> do
        let RequestMessage _ _ _ (ExecuteCommandParams Nothing "doAnEdit" (Just (List [val]))) = req
            Success docUri = fromJSON val
            edit = List [TextEdit (mkRange 0 0 0 5) "howdy"]
            params =
              ApplyWorkspaceEditParams (Just "Howdy edit") $
                WorkspaceEdit (Just (HM.singleton docUri edit)) Nothing
        resp $ Right Null
        void $ sendRequest SWorkspaceApplyEdit params (const (pure ())),
      requestHandler STextDocumentCodeAction $ \req resp -> do
        let RequestMessage _ _ _ params = req
            CodeActionParams _ _ _ _ cactx = params
            CodeActionContext diags _ = cactx
            codeActions = fmap diag2ca diags
            diag2ca d =
              CodeAction
                "Delete this"
                Nothing
                (Just (List [d]))
                Nothing
                Nothing
                (Just (Command "" "deleteThis" Nothing))
        resp $ Right $ InR <$> codeActions,
      requestHandler STextDocumentCompletion $ \_req resp -> do
        let res = CompletionList True (List [item])
            item =
              CompletionItem
                "foo"
                (Just CiConstant)
                (Just (List []))
                Nothing
                Nothing
                Nothing
                Nothing
                Nothing
                Nothing
                Nothing
                Nothing
                Nothing
                Nothing
                Nothing
                Nothing
                Nothing
        resp $ Right $ InR res
    ]

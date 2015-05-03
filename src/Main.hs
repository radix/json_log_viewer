{-# LANGUAGE NamedWildCards        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TupleSections         #-}

module Main where

-- There are a few big gross things about this app
-- 1. The code is poorly factored (my fault)
-- 2. There is no good "model/view" layer in vty-ui. Dealing with the lists of
--    messages, pinned messages, and filters, is tedious and error-prone. If
--    List widgets wrapped and observed ListModels instead of making me
--    manually manage everything in the list, everything would be a lot
--    better. I could certainly implement such a layer myself but so far I
--    have just suffered through it.
-- 3. All the UI setup code is pointlessly in the IO monad. It seems so much
--    better to me (a Haskell newbie, so take that with a grain of salt) that
--    only runUi, various "set" functions, and event handlers should return IO,
--    and there should be some pure API for constructing trees of
--    widgets.
-- 4. (I'm not so sure on this one) Widget types depend on their contents. I
--    like the idea of strongly typing as much as possible, but it's annoyed me
--    a few times. The annoyance is drastically lessened with use of GHC's new
--    "partial type signatures", so I can just try to ignore the contents of
--    widgets.
-- 5. There's no show/hide mechanism in vty-ui, and the "Group" widget will
--    only allow replacing a widget with the *same type* of widget (see #4).


-- Doing List as a view/model thing will be kind of tricky. For my use case it
-- would require the ability to indicate list items to show/hide.


import           Control.Concurrent         (forkIO)
import           Control.Monad              (forever, unless, when)
import qualified Data.Aeson                 as Aeson
import           Data.Aeson.Encode.Pretty   (encodePretty)
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Lazy       as BSL
import           Data.Char                  (isSpace)
import           Data.Foldable              (toList)
import qualified Data.HashMap.Strict        as HM
import           Data.IORef                 (IORef, modifyIORef, newIORef,
                                             readIORef, writeIORef)
import           Data.Maybe                 (mapMaybe)
import           Data.Sequence              ((><))
import qualified Data.Sequence              as Seq
import qualified Data.Text                  as T
import           Data.Text.Encoding         (decodeUtf8)
import qualified Graphics.Vty.Input.Events  as Events
import           Graphics.Vty.Widgets.All   ((<++>), (<-->))
import qualified Graphics.Vty.Widgets.All   as UI
import           System.Environment         (getArgs)
import           System.Exit                (exitSuccess)
import           System.IO                  (BufferMode (LineBuffering), Handle,
                                             hIsSeekable, hReady, hSetBuffering)
import           System.Posix.IO            (fdToHandle)
import           System.Posix.Types         (Fd (Fd))

import           JsonLogViewer.FilterDialog (blankFilterDialog,
                                             filterFromDialog, makeFilterDialog,
                                             setDefaultsFromFilter)
import           JsonLogViewer.Filtration   (IsActive (..), LogFilter (..),
                                             matchFilter)
import           JsonLogViewer.Settings     (getSettingsFilePath,
                                             loadSettingsFile,
                                             writeSettingsFile)
import           JsonLogViewer.UIUtils      (makeCoolList, makeEditField)

-- purely informative type synonyms
newtype IsPinned = IsPinned { unIsPinned :: Bool } deriving Show
newtype LinesCallback = LinesCallback { unLinesCallback :: [BS.ByteString] -> IO () }
type FilterName = T.Text
type Filters = [LogFilter]
type Message = (IsPinned, Aeson.Value)
type Messages = Seq.Seq Message
type MessagesRef = IORef Messages
type PinnedListEntry = (Int, Aeson.Value) -- ^ The Int is an index into the
                                          -- Messages sequence.
type FiltersRef = IORef Filters
type ColumnsRef = IORef [T.Text]
type CurrentlyFollowing = Bool
type FiltersIndex = Int -- ^ Index into the FiltersRef sequence

-- Widgets
type MessageListWidget = UI.Widget (UI.List Int UI.FormattedText)
type FilterListWidget = UI.Widget (UI.List LogFilter UI.FormattedText)
type PinnedListWidget = UI.Widget (UI.List PinnedListEntry UI.FormattedText)


-- |Return True if the message should be shown in the UI (if it's pinned or
-- matches filters)
shouldShowMessage :: [LogFilter] -> (IsPinned, Aeson.Value) -> Bool
shouldShowMessage filters (pinned, json) = unIsPinned pinned || all (`matchFilter` json) activeFilters
  where activeFilters = filter (unIsActive . filterIsActive) filters

-- super general utilities

replaceAtIndex :: Int -> a -> [a] -> [a]
replaceAtIndex index item ls = a ++ (item:b) where (a, _:b) = splitAt index ls

jsonToText :: Aeson.Value -> T.Text
jsonToText = decodeUtf8 . BSL.toStrict . Aeson.encode

removeSlice :: Int -> Int -> [a] -> [a]
removeSlice n m xs = take n xs ++ drop m xs

removeIndex :: Int -> [a] -> [a]
removeIndex n = removeSlice n (n+1)


-- |Given a list of columns and a json value, format it.
columnify :: [T.Text] -> Aeson.Value -> T.Text
columnify columns message =
  case message of
       (Aeson.Object hashmap) -> T.concat $ fmap (getColumn hashmap) columns
       _ -> "not an object"
  where getColumn hashmap column =
          case HM.lookup column hashmap of
           (Just (Aeson.String str)) ->
             if "\n" `T.isInfixOf` str -- the list widgets won't show anything
                                     -- after a newline, so don't include them
             then renderWithKey column (T.pack $ show str)
             else renderWithKey column str
           (Just (Aeson.Number num)) -> renderWithKey column $ T.pack $ show num
           (Just x) -> renderWithKey column (T.pack $ show x)
           _ -> ""
        renderWithKey key str = key `T.append` "=" `T.append` str `T.append` " "

-- |Given a list of columns and a json value, format it. If columns is null,
-- the plain json is returned.
formatMessage :: [T.Text] -> Aeson.Value -> T.Text
formatMessage columns message = if null columns
                                then jsonToText message
                                else columnify columns message

-- UI code. It's groooooss.


headerText :: T.Text
headerText = "ESC=Exit, TAB=Switch section, D=Delete filter, RET=Open, \
             \P=Pin message, F=Create Filter, C=Change Columns, E=Follow end, \
             \Ctrl+s=Save settings"

makeMainWindow
  :: MessagesRef -> FiltersRef -> IORef Bool -> ColumnsRef
  -> IO (UI.Widget _W , -- ^ main widget
         MessageListWidget,
         FilterListWidget,
         PinnedListWidget,
         IO (), -- ^ refreshMessages
         Seq.Seq (IsPinned, Aeson.Value) -> IO (), -- ^ addmessage
         UI.Widget UI.Edit -- ^ column edit widget
        )
makeMainWindow messagesRef filtersRef followingRef columnsRef = do
  mainHeader <- UI.plainText headerText

  (messageList, messagesWidget) <- makeCoolList 1 "Messages"
  (pinnedList, pinBorder) <- makeCoolList 1 "Pinned Messages"
  (filterList, borderedFilters) <- makeCoolList 1 "Filters"
  (columnsEdit, columnsField) <- makeEditField "Columns:"

  rightArea <- return columnsField
               <-->
               return pinBorder
               <-->
               return messagesWidget
  let leftArea = borderedFilters
  body <- return leftArea <++> return rightArea
  UI.setBoxChildSizePolicy body $ UI.Percentage 15
  headerAndBody <- return mainHeader
                   <-->
                   return body
  ui <- UI.centered headerAndBody

  let refreshMessages = do
        messages <- readIORef messagesRef
        filters <- readIORef filtersRef
        -- update filters list
        let renderFilter filt = if unIsActive $ filterIsActive filt
                                then T.append "* " $ filterName filt
                                else T.append "- " $ filterName filt
        filterWidgets <- mapM (UI.plainText . renderFilter) filters
        let filterItems = zip filters filterWidgets
        UI.clearList filterList
        UI.addMultipleToList filterList filterItems
        -- update messages list
        UI.clearList messageList
        currentlyFollowing <- readIORef followingRef
        columns <- readIORef columnsRef
        UI.setEditText columnsEdit $ T.intercalate ", " columns
        addMessagesToUI 0 filters columns messageList messages currentlyFollowing
        -- update pinned messages (in case columns changed)
        pinnedSize <- UI.getListSize pinnedList
        let rerenderPinned index = do
              mPinnedWidget <- UI.getListItem pinnedList index
              case mPinnedWidget of
               Just ((_, json), widget) -> UI.setText widget $ formatMessage columns json
               Nothing -> error "could't find pinned item when going through what should be all of its valid indices"
        mapM_ rerenderPinned [0..pinnedSize - 1]
      addMessages newMessages = do
        messages <- readIORef messagesRef
        let oldLength = Seq.length messages
        writeIORef messagesRef (messages >< newMessages)
        filters <- readIORef filtersRef
        currentlyFollowing <- readIORef followingRef
        columns <- readIORef columnsRef
        addMessagesToUI oldLength filters columns messageList newMessages currentlyFollowing
      toggleSelectedFilterActive = do
        selection <- UI.getSelected filterList
        case selection of
         Just (index, (filt, _)) -> do
           let newFilt = filt {filterIsActive=IsActive $ not $ unIsActive $ filterIsActive filt}
           modifyIORef filtersRef $ replaceAtIndex index newFilt
           refreshMessages
         Nothing -> return ()
      pin index msg = do
        columns <- readIORef columnsRef
        modifyIORef messagesRef $ Seq.update index (IsPinned True, msg)
        listItemWidget <- UI.plainText $ formatMessage columns msg
        -- figure out the index at which we must insert the widget
        -- (to keep it sorted by messagelist index)
        mPinnedIndex <- UI.listFindFirstBy ((> index) . fst) pinnedList
        pinIndex <- case mPinnedIndex of
          Just pinnedIndex -> return pinnedIndex
          Nothing -> UI.getListSize pinnedList
        UI.insertIntoList pinnedList (index, msg) listItemWidget pinIndex
        UI.setSelected pinnedList pinIndex
      unPin index msg = do
        modifyIORef messagesRef $ Seq.update index (IsPinned False, msg)
        mPinnedIndex <- UI.listFindFirstBy ((== index) . fst) pinnedList
        case mPinnedIndex of
         Just pinnedIndex -> do
           _ <- UI.removeFromList pinnedList pinnedIndex
           return ()
         Nothing -> error "Couldn't find pinned list item but pinned was true, this shouldn't happen."

  messageList `UI.onKeyPressed` \_ key _ ->
    case key of
      Events.KHome -> UI.scrollToBeginning messageList >> return True
      Events.KEnd -> UI.scrollToEnd messageList >> return True
      (Events.KChar 'p') -> do
        selection <- UI.getSelected messageList
        case selection of
         Just (_, (index, _)) -> do
           -- Note that this index is the ListItem value, not the index into
           -- the UI.List.
           messages <- readIORef messagesRef
           let message = messages `Seq.index` index
               isPinned = unIsPinned $ fst message
               msgJson = snd message
           if not isPinned
             then pin index msgJson
             else unPin index msgJson
           return True
         Nothing -> return True
      _ -> return False

  pinnedList `UI.onKeyPressed` \_ key _ ->
    case key of
     (Events.KChar 'p') -> do
       selection <- UI.getSelected pinnedList
       case selection of
        -- note that the bound index here is the messageList index, not the
        -- pinnedList index.
        Just (_, ((index, msg), _)) -> unPin index msg
        Nothing -> return ()
       return True
     _ -> return False

  filterList `UI.onKeyPressed` \_ key _ ->
    case key of
      Events.KHome -> UI.scrollToBeginning filterList >> return True
      Events.KEnd -> UI.scrollToEnd filterList >> return True
      Events.KChar ' ' -> toggleSelectedFilterActive >> return True
      _ -> return False

  columnsEdit `UI.onActivate` \widg -> do
    columnsText <- UI.getEditText widg
    let columns = filter (not . T.null) $ T.split (\char -> char == ',' || isSpace char) columnsText
    writeIORef columnsRef columns
    refreshMessages
    UI.focus messageList

  refreshMessages
  return (ui, messageList, filterList, pinnedList, refreshMessages, addMessages, columnsEdit)

addMessagesToUI :: Int -> Filters -> [T.Text] -> MessageListWidget -> Messages -> CurrentlyFollowing -> IO ()
addMessagesToUI oldLength filters columns messageList newMessages currentlyFollowing = do
  let theRange = [oldLength..]
      -- Decorate the new messages with their *index into the messages model*,
      -- so that after we filter them we can remember their index as the
      -- model-value of each list item.
      newMessages' = toList newMessages
      decorated = zip theRange newMessages'
      filteredMessagesWithIndices = filter (shouldShowMessage filters . snd) decorated
  messageWidgets <- mapM (UI.plainText . formatMessage columns . snd . snd) filteredMessagesWithIndices
  let messageItems = zip (map fst filteredMessagesWithIndices) messageWidgets
  UI.addMultipleToList messageList messageItems
  when currentlyFollowing $ UI.scrollToEnd messageList

makeMessageDetailWindow :: IO (UI.Widget _W, UI.Widget UI.FormattedText)
makeMessageDetailWindow = do
  mdHeader' <- UI.plainText "Message Detail. ESC=return"
  mdHeader <- UI.bordered mdHeader'
  mdBody <- UI.plainText "Insert message here."
  messageDetail <- UI.vBox mdHeader mdBody
  return (messageDetail, mdBody)


-- TODO radix: consider async + wait for getting the result of filter editing?

makeFilterEditWindow
  :: FiltersRef
  -> IO () -- ^ refreshMessages function
  -> IO () -- ^ switchToMain function
  -> IO (UI.Widget _W -- ^ the main widget
        , UI.Widget UI.FocusGroup -- ^ the dialog's focus group
        , FiltersIndex -> LogFilter -> IO ()) -- ^ the editFilter function
makeFilterEditWindow filtersRef refreshMessages switchToMain = do
  (dialogRec, filterDialog, filterFg) <- makeFilterDialog "Edit Filter" switchToMain

  -- YUCK
  filterIndexRef <- newIORef (Nothing :: Maybe FiltersIndex)

  let editFilter index logFilter = do
        setDefaultsFromFilter dialogRec logFilter
        writeIORef filterIndexRef $ Just index

  filterDialog `UI.onDialogAccept` \_ -> do
    maybeIndex <- readIORef filterIndexRef
    case maybeIndex of
     Nothing -> error "Error: trying to save an edited filter without knowing its index"
     Just index -> do
       maybeFilt <- filterFromDialog dialogRec
       case maybeFilt of
        Nothing -> return ()
        Just filt -> do
          modifyIORef filtersRef $ replaceAtIndex index filt
          refreshMessages
          writeIORef filterIndexRef Nothing
          switchToMain

  return (UI.dialogWidget filterDialog, filterFg, editFilter)


makeFilterCreationWindow :: FiltersRef -> IO () -> IO () -> IO (UI.Widget _W, UI.Widget UI.FocusGroup, IO ())
makeFilterCreationWindow filtersRef refreshMessages switchToMain = do
  (dialogRec, filterDialog, filterFg) <- makeFilterDialog "Create Filter" switchToMain

  filterDialog `UI.onDialogAccept` \_ -> do
    maybeNameAndFilt <- filterFromDialog dialogRec
    case maybeNameAndFilt of
     Just filt -> do
       modifyIORef filtersRef (filt:)
       refreshMessages
       switchToMain
     Nothing -> return ()

  let createFilter = blankFilterDialog dialogRec

  return (UI.dialogWidget filterDialog,
          filterFg,
          createFilter)

makeSaveSettingsDialog
  :: FiltersRef
  -> ColumnsRef
  -> IO () -- ^ switchToMain
  -> IO (UI.Widget _W, UI.Widget UI.FocusGroup)
makeSaveSettingsDialog filtersRef columnsRef switchToMain = do
  settingsPath <- getSettingsFilePath
  dialogBody <- UI.plainText $ T.append "Filters and columns will be saved to " $ T.pack settingsPath
  (dialog, dialogFg) <- UI.newDialog dialogBody "Save settings?"
  let dialogWidget = UI.dialogWidget dialog

  dialogFg `UI.onKeyPressed` \_ key _ -> case key of
    Events.KEsc -> switchToMain >> return True
    _ -> return False

  dialog `UI.onDialogAccept` \_ -> do
    filters <- readIORef filtersRef
    columns <- readIORef columnsRef
    writeSettingsFile settingsPath filters columns
    switchToMain
    return ()

  dialog `UI.onDialogCancel` const switchToMain

  return (dialogWidget, dialogFg)

-- |Handle lines that are coming in from our "tail" process.
linesReceived
  :: (Messages -> IO ()) -- ^ the addMessages function
  -> [BS.ByteString] -- ^ the new line
  -> IO ()
linesReceived addMessages newLines = do
  -- potential for race condition here I think!
  -- hmm, or not, since this will be run in the vty-ui event loop.
  let decoder = Aeson.decode :: BSL.ByteString -> Maybe Aeson.Value
      newJsons = mapMaybe (decoder . BSL.fromStrict) newLines
      newMessages = Seq.fromList $ map (IsPinned False,) newJsons
  addMessages newMessages

-- |Given a Handle, call the callback function
streamLines :: Handle -> LinesCallback -> IO ()
streamLines handle callback = do
  isNormalFile <- hIsSeekable handle
  if isNormalFile then cb =<< BS.split 10 <$> BS.hGetContents handle
  else do
    -- it's a real stream, so let's stream it
    hSetBuffering handle LineBuffering
    forever $ do
      availableLines <- hGetLines handle
      if not $ null availableLines then cb availableLines
      else do
        -- fall back to a blocking read now that we've reached the end of the
        -- stream
        line <- BS.hGetLine handle
        cb [line]
  where cb = unLinesCallback callback

-- |Get all the lines available from a handle, *hopefully* without blocking
-- This will sadly still block if there is a partial line at the end of the
-- stream and no more data is being written. hGetBufNonBlocking would allow me
-- to work around this problem, but then I'd have to keep my own buffer!
hGetLines :: Handle -> IO [BS.ByteString]
hGetLines handle = do
  readable <- hReady handle
  if readable then (:) <$> BS.hGetLine handle <*> hGetLines handle
  else return []


usage :: String
usage = " \n\
\USAGE: json-log-viewer 3< <(tail -F LOGFILE) -- for streaming\n\
\       json-log-viewer 3< LOGFILE -- to load a file without streaming\n\
\\n\
\Input must be JSON documents, one per line.\n\
\\n\
\This syntax works with bash and zsh.\n\
\\n\
\fish supports file redirection but I haven't figured out the syntax for\n\
\subprocess redirection."

main :: IO ()
main = do
  args <- getArgs
  case args of
        [] -> startApp
        ["-h"] -> error usage
        ["--help"] -> error usage
        _ -> error usage

startApp :: IO ()
startApp = do
  -- mutable variablessss
  messagesRef <- newIORef Seq.empty :: IO MessagesRef
  filtersRef <- newIORef [] :: IO FiltersRef
  followingRef <- newIORef False :: IO (IORef CurrentlyFollowing)
  columnsRef <- newIORef [] :: IO ColumnsRef

  -- load settings
  fp <- getSettingsFilePath
  (filters, columns) <- loadSettingsFile fp
  writeIORef filtersRef filters
  writeIORef columnsRef columns

  -- UI stuff

  -- main window
  (ui,
   messageList,
   filterList,
   pinnedList,
   refreshMessages,
   addMessages,
   columnsEdit) <- makeMainWindow messagesRef filtersRef followingRef columnsRef

  handle <- fdToHandle $ Fd 3
  _ <- forkIO $ streamLines handle $ LinesCallback (UI.schedule . linesReceived addMessages)

  mainFg <- UI.newFocusGroup
  _ <- UI.addToFocusGroup mainFg messageList
  _ <- UI.addToFocusGroup mainFg filterList
  _ <- UI.addToFocusGroup mainFg columnsEdit
  _ <- UI.addToFocusGroup mainFg pinnedList
  c <- UI.newCollection
  switchToMain <- UI.addToCollection c ui mainFg

  -- message detail window
  (messageDetail, mdBody) <- makeMessageDetailWindow
  messageDetailFg <- UI.newFocusGroup
  switchToMessageDetail <- UI.addToCollection c messageDetail messageDetailFg

  -- filter creation window
  (filterCreationWidget,
   filterCreationFg,
   createFilter) <- makeFilterCreationWindow filtersRef refreshMessages switchToMain
  switchToFilterCreation <- UI.addToCollection c filterCreationWidget filterCreationFg

  -- filter edit window
  (filterEditWidget,
   filterEditFg,
   editFilter) <- makeFilterEditWindow filtersRef refreshMessages switchToMain
  switchToFilterEdit <- UI.addToCollection c filterEditWidget filterEditFg

  (saveSettingsWidget, saveSettingsFg) <- makeSaveSettingsDialog filtersRef columnsRef switchToMain
  switchToSaveSettingsDialog <- UI.addToCollection c saveSettingsWidget saveSettingsFg

  mainFg `UI.onKeyPressed` \_ key _ ->
    case key of
     Events.KEsc -> exitSuccess
     _ -> return False

  -- vty-ui, bafflingly, calls event handlers going from *outermost* first to
  -- the innermost widget last. So if we bind things on mainFg, they will
  -- override things like key input in the column text field. (!?)  So we apply
  -- the "mostly-global" key bindings to almost all widgets, but not the
  -- column-edit widget.
  let bindGlobalThings _ key mods = case (key, mods) of
        (Events.KChar 'q', []) -> exitSuccess
        (Events.KChar 'f', []) -> do
          createFilter
          switchToFilterCreation
          return True
        (Events.KChar 'e', []) -> do
          isFollowing <- readIORef followingRef
          unless isFollowing $ UI.scrollToEnd messageList
          modifyIORef followingRef not
          return True
        (Events.KChar 'j', []) -> do
          UI.scrollDown messageList
          return True
        (Events.KChar 'k', []) -> do
          UI.scrollUp messageList
          return True
        (Events.KChar 's', [Events.MCtrl]) -> do
          switchToSaveSettingsDialog
          return True
        _ -> return False


  messageList `UI.onKeyPressed` bindGlobalThings
  filterList `UI.onKeyPressed` bindGlobalThings
  pinnedList `UI.onKeyPressed` bindGlobalThings

  let viewDetails msg = do
        let pretty = decodeUtf8 $ BSL.toStrict $ encodePretty msg
        UI.setText mdBody pretty
        switchToMessageDetail

  pinnedList `UI.onItemActivated` \(UI.ActivateItemEvent _ (_, message) _) ->
    viewDetails message

  messageList `UI.onItemActivated` \(UI.ActivateItemEvent _ index _) -> do
    -- Note that this `index` is the UI.List "value", not the index into the
    -- List view.
    messages <- readIORef messagesRef
    viewDetails $ snd $ messages `Seq.index` index

  filterList `UI.onItemActivated` \(UI.ActivateItemEvent index filt _) -> do
    editFilter index filt
    switchToFilterEdit

  filterList `UI.onKeyPressed` \_ key _ ->
    case key of
     (Events.KChar 'd') -> do
       selected <- UI.getSelected filterList
       case selected of
        Just (index, _) -> do
          _ <- UI.removeFromList filterList index
          modifyIORef filtersRef (removeIndex index)
          refreshMessages
          return True
        Nothing -> return False
     _ -> return False


  messageDetailFg `UI.onKeyPressed` \_ key _ ->
    case key of
     Events.KEsc -> switchToMain >> return True
     _ -> return False

  UI.runUi c UI.defaultContext

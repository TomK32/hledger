-- The account register screen, showing transactions in an account, like hledger-web's register.

{-# LANGUAGE OverloadedStrings, FlexibleContexts #-}

module Hledger.UI.RegisterScreen
 (screen
 ,rsSetCurrentAccount
 )
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.List
import Data.List.Split (splitOn)
import Data.Monoid
-- import Data.Maybe
import Data.Time.Calendar (Day)
import qualified Data.Vector as V
import Graphics.Vty as Vty
import Brick
import Brick.Widgets.List
import Brick.Widgets.Border (borderAttr)
-- import Brick.Widgets.Center
-- import Text.Printf

import Hledger
import Hledger.Cli hiding (progname,prognameandversion,green)
import Hledger.UI.UIOptions
-- import Hledger.UI.Theme
import Hledger.UI.UITypes
import Hledger.UI.UIUtils
import qualified Hledger.UI.TransactionScreen as TS (screen)
import qualified Hledger.UI.ErrorScreen as ES (screen)

screen = RegisterScreen{
   rsState   = (list "register" V.empty 1, "")
  ,sInitFn   = initRegisterScreen
  ,sDrawFn   = drawRegisterScreen
  ,sHandleFn = handleRegisterScreen
  }

rsSetCurrentAccount a scr@RegisterScreen{rsState=(l,_)} = scr{rsState=(l,a)}
rsSetCurrentAccount _ scr = scr

initRegisterScreen :: Day -> AppState -> AppState
initRegisterScreen d st@AppState{aopts=opts, ajournal=j, aScreen=s@RegisterScreen{rsState=(_,acct)}} =
  st{aScreen=s{rsState=(l,acct)}}
  where
    -- gather arguments and queries
    ropts = (reportopts_ $ cliopts_ opts)
            {
              depth_=Nothing,
              balancetype_=HistoricalBalance
            }
    -- XXX temp
    thisacctq = Acct $ accountNameToAccountRegex acct -- includes subs
    q = filterQuery (not . queryIsDepth) $ queryFromOpts d ropts

    -- run a transactions report, most recent last
    (_label,items') = accountTransactionsReport ropts j q thisacctq
    items = reverse items'

    -- pre-render all items; these will be the List elements. This helps calculate column widths.
    displayitem (t, _, _issplit, otheracctsstr, change, bal) =
      (showDate $ tdate t
      ,tdescription t
      ,case splitOn ", " otheracctsstr of
        [s] -> s
        ss  -> intercalate ", " ss
        -- _   -> "<split>"  -- should do this if accounts field width < 30
      ,showMixedAmountOneLineWithoutPrice change
      ,showMixedAmountOneLineWithoutPrice bal
      ,t
      )
    displayitems = map displayitem items

    -- build the List, moving the selection to the end
    l = listMoveTo (length items) $
        list (Name "register") (V.fromList displayitems) 1

        -- (listName someList)

initRegisterScreen _ _ = error "init function called with wrong screen type, should not happen"

drawRegisterScreen :: AppState -> [Widget]
drawRegisterScreen AppState{aopts=uopts -- @UIOpts{cliopts_=_copts@CliOpts{reportopts_=_ropts@ReportOpts{query_=querystr}}
                           ,aScreen=RegisterScreen{rsState=(l,acct)}} = [ui]
  where
    toplabel = withAttr ("border" <> "bold") (str acct)
            <+> cleared
            <+> str " transactions"
            -- <+> borderQueryStr querystr -- no, account transactions report shows all transactions in the acct ?
            -- <+> str " and subs"
            <+> str " ("
            <+> cur
            <+> str "/"
            <+> total
            <+> str ")"
    cleared = if (cleared_ $ reportopts_ $ cliopts_ uopts)
              then withAttr (borderAttr <> "query") (str " cleared")
              else str ""
    cur = str $ case l^.listSelectedL of
                 Nothing -> "-"
                 Just i -> show (i + 1)
    total = str $ show $ length displayitems
    displayitems = V.toList $ l^.listElementsL

    -- query = query_ $ reportopts_ $ cliopts_ opts

    ui = Widget Greedy Greedy $ do

      -- calculate column widths, based on current available width
      c <- getContext
      let
        totalwidth = c^.availWidthL
                     - 2 -- XXX due to margin ? shouldn't be necessary (cf UIUtils)

        -- the date column is fixed width
        datewidth = 10

        -- multi-commodity amounts rendered on one line can be
        -- arbitrarily wide.  Give the two amounts as much space as
        -- they need, while reserving a minimum of space for other
        -- columns and whitespace.  If they don't get all they need,
        -- allocate it to them proportionally to their maximum widths.
        whitespacewidth = 10 -- inter-column whitespace, fixed width
        minnonamtcolswidth = datewidth + 2 + 2 -- date column plus at least 2 for desc and accts
        maxamtswidth = max 0 (totalwidth - minnonamtcolswidth - whitespacewidth)
        maxchangewidthseen = maximum' $ map (strWidth . fourth6) displayitems
        maxbalwidthseen = maximum' $ map (strWidth . fifth6) displayitems
        changewidthproportion = fromIntegral maxchangewidthseen / fromIntegral (maxchangewidthseen + maxbalwidthseen)
        maxchangewidth = round $ changewidthproportion * fromIntegral maxamtswidth
        maxbalwidth = maxamtswidth - maxchangewidth
        changewidth = min maxchangewidth maxchangewidthseen 
        balwidth = min maxbalwidth maxbalwidthseen

        -- assign the remaining space to the description and accounts columns
        -- maxdescacctswidth = totalwidth - (whitespacewidth - 4) - changewidth - balwidth
        maxdescacctswidth =
          -- trace (show (totalwidth, datewidth, changewidth, balwidth, whitespacewidth)) $
          max 0 (totalwidth - datewidth - changewidth - balwidth - whitespacewidth)
        -- allocating proportionally.
        -- descwidth' = maximum' $ map (strWidth . second6) displayitems
        -- acctswidth' = maximum' $ map (strWidth . third6) displayitems
        -- descwidthproportion = (descwidth' + acctswidth') / descwidth'
        -- maxdescwidth = min (maxdescacctswidth - 7) (maxdescacctswidth / descwidthproportion)
        -- maxacctswidth = maxdescacctswidth - maxdescwidth
        -- descwidth = min maxdescwidth descwidth' 
        -- acctswidth = min maxacctswidth acctswidth'
        -- allocating equally.
        descwidth = maxdescacctswidth `div` 2
        acctswidth = maxdescacctswidth - descwidth
        colwidths = (datewidth,descwidth,acctswidth,changewidth,balwidth)

        bottomlabel = borderKeysStr [
           -- ("up/down/pgup/pgdown/home/end", "move")
           ("left", "back")
          ,("C", "cleared?")
          ,("right/enter", "transaction")
          ,("g", "reload")
          ,("q", "quit")
          ]

      render $ defaultLayout toplabel bottomlabel $ renderList l (drawRegisterItem colwidths)

drawRegisterScreen _ = error "draw function called with wrong screen type, should not happen"

drawRegisterItem :: (Int,Int,Int,Int,Int) -> Bool -> (String,String,String,String,String,Transaction) -> Widget
drawRegisterItem (datewidth,descwidth,acctswidth,changewidth,balwidth) selected (date,desc,accts,change,bal,_) =
  Widget Greedy Fixed $ do
    render $
      str (fitString (Just datewidth) (Just datewidth) True True date) <+>
      str "  " <+>
      str (fitString (Just descwidth) (Just descwidth) True True desc) <+>
      str "  " <+>
      str (fitString (Just acctswidth) (Just acctswidth) True True accts) <+>
      str "   " <+>
      withAttr changeattr (str (fitString (Just changewidth) (Just changewidth) True False change)) <+>
      str "   " <+>
      withAttr balattr (str (fitString (Just balwidth) (Just balwidth) True False bal))
  where
    changeattr | '-' `elem` change = sel $ "list" <> "amount" <> "decrease"
               | otherwise         = sel $ "list" <> "amount" <> "increase"
    balattr    | '-' `elem` bal    = sel $ "list" <> "balance" <> "negative"
               | otherwise         = sel $ "list" <> "balance" <> "positive"
    sel | selected  = (<> "selected")
        | otherwise = id

handleRegisterScreen :: AppState -> Vty.Event -> EventM (Next AppState)
handleRegisterScreen st@AppState{
   aScreen=s@RegisterScreen{rsState=(l,acct)}
  ,aopts=UIOpts{cliopts_=_copts}
  ,ajournal=j
  } e = do
  d <- liftIO getCurrentDay
  case e of
    Vty.EvKey Vty.KEsc []        -> halt st
    Vty.EvKey (Vty.KChar 'q') [] -> halt st

    Vty.EvKey (Vty.KChar 'g') [] -> do
      ej <- liftIO $ journalReload j  -- (ej, changed) <- liftIO $ journalReloadIfChanged copts j
      case ej of
        Right j' -> continue $ reload j' d st
        Left err -> continue $ screenEnter d ES.screen{esState=err} st

    Vty.EvKey (Vty.KChar 'C') [] -> continue $ reload j d $ stToggleCleared st

    Vty.EvKey (Vty.KLeft) []     -> continue $ popScreen st

    Vty.EvKey (k) [] | k `elem` [Vty.KRight, Vty.KEnter] -> do
      case listSelectedElement l of
        Just (_, (_, _, _, _, _, t)) ->
          let
            ts = map sixth6 $ V.toList $ listElements l
            numberedts = zip [1..] ts
            i = fromIntegral $ maybe 0 (+1) $ elemIndex t ts -- XXX
          in
            continue $ screenEnter d TS.screen{tsState=((i,t),numberedts,acct)} st
        Nothing -> continue st

    -- fall through to the list's event handler (handles [pg]up/down)
    ev                       -> do
                                 l' <- handleEvent ev l
                                 continue st{aScreen=s{rsState=(l',acct)}}
                                 -- continue =<< handleEventLensed st someLens ev

handleRegisterScreen _ _ = error "event handler called with wrong screen type, should not happen"

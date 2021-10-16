#!/usr/bin/env stack
{- stack script --optimize --verbosity=warn --resolver=nightly-2021-10-12
  --ghc-options=-threaded
  --package ansi-terminal
  --package ansi-terminal-game
  --package containers
  --package directory
  --package filepath
  --package pretty-simple
  --package safe
  --package time
  --package typed-process
-}
-- stack (https://www.fpcomplete.com/haskell/get-started) is the easiest
-- way to run this program reliably. On first run the script may seem
-- to hang (perhaps for minutes) while downloading and unpacking GHC;
-- change to --verbosity=info above to see more output.
--
-- You can also use cabal and/or your system package manager to install
-- the above haskell packages and a suitable GHC version (eg 8.10),
-- and then compile the script.

-------------------------------------------------------------------------------
-- language & imports

{-# OPTIONS_GHC -Wno-missing-signatures -Wno-unused-imports #-}
{-# LANGUAGE MultiWayIf, NamedFieldPuns, RecordWildCards, ScopedTypeVariables #-}

import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Function (fix)
import Data.List
import qualified Data.Map as M
import Data.Maybe
import Data.Time (UTCTime(..), getCurrentTime)
import Debug.Trace
import Safe
import System.Console.ANSI
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
import System.IO.Unsafe (unsafePerformIO)
import System.Process.Typed
import Terminal.Game
import Text.Pretty.Simple (pPrint)
import Text.Printf

-------------------------------------------------------------------------------
-- help

progname  = "caverunner"
version   = "1.0alpha"
banner = unlines [
   "  _________ __   _____  _______  ______  ____  ___  _____"
  ," / ___/ __ `/ | / / _ \\/ ___/ / / / __ \\/ __ \\/ _ \\/ ___/"
  ,"/ /__/ /_/ /| |/ /  __/ /  / /_/ / / / / / / /  __/ /    "
  ,"\\___/\\__,_/ |___/\\___/_/   \\__,_/_/ /_/_/ /_/\\___/_/     "
  ]

usage termsize msoxpath sstate@SavedState{..} sscores = banner ++ unlines [
   "--------------------------------------------------------------------------------" -- 80
  ,"caverunner "++version++" - a small terminal game by Simon Michael."
  ,""
  ,"Thrillseeking drone pilots dive the solar system's caves, competing for glory!"
  ,"Each cave and speed has a high score. Reaching the bottom unlocks more caves."
  ,"How fast, how deep, how far can you go ?"
  ,""
  ,"Usage:"
  ,"caverunner.hs                            # install deps, compile, run the game"
  ,"caverunner [CAVE [SPEED]]                # run the game"
  ,"caverunner --print-cave [CAVE [DEPTH]]   # show the cave on stdout"
  ,"caverunner --help|-h                     # show this help"
  ,""
  ,"CAVE selects a different cave, from 1 to <highest completed + "++show cavelookahead++">."
  ,cavesStatusMessage sstate
  ,""
  ,"SPEED sets a different maximum dive speed, from 1 to 60."
  ,"Currently running cave "++show currentcave++" at speed "++show currentspeed++"; "
   ++ "your best score is " ++ show highscore ++ "."
  ,""
  ,"Your terminal size is "++termsize++". (80x25 terminals are best for competition play.)"
  ]
  ++ case msoxpath of
    Nothing -> unlines [
      "To enable sound effects, install sox in PATH:"
      ,"apt install sox / brew install sox / choco install sox.portable / etc."
      ]
    Just soxpath -> unlines [
      "Sound effects are enabled, using " ++ soxpath ++ ". --no-sound to disable."
      ]
  where
    highscore = fromMaybe 0 $ M.lookup (currentcave, currentspeed) sscores

cavesStatusMessage SavedState{..} =
  -- "You have not completed a cave."
  "You have completed " ++ cavecompleted ++ ", and can reach caves 1 to " ++ show maxcave ++ "."
  where
    cavecompleted = if highcave==0 then "no caves" else "cave "++show highcave
    maxcave = highcave + cavelookahead

-------------------------------------------------------------------------------
-- tweakable parameters

(leftkey,rightkey) = (',','.')
wallchar           = '#'
spacechar          = ' '
crashchar          = '*'
fps                = 60  -- target frame rate; computer/terminal may not achieve it
restartdelaysecs   = 3   -- minimum pause after game over
minhelpsecs        = 5   -- minimum time to show onscreen help in first game

{- Three widths:

<-----------------------------screen width (terminal size)------------------------------->

    <----------------------------------game width (80)----------------------------->
    caverunner!    cave 1 @ 15      high score 0450        score 0000      speed   2  

    ####################<---cave width (decreasing from 40)---->####################
    #####################                                        ###################
    #####################                                      #####################

-}

-- parameters affecting cave procedural generation, keep these and stepCave the same for repeatable caves
gamewidth     = 80     -- how many columns to use (and require) for the game ? Can reduce it during development
cavemarginmin = 2      -- how close can cave walls get to the game edge ?
cavewidthinit = 40     -- how wide should the cave mouth be ?
cavewidthmin  = 0      -- how narrow can the cave get ?
cavewidthdurations = [ -- how long should the various cave widths last ?
-- (W,N): at width >= W, narrow (by 1) every N cave lines
   (20,3)
  ,(10,10)
  ,( 8,50)
  ,( 7,50)
  ,( 6,50)
  ,( 5,50)
  ,( 4,50)
  ,( 3,10)
  ,( 2,3)
  ]
-- Eg:
--  (20, 2) "at 20+,   narrow (by 1) every 2 lines"
--  (10,10) "at 10-19, narrow every 10 lines"
--  ( 8,50) "at 8-9,   narrow every 50 lines"

defcavenum  = 1
defmaxspeed = 15
cavelookahead = 3

cavespeedinit  = 1      -- nominal initial cave scroll speed (= player's speed within the cave)
cavespeedaccel = 1.008  -- multiply speed by this much each game tick (gravity)
cavespeedbrake = 1      -- multiply speed by this much each player movement (autobraking)

(playerymin, playerymax) = (0.4, 0.4)  -- player bounds relative to screen height, different bounds enables speed panning

-- cavespeedinit  = 2            
-- cavespeedaccel = 1.005         
-- cavespeedbrake = 0.7           
-- (playerymin, playerymax) = (0.2, 0.6)

-- cavespeedinit  = 4
-- cavespeedaccel = 1.001
-- cavespeedbrake = 0.8
-- (playerymin, playerymax) = (0.4, 0.4)

-------------------------------------------------------------------------------
-- types

type CaveNum    = Int    -- the number of a cave (and its random seed)
type MaxSpeed   = Int    -- a maximum dive/scroll speed in a cave
type Speed      = Float
type Score      = Int

-- Coordinates within the on-screen game drawing area, from 1,1 at top left.
type GameRow = Row
type GameCol = Column

-- Coordinates within a cave, from 1,1 at the cave mouth's midpoint.
type CaveRow = Row
type CaveCol = Column

-- One line within a cave, with its left/right wall positions.
data CaveLine = CaveLine GameCol GameCol deriving (Show)

data Scene =
    Playing
  | Crashed
  | Won
  deriving (Show,Eq)

data GameState = GameState {
  -- options
   stats           :: Bool       -- whether to show statistics
  -- current app state
  ,firstgame       :: Bool       -- is this the first game since app start ? (affects help)
  ,controlspressed :: Bool       -- have any movement keys been pressed since game start ? (affects help)
  ,showhelp        :: Bool       -- keep showing the on-screen help ?
  ,pause           :: Bool       -- keep things paused ?
  ,restarttimer    :: Timed Bool -- delay after game over before allowing a restart keypress
  ,restart         :: Bool       -- is it time to restart after game over ?
  ,exit            :: Bool       -- is it time to exit the app ?
  ,scene           :: Scene      -- current app/game mode
  -- current game state
  ,gamew           :: Width      -- width of the game  (but perhaps not the screen)
  ,gameh           :: Height     -- height of the game (and usually the screen)
  ,gtick           :: Integer    -- current game tick
  ,cavenum         :: CaveNum
  ,highscore       :: Score      -- high score for the current cave and max speed
  ,score           :: Score      -- current score in this game
  ,randomgen       :: StdGen
  ,cavesteps       :: Int        -- how many cave lines have been generated since game start (should be Integer but I can't be bothered)
  ,cavelines       :: [CaveLine] -- recent cave lines, for display; newest/bottom-most first
  ,cavewidth       :: Width      -- current cave width (inner space between the walls)
  ,cavecenter      :: GameCol    -- current x coordinate in game area of the cave's horizontal midpoint
  ,cavespeed       :: Speed      -- current speed of player dive/cave scroll in lines/s, must be <= fps
  ,cavespeedmin    :: Speed      -- current minimum speed player can brake to
  ,cavespeedmax    :: Speed      -- maximum speed player can accelerate to, must be <= fps
  ,cavetimer       :: Timed Bool -- delay before next cave scroll
  ,speedpan        :: Height     -- current number of rows to pan the viewport down, based on current speed
  ,playery         :: GameRow    -- player's y coordinate in game area
  ,playerx         :: GameCol    -- player's x coordinate in game area
  ,playerchar      :: Char
  }
  deriving (Show)

newGameState firstgame stats w h cavenum maxspeed hs = GameState {
   stats           = stats
  ,firstgame       = firstgame
  ,controlspressed = False
  ,showhelp        = True
  ,pause           = False
  ,restart         = False
  ,exit            = False
  ,restarttimer    = creaBoolTimer $ secsToTicks restartdelaysecs
  ,scene           = Playing
  ,gamew           = w
  ,gameh           = h
  ,gtick           = 0
  ,cavenum         = cavenum
  ,highscore       = hs
  ,score           = 0
  ,randomgen       = mkStdGen cavenum
  ,cavesteps       = 0
  ,cavelines       = []
  ,cavewidth       = cavewidthinit
  ,cavecenter      = half w
  ,cavespeed       = initspeed
  ,cavespeedmin    = initspeed
  ,cavespeedmax    = fromIntegral maxspeed
  ,cavetimer       = newCaveTimer initspeed
  ,speedpan        = 0
  ,playery         = playerYMin h
  ,playerx         = half w
  ,playerchar      = 'V'
  }
  where
    initspeed = fromIntegral maxspeed / 6

-- save files, separated for robustness

-- miscellaneous saved state

data SavedState = SavedState {
   currentcave  :: CaveNum     -- the cave most recently played
  ,currentspeed :: MaxSpeed    -- the max speed most recently played
  ,highcave     :: CaveNum     -- the highest cave number completed (0 for none)
} deriving (Read, Show, Eq)

newSavedState = SavedState{
   currentcave  = defcavenum
  ,currentspeed = defmaxspeed
  ,highcave     = 0
}

statefilename   = "state"
loadState       = load statefilename
saveState       = maybeSave statefilename

-- high scores

type SavedScores = M.Map (CaveNum, MaxSpeed) Score  -- high scores achieved for each cave and max speed 

newSavedScores = M.empty

scoresfilename  = "scores"
loadScores      = load scoresfilename
saveScores      = maybeSave scoresfilename

-------------------------------------------------------------------------------
-- app logic

main = do
  args <- getArgs
  (sstate@SavedState{..}, sstatet) <- fromMaybe (newSavedState, Nothing) <$> loadState
  (sscores, sscorest) <- fromMaybe (newSavedScores, Nothing) <$> loadScores
  when ("-h" `elem` args || "--help" `elem` args) $ exitWithUsage sstate sscores
  let
    (flags, args') = partition ("-" `isPrefixOf`) args
    (cavenum, speed, hasspeedarg) =
      case args' of
        []    -> (currentcave, currentspeed, False)
        [c]   -> (checkcave $ readDef (caveerr c) c, currentspeed, False)
        [c,s] -> (checkcave $ readDef (caveerr c) c, checkspeed $ readDef (speederr s) s, True)
        _     -> err "too many arguments, please see --help"
        where
          caveerr a = err $ "CAVE should be a natural number (received "++a++"), see --help)"
          checkcave c
            | c <= highcave + cavelookahead = c
            | otherwise = err $ unlines [
                 ""
                ,cavesStatusMessage sstate
                ,"You must complete at least cave "++ show (c-cavelookahead) ++ " to reach cave "++show c ++ "."
                ]
          speederr a = err $ "SPEED should be 1-60 (received "++a++"), see --help)"
          checkspeed s = if s >= 1 && s <= 60 then s else speederr $ show s

  cavenum `seq` if
    --  | "--print-speed-sound-volume" `elem` flags -> printSpeedSoundVolumes

    | "--print-cave" `elem` flags ->
      let mdepth = if hasspeedarg then Just speed else Nothing
      in printCave cavenum mdepth

    | otherwise -> do
      let sstate' = sstate{ currentcave=cavenum, currentspeed=speed }
      playGames True ("--stats" `elem` flags) cavenum (fromIntegral speed) (sstate',sstatet) (sscores,sscorest)

-- Generate the cave just like the game would, printing each line to stdout.
-- Optionally, limit to just the first N lines.
printCave cavenum mdepth = do
  putStrLn $ progname ++ " cave "++show cavenum
  go mdepth $ newGameState False False gamewidth 25 cavenum 15 0
  where
    go (Just 0) _ = return ()
    go mremaining g@GameState{..} =
      when (cavewidth > 0) $ do
        let
          (cavesteps',
           cavewidth',
           randomgen',
           cavecenter',
           cavelines'@(l:_)) = stepCave g
        putStrLn $ showCaveLineNumbered gamewidth l cavesteps'
        go (fmap (subtract 1) mremaining)
           g{randomgen    = randomgen'
            ,cavesteps    = cavesteps'
            ,cavelines    = cavelines'
            ,cavewidth    = cavewidth'
            ,cavecenter   = cavecenter'
            }

-- Play the game repeatedly at the given cave and speed,
-- updating save files and/or advancing to next cave when appropriate.
-- The first arguments specify if this is the first game of a session and
-- if onscreen dev stats should be displayed.
playGames :: Bool -> Bool -> CaveNum -> MaxSpeed -> (SavedState, Maybe UTCTime) -> (SavedScores, Maybe UTCTime) -> IO ()
playGames firstgame showstats cavenum maxspeed (sstate@SavedState{..},sstatet) (sscores,sscorest) = do
  (_,screenh) <- displaySize  -- use full screen height for each game (apparently last line is unusable on windows ? surely it's fine)
  let
    highscore = fromMaybe 0 $ M.lookup (cavenum, maxspeed) sscores
    game = newGame firstgame showstats screenh cavenum maxspeed highscore

  g@GameState{score,exit} <- Terminal.Game.playGameS game  -- run one game. Will fail if terminal is too small.

  -- if the game started successfully, remember the cave and speed
  d <- getSaveDir
  esaved <- saveState (sstate,sstatet)
  sstatet' <- case esaved of
    Left msg -> hPutStrLn stderr msg >> return sstatet
    Right t  -> return t

  -- if there's a new high score, remember it
  let sscores' = M.insert (cavenum, maxspeed) (max score highscore) sscores
  esaved <- saveScores (sscores',sscorest)
  sscorest' <- case esaved of
    Left msg -> hPutStrLn stderr msg >> return sscorest
    Right t  -> return t

  let
    (cavenum', highcave')
      | playerAtEnd g = (cavenum+1, max highcave cavenum)
      | otherwise     = (cavenum, highcave)
    sstate' = SavedState{
       currentcave  = cavenum'
      ,currentspeed = maxspeed
      ,highcave     = highcave'
      }
  if exit
  then quitSound
  else playGames False showstats cavenum' maxspeed (sstate',sstatet') (sscores',sscorest')

-- Initialise a new game (a cave run).
newGame :: Bool -> Bool -> Height -> CaveNum -> MaxSpeed -> Score -> Game GameState
newGame firstgame stats gameh cavenum maxspeed hs =
  Game { gScreenWidth   = gamewidth, -- width used (and required) for drawing (a constant 80 for repeatable caves)
         gScreenHeight  = gameh,     -- height used for drawing (the screen height)
         gFPS           = fps,       -- target frames/game ticks per second
         gInitState     = newGameState firstgame stats gamewidth gameh cavenum maxspeed hs,
         gLogicFunction = step',
         gDrawFunction  = draw,
         gQuitFunction  = timeToQuit
       }

-------------------------------------------------------------------------------
-- event handlers & game logic for each scene

-- Before calling step, do updates that should happen on every tick no matter what.
step' g@GameState{..} Tick = step g' Tick
  where
    g' = g{
       gtick=gtick+1
      ,showhelp=showhelp && not (timeToHideHelp g)
      }
step' g ev = step g ev

step g@GameState{scene=Playing, ..} (KeyPress k)
  | k == 'q'              = g { exit=True }
  | k `elem` "p ", pause  = g { pause=False }
  | k `elem` "p "         = g { pause=True,  showhelp=True }
  | not pause, k == leftkey =
      g { playerx   = max 1 (playerx - 1)
        , cavespeed = max cavespeedmin (cavespeed * cavespeedbrake)
        , controlspressed = True
        }
  | not pause, k == rightkey =
      g { playerx   = min gamew (playerx + 1)
        , cavespeed = max cavespeedmin (cavespeed * cavespeedbrake)
        , controlspressed = True
        }
  | otherwise = g

step g@GameState{scene=Playing, ..} Tick =
  let
    starting = gtick==1
    gameover = playerCrashed g
    victory  = playerAtEnd g
  in
    if
      | pause -> g  -- paused

      | starting -> unsafePlay gameStartSound g

      | gameover ->  -- crashed / reached the end
        unsafePlay (if victory then victorySound else crashSound cavespeed) $
        (if score > highscore then unsafePlay endGameHighScoreSound else id) $
        g{ scene        = if victory then Won else Crashed
          ,highscore    = max score highscore
          ,restarttimer = reset restarttimer
          }

      | isExpired cavetimer ->  -- time to step the cave
        let
          (cavespeed',
           cavespeedmin') = stepSpeed g
          (cavesteps',
           cavewidth',
           randomgen',
           cavecenter',
           cavelines') = stepCave     g
          speedpan'    = stepSpeedpan g cavesteps' cavespeed' cavelines'
          score'       = stepScore    g cavesteps'
          walldist     = fromMaybe 9999 $ playerWallDistance g
        in
          -- (if cavesteps `mod` 5 == 4 -- && cavespeed' > 5 
          --   then unsafePlay $ speedSound cavespeed' else id) $
          -- XXX trying very hard to start the beeps at cave mouth, no success
          -- (if depth>0 && (depth-1) `mod` 5 == 1 
          -- (if cavesteps'>playerHeight g && cavesteps' `mod` 5 == 0
          (if cavesteps `mod` 5 == 2
            then unsafePlay $ depthSound cavesteps' else id) $
          (if walldist <= 2 then unsafePlay $ closeShaveSound walldist else id) $
          -- (if score <= highscore && score' > highscore then unsafePlay inGameHighScoreSound else id) $
          g{ randomgen    = randomgen'
            ,score        = score'
            ,speedpan     = speedpan'
            ,cavesteps    = cavesteps'
            ,cavelines    = cavelines'
            ,cavewidth    = cavewidth'
            ,cavecenter   = cavecenter'
            ,cavespeed    = cavespeed'
            ,cavespeedmin = cavespeedmin'
            ,cavetimer    = newCaveTimer cavespeed'
            }

      | otherwise ->  -- time is passing
        let (cavespeed', cavespeedmin') = stepSpeed g
        in
          g{ cavetimer    = tick cavetimer
            ,cavespeed    = cavespeed'
            ,cavespeedmin = cavespeedmin'
            }

step g@GameState{..} (KeyPress 'q') = g { exit = True }

step g@GameState{..} Tick | gameOver g = g{restarttimer = tick restarttimer}

step g@GameState{..} (KeyPress _) | gameOver g, isExpired restarttimer = g{restart=True}

step g@GameState{..} (KeyPress _) | gameOver g = g

step g@GameState{..} (KeyPress k)
  | k `elem` " p"         = g{pause=True}
  | k `elem` " p", pause  = g{pause=False}
  | otherwise             = g

step GameState{..} Tick = error $ "No handler for " ++ show scene ++ " -> " ++ show Tick ++ " !"

-------------------------------------------------------------------------------
-- logic helpers

-- Should the current game be ended ?
timeToQuit g@GameState{..}
  | exit = True           -- yes if q was pressed
  | pause = False         -- no if paused
  | restart = True        -- yes if a key was pressed after game over
  | otherwise = False

-- If onscreen help is being shown, is it time to hide it yet ?
-- In the first game of a session, true after a certain amount of game time
-- and any movement keys have been pressed and the game is not paused.
-- In subsequent games, true when the game is not paused.
timeToHideHelp GameState{..}
  | firstgame = gtick > secsToTicks minhelpsecs && controlspressed && not pause
  | otherwise = not pause

stepSpeed :: GameState -> (Speed, Speed)
stepSpeed GameState{..} = (speed', minspeed')
  where
    -- gravity - gradually accelerate
    speed' = min cavespeedmax (cavespeed * cavespeedaccel)
    -- hurryup - slowly increase minimum speed ?
    -- minspeed' = cavespeedinit * 2 + float (cavesteps `div` 100)
    minspeed' = cavespeedmin

stepCave GameState{..} =
  (cavesteps'
  ,cavewidth'
  ,randomgen'
  ,cavecenter'
  ,cavelines'
  )
  where
    cavesteps' = cavesteps + 1

    -- narrowing - gradually narrow cave
    cavewidth'
      | cannarrow = max cavewidthmin (cavewidth - 1)
      | otherwise = cavewidth
      where
        cannarrow = cavesteps' `mod` interval == 0
          where
            interval = maybe 1 snd $ find ((<= cavewidth) . fst) cavewidthdurations

    -- morejagged - slowly increase max allowed sideways shift ?
    maxdx =
      -- min (cavewidth' `div` 4) (cavesteps' `div` 100 + 1)
      min (cavewidth' `div` 4) 1

    -- choose cave's next x position, with constraints:
    -- keep the walls within bounds
    -- keep it somewhat navigable
    --  (user can move sideways at ~5/s, don't allow long traverses faster than that)
    (randomdx, randomgen') = getRandom (-maxdx,maxdx) randomgen
    cavecenter' =
      let
        x = cavecenter + randomdx
        (l,r) = caveWalls x cavewidth'
        (cavemin,cavemax) = (cavemarginmin, gamew - cavemarginmin)
      in
        if | l < cavemin -> cavemin + half cavewidth'
           | r > cavemax -> cavemax - half cavewidth'
           | otherwise   -> x

    -- extend the cave, discarding old lines,
    -- except for an extra screenful that might be needed for speedpan
    cavelines' = take (gameh * 2) $ CaveLine l r : cavelines
      where
        (l,r) = caveWalls cavecenter' cavewidth'

-- speedpan - as speed increases, maybe pan the viewport up (player and walls move down)
-- with constraints:
-- only after screen has filled with cave steps
-- pan gradually, at most one row every few cave steps
-- keep player within configured min/max Y bounds
stepSpeedpan GameState{..} cavesteps' cavespeed' cavelines'
  | speedpan < idealpan, readytopan = speedpan+1
  | speedpan > idealpan, readytopan = speedpan-1
  | otherwise                       = speedpan
  where
    readytopan =
      length cavelines' >= gameh
      && cavesteps' `mod` 5 == 0
    idealpan =
      round $
      fromIntegral (playerYMax gameh - playerYMin gameh)
      * (cavespeed'-cavespeedinit) / (cavespeedmax-cavespeedinit)

-- increase score for every step deeper into the cave
stepScore g@GameState{..} cavesteps'
  | insidecave = score + 1
  | otherwise  = score
  where
    insidecave = cavesteps' > playerHeight g

-------------------------------------------------------------------------------
-- game state helpers

gameOver GameState{scene} = scene `elem` [Crashed,Won]

-- Create a timer for the next cave step, given the desired steps/s.
-- The steps/s should be no greater than ticks/s (the frame rate),
-- and will be capped at that (creating a one-tick timer).
newCaveTimer stepspersec = creaBoolTimer $ max 1 (secsToTicks  $ 1 / stepspersec)

-- Calculate the cave's left and right wall coordinates from center and width.
caveWalls center width = (center - half width, center + half width)

-- Player's minimum and maximum y coordinate in the game drawing area.
playerYMin, playerYMax :: Height -> GameRow
playerYMin gameh = round $ playerymin * fromIntegral gameh
playerYMax gameh = round $ playerymax * fromIntegral gameh

-- Player's current height above bottom of the game drawing area.
playerHeight :: GameState -> GameRow
playerHeight GameState{..} = gameh - playery

-- Player's current depth within the cave.
playerDepth :: GameState -> CaveRow
playerDepth g@GameState{..} = max 0 (cavesteps - playerHeight g)

-- The cave line currently at the player's position, if any.
playerLine :: GameState -> Maybe CaveLine
playerLine g@GameState{..} = cavelines `atMay` playerHeight g

playerLineAbove g@GameState{..} = cavelines `atMay` (playerHeight g - 1)

playerLineBelow g@GameState{..} = cavelines `atMay` (playerHeight g + 1)

-- Has player hit a wall ?
playerCrashed g@GameState{..} =
  case playerLine g of
    Nothing             -> False
    Just (CaveLine l r) -> playerx <= l || playerx > r

-- How close is player flying to a wall ?
-- Actually, checks the line below (ahead) of the player, to sync better with sound effects.
playerWallDistance :: GameState -> Maybe Width
playerWallDistance g@GameState{..} =
  case playerLineBelow g of
    Nothing             -> Nothing
    Just (CaveLine l r) -> Just $ min (max 0 $ playerx-l) (max 0 $ r+1-playerx)

-- Has player reached the cave bottom (a zero-width line) ?
playerAtEnd g = case playerLine g of
  Just (CaveLine l r) | r <= l -> True
  _                            -> False

-------------------------------------------------------------------------------
-- save file helpers

getSaveDir :: IO FilePath
getSaveDir = getXdgDirectory XdgData progname

-- Try to read a value from the named save file, using read.
-- Exits with an error message if reading fails,
-- returns Nothing if the file does not exist,
-- or Just (value, <current time>) if successful.
-- This time should be passed to maybeSave when next saving to this file,
-- to help detect write conflicts and prevent data loss.
-- (The time is wrapped in Maybe for ease of use, but will always be Just.)
load :: (Read a, Show a, Eq a) => FilePath -> IO (Maybe (a, Maybe UTCTime))
load filename = do
  d <- getSaveDir
  let f = d </> filename
  exists <- doesFileExist f
  if not exists
  then pure Nothing
  else do
    v <- readDef (err $ init $ unlines [
      "could not read " ++ f
      ,"Perhaps the format has changed ? Please move it out of the way and run again."
      ]) <$> readFile f
    t <- getCurrentTime
    return $ Just (v, Just t)

-- Write a value to the named save file, using show,
-- creating the save directory if it does not exist.
-- Any previous value in the save file will be overwritten.
save :: (Read a, Show a, Eq a) => FilePath -> a -> IO ()
save filename val = do
  d <- getSaveDir
  createDirectoryIfMissing True d
  let f = d </> filename
  writeFile f $ show val

-- Like save, but more careful: avoids writing
-- 1. unnecessarily (the save file exists and already contains the same value), or
-- 2. unsafely (the save file has been written to since we last read it).
-- To detect case 2, the last read time (obtained from load) should be provided.
-- Returns Left <warning message> in case 2, Right Nothing in case 1,
-- or Right <current time> on successful write.
maybeSave :: (Read a, Show a, Eq a) => FilePath -> (a, Maybe UTCTime) -> IO (Either String (Maybe UTCTime))
maybeSave filename (val,mloadtime)  = do
  d <- getSaveDir
  let f = d </> filename
  modtime <- getModificationTime f
  mvt <- load filename
  now <- getCurrentTime
  case (mvt, mloadtime) of
    (Just (oldval, _), _) | oldval==val -> return $ Right Nothing
    (Just _, Just loadtime) | modtime > loadtime -> 
      return $ Left $ "warning: " ++ filename ++ " file was modified since last read, could not write"
    _ -> save filename val >> return (Right $ Just now)

-------------------------------------------------------------------------------
-- utilities

exitWithUsage sstate sscores = do
  clearScreen
  setCursorPosition 0 0
  termsize <- displaySizeStrSafe
  msox <- findExecutable "sox"
  putStr $ usage termsize msox sstate sscores
  exitSuccess

displaySizeStrSafe = handle (\(_::ErrorCall) -> return "unknown") $ do
  (w,h) <- displaySize
  return $! show w++"x"++show h

-- Convert seconds to game ticks based on global frame rate.
secsToTicks :: Float -> Integer
secsToTicks = round . (* fromIntegral fps)

half :: Integral a => a -> a
half = (`div` 2)

err = errorWithoutStackTrace

-- Run a shell command, either synchronously or in a background process,
-- ignoring any output, errors or exceptions. ("Silent" here does not mean sound.)
runProcessSilent :: Bool -> String -> IO ()
runProcessSilent synchronous =
  silenceExceptions .
  (if synchronous then void else void . forkIO) . void . runProcess .
  silenceOutput .
  shell

silenceExceptions :: IO () -> IO ()
silenceExceptions = handle (\(e::IOException) -> -- trace (show e) $ 
  return ())

silenceOutput :: ProcessConfig i o e -> ProcessConfig i () ()
silenceOutput = setStdout nullStream . setStderr nullStream

-------------------------------------------------------------------------------
-- drawing for each scene

draw g@GameState{..} =
    blankPlane gamew gameh
  & (max 1 (gameh - length cavelines + 1), 1) % drawCave g
  -- & (1, 1)          % blankPlane gamew 1
  & (1, titlex)     % drawTitle g
  & (1, cavenamex)  % drawCaveName g
  & (if showhelp then (3, helpx) % drawHelp g else id)
  & (1, highscorex) % drawHighScore g
  & (1, scorex)     % drawScore g
  & (1, speedx)     % drawSpeed g
  & (playery+speedpan, playerx) % drawPlayer g
  & (if gameOver g then (gameovery, gameoverx) % drawGameOver g gameoverw gameoverh else id)
  & (if stats then (3, gamew - 13) % drawStats g else id)
  where
    titlew     = 12
    cavenamew  = fromIntegral $ 10 + length (show cavenum) + length (show cavespeedmax)
    highscorew = 17
    scorew     = 11
    speedw     = 10
    gameoverw  = 40
    gameoverh  = 7

    titlex     = 1
    helpx      = 1
    speedx     = gamew - speedw + 1
    scorex     = highscorex + highscorew + half (speedx - (highscorex + highscorew)) - half scorew
    highscorex = half gamew - half highscorew
    cavenamex  = min (highscorex - cavenamew) (half (highscorex - (titlex+titlew)) + titlex + titlew - half cavenamew)
    gameoverx  = half gamew - half gameoverw
    gameovery  = max (playery+2) $ half gameh - half gameoverh

-------------------------------------------------------------------------------
-- drawing helpers

drawCave GameState{..} =
  vcat $
  map (drawCaveLine gamew) $
  reverse $
  take gameh $
  drop speedpan cavelines

drawCaveLine gamew line = stringPlane $ showCaveLine gamew line

showCaveLine gamew (CaveLine left right) =
  concat [
    replicate left wallchar
   ,replicate (right - left) spacechar
   ,replicate (gamew - right ) wallchar
   ]

showCaveLineNumbered gamew l n =
  num ++ drop (length num) (showCaveLine gamew l  )
  where
    num = show n

drawPlayer GameState{..} =
  cell char #bold #color hue Vivid
  where
    (char, hue) | scene==Crashed = (crashchar,Red)
                | otherwise = (playerchar,Blue)

drawTitle GameState{..} =
  hcat $ zipWith (\a b -> a b) colors (map (bold.cell) $ progname++"! ")
  where
    colors =
      drop (cavesteps `div` 3 `mod` 4) $
      cycle [color Red Vivid, color Green Vivid, color Blue Vivid, color Yellow Vivid]

drawCaveName GameState{..} = stringPlane $ " cave "++show cavenum++" @ "++show (round cavespeedmax) ++ " "

drawHelp GameState{..} =
      (stringPlane (" "++[leftkey]++" ")  #bold  ||| stringPlane " left ")
  === (stringPlane (" "++[rightkey]++" ") #bold  ||| stringPlane " right ")
  === (stringPlane "spc" #bold  ||| if pause then stringPlane " pause " #bold else stringPlane " pause ")
  === (stringPlane " q " #bold  ||| if exit then stringPlane " quit " #bold else stringPlane " quit ")

drawHighScore g@GameState{..} =
  stringPlane " high score " ||| (stringPlane (printf "%04d " highscore) & maybebold)
  where
    maybebold = if gameOver g && highscore==score then (#bold) else id

drawScore GameState{..} =
  stringPlane " score " ||| (stringPlane (printf "%04d " score) & maybebold)
  where
    maybebold = if score >= highscore then (#bold) else id

drawSpeed g@GameState{..} = stringPlane " speed " ||| stringPlane (printf "%3.f " cavespeed)

drawStats g@GameState{..} =
      (stringPlane "    depth " ||| stringPlane (printf "%3d " (playerDepth g)))
  -- === (stringPlane "depthmod5 " ||| stringPlane (printf "%3d " (playerDepth g `mod` 5)))
  === (stringPlane "    width " ||| stringPlane (printf "%3d " cavewidth))
  === (stringPlane " minspeed " ||| stringPlane (printf "%3.f " cavespeedmin))
  -- === (stringPlane " speedpan " ||| stringPlane (printf "%3d " speedpan))
  -- === (stringPlane "    speed " ||| stringPlane (printf "%3.f " cavespeed))

drawGameOver g@GameState{..} w h =
  box w h '-'
  & (2,2) % box (w-2) (h-2) ' '
  & (txty,txtx) % stringPlane txt
  & (txty+1,txtx - half (length txt2 - length txt - 1)) % stringPlane txt2
  & (if isExpired restarttimer then (txty+2,txtx-7) % stringPlane "press a key to relaunch" else id)
  where
    innerw = w - 2
    innerh = h - 2
    txt = "GAME OVER"
    txt2 =
      if playerAtEnd g
      then printf "you completed cave %d. Nice flying!" cavenum
      else printf "you reached depth %d." (playerDepth g)
      ++ if highscore==score then " High score!" else ""
    txtw = fromIntegral $ length txt
    txth = 2
    txtx = 2 + half innerw - half txtw
    txty = 3

-------------------------------------------------------------------------------
-- sound helpers

-- Check whether sounds should be played - true unless the program was
-- run with the --no-sound flag. Uses unsafePerformIO. Won't change in a GHCI session.
soundEnabled :: Bool
soundEnabled = "--no-sound" `notElem` unsafePerformIO getArgs

-- Execute an IO action (typically one that plays a sound asynchronously)
-- before evaluating the second argument, unless sound is disabled.
-- Uses unsafePerformIO.
unsafePlay :: IO a -> b -> b
unsafePlay a = if soundEnabled then seq (unsafePerformIO a) else id

-- Try to play a synthesised sound by running `sox synth` with the given arguments, 
-- optionally blocking until the sound finishes playing, otherwise forking a background process to play it.
-- If no SynthArgs are provided, this plays a one-second tone.
-- This should never fail, and ignores all errors (so uncomment the trace if you need to troubleshoot).
--
-- Tips:
-- When possible, combine multiple notes into a single sox sound and call this once, 
-- minimising subprocesses and audible gaps between notes.
-- sox seems to truncate sounds at the end for some reason; you might need to add
-- some extra duration or a final delay to hear a sound in full.
--
soxPlay :: Bool -> SynthArgs -> IO ()
soxPlay synchronous args = runProcessSilent synchronous $
  -- traceShowId $
  "sox -V0 -qnd synth " ++ unwords (if null args then ["1"] else args)

-- Arguments to follow sox's `synth` command, such as ["1","sine","200"] (a 1 second 200hz sine wave).
-- Should be one or more `synth` arguments, optionally followed by any other sox arguments,
-- which allows complex sounds, chords and note sequences to be generated.
type SynthArgs = [String]

-------------------------------------------------------------------------------
-- sound effects. These should generally be asynchronous, returning immediately.

gameStartSound = void $ forkIO $ do
  let d = 0.12
      v = 0.7
  soxPlay False [show d,"sine","400-100","vol",show v]
  threadDelay $ round $ d * 1000000
  soxPlay False [show d,"sine","400-100","vol",show v]
  threadDelay $ round $ d * 1000000
  soxPlay False [".5","sine","400-100","vol",show v]

depthSound depth = do
  let v = 0.3
  soxPlay False [".15", "sine", show $ 100 + depth, "vol", show v]
  soxPlay False [".15", "sine", show $ 1000 - depth, "vol", show $ v/3]

-- trying to mimic a variable constant hiss with short sounds - too fragile
-- speedSound speed = do
--   let d = 1 / speed
--   soxPlay False [
--     show d, "pinknoise",
--     "fade q", show $ d / 2, "0", show $ d / 2,
--     "vol", show $ speedSoundVolume speed
--     ]

-- speedSoundVolume :: Speed -> Float
-- speedSoundVolume speed = max 0 $ (speed - 10) / 200

-- printSpeedSoundVolumes = do
--   putStrLn "        volume"
--   putStrLn "speed       123456789"
--   putStr $ unlines $ reverse $ [printf "%5.f  %4.1f " s v ++ replicate (round $ v * 10) '*' | (s,v) <- vols]
--   where vols = [(s, speedSoundVolume s) | s <- [0,5..60::Speed]]

closeShaveSound distance = do
  let
    d = 0.2
    v | distance<=1 = 0.3
      | distance<=2 = 0.1
      | otherwise   = 0
  soxPlay False [
    show d, "brownnoise",
    "fade p .2 -0 0",
    "vol", show v
    ]

crashSound speed = do
  -- soxPlay False [l, "pinknoise",  "fade", "l", "0", "-0", l, "vol", v, "vol .2"]
  soxPlay False [d, "brownnoise", "fade", "l", "0", "-0", d, "vol 1"]
  soxPlay False [d, "brownnoise", "fade", "l", "0", "-0", d, "vol", v]
  where
    speed' = min 60 $ 30 + speed / 2
    d = show $ speed' / 6
    v = show $ crashSoundVolume speed'

crashSoundVolume s = s / 25

printCrashSoundVolumes = do
  putStrLn "        volume"
  putStrLn "speed       123456789"
  putStr $ unlines $ reverse $ [printf "%5.f  %4.1f " s v ++ replicate (round $ v * 10) '*' | (s,v) <- vols]
  where vols = [(s, crashSoundVolume s) | s <- [0,5..60::Speed]]

inGameHighScoreSound = soxPlay False [".1 sine 800 sine 800 delay 0 +.2"]

endGameHighScoreSound =
  soxPlay False [
    ".05 sine 400 sine 500 sine 600 sine 800 sine 800"
    ,"delay", overalldelay
    ,"+.1 +.1 +.1 +.2"
    ]
  where
    overalldelay = show $ restartdelaysecs / 2

victorySound = do
  soxPlay False ["0.1 sine 200 sine 300 sine 400"]
  threadDelay 160000
  soxPlay False ["1.5 sine 200 sine 300 sine 400"]

dropSound = soxPlay False [".8","sine","300-1"]

-- synchronous, so it can play before app exits
quitSound = soxPlay True [".3","sine","200-100"]

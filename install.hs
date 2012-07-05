import Shelly
import Prelude hiding (FilePath)

import Text.Shakespeare.Text (lt)
import qualified Data.Text.Lazy as LT
import Data.Text.Lazy (Text)
import Control.Monad (forM_)
import System.Console.CmdArgs

#if __GLASGOW_HASKELL__ < 704
import Data.Monoid (Monoid, mappend)
infixr 5 <>
(<>) :: Monoid m => m -> m -> m
(<>) = mappend
#else
import Data.Monoid ((<>))
#endif

data CmdOptions = CmdOptions {
  clean :: Bool,
  fast :: Bool,
  install_extra :: [String]
} deriving (Show,Data,Typeable)

{-
 determine what repo you're in dynamically by parsing the output of git
 remote -v.

 we need to handle a few platform-specific formats. if you adjust this
 line to support your platform, please note it here and ensure your fix
 handles all cases present.

 Linux - git version 1.7.7.4. using git@ or https, with or without .git
 extension.

 Mac OSX - git version 1.7.5.4. using git@ or https, with or without
 .git extension.

   origin  git@github.com:yesodweb/scripts.git (fetch)
   origin  https://github.com:yesodweb/scripts.git (fetch)
   origin  git@github.com:yesodweb/scripts (fetch)
   origin  https://github.com:yesodweb/scripts (fetch)

-}
determine_repo :: ShIO Text
determine_repo = do
  pkg <- getenv "YESODPKG"
  if not $ LT.null pkg then return pkg
    else do
      repo <- fmap LT.strip $ run "sh" ["-c", "git remote -v | sed '/^origin.*\\/\\([^ ]*\\) *(fetch)$/!d; s//\\1/; s/\\.git$//'"]
      when (LT.null repo) $ errorExit [lt|

  unable to determine yesod package to install via `git remote -v`. if
  you're not using git or otherwise need to manually define the yesod
  package name, set the YESODPKG environment variable:

  YESODPKG=hamlet ./script/install

|]
      return repo

test_pkg :: FilePath -> Bool -> Text -> ShIO ()
test_pkg cabal test pkg = do
  when test $ do
    echo $ "testing " <> pkg
    run_ cabal ["configure","-ftest","-ftest_export","--enable-tests","--disable-optimization","--disable-library-profiling"]
    run_ cabal ["build"]
    run_ cabal ["test"]

  if pkg == "./mongoDB-haskell"
    then echo "skipping check for mongoDB-haskell" -- stupid Cabal warning
    else run_ cabal ["check"]


install_packages :: Text -- ^ repo
                 -> FilePath -- ^ cabal
                 -> ([Text] -> ShIO ()) -- ^ cabal install
                 -> CmdOptions
                 -> Bool -- ^ test
                 -> [Text]
                 -> ShIO ()
install_packages repo cabal cabal_install opts test pkgs = do
  let documentation = if fast opts then ["--disable-documentation"] else []

  when (clean opts) $ do
    echo "cleaning packages"
    forM_ pkgs $ \pkg -> do
      chdir (fromText pkg) $ run_ cabal ["clean"]

  echo $ "installing package dependencies for " <> repo

  cabal_install $ "--only-dependencies":pkgs

  echo $ "installing packages: " <> LT.intercalate " " pkgs
  let i = cabal_install $ "-ftest_export": documentation ++ ["--ghc-options=-Wall -Werror"] ++ pkgs
  catchany_sh i $ \_ -> errorExit [lt|
  installation failure!

  Please try a clean build with: ./script/install --clean

  If you are peforming a clean install and haven't mucked with the code,
  Please report this error to the mail list at http://groups.google.com/group/yesodweb
  or on the issue tracker at http://github.com/yesodweb/#{repo}/issues
|]

  echo "all packages installed. Doing a cabal-src-install and testing."

  msrc_install <- which "cabal-src-install"
  let src_install = case msrc_install of
                      Just _ -> True
                      Nothing -> False

  echo [lt|cabal-src-install #{show src_install}|]

  forM_ pkgs $ \pkg -> do
    chdir (fromText pkg) $ do
      when src_install $
        catchany_sh (run_ "cabal-src-install" ["--src-only"]) $ \_ -> do
          echo "failed while creating an sdist for cabal-src"
          exit 1
      test_pkg cabal test pkg

{- deprecated, but perhaps still useful?
install_individual_pkgs() {
  local pkg

  for pkg; do
    [[ -d "./$pkg" ]] || continue

    echo "Installing $pkg..."

    (
      cd "./$pkg"

      $clean && $CABAL clean

      if ! $CABAL configure --ghc-options='-Wall -Werror'; then
        $CABAL install --only-dependencies
        $CABAL configure --ghc-options='-Wall -Werror'
      fi

      test_pkg $pkg

      if $fast; then
        $CABAL install --disable-documentation
      else
        $CABAL install
      fi

      which cabal-src-install && cabal-src-install --src-only
    )
  done
}
-}

main :: IO ()
main = shelly $ verbosely $ do
  -- allow an env var to override
  cabal <- fmap fromText $ getenv_def "CABAL" "cabal"
  let cabal_install = command_ cabal ["install"]

  repo <- determine_repo
  echo [lt|Installing for repo #{repo}...|]

  -- set the pkgs array to those appropriate for that repo
  pkgs <- fmap LT.lines $ readfile "sources.txt"
  when (null pkgs) $ errorExit [lt|no packages to install for repository #{repo}.|]

  opts <- liftIO $ cmdArgs $ CmdOptions {clean=False, fast=False, install_extra=def&=args}

  -- allow individual packages to be passed on the commandline
  let install = install_packages repo cabal cabal_install opts 
  let extra = map LT.pack $ install_extra opts
  unless (null extra) $ cabal_install extra

  run_ "git" ["submodule", "init"]
  run_ "git" ["submodule", "update"]

  -- persistent is handled specially
  if repo == "persistent"
    then do
      echo "installing packages for the tests suites"
      cabal_install ["HUnit","QuickCheck","file-location","hspec >= 1.2 && < 1.3"]

      -- install all persistent packages without tests
      install False pkgs

      echo "now running persistent tests"

      chdir "./persistent-test" $ do
        -- persistent-test is the only persistent package with tests
        test_pkg cabal True "persistent-test"

    else do
      echo "installing packages for the tests suites"
      cabal_install ["HUnit","QuickCheck","hspec >= 1.2 && < 1.3", "blaze-html >= 0.5 && < 0.6"]

      echo [lt|installing #{repo} packages|]
      install True pkgs

  echo ""
  echo "Success: all packages installed and tested."

#!/bin/bash -e

errorout() { echo "$*" >&2; exit 1; }

usage() { echo 'scripts/install [ --clean ] [ --fast ]'; exit 1; }

# determine what repo you're in dynamically by parsing the output of git
# remote -v.
#
# we need to handle a few platform-specific formats. if you adjust this
# line to support your platform, please note it here and ensure your fix
# handles all cases present.
#
# Linux - git version 1.7.7.4. using git@ or https, with or without .git
# extension.
#
# Mac OSX - git version 1.7.5.4. using git@ or https, with or without
# .git extension.
#
#   origin  git@github.com:yesodweb/scripts.git (fetch)
#   origin  https://github.com:yesodweb/scripts.git (fetch)
#   origin  git@github.com:yesodweb/scripts (fetch)
#   origin  https://github.com:yesodweb/scripts (fetch)
#
###
determine_repo() {
  local repo

  if [[ -n "$YESODPKG" ]]; then
    echo $YESODPKG
    return
  fi

  if ! read -r repo < <(git remote -v | sed '/^origin.*\/\([^ ]*\) *(fetch)$/!d; s//\1/; s/\.git$//') || [[ -z "$repo" ]]; then
    cat >&2 <<"EOF"

    unable to determine yesod package to install via `git remote -v`. if
    you're not using git or otherwise need to manually define the yesod
    package name, set the YESODPKG environment variable:

    YESODPKG=hamlet ./script/install

EOF

    exit 1
  fi

  echo "$repo"
}

test_pkg() {
      if $test; then
        echo "testing $1"
        $CABAL configure -ftest -ftest_export --enable-tests --disable-optimization --disable-library-profiling
        $CABAL build
        $CABAL test
      fi

      if [[ "$1" == './mongoDB-haskell' ]]; then
        echo "skipping check for mongoDB-haskell" # stupid Cabal warning
      else
        $CABAL check
      fi
}

install_packages() { # {{{
  if $fast; then
    documentation="--disable-documentation"
  else
    documentation=""
  fi

  if which cabal-src-install; then
    src_install=true
  else
    src_install=false
  fi
  echo "cabal-src-install $src_install"

  local pkg
  if $clean ; then
    echo "cleaning packages"
    for pkg in ${pkgs[@]}; do
      (
        cd $pkg
        $CABAL clean
      )
    done
  fi

  echo "installing package dependencies ${pkgs[@]}"
  $CABAL install --only-dependencies ${pkgs[@]}

  echo "installing packages: ${pkgs[@]}"
  if ! $CABAL install -ftest_export $documentation --ghc-options='-Wall' ${pkgs[@]}; then
    echo "installation failure!"
    echo ""
    echo "Please try a clean build with: ./script/install --clean"
    echo ""
    echo "If you are peforming a clean instal and haven't mucked with the code,"
    echo "please report this error to the mail list at http://groups.google.com/group/yesodweb"
    echo "or on the issue tracker at http://github.com/yesodweb/$repo/issues"
    exit 1
  fi

  echo "all packages installed. Doing a cabal-src-install and testing."

  for pkg in ${pkgs[@]}; do
    (
      cd $pkg
      if $src_install && ! CABAL=$CABAL cabal-src-install --src-only; then
        echo "failed while creating an sdist for cabal-src"
        exit 1
      fi
      test_pkg $pkg
    )
  done
}
# }}}

# deprecated, but perhaps still useful?
install_individual_pkgs() { # {{{
  local pkg

  for pkg; do
    [[ -d "./$pkg" ]] || continue

    echo "Installing $pkg..."

    (
      cd "./$pkg"

      $clean && $CABAL clean

      if ! $CABAL configure --ghc-options='-Wall'; then
        $CABAL install --only-dependencies
        $CABAL configure --ghc-options='-Wall'
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
# }}}

# allow an env var to override
CABAL=${CABAL:-cabal}

read -r repo < <(determine_repo)
echo "Installing for repo $repo..."

# set the pkgs array to those appropriate for that repo
source package-list.sh
[[ "${#pkgs[@]}" -eq 0 ]] && errorout "no packages to install for repository $repo."

# set defaults
test=true
clean=false
fast=false

# commandline options
while [[ -n "$1" ]]; do
  case "$1" in
    -c|--clean) clean=true ;;
    -f|--fast)  fast=true  ;;
    -h|--help)  usage      ;;
    *)          break      ;;
  esac
  shift
done

# allow individual packages to be passed on the commandline
if [[ $# -ne 0 ]]; then
  $CABAL install HUnit QuickCheck 'hspec >= 0.8 && < 0.10'
  install_packages "$@"
  exit $?
fi

git submodule init
git submodule update

# persistent is handled specially
if [[ "$repo" == 'persistent' ]]; then
  echo "installing packages for the tests suites"
  $CABAL install HUnit QuickCheck 'file-location' 'hspec >= 0.8 && < 0.10'

  test=false  # install all persistent packages without tests
  install_packages "${pkgs[@]}"

  echo "now running persistent tests"

  test=true # persistent-test is the only persistent package with tests
  cd "./persistent-test"
  test_pkg "persistent-test"

else
  echo "installing packages for the tests suites"
  $CABAL install HUnit QuickCheck 'hspec >= 0.8 && < 1.0' # shelltestrunner

  echo "installing $repo packages"
  install_packages "${pkgs[@]}"
fi

echo ""
echo "Success: all packages installed and tested."

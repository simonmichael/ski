# ski

Basic terminal version ([ski1.hs](ski1.hs)):

![screencast](ski1.gif)

ansi-terminal-game version ([ski2.hs](ski2.hs)):

![screencast](ski2.anim.gif)
https://asciinema.org/a/f1xjpZx6UuuNBJcs5nGiGiKWo

## Some problems and solutions

How hard is it to make classic terminal/console games in Haskell ?
Pretty hard to figure out a good setup; relatively easy after that.
These notes and the examples in this repo aim to help.
Last updated 2021-09.

### Packaging

- Minimising packaging boilerplate & complex/unreliable install instructions:\
  use a [stack script with `script` command](https://docs.haskellstack.org/en/stable/GUIDE/#script-interpreter)

- Getting stack script options just right:
  - Specify all extra packages (packages other than `base` that you import from)
    with `--package` options in stack options line.
    If you forget any, the script may run for you but fail for others.
  - If they depend on packages not in stackage, you must also mention each of those
    (the error message will list them.)
  - Remember stack options must be all on one line. 
    Follow-on lines will be silently ignored.

- Avoiding apparent hang when ghc is installed on first run:\
  add `--verbosity=info` to stack options line to show ghc install progress
  (but this also shows unwanted "resolver" output on every run.
  `--verbosity=warning` hides that, but still shows package install progress.
  `--verbosity=error` hides that too.)

- Avoiding recompilation delay on every run:\
  use `script --compile` in stack options line

- Recompiling with full optimisation, accepting greater recompilation delay:\
  use `script --optimize` instead of `script --compile`

- Running stack script in threaded mode when using packages that require this
  (ansi-terminal-game, etc.):  add `--ghc-options=-threaded` to stack options line

- Providing ready-to-run binaries that don't require the user to have `stack` or other haskell tools:
  - set up Github CI workflows to build binary artifacts on the main platforms 
    (and ideally, statically link the GNU/Linux binary);
    add those to a Github release for stable download url.
  - mac: get your app packaged in homebrew
  - etc.

- Providing screenshots/screencasts:\
  use a convenient screenshot tool on your platform (eg CMD-SHIFT-5 and friends on mac);
  or install and use asciinema to record .cast files,
  asciicast2gif or similar to convert those to animated GIF images;
  add the images to a README.md.

### Tools

- Getting haskell-language-server to see extra packages, eg for editing in VS Code:\
  add this `hie.yaml` in the same directory:
  ```
  cradle:
    stack:
  ```
  and `stack install` each extra package in stack's global project.\
  (Still flaky..)

- Configure GHC build options, eg to silence unwanted warnings:\
  Add lines above your imports like\
  `{-# OPTIONS_GHC -Wno-missing-signatures -Wno-unused-imports #-}`

- Enabling/disabling GHC's optional Haskell language extensions:\
  Add lines above your imports like\
  `{-# LANGUAGE MultiWayIf, RecordWildCards #-}`

### Functionality

- Drawing anywhere on the terminal, portably:\
  use [ansi-terminal](https://hackage.haskell.org/package/ansi-terminal)

- Getting non-blocking input, a ready-made event loop, and more powerful drawing, portably:\
  use [ansi-terminal-game](https://hackage.haskell.org/package/ansi-terminal-game)

- Getting more powerful input/drawing/event loop, if you don't care about Windows:\
  use [vty](https://hackage.haskell.org/package/vty) and [brick](https://hackage.haskell.org/package/brick)

- Getting arrow key and modifier key inputs:\
  use vty

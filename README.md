# corral

Runs your dev processes side by side and shows one of them at a time. A
deliberately small vibe-coded replacement for the parts of mprocs I
actually use: find the projects in a tree, start the ones I want,
watch each, stop and restart them individually.

```
 ○ .            0/4 │ 12:04:31 INFO  convex dev listening
 ● api          2/3 │ 12:04:32 INFO  reverse proxy on :8443
 ● services/web 1/2 │ ➜  Local:   http://localhost:5173/
 ! tools     broken │
 j/k move  l enter  s start  S start all  q quit
```

The side panel is one flat list at a time. At the top it lists every
`corral.json` under the working directory. `l` steps into one and the same
list becomes that config's tasks; `h` steps back out. That is the whole
navigation model — there is no tree to expand and nothing is ever more than
two `h` presses from anywhere else.

**Nothing starts on its own.** `s` starts the selected task, `S` starts
everything in the selected config. Discovery finding twenty projects should
not mean twenty dev servers.

## Building

Needs Zig 0.16. `shell.nix` pins one:

```sh
nix-shell                    # drops you into fish with zig on PATH
zig build -Doptimize=ReleaseSafe
./zig-out/bin/corral
```

The first build downloads [ghostty][] (~450MB unpacked into `zig-pkg/`) and
compiles its terminal emulator from source. Later builds are incremental.

```sh
zig build test               # unit tests
zig build run                # debug build, straight from source
```

## Installing (nix)

`flake.nix` builds against the installing machine's nixpkgs, taking zig from
`pkgs.zig_0_16` specifically. A nixpkgs without that attribute is an error, not
a reason to try some other zig.

```sh
nix run .                    # try it from a checkout
nix build .                  # ./result/bin/corral
```

In a NixOS config, add the flake as an input and take either the package or the
overlay:

```nix
{
  inputs.corral.url = "path:/home/you/projects/corral";   # or a git URL
  inputs.corral.inputs.nixpkgs.follows = "nixpkgs";

  # ... in your system module:
  environment.systemPackages = [ inputs.corral.packages.${pkgs.system}.default ];

  # or, if you would rather say `pkgs.corral` — this one builds against whatever
  # pkgs applies it, so it needs no `follows`:
  nixpkgs.overlays = [ inputs.corral.overlays.default ];
}
```

`nix develop` gives the same shell as `nix-shell`. Dependencies are fetched once
into a fixed-output derivation, so the sandboxed build itself needs no network;
after changing `build.zig.zon`, refresh `depsHash` in `package.nix` the way the
comment there describes.

## Config

`corral.json`, anywhere in the tree:

```json
{
  "tasks": {
    "convex": {
      "shell": "vp run dev",
      "cwd": "convex",
      "stop": { "send-keys": ["<C-c>"] }
    },
    "web": "npm run dev"
  }
}
```

| field | |
| --- | --- |
| `shell` | the command, run with `sh -c`. A bare string task is shorthand for this. |
| `cwd` | working directory, resolved against the config's directory. Defaults to it. |
| `env` | extra environment variables |
| `stop` | `"SIGINT"` / `"SIGTERM"` / `"SIGKILL"`, or `{"send-keys": ["<C-c>"]}` |
| `autostart` | `false` excludes the task from `S`. Nothing autostarts either way. |

Tasks appear in the order the file lists them. A task that ignores its stop
request gets five seconds, then `SIGKILL`.

`corral -c <path>` opens one config directly. It still appears in the list,
so `h` gets you back to whatever else is around.

## Keys

| key | |
| --- | --- |
| `j` / `k`, arrows, `1`–`9` | move |
| `l` / `→` | step in: into a config, or into the task's own output |
| `h` / `←` | step back out |
| `^a` | leave a focused task |
| `s` / `S` | start the task / everything in this config |
| `x` / `X` / `r` | stop / force kill / restart |
| `^u` `^d` `^e` `^y`, PgUp/PgDn, `g` / `G` | scroll output |
| wheel | scroll the focused task's output, three lines a notch |
| `w` | dump the task's scrollback to the host terminal |
| `z` | zoom (hide the panel) |
| `q` | stop everything and quit |

While a task is focused, every key goes straight to it — including `^c`. The
wheel is the exception: corral keeps that one, unless the program running in
the task asked for the mouse itself.

## Discovery

Walks down from the working directory looking for `corral.json`, up to eight
levels deep. It skips hidden directories and the usual heavy ones
(`node_modules`, `target`, `vendor`, `dist`, `build`, `out`, `result`,
`zig-out`, `__pycache__`, `Pods`, `DerivedData`). Symlinked directories are
listed but never descended into, which is also what makes a cyclic symlink a
non-event.

Configs are sorted shallowest first, so the one in the directory you launched
from is always the top row.

Every config is parsed at startup — that is where the task counts in the list
come from, and why a config with a typo in it says `broken` immediately
rather than when you finally step into it. Parsing is all that happens; no
process is started.

## Two deliberate design choices

**The mouse is left alone, until a task is focused.** With the list in front
corral enables no mouse reporting at all, so your terminal's own selection,
scrollback and ctrl-click-to-open-link keep working over task output.

Focusing a task turns reporting on, because the alternative is worse: in the
alternate screen with reporting off, terminals turn the wheel into arrow keys,
and a dev server that is not reading its input echoes those back as `^[[A`.
With it on, the wheel scrolls the task's own scrollback instead — and a
program that asked for the mouse itself (vim, htop, lazygit) gets the events,
while a full-screen one that did not still gets its arrow keys. The cost is
that selection needs shift held while a task is focused, which every terminal
that reports the mouse honours. `^a` hands the mouse straight back.

**`w` hands the log back to the host terminal.** It leaves the alternate
screen and prints the task's scrollback as ordinary output, so the host's
selection, search and hyperlink handling apply to it. Press enter to return.

## How it works

| | |
| --- | --- |
| `src/Config.zig` | `corral.json`, path resolution, `<C-c>` key notation |
| `src/discover.zig` | the recursive walk |
| `src/Pty.zig` | one pty and one child per run |
| `src/Task.zig` | a ghostty terminal plus the stopped/running/stopping machine |
| `src/Term.zig` | the host terminal: raw mode, alternate screen, signals |
| `src/Grid.zig` | a double-buffered cell grid that diffs frames into escape sequences |
| `src/input.zig` | key decoding for the list, and mouse reports |
| `src/App.zig` | layout, the event loop, the two-level list |

Terminal emulation is [libghostty-vt][ghostty], used as a Zig module. It is
the emulator out of [Ghostty][], so a task's output is parsed by the same
code a real terminal would use — including scrollback, wide characters, and
replies to the queries programs send when they want to know what they are
running inside.

The TUI is custom made, about 500 lines across `Grid.zig` and the drawing
half of `App.zig`. A panel and one output pane did not justify a framework,
and owning the cell grid means a task's screen can be blitted straight across
rather than translated into somebody else's cell model. Colours pass through
as palette *indexes* wherever a task used one, so your terminal's theme still
decides what "red" looks like.

One `poll` loop watches stdin, every running task's pty, and a self-pipe fed
by the signal handler. Repaints coalesce to one frame per 16ms, and only the
visible task is drawn; background tasks accumulate into their own emulator,
which costs nothing to not look at.

Tasks are spawned with `setsid`, with the pty claimed as the controlling
terminal. That is load-bearing twice over: without a controlling terminal,
writing `0x03` is just a byte and `send-keys: <C-c>` silently does nothing;
and being its own process group is what lets a stop reach the whole tree
rather than only the wrapping `sh`.

[ghostty]: https://github.com/ghostty-org/ghostty
[Ghostty]: https://ghostty.org

# Double Commander with remote control

**This is the `remote-control` branch of a fork of [Double Commander](https://github.com/doublecmd/doublecmd),
not an official Double Commander.** It adds an opt-in, local-only channel through which another program of
the same user can ask Double Commander what it shows and send it a few safe commands. The motivating use is
**[VersariteViewer](https://github.com/versarite/VersariteViewer)**, a fast image viewer that works side by side
with Double Commander: it follows the folder and file under the cursor, Double Commander follows the viewer,
and Double Commander's toolbar buttons drive the viewer. Windows and Linux.

The addition is offered to the Double Commander developers for discussion; until they decide, it lives here.
It is kept small on purpose (one new unit, a few lines elsewhere), so it can follow Double Commander's master
closely. Everything else is Double Commander as its developers made it - please report problems with this
branch here, not to them. Double Commander's own README follows below.

**VersariteViewer and Double Commander together** (1 min 40 s):

https://github.com/user-attachments/assets/51d4252d-0e09-4e7e-b5c4-178712619f69

([the video as a file](docs/VersariteViewer_DoubleCommander.mp4?raw=true))

## Download

- **Linux x86_64 (GTK2):** `doublecmd-1.3-remote-control.gtk2.x86_64.tar.gz` on the
  [release page](https://github.com/versarite/doublecmd/releases) - unpack, `./install.sh --user --enable-remote`
  (see `README-remote-control.txt` inside).
- **Windows:** see the release page, or build from this branch (Lazarus 4.x, `build.bat`).

## Switching it on

It is off by default. With Double Commander closed:

1. In `doublecmd.xml`, under `<Behaviours>`: `<RemoteControl>True</RemoteControl>` (there is no options page yet).
2. In `remoteallow.txt` (Double Commander's settings folder; made at the first start with comments only):
   one line with the program's name, e.g. `VersariteViewer`.
3. Start Double Commander and the program. On its first `HELLO`, Double Commander asks once whether to allow it.

The settings folder is `%APPDATA%\doublecmd` on Windows (or `<program folder>\settings` for a portable copy),
`~/.config/doublecmd` on Linux.

## Changes

A few commits on top of master, each one step (see the history of this branch):

| File | Change |
|---|---|
| src/uremotecontrol.pas | new: the channel (Unix: a domain socket; Windows: a named pipe), pairing, request handling, per-client event queue |
| src/uglobs.pas | new setting `Behaviours/RemoteControl` (False by default) |
| src/fmain.pas, src/fmain.lfm | starts the channel after the main form is created and stops it when the form is destroyed; actions for the new commands (category Tools) |
| src/umaincommands.pas | parameters for three existing commands, six new commands (see below) |
| src/frames/foptionstoolbarbase.pas | toolbar editor: for `cm_ViewerCommand`, the parameter helper button lists the connected program's commands |
| tools/remote_client.py | a small test client (Python 3.8+, nothing else) |

## Security

- **Off by default.**
- **Unix:** a domain socket at `$XDG_RUNTIME_DIR/doublecmd-remote`, or else `/tmp/doublecmd-<uid>/` (mode 0700).
  The socket itself has mode 0600, and each connection's user id is checked with `SO_PEERCRED`.
- **Windows:** a named pipe `\\.\pipe\doublecmd-remote-<user SID>`.
  - Its access list is protected and has one entry, full access for the current user (`D:P(A;;GA;;;<SID>)`).
    Other users, services and anonymous logons can't open it.
  - `PIPE_REJECT_REMOTE_CLIENTS` keeps it local.
  - `FILE_FLAG_FIRST_PIPE_INSTANCE` stops a second Double Commander from serving the same name.
  - Clients should open it with `SECURITY_IDENTIFICATION`, so a squatter can't impersonate them.
- **Allow list:** only program names listed in `remoteallow.txt` may connect at all (`#` or `;` starts a
  comment). When missing, it is created with comments only, so **no program may connect until the user names
  it**. Other names are refused without asking the user.
- **Pairing:** on the first `HELLO` from a listed program, Double Commander asks the user ("Allow ...?",
  showing the connecting program's file) and hands out a token. The token is kept with that program file in
  `remoteclients.txt` (mode 0600); deleting the line withdraws access.
- **Bound to the program file:** Double Commander looks up the executable at the other end of the connection
  (Windows: `GetNamedPipeClientProcessId` + `QueryFullProcessImageNameW`; Unix: the `SO_PEERCRED` pid +
  `/proc/<pid>/exe`). A token only counts from the file it was given to; a copy of the program elsewhere is
  asked about again. If the file can't be read (a process with more rights), the token alone counts.
- **No repeated questions:** a refused program isn't asked about again until Double Commander restarts.
- **Command allow list:** only a fixed set of internal commands can be run (see below). Nothing that deletes,
  moves, copies or runs programs.
- **Never blocks:** the channel is polled from a 10 ms timer with non-blocking / overlapped I/O, so nothing
  holds up the UI. A client that doesn't read its answers is dropped after 1 s.

## Protocol

UTF-8 lines, fields separated by TAB. Each request gets exactly one answer line, beginning with `OK` or `ERR`.
`<panel>` is `left`, `right`, `active` or `inactive`.

    HELLO <name> [<token>]          -> OK <token> | ERR denied
    GET ACTIVE                      -> OK left|right
    GET PATH <panel>                -> OK <path> filesystem|other
    GET CURSOR <panel>              -> OK <full name>    (empty: "..", or not a file system)
    GET FOLLOW <panel>              -> OK <path> filesystem|other <cursor>   (PATH + CURSOR in one)
    GET VIEW <panel>                -> OK columns|brief|thumbnails
    GET WINDOW                      -> OK <left> <top> <width> <height> shown|hidden
    GET UPTIME                      -> OK <ms since the channel started>
    GET EVENT                       -> OK [<event fields>]   (just OK: nothing queued)
    SET WINDOW <l> <t> <w> <h>      -> OK    (sent before the window is shown: applied once it is)
    SET CURSOR <panel> <full name>  -> OK    (puts that file under the cursor; another folder: goes there)
    SET SORT <panel> name|ext|size|date asc|desc -> OK
    SET COMMANDS <name>=<caption> ... -> OK  (the client's own commands, see below)
    CMD <cm_...> [<param>...]       -> OK | ERR not allowed | ERR not found

Everything except `HELLO` is refused until the client has been accepted. `SET WINDOW` exists because on
Windows a client that started Double Commander often can't move its window itself (a different integrity
level, or the timing at start-up), and under Wayland no program may place another's window. `GET FOLLOW`
exists so a client that follows the cursor needs only one round trip per poll (about 3.5 ms).

### Commands allowed with `CMD`

`cm_ChangeDir`, `cm_ChangeDirToParent`, `cm_ChangeDirToHome`, `cm_MakeDir` (only with `path=`), `cm_Refresh`,
`cm_FocusSwap`, and the view modes (`cm_ColumnsView`, `cm_BriefView`, `cm_ThumbnailsView` and their `Left` /
`Right` variants).

### Events (Double Commander to the client)

The channel stays request / answer. Double Commander queues messages for each paired, connected client (at
most 20; the oldest are dropped), and the client fetches them with `GET EVENT`.

    TREE <folder> <subfolder> <subfolder> ...   (from cm_SendTree; full names, sorted)
    FOLLOW on|off|1|2                           (from cm_ViewerFollowModeOn / Off)
    COMMAND <name>                              (from cm_ViewerCommand and the cm_Remote... commands)

## Changes to internal commands

Existing commands, new parameters (behaviour without the parameter is unchanged):

- `cm_MakeDir path=<folder>`: creates the folder without the dialog. A relative path is taken from the active
  panel's folder; an existing folder is left alone.
- `cm_ThumbnailsView`, `cm_LeftThumbView`, `cm_RightThumbView` take `state=on` / `state=off`. Without it they
  toggle as before.

New commands, for toolbar buttons and hotkeys (category Tools). If remote control is off or no client is
connected, each just says so.

| Command | What it does |
|---|---|
| `cm_SendTree` | Queues `TREE` with the active panel's folder and its first-level subfolders (hidden / system ones only when Double Commander shows them) |
| `cm_ViewerFollowModeOn` | Queues `FOLLOW on`, or `FOLLOW 1` / `FOLLOW 2` with `mode=1` / `mode=2` |
| `cm_ViewerFollowModeOff` | Queues `FOLLOW off` |
| `cm_ViewerCommand` | `cmd=<name>` (or just `<name>`): queues `COMMAND <name>`. The client decides what the name means, so one toolbar button per client command needs no further change to Double Commander |
| `cm_RemoteSendFolderToInactive` | Asks the client for its folder (`COMMAND SendFolderToInactive`); it answers with `cm_ChangeDir inactivepath=` |
| `cm_RemoteCreateSortFromSubdirs` | `COMMAND CreateSortFromSubdirs`: the client makes a list of the subfolders of the folder under the cursor; parameter `1`: `CreateSortFromSubdirsWithFolder` (the folder itself first) |

### The client's commands in the toolbar editor

A client can announce its own commands with `SET COMMANDS <name>=<caption> ...` (one TAB-separated field per
command; VersariteViewer sends this once per connection). Double Commander keeps them in `remotecommands.txt`
in the configuration folder (`<client> TAB <name> TAB <caption>` per line; a client's lines are replaced as a
whole, and the file is written only when they change).

In the toolbar editor, when the button's internal command is `cm_ViewerCommand`, the helper button next to
**Parameters** shows these commands as a menu ("caption (name)") in place of the `%` variables. Choosing one
puts `cmd=<name>` into the parameters, and its caption into the tooltip if the tooltip is empty or still the
command's default. The list comes from the file, so it is there even while the client isn't running.

Icons for such buttons: [VersariteViewer's `docs/dc_icons`](https://github.com/versarite/VersariteViewer/tree/main/docs/dc_icons).

## Tested

- **Linux (GTK2, under a virtual display):** the pairing dialog and the token; every
  request; `cm_ChangeDir rightpath=`; `cm_MakeDir path=` (including a folder name with a space); thumbnails on /
  on again / off; `SET` / `GET WINDOW`; `cm_Delete` refused; requests before `HELLO` refused; an empty allow
  list refuses every name; `SET COMMANDS` and the toolbar editor's menu.
- **Windows 10 (Lazarus 4.8):** the named pipe, pairing, follow modes, `SET WINDOW` side by side, the toolbar
  commands - used daily together with VersariteViewer.

## Open questions

- **Pipe name squatting (Windows):** another program of the same user could create the pipe name before Double
  Commander starts, since the name is predictable. Clients only let it identify them, not impersonate them.
  Checking the server process (`GetNamedPipeServerProcessId`) would close that too.
- **UI:** an options page (on / off, list and revoke paired programs), and translations of the pairing question.
- **Wrong token:** a wrong token for a known name currently asks the user again. Should it simply be refused?
- **Wayland:** the pairing question may open behind other windows.
- **Command names:** `cm_Viewer...` assume an external viewer; a more neutral name (e.g. `cm_RemoteCommand`)
  may suit better.

## License

Double Commander is free software by Alexander Koblov and its contributors, under the GNU General Public
License, version 2 or (at your option) any later version, as its source files state; the licence text is
[`LICENSE.md`](LICENSE.md). Components and libraries that come with it keep their own licences
(`doc/COPYING.*` and the files in `components/`).

The remote-control commits are Copyright (C) 2026 DL1BWA/AC1WW, under the same terms (GPL version 2 or
later). They come without any warranty, like Double Commander itself.

---

*Double Commander's own README:*

**Double Commander** is a [free](https://www.gnu.org/philosophy/free-sw.html) cross-platform open source file manager with two panels side by side (or one above the other). It is inspired by Total Commander and features some innovative new ideas. 

Double Commander can be run on several platforms and operating systems.
It supports 32-bit and 64-bit processors. See [Supported platforms](https://github.com/doublecmd/doublecmd/wiki/Supported-platforms)
for a complete list.

See Double Commander in action in the [Screenshot Gallery](https://doublecmd.sourceforge.io/gallery).

## Where to start

### Download

Go to the [Double Commander download page](https://sourceforge.net/p/doublecmd/wiki/Download) to download the latest release.

You can check the latest version on the [Versions](https://github.com/doublecmd/doublecmd/wiki/Versions) page.

See if Double Commander is supported for your platform on the [Supported
platforms](https://github.com/doublecmd/doublecmd/wiki/Supported-platforms) page.

### Develop

For more information on the development of Double Commander,
see the [Development](https://github.com/doublecmd/doublecmd/wiki/Development) page.

### Discuss
  
Go to our [forum](https://doublecmd.h1n.ru) for discussions. There are English and Russian sections.

If you want to stay up-to-date with the project, you can check out the available [news feeds](https://github.com/doublecmd/doublecmd/wiki/News-feeds).

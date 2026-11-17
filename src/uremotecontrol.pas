{
   Double Commander
   -------------------------------------------------------------------------
   Remote control: a local channel through which another program of the
   same user (an image viewer, a script) can ask Double Commander what it
   shows and send it a few commands.

   Off by default (Behaviours: RemoteControl). Only the current user can
   connect:
   - Linux / Unix: a Unix domain socket in $XDG_RUNTIME_DIR (else a
     private folder in /tmp, mode 0700), the socket mode 0600, and every
     connection's user id is checked (SO_PEERCRED). The sockets are not
     passed on to programs Double Commander starts (close-on-exec), a
     write to a program that has gone doesn't raise SIGPIPE, and what a
     full socket can't take yet is sent on the next round.
   - Windows: a named pipe \\.\pipe\doublecmd-remote-<user SID> whose
     access list admits only the current user, local clients only
     (PIPE_REJECT_REMOTE_CLIENTS); the first instance is created with
     FILE_FLAG_FIRST_PIPE_INSTANCE, so a second Double Commander does not
     serve the same name.
   Only programs named in remoteallow.txt (configuration folder) may
   connect at all; any other name is turned away without a question. If
   the file is missing, it is made with comments only (an example
   included), so no program may connect until the user adds a name. A listed program
   says who it is (HELLO); the first time, the user is asked whether to
   allow it (the question shows its program file), and it gets a token,
   which it presents afterwards. Allowed programs are listed in
   remoteclients.txt with their token and program file: the token counts
   only from that same program file (a copy elsewhere is asked about
   again). Delete a line to withdraw. A program refused once is not
   asked about again until Double Commander restarts.

   Protocol: UTF-8 text lines, fields separated by TAB; one answer line
   per request, beginning with OK or ERR.

     HELLO <name> [<token>]        -> OK <token> | ERR denied
     GET ACTIVE                    -> OK left|right
     GET PATH <panel>              -> OK <path> <filesystem|other>
     GET CURSOR <panel>            -> OK <full name>  (a file or a folder;
                                      empty: "..", or not on the file system)
     GET VIEW <panel>              -> OK columns|brief|thumbnails
     GET FOLLOW <panel>            -> OK <path> <filesystem|other> <cursor>
                                      (PATH and CURSOR in one answer)
     GET WINDOW                    -> OK <left> <top> <width> <height> <shown|hidden>
     SET WINDOW <l> <t> <w> <h>    -> OK  (before the window is shown at the
                                      start: applied again when it is, so
                                      the saved place doesn't win)
     CMD <cm_...> [<param>...]     -> OK | ERR not allowed | ERR not found
     SET CURSOR <panel> <full name> -> OK  (that file under the panel's cursor;
                                      another folder: the panel goes there)
     SET SORT <panel> name|ext|size|date asc|desc -> OK
     GET UPTIME                    -> OK <ms since the remote control started>
     GET EVENT                     -> OK [<event fields>]  (the oldest message
                                      Double Commander has for this program;
                                      just OK: none)
     SET COMMANDS <name>=<caption> ... -> OK  (the program's own commands, for
                                      cm_ViewerCommand: kept in
                                      remotecommands.txt and offered in the
                                      toolbar editor's parameter helper)

   Events, queued for every allowed program
   connected at that moment:
     TREE <folder> <subfolder> <subfolder> ...   (cm_SendTree; full names)
     COMMAND <name>                              (cm_ViewerCommand cmd=<name>:
                                                  the viewer's own command
                                                  of that name)
     FOLLOW on|off|1|2                           (cm_ViewerFollowModeOn /
                                                  Off: the viewer follows
                                                  Double Commander or stops;
                                                  on = its last mode)

   <panel> = left, right, active or inactive. CMD runs an internal command
   as a toolbar button does, from a short allow-list only (changing
   folders, view modes, creating a folder, refresh): nothing that deletes,
   moves, or runs programs.

   Copyright (C) 2026 DL1BWA/AC1WW (VersariteViewer)

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program. If not, see <http://www.gnu.org/licenses/>.
}

unit uRemoteControl;

{$mode objfpc}{$H+}

interface

uses
  Classes;

{ Starts listening if gRemoteControl is on (main form created). }
procedure StartRemoteControl;
procedure StopRemoteControl;
{ The socket's file name / the pipe's name (for the options page and the
  documentation). }
function RemoteControlSocketName: String;
{ cm_SendTree: the first-level folders of the
  active panel's folder are queued for every connected, allowed program
  (it fetches them with GET EVENT). }
procedure RemoteSendTree;
{ cm_ViewerFollowModeOn / Off: FOLLOW <on|off|1|2>
  queued for every connected, allowed program. }
procedure RemoteViewerFollow(const AMode: String);
{ cm_ViewerCommand: COMMAND <name> queued for every
  connected, allowed program (the viewer runs its command of that name). }
procedure RemoteViewerCommand(const AName: String);
{ The commands the allowed programs said they have (SET COMMANDS), as
  lines name=caption in their order; kept in remotecommands.txt, so they
  are offered while the program isn't running too. Empty: none known. }
procedure RemoteClientCommands(AList: TStrings);

implementation

{$IF DEFINED(UNIX) or DEFINED(MSWINDOWS)}
uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils, Types, ExtCtrls, Forms, Controls, Dialogs,
  {$IFDEF UNIX}
  LCLIntf, BaseUnix, Sockets,
  {$ENDIF}
  uGlobs, uGlobsPaths, uFileView, uFileSource, uFileSystemFileSource, uFile,
  uFileSorting, uFileFunctions, uFormCommands, fMain;

const
  ClientsFileName = 'remoteclients.txt';
  CommandsFileName = 'remotecommands.txt';
  MaxCommands = 500;
  AllowFileName = 'remoteallow.txt';
  MaxLine = 65536;
  MaxEvents = 20;                      { per program; older ones are dropped }
  { How often the channel is looked at. The asking program waits for its
    answer until then (VersariteViewer: its window), so short; a look
    costs next to nothing (Day 40: was 50). }
  PollMs = 10;
  { The internal commands a remote program may run. }
  AllowedCommands: array[0..14] of String = (
    'cm_changedir', 'cm_makedir', 'cm_refresh',
    'cm_thumbnailsview', 'cm_leftthumbview', 'cm_rightthumbview',
    'cm_columnsview', 'cm_leftcolumnsview', 'cm_rightcolumnsview',
    'cm_briefview', 'cm_leftbriefview', 'cm_rightbriefview',
    'cm_focusswap', 'cm_changedirtoparent', 'cm_changedirtohome');

{$IFDEF UNIX}
const
  SocketFileName = 'doublecmd-remote';
  SO_PEERCRED_OPT = 17;
  { A write to a program that has gone raises SIGPIPE, which ends a
    process that doesn't handle it: asked not to (Linux), EPIPE instead. }
  {$IFDEF LINUX}
  RC_MSG_NOSIGNAL = $4000;
  {$ELSE}
  RC_MSG_NOSIGNAL = 0;
  {$ENDIF}
  RC_FD_CLOEXEC = 1;
  { Answers not taken yet by a program that doesn't read: it is dropped. }
  MaxOutput = 1024 * 1024;

type
  TPeerCred = record
    Pid: Int32;
    Uid: UInt32;
    Gid: UInt32;
  end;
{$ENDIF}

{$IFDEF MSWINDOWS}
{ Declared here (not taken from the Windows unit) so that every parameter
  is a plain pointer: no var/pointer overload can be picked wrongly. }
const
  PipePrefix = '\\.\pipe\doublecmd-remote-';
  RC_TOKEN_QUERY = $0008;
  RC_TokenUser = 1;
  RC_SDDL_REVISION_1 = 1;
  RC_PIPE_ACCESS_DUPLEX = $00000003;
  RC_FILE_FLAG_OVERLAPPED = $40000000;
  RC_FILE_FLAG_FIRST_PIPE_INSTANCE = $00080000;
  RC_PIPE_TYPE_BYTE = $00000000;
  RC_PIPE_READMODE_BYTE = $00000000;
  RC_PIPE_WAIT = $00000000;
  RC_PIPE_REJECT_REMOTE_CLIENTS = $00000008;
  RC_PIPE_UNLIMITED_INSTANCES = 255;
  RC_ERROR_IO_PENDING = 997;
  RC_ERROR_PIPE_CONNECTED = 535;
  RC_WAIT_OBJECT_0 = 0;
  RC_PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  PipeBufferSize = 4096;
  WriteWaitMs = 1000;

type
  TRCOverlapped = record
    Internal: PtrUInt;
    InternalHigh: PtrUInt;
    Offset: DWORD;
    OffsetHigh: DWORD;
    hEvent: THandle;
  end;
  PRCOverlapped = ^TRCOverlapped;

  TRCSidAndAttributes = record
    Sid: Pointer;
    Attributes: DWORD;
  end;
  PRCSidAndAttributes = ^TRCSidAndAttributes;

  TRCSecurityAttributes = record
    nLength: DWORD;
    lpSecurityDescriptor: Pointer;
    bInheritHandle: LongBool;
  end;

function RC_OpenProcessToken(Process: THandle; Access: DWORD; Token: PHandle): LongBool;
  stdcall; external 'advapi32.dll' name 'OpenProcessToken';
function RC_GetTokenInformation(Token: THandle; InfoClass: DWORD; Info: Pointer;
  InfoLength: DWORD; ReturnLength: PDWORD): LongBool;
  stdcall; external 'advapi32.dll' name 'GetTokenInformation';
function RC_ConvertSidToStringSidW(Sid: Pointer; StringSid: PPWideChar): LongBool;
  stdcall; external 'advapi32.dll' name 'ConvertSidToStringSidW';
function RC_ConvertStringSDToSDW(StringSD: PWideChar; Revision: DWORD;
  SD: PPointer; SDSize: PDWORD): LongBool;
  stdcall; external 'advapi32.dll' name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';
function RC_LocalFree(Mem: Pointer): Pointer;
  stdcall; external 'kernel32.dll' name 'LocalFree';
function RC_CreateNamedPipeW(Name: PWideChar; OpenMode, PipeMode, MaxInstances,
  OutBufferSize, InBufferSize, DefaultTimeOut: DWORD; SA: Pointer): THandle;
  stdcall; external 'kernel32.dll' name 'CreateNamedPipeW';
function RC_ConnectNamedPipe(Pipe: THandle; Ovl: PRCOverlapped): LongBool;
  stdcall; external 'kernel32.dll' name 'ConnectNamedPipe';
function RC_DisconnectNamedPipe(Pipe: THandle): LongBool;
  stdcall; external 'kernel32.dll' name 'DisconnectNamedPipe';
function RC_PeekNamedPipe(Pipe: THandle; Buffer: Pointer; BufferSize: DWORD;
  BytesRead, TotalAvail, BytesLeft: PDWORD): LongBool;
  stdcall; external 'kernel32.dll' name 'PeekNamedPipe';
function RC_ReadFile(F: THandle; Buffer: Pointer; ToRead: DWORD; Read: PDWORD;
  Ovl: PRCOverlapped): LongBool;
  stdcall; external 'kernel32.dll' name 'ReadFile';
function RC_WriteFile(F: THandle; Buffer: Pointer; ToWrite: DWORD; Written: PDWORD;
  Ovl: PRCOverlapped): LongBool;
  stdcall; external 'kernel32.dll' name 'WriteFile';
function RC_GetOverlappedResult(F: THandle; Ovl: PRCOverlapped; Transferred: PDWORD;
  Wait: LongBool): LongBool;
  stdcall; external 'kernel32.dll' name 'GetOverlappedResult';
function RC_CreateEventW(SA: Pointer; ManualReset, InitialState: LongBool;
  Name: PWideChar): THandle;
  stdcall; external 'kernel32.dll' name 'CreateEventW';
function RC_WaitForSingleObject(H: THandle; Ms: DWORD): DWORD;
  stdcall; external 'kernel32.dll' name 'WaitForSingleObject';
function RC_CancelIo(F: THandle): LongBool;
  stdcall; external 'kernel32.dll' name 'CancelIo';
function RC_CloseHandle(H: THandle): LongBool;
  stdcall; external 'kernel32.dll' name 'CloseHandle';
function RC_GetCurrentProcess: THandle;
  stdcall; external 'kernel32.dll' name 'GetCurrentProcess';
function RC_GetLastError: DWORD;
  stdcall; external 'kernel32.dll' name 'GetLastError';
function RC_GetNamedPipeClientProcessId(Pipe: THandle; Pid: PDWORD): LongBool;
  stdcall; external 'kernel32.dll' name 'GetNamedPipeClientProcessId';
function RC_OpenProcess(Access: DWORD; Inherit: LongBool; Pid: DWORD): THandle;
  stdcall; external 'kernel32.dll' name 'OpenProcess';
function RC_QueryFullProcessImageNameW(Process: THandle; Flags: DWORD; Name: PWideChar;
  Size: PDWORD): LongBool;
  stdcall; external 'kernel32.dll' name 'QueryFullProcessImageNameW';
{$ENDIF}

type
  TRemoteClient = class
    Input: String;
    Name: String;
    Allowed: Boolean;
    Closed: Boolean;
    Events: TStringList;               { for GET EVENT; made on first use }
    ExePath: String;                   { the program file at the other end ('' unknown) }
    {$IFDEF UNIX}
    Socket: cint;
    Output: String;                    { not sent yet (the socket was full) }
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    Pipe: THandle;
    Ovl: TRCOverlapped;
    {$ENDIF}
    destructor Destroy; override;
  end;

  TRemoteServer = class
  private
    FTimer: TTimer;
    FClients: TList;
    FBusy: Boolean;
    FPendingBounds: TRect;             { SET WINDOW before the window was shown }
    FStartMs: QWord;                   { for GET UPTIME }
    FDenied: TStringList;              { name + program refused in this session }
    FPending: Boolean;
    { Linux: the window manager's frame is known only a moment after the
      window is placed or shown; the place is applied again a few times
      (FAgainLeft, every 250 ms), each time with the frame as it is. }
    FAgainLeft: Integer;
    FAgainAt: QWord;
    {$IFDEF UNIX}
    FSocket: cint;
    FFileName: String;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FPipeName: WideString;
    FSddl: WideString;
    FListen: THandle;                  { the instance waiting for a client }
    FListenOvl: TRCOverlapped;
    FListenConnected: Boolean;         { a client came before we waited }
    function MakePipeInstance(AFirst: Boolean): THandle;
    function Listen(AFirst: Boolean): Boolean;
    {$ENDIF}
    procedure ApplyBounds(const R: TRect);
    procedure AcceptClients;
    procedure ReadAvailable(AClient: TRemoteClient);
    procedure SendLine(AClient: TRemoteClient; const ALine: String);
    procedure CloseClient(AClient: TRemoteClient);
    {$IFDEF UNIX}
    procedure Flush(AClient: TRemoteClient);
    {$ENDIF}
    procedure HandleTimer(Sender: TObject);
    procedure Serve(AClient: TRemoteClient);
    function Answer(AClient: TRemoteClient; const ALine: String): String;
  public
    { Queues AEvent for every allowed program; how many got it. }
    function Broadcast(const AEvent: String): Integer;
    {$IFDEF UNIX}
    constructor Create(ASocket: cint; const AFileName: String);
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    constructor Create(const APipeName, ASddl: WideString);
    { False: the name is served already (another Double Commander). }
    function Start: Boolean;
    {$ENDIF}
    destructor Destroy; override;
  end;

var
  Server: TRemoteServer = nil;

{ ---- helpers ---- }

{$IFDEF UNIX}
function RuntimeFolder: String;
begin
  Result := GetEnvironmentVariable('XDG_RUNTIME_DIR');
  if (Result = '') or not DirectoryExists(Result) then
  begin
    Result := '/tmp/doublecmd-' + IntToStr(FpGetUid);
    if not DirectoryExists(Result) then
      FpMkdir(Result, &700);
  end;
  Result := IncludeTrailingPathDelimiter(Result);
end;

function RemoteControlSocketName: String;
begin
  Result := RuntimeFolder + SocketFileName;
end;

{ Not handed on to the programs Double Commander starts (an open copy of
  the listening socket in a viewer started from here would answer a later
  Double Commander's "is one serving already?" check; a copy of a client's
  socket would keep that client's connection open after it was closed). }
procedure NoInherit(ASocket: cint);
begin
  FpFcntl(ASocket, F_SETFD, FpFcntl(ASocket, F_GETFD) or RC_FD_CLOEXEC);
end;

function SameUser(ASocket: cint): Boolean;
var
  Cred: TPeerCred;
  Len: TSockLen;
begin
  FillChar(Cred, SizeOf(Cred), $FF);
  Len := SizeOf(Cred);
  Result := (fpGetSockOpt(ASocket, SOL_SOCKET, SO_PEERCRED_OPT, @Cred, @Len) = 0)
    and (Cred.Uid = FpGetUid);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
{ The current user's SID as text (S-1-5-21-...); '' if not known. }
function UserSidString: String;
var
  Token: THandle;
  Buffer: array[0..1023] of Byte;
  Len: DWORD;
  P: PWideChar;
begin
  Result := '';
  if not RC_OpenProcessToken(RC_GetCurrentProcess, RC_TOKEN_QUERY, @Token) then
    Exit;
  try
    Len := 0;
    if RC_GetTokenInformation(Token, RC_TokenUser, @Buffer[0], SizeOf(Buffer), @Len) then
    begin
      P := nil;
      if RC_ConvertSidToStringSidW(PRCSidAndAttributes(@Buffer[0])^.Sid, @P) then
      begin
        Result := UTF8Encode(WideString(P));
        RC_LocalFree(P);
      end;
    end;
  finally
    RC_CloseHandle(Token);
  end;
end;

function RemoteControlSocketName: String;
var
  Sid: String;
begin
  Sid := UserSidString;
  if Sid = '' then
    Result := ''
  else
    Result := PipePrefix + Sid;
end;
{$ENDIF}

function Fields(const ALine: String): TStringArray;
begin
  Result := ALine.Split([#9]);
end;

function IsAllowedCommand(const AName: String): Boolean;
var
  S: String;
begin
  for S in AllowedCommands do
    if SameText(S, AName) then
      Exit(True);
  Result := False;
end;

function PanelView(const AWhich: String; out AView: TFileView): Boolean;
begin
  AView := nil;
  if SameText(AWhich, 'left') then
    AView := frmMain.FrameLeft
  else if SameText(AWhich, 'right') then
    AView := frmMain.FrameRight
  else if SameText(AWhich, 'active') or (AWhich = '') then
    AView := frmMain.ActiveFrame
  else if SameText(AWhich, 'inactive') then
    AView := frmMain.NotActiveFrame;
  Result := Assigned(AView);
end;

function OnFileSystem(AView: TFileView): Boolean;
begin
  Result := AView.FileSource.IsClass(TFileSystemFileSource);
end;

destructor TRemoteClient.Destroy;
begin
  Events.Free;
  inherited Destroy;
end;

{ ---- allowed programs ---- }

function ClientsFile: String;
begin
  Result := gpCfgDir + ClientsFileName;
end;

function SameExe(const A, B: String): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := SameText(A, B);
  {$ELSE}
  Result := A = B;
  {$ENDIF}
end;

{ The program file of the process at the other end; '' if not known. }
{$IFDEF UNIX}
function PeerExe(ASocket: cint): String;
var
  Cred: TPeerCred;
  Len: TSockLen;
begin
  Result := '';
  FillChar(Cred, SizeOf(Cred), 0);
  Len := SizeOf(Cred);
  if (fpGetSockOpt(ASocket, SOL_SOCKET, SO_PEERCRED_OPT, @Cred, @Len) = 0) and (Cred.Pid > 0) then
    Result := fpReadLink('/proc/' + IntToStr(Cred.Pid) + '/exe');
end;
{$ENDIF}
{$IFDEF MSWINDOWS}
function PeerExe(APipe: THandle): String;
var
  Pid, Size: DWORD;
  H: THandle;
  Buffer: array[0..1023] of WideChar;
begin
  Result := '';
  Pid := 0;
  if not RC_GetNamedPipeClientProcessId(APipe, @Pid) or (Pid = 0) then
    Exit;
  H := RC_OpenProcess(RC_PROCESS_QUERY_LIMITED_INFORMATION, False, Pid);
  if H = 0 then
    Exit;
  try
    Size := Length(Buffer);
    if RC_QueryFullProcessImageNameW(H, 0, @Buffer[0], @Size) then
      Result := UTF8Encode(WideString(Copy(Buffer, 0, Size)));
  finally
    RC_CloseHandle(H);
  end;
end;
{$ENDIF}

{ remoteallow.txt: the program names that may connect at all, one per
  line (# or ; starts a comment). Missing: made with comments only, so
  nobody may connect yet; unreadable: nobody may connect. }
function NameAllowed(const AName: String): Boolean;
var
  Lines: TStringList;
  I: Integer;
  FileName: String;
begin
  Result := False;
  FileName := gpCfgDir + AllowFileName;
  Lines := TStringList.Create;
  try
    try
      if FileExists(FileName) then
        Lines.LoadFromFile(FileName)
      else
      begin
        Lines.Add('# Programs allowed to use Double Commander''s remote control:');
        Lines.Add('# one name per line, as the program gives it when it connects.');
        Lines.Add('# Lines starting with # or ; are comments. Remove the # to allow');
        Lines.Add('# a program, for example:');
        Lines.Add('# VersariteViewer');
        Lines.SaveToFile(FileName);
        Lines.Clear;
      end;
    except
      Lines.Clear;
    end;
    for I := 0 to Lines.Count - 1 do
      if (Trim(Lines[I]) <> '') and not (Trim(Lines[I])[1] in ['#', ';'])
        and (Trim(Lines[I]) = AName) then
        Exit(True);
  finally
    Lines.Free;
  end;
end;

{ A paired program: its token counts for that name and, when a program
  file was noted at the pairing, only from that same file (a program file
  that can't be read, e.g. of a process with more rights: the token
  alone). The same program file without its token (it couldn't keep it)
  counts too: ATokenOut is the noted one, so it can keep it now. }
function KnownClient(const AName, AToken, AExe: String; out ATokenOut: String): Boolean;
var
  Lines: TStringList;
  I: Integer;
  F: TStringArray;
begin
  Result := False;
  ATokenOut := AToken;
  if (AName = '') or not FileExists(ClientsFile) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(ClientsFile);
    for I := 0 to Lines.Count - 1 do
    begin
      F := Fields(Lines[I]);
      if (Length(F) < 2) or (F[0] <> AName) then
        Continue;
      if (AToken <> '') and (F[1] = AToken) then
        Exit((Length(F) < 3) or (F[2] = '') or (AExe = '') or SameExe(F[2], AExe));
      if (Length(F) >= 3) and (F[2] <> '') and (AExe <> '') and SameExe(F[2], AExe) then
      begin
        ATokenOut := F[1];
        Exit(True);
      end;
    end;
  finally
    Lines.Free;
  end;
end;

function NewToken: String;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := LowerCase(StringReplace(Copy(GUIDToString(G), 2, 36), '-', '', [rfReplaceAll]));
end;

procedure RememberClient(const AName, AToken, AExe: String);
var
  Lines: TStringList;
  I: Integer;
  F: TStringArray;
begin
  Lines := TStringList.Create;
  try
    if FileExists(ClientsFile) then
      Lines.LoadFromFile(ClientsFile);
    for I := Lines.Count - 1 downto 0 do
    begin
      F := Fields(Lines[I]);
      if (Length(F) = 0) or (F[0] = AName) then
        Lines.Delete(I);
    end;
    Lines.Add(AName + #9 + AToken + #9 + AExe);
    Lines.SaveToFile(ClientsFile);
    {$IFDEF UNIX}
    FpChmod(ClientsFile, &600);
    {$ENDIF}
    { Windows: the configuration folder is in the user's profile (or next
      to a portable doublecmd.exe), protected like the rest of it. }
  finally
    Lines.Free;
  end;
end;

{ ---- the programs' own commands (SET COMMANDS) ---- }

{ remotecommands.txt: <program> TAB <name> TAB <caption> per line. A
  program's lines are replaced as a whole; written only when they change. }
procedure RememberCommands(const AClient: String; const AFields: TStringArray);
var
  Lines, Mine: TStringList;
  I, P: Integer;
  F: TStringArray;
  Name, Caption, FileName: String;
begin
  FileName := gpCfgDir + CommandsFileName;
  Lines := TStringList.Create;
  Mine := TStringList.Create;
  try
    { AFields[0..1] = SET COMMANDS. }
    for I := 2 to High(AFields) do
    begin
      if Mine.Count >= MaxCommands then
        Break;
      P := Pos('=', AFields[I]);
      if P > 0 then
      begin
        Name := Trim(Copy(AFields[I], 1, P - 1));
        Caption := Trim(Copy(AFields[I], P + 1, MaxInt));
      end
      else
      begin
        Name := Trim(AFields[I]);
        Caption := '';
      end;
      if Name <> '' then
        Mine.Add(AClient + #9 + Name + #9 + Caption);
    end;
    if FileExists(FileName) then
      Lines.LoadFromFile(FileName);
    { Unchanged: not written again. }
    P := 0;
    for I := 0 to Lines.Count - 1 do
    begin
      F := Fields(Lines[I]);
      if (Length(F) > 0) and (F[0] = AClient) then
      begin
        if (P >= Mine.Count) or (Lines[I] <> Mine[P]) then
        begin
          P := -1;
          Break;
        end;
        Inc(P);
      end;
    end;
    if P = Mine.Count then
      Exit;
    for I := Lines.Count - 1 downto 0 do
    begin
      F := Fields(Lines[I]);
      if (Length(F) = 0) or (F[0] = AClient) then
        Lines.Delete(I);
    end;
    Lines.AddStrings(Mine);
    Lines.SaveToFile(FileName);
  finally
    Mine.Free;
    Lines.Free;
  end;
end;

procedure RemoteClientCommands(AList: TStrings);
var
  Lines: TStringList;
  I: Integer;
  F: TStringArray;
begin
  AList.Clear;
  if not FileExists(gpCfgDir + CommandsFileName) then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(gpCfgDir + CommandsFileName);
    except
      Exit;
    end;
    for I := 0 to Lines.Count - 1 do
    begin
      F := Fields(Lines[I]);
      if (Length(F) >= 2) and (F[1] <> '') then
        if Length(F) >= 3 then
          AList.Add(F[1] + '=' + F[2])
        else
          AList.Add(F[1] + '=');
    end;
  finally
    Lines.Free;
  end;
end;

{ ---- the server: transport (Unix) ---- }

{$IFDEF UNIX}
constructor TRemoteServer.Create(ASocket: cint; const AFileName: String);
begin
  inherited Create;
  FSocket := ASocket;
  FFileName := AFileName;
  FClients := TList.Create;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := PollMs;
  FStartMs := GetTickCount64;
  FDenied := TStringList.Create;
  FTimer.OnTimer := @HandleTimer;
  FTimer.Enabled := True;
end;

destructor TRemoteServer.Destroy;
var
  I: Integer;
begin
  FTimer.Free;
  for I := 0 to FClients.Count - 1 do
  begin
    CloseClient(TRemoteClient(FClients[I]));
    TRemoteClient(FClients[I]).Free;
  end;
  FClients.Free;
  FDenied.Free;
  CloseSocket(FSocket);
  DeleteFile(FFileName);
  inherited Destroy;
end;

procedure TRemoteServer.AcceptClients;
var
  C: cint;
  Client: TRemoteClient;
begin
  repeat
    C := fpAccept(FSocket, nil, nil);
    if C >= 0 then
    begin
      if not SameUser(C) then
        CloseSocket(C)
      else
      begin
        NoInherit(C);
        FpFcntl(C, F_SETFL, FpFcntl(C, F_GETFL) or O_NONBLOCK);
        Client := TRemoteClient.Create;
        Client.Socket := C;
        Client.ExePath := PeerExe(C);
        FClients.Add(Client);
      end;
    end;
  until C < 0;
end;

procedure TRemoteServer.ReadAvailable(AClient: TRemoteClient);
var
  Buffer: array[0..4095] of Char;
  Got: ssize_t;
  Err: cint;
  S: String;
begin
  repeat
    Got := fpRecv(AClient.Socket, @Buffer[0], SizeOf(Buffer), 0);
    if Got > 0 then
    begin
      SetString(S, PChar(@Buffer[0]), Got);
      AClient.Input := AClient.Input + S;
    end
    else if Got = 0 then
    begin
      AClient.Closed := True;    { the other side closed }
      Exit;
    end
    else
    begin
      Err := fpGetErrno;
      if Err = ESysEINTR then
        Continue;
      if (Err <> ESysEAGAIN) and (Err <> ESysEWOULDBLOCK) then
        AClient.Closed := True;
      Exit;
    end;
  until False;
end;

{ Sends what is waiting; a full socket (a long TREE event, a client that
  reads slowly): the rest stays for the next round, so Double Commander
  never waits and never sends half a line followed by the next one. }
procedure TRemoteServer.Flush(AClient: TRemoteClient);
var
  Sent: ssize_t;
  Err: cint;
begin
  while (AClient.Output <> '') and not AClient.Closed do
  begin
    Sent := fpSend(AClient.Socket, @AClient.Output[1], Length(AClient.Output), RC_MSG_NOSIGNAL);
    if Sent > 0 then
      Delete(AClient.Output, 1, Sent)
    else
    begin
      Err := fpGetErrno;
      if Err = ESysEINTR then
        Continue;
      if (Err <> ESysEAGAIN) and (Err <> ESysEWOULDBLOCK) then
        AClient.Closed := True;  { EPIPE: the program has gone }
      Exit;
    end;
  end;
end;

procedure TRemoteServer.SendLine(AClient: TRemoteClient; const ALine: String);
begin
  if (ALine = '') or AClient.Closed then
    Exit;
  AClient.Output := AClient.Output + ALine;
  if Length(AClient.Output) > MaxOutput then
  begin
    AClient.Closed := True;
    Exit;
  end;
  Flush(AClient);
end;

procedure TRemoteServer.CloseClient(AClient: TRemoteClient);
begin
  if AClient.Socket >= 0 then
    CloseSocket(AClient.Socket);
  AClient.Socket := -1;
  AClient.Output := '';
  AClient.Closed := True;
end;
{$ENDIF}

{ ---- the server: transport (Windows) ---- }

{$IFDEF MSWINDOWS}
constructor TRemoteServer.Create(const APipeName, ASddl: WideString);
begin
  inherited Create;
  FPipeName := APipeName;
  FSddl := ASddl;
  FListen := INVALID_HANDLE_VALUE;
  FillChar(FListenOvl, SizeOf(FListenOvl), 0);
  FListenOvl.hEvent := RC_CreateEventW(nil, True, False, nil);
  FClients := TList.Create;
  FTimer := TTimer.Create(nil);
  FTimer.Interval := PollMs;
  FStartMs := GetTickCount64;
  FDenied := TStringList.Create;
  FTimer.OnTimer := @HandleTimer;
  FTimer.Enabled := False;
end;

function TRemoteServer.Start: Boolean;
begin
  Result := (FListenOvl.hEvent <> 0) and Listen(True);
  FTimer.Enabled := Result;
end;

destructor TRemoteServer.Destroy;
var
  I: Integer;
begin
  FTimer.Free;
  for I := 0 to FClients.Count - 1 do
  begin
    CloseClient(TRemoteClient(FClients[I]));
    TRemoteClient(FClients[I]).Free;
  end;
  FClients.Free;
  FDenied.Free;
  if FListen <> INVALID_HANDLE_VALUE then
  begin
    RC_CancelIo(FListen);
    RC_CloseHandle(FListen);
  end;
  if FListenOvl.hEvent <> 0 then
    RC_CloseHandle(FListenOvl.hEvent);
  inherited Destroy;
end;

{ A pipe instance only the current user may open, local clients only. }
function TRemoteServer.MakePipeInstance(AFirst: Boolean): THandle;
var
  SD: Pointer;
  SA: TRCSecurityAttributes;
  OpenMode: DWORD;
begin
  Result := INVALID_HANDLE_VALUE;
  SD := nil;
  if not RC_ConvertStringSDToSDW(PWideChar(FSddl), RC_SDDL_REVISION_1, @SD, nil) then
    Exit;
  try
    SA.nLength := SizeOf(SA);
    SA.lpSecurityDescriptor := SD;
    SA.bInheritHandle := False;
    OpenMode := RC_PIPE_ACCESS_DUPLEX or RC_FILE_FLAG_OVERLAPPED;
    if AFirst then
      OpenMode := OpenMode or RC_FILE_FLAG_FIRST_PIPE_INSTANCE;
    Result := RC_CreateNamedPipeW(PWideChar(FPipeName), OpenMode,
      RC_PIPE_TYPE_BYTE or RC_PIPE_READMODE_BYTE or RC_PIPE_WAIT or RC_PIPE_REJECT_REMOTE_CLIENTS,
      RC_PIPE_UNLIMITED_INSTANCES, PipeBufferSize, PipeBufferSize, 0, @SA);
  finally
    RC_LocalFree(SD);
  end;
end;

{ A fresh instance waits (overlapped) for the next client. }
function TRemoteServer.Listen(AFirst: Boolean): Boolean;
var
  Err: DWORD;
begin
  Result := False;
  FListenConnected := False;
  FListen := MakePipeInstance(AFirst);
  if FListen = INVALID_HANDLE_VALUE then
    Exit;
  if RC_ConnectNamedPipe(FListen, @FListenOvl) then
    FListenConnected := True        { overlapped: not expected, but fine }
  else
  begin
    Err := RC_GetLastError;
    if Err = RC_ERROR_PIPE_CONNECTED then
      FListenConnected := True      { the client was quicker than us }
    else if Err <> RC_ERROR_IO_PENDING then
    begin
      RC_CloseHandle(FListen);
      FListen := INVALID_HANDLE_VALUE;
      Exit;
    end;
  end;
  Result := True;
end;

procedure TRemoteServer.AcceptClients;
var
  Client: TRemoteClient;
  N: DWORD;
begin
  { A lost listening instance (an error earlier) is made again. }
  if FListen = INVALID_HANDLE_VALUE then
    if not Listen(False) then
      Exit;
  while FListenConnected
    or ((RC_WaitForSingleObject(FListenOvl.hEvent, 0) = RC_WAIT_OBJECT_0)
        and RC_GetOverlappedResult(FListen, @FListenOvl, @N, False)) do
  begin
    Client := TRemoteClient.Create;
    Client.Pipe := FListen;
    Client.ExePath := PeerExe(FListen);
    FillChar(Client.Ovl, SizeOf(Client.Ovl), 0);
    Client.Ovl.hEvent := RC_CreateEventW(nil, True, False, nil);
    FClients.Add(Client);
    FListen := INVALID_HANDLE_VALUE;
    if not Listen(False) then
      Exit;
  end;
end;

procedure TRemoteServer.ReadAvailable(AClient: TRemoteClient);
var
  Buffer: array[0..4095] of Char;
  Avail, Got: DWORD;
  Want: DWORD;
begin
  repeat
    Avail := 0;
    if not RC_PeekNamedPipe(AClient.Pipe, nil, 0, nil, @Avail, nil) then
    begin
      AClient.Closed := True;       { the other side has gone }
      Exit;
    end;
    if Avail = 0 then
      Exit;
    Want := Avail;
    if Want > SizeOf(Buffer) then
      Want := SizeOf(Buffer);
    Got := 0;
    if not RC_ReadFile(AClient.Pipe, @Buffer[0], Want, nil, @AClient.Ovl) then
      if RC_GetLastError <> RC_ERROR_IO_PENDING then
      begin
        AClient.Closed := True;
        Exit;
      end;
    { The bytes are there (peeked): this does not wait for long. }
    if not RC_GetOverlappedResult(AClient.Pipe, @AClient.Ovl, @Got, True) or (Got = 0) then
    begin
      AClient.Closed := True;
      Exit;
    end;
    AClient.Input := AClient.Input + Copy(Buffer, 0, Got);
  until Length(AClient.Input) > MaxLine;
end;

procedure TRemoteServer.SendLine(AClient: TRemoteClient; const ALine: String);
var
  N: DWORD;
begin
  if (Length(ALine) = 0) or AClient.Closed then
    Exit;
  if not RC_WriteFile(AClient.Pipe, @ALine[1], Length(ALine), nil, @AClient.Ovl) then
    if RC_GetLastError <> RC_ERROR_IO_PENDING then
    begin
      AClient.Closed := True;
      Exit;
    end;
  { A client that doesn't read its answers is dropped rather than letting
    it hang Double Commander. }
  if RC_WaitForSingleObject(AClient.Ovl.hEvent, WriteWaitMs) <> RC_WAIT_OBJECT_0 then
  begin
    RC_CancelIo(AClient.Pipe);
    AClient.Closed := True;
    Exit;
  end;
  if not RC_GetOverlappedResult(AClient.Pipe, @AClient.Ovl, @N, False) then
    AClient.Closed := True;
end;

procedure TRemoteServer.CloseClient(AClient: TRemoteClient);
begin
  if AClient.Pipe <> INVALID_HANDLE_VALUE then
  begin
    RC_CancelIo(AClient.Pipe);
    RC_DisconnectNamedPipe(AClient.Pipe);
    RC_CloseHandle(AClient.Pipe);
  end;
  AClient.Pipe := INVALID_HANDLE_VALUE;
  if AClient.Ovl.hEvent <> 0 then
    RC_CloseHandle(AClient.Ovl.hEvent);
  AClient.Ovl.hEvent := 0;
  AClient.Closed := True;
end;
{$ENDIF}

{ ---- the server: common ---- }

function TRemoteServer.Broadcast(const AEvent: String): Integer;
var
  I: Integer;
  Client: TRemoteClient;
begin
  Result := 0;
  for I := 0 to FClients.Count - 1 do
  begin
    Client := TRemoteClient(FClients[I]);
    if Client.Closed or not Client.Allowed then
      Continue;
    if Client.Events = nil then
      Client.Events := TStringList.Create;
    while Client.Events.Count >= MaxEvents do
      Client.Events.Delete(0);
    Client.Events.Add(AEvent);
    Inc(Result);
  end;
end;

{ R: the whole window, frame included (what the client sees on screen).
  Windows: the LCL's form size leaves the frame, caption and menu out, so
  SetBounds made the window that much larger (right and bottom off the
  screen); the window itself is placed instead, and the LCL takes over its
  new size from Windows.
  Linux (X11 / XWayland): the window manager adds its title bar to the size
  set, so the window reached below the screen's bottom edge; the frame as
  it is now (the window rect less the form's size) is taken off. Not known
  before the window is shown: then nothing is taken off, and the pending
  place is applied again once it is (HandleTimer). }
procedure TRemoteServer.ApplyBounds(const R: TRect);
{$IFNDEF MSWINDOWS}
var
  WR: TRect;
  ExtraW, ExtraH: Integer;
{$ENDIF}
begin
  if frmMain.WindowState <> wsNormal then
    frmMain.WindowState := wsNormal;
  {$IFDEF MSWINDOWS}
  if frmMain.HandleAllocated then
  begin
    SetWindowPos(frmMain.Handle, 0, R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top,
      SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOOWNERZORDER);
    Exit;
  end;
  {$ENDIF}
  {$IFNDEF MSWINDOWS}
  ExtraW := 0;
  ExtraH := 0;
  if frmMain.HandleAllocated and frmMain.Visible
    and (LCLIntf.GetWindowRect(frmMain.Handle, WR) <> 0) then
  begin
    ExtraW := (WR.Right - WR.Left) - frmMain.Width;
    ExtraH := (WR.Bottom - WR.Top) - frmMain.Height;
    { Only a plausible frame (not a stale or unknown size). }
    if (ExtraW < 0) or (ExtraW > 100) then
      ExtraW := 0;
    if (ExtraH < 0) or (ExtraH > 150) then
      ExtraH := 0;
  end;
  frmMain.SetBounds(R.Left, R.Top, R.Right - R.Left - ExtraW, R.Bottom - R.Top - ExtraH);
  {$ELSE}
  frmMain.SetBounds(R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top);
  {$ENDIF}
end;

{ The whole window, frame included (the counterpart of ApplyBounds). }
function MainWindowRect: TRect;
{$IFDEF MSWINDOWS}
var
  WR: Windows.RECT;
{$ENDIF}
begin
  Result := frmMain.BoundsRect;
  {$IFDEF MSWINDOWS}
  if frmMain.HandleAllocated and GetWindowRect(frmMain.Handle, WR) then
    Result := Rect(WR.Left, WR.Top, WR.Right, WR.Bottom);
  {$ELSE}
  if frmMain.HandleAllocated and frmMain.Visible then
    LCLIntf.GetWindowRect(frmMain.Handle, Result);
  {$ENDIF}
end;

procedure TRemoteServer.HandleTimer(Sender: TObject);
var
  Client: TRemoteClient;
  I: Integer;
begin
  { A pairing question is open (modal): no new work meanwhile. }
  if FBusy then
    Exit;
  FBusy := True;
  try
    { A place asked for while starting: now that the window is shown
      (with its saved place, maybe maximized), it is put there again. }
    if FPending and frmMain.Visible then
    begin
      FPending := False;
      ApplyBounds(FPendingBounds);
      {$IFNDEF MSWINDOWS}
      FAgainLeft := 3;
      FAgainAt := GetTickCount64 + 250;
      {$ENDIF}
    end
    else if (FAgainLeft > 0) and not FPending and frmMain.Visible
      and (GetTickCount64 >= FAgainAt) then
    begin
      Dec(FAgainLeft);
      FAgainAt := GetTickCount64 + 250;
      ApplyBounds(FPendingBounds);
    end;
    AcceptClients;
    for I := FClients.Count - 1 downto 0 do
    begin
      Client := TRemoteClient(FClients[I]);
      {$IFDEF UNIX}
      Flush(Client);             { what didn't fit last time first }
      {$ENDIF}
      Serve(Client);
      if Client.Closed then
      begin
        CloseClient(Client);
        FClients.Delete(I);
        Client.Free;
      end;
    end;
  finally
    FBusy := False;
  end;
end;

{ Reads what has arrived, answers every complete line; the other side
  closing (or an error) ends the client. }
procedure TRemoteServer.Serve(AClient: TRemoteClient);
var
  P: Integer;
  Line, Reply: String;
begin
  ReadAvailable(AClient);
  if Length(AClient.Input) > MaxLine then
    AClient.Closed := True;
  if AClient.Closed then
    Exit;
  repeat
    P := Pos(#10, AClient.Input);
    if P = 0 then
      Break;
    Line := Copy(AClient.Input, 1, P - 1);
    Delete(AClient.Input, 1, P);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    try
      Reply := Answer(AClient, Line);
    except
      on E: Exception do
        Reply := 'ERR' + #9 + E.Message;
    end;
    SendLine(AClient, Reply + #10);
  until AClient.Closed;
end;

function TRemoteServer.Answer(AClient: TRemoteClient; const ALine: String): String;
var
  F, Params: TStringArray;
  View: TFileView;
  AFile: TFile;
  Token, Path: String;
  I: Integer;
  R: TRect;
  Sortings: TFileSortings;
begin
  F := Fields(ALine);
  if Length(F) = 0 then
    Exit('ERR' + #9 + 'empty');

  if SameText(F[0], 'HELLO') then
  begin
    if (Length(F) < 2) or (Trim(F[1]) = '') then
      Exit('ERR' + #9 + 'name missing');
    AClient.Name := Trim(F[1]);
    Token := '';
    if Length(F) >= 3 then
      Token := F[2];
    { Not on the allow list: turned away, no question. }
    if not NameAllowed(AClient.Name) then
      Exit('ERR' + #9 + 'not allowed');
    if KnownClient(AClient.Name, Token, AClient.ExePath, Token) then
      AClient.Allowed := True
    { Refused in this session already: not asked again. }
    else if FDenied.IndexOf(AClient.Name + #9 + AClient.ExePath) >= 0 then
      AClient.Allowed := False
    else
    begin
      Path := AClient.ExePath;
      if Path = '' then
        Path := '(program file not known)';
      if MessageDlg('Double Commander',
        Format('Allow "%s" to see what Double Commander shows and to change its folders and views?'
          + LineEnding + LineEnding + '%s', [AClient.Name, Path]),
        mtConfirmation, [mbYes, mbNo], 0) = mrYes then
      begin
        Token := NewToken;
        RememberClient(AClient.Name, Token, AClient.ExePath);
        AClient.Allowed := True;
      end
      else
        FDenied.Add(AClient.Name + #9 + AClient.ExePath);
    end;
    if AClient.Allowed then
      Exit('OK' + #9 + Token);
    Exit('ERR' + #9 + 'denied');
  end;

  if not AClient.Allowed then
    Exit('ERR' + #9 + 'say HELLO first');

  if SameText(F[0], 'GET') and (Length(F) >= 2) then
  begin
    if SameText(F[1], 'ACTIVE') then
    begin
      if frmMain.ActiveFrame = frmMain.FrameLeft then
        Exit('OK' + #9 + 'left');
      Exit('OK' + #9 + 'right');
    end;
    if SameText(F[1], 'UPTIME') then
      Exit('OK' + #9 + IntToStr(GetTickCount64 - FStartMs));
    if SameText(F[1], 'EVENT') then
    begin
      if Assigned(AClient.Events) and (AClient.Events.Count > 0) then
      begin
        Result := 'OK' + #9 + AClient.Events[0];
        AClient.Events.Delete(0);
        Exit;
      end;
      Exit('OK');
    end;
    if SameText(F[1], 'WINDOW') then
    begin
      R := MainWindowRect;
      if frmMain.Visible and (frmMain.WindowState <> wsMinimized) then
        Path := 'shown'
      else
        Path := 'hidden';
      Exit(Format('OK'#9'%d'#9'%d'#9'%d'#9'%d'#9'%s',
        [R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top, Path]));
    end;
    Path := '';
    if Length(F) >= 3 then
      Path := F[2];
    if not PanelView(Path, View) then
      Exit('ERR' + #9 + 'panel: left, right, active or inactive');
    if SameText(F[1], 'PATH') then
    begin
      if OnFileSystem(View) then
        Exit('OK' + #9 + ExcludeTrailingPathDelimiter(View.CurrentPath) + #9 + 'filesystem');
      Exit('OK' + #9 + View.CurrentPath + #9 + 'other');
    end;
    { PATH and CURSOR in one (Day 40: a follower asks once, not twice). }
    if SameText(F[1], 'FOLLOW') then
    begin
      if not OnFileSystem(View) then
        Exit('OK' + #9 + View.CurrentPath + #9 + 'other' + #9);
      Result := 'OK' + #9 + ExcludeTrailingPathDelimiter(View.CurrentPath) + #9 + 'filesystem' + #9;
      AFile := View.CloneActiveFile;
      try
        if Assigned(AFile) and AFile.IsNameValid then
          Result := Result + ExcludeTrailingPathDelimiter(AFile.FullPath);
      finally
        AFile.Free;
      end;
      Exit;
    end;
    if SameText(F[1], 'CURSOR') then
    begin
      Result := 'OK' + #9;
      if not OnFileSystem(View) then
        Exit;
      AFile := View.CloneActiveFile;
      try
        { A folder too (a caller may preview it); ".." is not a name. }
        if Assigned(AFile) and AFile.IsNameValid then
          Result := Result + ExcludeTrailingPathDelimiter(AFile.FullPath);
      finally
        AFile.Free;
      end;
      Exit;
    end;
    if SameText(F[1], 'VIEW') then
    begin
      if View.ClassNameIs('TThumbFileView') then
        Exit('OK' + #9 + 'thumbnails');
      if View.ClassNameIs('TBriefFileView') then
        Exit('OK' + #9 + 'brief');
      Exit('OK' + #9 + 'columns');
    end;
    Exit('ERR' + #9 + 'unknown question');
  end;

  { The file VersariteViewer shows, under the panel's cursor (another
    folder: the panel goes there first). }
  if SameText(F[0], 'SET') and (Length(F) >= 4) and SameText(F[1], 'CURSOR') then
  begin
    if not PanelView(F[2], View) then
      Exit('ERR' + #9 + 'panel: left, right, active or inactive');
    if not OnFileSystem(View) then
      Exit('ERR' + #9 + 'not on the file system');
    Path := F[3];
    if SameExe(ExcludeTrailingPathDelimiter(ExtractFilePath(Path)),
      ExcludeTrailingPathDelimiter(View.CurrentPath)) then
      View.SetActiveFile(ExtractFileName(Path))
    else if FileExists(Path) then
      View.ChangePathAndSetActiveFile(Path)
    else
      Exit('ERR' + #9 + 'not found');
    Exit('OK');
  end;

  { The program's own commands, for cm_ViewerCommand's parameter helper. }
  if SameText(F[0], 'SET') and (Length(F) >= 2) and SameText(F[1], 'COMMANDS') then
  begin
    RememberCommands(AClient.Name, F);
    Exit('OK');
  end;

  if SameText(F[0], 'SET') and (Length(F) >= 5) and SameText(F[1], 'SORT') then
  begin
    if not PanelView(F[2], View) then
      Exit('ERR' + #9 + 'panel: left, right, active or inactive');
    Sortings := nil;
    SetLength(Sortings, 1);
    SetLength(Sortings[0].SortFunctions, 1);
    if SameText(F[3], 'name') then
      Sortings[0].SortFunctions[0] := fsfName
    else if SameText(F[3], 'ext') then
      Sortings[0].SortFunctions[0] := fsfExtension
    else if SameText(F[3], 'size') then
      Sortings[0].SortFunctions[0] := fsfSize
    else if SameText(F[3], 'date') then
      Sortings[0].SortFunctions[0] := fsfModificationTime
    else
      Exit('ERR' + #9 + 'sort: name, ext, size or date');
    if SameText(F[4], 'desc') then
      Sortings[0].SortDirection := sdDescending
    else
      Sortings[0].SortDirection := sdAscending;
    View.Sorting := Sortings;
    Exit('OK');
  end;

  if SameText(F[0], 'SET') and (Length(F) >= 6) and SameText(F[1], 'WINDOW') then
  begin
    R := Rect(StrToInt(F[2]), StrToInt(F[3]), StrToInt(F[2]) + StrToInt(F[4]),
      StrToInt(F[3]) + StrToInt(F[5]));
    ApplyBounds(R);
    FPending := not frmMain.Visible;
    FPendingBounds := R;
    {$IFNDEF MSWINDOWS}
    FAgainLeft := 3;
    FAgainAt := GetTickCount64 + 250;
    {$ENDIF}
    Exit('OK');
  end;

  if SameText(F[0], 'CMD') and (Length(F) >= 2) then
  begin
    if not IsAllowedCommand(F[1]) then
      Exit('ERR' + #9 + 'not allowed');
    { cm_MakeDir only without its dialog: a path= is required. }
    if SameText(F[1], 'cm_MakeDir') then
    begin
      Path := '';
      for I := 2 to High(F) do
        if Pos('path=', LowerCase(F[I])) = 1 then
          Path := Copy(F[I], 6, MaxInt);
      if Path = '' then
        Exit('ERR' + #9 + 'cm_MakeDir needs path=');
    end;
    Params := nil;
    SetLength(Params, Length(F) - 2);
    for I := 2 to High(F) do
      Params[I - 2] := F[I];
    if frmMain.Commands.Commands.ExecuteCommand(F[1], Params) = cfrNotFound then
      Exit('ERR' + #9 + 'not found');
    Exit('OK');
  end;

  Result := 'ERR' + #9 + 'unknown request';
end;

{ ---- start / stop ---- }

{$IFDEF UNIX}
procedure StartRemoteControl;
var
  S: cint;
  Addr: TUnixSockAddr;
  Name: String;
begin
  if Assigned(Server) or not gRemoteControl then
    Exit;
  Name := RemoteControlSocketName;
  if Length(Name) >= SizeOf(Addr.path) then
    Exit;
  { A file left by a crashed Double Commander; a running one is not
    disturbed: binding fails below only if the name is taken and live. }
  S := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if S < 0 then
    Exit;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.family := AF_UNIX;
  Move(Name[1], Addr.path[0], Length(Name));
  if fpConnect(S, @Addr, SizeOf(Addr)) = 0 then
  begin
    CloseSocket(S);          { another instance serves already }
    Exit;
  end;
  CloseSocket(S);
  DeleteFile(Name);
  S := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if S < 0 then
    Exit;
  NoInherit(S);
  if (fpBind(S, @Addr, SizeOf(Addr)) <> 0) or (fpListen(S, 8) <> 0) then
  begin
    CloseSocket(S);
    Exit;
  end;
  FpChmod(Name, &600);
  FpFcntl(S, F_SETFL, FpFcntl(S, F_GETFL) or O_NONBLOCK);
  Server := TRemoteServer.Create(S, Name);
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
procedure StartRemoteControl;
var
  Sid: String;
begin
  if Assigned(Server) or not gRemoteControl then
    Exit;
  Sid := UserSidString;
  if Sid = '' then
    Exit;
  { Protected (P: no inherited entries), one entry: full access for this
    user. Everyone else, other users and anonymous logons included, can't
    open the pipe at all. }
  Server := TRemoteServer.Create(UTF8Decode(PipePrefix + Sid),
    UTF8Decode('D:P(A;;GA;;;' + Sid + ')'));
  if not Server.Start then
    FreeAndNil(Server);      { another instance serves already }
end;
{$ENDIF}

procedure StopRemoteControl;
begin
  FreeAndNil(Server);
end;

procedure RemoteSendTree;
var
  View: TFileView;
  Folder, Line: String;
  Subs: TStringList;
  SR: TSearchRec;
  I, Sent: Integer;
begin
  if not Assigned(Server) then
  begin
    MessageDlg('Double Commander', 'Send tree: the remote control is off '
      + '(<RemoteControl>True</RemoteControl> in doublecmd.xml).', mtInformation, [mbOK], 0);
    Exit;
  end;
  View := frmMain.ActiveFrame;
  if not Assigned(View) or not OnFileSystem(View) then
  begin
    MessageDlg('Double Commander', 'Send tree: only for a folder on the file system.',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  Folder := View.CurrentPath;
  Subs := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Folder) + AllFilesMask, faAnyFile, SR) = 0 then
    try
      repeat
        if ((SR.Attr and faDirectory) = 0) or (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        { Hidden / system folders only when Double Commander shows them. }
        if ((SR.Attr and (faHidden or faSysFile)) <> 0) and not gShowSystemFiles then
          Continue;
        if (Pos(#9, SR.Name) > 0) or (Pos(#10, SR.Name) > 0) then
          Continue;
        Subs.Add(IncludeTrailingPathDelimiter(Folder) + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    if Subs.Count = 0 then
    begin
      MessageDlg('Double Commander', 'Send tree: ' + Folder + ' has no subfolders.',
        mtInformation, [mbOK], 0);
      Exit;
    end;
    Subs.Sort;
    Line := 'TREE' + #9 + ExcludeTrailingPathDelimiter(Folder);
    for I := 0 to Subs.Count - 1 do
      Line := Line + #9 + Subs[I];
    Sent := Server.Broadcast(Line);
    if Sent = 0 then
      MessageDlg('Double Commander', 'Send tree: no program is connected to the remote control.',
        mtInformation, [mbOK], 0);
  finally
    Subs.Free;
  end;
end;

procedure RemoteViewerFollow(const AMode: String);
begin
  if not Assigned(Server) then
  begin
    MessageDlg('Double Commander', 'Viewer follow mode: the remote control is off '
      + '(<RemoteControl>True</RemoteControl> in doublecmd.xml).', mtInformation, [mbOK], 0);
    Exit;
  end;
  if Server.Broadcast('FOLLOW' + #9 + AMode) = 0 then
    MessageDlg('Double Commander', 'Viewer follow mode: no viewer is connected to the remote control.',
      mtInformation, [mbOK], 0);
end;

procedure RemoteViewerCommand(const AName: String);
begin
  if (AName = '') or (Pos(#9, AName) > 0) or (Pos(#10, AName) > 0) then
  begin
    MessageDlg('Double Commander', 'Viewer command: give the command''s name as the parameter, '
      + 'e.g. cmd=SlideShow.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if not Assigned(Server) then
  begin
    MessageDlg('Double Commander', 'Viewer command: the remote control is off '
      + '(<RemoteControl>True</RemoteControl> in doublecmd.xml).', mtInformation, [mbOK], 0);
    Exit;
  end;
  if Server.Broadcast('COMMAND' + #9 + AName) = 0 then
    MessageDlg('Double Commander', 'Viewer command: no viewer is connected to the remote control.',
      mtInformation, [mbOK], 0);
end;

{$ELSE}

{ Other systems: no remote control. }

procedure StartRemoteControl;
begin
end;

procedure StopRemoteControl;
begin
end;

function RemoteControlSocketName: String;
begin
  Result := '';
end;

procedure RemoteSendTree;
begin
end;

procedure RemoteViewerFollow(const AMode: String);
begin
end;

procedure RemoteViewerCommand(const AName: String);
begin
end;

procedure RemoteClientCommands(AList: TStrings);
begin
  AList.Clear;
end;

{$ENDIF}

end.

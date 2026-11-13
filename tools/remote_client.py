#!/usr/bin/env python3
"""Test client for Double Commander's remote control channel.

Connects to the running Double Commander of the current user (Unix: the
domain socket, Windows: the named pipe), says HELLO (Double Commander
asks once whether to allow it; the token is kept in a file next to this
script), then sends requests.

    python3 remote_client.py                      interactive prompt
    python3 remote_client.py "GET FOLLOW active" "GET VIEW left"
    python3 remote_client.py --events             print events as they come

A request is written with spaces; quote a field that contains spaces:

    SET CURSOR active "/home/me/My Pictures/a.jpg"
    CMD cm_ChangeDir "activepath=/tmp"

Requires Python 3.8+, nothing else. Remote control must be on:
<RemoteControl>True</RemoteControl> under <Behaviours> in doublecmd.xml.
"""

import argparse
import os
import shlex
import socket
import subprocess
import sys
import time

TOKEN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.remote_client_token')


def channel_path():
    if sys.platform == 'win32':
        out = subprocess.run(['whoami', '/user', '/fo', 'csv', '/nh'],
                             capture_output=True, text=True, check=True).stdout
        sid = out.strip().split(',')[-1].strip('"')
        return r'\\.\pipe\doublecmd-remote-' + sid
    runtime = os.environ.get('XDG_RUNTIME_DIR', '')
    if runtime and os.path.isdir(runtime):
        return os.path.join(runtime, 'doublecmd-remote')
    return '/tmp/doublecmd-%d/doublecmd-remote' % os.getuid()


class Channel:
    def __init__(self, path):
        if sys.platform == 'win32':
            # The pipe as a file: one request, one answer line.
            self.f = open(path, 'r+b', buffering=0)
            self.sock = None
        else:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.connect(path)
            self.f = self.sock.makefile('rwb', buffering=0)

    def ask(self, fields):
        line = '\t'.join(fields) + '\n'
        self.f.write(line.encode('utf-8'))
        if hasattr(self.f, 'flush'):
            self.f.flush()
        answer = b''
        while not answer.endswith(b'\n'):
            chunk = self.f.read(1)
            if not chunk:
                raise ConnectionError('Double Commander closed the connection')
            answer += chunk
        return answer.decode('utf-8').rstrip('\r\n').split('\t')


def hello(ch, name):
    token = ''
    if os.path.exists(TOKEN_FILE):
        token = open(TOKEN_FILE, encoding='utf-8').read().strip()
    fields = ['HELLO', name] + ([token] if token else [])
    print('(if Double Commander asks whether to allow "%s", answer it there)' % name)
    answer = ch.ask(fields)
    if answer[0] != 'OK':
        sys.exit('refused: ' + ' '.join(answer[1:]))
    if len(answer) > 1 and answer[1] and answer[1] != token:
        with open(TOKEN_FILE, 'w', encoding='utf-8') as t:
            t.write(answer[1])
    print('connected')


def show(answer):
    print(' | '.join(answer))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('requests', nargs='*', help='requests to send, e.g. "GET PATH active"')
    p.add_argument('--name', default='RemoteTestClient',
                   help='the program name to announce (must be in remoteallow.txt if that file exists)')
    p.add_argument('--events', action='store_true', help='print events (GET EVENT twice a second)')
    a = p.parse_args()

    path = channel_path()
    try:
        ch = Channel(path)
    except OSError as e:
        sys.exit('cannot connect to %s: %s\n(is Double Commander running with RemoteControl on?)' % (path, e))
    hello(ch, a.name)

    if a.events:
        print('waiting for events (Ctrl+C ends) - try cm_SendTree or cm_ViewerCommand cmd=Test')
        try:
            while True:
                answer = ch.ask(['GET', 'EVENT'])
                if len(answer) > 1:
                    show(answer[1:])
                time.sleep(0.5)
        except KeyboardInterrupt:
            return

    if a.requests:
        for r in a.requests:
            t0 = time.perf_counter()
            answer = ch.ask(shlex.split(r))
            show(answer)
            print('  (%.1f ms)' % ((time.perf_counter() - t0) * 1000))
        return

    print('requests like: GET FOLLOW active | GET WINDOW | SET SORT active name asc | quit')
    while True:
        try:
            r = input('> ').strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not r:
            continue
        if r.lower() in ('quit', 'exit'):
            break
        show(ch.ask(shlex.split(r)))


if __name__ == '__main__':
    main()

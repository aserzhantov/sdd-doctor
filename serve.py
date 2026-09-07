#!/usr/bin/env python3
"""Локальный сервер для проверки правок.

    python3 serve.py          # http://localhost:8766
    python3 serve.py 9000     # другой порт

Зачем не `python3 -m http.server`: тот отдаёт файлы с Last-Modified и без
Cache-Control, поэтому браузер оставляет у себя старые assets/app.js
и assets/styles.css. Правишь файл, жмёшь F5 — и видишь прежнюю страницу,
причём молча: ошибок нет, просто «не применилось». На отладку такой
иллюзии уходит больше времени, чем на саму правку.

Здесь каждый ответ помечен no-store, поэтому браузер каждый раз берёт файл
заново. Только для локальной работы: в бою файлы отдаёт GitHub Pages.
"""
import functools
import http.server
import os
import socketserver
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store, max-age=0')
        super().end_headers()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8766
    socketserver.TCPServer.allow_reuse_address = True
    handler = functools.partial(NoCacheHandler, directory=ROOT)
    with socketserver.TCPServer(('', port), handler) as httpd:
        print(f'http://localhost:{port}/  (Ctrl+C — остановить)')
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print()


if __name__ == '__main__':
    main()

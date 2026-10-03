# Minimal range-request-capable HTTP server for offline e2e tests.
# (python's http.server ignores Range, which breaks yt-dlp/ffmpeg downloads.)
import http.server, socketserver, re, os, sys

class H(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return super().send_head()
        f = open(path, 'rb')
        size = os.path.getsize(path)
        rng = self.headers.get('Range')
        if rng:
            m = re.match(r'bytes=(\d*)-(\d*)', rng)
            start = int(m.group(1) or 0)
            end = int(m.group(2) or (size - 1))
            if end >= size: end = size - 1
            self.send_response(206)
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
            self.send_header('Content-Length', str(end - start + 1))
            self.send_header('Content-Type', self.guess_type(path))
            self.end_headers()
            f.seek(start)
            return f
        self.send_response(200)
        self.send_header('Content-Length', str(size))
        self.send_header('Content-Type', self.guess_type(path))
        self.end_headers()
        return f
    def log_message(self, *a):
        pass

httpd = http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H)
httpd.serve_forever()
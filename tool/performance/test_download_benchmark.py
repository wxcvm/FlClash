import http.server
import os
import tempfile
import threading
import unittest
from download_benchmark import measure, measure_upload, write_synthetic_payload


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(403 if self.path == '/error' else 200)
        self.end_headers()
        self.wfile.write(b'x' * 4096)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        content = self.rfile.read(length)
        self.server.last_upload_bytes = len(content)
        self.send_response(403 if self.path == '/error' else 201)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PUT(self):
        self.do_POST()

    def log_message(self, *args):
        pass


class BenchmarkTest(unittest.TestCase):
    def test_full_file_and_invalid_samples(self):
        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f'http://127.0.0.1:{server.server_port}'
                result = measure(url + '/file', None, 5, 4096)
                self.assertTrue(result['ok'])
                self.assertEqual(result['bytes'], 4096)
                self.assertGreater(result['bytes_per_second'], 0)
                self.assertFalse(measure(url + '/file', None, 5, 8192)['ok'])
                self.assertFalse(measure(url + '/error', None, 5, 4096)['ok'])
            finally:
                server.shutdown()
                thread.join()


    def test_upload_requires_accepted_full_body(self):
        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f'http://127.0.0.1:{server.server_port}'
                with tempfile.TemporaryDirectory() as tmp:
                    path = os.path.join(tmp, 'synthetic.bin')
                    write_synthetic_payload(path, 4096)
                    self.assertEqual(os.stat(path).st_size, 4096)
                    sent = measure_upload(url + '/upload', None, 5, path, 4096)
                    self.assertTrue(sent['ok'], sent)
                    self.assertEqual(server.last_upload_bytes, 4096)
                    self.assertGreater(sent['bytes_per_second'], 0)
                    self.assertTrue(measure_upload(url + '/upload', None, 5, path, 4096, 'PUT')['ok'])
                    self.assertFalse(measure_upload(url + '/upload', None, 5, path, 8192)['ok'])
                    self.assertFalse(measure_upload(url + '/error', None, 5, path, 4096)['ok'])
            finally:
                server.shutdown()
                thread.join()


if __name__ == '__main__':
    unittest.main()

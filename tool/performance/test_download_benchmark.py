import http.server
import threading
import unittest
from download_benchmark import measure


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(403 if self.path == '/error' else 200)
        self.end_headers()
        self.wfile.write(b'x' * 4096)

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


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Run the actual cache/decoder/limiter against disposable synthetic local images."""
from pathlib import Path
import http.server, json, os, struct, subprocess, threading, time, zlib, sys
root = Path(__file__).resolve().parents[1]
source = (root/'CivitViewer/MediaCache.swift').read_text()
shim = '''import AppKit
typealias UIImage = NSImage
extension NSImage {
    var scale: CGFloat { 1 }
    func jpegData(compressionQuality: CGFloat) -> Data? { tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) } }
    convenience init(cgImage: CGImage) { self.init(cgImage: cgImage, size: .zero) }
}'''
extracted = root/'build/ImageCacheUnderTest.swift'
extracted.parent.mkdir(exist_ok=True)
extracted.write_text(source.replace('import UIKit', shim, 1))
env = {**os.environ, 'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer'}
binary = root/'build/image-cache-checks'
subprocess.run(['xcrun','swiftc',str(root/'CivitViewer/VideoDuration.swift'),str(root/'CivitViewer/Models.swift'),str(root/'CivitViewer/MediaLoadQueue.swift'),str(root/'CivitViewer/MediaFormat.swift'),str(root/'CivitViewer/MediaRepairStore.swift'),str(root/'CivitViewer/PlaybackDiagnostics.swift'),str(root/'CivitViewer/LocalDiagnostics.swift'),str(extracted),str(root/'Tests/ImageCacheChecks.swift'),'-o',str(binary)],check=True,env=env)
def chunk(t, data):
    return struct.pack('!I',len(data))+t+data+struct.pack('!I',zlib.crc32(t+data)&0xffffffff)
png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',16,16,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+bytes((30,120,210))*16)*16))+chunk(b'IEND',b'')
lock=threading.Lock(); requests={}; active=0; maximum=0
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        global active,maximum
        if self.path=='/stats':
            with lock: data=json.dumps({'requests':requests,'maxActive':maximum}).encode()
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
        with lock:
            requests[self.path]=requests.get(self.path,0)+1; nth=requests[self.path];active+=1;maximum=max(maximum,active)
        try:
            time.sleep(0.7 if self.path.startswith('/block-') else 0.25)
            if self.path == '/large-video':
                # A small-prefetch flight must finish before the larger repair
                # request retries. Stream a representative 65MiB body, not RAM.
                size = 65 * 1024 * 1024
                self.send_response(200);self.send_header('Content-Type','video/mp4');self.send_header('Content-Length',str(size));self.end_headers()
                first=(root/'Tests/Fixtures/short.mp4').read_bytes()
                self.wfile.write(first);remaining=size-len(first);block=b'\0'*(256*1024)
                while remaining:
                    count=min(remaining,len(block));self.wfile.write(block[:count]);remaining-=count
                return
            if self.path in ('/redirect-image','/redirect-403'):
                self.send_response(302);self.send_header('Location','/video-header-image' if self.path=='/redirect-image' else '/http403');self.end_headers();return
            code=404 if self.path=='/http404' else 429 if self.path=='/http429' else 403 if self.path=='/http403' else 200
            fixtures = {'/video-poster':'short.mp4','/short-video':'short.mp4','/animated-gif':'animated.gif','/animated-webp':'animated.webp'}
            body=(root/'Tests/Fixtures'/fixtures[self.path]).read_bytes() if self.path in fixtures else b'<html>login needed</html>' if self.path=='/html-body' else b'{"error":"authentication"}' if self.path=='/json-body' else b'bad image' if self.path=='/recover' and nth==1 else png
            mime='video/mp4' if self.path in ('/video-poster','/video-header-image','/short-video') else 'text/plain' if self.path=='/mislabel-image' else None if self.path=='/no-type-image' else 'application/octet-stream' if self.path=='/octet-image' else 'image/png'
            self.send_response(code);
            if mime:self.send_header('Content-Type',mime)
            self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError):pass
        finally:
            with lock:active-=1
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
threading.Thread(target=server.serve_forever,daemon=True).start()
try:subprocess.run([str(binary),f'http://127.0.0.1:{server.server_port}',*sys.argv[1:]],check=True,env=env,timeout=60)
finally:server.shutdown();server.server_close()

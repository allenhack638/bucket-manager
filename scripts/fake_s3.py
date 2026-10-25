#!/usr/bin/env python3
"""Tiny S3-compatible server for the end-to-end tests.

It intentionally ignores signatures: the goal is to exercise the real AWS SDK
serialization/deserialization and the app's listing/metadata code, not auth.

Run: python3 scripts/fake_s3.py 0   # prints "LISTENING <port>"
Endpoints: /__stats, /__reset, /__last_put, /__health
"""
import base64
import http.server
import json
import os
import sys
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from email.utils import formatdate

STATS = {}
LAST_PUT = {"key": "", "size": 0}
LAST_DELETE = {"key": ""}
LIST_TIMES = []
ACTIVE_LIST = 0
MAX_ACTIVE_LIST = 0
MULTIPART = {}
OBJECTS = {}
FAILED_PARTS = set()
NEXT_UPLOAD = 0
MULTIPART_DELAY = float(os.environ.get("FAKE_MULTIPART_DELAY", "0"))
MULTIPART_STAGGER = os.environ.get("FAKE_MULTIPART_STAGGER", "0") == "1"
GET_DELAY = float(os.environ.get("FAKE_GET_DELAY", "0"))
LOCK = threading.Lock()
XMLNS = "http://s3.amazonaws.com/doc/2006-03-01/"
DATE = "2026-01-02T03:04:05.000Z"
HTTP_DATE = formatdate(time.time(), usegmt=True)
RESUME_DATA = bytes(i % 251 for i in range(2 * 1024 * 1024))
RESUME_ETAG = '"etag-resume"'


def decode_aws_chunked(body):
    """Decode the aws-chunked request body used by the AWS SDKs.

    Real S3 decodes this framing before storing the object. The fixture has to
    do the same or download tests see chunk signatures and trailers.
    """
    if not body:
        return body
    decoded = bytearray()
    position = 0
    try:
        while True:
            line_end = body.index(b"\r\n", position)
            size_line = body[position:line_end].split(b";", 1)[0]
            size = int(size_line, 16)
            position = line_end + 2
            if size == 0:
                return bytes(decoded)
            if position + size > len(body):
                return body
            decoded.extend(body[position:position + size])
            position += size
            if body[position:position + 2] != b"\r\n":
                return body
            position += 2
    except (ValueError, IndexError):
        return body


def read_request_body(handler):
    length = int(handler.headers.get("Content-Length", "0") or 0)
    body = handler.rfile.read(length) if length else b""
    content_sha = (handler.headers.get("x-amz-content-sha256") or "").upper()
    content_encoding = (handler.headers.get("Content-Encoding") or "").lower()
    if content_sha.startswith("STREAMING-") or "aws-chunked" in content_encoding:
        return decode_aws_chunked(body)
    return body


def bump(name):
    with LOCK:
        STATS[name] = STATS.get(name, 0) + 1


def xml_response(handler, body, status=200, content_type="application/xml"):
    data = body.encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def error_response(handler, code, message, status=403):
    xml_response(
        handler,
        f'<?xml version="1.0" encoding="UTF-8"?><Error><Code>{code}</Code>'
        f"<Message>{message}</Message><RequestId>e2e</RequestId></Error>",
        status=status,
    )


def contents_xml(rows):
    out = []
    for key, size in rows:
        out.append(
            "<Contents>"
            f"<Key>{key}</Key><LastModified>{DATE}</LastModified>"
            '<ETag>&quot;etag1&quot;</ETag>'
            f"<Size>{size}</Size><StorageClass>STANDARD</StorageClass>"
            "</Contents>"
        )
    return "".join(out)


def prefixes_xml(prefixes):
    return "".join(f"<CommonPrefixes><Prefix>{p}</Prefix></CommonPrefixes>" for p in prefixes)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def split(self):
        parsed = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(parsed.path)
        parts = path.lstrip("/").split("/", 1)
        bucket = parts[0] if parts and parts[0] else None
        key = parts[1] if len(parts) > 1 else ""
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        return bucket, key, query

    def do_GET(self):
        global MAX_ACTIVE_LIST
        bucket, key, query = self.split()
        if bucket is None:
            bump("listBuckets")
            buckets = "".join(
                f"<Bucket><Name>{name}</Name><CreationDate>{DATE}</CreationDate></Bucket>"
                for name in ["alpha", "beta", "denied", "fast", "slow"]
            )
            return xml_response(
                self,
                f'<?xml version="1.0" encoding="UTF-8"?><ListAllMyBucketsResult xmlns="{XMLNS}">'
                "<Owner><ID>e2e</ID><DisplayName>e2e</DisplayName></Owner>"
                f"<Buckets>{buckets}</Buckets></ListAllMyBucketsResult>",
            )
        if bucket == "__stats":
            with LOCK:
                body = json.dumps(STATS)
            return xml_response(self, body, content_type="application/json")
        if bucket == "__seed_multipart":
            upload_id = query.get("id", ["orphan-upload"])[0]
            with LOCK:
                MULTIPART[upload_id] = {
                    "bucket": query.get("bucket", ["alpha"])[0],
                    "key": query.get("key", ["orphan.bin"])[0],
                    "content_type": "application/octet-stream",
                    "parts": {},
                }
            return xml_response(self, '{"seeded": true}', content_type="application/json")
        if bucket == "__objects":
            with LOCK:
                body = json.dumps({k: len(v["body"]) for k, v in OBJECTS.items()})
            return xml_response(self, body, content_type="application/json")
        if bucket == "__reset":
            with LOCK:
                STATS.clear()
                LAST_PUT.update(key="", size=0)
                LAST_DELETE.update(key="")
                LIST_TIMES.clear()
                MAX_ACTIVE_LIST = 0
                MULTIPART.clear()
                OBJECTS.clear()
                FAILED_PARTS.clear()
            return xml_response(self, "{}", content_type="application/json")
        if bucket == "__last_put":
            with LOCK:
                body = json.dumps(LAST_PUT)
            return xml_response(self, body, content_type="application/json")
        if bucket == "__last_delete":
            with LOCK:
                body = json.dumps(LAST_DELETE)
            return xml_response(self, body, content_type="application/json")
        if bucket == "__times":
            with LOCK:
                body = json.dumps({"times": LIST_TIMES, "max_active": MAX_ACTIVE_LIST})
            return xml_response(self, body, content_type="application/json")
        if bucket == "__health":
            return xml_response(self, "ok", content_type="text/plain")
        if "list-type" in query:
            return self.list_objects(bucket, query)
        if "versions" in query:
            return self.list_versions(bucket, key, query)
        if "tagging" in query:
            bump("tags")
            return xml_response(
                self,
                f'<?xml version="1.0" encoding="UTF-8"?><Tagging xmlns="{XMLNS}"><TagSet>'
                "<Tag><Key>team</Key><Value>design</Value></Tag>"
                "<Tag><Key>stage</Key><Value>e2e</Value></Tag>"
                "</TagSet></Tagging>",
            )
        if "acl" in query:
            bump("acl")
            return xml_response(
                self,
                f'<?xml version="1.0" encoding="UTF-8"?><AccessControlPolicy xmlns="{XMLNS}">'
                "<Owner><ID>owner</ID><DisplayName>owner</DisplayName></Owner>"
                "<AccessControlList><Grant>"
                '<Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
                'xsi:type="CanonicalUser"><ID>owner</ID><DisplayName>owner</DisplayName></Grantee>'
                "<Permission>FULL_CONTROL</Permission>"
                "</Grant></AccessControlList></AccessControlPolicy>",
            )
        if bucket == "denied":
            bump("denied")
            return error_response(self, "AccessDenied", "Access Denied")
        with LOCK:
            stored = OBJECTS.get(key)
        if stored:
            if key.startswith("slowcopy/") or GET_DELAY:
                time.sleep(GET_DELAY or 0.5)
            bump("getObject")
            body = stored["body"]
            self.send_response(200)
            self.send_header("Content-Type", stored["content_type"])
            self.send_header("Content-Length", str(len(body)))
            self.send_header("ETag", '"etag-multipart"')
            self.send_header("Last-Modified", HTTP_DATE)
            self.end_headers()
            self.wfile.write(body)
            return
        bump("getObject")
        if key == "resume.bin":
            if_match = self.headers.get("If-Match")
            if if_match and if_match != RESUME_ETAG:
                bump("precondition")
                return error_response(self, "PreconditionFailed", "ETag changed", status=412)
            range_header = self.headers.get("Range", "")
            if range_header.startswith("bytes="):
                start = int(range_header.split("=", 1)[1].split("-", 1)[0])
                start = max(0, min(start, len(RESUME_DATA)))
                body = RESUME_DATA[start:]
                bump("rangeRequests")
                self.send_response(206)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Content-Range", f"bytes {start}-{len(RESUME_DATA) - 1}/{len(RESUME_DATA)}")
                self.send_header("ETag", RESUME_ETAG)
                self.send_header("Last-Modified", HTTP_DATE)
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(RESUME_DATA)))
            self.send_header("ETag", RESUME_ETAG)
            self.send_header("Last-Modified", HTTP_DATE)
            self.end_headers()
            self.wfile.write(RESUME_DATA)
            return
        content_type = "text/plain"
        if key == "readme.txt":
            body = b"hello from fake s3"
        elif key == "photos/a.jpg":
            body = base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2n1kAAAAASUVORK5CYII="
            )
            content_type = "image/png"
        else:
            body = f"body of {key}".encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", '"etag1"')
        self.send_header("Last-Modified", HTTP_DATE)
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        bucket, key, query = self.split()
        with LOCK:
            stored = OBJECTS.get(key)
        if stored:
            bump("head")
            content_length = len(stored["body"])
            if key.startswith("verify-fail/"):
                content_length += 1
            e_tag = '"head-etag"' if key.startswith("mutating/") else '"etag-multipart"'
            self.send_response(200)
            self.send_header("Content-Type", stored["content_type"])
            self.send_header("Content-Length", str(content_length))
            self.send_header("ETag", e_tag)
            self.send_header("Last-Modified", HTTP_DATE)
            self.end_headers()
            return
        if bucket != "alpha" or key != "readme.txt":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        bump("head")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "12")
        self.send_header("ETag", '"etag1"')
        self.send_header("Last-Modified", HTTP_DATE)
        self.send_header("x-amz-meta-owner", "e2e")
        self.send_header("x-amz-version-id", "v1")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

    def do_PUT(self):
        bucket, key, query = self.split()
        if bucket == "denied":
            bump("deniedPut")
            return error_response(self, "AccessDenied", "Access Denied", 403)
        body = read_request_body(self)
        upload_id = query.get("uploadId", [None])[0]
        part_number = query.get("partNumber", [None])[0]
        if upload_id and part_number:
            if MULTIPART_DELAY:
                delay = MULTIPART_DELAY
                if MULTIPART_STAGGER:
                    delay *= 1 + 0.4 * (int(part_number) - 1)
                if key.startswith("large-cancel/"):
                    delay = 0.1 if int(part_number) == 1 else 5.0
                time.sleep(delay)
            with LOCK:
                upload = MULTIPART.get(upload_id)
                should_fail = (
                    key.startswith("fail/")
                    and int(part_number) == 2
                    and upload_id not in FAILED_PARTS
                )
                if should_fail:
                    FAILED_PARTS.add(upload_id)
                elif upload is not None:
                    upload["parts"][int(part_number)] = body
            if should_fail:
                bump("failPart")
                return error_response(self, "BadDigest", "Injected part failure", 400)
            if upload is None:
                return error_response(self, "NoSuchUpload", "The upload does not exist", 404)
            bump("uploadPart")
            self.send_response(200)
            self.send_header("ETag", f'"part-{part_number}"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        copy_source = urllib.parse.unquote(self.headers.get("x-amz-copy-source", ""))
        if "?versionId=" in copy_source:
            source, version_id = copy_source.split("?versionId=", 1)
            if source.lstrip("/") == f"{bucket}/{key}":
                bump(f"restoreVersion:{version_id}")
            return xml_response(
                self,
                f'<?xml version="1.0" encoding="UTF-8"?><CopyObjectResult xmlns="{XMLNS}">'
                f'<LastModified>{DATE}</LastModified><ETag>&quot;etag-restored&quot;</ETag></CopyObjectResult>',
            )
        with LOCK:
            LAST_PUT.update(key=key, size=len(body))
            OBJECTS[key] = {
                "body": body,
                "content_type": self.headers.get("Content-Type", "application/octet-stream"),
            }
        bump("put")
        self.send_response(200)
        self.send_header("ETag", '"etag-put"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        global NEXT_UPLOAD
        bucket, key, query = self.split()
        if bucket == "denied":
            bump("deniedPost")
            return error_response(self, "AccessDenied", "Access Denied", 403)
        if "uploads" in query:
            with LOCK:
                NEXT_UPLOAD += 1
                upload_id = f"upload-{NEXT_UPLOAD}"
                MULTIPART[upload_id] = {
                    "bucket": bucket,
                    "key": key,
                    "parts": {},
                    "content_type": self.headers.get("Content-Type", "application/octet-stream"),
                }
            bump("createMultipart")
            return xml_response(
                self,
                f'<?xml version="1.0" encoding="UTF-8"?><InitiateMultipartUploadResult xmlns="{XMLNS}">'
                f"<Bucket>{bucket}</Bucket><Key>{key}</Key><UploadId>{upload_id}</UploadId>"
                "</InitiateMultipartUploadResult>",
            )
        upload_id = query.get("uploadId", [None])[0]
        if upload_id:
            body = read_request_body(self)
            with LOCK:
                upload = MULTIPART.get(upload_id)
            if upload is None:
                return error_response(self, "NoSuchUpload", "The upload does not exist", 404)
            try:
                root = ET.fromstring(body)
                ns = {"s3": XMLNS}
                requested = []
                for part in root.findall(".//s3:Part", ns):
                    number = int(part.findtext("s3:PartNumber", namespaces=ns))
                    requested.append(number)
                if not requested:
                    requested = sorted(upload["parts"])
                payload = b"".join(upload["parts"][number] for number in requested)
            except (ET.ParseError, KeyError, TypeError, ValueError):
                return error_response(self, "InvalidPart", "Missing or invalid parts", 400)
            with LOCK:
                OBJECTS[upload["key"]] = {
                    "body": payload,
                    "content_type": upload["content_type"],
                }
                MULTIPART.pop(upload_id, None)
            bump("completeMultipart")
            return xml_response(
                self,
                f'<?xml version="1.0" encoding="UTF-8"?><CompleteMultipartUploadResult xmlns="{XMLNS}">'
                f"<Location>http://127.0.0.1/{upload['bucket']}/{upload['key']}</Location>"
                f"<Bucket>{upload['bucket']}</Bucket><Key>{upload['key']}</Key>"
                '<ETag>&quot;etag-multipart&quot;</ETag></CompleteMultipartUploadResult>',
            )
        return error_response(self, "InvalidRequest", "Unsupported POST", 400)

    def do_DELETE(self):
        bucket, key, query = self.split()
        upload_id = query.get("uploadId", [None])[0]
        if upload_id:
            with LOCK:
                upload = MULTIPART.pop(upload_id, None)
            if upload is None:
                return error_response(self, "NoSuchUpload", "The upload does not exist", 404)
            bump("abortMultipart")
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        version_id = query.get("versionId", [None])[0]
        if version_id:
            bump(f"deleteVersion:{version_id}")
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with LOCK:
            LAST_DELETE.update(key=key)
            OBJECTS.pop(key, None)
        bump("delete")
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def list_objects(self, bucket, query):
        global ACTIVE_LIST, MAX_ACTIVE_LIST
        bump("list")
        with LOCK:
            ACTIVE_LIST += 1
            MAX_ACTIVE_LIST = max(MAX_ACTIVE_LIST, ACTIVE_LIST)
            LIST_TIMES.append(time.time())
        try:
            return self._list_objects(bucket, query)
        finally:
            with LOCK:
                ACTIVE_LIST -= 1

    def _list_objects(self, bucket, query):
        prefix = query.get("prefix", [""])[0]
        delimiter = query.get("delimiter", [None])[0]
        recursive = delimiter is None

        if bucket == "denied" or (bucket == "alpha" and prefix == "deniedfolder/"):
            return error_response(self, "AccessDenied", "Access Denied")

        if bucket == "slow":
            time.sleep(1.0)
            rows, prefixes = [("slow-item.txt", 4)], []
        elif bucket == "throttle":
            time.sleep(0.25)
            rows, prefixes = [(f"{prefix}item.txt", 1)], []
        elif bucket == "fast":
            rows, prefixes = [("fast-item.txt", 4)], []
        elif bucket == "beta":
            if prefix == "beta-folder/":
                rows, prefixes = [("beta-folder/item.txt", 3)], []
            else:
                rows, prefixes = [("beta-item.txt", 4)], []
        elif bucket == "alpha" and recursive:
            if prefix == "slowfolder/":
                time.sleep(0.5)
                rows, prefixes = [("slowfolder/item.txt", 9)], []
            elif prefix in ("photos/", "paged/"):
                # Keep scans alive long enough to prove the concurrency cap.
                time.sleep(0.2)
                rows, prefixes = self.alpha_recursive(prefix)
            else:
                rows, prefixes = self.alpha_recursive(prefix)
        elif bucket == "alpha":
            rows, prefixes = self.alpha_direct(prefix)
        else:
            rows, prefixes = [], []

        if bucket == "alpha":
            with LOCK:
                dynamic = [
                    (stored_key, len(value["body"]))
                    for stored_key, value in OBJECTS.items()
                    if stored_key.startswith(prefix)
                    and (recursive or "/" not in stored_key[len(prefix):])
                ]
            rows = rows + dynamic

        next_token = None
        if bucket == "alpha" and recursive and prefix == "paged/":
            try:
                start = int(query.get("continuation-token", ["0"])[0] or 0)
            except ValueError:
                start = 0
            rows = rows[start:start + 2]
            if start + 2 < 5:
                next_token = str(start + 2)

        body = (
            f'<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="{XMLNS}">'
            f"<Name>{bucket}</Name><Prefix>{prefix}</Prefix>"
            f"<KeyCount>{len(rows)}</KeyCount><MaxKeys>1000</MaxKeys>"
            f"<IsTruncated>{'true' if next_token else 'false'}</IsTruncated>"
            + (f"<NextContinuationToken>{next_token}</NextContinuationToken>" if next_token else "")
            + f"{prefixes_xml(prefixes)}{contents_xml(rows)}</ListBucketResult>"
        )
        return xml_response(self, body)

    def alpha_direct(self, prefix):
        if prefix == "":
            return (
                [("readme.txt", 12), ("notes.txt", 5), ("marker/", 0)],
                ["photos/", "paged/", "deniedfolder/", "marker/", "emptyfolder/", "slowfolder/"],
            )
        if prefix == "photos/":
            return [("photos/a.jpg", 100)], ["photos/2026/"]
        if prefix == "paged/":
            return [("paged/1.txt", 10), ("paged/2.txt", 20), ("paged/3.txt", 30),
                    ("paged/4.txt", 40), ("paged/5.txt", 50)], []
        if prefix == "marker/":
            return [("marker/x.txt", 5)], []
        if prefix == "folder/":
            with LOCK:
                if LAST_PUT["key"].startswith("folder/"):
                    return [(LAST_PUT["key"], LAST_PUT["size"])], []
            return [], []
        return [], []

    def alpha_recursive(self, prefix):
        data = [
            ("readme.txt", 12),
            ("notes.txt", 5),
            ("photos/a.jpg", 100),
            ("photos/2026/b.jpg", 200),
            ("photos/2026/c.jpg", 300),
            ("paged/1.txt", 10),
            ("paged/2.txt", 20),
            ("paged/3.txt", 30),
            ("paged/4.txt", 40),
            ("paged/5.txt", 50),
            ("deniedfolder/x.txt", 7),
            ("marker/", 0),
            ("marker/x.txt", 5),
        ]
        if prefix == "":
            return data, []
        if prefix == "paged/":
            return [(k, n) for k, n in data if k.startswith("paged/")], []
        if prefix in ("deniedfolder/", "marker/", "folder/") or prefix.startswith("photos/"):
            return [(k, n) for k, n in data if k.startswith(prefix)], []
        return [], []

    def list_versions(self, bucket, key, query):
        bump("versions")
        prefix = query.get("prefix", ["readme.txt"])[0]
        body = (
            f'<?xml version="1.0" encoding="UTF-8"?><ListVersionsResult xmlns="{XMLNS}">'
            f"<Name>{bucket}</Name><Prefix>{prefix}</Prefix>"
            "<KeyMarker></KeyMarker><VersionIdMarker></VersionIdMarker>"
            "<MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated>"
            "<Version><Key>readme.txt</Key><VersionId>v1</VersionId><IsLatest>true</IsLatest>"
            f"<LastModified>{DATE}</LastModified><ETag>&quot;etag1&quot;</ETag>"
            "<Size>12</Size><StorageClass>STANDARD</StorageClass></Version>"
            "</ListVersionsResult>"
        )
        return xml_response(self, body)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"LISTENING {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

from .exceptions cimport BadRequestFormat
from .headers cimport HttpHeaderCollection, HttpHeader
from .cookies cimport HttpCookie, parse_cookie, datetime_to_cookie_format
from .contents cimport HttpContent, extract_multipart_form_data_boundary, parse_www_form_urlencoded, parse_multipart_form_data


import re
import httptools
from asyncio import Event
from urllib.parse import parse_qs
from json import loads as json_loads
from json.decoder import JSONDecodeError
from datetime import datetime, timedelta
from typing import Union, Dict, List, Optional


cdef int get_content_length(HttpHeaderCollection headers):
    header = headers.get_single(b'content-length')
    if header:
        return int(header.value)
    return -1


cdef bint get_is_chunked_encoding(HttpHeaderCollection headers):
    cdef HttpHeader header
    header = headers.get_single(b'transfer-encoding')
    if header and b'chunked' in header.value.lower():
        return True
    return False


_charset_rx = re.compile(b'charset=([^;]+)\\s', re.I)


cpdef str parse_charset(bytes value):
    m = _charset_rx.match(value)
    if m:
        return m.group(1).decode('utf8')
    return None


cdef class HttpMessage:

    def __init__(self, 
                 HttpHeaderCollection headers, 
                 HttpContent content):
        self.headers = headers
        self._content = None
        self._cookies = None
        self._raw_body = bytearray()
        self.complete = Event()
        self._form_data = None
        self._content_length = get_content_length(self.headers) if headers else -1
        self._chunked_encoding = get_is_chunked_encoding(self.headers) if headers else False
        self.content = content

    @property
    def raw_body(self):
        return self._raw_body

    @property
    def content(self):
        return self._content

    @content.setter
    def content(self, value: HttpContent):
        self._content = value
        if value and value.body:
            self.complete.set()
            self._raw_body.extend(value.body)
        else:
            self.complete.clear()

    cdef void on_body(self, bytes chunk):
        self._raw_body.extend(chunk)
        body_len = len(self._raw_body)

        if self._content_length > -1:
            if body_len >= self._content_length:
                self.complete.set()
        else:
            if self._chunked_encoding and (chunk.endswith(b'0\n\n') or chunk.endswith(b'0\r\n\r\n')):
                self.complete.set()

    async def read(self) -> bytes:
        await self.complete.wait()
        return bytes(self._raw_body)

    async def text(self) -> str:
        body = await self.read()
        return body.decode(self.charset)

    async def form(self):
        if self._form_data is not None:
            return self._form_data
        content_type = self.headers.get_single(b'content-type')

        if not content_type:
            return {}

        content_type_value = content_type.value

        if b'application/x-www-form-urlencoded' in content_type_value:
            text = await self.text()
            self._form_data = parse_www_form_urlencoded(text)
            return self._form_data

        if b'multipart/form-data;' in content_type_value:
            body = await self.read()
            boundary = extract_multipart_form_data_boundary(content_type_value)
            self._form_data = list(parse_multipart_form_data(body, boundary))
            return self._form_data
        self._form_data = {}

    async def files(self, name=None):
        if isinstance(name, str):
            name = name.encode('ascii')

        content_type = self.headers.get_single(b'content-type')

        if not content_type or b'multipart/form-data;' not in content_type.value:
            return []
        data = await self.form()
        if name:
            return [part for part in data if part.file_name and part.name == name]
        return [part for part in data if part.file_name]

    async def json(self, loads=json_loads):
        text = await self.text()
        try:
            return loads(text)
        except JSONDecodeError as decode_error:
            content_type = self.headers.get_single(b'content-type')
            if content_type and b'application/json' in content_type.value:
                raise BadRequestFormat('Content-Type is application/json but the content cannot be parsed as JSON',
                                       decode_error)
            else:
                raise

    @property
    def charset(self):
        content_type = self.headers.get_single(b'content-type')
        if content_type:
            return parse_charset(content_type.value) or 'utf8'
        return 'utf8'


cdef class HttpRequest(HttpMessage):

    def __init__(self,
                 bytes method,
                 bytes url,
                 HttpHeaderCollection headers,
                 HttpContent content):
        super().__init__(headers, content)
        self.raw_url = url
        self.url = httptools.parse_url(url)
        self.method = method
        self._query = None
        self.client_ip = None
        self.route_values = None
        self.active = True
        if method in {b'GET', b'HEAD', b'TRACE'}:
            self.complete.set()  # methods without body
        
    def __repr__(self):
        return f'<HttpRequest {self.method.decode()} {self.raw_url.decode()}>'

    @property
    def query(self):
        if self._query is None:
            self._query = parse_qs(self.url.query.decode('utf8'))
        return self._query

    @property
    def cookies(self):
        if self._cookies is not None:
            return self._cookies

        cookies = {}
        if b'cookie' in self.headers:
            for header in self.headers.get(b'cookie'):
                cookie = parse_cookie(header.value)
                cookies[cookie.name] = cookie
        self._cookies = cookies
        return cookies

    def get_cookie(self, name):
        return self.cookies[name]

    def set_cookie(self, cookie):
        self.cookies[cookie.name] = cookie

    def set_cookies(self, cookies):
        for cookie in cookies:
            self.set_cookie(cookie)

    def unset_cookie(self, name):
        del self.cookies[name]

    @property
    def etag(self):
        return self.headers.get(b'etag')

    @property
    def if_none_match(self):
        return self.headers.get_first(b'if-none-match')


cdef class HttpResponse(HttpMessage):

    def __init__(self,
                 int status,
                 HttpHeaderCollection headers=None,
                 HttpContent content=None):
        super().__init__(headers or HttpHeaderCollection(), content)
        self.status = status
        self.active = True

    def __repr__(self):
        return f'<HttpResponse {self.status}>'

    @property
    def cookies(self):
        if self._cookies is not None:
            return self._cookies

        # NB: if cookies are configured headers, here they are read
        cookies = {}
        if b'set-cookie' in self.headers:
            for header in self.headers.get(b'set-cookie'):
                cookie = parse_cookie(header.value)
                cookies[cookie.name] = cookie
        self._cookies = cookies
        return cookies

    def get_cookie(self, name):
        return self.cookies[name]

    def set_cookie(self, cookie):
        self.cookies[cookie.name] = cookie

    def set_cookies(self, cookies):
        for cookie in cookies:
            self.set_cookie(cookie)

    def unset_cookie(self, name):
        self.cookies[name] = HttpCookie(name, b'', datetime_to_cookie_format(datetime.utcnow() - timedelta(days=365)))

    def remove_cookie(self, name):
        del self.cookies[name]

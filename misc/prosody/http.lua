-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local socket = require "socket"
local mime = require "mime"
local url = require "socket.url"
local httpstream_new = require "prosody.httpstream".new;
local server = require "prosody.server"

require"logger"
local start_logger = start_logger
local tbl2str = tbl2str
local type = type

local connlisteners_get = require "prosody.connlisteners".get;
local listener = connlisteners_get("httpclient") or error("No httpclient listener!");

local t_insert, t_concat = table.insert, table.concat;
local pairs, ipairs = pairs, ipairs;
local tonumber, tostring, xpcall, select, debug_traceback, char, format =
      tonumber, tostring, xpcall, select, debug.traceback, string.char, string.format;

module "http"

function urlencode(s) return s and (s:gsub("%W", function (c) return format("%%%02x", c:byte()); end)); end
function urldecode(s) return s and (s:gsub("%%(%x%x)", function (c) return char(tonumber(c,16)); end)); end

local function _formencodepart(s)
	return s and (s:gsub("%W", function (c)
		if c ~= " " then
			return format("%%%02x", c:byte());
		else
			return "+";
		end
	end));
end

function formencode(form)
	local result = {};
	for _, field in ipairs(form) do
		t_insert(result, _formencodepart(field.name).."=".._formencodepart(field.value));
	end
	return t_concat(result, "&");
end

local function request_reader(request, data, startpos)
	if not request.parser then
		local function success_cb(r)
			if request.callback then
				for k,v in pairs(r) do request[k] = v; end
				request.callback(r.body, r.code, request);
				request.callback = nil;
			end
			destroy_request(request);
		end
		local function error_cb(r)
			if request.callback then
				request.callback(r or "connection-closed", 0, request);
				request.callback = nil;
			end
			destroy_request(request);
		end
		local function options_cb()
			return request;
		end
		request.parser = httpstream_new(success_cb, error_cb, "client", options_cb);
	end
	request.parser:feed(data);
end

local function handleerr(err)
	local log1 = start_logger(".PROSODY_MODULE .HTTP_LIB http_handle_error")
	log1:logprint("ERROR", "Traceback[http]: "..tostring(err)..": "..debug_traceback())
end

function request(u, ex, callback)
	local log1 = start_logger(".PROSODY_MODULE .HTTP_LIB http_request")
	local req = url.parse(u);
	
	if not (req and req.host) then
		callback(nil, 0, req);
		return nil, "invalid-url";
	end
	
	if not req.path then
		req.path = "/";
	end
	
	local custom_headers, body;
	local default_headers = { ["Host"] = req.host, ["User-Agent"] = "Prosody XMPP Server" }
	
	
	if req.userinfo then
		default_headers["Authorization"] = "Basic "..mime.b64(req.userinfo);
	end
	
	if ex then
		custom_headers = ex.headers;
		req.onlystatus = ex.onlystatus;
		body = ex.body;
		if body then
			req.method = "POST ";
			default_headers["Content-Length"] = tostring(#body);
			default_headers["Content-Type"] = "application/x-www-form-urlencoded";
		end
		if ex.method then req.method = ex.method; end
	end
	
	req.handler, req.conn = server.wrapclient(socket.tcp(), req.host, req.port or 80, listener, "*a");
	req.write = function (...) return req.handler:write(...); end
	req.conn:settimeout(0);
	local ok, err = req.conn:connect(req.host, req.port or 80);
	if not ok and err ~= "timeout" then
		callback(nil, 0, req);
		return nil, err;
	end
	
	local request_line = { req.method or "GET", " ", req.path, " HTTP/1.1\r\n" };
	
	if req.query then
		t_insert(request_line, 4, "?");
		t_insert(request_line, 5, req.query);
	end
	
	req.write(t_concat(request_line));
	local t = { [2] = ": ", [4] = "\r\n" };
	if custom_headers then
		for k, v in pairs(custom_headers) do
			t[1], t[3] = k, v;
			req.write(t_concat(t));
			default_headers[k] = nil;
		end
	end
	
	for k, v in pairs(default_headers) do
		t[1], t[3] = k, v;
		req.write(t_concat(t));
		default_headers[k] = nil;
	end
	req.write("\r\n");
	
	if body then
		req.write(body);
	end
	
	req.callback = function (content, code, request)
		local log1 = start_logger(".PROSODY_MODULE .HTTP_LIB http_request", "Calling callback, status "..(code or "---"))
		--local x1, x2, x3, x4, x5, x6, x7 = select(2, xpcall(function () return callback(content, code, request) end, handleerr))
		local x1, x2, x3, x4, x5, x6, x7 = xpcall(function () local log1 = start_logger(".PROSODY_MODULE .HTTP_LIB CALLBACK") return callback(content, code, request) end, handleerr)
		log1:logprint("", "x1="..tostring(x1)..", x2="..type(x2)..", x3="..type(x3)..", x4="..type(x4)..", x5="..type(x5)..", x6="..type(x6)..", x7="..type(x7))
		return x3, x4, x5, x6, x7
	end
	
	req.reader = request_reader;
	req.state = "status";
	log1:logprint("", "CHECKPOINT!, type req="..type(req))
	listener.register_request(req.handler, req);
	return req;
end

function destroy_request(request)
	if request.conn then
		request.conn = nil;
		request.handler:close()
		listener.ondisconnect(request.handler, "closed");
	end
end

_M.urlencode = urlencode;

return _M;
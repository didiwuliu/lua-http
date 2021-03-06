describe("http2 connection", function()
	local h2_connection = require "http.h2_connection"
	local new_headers = require "http.headers".new
	local cqueues = require "cqueues"
	local ca = require "cqueues.auxlib"
	local cc = require "cqueues.condition"
	local ce = require "cqueues.errno"
	local cs = require "cqueues.socket"
	it("has a pretty __tostring", function()
		do
			local s, c = ca.assert(cs.pair())
			c = assert(h2_connection.new(c, "client"))
			local stream = c:new_stream()
			assert.same("http.h2_stream{", tostring(stream):match("^.-%{"))
			assert.same("http.h2_connection{", tostring(c):match("^.-%{"))
			c:close()
			s:close()
		end

		-- Start an actual connection so that the tostring shows dependant streams
		local s, c = ca.assert(cs.pair())
		local cq = cqueues.new()
		cq:wrap(function()
			c = assert(h2_connection.new(c, "client"))
			local stream = c:new_stream()
			assert.same("http.h2_stream{", tostring(stream):match("^.-%{"))
			assert.same("http.h2_connection{", tostring(c):match("^.-%{"))
			stream:shutdown()
			assert(c:close())
		end)
		cq:wrap(function()
			s = assert(h2_connection.new(s, "server"))
			assert_loop(s)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("Rejects invalid #preface", function()
		local function test_preface(text)
			local s, c = ca.assert(cs.pair())
			local cq = cqueues.new()
			cq:wrap(function()
				s = assert(h2_connection.new(s, "server"))
				local ok, err = s:step()
				assert.same(nil, ok)
				assert.same("invalid connection preface. not an http2 client?", err.message)
			end)
			cq:wrap(function()
				assert(c:xwrite(text, "n"))
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
			c:close()
			s:close()
		end
		test_preface("invalid preface")
		test_preface("PRI * HTTP/2.0\r\n\r\nSM\r\n\r") -- missing last \n
		test_preface(("long string"):rep(1000))
	end)
	it("read_http2_frame fails with EPROTO on corrupt frame", function()
		local spack = string.pack or require "compat53.string".pack
		local s, c = ca.assert(cs.pair())
		local cq = cqueues.new()
		cq:wrap(function()
			c = assert(h2_connection.new(c, "client"))
			assert.same(ce.EPROTO, select(3, c:read_http2_frame()))
			c:close()
		end)
		cq:wrap(function()
			assert(s:xwrite(spack(">I3 B B I4", 100, 0x6, 0, 0), "bf"))
			assert(s:xwrite("not 100 bytes", "bn"))
			s:close()
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("Can #ping back and forth", function()
		local s, c = ca.assert(cs.pair())
		local cq = cqueues.new()
		cq:wrap(function()
			c = assert(h2_connection.new(c, "client"))
			cq:wrap(function()
				for _=1, 10 do
					assert(c:ping())
				end
				assert(c:shutdown())
			end)
			assert_loop(c)
			assert(c:close())
		end)
		cq:wrap(function()
			s = assert(h2_connection.new(s, "server"))
			cq:wrap(function()
				assert(s:ping())
			end)
			assert_loop(s)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("Can #ping without a driving loop", function()
		local s, c = ca.assert(cs.pair())
		local cq = cqueues.new()
		cq:wrap(function()
			c = assert(h2_connection.new(c, "client"))
			for _=1, 10 do
				assert(c:ping())
			end
			assert(c:close())
		end)
		cq:wrap(function()
			s = assert(h2_connection.new(s, "server"))
			assert_loop(s)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("can send a body", function()
		local s, c = ca.assert(cs.pair())
		local cq = cqueues.new()
		cq:wrap(function()
			c = assert(h2_connection.new(c, "client"))
			local client_stream = c:new_stream()
			local req_headers = new_headers()
			req_headers:append(":method", "GET")
			req_headers:append(":scheme", "http")
			req_headers:append(":path", "/")
			-- use non-integer timeouts to catch errors with integer vs number
			assert(client_stream:write_headers(req_headers, false, 1.1))
			assert(client_stream:write_chunk("some body", false, 1.1))
			assert(client_stream:write_chunk("more body", true, 1.1))
			assert(c:close())
		end)
		cq:wrap(function()
			s = assert(h2_connection.new(s, "server"))
			local stream = assert(s:get_next_incoming_stream())
			local body = assert(stream:get_body_as_string(1.1))
			assert.same("some bodymore body", body)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("waits for peer flow #credits", function()
		local s, c = ca.assert(cs.pair())
		local cq = cqueues.new()
		local client_stream
		cq:wrap(function()
			c = assert(h2_connection.new(c, "client"))

			client_stream = c:new_stream()
			local req_headers = new_headers()
			req_headers:append(":method", "GET")
			req_headers:append(":scheme", "http")
			req_headers:append(":path", "/")
			assert(client_stream:write_headers(req_headers, false))
			local ok, cond = 0, cc.new()
			cq:wrap(function()
				ok = ok + 1
				if ok == 2 then cond:signal() end
				assert(c.peer_flow_credits_increase:wait(TEST_TIMEOUT/2), "no connection credits")
			end)
			cq:wrap(function()
				ok = ok + 1
				if ok == 2 then cond:signal() end
				assert(client_stream.peer_flow_credits_increase:wait(TEST_TIMEOUT/2), "no stream credits")
			end)
			cond:wait() -- wait for above threads to get scheduled
			assert(client_stream:write_chunk(("really long string"):rep(1e4), true))
			assert_loop(c)
			assert(c:close())
		end)
		local len = 0
		cq:wrap(function()
			s = assert(h2_connection.new(s, "server"))
			local stream = assert(s:get_next_incoming_stream())
			while true do
				local chunk, err = stream:get_next_chunk()
				if chunk == nil then
					if err == nil then
						break
					else
						error(err)
					end
				end
				len = len + #chunk
			end
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		assert.same(client_stream.stats_sent, len)
	end)
	describe("priority", function()
		it("allows sending priority frames", function()
			local cq = cqueues.new()
			local s, c = ca.assert(cs.pair())
			cq:wrap(function()
				c = assert(h2_connection.new(c, "client"))
				local parent_stream = c:new_stream()
				assert(parent_stream:write_priority_frame(false, 0, 201))
				parent_stream:shutdown()
				assert(c:close())
			end)
			cq:wrap(function()
				s = assert(h2_connection.new(s, "server"))
				local stream = assert(s:get_next_incoming_stream())
				assert.same(201, stream.weight)
				stream:shutdown()
				assert(s:close())
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
		end)
		it("sets default priority for streams with missing parent", function()
			local cq = cqueues.new()
			local s, c = ca.assert(cs.pair())
			cq:wrap(function()
				c = assert(h2_connection.new(c, "client"))
				local client_stream = c:new_stream()
				local req_headers = new_headers()
				req_headers:append(":method", "GET")
				req_headers:append(":scheme", "http")
				req_headers:append(":path", "/")
				-- Encode HEADER payload and send with dependency on missing stream
				c.encoding_context:encode_headers(req_headers)
				local payload = c.encoding_context:render_data()
				c.encoding_context:clear_data()
				assert(client_stream:write_headers_frame(payload, true, true, nil, nil, 99, 99))
				client_stream:shutdown()
				assert(c:close())
			end)
			cq:wrap(function()
				s = assert(h2_connection.new(s, "server"))
				local stream = assert(s:get_next_incoming_stream())
				-- Check if set to default priority instead of missing parent
				assert.is_not.same(stream.weight, 99)
				stream:shutdown()
				assert(s:close())
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
		end)
	end)
	describe("settings", function()
		it("correctly handles odd frame sizes", function()
			local s, c = ca.assert(cs.pair())
			-- should error if < 16384
			assert.has.errors(function()
				h2_connection.new(c, "client", {[0x5]=1}, TEST_TIMEOUT)
			end)
			assert.has.errors(function()
				h2_connection.new(c, "client", {[0x5]=16383}, TEST_TIMEOUT)
			end)
			-- should error if > 2^24
			assert.has.errors(function()
				h2_connection.new(c, "client", {[0x5]=2^24}, TEST_TIMEOUT)
			end)
			assert.has.errors(function()
				h2_connection.new(c, "client", {[0x5]=2^32}, TEST_TIMEOUT)
			end)
			assert.has.errors(function()
				h2_connection.new(c, "client", {[0x5]=math.huge}, TEST_TIMEOUT)
			end)
			s:close()
			c:close()
		end)
	end)
	describe("correct state transitions", function()
		it("closes a stream when writing headers to a half-closed stream", function()
			local cq = cqueues.new()
			local s, c = ca.assert(cs.pair())
			cq:wrap(function()
				c = assert(h2_connection.new(c, "client"))
				local client_stream = c:new_stream()
				local req_headers = new_headers()
				req_headers:append(":method", "GET")
				req_headers:append(":scheme", "http")
				req_headers:append(":path", "/")
				req_headers:append(":authority", "example.com")
				assert(client_stream:write_headers(req_headers, false))
				assert(client_stream:get_headers())
				assert(c:close())
			end)
			cq:wrap(function()
				s = assert(h2_connection.new(s, "server"))
				local stream = assert(s:get_next_incoming_stream())
				assert(stream:get_headers())
				local res_headers = new_headers()
				res_headers:append(":status", "200")
				assert(stream:write_headers(res_headers, true))
				assert("closed", stream.state)
				assert(s:close())
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
		end)
	end)
	describe("push_promise", function()
		it("permits a simple push promise from server => client", function()
			local cq = cqueues.new()
			local s, c = ca.assert(cs.pair())
			cq:wrap(function()
				c = assert(h2_connection.new(c, "client"))
				local client_stream = c:new_stream()
				local req_headers = new_headers()
				req_headers:append(":method", "GET")
				req_headers:append(":scheme", "http")
				req_headers:append(":path", "/")
				req_headers:append(":authority", "example.com")
				assert(client_stream:write_headers(req_headers, true))
				local pushed_stream = assert(c:get_next_incoming_stream())
				do
					local h = assert(pushed_stream:get_headers())
					assert.same("GET", h:get(":method"))
					assert.same("http", h:get(":scheme"))
					assert.same("/foo", h:get(":path"))
					assert.same(req_headers:get(":authority"), h:get(":authority"))
					assert.same(nil, pushed_stream:get_next_chunk())
				end
				assert(c:close())
			end)
			cq:wrap(function()
				s = assert(h2_connection.new(s, "server"))
				local stream = assert(s:get_next_incoming_stream())
				do
					local h = assert(stream:get_headers())
					assert.same("GET", h:get(":method"))
					assert.same("http", h:get(":scheme"))
					assert.same("/", h:get(":path"))
					assert.same("example.com", h:get(":authority"))
					assert.same(nil, stream:get_next_chunk())
				end
				local pushed_stream do
					local req_headers = new_headers()
					req_headers:append(":method", "GET")
					req_headers:append(":scheme", "http")
					req_headers:append(":path", "/foo")
					req_headers:append(":authority", "example.com")
					pushed_stream = assert(stream:push_promise(req_headers))
				end
				do
					local req_headers = new_headers()
					req_headers:append(":status", "200")
					assert(pushed_stream:write_headers(req_headers, true))
				end
				assert(s:close())
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
		end)
	end)
end)

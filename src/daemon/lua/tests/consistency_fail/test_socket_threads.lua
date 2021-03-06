require"splay.base"
local rpc = require"splay.rpc"
local l_o = log.new(3, "[test_socket_threads]")
local se = require"splay.socket_events"
se.l_o.level = 5
local ev = require"splay.events"
ev.l_o.level = 5
local finish = false
--check that the server thread correctly yields to the periodic thread
events.run(function()
	local rpc_server_thread = rpc.server(30001)
	events.thread(function()
		l_o:print("thread scheduled after rpc.server")
		assert(true)
		l_o:print("TEST_OK")
		finish = true		
	end)
end)

local clock = os.clock
function sleep(n)  -- seconds
  local t0 = clock()
  while clock() - t0 <= n and finish==false do end
end

sleep(1)
if (finish == false) then
	error("Test fail")	
end
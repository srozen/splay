require"splay.base"
-- crypto required for hashing
local crypto	= require"crypto"
-- splay.rpc for RPC calls
local rpc	= require"splay.rpc"
-- splay.net for the HTTP server
local net	= require"splay.net"
-- splay.benc for enconding/decoding
local enc	= require"splay.benc"
-- for handling hexa strings
local misc	= require"splay.misc"
-- splay.lbinenc handles native encoding/decoding for HTTP messages
local serializer	= require"splay.lbinenc"
--splay.paxos for consistency model through paxos
local paxos	= require"splay.paxos"

local log = require"splay.log"

-- _BOOTSTRAPPING controls if the DHT is progressively created by adding nodes to it, or immediately (by taking info from job.nodes)
local _BOOTSTRAPPING = false
-- _PINGING controls if the node pings their neighbors or not
local _PINGING = false
-- _USE_KYOTO controls if the local k,v store uses KyotoCabinet (through splay.restricted_db) or RAM
local _USE_KYOTO = true

local local_db
--if KyotoCabinet is used; TODO maybe the kyoto vs mem mode can be set inside the restricted_db
if _USE_KYOTO then
	--for local DB handling, use splay.restricted_db
	local_db = require"splay.restricted_db"
--if not KyotoCabinet
else
	--for local DB handling, use memory-based DB (a simple table): dbs and local_db
	local_db = {
		init = function(settings)
			dbs = {}
		end,

		open = function(table_name, mode)
			dbs[table_name] = {}
		end,

		get = function(table_name, key)
			if not dbs[table_name] then return nil end
			return dbs[table_name][key]
		end,

		set = function(table_name, key, value)
			if dbs[table_name] then
				dbs[table_name][key] = value
			end
		end,

		totable = function(table_name)
			return dbs[table_name]
		end,

		remove = function(table_name, key)
			if dbs[table_name] then
				dbs[table_name][key] = nil
			end
		end,

		exists = function(table_name)
			if dbs[table_name] then return true else return false end
		end,

		check = function(table_name, key)
			if not dbs[table_name] then
				return -1
			end
			if not dbs[table_name][key] then
				return -1
			end
			return 0
		end,

		close = function(table_name)
			dbs[table_name] = nil
		end
	}
end

--[[ DEBUG ]]--
l_o = log.new(2, "[distdb]")

--LOCAL VARIABLES

--locked_keys contains all the keys that are being modified, thus are locked; stored in RAM, i don't think there is need to store in disk - not so big
local locked_keys = {}
--n_replicas is the number of nodes that store a k,v record; TODO maybe this should match with some distdb settings object
local n_replicas = 3
--min_replicas_write is the minimum number of nodes that must write a k,v to be considered
--successful (only for eventually consistent put); TODO maybe this should match with some distdb settings object
local min_replicas_write = 2
--min_replicas_write is the minimum number of nodes that must read k,v to have
--quorum (only for eventually consistent get); TODO maybe this should match with some distdb settings object
local min_replicas_read = 2
--rpc_timeout is the time in seconds that a node waits for an answer from another node on any rpc call
local rpc_timeout = 15
--paxos_propose_timeout is the time in seconds that a Proposer waits that all Acceptors answer a Propose message
local paxos_propose_timeout = 15
--paxos_accept_timeout is the time in seconds that a Proposer waits that all Acceptors answer an Accept message
local paxos_accept_timeout = 15
--paxos_learn_timeout is the time in seconds that an Acceptor waits that all Learners answer a Learn message
local paxos_learn_timeout = 15
--neighborhood is a table containing tables that contains the ip address, port and ID of all other nodes
local neighborhood = {}
--next_node is a table containing the ip addr, port and ID of the smallest node with bigger ID (next on the ring)
local next_node
--previous_node is a table containing the ip addr, port and ID of the biggest node with smaller ID (previous on the ring)
local previous_node
--init_done is a flag to avoid double initialization
local init_done = false
--prop_ids holds the Proposal IDs for Paxos operations (used by Proposer)
local prop_ids = {}
--paxos_max_retries is the maximum number of times a Proposer can try a Proposal; TODO maybe this should match with some distdb settings object
local paxos_max_retries = 5
--im_gossiping is set to true if the node sent an update about the network and it is still traversing the ring
local im_gossiping = false
--TODO use this to measure the time it takes to spread updates through the ring
local gossiping_elpsd_t = 0
--times_waiting_before_ping: trick variable to make the node wait n periods of 5s to start pinging its neighbor
local times_waiting_before_ping = 4
local ping_period = 5

--Testers:
local sim_delay = false
--sim_fail_rate holds the percentage of failed local transactions (for testing purposes)
local sim_fail_rate = 0
--sim_fail_rate holds the percentage of times that the EP contacts a wrong node (for testing purposes)
local sim_wrong_node_rate = 0


--LOCAL FUNCTIONS

--function get_position returns the position of the node on the ring
local function get_position(node_id)
	--if no node ID is specified
	if not node_id then
		--checks the ID of the node itself
		node_id = n.id
	end
	--for all neighbors
	for i = 1, #neighborhood do
		--if ID is the same as node.id
		if neighborhood[i].id == node_id then
			--return the index
			return i
		end
	end
end

--function calculate_id: calculates the node ID from its ip address and port
local function calculate_id(node)
	--if no node is specified
	if not node then
		--calculates the ID from the ip addr and port of the node itself
		node = {ip = n.ip, port = n.port}
	end
	--returns a SHA1 hash of the concatenation of ip addr + port
	return crypto.evp.digest("sha1", node.ip..node.port)
end

--function get_next_node returns the node in the ring after the specified node
local function get_next_node(node_id)
	--if neighborhood is a list of only 1 node
	if #neighborhood == 1 then
		--return nil
		return nil
	end
	--gets the position with the function get_position; if no node is specified, get_position
	-- will return the position of the node itself
	local node_pos = get_position(node_id)
	--if the node is the last on the neighborhood list
	if node_pos == #neighborhood then
		--return the first node and position=1
		return neighborhood[1], 1
	end
	--else, return the node whose position = node_pos + 1
	return neighborhood[node_pos + 1], (node_pos + 1)
end

--function get_previous_node returns the node in the ring before the specified node
local function get_previous_node(node_id)
	--if neighborhood is a list of only 1 node
	if #neighborhood == 1 then
		--return nil
		return nil
	end
	--gets the position with the function get_position; if no node is specified, get_position
	-- will return the position of the node itself
	local node_pos = get_position(node_id)
	--if the node is the first on the neighborhood list
	if node_pos == 1 then
		--return the last node
		return neighborhood[#neighborhood], #neighborhood
	end
	--else, return the node whose position = node_pos - 1
	return neighborhood[node_pos - 1], (node_pos - 1)
end

--function get_master: looks for the master of a given key
local function get_master(key)
	--the master is initialized as equal to the last node
	local master_pos = 1
	local master = neighborhood[1]
	--if the neighborhood is only one node, this is the master
	if #neighborhood == 1 then
		return master, master_pos
	end
	--for all the neighbors but the first one
	for i = 2, #neighborhood do
		--compares the key with the id of the node
		local compare = misc.bighex_compare(neighborhood[i].id, key)
		--if node ID is bigger
		if (compare == 1) then
			master_pos = i
			--the master is node i
			master = neighborhood[i]
			--get out of the loop
			break
		end
	end
	--prints the master ID at debug level
	--l_o:debug("get_master: master -> "..master.id)
	--returns the master
	return master, master_pos
end

--function get_responsibles: looks for the nodes that are responsible of a given key
local function get_responsibles(key)
	--gets the master of the key
	local master, master_pos = get_master(key)
	--the first responsible is the master
	local responsibles = {master}
	--the number of responsibles is in principle = number of replicas
	local n_responsibles = n_replicas
	--if the size of the neighborhood is less than that, n_responsibles = size of neighborhood
	if n_replicas > #neighborhood then
		n_responsibles = #neighborhood
	end
	--repeat n_responsibles - 1 times:
	for i = 1, (n_responsibles - 1) do
		--if master_pos + i is less or equal to the size of neighborhood
		if master_pos + i <= #neighborhood then
			--insert the node with this position
			table.insert(responsibles, neighborhood[master_pos + i])
		--else
		else
			--insert the node with position = master_pos + i - #neighborhood (closing the ring)
			table.insert(responsibles, neighborhood[master_pos + i - #neighborhood])
		end
	end
	--return the list of responsible nodes and the position of the master node
	return responsibles, master_pos
end

--function is_responsible: checks if a node is responsible for a key or not
local function is_responsible(key, node_id)
		--for all the responsible nodes for key
		for i,v in ipairs(get_responsibles(key)) do
			--if v.id is equal to the given node ID
			if node_id == v.id then
				--returns true
				return true
			end
		end
		--if there were no matches, returns false
		return false
end

--function sanity_check: checks if there are keys that don't belong to the node anymore and deletes them
local function sanity_check()
	--l_o:notice(n.short_id..":sanity_check: START")
	--obtains the key list
	local my_keys = local_db.totable("key_list")
	--for all the keys of the node
	for i,v in pairs(my_keys) do
		--if the node is not responsible for key i
		if not is_responsible(i, n.id) then
			--prints message
			--l_o:debug(n.short_id..":sanity_check: removing key="..key)
			--removes the key from "db_table" and "key_list"
			local_db.remove("db_table", key)
			local_db.remove("key_list", key)
		end
	end
end

--function shorten_id: returns only the first 5 hexadigits of a ID string (for better printing)
function shorten_id(id)
	if not id then
		return nil
	end
	if #id < 5 then
		return id
	end
	return string.sub(id, 1, 5)..".."
end

--function print_me: prints the IP address, port and position of the node
local function print_me()
	--l_o:print(n.short_id..":print_me: ME! IP:port=", n.ip..":"..n.port, "position=", n.position)
end

--function print_node: prints the IP address, port, and ID of a given node
local function print_node(node)
	--l_o:print(n.short_id..":print_node: neighbor=", node.ip, node.port, node.id)
end

--function print_all: prints the node itself and its neighbors
function print_all()
	print_me()
	--l_o:print()
	--for the conf file "ports.lua" of the client test file
	local for_ports_lua = "for ports.lua "
	for _,v in ipairs(neighborhood) do
		print_node(v)
		for_ports_lua = for_ports_lua..", "..v.ip..":"..(v.port+1)
	end
	--l_o:print(n.short_id..":print_all: "..for_ports_lua)

end

--function transfer_key: function meant to be called remotely; it transfers the raw value of a key from a node to another
function transfer_key(key, value)
	--logs entrance
	--l_o:debug(n.short_id..":transfer_key: receiving key=", key, "value type=", type(value))
	--sets "db_table" and "key_list" with respective values
	local_db.set("db_table", key, value)
	local_db.set("key_list", key, 1)
end

--function add_node_to_neighborhood: adds a node to the neighborhood table, re-sorts and updates n.position
function add_node_to_neighborhood(node)
	--if node is nil don't do anything
	if not node then
		return nil
	end

	--retrieves the keys that are managed by itself
	local my_keys = local_db.totable("key_list")
	--this variable will hold the set of keys that were managed by the old next-node
	local old_next_node_keys = {}
	--this variable will hold the set of keys that were managed by the old previous-node
	local old_previous_node_keys = {}
 
	--for each key
	for i,v in pairs(my_keys) do
		--if the old next-node is responsible before changes
		if is_responsible(i, next_node.id) then
			--adds to the list of "old next-node keys"
			table.insert(old_next_node_keys, i)
		end
		--if the old previous-node is responsible before changes
		if is_responsible(i, previous_node.id) then
			--adds to the list of "old next-node keys"
			table.insert(old_previous_node_keys, i)
		end
		--NOTE: this code is cleaner, but if there are millions of keys being administered, it would be better to save the list of responsible
		-- nodes for the second for loop, done after rearranging the network
	end

	--insert the node
	table.insert(neighborhood, node)
	--sort the neighborhood table
	table.sort(neighborhood, function(a,b) return a.id<b.id end)
	--updates the node's position
	n.position = get_position()
	--updates the "pointer" to the next node
	next_node = get_next_node()
	--updates the "pointer" to the previous node
	previous_node = get_previous_node()
	--logs
	--l_o:debug(n.short_id..":add_node_to_neighborhood: adding node="..node.short_id.." to my list")

	--holds the set of keys that are managed by the new next-node
	local new_next_node_keys = {}
	--holds the set of keys that are managed by the new previous-node
	local new_previous_node_keys = {}
	--for each key
	for i,v in pairs(my_keys) do
		--if the new next-node is responsible
		if is_responsible(i, next_node.id) then
			--adds to the list of "new next-node keys"
			table.insert(new_next_node_keys, i)
		end
		--if the new previous-node is responsible
		if is_responsible(i, previous_node.id) then
			--adds to the list of "new next-node keys"
			table.insert(new_previous_node_keys, i)
		end
	end
	
	--declares in_new
	local in_new

	--for all the keys that the old next-node had
	for i,v in ipairs(old_next_node_keys) do
		--in_new starts as false
		in_new = false
		--if it finds the key v in the new next-node keys
		for i2,v2 in ipairs(new_next_node_keys) do
			if v == v2 then
				--in_new is true
				in_new = true
				--removes the matching key from the new list to improve efficiency in the next searchs
				table.remove(new_next_node_keys, i2)
				--no need to look further; the key is in the new list
				break
			end
		end
		--if the key is not in the new list
		if not in_new then
			--it transfers it to the new next-node AQUI ME QUEDE
			rpc.acall(next_node, {"distdb.transfer_key", v, local_db.get("db_table", v)})
		end
	end

	--for all the keys that the old next-node had
	for i,v in ipairs(old_previous_node_keys) do
		--in_new starts as false
		in_new = false
		--if it finds the key v in the new next-node keys
		for i2,v2 in ipairs(new_previous_node_keys) do
			if v == v2 then
				--in_new is true
				in_new = true
				--removes the matching key from the new list to improve efficiency in the next searchs
				table.remove(new_previous_node_keys, i2)
				--no need to look further; the key is in the new list
				break
			end
		end
		--if the key is not in the new list
		if not in_new then
			--it transfers it to the new next-node AQUI ME QUEDE
			rpc.acall(previous_node, {"distdb.transfer_key", v, local_db.get("db_table", v)})
		end
	end

	--does a self sanity check
	sanity_check()


end

--function remove_node_from_neighborhood: removes a node from the neighborhood table, re-sorts and updates n.position; TODO take care of n_nodes < n_replicas
function remove_node_from_neighborhood(node_pos)

	--retrieves the keys that are managed by itself
	local my_keys = local_db.totable("key_list")
	--this variable will hold the set of keys that were managed by the old next-node
	local old_next_node_keys = {}
 
	--for each key
	for i,v in pairs(my_keys) do
		--if the old next-node is responsible before changes
		if is_responsible(i, next_node.id) then
			--adds to the list of "old next-node keys"
			table.insert(old_next_node_keys, i)
		end
		--NOTE: this code is cleaner, but if there are millions of keys being administered, it would be better to save the list of responsible
		-- nodes for the second for loop, done after rearranging the network
	end

	--retrieves the node for logging purposes
	local node = neighborhood[node_pos]
	--logs
	--l_o:debug(n.short_id..":remove_node_from_neighborhood: removing node="..node.short_id.." of my list")
	
	--removes the node from the neighborhood
	table.remove(neighborhood, node_pos)
	--recalculates n.position
	n.position = get_position()
	--updates the "pointer" to the next node
	next_node = get_next_node()
	--updates the "pointer" to the previous node
	previous_node = get_previous_node()


	--holds the set of keys that are managed by the new next-node
	local new_next_node_keys = {}
	--for each key
	for i,v in pairs(my_keys) do
		--if the new next-node is responsible
		if is_responsible(i, next_node.id) then
			--adds to the list of "new next-node keys"
			table.insert(new_next_node_keys, i)
		end
	end
	
	--declares in_new
	local in_new

	--for all the keys that the old next-node had
	for i,v in ipairs(old_next_node_keys) do
		--in_new starts as false
		in_new = false
		--if it finds the key v in the new next-node keys
		for i2,v2 in ipairs(new_next_node_keys) do
			if v == v2 then
				--in_new is true
				in_new = true
				--removes the matching key from the new list to improve efficiency in the next searchs
				table.remove(new_next_node_keys, i2)
				--no need to look further; the key is in the new list
				break
			end
		end
		--if the key is not in the new list
		if not in_new then
			--it transfers it to the new next-node AQUI ME QUEDE
			rpc.acall(next_node, {"distdb.transfer_key", v, local_db.get("db_table", v)})
		end
	end

	--does a self sanity check
	sanity_check()
end

--function receive_gossip: updates the table if necessary and forwards the gossip
function receive_gossip(message, neighbor_about)
	--TODO this gossiping technique may not work for 2 failures in 1 whole gossiping period
	--if the message is an "add"
	if message == "add" then
		--if get_position returns something, it means the node is already in the list, so it returns
		if get_position(neighbor_about) then
			im_gossiping = false
			return nil
		end
		--if not, add the node to the neighborhood table
		add_node_to_neighborhood(neighbor_about)
	--if the message is a "remove"
	elseif message == "remove" then
		--gets the position from the arguments of the function
		local neighbor_about_pos = get_position(neighbor_about)
		--if the node does not exist, it returns
		if not neighbor_about_pos then
			im_gossiping = false
			return nil
		end
		--else, it removes it from the neighbordhood table
		remove_node_from_neighborhood(neighbor_about_pos)
	end
	
	if sim_delay then
		--sleep for a random time between 0 and 2sec
		events.sleep(math.random(100)/50)
	end

	--forward the gossip to the previous node
	events.thread(function()
		--l_o:notice(n.short_id..":receive_gossip: gossiping to node="..previous_node.short_id..", message="..message..", about node="..neighbor_about.short_id)
		rpc.call({ip=previous_node.ip, port=(previous_node.port+2)}, {"distdb.receive_gossip", message, neighbor_about})
	end)

end

--function gossip_changes: starts a event-based gossip to announce a node adding or removal
local function gossip_changes(message, neighbor_about)
	if previous_node then
		--create the gossip to the previous node
		events.thread(function()
			--l_o:notice(n.short_id..":gossip_changes: gossiping to node="..previous_node.short_id..", message="..message..", about node="..neighbor_about.short_id)
			rpc.call({ip=previous_node.ip, port=(previous_node.port+2)}, {"distdb.receive_gossip", message, neighbor_about})
		end)
	end
end

--function ping_others: periodic function that pings the next node on the ring
local function ping_others()
	--if there is a next_node (it could be the case of a 1-node ring, where the node will not ping anyone)
	if next_node and (times_waiting_before_ping < 0) then
		--logs
		--l_o:debug(n.short_id..":ping_others: pinging "..next_node.short_id)
		--pings, and if the response is not ok; TODO should be after several tries
		if not rpc.ping({ip=next_node.ip, port=(next_node.port+2)}) then
			--logs that it lost a neighbor
			--l_o:debug(n.short_id..":ping_others: i lost neighbor="..next_node.short_id)
			--creates an object node_about to insert it into the message to be gossipped
			local node_about = {id = next_node.id}
			--calculates the position of the next node
			local next_node_pos = get_position(next_node)
			
			--removes the node from its table
			remove_node_from_neighborhood(next_node_pos)

			--gossips the removal
			gossip_changes("remove", node_about)
		end
	else
		--this variable reaches to 6; alternative way to make a events.sleep of 30s which
		-- is not permitted within the init function
		times_waiting_before_ping = times_waiting_before_ping - 1
	end
end

function is_gossiping()
	return im_gossiping
end

--function add_me: called by a new node to the RDV node (job.nodes[1]) to retrieve the neighborhood table and make him gossip the adding
function add_me(node_to_add)
	--if the node is already in the ring, leave
	if get_position(node_to_add) then
		return nil
	end
	im_gossiping = true
	--add the node to its own table
	add_node_to_neighborhood(node_to_add)
	--create a gossip to announce the adding
	gossip_changes("add", node_to_add)
	--return the neighborhood table as answer to the new node
	return neighborhood
end

--function parse_http_request: parses the payload of the HTTP request
function parse_http_request(socket)
	--retrieves the first line, in order to get the method
	local first_line = socket:receive("*l")
	--initializes an auxiliary variable
	local first_line_analyzer = {}
	--for every "word" separated by spaces on the first line, add the word to the aux variable
	for piece in string.gmatch(first_line, "[^ ]+") do
		table.insert(first_line_analyzer, piece)
	end
	--the method is the first word
	local method = first_line_analyzer[1]
	--the resource is the second word
	local resource = first_line_analyzer[2]
	--the HTTP version is the third
	local http_version = first_line_analyzer[3]
	local headers = {}
	--extract the headers line by line
	while true do
		local data = socket:receive("*l")
		if ( #data < 1 ) then
			break
		end
		--print("data = "..data)
		local header_separator = string.find(data, ":")
		local header_k = string.sub(data, 1, header_separator-1)
		local header_v = string.sub(data, header_separator+2)
		--print(header_k, header_v)
		headers[header_k] = header_v
	end

	--takes the number of bytes for the body from the header "content-length"
	local bytes_left = tonumber(headers["content-length"] or headers["Content-Length"])
	-- initializes the request body read from client as empty string
	local body
	--if there are bytes left
	if bytes_left then
		--retrieve the body
		body = socket:receive(bytes_left)
	end
	--returns all the parsed elements
	return method, resource, http_version, headers, body
end

--REQUEST HANDLING FUNCTIONS

--function handle_get: handles a GET request as an Entry Point
function handle_get(key, type_of_transaction)
	--logs entrance
	--l_o:debug(n.short_id..":handle_get: for key="..shorten_id(key))
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":handle_get: key="..shorten_id(key).." START. elapsed_time=0\n"}

	--gets the list of responsibles for the given key
	local responsibles = get_responsibles(key)
	--choses a random responsible node
	local chosen_node_id = math.random(#responsibles)
	--logs
	--l_o:debug(n.short_id..":handle_get: choosing responsible n. "..chosen_node_id)
	local chosen_node = responsibles[chosen_node_id]

	--probability of sending the request to a wrong node (for testing purposes)
	if math.random(100) < sim_wrong_node_rate then
		--choses a random node from the whole network
		local new_node_id = math.random(#neighborhood)
		chosen_node = neighborhood[new_node_id]
		--logs
		--l_o:debug(n.short_id..":handle_get: Chosen node changed")
	end

	--constructs the function to call
	local function_to_call = "distdb."..type_of_transaction.."_get"
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":handle_get: responsible chosen, about to make RPC call. elapsed_time="..(misc.time() - start_time).."\n")
	--makes the RPC call
	local rpc_ok, rpc_answer = rpc.acall(chosen_node, {function_to_call, key, value})
	--if the call was OK
	if rpc_ok then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":handle_get: key="..shorten_id(key).." END success=true. elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns the answer to the RPC call
		return rpc_answer[1], rpc_answer[2]
	end
	--if the call was not OK (the if has a return)
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":handle_get: key="..shorten_id(key).." END success=false. elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))
	--returns with error message
	return nil, "network problem"
end

--function handle_get_all_records: handles a GET_ALL_RECORDS request, returns the whole database the node holds
function handle_get_all_records()
	return true, local_db.totable("db_table") 
end

--function handle_get_key_list: handles a GET_KEY_LIST request, returns the list of keys that the node holds
function handle_get_key_list()
	return true, local_db.totable("key_list") 
end

--function handle_get_master: handles a GET_MASTER request, returns a node object (IP, port, ID, short ID) of the node that is the master of a given key
function handle_get_master(key)
	return true, get_master(key)
end

--function handle_get_node_list: handles a GET_NODE_LIST request, returns the list of all currently active nodes
function handle_get_node_list()
	return true, neighborhood 
end

--function handle_put: handles a PUT request as the Entry Point; TODO check about setting N,R,W on the transaction
function handle_put(key, type_of_transaction, value)
	--logs entrance
	--l_o:print(n.short_id..":handle_put: START for key=", shorten_id(key))
	--l_o:debug(n.short_id..":handle_put: value=", value)
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":handle_put: key="..shorten_id(key).." START. elapsed_time=0\n"}
	
	--initializes chosen_node
	local chosen_node
	--if the transaction is of type "consistent"
	if type_of_transaction == "consistent" then
		--the chosen_node is the master of the key
		chosen_node = get_master(key)
	--if not
	else
		--takes a random node from the responsibles list
		local responsibles = get_responsibles(key)
		local chosen_node_id = math.random(#responsibles)
		--logs
		--l_o:debug(n.short_id..":handle_put: choosing responsible n. "..chosen_node_id)
		chosen_node = responsibles[chosen_node_id]
	end
	--logs
	--l_o:debug(n.short_id..":handle_put: Chosen node="..chosen_node.short_id)
	
	--probability of sending the request to a wrong node (for testing purposes)
	if math.random(100) < sim_wrong_node_rate then
		--choses a random node from the whole network
		local new_node_id = math.random(#neighborhood)
		chosen_node = neighborhood[new_node_id]
		--logs
		--l_o:debug(n.short_id..":handle_put: Chosen node changed")
	end

	--constructs the function to call
	local function_to_call = "distdb."..type_of_transaction.."_put"
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":handle_put: responsible chosen, about to make RPC call. elapsed_time="..(misc.time() - start_time).."\n")
	--makes the RPC call
	local rpc_ok, rpc_answer = rpc.acall(chosen_node, {function_to_call, key, value})
	--if the call went OK
	if rpc_ok then
		--if something went wrong (internal answer from the remote function)
		if not rpc_answer[1] then
			--logs error
			--l_o:error(n.short_id..":handle_put: something went wrong; node="..chosen_node.ip..":"..chosen_node.port.." answered=", rpc_answer[2])
		end
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":handle_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success=true. elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns the answer of the RPC call
		return rpc_answer[1], rpc_answer[2]
	end
	--if the call did not go OK (the previous if has a return)
	--logs error
	--l_o:error(n.short_id..":handle_put: RPC call to node="..chosen_node.ip..":"..chosen_node.port.." was unsuccessful")
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":handle_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success=false. elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))
	--returns with error message
	return nil, "network problem"
end

--function handle_delete: handles a DELETE request
function handle_delete(key, type_of_transaction)
	--l_o:print(n.short_id..":handle_delete: START for key=", shorten_id(key))
	--a delete is a put with a value = nil
	return handle_put(key, type_of_transaction, nil)
end

--function handle_change_log_lvl: handles a CHANGE_LOG_LVL request, to set the logging threshold in a new level (1-5)
function handle_change_log_lvl(log_level)
	l_o.level = tonumber(log_level)
	return true
end

--function handle_change__n_replicas: handles a CHANGE_N_REPLICAS request; changes locally in the node the number of replicas that its keys will have
function handle_change_n_replicas(n_replicas)
	n_replicas = tonumber(n_replicas)
	return true
end

--TABLE OF FORWARDING FUNCTIONS
local forward_request = {
	["GET"] = handle_get,
	["PUT"] = handle_put,
	["DELETE"] = handle_delete,
	["GET_MASTER"] = handle_get_master,
	["GET_NODE_LIST"] = handle_get_node_list,
	["GET_ALL_RECORDS"] = handle_get_all_records,
	["GET_KEY_LIST"] = handle_get_key_list,
	["CHANGE_LOG_LVL"] = handle_change_log_lvl,
	["CHANGE_N_REPLICAS"] = handle_change_n_replicas
	}


--FRONT-END FUNCTIONS

--function handle_http_message: handles the incoming messages (HTTP requests)
function handle_http_message(socket)
	--logs entrance
	--l_o:debug(n.short_id..":handle_http_message: START")
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":handle_http_message: START. elapsed_time=0\n"}

	--gets the client IP address and port from the socket
	local client_ip, client_port = socket:getpeername()
	--parses the HTTP message and extracts the HTTP method, the requested resource, etc.
	local method, resource, http_version, headers, body = parse_http_request(socket)
	--the resource has the format /resource
	resource = string.sub(resource, 2)
	--logs
	--l_o:debug(n.short_id..":handle_http_message: resource is "..resource)
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":handle_http_message: http message parsed. elapsed_time="..(misc.time() - start_time).."\n")

	--the value is the body if it exists
	local value = body
	--the header Type tells if the transaction is strongly consistent, eventually consistent, or paxos
	local type_of_transaction = headers["Type"] or headers["type"]
	--logs
	--l_o:debug(n.short_id..":handle_http_message: http request parsed, a "..method.." request will be forwarded")
	--l_o:debug(n.short_id..":handle_http_message: resource=", resource)
	--l_o:debug(n.short_id..":handle_http_message: value=", value)
	--forwards the request to a specific handle function
	local ok, answer = forward_request[method](resource, type_of_transaction, value)

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":handle_http_message: method was performed. elapsed_time="..(misc.time() - start_time).."\n")

	--initializes the response body, code and content type as nil
	local http_response_body, http_response_code, http_response_content_type
	--if the call was OK
	if ok then
		--if answer exists
		if answer then
			--serializes the answer for HTTP transmision
			http_response_body = serializer.encode(answer)
		end
		--response code is 200 OK
		http_response_code = "200 OK"
		--the content is text
		http_response_content_type = "text/plain"
	--if the call was not OK
	else
		--send 409 Conflict (can be more specific)
		http_response_code = "409 Conflict"
		--if there is an answer
		if answer then
			--put it in the body; the content type is "text/plain"
			http_response_body = answer
			http_response_content_type = "text/plain"
		end
	end

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":handle_http_message: answer was encoded. elapsed_time="..(misc.time() - start_time).."\n")

	--constructs the HTTP message's first line
	local http_response = "HTTP/1.1 "..http_response_code.."\r\n"
	--if there is a response body
	if http_response_body then
		--concatenates headers "Content-Length" and "Content-Type" describing the body
		http_response = http_response..
			"Content-Length: "..#http_response_body.."\r\n"..
			"Content-Type: "..http_response_content_type.."\r\n\r\n"..http_response_body
	--else
	else
		--closes the HTTP message
		http_response = http_response.."\r\n"
	end

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":handle_http_message: all work is done, ready to send. elapsed_time="..(misc.time() - start_time).."\n")

	--send the HTTP response
	socket:send(http_response)

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":handle_http_message: sent. elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))
end

--function create_distdb_node: makes a node element (IP, port, ID, short ID) from an IP-port tuple
function create_distdb_node(job_node)
		--takes IP address and port from argument job_node
		local n = {ip=job_node.ip, port=job_node.port}
		--calculates the ID by hashing the IP address and port
		n.id = calculate_id(job_node)
		--stores also the first 5 hexadigits of the ID for better printing
		n.short_id = string.sub(n.id, 1, 5)..".."
		--returns the element
		return n
end

--function init: initialization of the node
function init(job)
	--logs entrance
	--l_o:debug("init: START")
	--if init has not been previously called
	if not init_done then
		--make the init_done flag true
		init_done = true

		--if not in SPLAY
		if not job then
			--logs error
			--l_o:error("no job!")
			--returns; TODO for splay. there should be a better way to return on failure
			return
		end

		--takes IP address and port from job.me
		n = {ip=job.me.ip, port=job.me.port}
		--initializes the randomseed with the port
		math.randomseed(n.port)
		--calculates the ID by hashing the IP address and port
		n.id = calculate_id(job.me)
		--stores also the first 5 hexadigits of the ID for better printing
		n.short_id = string.sub(n.id, 1, 5)..".."

		--starts the RPC server for internal communication
		rpc.server(n.port)
		--HTTP server listens through the RPC port+1
		net.server(n.port+1, handle_http_message)

		--initializes DB tables ("db_table" and "key_list")
		local_db.open("db_table", "hash")
		local_db.open("key_list", "hash")

		--initializes variables related to replication; TODO this should be configurable
		n_replicas = 3
		min_replicas_write = 2
		min_replicas_read = 2
		
		--changing pointers of paxos functions
		paxos.send_proposal = send_paxos_proposal
		--receive_paxos_proposal = paxos.receive_proposal
		paxos.send_accept = send_paxos_accept
		--receive_paxos_accept = paxos.receive_accept
		paxos.send_proposal = send_paxos_proposal

		--if Bootstrapping is set
		if _BOOTSTRAPPING then
			--if it is the RDV node
			if job.position == 1 then
				--prints message saying it is the RDV node
				l_o:print("RDV node HTTP port = "..n.ip.." "..(n.port+1))
				--neighborhood is only itself
				neighborhood = {n}
			--if we skip bootstrapping
			else
				local job_nodes = job.nodes
				local rdv_busy = true
				local ok1, answer1
				--waits while the RDV node is gossiping the inclusion of other nodes along the ring
				while rdv_busy do
					--waits for random(0.2-0.4) sec
					events.sleep(0.2 + (math.random(20)/100))
					--asks the RDV if it's busy gossiping
					ok1, answer1 = rpc.acall({ip=job_nodes[1].ip, port=(job_nodes[1].port+2)}, {"distdb.is_gossiping"})
					--if answer is not OK, we keep trying
					if not ok1 then
						rdv_busy = true
					--if answer is OK, rdv_busy is = what the RDV answered
					else
						rdv_busy = answer1[1]
					end
				end
				--makes RPC call "add_me" to RDV node
				neighborhood = rpc.call(job_nodes[1], {"distdb.add_me", n})
			end

			--gets the position from the neighborhood table
			n.position = get_position()
			--calculates the next node
			next_node = get_next_node()
			--calculates the previous node
			previous_node = get_previous_node()

			--create a gossip to announce the adding
			gossip_changes("add", n)
		else
			--if it is the RDV node
			if job.position == 1 then
				--prints the HTTP port in the log
				l_o:print("RDV node HTTP port = "..n.ip.." "..(n.port+1))
			end
			
			--creates the neighborhood table from job.nodes
			local job_nodes = job.nodes
			for i,v in ipairs(job_nodes) do
				table.insert(neighborhood, create_distdb_node(v))
			end
			
			--orders the table neighborhood by ID
			table.sort(neighborhood, function(a,b) return a.id<b.id end)

			--gets the position from the neighborhood table
			n.position = get_position()
			--calculates the next node
			next_node = get_next_node()
			--calculates the previous node
			previous_node = get_previous_node()

		end

		--if pinging is activated
		if _PINGING then
			--sleeps for 30 seconds
			events.sleep(30)
			--starts a 5 second periodic pinging to the next node of the ring
			events.periodic(ping_period, ping_others)
		end
	end
end

--function stop: stops both servers (RPC and HTTP)
function stop()
	net.stop_server(n.port+1)
	rpc.stop_server(n.port)
end

--function consistent_put: puts a k,v and waits until all the replicas assure they have a copy; TODO this code can be merged with "evtl_consistent" by setting min_replicas to the total
function consistent_put(key, value)
	--logs entrance
	--l_o:debug(n.short_id..":consistent_put: START, for key=", shorten_id(key))
	--l_o:debug(n.short_id..":consistent_put: value=", value)
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":consistent_put: key="..shorten_id(key).." START. elapsed_time=0\n"}

	--initializes boolean not_responsible
	local not_responsible = true
	--gets the master for the key
	local master_node = get_master(key)
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." Master node is retrieved. elapsed_time="..(misc.time() - start_time).."\n")
	--if the node is not the master
	if master_node.id ~= n.id then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success=false(wrong_node). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns with error
		return false, "wrong node"
	end
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." Lookup to see if im responsible finished. elapsed_time="..(misc.time() - start_time).."\n")

	--TODO consider min replicas > neighborhood

	--if the key is locked
	if false and locked_keys[key] then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success=false(locked_key). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns with error
		return false, "locked key"
	end

	--initializes the answers as 0
	local answers = 0
	--initializes successful as false
	local successful = false
	--locks the key during the put
	locked_keys[key] = true
	--gets all responsibles for the key
        local responsibles = get_responsibles(key)
	--puts the key locally; TODO maybe this can change to a sequential approach: first node itself
	events.thread(function()
		local put_local_result
		--logs
		--l_o:debug(n.short_id..":consistent_put: value_type=", type(value))
		--if there's a value to put
		if value then
			--timestamp logging
			--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." Local put done, value size="..string.len(value))
			--makes a put_local
			put_local_result = put_local(key, value, n)
		--if value is nil
		else
			--timestamp logging
			--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." Local put done, it's a delete")
			--makes a delete_local
			put_local_result = delete_local(key)
		end
			--timestamp logging
		--table.insert(to_report_t, ". elapsed_time="..(misc.time() - start_time).."\n")
			--if the "put" action is successful
		if put_local_result then
			--increment answers
			answers = answers + 1
			--if answers reaches the number of replicas
			if answers >= n_replicas then
				--trigger the unlocking of the key
				events.fire(key)
			end
		end
	end)
	--for all responsibles; TODO this can be merged and only de diff part be separated (put the if v.id ~= n.id just before "if value == nil")
	for i,v in ipairs(responsibles) do
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." Starting the loop for "..v.id..". elapsed_time="..(misc.time() - start_time).."\n")
		--if node ID is not the same as the node itself (avoids RPC calling itself)
		if v.id ~= n.id then
			--executes in parallel
			events.thread(function()
				local rpc_ok, rpc_answer
				--timestamp logging
				--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." Gonna do put in "..v.id..". elapsed_time="..(misc.time() - start_time).."\n")
				--if there's a value to put
				if value then
					--makes RPC call to put_local
					rpc_ok, rpc_answer = rpc.acall(v, {"distdb.put_local", key, value, n})
				--if value is nil
				else
					--makes RPC call to delete_local
					rpc_ok, rpc_answer = rpc.acall(v, {"distdb.delete_local", key})
				end
					--timestamp logging
				--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." Put in "..v.id.." done. elapsed_time="..(misc.time() - start_time).."\n")
					--if the RPC call was OK
				if rpc_ok then
					if rpc_answer[1] then
						--increments answers
						answers = answers + 1
						--if answers reaches the minimum number of replicas that must write
						if answers >= n_replicas then
							--triggers the unlocking of the key
							events.fire(key)
						end
					end
				--else (maybe network problem, dropped message) TODO also consider timeouts!
				else
					--logs the error
					--l_o:error(n.short_id..":consistent_put: SOMETHING WENT WRONG ON THE RPC CALL PUT_LOCAL TO NODE="..v.short_id)
				end
			end)
		end
	end
	--waits until min_write replicas answer, or until the rpc_timeout is depleted; TODO match rpc_timeout with settings
	successful = events.wait(key, rpc_timeout)
	--unlocks the key
	locked_keys[key] = nil

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":consistent_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success="..tostring(successful)..". elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))

	--returns the value of the variable successful
	return successful
end

--function evtl_consistent_put: puts a k,v and waits until a minimum of the replicas assure they have a copy
function evtl_consistent_put(key, value)
	--logs entrance
	--l_o:debug(n.short_id..":evtl_consistent_put: START, for key=", shorten_id(key))
	--l_o:debug(n.short_id..":evtl_consistent_put: value=", value)
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":evtl_consistent_put: key="..shorten_id(key).." START. elapsed_time=0\n"}
	
	--initializes boolean not_responsible
	local not_responsible = true
	--gets all responsibles for the key
	local responsibles = get_responsibles(key)
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." Responsible nodes are retrieved. elapsed_time="..(misc.time() - start_time).."\n")
	--for all responsibles
	for i,v in ipairs(responsibles) do
		--if the ID of the node matches, make not_responsible false
		if v.id == n.id then
			not_responsible = false
			break
		end
	end
	--if the node is not responsible
	if not_responsible then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success=false(wrong_node). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns with error
		return false, "wrong node"
	end
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." Lookup to see if im responsible finished. elapsed_time="..(misc.time() - start_time).."\n")

	--TODO consider min replicas > neighborhood

	--if the key is locked
	if false and locked_keys[key] then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success=false(locked_key). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns with error
		return false, "locked key"
	end

	--initialize the answers as 0
	local answers = 0
	--initialize successful as false
	local successful = false
	--locks the key during the put
	locked_keys[key] = true
	--puts the key locally; TODO maybe this can change to a sequential approach: first node itself
	--checks the version and writes the k,v, then it writes to others
	events.thread(function()
		local put_local_result
		--if there's a value to put
		if value then
			--timestamp logging
			--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." Local put done, value size="..string.len(value))
			--calls put_local
			put_local_result = put_local(key, value, n)
		--if value is nil
		else
			--timestamp logging
			--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." Local put done, it's a delete")
			--calls delete_local
			put_local_result = delete_local(key)
		end
			--timestamp logging
		--table.insert(to_report_t, ". elapsed_time="..(misc.time() - start_time).."\n")
			--if the "put" action is successful
		if put_local_result then
			--increment answers
			answers = answers + 1
			--if answers reaches the minimum number of replicas that must write
			if answers >= min_replicas_write then
				--trigger the unlocking of the key
				events.fire(key)
			end
		end
	end)
	--for all responsibles
	for i,v in ipairs(responsibles) do
		--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." starting the loop for "..v.id..". elapsed_time="..(misc.time() - start_time).."\n")
		--if node ID is not the same as the node itself (avoids RPC calling itself)
		if v.id ~= n.id then
			--executes in parallel
			events.thread(function()
				local rpc_ok, rpc_answer
				--timestamp logging
				--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." gonna do put in "..v.id..". elapsed_time="..(misc.time() - start_time).."\n")
				--if there's a value to put
				if value then
					--makes RPC call to put_local
					rpc_ok, rpc_answer = rpc.acall(v, {"distdb.put_local", key, value, n})
				--if value is nil
				else
					--makes RPC call to delete_local
					rpc_ok, rpc_answer = rpc.acall(v, {"distdb.delete_local", key})
				end
					--timestamp logging
				--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." put in "..v.id.." done. elapsed_time="..(misc.time() - start_time).."\n")
					--if the RPC call was OK
				if rpc_ok then
					if rpc_answer[1] then
						--increments answers
						answers = answers + 1
						--if answers reaches the minimum number of replicas that must write
						if answers >= min_replicas_write then
							--triggers the unlocking of the key
							events.fire(key)
						end
					end
				--else (maybe network problem, dropped message) TODO also consider timeouts!
				else
					--logs the error
					--l_o:error(n.short_id..":evtl_consistent_put: SOMETHING WENT WRONG ON THE RPC CALL PUT_LOCAL TO NODE="..v.short_id)
				end
			end)
		end
	end
	--waits until min_write replicas answer, or until the rpc_timeout is depleted; TODO match rpc_timeout with settings
	successful = events.wait(key, rpc_timeout)
	--unlocks the key
	locked_keys[key] = nil

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":evtl_consistent_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success="..tostring(successful)..". elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))

	--returns the value of the variable successful
	return successful
end

--function paxos_put: performs a Basic Paxos protocol in order to put a k,v pair
function paxos_put(key, value)
	--logs entrance
	--l_o:debug(n.short_id..":paxos_put: START, for key=", shorten_id(key))
	--l_o:debug(n.short_id..":paxos_put: value=", value)
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":paxos_put: key="..shorten_id(key).." START. elapsed_time=0\n"}
	
	--initializes boolean not_responsible
	local not_responsible = true
	--gets all responsibles for the key
	local responsibles = get_responsibles(key)
	--for all responsibles
	for i,v in ipairs(responsibles) do
		--if the ID of the node matches, make not_responsible false
		if v.id == n.id then
			not_responsible = false
			break
		end
	end
	--if the node is not responsible
	if not_responsible then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":paxos_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success=false(wrong_node). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns with error
		return false, "wrong node"
	end

	--if the key is being modified right now
	if false and locked_keys[key] then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":paxos_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success=false(locked_key). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns with error
		return false, "locked key"
	end

	--locks the key; TODO check if this is necessary
	locked_keys[key] = true
	--if no previous proposals have been done for this key; TODO why does it always start with 1???
	if not prop_ids[key] then
		--first number to use is 1
		prop_ids[key] = 1
	end
	--logs
	--l_o:debug(n.short_id..":paxos_put:key=", shorten_id(key), "propID="..prop_ids[key])
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":paxos_put: key="..shorten_id(key).." Before calling paxos_write. elapsed_time="..(misc.time() - start_time).."\n")
	--performs a paxos_write operation
	local ok, answer = paxos.paxos_write(prop_ids[key], responsibles, paxos_max_retries, value, key)
	--unlocks the key
	locked_keys[key] = false

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":paxos_put: key="..shorten_id(key).." END value_sz="..tostring(value and value:len()).." success=true. elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))

	--returns the answer of paxos_operation
	return ok, answer
end

--function consistent_get: returns the value of a certain key; reads the value only from the node itself (matches with
-- the behavior of consistent_put, where all replicas write always all values)
function consistent_get(key)
	--logs entrance
	--l_o:debug(n.short_id..":consistent_get: START, for key="..shorten_id(key))
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":consistent_get: key="..shorten_id(key).." START. elapsed_time=0\n"}

	--gets the responsibles of the key
	local responsibles = get_responsibles(key)
	--for all responsibles
	for i,v in ipairs(responsibles) do
		--if the node ID is the same as the ID of the node itself
		if v.id == n.id then
			--timestamp logging
			--table.insert(to_report_t, n.short_id..":consistent_get: key="..shorten_id(key).." END success=true. elapsed_time="..(misc.time() - start_time))
			--flushes all timestamp logs
			--l_o:notice(table.concat(to_report_t))
			--returns the value of the key
			return true, {get_local(key)}
		end
	end
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":consistent_get: key="..shorten_id(key).." END success=false(wrong_node). elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))

	--if none of the responsible matched IDs with the node itself, returns with error message
	return false, "wrong node"
end

--function evtl_consistent_get: returns the value of a certain key; reads the value from a minimum of replicas
function evtl_consistent_get(key)
	--logs entrance
	--l_o:debug(n.short_id..":evtl_consistent_get: START, for key=", shorten_id(key))
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":evtl_consistent_get: key="..shorten_id(key).." START. elapsed_time=0\n"}

	--initializes not_responsible as false
	local not_responsible = true
	--gets the responsibles of the key
	local responsibles = get_responsibles(key)
	--for all responsibles
	for i,v in ipairs(responsibles) do
		--if the node ID is the same as the ID of the node itself
		if v.id == n.id then
			--not_responsible is false
			not_responsible = false
			--breaks the "for" loop
			break
		end
	end
	--if the node is not one of the responsibles
	if not_responsible then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":evtl_consistent_get: key="..shorten_id(key).." END success=false(wrong_node). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns false with an error message
		return false, "wrong node"
	end

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":evtl_consistent_get: key="..shorten_id(key).." Im a responsible. elapsed_time="..(misc.time() - start_time).."\n")

	--initializes variables
	local answers = 0
	local answer_data = {}
	local return_data = {}
	local latest_vector_clock = {}
	local successful = false
	--for all the responsibles
	for i,v in ipairs(responsibles) do
		--executes in parallel
		events.thread(function()
			--if the ID is the same as the node itself
			if v.id == n.id then
				--gets the value locally; TODO deal with attemps of writing a previous version
				answer_data[v.id] = get_local(key)
			--if it is not the same ID as the node
			else
				--gets the value remotely with an RPC call
				local rpc_ok, rpc_answer = rpc.acall(v, {"distdb.get_local", key})
				--if the RPC call was OK
				if rpc_ok then
					answer_data[v.id] = rpc_answer[1]
				--else (maybe network problem, dropped message) TODO also consider timeouts!
				else
					--logs the error
					--l_o:error(n.short_id..":evtl_consistent_get: SOMETHING WENT WRONG ON THE RPC CALL GET_LOCAL TO NODE="..v.short_id)
				end
			end
			--timestamp logging
			--table.insert(to_report_t, n.short_id..":evtl_consistent_get: key="..shorten_id(key).." Get on "..v.short_id.."done. elapsed_time="..(misc.time() - start_time).."\n")
			--if there is an answer
			if answer_data[v.id] then
				--logs
				--l_o:debug(n.short_id..":evtl_consistent_get: received from node=", v.short_id, "key=", shorten_id(key), "enabled=", answer_data[v.id].enabled)
				--l_o:debug(n.short_id..":evtl_consistent_get: value=", answer_data[v.id].value)
				for i2,v2 in pairs(answer_data[v.id].vector_clock) do
					--l_o:debug(n.short_id..":evtl_consistent_get: vector_clock=",i2,v2)
				end
				--increments answers
				answers = answers + 1
				--if answers reaches the minimum number of replicas that must read
				if answers >= min_replicas_read then
					--triggers the unlocking of the key
					events.fire(key)
				end
			end
		end)
	end
	--waits until min_read replicas answer, or until the rpc_timeout is depleted; TODO match rpc_timeout with settings
	successful = events.wait(key, rpc_timeout)
	--if it is not a successful read
	if not successful then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":evtl_consistent_get: key="..shorten_id(key).." END success=false(timeout). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns with an error message
		return false, "timeout"
	end
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":evtl_consistent_get: key="..shorten_id(key).." Get successful. elapsed_time="..(misc.time() - start_time).."\n")
	--initializes the comparison table for vector clocks
	local comparison_table = {}
	--for all answers
	for i,v in pairs(answer_data) do
		comparison_table[i] = {}
		--for all answers (compare all against all)
		for i2,v2 in pairs(answer_data) do
			comparison_table[i][i2] = 0
			--if the IDs to be compared are different
			if i2 ~= i then
				--l_o:debug(n.short_id..":evtl_consistent_get: comparing "..i.." and "..i2)
				--checks whether the comparison was already done
				local do_comparison = false
				if not comparison_table[i2] then
					do_comparison = true
				elseif not comparison_table[i2][i] then
					do_comparison = true
				end
				--if the comparison was not yet made
				if do_comparison then
					--initializes the merged clock vector
					local merged_vector = {}
					--writes first the first vector to be merged as the winner (max = 1)
					for i3,v3 in pairs(v.vector_clock) do
						merged_vector[i3] = {value=v3, max=1}
						--logs
						--l_o:debug(i3, v3)
					end
					--logs
					--l_o:debug(n.short_id..":evtl_consistent_get: then "..i2)
					--then, for all elements of the second vector
					for i4,v4 in pairs(v2.vector_clock) do
						--logs
						--l_o:debug(i4, v4)
						--if there is already an element like this in the vector
						if merged_vector[i4] then
							--compares both, if the second is bigger, max is 2
							if v4 > merged_vector[i4].value then
								merged_vector[i4] = {value=v4, max=2}
							--if they are equal, max is 0 (draw)
							elseif v4 == merged_vector[i4].value then
								merged_vector[i4].max = 0
							end
						--if there was no element, it just adds it to the vector with max = 2
						else
							merged_vector[i4] = {value=v4, max=1}
						end
					end
					--goes through the whole merged vector
					for i5,v5 in pairs(merged_vector) do
						--logs
						--l_o:debug(n.short_id..":evtl_consistent_get: merged_vector["..i5.."]= value=", v5.value, "max=", v5.max)
						--rules: if all elements are =1 or 0, the first is fresher
						-- if all elements are =2 or 0, the second is fresher
						-- if all are equal, vectors are equal
						-- if some are 2 and some are 1, nothing can be said (comparison_table=3)
						if v5.max == 1 then
							if comparison_table[i][i2] == 0 then
								comparison_table[i][i2] = 1
							elseif comparison_table[i][i2] == 2 then
								comparison_table[i][i2] = 3
							end
						elseif v5.max == 2 then
							if comparison_table[i][i2] == 0 then
								comparison_table[i][i2] = 2
							elseif comparison_table[i][i2] == 1 then
								comparison_table[i][i2] = 3
							end
						end
					end
				end
				--logs
				--l_o:debug(n.short_id..":evtl_consistent_get: comparison_table=", comparison_table[i][i2])
			end
		end
	end
	--for all comparisons
	for i,v in pairs(comparison_table) do
		for i2,v2 in pairs(v) do
			--if the comparison == 1, deletes the second answer
			if v2 == 1 then
				answer_data[i2] = nil
				--logs
				--l_o:debug(n.short_id..":evtl_consistent_get: deleting answer from "..i2.." because "..i.." is fresher")
			--if the comparison == 2 or 0, deletes the first answer; TODO missing the or v2 == 0, try with 0 (equal vectors)
			elseif v2 == 2 then
				answer_data[i] = nil
				--logs
				--l_o:debug(n.short_id..":evtl_consistent_get: deleting answer from "..i.." because "..i2.." is fresher")
			end
		end
	end
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":evtl_consistent_get: key="..shorten_id(key).." Comparisons done. elapsed_time="..(misc.time() - start_time).."\n")
	--insert the info in the return data
	for i,v in pairs(answer_data) do
		--logs
		--l_o:debug(n.short_id..":evtl_consistent_get: remaining answer=", i)
		--l_o:debug(n.short_id..":evtl_consistent_get: value=", v.value)
		table.insert(return_data, v)
	end
	
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":evtl_consistent_get: key="..shorten_id(key).." END success=true. elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))

	--returns
	return true, return_data
end

--function paxos_get: performs a Basic Paxos protocol in order to get v from a k,v pair
function paxos_get(key)
	--logs entrance
	--l_o:debug(n.short_id..":paxos_get: START, for key=", shorten_id(key))
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":paxos_get: key="..shorten_id(key).." START. elapsed_time=0\n"}

	--initializes boolean not_responsible
	local not_responsible = true
	--gets all responsibles for the key
	local responsibles = get_responsibles(key)
	--for all responsibles
	for i,v in ipairs(responsibles) do
		--if the ID of the node matches, make not_responsible false
		if v.id == n.id then
			not_responsible = false
			break
		end
	end
	--if the node is not one of the responsibles
	if not_responsible then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":paxos_get: key="..shorten_id(key).." END success=false(wrong_node). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns with error message
		return false, "wrong node"
	end

	--if the key is being modified right now
	if false and locked_keys[key] then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":paxos_get: key="..shorten_id(key).." END success=false(locked_key). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--returns with error message
		return false, "locked key"
	end

	--locks the key; TODO check if this is necessary
	locked_keys[key] = true
	--if no previous proposals have been done for this key; TODO why does it always start with 1???
	if not prop_ids[key] then
		--first number to use is 1
		prop_ids[key] = 1
	end
	--logs
	--l_o:debug(n.short_id..":paxos_get: key=", shorten_id(key), "propID=", prop_ids[key])
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":paxos_get: key="..shorten_id(key).." Before calling paxos_read. elapsed_time="..(misc.time() - start_time).."\n")
	--performs a paxos_read operation
	local ok, answer = paxos.paxos_read(prop_ids[key], responsibles, paxos_max_retries, key)
	--unlocks the key
	locked_keys[key] = false

	--table.insert(to_report_t, n.short_id..":paxos_get: key="..shorten_id(key).." END success=true. elapsed_time="..(misc.time() - start_time))
	--l_o:notice(table.concat(to_report_t))
	--returns the answer of paxos_operation
	return ok, answer
end



--REPLACEMENTS OF PAXOS FUNCTIONS
--function send_paxos_proposal:
function send_paxos_proposal(v, prop_id, key)
	--logs entrance
	--l_o:debug(n.short_id..":send_paxos_proposal: START, for node=", shorten_id(v.id), "key=", shorten_id(key), "propID=", prop_id)
	return rpc.acall(v, {"distdb.receive_paxos_proposal", prop_id, key})
end

--function send_paxos_accept:
function send_paxos_accept(v, prop_id, peers, value, key)
	--logs entrance
	--l_o:debug(n.short_id..":send_paxos_accept: START, for node=", shorten_id(v.id), "key=", shorten_id(key), "propID=", prop_id)
	--l_o:debug(n.short_id..":send_paxos_accept: value=", value)
	for i2,v2 in ipairs(peers) do
		--l_o:debug(n.short_id..":send_paxos_accept: peers: node="..shorten_id(v2.id))
	end
	return rpc.acall(v, {"distdb.receive_paxos_accept", prop_id, peers, value, key})
end

--function send_paxos_learn: replaces paxos.send_learn
function send_paxos_learn(v, value, key)
	--logs entrance
	--l_o:debug(n.short_id..":send_paxos_learn: START, for node=", shorten_id(v.id), "key=", shorten_id(key))
	--l_o:debug(n.short_id..":send_paxos_learn: value=",value)
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":send_paxos_learn: key="..shorten_id(key).." START. elapsed_time=0\n"}
	
	local ret_put_local
	--if there's a value to put
	if value then
		--makes RPC call to put_local
		ret_put_local = rpc.call(v, {"distdb.put_local", key, value})
	--if value is nil
	else
		--makes RPC call to delete_local
		ret_put_local = rpc.call(v, {"distdb.delete_local", key})
	end

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":send_paxos_learn: key="..shorten_id(key).." END success=true. elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))

	--returns
	return ret_put_local
end

--function receive_paxos_proposal:
function receive_paxos_proposal(prop_id, key)
	--logs entrance
	--l_o:debug(n.short_id..":receive_paxos_proposal: START, for key=", shorten_id(key), ", propID=", prop_id)
	
	--probability of having a fail (for testing purposes)
	if math.random(100) < sim_fail_rate then
		--logs
		--l_o:notice(n.short_id..":receive_paxos_proposal: RANDOMLY NOT accepting Propose for key=", shorten_id(key))
		--returns false
		return false
	end

	--if delay simulation is activated
	if sim_delay then
		--adds a random waiting time to simulate different response times
		events.sleep(math.random(100)/100)
	end

	--if key is not a string, dont accept the transaction
	if type(key) ~= "string" then
		--l_o:notice(n.short_id..":receive_paxos_proposal: NOT accepting Propose for key, wrong key type")
		return false, "wrong key type"
	end

	--if the k,v pair doesnt exist --BIG TODO: WHEN USING RAM DB, I SHOULD NOT SERIALIZE, IT'S A WASTE OF TIME
	local kv_record_serialized = local_db.get("db_table", key)
	local kv_record
	if kv_record_serialized then
		kv_record = serializer.decode(kv_record_serialized)
	end
	--creates it with a new vector clock, enabled=true
	if not kv_record then
		kv_record = {enabled=true, vector_clock={}}
	--if it exists and if prop_id is bigger than the proposed
	elseif kv_record.prop_id and kv_record.prop_id >= prop_id then
		--returns false, the proposalID and the KV record; TODO maybe to send the value on a negative answer is not necessary. CHECK IF I CAN JUST PUT THE VALUE
		return false, kv_record.prop_id, kv_record
	end
	--replaces the proposal ID
	local old_prop_id = kv_record.prop_id
	kv_record.prop_id = prop_id

	--writes the new proposal ID in the DB
	local_db.set("db_table", key, serializer.encode(kv_record))
	
	--returns the old Proposal ID and the KV record
	return true, old_prop_id, kv_record
end

--function receive_paxos_accept: replaces paxos.receive_accept
function receive_paxos_accept(prop_id, peers, value, key)
	--logs entrance
	--l_o:debug(n.short_id..":receive_paxos_accept: START, for key=", shorten_id(key), "propID=", prop_id)
	--l_o:debug(n.short_id..":receive_paxos_accept: value=", value)
	
	--if delay simulation is activated
	if sim_delay then
		--adds a random waiting time to simulate different response times
		events.sleep(math.random(100)/100)
	end

	--if key is not a string
	if type(key) ~= "string" then
		--logs
		--l_o:error(n.short_id..":receive_paxos_accept: NOT accepting Accept! wrong key type")
		--returns with error message
		return false, "wrong key type"
	end

	local kv_record_serialized = local_db.get("db_table", key)
	local kv_record
	if kv_record_serialized then
		kv_record = serializer.decode(kv_record_serialized)
	end

	--if the k,v pair doesnt exist
	if not kv_record then
		--BIZARRE: because this is not meant to happen (an Accept comes after a Propose, and a record for the key
		-- is always created at a Propose)
		--logs
		--l_o:error(n.short_id..":receive_paxos_accept: BIZARRE! wrong key=", shorten_id(key), ", key does not exist")
		--returns with error message
		return false, "BIZARRE! wrong key, key does not exist"
	end
	
	--if it exists, and the locally stored prop_id is bigger than the proposed prop_id
	if kv_record.prop_id > prop_id then
		--logs
		--l_o:error(n.short_id..":receive_paxos_accept: REJECTED, higher prop_id")
		--returns with error message
		return false, "higher prop_id"
	end

	--if the locally stored prop_id is smaller than the proposed prop_id
	if kv_record.prop_id < prop_id then
		--BIZARRE: again, Accept comes after Propose, and a later Propose can only increase the prop_id
		--logs
		--l_o:error(n.short_id..":receive_paxos_accept: BIZARRE! lower prop_id")
		--returns with error message
		return false, "BIZARRE! lower prop_id"
	end

	--logs
	--l_o:debug(n.short_id..":receive_paxos_accept: Telling learners about key=", shorten_id(key), "enabled=", kv_record.enabled, "propID=", prop_id)
	--l_o:debug(n.short_id..":receive_paxos_accept: value=", value)
	--for all peers
	for i,v in ipairs(peers) do
		--executes in parallel
		events.thread(function()
			--if it is the same node
			if v.id == n.id then
				--if there's a value to put
				if value then
					--calls put_local; TODO can we put n for src_write?
					put_local(key, value)
				--if value is nil
				else
					--calls delete_local
					delete_local(key)
				end
			--if it's not the same node
			else
				--TODO Normally this will be replaced in order to not make a WRITE in RAM/Disk everytime an Acceptor
				--orders a Learner to learn the value
				send_paxos_learn(v, value, key)
			end
		end)
	end

	--returns
	return true
end


--BACK-END FUNCTIONS

--function put_local: writes a k,v pair; TODO should be atomic? is it?
function put_local(key, value, src_write)
	--logs entrance
	--l_o:debug(n.short_id..":put_local: START, for key=", shorten_id(key))
	--l_o:debug(n.short_id..":put_local: value=", value)
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":put_local: key="..shorten_id(key).." START. elapsed_time=0\n"}

	--TODO how to check if the source node is valid?

	--probability of having a fail (for testing purposes)
	if math.random(100) < sim_fail_rate then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":put_local: key="..shorten_id(key).." END success=false(on_purpose). elapsed_time="..(misc.time() - start_time))
		--flushes all timestamp logs
		--l_o:notice(table.concat(to_report_t))
		--logs
		--l_o:debug(n.short_id..":put_local: RANDOMLY NOT writing key: "..key)
		--returns with error message
		return false, "404"
	end

	--if delay simulation is activated
	if sim_delay then
		--adds a random waiting time to simulate different response times
		events.sleep(math.random(100)/100)
	end

	--if key is not a string, dont accept the transaction
	if type(key) ~= "string" then
		--l_o:error(n.short_id..":put_local: NOT writing key, wrong key type")
		--table.insert(to_report_t, n.short_id..":put_local: key="..shorten_id(key).." END success=false(wrong_key_type). elapsed_time="..(misc.time() - start_time))
		--l_o:notice(table.concat(to_report_t))
		return false, "wrong key type"
	end

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":put_local: check key type done. elapsed_time="..(misc.time() - start_time).."\n")

	--if value is not a string or a number, dont accept the transaction
	if type(value) ~= "string" and type(value) ~= "number" then
		--l_o:error(n.short_id..":put_local: NOT writing key, wrong value type")
		--table.insert(to_report_t, n.short_id..":put_local: UNsuccessful END. elapsed_time="..(misc.time() - start_time))
		--l_o:notice(table.concat(to_report_t))
		return false, "wrong value type"
	end

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":put_local: check value type done. elapsed_time="..(misc.time() - start_time).."\n")

	--if the source is not specified
	if not src_write then
		--writes "version" as the ID, for compatibility with paxos_put
		src_write = {id="version"}
	end

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":put_local: setting up src_write when there isnt done. elapsed_time="..(misc.time() - start_time).."\n")

	local kv_record_serialized = local_db.get("db_table", key)
	local kv_record
	if kv_record_serialized then
		kv_record = serializer.decode(kv_record_serialized)
	end

	--if the k,v pair doesnt exist, creates it with a new vector clock, enabled=true
	if not kv_record then
		kv_record = {enabled=true, vector_clock={}}
	end
	--replaces the value and increases the version
	kv_record.value=value
	kv_record.vector_clock[src_write.id] = (kv_record.vector_clock[src_write.id] or 0)+ 1

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":put_local: k,v record written. elapsed_time="..(misc.time() - start_time).."\n")

	--serializes the KV record
	local kv_record_serialized = serializer.encode(kv_record)

	--logs
	--l_o:debug(n.short_id..":put_local: type(key)=", type(key), "type(kv_record_serialized)=", type(kv_record_serialized))

	--writes the record
	local set_ok = local_db.set("db_table", key, kv_record_serialized)
	local_db.set("key_list", key, 1)

	--logs
	--l_o:debug(n.short_id..":put_local: writing key=", shorten_id(key), "enabled=", kv_record.enabled, "writing was ok?", set_ok)
	--l_o:debug(n.short_id..":put_local: value=", value)
	for i,v in pairs(kv_record.vector_clock) do
		--l_o:debug(n.short_id..":put_local: vector_clock=",i,v)
	end
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":put_local: key="..shorten_id(key).." END success=true. elapsed_time="..(misc.time() - start_time))
	--flushes all timestamp logs
	--l_o:notice(table.concat(to_report_t))

	--returns
	return true
end

--function delete_local: deletes a k,v pair; TODO Consider this effing src_write and if the data is ever deleted; NOTE enabled is a field meant to handle this
function delete_local(key, src_write) 
	--logs entrance
	--l_o:debug(n.short_id..":delete_local: START, for key=", shorten_id(key))
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":delete_local: key="..shorten_id(key).." START. elapsed_time=0\n"}
	
	--probability of having a fail (for testing purposes)
	if math.random(100) < sim_fail_rate then
		--logs
		--l_o:debug(n.short_id..": NOT writing key: "..key)
		--returns with error message
		return false, "404"
	end

	--if a delay is simulated
	if sim_delay then
		--adds a random waiting time to simulate different response times
		events.sleep(math.random(100)/100)
	end

	--if key is not a string, dont accept the transaction
	if type(key) ~= "string" then
		--logs
		--l_o:error(n.short_id..":delete_local: NOT writing key, wrong key type")
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":delete_local: key="..shorten_id(key).." END success=false(wrong_key_type). elapsed_time="..(misc.time() - start_time))
		--l_o:notice(table.concat(to_report_t))
		--returns with error message
		return false, "wrong key type"
	end
	
	--if the k,v pair exists, delete it; TODO maybe can be improved with only db:remove, just 1 DB op
	if local_db.check("db_table", key) ~= -1 then
		local_db.remove("db_table", key)
		local_db.remove("key_list", key)
	end
	--logs
	--l_o:debug(n.short_id..":delete_local: deleting key="..shorten_id(key))
	--timestamp logging
	--table.insert(to_report_t, n.short_id..":delete_local: key="..shorten_id(key).." END success=true. elapsed_time="..(misc.time() - start_time))
	--l_o:notice(table.concat(to_report_t))
	--returns true
	return true
end

--function get_local: returns v from a k,v pair.
function get_local(key)
	--logs entrance
	--l_o:debug(n.short_id..":get_local: START, for key="..shorten_id(key))
	--timestamp logging
	--local start_time = misc.time()
	--local to_report_t = {n.short_id..":get_local: key="..shorten_id(key).." START. elapsed_time=0\n"}

	--probability of having a fail (for testing purposes)
	if math.random(100) < sim_fail_rate then
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":get_local: key="..shorten_id(key).." END success=false(on_purpose). elapsed_time="..(misc.time() - start_time))
		--l_o:notice(table.concat(to_report_t))
		--returns nil
		return nil
	end

	--if delay is simulated
	if sim_delay then
		--adding a random waiting time to simulate different response times
		events.sleep(math.random(100)/100)
	end

	--retrieves the serialized version of the record
	local kv_record_serialized = local_db.get("db_table", key)
	--if there's no record
	if not kv_record_serialized then
		--logs error
		--l_o:error(n.short_id..":get_local: record is nil")
		--timestamp logging
		--table.insert(to_report_t, n.short_id..":get_local: key="..shorten_id(key).." END success=false. elapsed_time="..(misc.time() - start_time))
		--l_o:notice(table.concat(to_report_t))
		--returns nil
		return nil
	end

	--timestamp logging
	--table.insert(to_report_t, n.short_id..":get_local: key="..shorten_id(key).." END success=true. elapsed_time="..(misc.time() - start_time))
	--l_o:notice(table.concat(to_report_t))
	--returns the record as table
	return serializer.decode(kv_record_serialized)
end


if #arg < 5 then
	print("Usage: "..arg[0].." <IP prefix> <node1 IP last octect> <RPC port> <n_nodes> <my_position>")
	os.exit()
end

local arg_ip_prefix = arg[1]
local arg_node1_end = tonumber(arg[2])
local arg_port = tonumber(arg[3])
local arg_n_nodes = tonumber(arg[4])
local arg_my_pos = tonumber(arg[5])

local job = {
	me = {
		ip = arg_ip_prefix.."."..(arg_node1_end + arg_my_pos - 1),
		port = arg_port
	},
	position = arg_my_pos,
	nodes = {
	}
}

for i = 1, arg_n_nodes do
	table.insert(job.nodes, {ip = arg_ip_prefix.."."..(arg_node1_end + i - 1), port = arg_port})
end

dofile("../../../misc/logger.lua")

local logfile = "<print>"
local logrules = {
}
local logbatching = false
local global_details = true
local global_timestamp = false
local global_elapsed = false

init_logger(logfile, logrules, logbatching, global_details, global_timestamp, global_elapsed)

--print(tbl2str("job", 0, job))

events.run(function()
	init(job)
end)

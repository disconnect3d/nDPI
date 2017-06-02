--
-- (C) 2017 - ntop.org
--
-- This plugin is part of nDPI (https://github.com/ntop/nDPI)
--
--


local ndpi_proto = Proto("ndpi", "nDPI", "nDPI Protocol Interpreter")
ndpi_proto.fields = {}
local ndpi_fds = ndpi_proto.fields
ndpi_fds.network_protocol     = ProtoField.new("nDPI Network Protocol", "ndpi.protocol.network", ftypes.UINT8, nil, base.DEC)
ndpi_fds.application_protocol = ProtoField.new("nDPI Application Protocol", "ndpi.protocol.application", ftypes.UINT8, nil, base.DEC)
ndpi_fds.name                 = ProtoField.new("nDPI Protocol Name", "ndpi.protocol.name", ftypes.STRING)

local ntop_proto = Proto("ntop", "ntop", "ntop Extensions")
ntop_proto.fields = {}

local ntop_fds = ntop_proto.fields
ntop_fds.client_nw_rtt    = ProtoField.new("TCP client network RTT (msec)",  "ntop.latency.client_rtt", ftypes.FLOAT, nil, base.NONE)
ntop_fds.server_nw_rtt    = ProtoField.new("TCP server network RTT (msec)",  "ntop.latency.server_rtt", ftypes.FLOAT, nil, base.NONE)
ntop_fds.appl_latency_rtt = ProtoField.new("Application Latency RTT (msec)", "ntop.latency.appl_rtt",   ftypes.FLOAT, nil, base.NONE)

-- local f_eth_trailer    = Field.new("eth.trailer")
local f_dns_query_name    = Field.new("dns.qry.name")
local f_dns_ret_code      = Field.new("dns.flags.rcode")
local f_dns_response      = Field.new("dns.flags.response")
local f_udp_len           = Field.new("udp.length")
local f_tcp_header_len    = Field.new("tcp.hdr_len")
local f_ip_len            = Field.new("ip.len")
local f_ip_hdr_len        = Field.new("ip.hdr_len")

local ndpi_protos            = {}
local ndpi_flows             = {}
local num_ndpi_flows         = 0

local arp_stats              = {}
local mac_stats              = {}
local vlan_stats             = {}
local vlan_found             = false

local dns_responses_ok       = {}
local dns_responses_error    = {}
local dns_client_queries     = {}
local dns_server_responses   = {}
local dns_queries            = {}

local syn                    = {}
local synack                 = {}
local lower_ndpi_flow_id     = 0
local lower_ndpi_flow_volume = 0

local compute_flows_stats    = true
local max_num_entries        = 10
local max_num_flows          = 50

local num_top_dns_queries    = 0
local max_num_dns_queries    = 50

local min_nw_client_RRT      = {}
local min_nw_server_RRT      = {}
local max_nw_client_RRT      = {}
local max_nw_server_RRT      = {}
local min_appl_RRT           = {}
local max_appl_RRT           = {}

local first_payload_ts       = {}
local first_payload_id       = {}

local num_pkts               = 0
local last_processed_packet_number = 0
local max_latency_discard    = 5000 -- 5 sec
local debug                  = false

-- ##############################################

function string.contains(String,Start)
   if type(String) ~= 'string' or type(Start) ~= 'string' then
      return false
   end
   return(string.find(String,Start,1) ~= nil)
end

-- ##############################################

function string.starts(String,Start)
   if type(String) ~= 'string' or type(Start) ~= 'string' then
      return false
   end
   return string.sub(String,1,string.len(Start))==Start
end

-- ##############################################

function string.ends(String,End)
   if type(String) ~= 'string' or type(End) ~= 'string' then
      return false
   end
   return End=='' or string.sub(String,-string.len(End))==End
end

-- ###############################################

function round(num, idp)
   return tonumber(string.format("%." .. (idp or 0) .. "f", num))
end

function formatPctg(p)
   local p = round(p, 1)

   if(p < 1) then return("< 1 %") end

   return p.." %"
end

-- ###############################################

string.split = function(s, p)
  local temp = {}
  local index = 0
  local last_index = string.len(s)

  while true do
    local i, e = string.find(s, p, index)

    if i and e then
      local next_index = e + 1
      local word_bound = i - 1
      table.insert(temp, string.sub(s, index, word_bound))
      index = next_index
    else
      if index > 0 and index <= last_index then
	table.insert(temp, string.sub(s, index, last_index))
      elseif index == 0 then
	temp = nil
      end
      break
    end
  end

  return temp
end

-- ##############################################

function shortenString(name, max_len)
   max_len = max_len or 24
    if(string.len(name) < max_len) then
      return(name)
   else
      return(string.sub(name, 1, max_len).."...")
   end
end

-- ###############################################

-- Convert bytes to human readable format
function bytesToSize(bytes)
   if(bytes == nil) then
      return("0")
   else
      precision = 2
      kilobyte = 1024;
      megabyte = kilobyte * 1024;
      gigabyte = megabyte * 1024;
      terabyte = gigabyte * 1024;

      bytes = tonumber(bytes)
      if((bytes >= 0) and (bytes < kilobyte)) then
	 return round(bytes, precision) .. " Bytes";
      elseif((bytes >= kilobyte) and (bytes < megabyte)) then
	 return round(bytes / kilobyte, precision) .. ' KB';
      elseif((bytes >= megabyte) and (bytes < gigabyte)) then
	 return round(bytes / megabyte, precision) .. ' MB';
      elseif((bytes >= gigabyte) and (bytes < terabyte)) then
	 return round(bytes / gigabyte, precision) .. ' GB';
      elseif(bytes >= terabyte) then
	 return round(bytes / terabyte, precision) .. ' TB';
      else
	 return round(bytes, precision) .. ' Bytes';
      end
   end
end

-- ###############################################

function pairsByValues(t, f)
   local a = {}
   for n in pairs(t) do table.insert(a, n) end
   table.sort(a, function(x, y) return f(t[x], t[y]) end)
   local i = 0      -- iterator variable
   local iter = function ()   -- iterator function
      i = i + 1
      if a[i] == nil then return nil
      else return a[i], t[a[i]]
      end
   end
   return iter
end

-- ###############################################

function asc(a,b) return (a < b) end
function rev(a,b) return (a > b) end

-- ###############################################

local function BitOR(a,b)--Bitwise or
   local p,c=1,0
   while a+b>0 do
      local ra,rb=a%2,b%2
      if ra+rb>0 then c=c+p end
      a,b,p=(a-ra)/2,(b-rb)/2,p*2
   end
   return c
end

local function BitNOT(n)
   local p,c=1,0
   while n>0 do
      local r=n%2
      if r<1 then c=c+p end
      n,p=(n-r)/2,p*2
   end
   return c
end

local function BitAND(a,b)--Bitwise and (portable edition)
   local p,c=1,0
   while a>0 and b>0 do
      local ra,rb=a%2,b%2
      if ra+rb>1 then c=c+p end
      a,b,p=(a-ra)/2,(b-rb)/2,p*2
   end
   return c
end

-- ###############################################

function ndpi_proto.init()
   ndpi_protos            = { }
   ndpi_flows             = { }

   num_ndpi_flows         = 0
   lower_ndpi_flow_id     = 0
   lower_ndpi_flow_volume = 0
   num_pkts               = 0
   last_processed_packet_number = 0

   -- ARP
   arp_stats              = { }

   -- MAC
   mac_stats              = { }

   -- VLAN
   vlan_stats             = { }
   vlan_found             = false

   -- TCP
   syn                    = {}
   synack                 = {}

   -- DNS
   dns_responses_ok       = {}
   dns_responses_error    = {}
   dns_client_queries     = {}
   dns_server_responses   = {}
   top_dns_queries        = {}
   num_top_dns_queries    = 0

   -- Network RRT
   min_nw_client_RRT  = {}
   min_nw_server_RRT  = {}
   max_nw_client_RRT  = {}
   max_nw_server_RRT  = {}

   -- Application Latency
   first_payload_ts      = {}
   first_payload_id      = {}   
end

function slen(str)
   local i = 1
   local len = 0
   local zero = string.char(0)

   for i = 1, 16 do
      local c = str:sub(i,i)

      if(c ~= zero) then
	 len = len + 1
      else
	 break
      end
   end

   return(str:sub(1, len))
end

-- Print contents of `tbl`, with indentation.
-- You can call it as tprint(mytable)
-- The other two parameters should not be set
function tprint(s, l, i)
   l = (l) or 1000; i = i or "";-- default item limit, indent string
   if (l<1) then io.write("ERROR: Item limit reached.\n"); return l-1 end;
   local ts = type(s);
   if (ts ~= "table") then io.write(i..' '..ts..' '..tostring(s)..'\n'); return l-1 end
   io.write(i..' '..ts..'\n');
   for k,v in pairs(s) do
      local indent = ""

      if(i ~= "") then
	 indent = i .. "."
      end
      indent = indent .. tostring(k)

      l = tprint(v, l, indent);
      if (l < 0) then break end
   end

   return l
end

-- ###############################################

local function getstring(finfo)
   local ok, val = pcall(tostring, finfo)
   if not ok then val = "(unknown)" end
   return val
end

local function getval(finfo)
   local ok, val = pcall(tostring, finfo)
   if not ok then val = nil end
   return val
end

function dump_pinfo(pinfo)
   local fields = { all_field_infos() }
   for ix, finfo in ipairs(fields) do
      --  output = output .. "\t[" .. ix .. "] " .. finfo.name .. " = " .. getstring(finfo) .. "\n"
      --print(finfo.name .. "\n")
      print("\t[" .. ix .. "] " .. finfo.name .. " = " .. getstring(finfo) .. "\n")
   end
end

-- ###############################################


function initARPEntry(mac)
   if(arp_stats[mac] == nil) then
      arp_stats[mac] = { request_sent=0, request_rcvd=0, response_sent=0, response_rcvd=0 }
   end
end

function dissectARP(isRequest, src_mac, dst_mac)
   local mac

   -- print(num_pkts)
   if(isRequest == 1) then
      -- ARP Request
      initARPEntry(src_mac)
      arp_stats[src_mac].request_sent = arp_stats[src_mac].request_sent + 1

      initARPEntry(dst_mac)
      arp_stats[dst_mac].request_rcvd = arp_stats[dst_mac].request_rcvd + 1
   else
      -- ARP Response
      initARPEntry(src_mac)
      arp_stats[src_mac].response_sent = arp_stats[src_mac].response_sent + 1

      initARPEntry(dst_mac)
      arp_stats[dst_mac].response_rcvd = arp_stats[dst_mac].response_rcvd + 1
   end
end

-- ###############################################

function abstime_diff(a, b)
   return(tonumber(a)-tonumber(b))
end

-- ###############################################

local field_tcp_flags = Field.new('tcp.flags')

-- the dissector function callback
function ndpi_proto.dissector(tvb, pinfo, tree)
   -- Wireshark dissects the packet twice. We ignore the first
   -- run as on that step the packet is still undecoded
   -- The trick below avoids to process the packet twice

   if(pinfo.visited == false) then return end

   num_pkts = num_pkts + 1
   if((num_pkts > 1) and (pinfo.number == 1)) then return end

   if(last_processed_packet_number < pinfo.number) then
      last_processed_packet_number = pinfo.number
   end

   -- print(num_pkts .. " / " .. pinfo.number .. " / " .. last_processed_packet_number)

   -- ############# ARP / VLAN #############
   local offset = 12
   local eth_proto = tostring(tvb(offset,2))

   if(eth_proto == "8100") then
      local vlan_id = BitAND(tonumber(tostring(tvb(offset+2,2))), 0xFFF)

      if(vlan_stats[vlan_id] == nil) then vlan_stats[vlan_id] = 0 end
      vlan_stats[vlan_id] = vlan_stats[vlan_id] + 1
      vlan_found = true
   end

   while(eth_proto == "8100") do
      offset = offset + 4
      eth_proto = tostring(tvb(offset,2))
   end

   if(eth_proto == "0806") then
      -- ARP
      local isRequest = tonumber(tvb(21,1))
      --print(eth_proto.." ["..tostring(pinfo.dl_src).." / ".. tostring(pinfo.dl_dst) .."] [" .. tostring(pinfo.src).." -> "..tostring(pinfo.dst).."]")
      dissectARP(isRequest, tostring(pinfo.dl_src), tostring(pinfo.dl_dst))
   else
      -- ############# 2 nDPI Dissection #############

      if(false) then
	 local srckey = tostring(pinfo.src)
	 local dstkey = tostring(pinfo.dst)
	 print("Processing packet "..pinfo.number .. "["..srckey.." / "..dstkey.."]")
      end

      local src_mac = tostring(pinfo.dl_src)
      local src_ip  = tostring(pinfo.src)
      if(mac_stats[src_mac] == nil) then mac_stats[src_mac] = {} end
      mac_stats[src_mac][src_ip] = 1

      local pktlen = tvb:len()
      -- local eth_trailer = f_eth_trailer()
      local magic = tostring(tvb(pktlen-28,4))

      if(magic == "19680924") then
	 local ndpi_subtree = tree:add(ndpi_proto, tvb(), "nDPI Protocol")
	 local network_protocol     = tvb(pktlen-24,2)
	 local application_protocol = tvb(pktlen-22,2)
	 local name = tvb(pktlen-20,16)
	 local name_str = name:string(ENC_ASCII)
	 local ndpikey, srckey, dstkey, flowkey

	 ndpi_subtree:add(ndpi_fds.network_protocol, network_protocol)
	 ndpi_subtree:add(ndpi_fds.application_protocol, application_protocol)
	 ndpi_subtree:add(ndpi_fds.name, name)

	 local pname = ""..application_protocol
	 if(pname ~= "0000") then
	    -- Set protocol name in the wireshark protocol column (if not Unknown)
	    pinfo.cols.protocol = name_str
	 end

	 if(compute_flows_stats) then
	    ndpikey = tostring(slen(name_str))

	    if(ndpi_protos[ndpikey] == nil) then ndpi_protos[ndpikey] = 0 end
	    ndpi_protos[ndpikey] = ndpi_protos[ndpikey] + pinfo.len

	    srckey = tostring(pinfo.src)
	    dstkey = tostring(pinfo.dst)

	    flowkey = srckey.." / "..dstkey.."\t["..ndpikey.."]"
	    if(ndpi_flows[flowkey] == nil) then
	       ndpi_flows[flowkey] = 0
	       num_ndpi_flows = num_ndpi_flows + 1

	       if(num_ndpi_flows > max_num_flows) then
		  -- We need to harvest the flow with least packets beside this new one
		  local tot_removed = 0

		  for k,v in pairsByValues(ndpi_flows, asc) do
		     if(k ~= flowkey) then
			table.remove(ndpi_flows, k)
			num_ndpi_flows = num_ndpi_flows + 1
			if(num_ndpi_flows == (2*max_num_entries)) then
			   break
			end
		     end
		  end
	       end
	    end

	    ndpi_flows[flowkey] = ndpi_flows[flowkey] + pinfo.len
	 end
      end -- nDPI

      -- ###########################################

      local dns_response = f_dns_response()
      if(dns_response ~= nil) then
	 local dns_ret_code = f_dns_ret_code()
	 local dns_response = tonumber(getval(dns_response))
	 local srckey = tostring(pinfo.src)
	 local dstkey = tostring(pinfo.dst)
	 local dns_query_name = f_dns_query_name()
	 dns_query_name = getval(dns_query_name)

	 if(dns_response == 0) then
	    -- DNS Query
	    if(dns_client_queries[srckey] == nil) then dns_client_queries[srckey] = 0 end
	    dns_client_queries[srckey] = dns_client_queries[srckey] + 1

	    if(dns_query_name ~= nil) then
	       if(top_dns_queries[dns_query_name] == nil) then
		  top_dns_queries[dns_query_name] = 0
		  num_top_dns_queries = num_top_dns_queries + 1

		  if(num_top_dns_queries > max_num_dns_queries) then
		     -- We need to harvest the flow with least packets beside this new one
		     for k,v in pairsByValues(dns_client_queries, asc) do
			if(k ~= dns_query_name) then
			   table.remove(ndpi_flows, k)
			   num_top_dns_queries = num_top_dns_queries - 1

			   if(num_top_dns_queries == (2*max_num_entries)) then
			      break
			   end
			end
		     end
		  end
	       end

	       top_dns_queries[dns_query_name] = top_dns_queries[dns_query_name] + 1
	    end
	 else
	    -- DNS Response
	    if(dns_server_responses[srckey] == nil) then dns_server_responses[srckey] = 0 end
	    dns_server_responses[srckey] = dns_server_responses[srckey] + 1

	    if(dns_ret_code ~= nil) then
	       dns_ret_code = getval(dns_ret_code)

	       if((dns_query_name ~= nil) and (dns_ret_code ~= nil)) then
		  dns_ret_code = tonumber(dns_ret_code)

		  if(debug) then print("[".. srckey .." -> ".. dstkey .."] "..dns_query_name.."\t"..dns_ret_code) end

		  if(dns_ret_code == 0) then
		     if(dns_responses_ok[srckey] == nil) then dns_responses_ok[srckey] = 0 end
		     dns_responses_ok[srckey] = dns_responses_ok[srckey] + 1
		  else
		     if(dns_responses_error[srckey] == nil) then dns_responses_error[srckey] = 0 end
		     dns_responses_error[srckey] = dns_responses_error[srckey] + 1
		  end
	       end
	    end
	 end
      end

      -- ###########################################

      local _tcp_flags = field_tcp_flags()
      local udp_len    = f_udp_len()
      
      if((_tcp_flags ~= nil) or (udp_len ~= nil)) then
	 local key
	 local rtt_debug = false
	 local tcp_flags
	 local tcp_header_len
	 local ip_len
	 local ip_hdr_len
	 
	 if(udp_len == nil) then
	    tcp_flags = field_tcp_flags().value
	    tcp_header_len = f_tcp_header_len()
	    ip_len         = f_ip_len()
	    ip_hdr_len     = f_ip_hdr_len()
	 end
	 
	 if(((ip_len ~= nil) and (tcp_header_len ~= nil) and (ip_hdr_len ~= nil))
	       or (udp_len ~= nil)
	 ) then
	    local payloadLen

	    if(udp_len == nil) then
	       ip_len         = tonumber(getval(ip_len))
	       tcp_header_len = tonumber(getval(tcp_header_len))
	       ip_hdr_len     = tonumber(getval(ip_hdr_len))
	       
	       payloadLen = ip_len - tcp_header_len - ip_hdr_len
	    else
	       payloadLen = tonumber(getval(udp_len))
	    end
	    
	    if(payloadLen > 0) then
	       local key = getstring(pinfo.src).."_"..getstring(pinfo.src_port).."_"..getstring(pinfo.dst).."_"..getstring(pinfo.dst_port)
	       local revkey = getstring(pinfo.dst).."_"..getstring(pinfo.dst_port).."_"..getstring(pinfo.src).."_"..getstring(pinfo.src_port)

	       if(first_payload_ts[revkey] ~= nil) then
		  local appl_latency = abstime_diff(pinfo.abs_ts, first_payload_ts[revkey]) * 1000

		  if((appl_latency > 0)
		     -- The trick below is used to set only the first latency packet
			and ((first_payload_id[revkey] == nil) or (first_payload_id[revkey] == pinfo.number))
		  ) then
		     local ntop_subtree = tree:add(ntop_proto, tvb(), "ntop")
		     local server = getstring(pinfo.src)
		     if(rtt_debug) then print("==> Appl Latency @ "..pinfo.number..": "..appl_latency) end
		     
		     ntop_subtree:add(ntop_fds.appl_latency_rtt, appl_latency)
		     first_payload_id[revkey] = pinfo.number

		     if(min_appl_RRT[server] == nil) then
			min_appl_RRT[server] = appl_latency
		     else
			min_appl_RRT[server] = math.min(min_appl_RRT[server], appl_latency)
		     end
		     
		     if(max_appl_RRT[server] == nil) then
			max_appl_RRT[server] = appl_latency
		     else
			max_appl_RRT[server] = math.max(max_appl_RRT[server], appl_latency)
		     end

		     -- first_payload_ts[revkey] = nil
		  end
	       else
		  if(first_payload_ts[key] == nil) then first_payload_ts[key] = pinfo.abs_ts end
	       end
	    end
	 end
	 
	 
	 tcp_flags = tonumber(tcp_flags)

	 if(tcp_flags == 2) then
	    -- SYN
	    key = getstring(pinfo.src).."_"..getstring(pinfo.src_port).."_"..getstring(pinfo.dst).."_"..getstring(pinfo.dst_port)
	    if(rtt_debug) then print("SYN @ ".. pinfo.abs_ts.." "..key) end
	    syn[key] = pinfo.abs_ts
	 elseif(tcp_flags == 18) then
	    -- SYN|ACK
	    key = getstring(pinfo.dst).."_"..getstring(pinfo.dst_port).."_"..getstring(pinfo.src).."_"..getstring(pinfo.src_port)
	    if(rtt_debug) then print("SYN|ACK @ ".. pinfo.abs_ts.." "..key) end
	    synack[key] = pinfo.abs_ts
	    if(syn[key] ~= nil) then
	       local diff = abstime_diff(synack[key], syn[key]) * 1000 -- msec

	       if(rtt_debug) then print("Server RTT --> ".. diff .. " msec") end

	       if(diff <= max_latency_discard) then
		  local ntop_subtree = tree:add(ntop_proto, tvb(), "ntop")
		  ntop_subtree:add(ntop_fds.server_nw_rtt, diff)
		  -- Do not delete the key below as it's used when a user clicks on a packet
		  -- syn[key] = nil
		  
		  local server = getstring(pinfo.src)
		  if(min_nw_server_RRT[server] == nil) then
		     min_nw_server_RRT[server] = diff
		  else
		     min_nw_server_RRT[server] = math.min(min_nw_server_RRT[server], diff)
		  end

		  if(max_nw_server_RRT[server] == nil) then
		     max_nw_server_RRT[server] = diff
		  else
		     max_nw_server_RRT[server] = math.max(max_nw_server_RRT[server], diff)
		  end		  
	       end
	    end
	 elseif(tcp_flags == 16) then
	    -- ACK
	    key = getstring(pinfo.src).."_"..getstring(pinfo.src_port).."_"..getstring(pinfo.dst).."_"..getstring(pinfo.dst_port)
	    if(rtt_debug) then print("ACK @ ".. pinfo.abs_ts.." "..key) end

	    if(synack[key] ~= nil) then
	       local diff = abstime_diff(pinfo.abs_ts, synack[key]) * 1000 -- msec
	       if(rtt_debug) then print("Client RTT --> ".. diff .. " msec") end

	       if(diff <= max_latency_discard) then
		  local ntop_subtree = tree:add(ntop_proto, tvb(), "ntop")
		  ntop_subtree:add(ntop_fds.client_nw_rtt, diff)
		  
		  -- Do not delete the key below as it's used when a user clicks on a packet
		   synack[key] = nil

		  local client = getstring(pinfo.src)
		  if(min_nw_client_RRT[client] == nil) then
		     min_nw_client_RRT[client] = diff
		  else
		     min_nw_client_RRT[client] = math.min(min_nw_client_RRT[client], diff)
		  end
		  
		  if(max_nw_client_RRT[client] == nil) then
		     max_nw_client_RRT[client] = diff
		  else
		     max_nw_client_RRT[client] = math.max(max_nw_client_RRT[client], diff)
		  end
	       end
	    end
	 end
      end

      if(debug) then
	 local fields  = { }
	 local _fields = { all_field_infos() }

	 -- fields['pinfo.number'] = pinfo.number

	 for k,v in pairs(_fields) do
	    local value = getstring(v)

	    if(value ~= nil) then
	       fields[v.name] = value
	    end
	 end

	 for k,v in pairs(fields) do
	    print(k.." = "..v)
	 end
      end
   end
end

register_postdissector(ndpi_proto)

-- ###############################################

local function ndpi_dialog_menu()
   local win = TextWindow.new("nDPI Protocol Statistics");
   local label = ""
   local i

   if(ndpi_protos ~= {}) then
      local tot = 0
      label =          "nDPI Protocol Breakdown\n"
      label = label .. "-----------------------\n"

      for _,v in pairs(ndpi_protos) do
	 tot = tot + v
      end

      i = 0
      for k,v in pairsByValues(ndpi_protos, rev) do
	 local pctg = formatPctg((v * 100) / tot)
	 label = label .. string.format("%-32s\t\t%s\t", k, bytesToSize(v)).. "\t["..pctg.."]\n"
	 if(i == max_num_entries) then break else i = i + 1 end
      end

      -- #######

      label = label .. "\nTop nDPI Flows\n"
      label = label .. "-----------\n"
      i = 0
      for k,v in pairsByValues(ndpi_flows, rev) do
	 local pctg = formatPctg((v * 100) / tot)
	 label = label .. string.format("%-48s\t%s", k, bytesToSize(v)).. "\t["..pctg.."]\n"
	 if(i == max_num_entries) then break else i = i + 1 end
      end

      win:set(label)
      win:add_button("Clear", function() win:clear() end)
   end
end

-- ###############################################

local function arp_dialog_menu()
   local win = TextWindow.new("ARP Statistics");
   local label = ""
   local _stats
   local found = false

   _stats = {}
   for k,v in pairs(arp_stats) do
      if(k ~= "Broadcast") then
	 _stats[k] = v.request_sent + v.request_rcvd + v.response_sent + v.response_rcvd
	 found = true
      end
   end

   if(not found) then
      label = "No ARP Traffic detected"
   else
      label = "Top ARP Senders/Receivers\n\nMAC Address\tTot Pkts\tPctg\tARP Breakdown\n"
      i = 0
      for k,v in pairsByValues(_stats, rev) do
	 local s = arp_stats[k]
	 local pctg = formatPctg((v * 100) / last_processed_packet_number)
	 local str = k .. "\t" .. v .. "\t" .. pctg .. "\t" .. "[sent: ".. (s.request_sent + s.response_sent) .. "][rcvd: ".. (s.request_rcvd + s.response_rcvd) .. "]\n"
	 label = label .. str
	 if(i == max_num_entries) then break else i = i + 1 end
      end
   end

   win:set(label)
   win:add_button("Clear", function() win:clear() end)
end

-- ###############################################

local function vlan_dialog_menu()
   local win = TextWindow.new("VLAN Statistics");
   local label = ""
   local _macs
   local num_hosts = 0

   if(vlan_found) then
      i = 0
      label = "VLAN\tPackets\n"
      for k,v in pairsByValues(vlan_stats, rev) do
	 local pctg = formatPctg((v * 100) / last_processed_packet_number)
	 label = label .. k .. "\t" .. v .. " pkts [".. pctg .."]\n"
	 if(i == max_num_entries) then break else i = i + 1 end
      end
   else
      label = "No VLAN traffic found"
   end

   win:set(label)
   win:add_button("Clear", function() win:clear() end)
end

-- ###############################################

local function ip_mac_dialog_menu()
   local win = TextWindow.new("IP-MAC Statistics");
   local label = ""
   local _macs, _manufacturers
   local num_hosts = 0

   _macs = {}
   _manufacturers = {}
   for mac,v in pairs(mac_stats) do
      local num = 0
      local m =  string.split(mac, "_")
      local manuf

      if(m == nil) then
	 m =  string.split(mac, ":")

	 manuf = m[1]..":"..m[2]..":"..m[3]
      else
	 manuf = m[1]
      end

      for a,b in pairs(v) do
	 num = num +1
      end

      _macs[mac] = num
      if(_manufacturers[manuf] == nil) then _manufacturers[manuf] = 0 end
      _manufacturers[manuf] = _manufacturers[manuf] + 1
      num_hosts = num_hosts + num
   end

   if(num_hosts > 0) then
      i = 0
      label = label .. "MAC\t\t# Hosts\tPercentage\n"
      for k,v in pairsByValues(_macs, rev) do
	 local pctg = formatPctg((v * 100) / num_hosts)
	 label = label .. k .. "\t" .. v .. "\t".. pctg .."\n"
	 if(i == max_num_entries) then break else i = i + 1 end
      end

      i = 0
      label = label .. "\n\nManufacturer\t# Hosts\tPercentage\n"
      for k,v in pairsByValues(_manufacturers, rev) do
	 local pctg = formatPctg((v * 100) / num_hosts)
	 label = label .. k .. "\t\t" .. v .. "\t".. pctg .."\n"
	 if(i == max_num_entries) then break else i = i + 1 end
      end
   else
      label = label .. "\nIP-MAC traffic found"
   end

   win:set(label)
   win:add_button("Clear", function() win:clear() end)
end

-- ###############################################

local function dns_dialog_menu()
   local win = TextWindow.new("DNS Statistics");
   local label = ""
   local tot = 0
   local _dns = {}

   for k,v in pairs(dns_responses_ok) do
      _dns[k] = v
      tot = tot + v
   end

   for k,v in pairs(dns_responses_error) do
      if(_dns[k] == nil) then _dns[k] = 0 end
      _dns[k] = _dns[k] + v
      tot = tot + v
   end

   if(tot > 0) then
      i = 0
      label = label .. "DNS Server\t\t# Responses\n"
      for k,v in pairsByValues(_dns, rev) do
	 local pctg = formatPctg((v * 100) / tot)
	 local ok   = dns_responses_ok[k]
	 local err  = dns_responses_error[k]

	 if(ok == nil)  then ok = 0 end
	 if(err == nil) then err = 0 end
	 label = label .. string.format("%-20s\t%s\n", shortenString(k), v .. "\t[ok: "..ok.."][error: "..err.."][".. pctg .."]")

	 if(i == max_num_entries) then break else i = i + 1 end
      end

      i = 0
      label = label .. "\n\nTop DNS Clients\t# Queries\n"
      for k,v in pairsByValues(dns_client_queries, rev) do
	 local pctg = formatPctg((v * 100) / tot)
	 label = label .. string.format("%-20s\t%s\n", shortenString(k), v .. "\t["..pctg.."]")
	 if(i == max_num_entries) then break else i = i + 1 end
      end

      i = 0
      label = label .. "\n\nTop DNS Resolvers\t# Responses\n"
      for k,v in pairsByValues(dns_server_responses, rev) do
	 local pctg = formatPctg((v * 100) / tot)
	 label = label .. string.format("%-20s\t%s\n", shortenString(k), v .. "\t["..pctg.."]")
	 if(i == max_num_entries) then break else i = i + 1 end
      end

      i = 0
      label = label .. "\n\nTop DNS Queries\t\t\t# Queries\n"
      for k,v in pairsByValues(top_dns_queries, rev) do
	 local pctg = formatPctg((v * 100) / tot)
	 label = label .. string.format("%-32s\t%s\n", shortenString(k,32), v .. "\t["..pctg.."]")
	 if(i == max_num_entries) then break else i = i + 1 end
      end
   else
      label = label .. "\nNo DNS traffic found"
   end

   win:set(label)


   -- add buttons to clear text window and to enable editing
   win:add_button("Clear", function() win:clear() end)
   --win:add_button("Enable edit", function() win:set_editable(true) end)

   -- print "closing" to stdout when the user closes the text windw
   --win:set_atclose(function() print("closing") end)
end

-- ###############################################

local function rtt_dialog_menu()
   local win = TextWindow.new("Network Latency");
   local label = ""
   local tot = 0
   local i

   i = 0
   label = label .. "Client\t\tMin/Max RTT\n"
   for k,v in pairsByValues(min_nw_client_RRT, rev) do
      label = label .. string.format("%-20s\t%.3f / %.3f msec\n", shortenString(k), v, max_nw_client_RRT[k])
      if(i == max_num_entries) then break else i = i + 1 end
   end

   i = 0
   label = label .. "\nServer\t\tMin RTT\n"
   for k,v in pairsByValues(min_nw_server_RRT, rev) do
      label = label .. string.format("%-20s\t%.3f / %.3f msec\n", shortenString(k), v, max_nw_server_RRT[k])
      if(i == max_num_entries) then break else i = i + 1 end
   end

   win:set(label)
   win:add_button("Clear", function() win:clear() end)
end

-- ###############################################

local function appl_rtt_dialog_menu()
   local win = TextWindow.new("Application Latency");
   local label = ""
   local tot = 0
   local i

   i = 0
   label = label .. "Server\t\tMin Application RTT\n"
   for k,v in pairsByValues(min_appl_RRT, rev) do
      label = label .. string.format("%-20s\t%.3f / %.3f msec\n", shortenString(k), v, max_appl_RRT[k])
      if(i == max_num_entries) then break else i = i + 1 end
   end

   win:set(label)
   win:add_button("Clear", function() win:clear() end)
end

-- ###############################################

register_menu("ntop/ARP",          arp_dialog_menu, MENU_TOOLS_UNSORTED)
register_menu("ntop/VLAN",         vlan_dialog_menu, MENU_TOOLS_UNSORTED)
register_menu("ntop/IP-MAC",       ip_mac_dialog_menu, MENU_TOOLS_UNSORTED)
register_menu("ntop/DNS",          dns_dialog_menu, MENU_TOOLS_UNSORTED)
register_menu("ntop/Latency/Network",      rtt_dialog_menu, MENU_TOOLS_UNSORTED)
register_menu("ntop/Latency/Application",  appl_rtt_dialog_menu, MENU_TOOLS_UNSORTED)

-- ###############################################

if(compute_flows_stats) then
   register_menu("ntop/nDPI", ndpi_dialog_menu, MENU_TOOLS_UNSORTED)
end

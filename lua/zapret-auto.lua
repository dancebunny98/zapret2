-- arg: reqhost - require hostname, do not work with ip
function automate_host_record(desync)
	local key
	if desync.arg.reqhost then
		key = desync.track and desync.track.hostname
	else
		key = host_or_ip(desync)
	end
	if not key then
		DLOG("automate: host record key unavailable")
		return nil
	end
	DLOG("automate: host record key '"..key.."'")
	if not autostate then
		autostate = {}
	end
	if not autostate[key] then
		autostate[key] = {}
	end
	return autostate[key]
end
function automate_conn_record(desync)
	if not desync.track.lua_state.automate then
		desync.track.lua_state.automate = {}
	end
	return desync.track.lua_state.automate
end

-- counts failure, optionally (if crec is given) prevents dup failure counts in a single connection
-- if 'maxtime' between failures is exceeded then failure count is reset
-- return true if threshold ('fails') is reached
-- hres is host record. host or ip bound table
-- cres is connection record. connection bound table
function automate_failure_counter(hrec, crec, fails, maxtime)
	if crec and crec.failure then
		DLOG("automate: duplicate failure in the same connection. not counted")
	else
		if crec then crec.failure = true end
		local tnow=os.time()
		if not hrec.failure_time_last then
			hrec.failure_time_last = tnow
		end
		if not hrec.failure_counter then
			hrec.failure_counter = 0
		elseif tnow>(hrec.failure_time_last + maxtime) then
			DLOG("automate: failure counter reset because last failure was "..(tnow - hrec.failure_time_last).." seconds ago")
			hrec.failure_counter = 0
		end
		hrec.failure_counter = hrec.failure_counter + 1
		hrec.failure_time_last = tnow
		if b_debug then DLOG("automate: failure counter "..hrec.failure_counter..(fails and ('/'..fails) or '')) end
		if fails and hrec.failure_counter>=fails then
			hrec.failure_counter = nil -- reset counter
			return true
		end
	end
	return false
end

-- location is url compatible with Location: header
-- hostname is original hostname
function is_dpi_redirect(hostname, location)
	local ds = dissect_url(location)
	if ds.domain then
		local sld1 = dissect_nld(hostname,2)
		local sld2 = dissect_nld(ds.domain,2)
		return sld2 and sld1~=sld2
	end
	return false
end

-- circularily change strategy numbers when failure count reaches threshold ('fails')
-- detected failures: incoming RST, incoming http redirection, outgoing retransmissions
-- this orchestrator requires redirection of incoming traffic to cache RST and http replies !
-- each orchestrated instance must have strategy=N arg, where N starts from 1 and increment without gaps
-- if 'final' arg is present in an orchestrated instance it stops rotation
-- arg: fails=N - failture count threshold. default is 3
-- arg: retrans=N - retrans count threshold. default is 3
-- arg: seq=<rseq> - if packet is beyond this relative sequence number treat this connection as successful. default is 64K
-- arg: rst=<rseq> - maximum relative sequence number to treat incoming RST as DPI reset. default is 1
-- arg: time=<sec> - if last failure happened earlier than `maxtime` seconds ago - reset failure counter. default is 60.
-- arg: reqhost - pass with no tampering if hostname is unavailable
-- test case: nfqws2 --qnum 200 --debug --lua-init=@zapret-lib.lua --lua-init=@zapret-auto.lua --in-range=-s1 --lua-desync=circular --lua-desync=argdebug:strategy=1 --lua-desync=argdebug:strategy=2
function circular(ctx, desync)
	local function count_strategies(hrec, plan)
		if not hrec.ctstrategy then
			local uniq={}
			local n=0
			for i,instance in pairs(plan) do
				if instance.arg.strategy then
					n = tonumber(instance.arg.strategy)
					if not n or n<1 then
						error("circular: strategy number '"..tostring(instance.arg.strategy).."' is invalid")
					end
					uniq[tonumber(instance.arg.strategy)] = true
					if instance.arg.final then
						hrec.final = n
					end
				end
			end
			n=0
			for i,v in pairs(uniq) do
				n=n+1
			end
			if n~=#uniq then
				error("circular: strategies numbers must start from 1 and increment. gaps are not allowed.")
			end
			hrec.ctstrategy = n
		end
	end

	-- take over orchestration. prevent further instance execution in case of error
	execution_plan_cancel(ctx)

	if not desync.dis.tcp then
		DLOG("circular: this orchestrator is tcp only")
		instance_cutoff(ctx)
		return
	end
	if not desync.track then
		DLOG_ERR("circular: conntrack is missing but required")
		return
	end

	local plan = execution_plan(ctx)
	if #plan==0 then
		DLOG("circular: need some desync instances or useless")
		return
	end

	local hrec = automate_host_record(desync)
	if not hrec then
		DLOG("circular: passing with no tampering")
		return
	end

	count_strategies(hrec, plan)
	if hrec.ctstrategy==0 then
		error("circular: add strategy=N tag argument to each following instance ! N must start from 1 and increment")
	end

	local rstseq = tonumber(desync.arg.rst) or 1
	local maxseq = tonumber(desync.arg.seq) or 0x10000
	local fails = tonumber(desync.arg.fails) or 3
	local retrans = tonumber(desync.arg.retrans) or 3
	local maxtime = tonumber(desync.arg.time) or 60
	local crec = automate_conn_record(desync)
	local trigger = false

	if not hrec.nstrategy then
		DLOG("circular: start from strategy 1")
		hrec.nstrategy = 1
	end

	if not crec.nocheck then
		local seq = pos_get(desync,'s')
		if seq>maxseq then
			DLOG("circular: s"..seq.." is beyond s"..maxseq..". treating connection as successful")
			crec.nocheck = true
		end
	end

	local verdict = VERDICT_PASS
	if not crec.nocheck and hrec.final~=hrec.nstrategy then
		if desync.outgoing then
			if #desync.dis.payload>0 and (crec.retrans or 0)<retrans then
				if not crec.uppos then crec.uppos=0 end
				if desync.track.tcp.pos_orig<=crec.uppos then
					crec.retrans = crec.retrans and (crec.retrans+1) or 1
					DLOG("circular: retransmission "..crec.retrans.."/"..retrans)
					trigger = crec.retrans>=retrans
				end
				if desync.track.tcp.pos_orig>crec.uppos then
					crec.uppos=desync.track.tcp.pos_orig
				end
			end
		else
			if bitand(desync.dis.tcp.th_flags, TH_RST)~=0 then
				local seq=u32add(desync.track.tcp.ack, -desync.track.tcp.ack0)
				trigger = seq<=rstseq
				if b_debug then
					if trigger then
						DLOG("circular: incoming RST s"..seq.." in range s"..rstseq)
					else
						DLOG("circular: not counting incoming RST s"..seq.." beyond s"..rstseq)
					end
				end
			elseif desync.l7payload=="http_reply" and desync.track.hostname then
				local hdis = http_dissect_reply(desync.dis.payload)
				if hdis and (hdis.code==302 or hdis.code==307) and hdis.headers.location and hdis.headers.location then
					trigger = is_dpi_redirect(desync.track.hostname, hdis.headers.location.value)
					if trigger and b_debug then
						DLOG("circular: http redirect "..hdis.code.." to '"..hdis.headers.location.value.."'")
					end
				end
			end
		end
		if trigger then
			if automate_failure_counter(hrec, crec, fails, maxtime) then
				-- circular strategy change
				hrec.nstrategy = (hrec.nstrategy % hrec.ctstrategy) + 1
				DLOG("circular: rotate strategy to "..hrec.nstrategy)
				if hrec.nstrategy == hrec.final then
					DLOG("circular: final strategy "..hrec.final.." reached. will rotate no more.")
				end
			end
		end
	end

	DLOG("circular: current strategy "..hrec.nstrategy)
	local dcopy = desync_copy(desync)
	for i=1,#plan do
		if plan[i].arg.strategy and tonumber(plan[i].arg.strategy)==hrec.nstrategy then
			apply_execution_plan(dcopy, plan[i])
			if cutoff_shim_check(dcopy) then
				DLOG("circular: not calling '"..dcopy.func_instance.."' because of voluntary cutoff")
			elseif not payload_match_filter(dcopy.l7payload, plan[i].payload_filter) then
				DLOG("circular: not calling '"..dcopy.func_instance.."' because payload '"..dcopy.l7payload.."' does not match filter '"..plan[i].payload_filter.."'")
			elseif not pos_check_range(dcopy, plan[i].range) then
				DLOG("circular: not calling '"..dcopy.func_instance.."' because pos "..pos_str(dcopy,plan[i].range.from).." "..pos_str(dcopy,plan[i].range.to).." is out of range '"..pos_range_str(plan[i].range).."'")
			else
				DLOG("circular: calling '"..dcopy.func_instance.."'")
				verdict = verdict_aggregate(verdict,_G[plan[i].func](nil, dcopy))
			end
		end
	end

	return verdict
end

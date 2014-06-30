local Que = require "script/queue"
local Cjson = require "cjson"
local Dbmgr = require "script/dbmgr"
local Attr = require "script/attr"
local Bag = require "script/bag"
local Skill = require "script/skill"
local Gate = require "script/gate"


local player = {
	groupid,    --在group管理器中的player对象索引
	gate,       --所在gateserver的网络连接
	game,       --所在gameserver的网络连接(如果有)
	chaid,      --角色唯一id
	actname,    --帐号名
	chaname,    --角色名(可重复)
	attr,       --角色属性
	skill,      --角色技能
	bag,        --角色背包
	status,
}

local stat_new = 0
local stat_loading = 1
local stat_create = 2
local stat_playing = 3

function player:new(o)
  o = o or {}   
  setmetatable(o, self)
  self.__index = self
  self.groupid = 0
  self.game = nil
  self.gate = nil
  self.actname = nil
  self.chaname = nil
  self.attr = Attr.NewAttr()
  self.skill = Skill.NewSkillmgr()
  self.bag = Bag.NewBag()
  self.chaid = 0
  self.status = stat_new
  return o
end

function player:pack(wpk)
	self.attr:pack(wpk)
	self.skill:pack(wpk)
	self.bag:pack(wpk)
end

function player:send2gate(wpk)
	wpk_write_uint32(wpk,self.gate.id.high)
	wpk_write_uint32(wpk,self.gate.id.low)
	wpk_write_uint32(wpk,1)
	C.send(self.gate.conn,wpk)	
end

local function notifybusy(ply)
	ply.status = stat_new --首先复位状态
	local wpk = new_wpk()
	wpk_write_uint16(wpk,CMD_GA_BUSY)
	ply:send2gate(wpk)
end

local function notifybegply(ply)
	ply.status = stat_playing
	local wpk = new_wpk()
	wpk_write_uint16(wpk,CMD_GC_BEGINPLY)
	ply:pack(wpk)
	ply:send2gate(wpk)	
end

local function cb_updateacdb(self,err,result)
	if err then
		self.ply.chaid = 0
		notifybusy(self.ply)	
		return
	end
	self.ply:create_character(self.chaname)
end

local function get_id_callback(self,err,result)
	if err or not result then
		notifybusy(self.ply)
	end
	local ply = self.ply
	local chaid = result
	ply.chaid = chaid
	print("get_id_callback chaid:" .. chaid)
	--向帐号数据库插入chaid
	local cmd = "set " .. ply.actname .. " " .. chaid
	err = Dbmgr.DBCmd(chaid,cmd,{callback = cb_updateacdb,ply=self})
	if err then
		notifybusy(self.ply)
	end
end

local function db_create_callback(self,error,result)
	local ply = self.ply
	if error then
		notifybusy(ply)
	else
		--通知玩家进入游戏
		notifybegply(ply)
	end
	print("db_create_callback")
end

function player:create_character(chaname)
	self.chaname = chaname
	if self.chaid == 0 then
		--请求角色唯一id
		local cmd = "incr chaid"
		local err = Dbmgr.DBCmd("global",cmd,{callback = get_id_callback,ply=self})
		if err then
			notifybusy(self)
		end	
	else
		local cmd = "hmset chaid:" .. self.chaid .. " chaname " .. self.chaname .. " attr " .. Cjson.encode(self.attr.attr)
		local err = Dbmgr.DBCmd(self.chaid,cmd,{callback = db_create_callback,ply=self})
		if err then
			notifybusy(self)
		end		
	end
	self.status = stat_create	
end



local function initfreeidx()
	local que = Que.Queue()
	for i=1,65536 do
		que:push({v=i,__next=nil})
	end
	return que
end 

--player管理容器
local playermgr = {
	freeidx = initfreeidx(),
	players = {},
	actname2player ={},
}

function playermgr:new_player(actname)
	if not actname or actname == '' then
		return nil
	end
	if self.freeidx:is_empty() then
		return nil
	else
		local newply = player:new()
		newply.actname = actname
		newply.groupid = self.freeidx:pop().v
		self.players[newply.groupid] = newply
		self.actname2player[actname] = newply
		print("new_player groupid:" .. newply.groupid)
		return newply
	end
end

function playermgr:release_player(ply)
	if ply.groupid and ply.groupid >= 1 and ply.groupid <= 65536 then
		self.freeidx:push({v=ply.groupid,__next=nil})
		self.players[ply.groupid] = nil
		self.actname2player[ply.actname] = nil
		ply.groupid = nil
	end
end

function playermgr:getplybyid(groupid)
	return self.players[groupid]
end

function playermgr:getplybyactname(actname)
	if not actname or actname == '' then
		return nil
	end
	return self.actname2player[actname]
end



function load_chainfo_callback(self,error,result)
	if error then
		notifybusy(self.ply)
		return
	end
	
	if not result then
		--通知客户端创建用户
		print("send CMD_GA_CREATE")	
		local wpk = new_wpk()
		wpk_write_uint16(wpk,CMD_GA_CREATE)
		wpk_write_uint32(wpk,ply.groupid)	
		ply:send2gate(wpk)	
		return 
	end
	
	local ply = self.ply	
	ply.attr =  Cjson.decode(result[1])
	ply.skill = Cjson.decode(result[2])
	notifybegply(ply)
end


local function AG_PLYLOGIN(_,rpk,conn)
	local actname = rpk_read_string(rpk)
	local chaid = rpk_read_uint32(rpk)
	local gateid = {}
	gateid.high = rpk_read_uint32(rpk)
	gateid.low = rpk_read_uint32(rpk)

	print(gateid.high)
	print(gateid.low)	
	local ply = playermgr:getplybyactname(actname)
	if ply then
		if ply.gate then
			--玩家在线游戏中,禁止另一个登陆请求
			local wpk = new_wpk()
			wpk_write_uint16(wpk,CMD_GA_PLY_INVAILD)
			wpk_write_uint32(wpk,gateid.high)
			wpk_write_uint32(wpk,gateid.low)
			C.send(conn,wpk)	
		else
			--玩家没有下线还在游戏中,现在重新与服务器建立连接，处理重连逻辑
			ply.gate = {id=gateid,conn = conn}
			Gate.InsertGatePly(ply,ply.gate)			
			print("here");	
		end
		return
	end
	ply = playermgr:new_player(actname)
	if not ply then
		--通知gate繁忙，请求gate断开客户端连接
		local wpk = new_wpk()
		wpk_write_uint16(wpk,CMD_GA_BUSY)
		wpk_write_uint32(wpk,gateid.high)
		wpk_write_uint32(wpk,gateid.low)
		C.send(conn,wpk)
	else
		ply.gate = {id=gateid,conn = conn}
		Gate.InsertGatePly(ply,ply.gate)
		if chaid == 0 then
			--通知客户端创建用户
			print("send CMD_GA_CREATE")	
			local wpk = new_wpk()
			wpk_write_uint16(wpk,CMD_GA_CREATE)
			wpk_write_uint32(wpk,ply.groupid)	
			ply:send2gate(wpk)
		else
			ply.chaid = chaid
			--从数据库载入角色数据
			local cmd = "hmget chaid:" .. chaid .. " attr skill bag"
			local err = Dbmgr.DBCmd(chaid,cmd,{callback = load_chainfo_callback,ply=ply})
			if err then
				notifybusy(ply)
			end
			ply.status = stat_loading
		end
	end
end

local function CG_CREATE(_,rpk,conn)
	local chaname = rpk_read_string(rpk)
	print("CG_CREATE:" .. chaname)
	local groupid = rpk_read_uint32(rpk)
	local gateid = {}
	gateid.high = rpk_read_uint32(rpk)
	gateid.low = rpk_read_uint32(rpk)	
	local ply = playermgr:getplybyid(groupid)
	if not ply then
		local wpk = new_wpk()
		wpk_write_uint16(wpk,CMD_GA_BUSY)
		wpk_write_uint32(wpk,gateid.high)
		wpk_write_uint32(wpk,gateid.low)
		C.send(conn,wpk)		
	else
		if ply.status == stat_create then
			return
		end	
		--[[if not isvaildword(chaname) then
			--角色名含有非法字
			local wpk = new_wpk()
			wpk_write_uint16(wpk,CMD_GC_ERROR)
			wpk_write_string(wpk,"角色名含有非法字符")
			ply:send2gate(wpk)
			return
		end]]--
		ply:create_character(chaname);
	end
	print("CG_CREATE3")
end


local function reg_cmd_handler()
	GroupApp.reg_cmd_handler(CMD_AG_PLYLOGIN,{handle=AG_PLYLOGIN})
	GroupApp.reg_cmd_handler(CMD_CG_CREATE,{handle=CG_CREATE})
end

return {
	RegHandler = reg_cmd_handler,
}

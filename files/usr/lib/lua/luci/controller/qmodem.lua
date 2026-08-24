-- Copyright 2024 Siriling <siriling@qq.com>
-- Copyright 2024 FJR <fjrcn@outlook.com>
module("luci.controller.qmodem", package.seeall)
local http = require "luci.http"
local fs = require "nixio.fs"
local json = require("luci.jsonc")
uci = luci.model.uci.cursor()
local script_path="/usr/share/qmodem/"
local run_path="/tmp/run/qmodem/"
local modem_ctrl = "/usr/share/qmodem/modem_ctrl.sh "

function index()
    if not nixio.fs.access("/etc/config/qmodem") then
        return
    end
	entry({"admin", "modem"}, firstchild(), _("Modem"), 25).dependent=false
	entry({"admin", "modem", "qmodem"}, alias("admin", "modem", "qmodem", "modem_info"), luci.i18n.translate("QModem"), 100).dependent = true
	--模块信息
	entry({"admin", "modem", "qmodem", "modem_info"}, template("qmodem/modem_info"), luci.i18n.translate("QModem Information"),2).leaf = true
	entry({"admin", "modem", "qmodem", "get_modem_cfg"}, call("getModemCFG"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "modem_ctrl"}, call("modemCtrl")).leaf = true
	--拨号配置
	entry({"admin", "modem", "qmodem", "dial_overview"},cbi("qmodem/dial_overview"),luci.i18n.translate("Dial Overview"),3).leaf = true
	entry({"admin", "modem", "qmodem", "dial_config"}, cbi("qmodem/dial_config")).leaf = true
	entry({"admin", "modem", "qmodem", "modems_dial_overview"}, call("getOverviews"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "modems_dial_logs"}, call("getLogs"), nil).leaf = true
	--模块调试
	entry({"admin", "modem", "qmodem", "modem_debug"},template("qmodem/modem_debug"),luci.i18n.translate("Advance Modem Settings"),4).leaf = true
	entry({"admin", "modem", "qmodem", "send_at_command"}, call("sendATCommand"), nil).leaf = true

	--Qmodem设置
	entry({"admin", "modem", "qmodem", "settings"}, cbi("qmodem/settings"), luci.i18n.translate("QModem Settings"),100).leaf = true
	entry({"admin", "modem", "qmodem", "slot_config"}, cbi("qmodem/slot_config")).leaf = true
	entry({"admin", "modem", "qmodem", "modem_config"}, cbi("qmodem/modem_config")).leaf = true
end

--[[
@Description 执行Shell脚本
@Params
	command sh命令
]]
function shell(command)
	local odpall = io.popen(command)
	local odp = odpall:read("*a")
	odpall:close()
	return odp
end

function translate_modem_info(result)
	modem_info = result["modem_info"]
	response = {}
	for k,entry in pairs(modem_info) do
		if type(entry) == "table" then
			key = entry["key"]
			full_name = entry["full_name"]
			if full_name then
				full_name = luci.i18n.translate(full_name)
			elseif key then
				full_name = luci.i18n.translate(key)
			end
			entry["full_name"] = full_name
			if entry["class"] then
				entry["class"] = luci.i18n.translate(entry["class"])
			end
			table.insert(response, entry)
		end
	end
	return response
end

-- ec200g_rich_status: preserve all QModem fields and only replace the
-- unreliable AT/CGACT connection flag with netifd's real PPP interface state.
local function override_ec200g_connect_status(result)
	result = result or {}
	result["modem_info"] = result["modem_info"] or {}
	local status = json.parse(shell("ubus call network.interface.wwan4g status 2>/dev/null")) or {}
	local connect_status = status["up"] == true and "Yes" or "No"
	local found = false

	for _, entry in pairs(result["modem_info"]) do
		if type(entry) == "table" and entry["key"] == "connect_status" then
			entry["value"] = connect_status
			found = true
		end
	end

	if not found then
		table.insert(result["modem_info"], {
			key = "connect_status",
			value = connect_status,
			full_name = "Connect Status",
			type = "plain_text",
			class = "Base Information",
			class_origin = "Base Information"
		})
	end
	return result
end

function modemCtrl()
	local action = http.formvalue("action")
	local cfg_id = http.formvalue("cfg")
	local params = http.formvalue("params")
	local translate = http.formvalue("translate")
	if params then
		result = shell(modem_ctrl..action.." "..cfg_id.." ".."\""..params.."\"")
	else 
		result = shell(modem_ctrl..action.." "..cfg_id)
	end
	if cfg_id == "ec200g" and (action == "info" or action == "base_info") then
		result = json.stringify(override_ec200g_connect_status(json.parse(result)))
	end
	if translate == "1" then
		modem_more_info = json.parse(result)
		modem_more_info = translate_modem_info(modem_more_info)
		result = json.stringify(modem_more_info)
	end
	luci.http.prepare_content("application/json")
	luci.http.write(result)
end

--[[
@Description 执行AT命令
@Params
	at_port AT串口
	at_command AT命令
]]
function at(at_port,at_command)
	local command="source "..script_path.."modem_util.sh && at "..at_port.." "..at_command
	local result=shell(command)
	result=string.gsub(result, "\r", "")
	return result
end

-- ec200g_log_endpoint: logs use a separate fast endpoint so a slow rich-info
-- AT query can no longer hold up the five-second dial-log refresh.
local function collect_modem_logs()
	local logs = {}
	uci:foreach("qmodem", "modem-device", function (modem_device)
		local section_name = modem_device[".name"]
		local modem_name = modem_device["name"] or luci.i18n.translate("Unknown")
		local alias = modem_device["alias"]
		if modem_device["state"] == "disabled" then
			return
		end

		local log_path = run_path..section_name.."_dir/dial_log"
		if fs.access(log_path) then
			table.insert(logs, {
				log_msg = fs.readfile(log_path),
				section_name = section_name,
				name = alias and (alias.."("..modem_name..")") or modem_name
			})
		end
	end)
	return logs
end

function getLogs()
	luci.http.prepare_content("application/json")
	luci.http.write_json({ logs = collect_modem_logs() })
end


--[[
@Description 获取模组信息
]]
function getOverviews()
	-- 获取所有模组
	local modems={}
	uci:foreach("qmodem", "modem-device", function (modem_device)
		section_name = modem_device[".name"]
		modem_name = modem_device["name"] or luci.i18n.translate("Unknown")
		alias = modem_device["alias"]
		modem_state = modem_device["state"]
		if modem_state == "disabled" then
			return
		end
--模组信息部分
		cmd = modem_ctrl.."base_info "..section_name
		result = shell(cmd)
		json_result = json.parse(result) or {}
		if section_name == "ec200g" then
			json_result = override_ec200g_connect_status(json_result)
		end
		modem_info = json_result["modem_info"] or {}
		tmp_info = {}
		if alias then
			title = alias .. "("..modem_name..")"
		else
			title = modem_name
		end
		name = {
			type = "plain_text",
			key = "name",
			value = title
		}
		table.insert(tmp_info, name)
		for k,v in pairs(modem_info) do
			full_name = v["full_name"]
			if full_name then
				v["full_name"] = luci.i18n.translate(full_name)
			end
			table.insert(tmp_info, v)
		end
		table.insert(modems, tmp_info)
	end)
	local logs = collect_modem_logs()
	
	-- 设置值
	local data={}
	data["modems"]=modems
	data["logs"]=logs
	luci.http.prepare_content("application/json")
	luci.http.write_json(data)
end

function getModemCFG()

	local cfgs={}
	local translation={}

	uci:foreach("qmodem", "modem-device", function (modem_device)
		modem_state = modem_device["state"]
		if modem_state == "disabled" then
			return
		end
		--获取模组的备注
		local network=modem_device["modem"]
		local alias=modem_device["alias"]
		local config_name=modem_device[".name"]
		--设置模组AT串口
		local cfg = modem_device[".name"]
		if modem_device["at_port"] ~= nil then
			local at_port=modem_device["at_port"]
			local name=modem_device["name"]:upper()
			local config = {}
			if alias then
				config["name"] = alias .. "("..name..")"
			else
				config["name"] = name
			end
			config["at_port"] = at_port
			config["cfg"] = cfg
			table.insert(cfgs, config)
		end
	end)

	-- 设置值
	local data={}
	data["cfgs"]=cfgs
	data["translation"]=translation

	-- 写入Web界面
	luci.http.prepare_content("application/json")
	luci.http.write_json(data)
end



function sendATCommand()
    local at_port = http.formvalue("port")
	local at_command = http.formvalue("command")

	local response={}
    if at_port and at_command then
		response["response"]=at(at_port,at_command)
		response["time"]=os.date("%Y-%m-%d %H:%M:%S")
    end

	-- 写入Web界面
	luci.http.prepare_content("application/json")
	luci.http.write_json(response)
end

-- Copyright (C) 2013 Jiale Zhi (calio), Cloudflare Inc.
--require "luacov"

local concat                = table.concat
local tcp                   = ngx.socket.tcp
local timer_at              = ngx.timer.at
local ngx_log               = ngx.log
local ngx_sleep             = ngx.sleep
local type                  = type
local pairs                 = pairs
local tostring              = tostring
local debug                 = ngx.config.debug

local DEBUG                 = ngx.DEBUG
local NOTICE                = ngx.NOTICE
local WARN                  = ngx.WARN
local ERR                   = ngx.ERR


local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end

local _M = new_tab(0, 4)


_M._VERSION = '0.01'

-- user config
local flush_limit           = 4096         -- 4KB
local drop_limit            = 1048576      -- 1MB
local timeout               = 1000         -- 1 sec
local host
local port
local path

-- internal variables
local buffer_size           = 0
local buffer_data           = new_tab(20000, 0)
local buffer_index          = 0

local error_buffer          = new_tab(10, 0)
local error_buffer_index    = 0
local max_error             = 5

local connecting
local connected
local retry_connect         = 0
local retry_send            = 0
local max_retry_times       = 3
local retry_interval        = 100         -- 0.1s
local pool_size             = 10
local flushing
local logger_initted
local sock


local function _write_error(msg)
    if error_buffer_index >= max_error then
        return
    end
    error_buffer_index = error_buffer_index + 1
    error_buffer[error_buffer_index] = msg
end

local function _do_connect()
    local ok, err

    if not connected then
        sock, err = tcp()
        if not sock then
            _write_error(err)
            return nil, err
        end

        sock:settimeout(timeout)
    end

    -- host/port and path config have already been checked in init()
    if host and port then
        ok, err =  sock:connect(host, port)
    elseif path then
        ok, err =  sock:connect("unix:" .. path)
    end

    return ok, err
end

local function _connect()
    local ok, err

    if connecting then
        if debug then
            ngx_log(DEBUG, "previous connect not finished")
        end
        return nil, "connecting"
    end

    connected = false
    connecting = true

    retry_connect = 0

    while retry_connect <= max_retry_times do
        ok, err = _do_connect()

        if ok then
            connected = true
            break
        end

        if debug then
            ngx_log(DEBUG, "retry to connect to the log server: ", err)
        end

        -- ngx.sleep use seconds to count time
        ngx_sleep(retry_interval / 1000)

        retry_connect = retry_connect + 1
    end

    connecting = false
    if not connected then
        return nil, "try to connect to the log server failed after "
                    .. max_retry_times .. " retries: " .. err
    end

    return true
end

local function _do_flush(packet)
    local ok, err = _connect()
    if not ok then
        --ngx_log(ERR, err)
        return nil, err
    end

    local bytes, err = sock:send(packet)
    if not bytes then
        -- sock:send always close current connection on error
        return nil, err
    end

    if debug then
        ngx_log(DEBUG, "log flush :" .. bytes)
    end

    ok, err = sock:setkeepalive(0, pool_size)
    if not ok then
        return nil, err
    end

    return true
end

local function _flush()
    local ok, err

    if flushing then
        if debug then
            ngx_log(DEBUG, "previous flush not finished")
        end
        -- do this later
        return true
    end

    flushing = true
    retry_send = 0

    local packet = concat(buffer_data, "", 1, buffer_index)

    -- maybe writing nil value is not needed
    for i = 1, buffer_index do
        buffer_data[i] = nil
    end
    buffer_size = 0
    buffer_index = 0

    while retry_send <= max_retry_times do
        ok, err = _do_flush(packet)

        if ok then
            break
        end

        if debug then
            ngx_log(DEBUG, "retry to send log message to the log server: ", err)
        end

        -- ngx.sleep use seconds to count time
        ngx_sleep(retry_interval / 1000)

        retry_send = retry_send + 1
    end

    flushing = false

    if not ok then
        local err_msg = "try to send log message to the log server "
                        .. "failed after " .. max_retry_times .. " retries: "
                        .. err
        _write_error(err_msg)
        return nil, err_msg
    end

    return true
end

local function _write_buffer(msg)
    buffer_index = buffer_index + 1
    buffer_data[buffer_index] = msg

    buffer_size = buffer_size + #msg

    if (buffer_size >= flush_limit) then
        local ok, err = timer_at(0, _flush)
        if not ok then
            --ngx_log(ERR, err)
            return nil, err
        end
    end

    return buffer_size
end

function _M.init(user_config)
    if (type(user_config) ~= "table") then
        return nil, "user_config must be a table"
    end

    for k, v in pairs(user_config) do
        if k == "host" then
            host = v
        elseif k == "port" then
            port = v
        elseif k == "path" then
            path = v
        elseif k == "flush_limit" then
            flush_limit = v
        elseif k == "drop_limit" then
            drop_limit = v
        elseif k == "timeout" then
            timeout = v
        elseif k == "max_error" then
            max_error = v
        elseif k == "max_retry_times" then
            max_retry_times = v
        elseif k == "retry_interval" then
            -- ngx.sleep uses seconds to count sleep time
            retry_interval = v
        elseif k == "pool_size" then
            pool_size = v
        end
    end

    if not (host and port) and not path then
        return nil, "no logging server configured. Need host/port or path."
    end


    if (flush_limit >= drop_limit) then
        return nil, "flush_limit should < drop_limit"
    end

    flushing = false
    connecting = false

    connected = false
    retry_connect = 0
    retry_send = 0

    logger_initted = true

    return logger_initted
end

function _M.log(msg)
    if not logger_initted then
        return nil, "not initialized"
    end

    if type(msg) ~= "string" then
        msg = tostring(msg)
    end

    if (debug) then
        ngx_log(DEBUG, "log message length: " .. #msg)
    end

    if (buffer_size >= flush_limit and buffer_size + #msg > drop_limit) then
        return nil, "logger buffer is full, this log would be dropped"
    end

    local ok, err = _write_buffer(msg)
    if not ok then
        return nil, err
    end

    if error_buffer_index ~= 0 then
        local last_error = concat(error_buffer)
        for i = 1, error_buffer_index do
            error_buffer[i] = nil
        end
        error_buffer_index = 0

        return nil, last_error
    end
    return true
end

function _M.initted()
    return logger_initted
end

return _M


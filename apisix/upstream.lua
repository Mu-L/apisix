--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local require = require
local core = require("apisix.core")
local config_local   = require("apisix.core.config_local")
local discovery = require("apisix.discovery.init").discovery
local upstream_util = require("apisix.utils.upstream")
local apisix_ssl = require("apisix.ssl")
local events = require("apisix.events")
local error = error
local tostring = tostring
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local ngx_var = ngx.var
local is_http = ngx.config.subsystem == "http"
local upstreams
local healthcheck

local healthcheck_shdict_name = "upstream-healthcheck"
if not is_http then
    healthcheck_shdict_name = healthcheck_shdict_name .. "-" .. ngx.config.subsystem
end

local set_upstream_tls_client_param
local ok, apisix_ngx_upstream = pcall(require, "resty.apisix.upstream")
if ok then
    set_upstream_tls_client_param = apisix_ngx_upstream.set_cert_and_key
else
    set_upstream_tls_client_param = function ()
        return nil, "need to build APISIX-Runtime to support upstream mTLS"
    end
end

local set_stream_upstream_tls
if not is_http then
    local ok, apisix_ngx_stream_upstream = pcall(require, "resty.apisix.stream.upstream")
    if ok then
        set_stream_upstream_tls = apisix_ngx_stream_upstream.set_tls
    else
        set_stream_upstream_tls = function ()
            return nil, "need to build APISIX-Runtime to support TLS over TCP upstream"
        end
    end
end



local HTTP_CODE_UPSTREAM_UNAVAILABLE = 503
local _M = {}


local function set_directly(ctx, key, ver, conf)
    if not ctx then
        error("missing argument ctx", 2)
    end
    if not key then
        error("missing argument key", 2)
    end
    if not ver then
        error("missing argument ver", 2)
    end
    if not conf then
        error("missing argument conf", 2)
    end

    ctx.upstream_conf = conf
    ctx.upstream_version = ver
    ctx.upstream_key = key
    return
end
_M.set = set_directly


local function release_checker(healthcheck_parent)
    if not healthcheck_parent or not healthcheck_parent.checker then
        return
    end
    local checker = healthcheck_parent.checker
    core.log.info("try to release checker: ", tostring(checker))
    checker:delayed_clear(3)
    checker:stop()
end


local function get_healthchecker_name(value)
    return "upstream#" .. value.key
end
_M.get_healthchecker_name = get_healthchecker_name


local function create_checker(upstream)
    local local_conf = config_local.local_conf()
    if local_conf and local_conf.apisix and local_conf.apisix.disable_upstream_healthcheck then
        core.log.info("healthchecker won't be created: disabled upstream healthcheck")
        return nil
    end
    if healthcheck == nil then
        healthcheck = require("resty.healthcheck")
    end

    local healthcheck_parent = upstream.parent
    if healthcheck_parent.checker and healthcheck_parent.checker_upstream == upstream
        and healthcheck_parent.checker_nodes_ver == upstream._nodes_ver then
        return healthcheck_parent.checker
    end

    if upstream.is_creating_checker then
        core.log.info("another request is creating new checker")
        return nil
    end
    upstream.is_creating_checker = true

    core.log.debug("events module used by the healthcheck: ", events.events_module,
                    ", module name: ",events:get_healthcheck_events_modele())

    local checker, err = healthcheck.new({
        name = get_healthchecker_name(healthcheck_parent),
        shm_name = healthcheck_shdict_name,
        checks = upstream.checks,
        -- the events.init_worker will be executed in the init_worker phase,
        -- events.healthcheck_events_module is set
        -- while the healthcheck object is executed in the http access phase,
        -- so it can be used here
        events_module = events:get_healthcheck_events_modele(),
    })

    if not checker then
        core.log.error("fail to create healthcheck instance: ", err)
        upstream.is_creating_checker = nil
        return nil
    end

    if healthcheck_parent.checker then
        local ok, err = pcall(core.config_util.cancel_clean_handler, healthcheck_parent,
                                              healthcheck_parent.checker_idx, true)
        if not ok then
            core.log.error("cancel clean handler error: ", err)
        end
    end

    core.log.info("create new checker: ", tostring(checker))

    local host = upstream.checks and upstream.checks.active and upstream.checks.active.host
    local port = upstream.checks and upstream.checks.active and upstream.checks.active.port
    local up_hdr = upstream.pass_host == "rewrite" and upstream.upstream_host
    local use_node_hdr = upstream.pass_host == "node" or nil
    for _, node in ipairs(upstream.nodes) do
        local host_hdr = up_hdr or (use_node_hdr and node.domain)
        local ok, err = checker:add_target(node.host, port or node.port, host,
                                           true, host_hdr)
        if not ok then
            core.log.error("failed to add new health check target: ", node.host, ":",
                    port or node.port, " err: ", err)
        end
    end

    local check_idx, err = core.config_util.add_clean_handler(healthcheck_parent, release_checker)
    if not check_idx then
        upstream.is_creating_checker = nil
        checker:clear()
        checker:stop()
        core.log.error("failed to add clean handler, err:",
            err, " healthcheck parent:", core.json.delay_encode(healthcheck_parent, true))

        return nil
    end

    healthcheck_parent.checker = checker
    healthcheck_parent.checker_upstream = upstream
    healthcheck_parent.checker_nodes_ver = upstream._nodes_ver
    healthcheck_parent.checker_idx = check_idx

    upstream.is_creating_checker = nil

    return checker
end


local function fetch_healthchecker(upstream)
    if not upstream.checks then
        return nil
    end

    return create_checker(upstream)
end


local function set_upstream_scheme(ctx, upstream)
    -- plugins like proxy-rewrite may already set ctx.upstream_scheme
    if not ctx.upstream_scheme then
        -- the old configuration doesn't have scheme field, so fallback to "http"
        ctx.upstream_scheme = upstream.scheme or "http"
    end

    ctx.var["upstream_scheme"] = ctx.upstream_scheme
end
_M.set_scheme = set_upstream_scheme

local scheme_to_port = {
    http = 80,
    https = 443,
    grpc = 80,
    grpcs = 443,
}


_M.scheme_to_port = scheme_to_port


local function fill_node_info(up_conf, scheme, is_stream)
    local nodes = up_conf.nodes
    if up_conf.nodes_ref == nodes then
        -- filled
        return true
    end

    local need_filled = false
    for _, n in ipairs(nodes) do
        if not is_stream and not n.port then
            if up_conf.scheme ~= scheme then
                return nil, "Can't detect upstream's scheme. " ..
                            "You should either specify a port in the node " ..
                            "or specify the upstream.scheme explicitly"
            end

            need_filled = true
        end

        if not n.priority then
            need_filled = true
        end
    end

    if not need_filled then
        up_conf.nodes_ref = nodes
        return true
    end

    core.log.debug("fill node info for upstream: ",
                core.json.delay_encode(up_conf, true))

    -- keep the original nodes for slow path in `compare_upstream_node()`,
    -- can't use `core.table.deepcopy()` for whole `nodes` array here,
    -- because `compare_upstream_node()` compare `metadata` of node by address.
    up_conf.original_nodes = core.table.new(#nodes, 0)
    for i, n in ipairs(nodes) do
        up_conf.original_nodes[i] = core.table.clone(n)
        if not n.port or not n.priority then
            nodes[i] = core.table.clone(n)

            if not is_stream and not n.port then
                nodes[i].port = scheme_to_port[scheme]
            end

            -- fix priority for non-array nodes and nodes from service discovery
            if not n.priority then
                nodes[i].priority = 0
            end
        end
    end

    up_conf.nodes_ref = nodes
    return true
end


function _M.set_by_route(route, api_ctx)
    if api_ctx.upstream_conf then
        -- upstream_conf has been set by traffic-split plugin
        return
    end

    local up_conf = api_ctx.matched_upstream
    if not up_conf then
        return 503, "missing upstream configuration in Route or Service"
    end
    -- core.log.info("up_conf: ", core.json.delay_encode(up_conf, true))

    if up_conf.service_name then
        if not discovery then
            return 503, "discovery is uninitialized"
        end
        if not up_conf.discovery_type then
            return 503, "discovery server need appoint"
        end

        local dis = discovery[up_conf.discovery_type]
        if not dis then
            local err = "discovery " .. up_conf.discovery_type .. " is uninitialized"
            return 503, err
        end

        local new_nodes, err = dis.nodes(up_conf.service_name, up_conf.discovery_args)
        if not new_nodes then
            return HTTP_CODE_UPSTREAM_UNAVAILABLE, "no valid upstream node: " .. (err or "nil")
        end

        local same = upstream_util.compare_upstream_node(up_conf, new_nodes)
        if not same then
            if not up_conf._nodes_ver then
                up_conf._nodes_ver = 0
            end
            up_conf._nodes_ver = up_conf._nodes_ver + 1

            local pass, err = core.schema.check(core.schema.discovery_nodes, new_nodes)
            if not pass then
                return HTTP_CODE_UPSTREAM_UNAVAILABLE, "invalid nodes format: " .. err
            end

            core.log.info("discover new upstream from ", up_conf.service_name, ", type ",
                          up_conf.discovery_type, ": ",
                          core.json.delay_encode(up_conf, true))
        end

        -- in case the value of new_nodes is the same as the old one,
        -- but discovery lib return a new table for it.
        -- for example, when watch loop of kubernetes discovery is broken or done,
        -- it will fetch full data again and return a new table for every services.
        up_conf.nodes = new_nodes
    end

    local id = up_conf.parent.value.id
    local conf_version = up_conf.parent.modifiedIndex
    -- include the upstream object as part of the version, because the upstream will be changed
    -- by service discovery or dns resolver.
    set_directly(api_ctx, id, conf_version .. "#" .. tostring(up_conf) .. "#"
                                    .. tostring(up_conf._nodes_ver or ''), up_conf)

    local nodes_count = up_conf.nodes and #up_conf.nodes or 0
    if nodes_count == 0 then
        release_checker(up_conf.parent)
        return HTTP_CODE_UPSTREAM_UNAVAILABLE, "no valid upstream node"
    end

    if not is_http then
        local ok, err = fill_node_info(up_conf, nil, true)
        if not ok then
            return 503, err
        end

        local scheme = up_conf.scheme
        if scheme == "tls" then
            local ok, err = set_stream_upstream_tls()
            if not ok then
                return 503, err
            end

            local sni = apisix_ssl.server_name()
            if sni then
                ngx_var.upstream_sni = sni
            end
        end

        local checker = fetch_healthchecker(up_conf)
        api_ctx.up_checker = checker
        return
    end

    set_upstream_scheme(api_ctx, up_conf)

    local ok, err = fill_node_info(up_conf, api_ctx.upstream_scheme, false)
    if not ok then
        return 503, err
    end

    local checker = fetch_healthchecker(up_conf)
    api_ctx.up_checker = checker

    local scheme = up_conf.scheme
    if (scheme == "https" or scheme == "grpcs") and up_conf.tls then

        local client_cert, client_key
        if up_conf.tls.client_cert_id then
            client_cert = api_ctx.upstream_ssl.cert
            client_key = api_ctx.upstream_ssl.key
        else
            client_cert = up_conf.tls.client_cert
            client_key = up_conf.tls.client_key
        end

        -- the sni here is just for logging
        local sni = api_ctx.var.upstream_host
        local cert, err = apisix_ssl.fetch_cert(sni, client_cert)
        if not ok then
            return 503, err
        end

        local key, err = apisix_ssl.fetch_pkey(sni, client_key)
        if not ok then
            return 503, err
        end

        if scheme == "grpcs" then
            api_ctx.upstream_grpcs_cert = cert
            api_ctx.upstream_grpcs_key = key
        else
            local ok, err = set_upstream_tls_client_param(cert, key)
            if not ok then
                return 503, err
            end
        end
    end

    return
end


function _M.set_grpcs_upstream_param(ctx)
    if ctx.upstream_grpcs_cert then
        local cert = ctx.upstream_grpcs_cert
        local key = ctx.upstream_grpcs_key
        local ok, err = set_upstream_tls_client_param(cert, key)
        if not ok then
            return 503, err
        end
    end
end


function _M.upstreams()
    if not upstreams then
        return nil, nil
    end

    return upstreams.values, upstreams.conf_version
end


function _M.check_schema(conf)
    return core.schema.check(core.schema.upstream, conf)
end


local function get_chash_key_schema(hash_on)
    if not hash_on then
        return nil, "hash_on is nil"
    end

    if hash_on == "vars" then
        return core.schema.upstream_hash_vars_schema
    end

    if hash_on == "header" or hash_on == "cookie" then
        return core.schema.upstream_hash_header_schema
    end

    if hash_on == "consumer" then
        return nil, nil
    end

    if hash_on == "vars_combinations" then
        return core.schema.upstream_hash_vars_combinations_schema
    end

    return nil, "invalid hash_on type " .. hash_on
end


local function check_upstream_conf(in_dp, conf)
    if not in_dp then
        local ok, err = core.schema.check(core.schema.upstream, conf)
        if not ok then
            return false, "invalid configuration: " .. err
        end

        if conf.nodes and not core.table.isarray(conf.nodes) then
            local port
            for addr,_ in pairs(conf.nodes) do
                _, port = core.utils.parse_addr(addr)
                if port then
                    if port < 1 or port > 65535 then
                        return false, "invalid port " .. tostring(port)
                    end
                end
            end
        end

        local ssl_id = conf.tls and conf.tls.client_cert_id
        if ssl_id then
            local key = "/ssls/" .. ssl_id
            local res, err = core.etcd.get(key)
            if not res then
                return nil, "failed to fetch ssl info by "
                                    .. "ssl id [" .. ssl_id .. "]: " .. err
            end

            if res.status ~= 200 then
                return nil, "failed to fetch ssl info by "
                                    .. "ssl id [" .. ssl_id .. "], "
                                    .. "response code: " .. res.status
            end
            if res.body and res.body.node and
                res.body.node.value and res.body.node.value.type ~= "client" then

                return nil, "failed to fetch ssl info by "
                                    .. "ssl id [" .. ssl_id .. "], "
                                    .. "wrong ssl type"
            end
        end

        -- encrypt the key in the admin
        if conf.tls and conf.tls.client_key then
            conf.tls.client_key = apisix_ssl.aes_encrypt_pkey(conf.tls.client_key)
        end
    end

    if is_http then
        if conf.pass_host == "rewrite" and
            (conf.upstream_host == nil or conf.upstream_host == "")
        then
            return false, "`upstream_host` can't be empty when `pass_host` is `rewrite`"
        end
    end

    if conf.tls and conf.tls.client_cert then
        local cert = conf.tls.client_cert
        local key = conf.tls.client_key
        local ok, err = apisix_ssl.validate(cert, key)
        if not ok then
            return false, err
        end
    end

    if conf.type ~= "chash" then
        return true
    end

    if conf.hash_on ~= "consumer" and not conf.key then
        return false, "missing key"
    end

    local key_schema, err = get_chash_key_schema(conf.hash_on)
    if err then
        return false, "type is chash, err: " .. err
    end

    if key_schema then
        local ok, err = core.schema.check(key_schema, conf.key)
        if not ok then
            return false, "invalid configuration: " .. err
        end
    end

    return true
end


function _M.check_upstream_conf(conf)
    return check_upstream_conf(false, conf)
end


local function filter_upstream(value, parent)
    if not value then
        return
    end

    value.parent = parent

    if not is_http and value.scheme == "http" then
        -- For L4 proxy, the default scheme is "tcp"
        value.scheme = "tcp"
    end

    if not value.nodes then
        return
    end

    local nodes = value.nodes
    if core.table.isarray(nodes) then
        for _, node in ipairs(nodes) do
            local host = node.host
            if not core.utils.parse_ipv4(host) and
                    not core.utils.parse_ipv6(host) then
                parent.has_domain = true
                break
            end
        end
    else
        local new_nodes = core.table.new(core.table.nkeys(nodes), 0)
        for addr, weight in pairs(nodes) do
            local host, port = core.utils.parse_addr(addr)
            if not core.utils.parse_ipv4(host) and
                    not core.utils.parse_ipv6(host) then
                parent.has_domain = true
            end
            local node = {
                host = host,
                port = port,
                weight = weight,
            }
            core.table.insert(new_nodes, node)
        end
        value.nodes = new_nodes
    end
end
_M.filter_upstream = filter_upstream


function _M.init_worker()
    local err
    upstreams, err = core.config.new("/upstreams", {
            automatic = true,
            item_schema = core.schema.upstream,
            -- also check extra fields in the DP side
            checker = function (item, schema_type)
                return check_upstream_conf(true, item)
            end,
            filter = function(upstream)
                upstream.has_domain = false

                filter_upstream(upstream.value, upstream)

                core.log.info("filter upstream: ", core.json.delay_encode(upstream, true))
            end,
        })
    if not upstreams then
        error("failed to create etcd instance for fetching upstream: " .. err)
        return
    end
end


function _M.get_by_id(up_id)
    local upstream
    local upstreams = core.config.fetch_created_obj("/upstreams")
    if upstreams then
        upstream = upstreams:get(tostring(up_id))
    end

    if not upstream then
        core.log.error("failed to find upstream by id: ", up_id)
        return nil
    end

    if upstream.has_domain then
        local err
        upstream, err = upstream_util.parse_domain_in_up(upstream)
        if err then
            core.log.error("failed to get resolved upstream: ", err)
            return nil
        end
    end

    core.log.info("parsed upstream: ", core.json.delay_encode(upstream, true))
    return upstream.dns_value or upstream.value
end


return _M

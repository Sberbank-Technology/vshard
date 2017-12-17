local log = require('log')
local luri = require('uri')
local lfiber = require('fiber')
local netbox = require('net.box')
local consts = require('vshard.consts')
local util = require('vshard.util')

-- Internal state
local self = {
    --
    -- All known replicasets used for bucket re-balancing.
    -- See format in util.build_replicasets.
    --
    replicasets = nil,
}

--------------------------------------------------------------------------------
-- Schema
--------------------------------------------------------------------------------

local function storage_schema_v1(username, password)
    log.info("Initializing schema")
    box.schema.user.create(username, {password = password})
    box.schema.user.grant(username, 'replication')

    local bucket = box.schema.space.create('_bucket')
    bucket:format({
        {'id', 'unsigned'},
        {'status', 'string'},
        {'destination', 'string', is_nullable = true}
    })
    bucket:create_index('pk', {parts = {'id'}})
    bucket:create_index('status', {parts = {'status'}, unique = false})

    local storage_api = {
        'vshard.storage.call',
        'vshard.storage.bucket_force_create',
        'vshard.storage.bucket_force_drop',
        'vshard.storage.bucket_collect',
        'vshard.storage.bucket_send',
        'vshard.storage.bucket_recv',
        'vshard.storage.bucket_stat',
    }

    for _, name in ipairs(storage_api) do
        box.schema.func.create(name, {setuid = true})
        box.schema.user.grant(username, 'execute', 'function', name)
    end

    box.snapshot()
end

--------------------------------------------------------------------------------
-- Replicaset
--------------------------------------------------------------------------------

-- Vclock comparing function
local function vclock_lesseq(vc1, vc2)
    local lesseq = true
    for i, lsn in ipairs(vc1) do
        lesseq = lesseq and lsn <= (vc2[i] or 0)
        if not lesseq then
            break
        end
    end
    return lesseq
end

local function sync(timeout)
    log.verbose("Synchronizing replicaset...")
    timeout = timeout or consts.SYNC_TIMEOUT
    local vclock = box.info.vclock
    local tstart = lfiber.time()
    local done = false
    repeat
        done = true
        for _, replica in ipairs(box.info.replication) do
            if replica.downstream and
               not vclock_lesseq(vclock, replica.downstream.vclock) then
                done = false
            end
        end
        if not done then
            lfiber.sleep(0.001)
        end
    until not (lfiber.time() <= tstart + timeout and not done)
    if not done then
        log.warn("Timed out during synchronizing replicaset")
        return false
    end
    log.info("Replicaset has been synchronized")
    return true
end

--------------------------------------------------------------------------------
-- Buckets
--------------------------------------------------------------------------------

local function bucket_check_state(bucket_id, mode)
    assert(type(bucket_id) == 'number')
    assert(mode == 'read' or mode == 'write')
    if self.this_replicaset.master ~= self.this_replica then
        -- Add redirect here
        return consts.PROTO.NON_MASTER
    end

    local bucket = box.space._bucket:get({bucket_id})
    if bucket == nil then
        return consts.PROTO.WRONG_BUCKET
    end

    if bucket.status == consts.BUCKET.ACTIVE or
       (bucket.status == consts.BUCKET.SENDING and mode == 'read') then
        return consts.PROTO.OK
    end

    assert(bucket.status == consts.BUCKET_SENDING or
           bucket.status == consts.BUCKET.SENT or
           bucket.status == consts.BUCKET_STATUS_RECEIVING)

    return consts.PROTO.WRONG_BUCKET, {bucket.id, bucket.destination}
end

--
-- Return information about bucket
--
local function bucket_stat(bucket_id)
    if type(bucket_id) ~= 'number' then
        error('Usage: bucket_force_create(bucket_id)')
    end

    local bucket = box.space._bucket:get({bucket_id})
    if bucket == nil or bucket.status ~= consts.BUCKET.ACTIVE then
        return consts.PROTO.WRONG_BUCKET, bucket_id
    end

    return consts.PROTO.OK, {
        id = bucket.id;
        status = bucket.status;
        destination = bucket.destination;
    }
end

--
-- Create bucket manually for initial bootstrap, tests or
-- emergency cases
--
local function bucket_force_create(bucket_id)
    if type(bucket_id) ~= 'number' then
        error('Usage: bucket_force_create(bucket_id)')
    end

    box.space._bucket:insert({bucket_id, consts.BUCKET.ACTIVE})
    return consts.PROTO.OK
end

--
-- Drop bucket manually for tests or emergency cases
--
local function bucket_force_drop(bucket_id)
    if type(bucket_id) ~= 'number' then
        error('Usage: bucket_force_drop(bucket_id)')
    end

    box.space._bucket:delete({bucket_id})
    return consts.PROTO.OK
end


--
-- Receive bucket with its data
--
local function bucket_recv(bucket_id, from, data)
    if type(bucket_id) ~= 'number' or type(data) ~= 'table' then
        error('Usage: bucket_recv(bucket_id, data)')
    end

    local bucket = box.space._bucket:get({bucket_id})
    if bucket ~= nil then
        return consts.PROTO.BUCKET_ALREADY_EXISTS, bucket_id
    end

    bucket = box.space._bucket:insert({bucket_id, consts.BUCKET.RECEIVING, from})

    box.begin()

    -- Fill spaces with data
    for _, row in ipairs(data) do
        local space_id, space_data = row[1], row[2]
        local space = box.space[space_id]
        if space == nil then
            box.error(box.error.NO_SUCH_SPACE, space_id)
            assert(false)
        end
        for _, tuple in ipairs(space_data) do
            space:insert(tuple)
        end
    end

    -- Activate bucket
    bucket = box.space._bucket:replace({bucket_id, consts.BUCKET.ACTIVE})

    box.commit()
    return consts.PROTO.OK
end

local function bucket_collect_internal(bucket_id)
    local data = {}
    for k, space in pairs(box.space) do
        if type(k) == 'number' and space.index.bucket_id ~= nil then
            local space_data = space.index.bucket_id:select({bucket_id})
            table.insert(data, {space.id, space_data})
        end
    end

    return consts.PROTO.OK, data
end

--
-- Collect bucket content
--
local function bucket_collect(bucket_id)
    if type(bucket_id) ~= 'number' then
        error('Usage: bucket_collect(bucket_id)')
    end

    local bucket = box.space._bucket:get({bucket_id})
    if bucket == nil or bucket.status ~= consts.BUCKET.ACTIVE then
        return consts.PROTO.WRONG_BUCKET, bucket_id
    end

    return bucket_collect_internal(bucket_id)
end

--
-- This function executes when a master role is removed from local
-- instance during configuration
--
local function local_master_disable()
    log.verbose("Resigning from the replicaset master role...")
    -- Wait until replicas are synchronized before one another become a new master
    sync(consts.SYNC_TIMEOUT)
    log.info("Resigned from the replicaset master role")
end

--
-- This function executes whan a master role is added to local
-- instance during configuration
--
local function local_master_enable()
    log.verbose("Taking on replicaset master role...")
    -- TODO: check current status
    log.info("Took on replicaset master role")
end

--
-- Send a bucket to other replicaset
--
local function bucket_send(bucket_id, destination)
    if type(bucket_id) ~= 'number' or type(destination) ~= 'string' then
        error('Usage: bucket_send(bucket_id, destination)')
    end

    local bucket = box.space._bucket:get({bucket_id})
    if bucket == nil or bucket.status ~= consts.BUCKET.ACTIVE then
        return consts.PROTO.WRONG_BUCKET, bucket_id
    end
    local replicaset = self.replicasets[destination]
    if replicaset == nil then
        return consts.PROTO.NO_SUCH_REPLICASET, destination
    end

    if destination == box.info.cluster.uuid then
        return consts.PROTO.MOVE_TO_SELF, bucket_id, destination
    end

    local status, data = bucket_collect_internal(bucket_id)
    if status ~= consts.PROTO.OK then
        return status, data
    end

    box.space._bucket:replace({bucket_id, consts.BUCKET.SENDING, destination})

    if replicaset.master.conn == nil then
        local status, conn = pcall(netbox.new, replicaset.master.uri,
                                   {reconnect_after = consts.RECONNECT_TIMEOUT})
        if status ~= true then
            return status, conn
        end
        replicaset.master.conn = conn
    end
    local conn = replicaset.master.conn
    local status, info = pcall(conn.call, conn, 'vshard.storage.bucket_recv',
                               {bucket_id, box.info.cluster.uuid, data})
    if status ~= true then
        -- Rollback bucket state.
        box.space._bucket:replace({bucket_id, consts.BUCKET.ACTIVE})
        return status, info
    end

    box.space._bucket:replace({bucket_id, consts.BUCKET.SENT, destination})

    return true
end


--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- Call wrapper
-- There is two modes for call operation: read and write, explicitly used for
-- call protocol: there is no way to detect what corresponding function does.
-- NOTE: may be a custom function call api without any checks is needed,
-- for example for some monitoring functions.
local function storage_call(bucket_id, mode, name, args)
    if mode ~= 'write' and mode ~= 'read' then
        error('Unknown mode: '..tostring(mode))
    end

    local status, info = bucket_check_state(bucket_id, mode)
    if status ~= consts.PROTO.OK then
        return status, info
    end
    -- TODO: implement box.call()
    return consts.PROTO.OK, netbox.self:call(name, args)
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------
local function storage_cfg(cfg, this_server_uuid)
    cfg = table.deepcopy(cfg)
    if this_server_uuid == nil then
        error('Usage: cfg(configuration, this_server_uuid)')
    end
    util.sanity_check_config(cfg.sharding)
    if self.replicasets ~= nil then
        log.info("Starting reconfiguration of replica %s", this_server_uuid)
    else
        log.info("Starting configuration of replica %s", this_server_uuid)
    end

    local was_master = self.this_replicaset and
                       self.this_replicaset.master == self.this_replica

    local this_replicaset
    local this_replica
    local new_replicasets = util.build_replicasets(cfg, self.replicasets or {},
                                                   false)
    for rs_uuid, rs in pairs(new_replicasets) do
        for replica_uuid, replica in pairs(rs.servers) do
            if replica_uuid == this_server_uuid then
                this_replicaset = rs
                this_replica = replica
                break
            end
        end
        if this_replica ~= nil then
            break
        end
    end
    if this_replicaset == nil then
        error(string.format("Local server %s wasn't found in config",
                            this_server_uuid))
    end

    cfg.listen = cfg.listen or this_replica.uri
    if cfg.replication == nil then
        cfg.replication = {}
        for uuid, server in pairs(this_replicaset.servers) do
            table.insert(cfg.replication, server.uri)
         end
    end
    cfg.instance_uuid = this_replica.uuid
    cfg.replicaset_uuid = this_replicaset.uuid
    cfg.sharding = nil

    local is_master = this_replicaset.master == this_replica
    if is_master then
        log.info('I am master')
    end
    box.cfg(cfg)
    log.info("Box has been configured")
    self.replicasets = new_replicasets
    self.this_replicaset = this_replicaset
    self.this_replica = this_replica
    local uri = luri.parse(this_replica.uri)
    box.once("vshard:storage:1", storage_schema_v1, uri.login, uri.password)

    local is_master = self.this_replicaset and
                      self.this_replicaset.master == self.this_replica
    if was_master and not is_master then
        local_master_disable()
    end

    if not was_master and is_master then
        local_master_enable()
    end

    -- Collect old net.box connections
    collectgarbage('collect')
end

--------------------------------------------------------------------------------
-- Monitoring
--------------------------------------------------------------------------------

local function storage_info()
    local ibuckets = setmetatable({}, { __serialize = 'mapping' })

    for _, bucket in box.space._bucket:pairs() do
        ibuckets[bucket.id] = {
            id = bucket.id;
            status = bucket.status;
            destination = bucket.destination;
        }
    end

    local ireplicaset = {}
    for uuid, replicaset in pairs(self.replicasets) do
        ireplicaset[uuid] = {
            uuid = uuid;
            master = {
                uri = replicaset.master.uri;
                uuid = replicaset.master.conn and replicaset.master.conn.peer_uuid;
                state = replicaset.master.conn and replicaset.master.conn.state;
                error = replicaset.master.conn and replicaset.master.conn.error;
            };
        };
    end

    return {
        buckets = ibuckets;
        replicasets = ireplicaset;
    }
end

--------------------------------------------------------------------------------
-- Module definition
--------------------------------------------------------------------------------

self.sync = sync

return {
    bucket_force_create = bucket_force_create;
    bucket_force_drop = bucket_force_drop;
    bucket_collect = bucket_collect;
    bucket_recv = bucket_recv;
    bucket_send = bucket_send;
    bucket_stat = bucket_stat;
    call = storage_call;
    cfg = storage_cfg;
    info = storage_info;
    internal = self;
}

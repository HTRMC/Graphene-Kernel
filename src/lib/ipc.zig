// Graphene Kernel - IPC Primitives
// Message passing and shared memory IPC

const object = @import("object.zig");
const thread = @import("thread.zig");
const scheduler = @import("scheduler.zig");
const capability = @import("capability.zig");

/// Maximum inline message data
pub const MAX_INLINE_DATA: usize = 256;

/// Maximum capabilities per message
pub const MAX_CAPS_PER_MSG: usize = 4;

/// Maximum pending messages per endpoint
const MAX_PENDING_MESSAGES: usize = 16;

/// IPC message header
pub const MessageHeader = struct {
    /// Length of message data (bytes)
    length: u32 = 0,

    /// Number of capability slots being transferred
    cap_count: u8 = 0,

    /// Message type/tag (application-defined)
    tag: u32 = 0,

    /// Flags
    flags: MessageFlags = .{},
};

/// Message flags
pub const MessageFlags = packed struct(u8) {
    /// This is a reply to a call
    is_reply: bool = false,

    /// Sender wants a reply
    wants_reply: bool = false,

    /// Message is urgent (higher priority)
    urgent: bool = false,

    _reserved: u5 = 0,
};

/// IPC message
pub const Message = struct {
    /// Header
    header: MessageHeader = .{},

    /// Inline data (for small messages)
    data: [MAX_INLINE_DATA]u8 = [_]u8{0} ** MAX_INLINE_DATA,

    /// Capability slots to transfer
    caps: [MAX_CAPS_PER_MSG]capability.CapSlot = [_]capability.CapSlot{capability.INVALID_SLOT} ** MAX_CAPS_PER_MSG,

    /// Clear message
    pub fn clear(self: *Message) void {
        self.header = .{};
        for (&self.data) |*b| b.* = 0;
        for (&self.caps) |*c| c.* = capability.INVALID_SLOT;
    }

    /// Copy data into message
    pub fn setData(self: *Message, data: []const u8) void {
        const len = @min(data.len, MAX_INLINE_DATA);
        for (0..len) |i| {
            self.data[i] = data[i];
        }
        self.header.length = @truncate(len);
    }

    /// Get data from message
    pub fn getData(self: *const Message) []const u8 {
        return self.data[0..@min(self.header.length, MAX_INLINE_DATA)];
    }
};

/// Message queue for async messages
pub const MessageQueue = struct {
    messages: [MAX_PENDING_MESSAGES]Message = [_]Message{.{}} ** MAX_PENDING_MESSAGES,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    /// Enqueue a message
    pub fn enqueue(self: *MessageQueue, msg: *const Message) bool {
        if (self.count >= MAX_PENDING_MESSAGES) {
            return false; // Queue full
        }

        self.messages[self.tail] = msg.*;
        self.tail = (self.tail + 1) % MAX_PENDING_MESSAGES;
        self.count += 1;
        return true;
    }

    /// Dequeue a message
    pub fn dequeue(self: *MessageQueue, msg: *Message) bool {
        if (self.count == 0) {
            return false; // Queue empty
        }

        msg.* = self.messages[self.head];
        self.head = (self.head + 1) % MAX_PENDING_MESSAGES;
        self.count -= 1;
        return true;
    }

    /// Check if empty
    pub fn isEmpty(self: *const MessageQueue) bool {
        return self.count == 0;
    }

    /// Check if full
    pub fn isFull(self: *const MessageQueue) bool {
        return self.count >= MAX_PENDING_MESSAGES;
    }
};

/// IPC endpoint (one end of communication channel)
pub const Endpoint = struct {
    /// Object header
    base: object.Object = object.Object.init(.ipc_endpoint),

    /// Threads waiting to receive
    recv_queue: thread.WaitQueue = .{},

    /// Threads waiting to send (when receiver not ready)
    send_queue: thread.WaitQueue = .{},

    /// Pending messages (for async mode)
    pending: MessageQueue = .{},

    /// Partner endpoint (for channels)
    partner: ?*Endpoint = null,

    /// Endpoint flags
    flags: EndpointFlags = .{},
};

/// Endpoint flags
pub const EndpointFlags = packed struct(u8) {
    /// Async mode (messages queued instead of blocking)
    async_mode: bool = false,

    /// Closed (no more sends allowed)
    closed: bool = false,

    _reserved: u6 = 0,
};

/// IPC channel (bidirectional communication)
pub const Channel = struct {
    /// Object header
    base: object.Object = object.Object.init(.ipc_channel),

    /// Two endpoints
    endpoints: [2]Endpoint = [_]Endpoint{.{}} ** 2,

    /// Shared memory region (optional, for zero-copy)
    shared_memory: ?*object.MemoryObject = null,

    /// Initialize channel with connected endpoints
    pub fn init(self: *Channel) void {
        self.endpoints[0] = .{};
        self.endpoints[1] = .{};
        self.endpoints[0].partner = &self.endpoints[1];
        self.endpoints[1].partner = &self.endpoints[0];
    }
};

/// IPC errors
pub const IpcError = error{
    EndpointClosed,
    WouldBlock,
    InvalidMessage,
    QueueFull,
    CapabilityError,
    NotConnected,
    Timeout,
};

/// Send message via endpoint (blocking)
pub fn send(endpoint: *Endpoint, msg: *const Message, sender_caps: ?*capability.CapTable) IpcError!void {
    if (endpoint.flags.closed) {
        return IpcError.EndpointClosed;
    }

    // Check if there's a waiting receiver
    if (endpoint.recv_queue.dequeue()) |receiver| {
        // Direct handoff
        transferMessage(msg, receiver, sender_caps);
        scheduler.wake(receiver);
        return;
    }

    // No receiver waiting
    if (endpoint.flags.async_mode) {
        // Queue the message
        if (!endpoint.pending.enqueue(msg)) {
            return IpcError.QueueFull;
        }
        return;
    }

    // Synchronous mode - block until receiver arrives
    const sender = scheduler.getCurrent() orelse return IpcError.NotConnected;

    // Store message in sender's context (simplified - would use proper staging)
    endpoint.send_queue.enqueue(sender);
    scheduler.blockCurrent(&endpoint.send_queue);

    // After waking, message has been transferred
}

/// Receive message from endpoint (blocking)
pub fn recv(endpoint: *Endpoint, msg: *Message, receiver_caps: ?*capability.CapTable) IpcError!void {
    _ = receiver_caps;

    // Check for pending messages (async mode)
    if (endpoint.pending.dequeue(msg)) {
        return;
    }

    // Check if there's a waiting sender
    if (endpoint.send_queue.dequeue()) |sender| {
        // Get message from sender (simplified)
        _ = sender;
        // In full implementation, would copy from sender's staging area
        scheduler.wake(sender);
        return;
    }

    if (endpoint.flags.closed) {
        return IpcError.EndpointClosed;
    }

    // No sender waiting - block
    const receiver = scheduler.getCurrent() orelse return IpcError.NotConnected;

    endpoint.recv_queue.enqueue(receiver);
    scheduler.blockCurrent(&endpoint.recv_queue);

    // After waking, message is in staging area
}

/// Call (send + wait for reply)
pub fn call(endpoint: *Endpoint, msg: *const Message, reply: *Message, caps: ?*capability.CapTable) IpcError!void {
    // Set wants_reply flag
    var send_msg = msg.*;
    send_msg.header.flags.wants_reply = true;

    try send(endpoint, &send_msg, caps);

    // Wait for reply on same endpoint (simplified)
    // In full implementation, would have reply endpoint
    try recv(endpoint, reply, caps);
}

/// Reply to a call
pub fn reply(receiver: *thread.Thread, msg: *const Message) IpcError!void {
    var reply_msg = msg.*;
    reply_msg.header.flags.is_reply = true;

    // Wake receiver and transfer message
    transferMessage(&reply_msg, receiver, null);
    scheduler.wake(receiver);
}

/// Non-blocking send
pub fn trySend(endpoint: *Endpoint, msg: *const Message) IpcError!bool {
    if (endpoint.flags.closed) {
        return IpcError.EndpointClosed;
    }

    // Check if there's a waiting receiver
    if (endpoint.recv_queue.dequeue()) |receiver| {
        transferMessage(msg, receiver, null);
        scheduler.wake(receiver);
        return true;
    }

    // No receiver - try to queue
    if (endpoint.flags.async_mode) {
        if (endpoint.pending.enqueue(msg)) {
            return true;
        }
    }

    return false; // Would block
}

/// Non-blocking receive
pub fn tryRecv(endpoint: *Endpoint, msg: *Message) IpcError!bool {
    // Check for pending messages
    if (endpoint.pending.dequeue(msg)) {
        return true;
    }

    // Check for waiting sender
    if (endpoint.send_queue.dequeue()) |sender| {
        _ = sender;
        // Transfer message from sender
        scheduler.wake(sender);
        return true;
    }

    return false; // Would block
}

/// Transfer message (internal helper)
fn transferMessage(msg: *const Message, receiver: *thread.Thread, sender_caps: ?*capability.CapTable) void {
    _ = receiver;
    _ = sender_caps;
    // In full implementation:
    // 1. Copy message data to receiver's buffer
    // 2. Transfer capabilities from sender to receiver's cap table
    // 3. Clear transferred caps from sender
    _ = msg;
}

/// Create IPC endpoint
pub fn createEndpoint() ?*Endpoint {
    // Allocate from pool
    const ep = allocEndpoint() orelse return null;
    ep.* = Endpoint{};
    return ep;
}

/// Create IPC channel
pub fn createChannel() ?*Channel {
    const ch = allocChannel() orelse return null;
    ch.* = Channel{};
    ch.init();
    return ch;
}

/// Close endpoint
pub fn closeEndpoint(endpoint: *Endpoint) void {
    endpoint.flags.closed = true;

    // Wake all waiting threads with error
    while (endpoint.recv_queue.dequeue()) |t| {
        scheduler.wake(t);
    }

    while (endpoint.send_queue.dequeue()) |t| {
        scheduler.wake(t);
    }
}

/// Setup shared memory for channel
pub fn setupSharedMemory(channel: *Channel, memory: *object.MemoryObject) void {
    channel.shared_memory = memory;
    memory.base.ref();
}

// Allocation pools for Phase 1
const MAX_ENDPOINTS: usize = 256;
var endpoint_pool: [MAX_ENDPOINTS]Endpoint = undefined;
var endpoint_used: [MAX_ENDPOINTS]bool = [_]bool{false} ** MAX_ENDPOINTS;

const MAX_CHANNELS: usize = 128;
var channel_pool: [MAX_CHANNELS]Channel = undefined;
var channel_used: [MAX_CHANNELS]bool = [_]bool{false} ** MAX_CHANNELS;

fn allocEndpoint() ?*Endpoint {
    for (&endpoint_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            return &endpoint_pool[i];
        }
    }
    return null;
}

fn freeEndpoint(ep: *Endpoint) void {
    const index = (@intFromPtr(ep) - @intFromPtr(&endpoint_pool)) / @sizeOf(Endpoint);
    if (index < MAX_ENDPOINTS) {
        endpoint_used[index] = false;
    }
}

fn allocChannel() ?*Channel {
    for (&channel_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            return &channel_pool[i];
        }
    }
    return null;
}

fn freeChannel(ch: *Channel) void {
    const index = (@intFromPtr(ch) - @intFromPtr(&channel_pool)) / @sizeOf(Channel);
    if (index < MAX_CHANNELS) {
        channel_used[index] = false;
    }
}

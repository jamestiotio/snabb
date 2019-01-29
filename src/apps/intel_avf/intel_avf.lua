-- intel_avf: Device driver that conforms to the Intel Adaptive Virtual
-- Function specification
-- https://www.intel.com/content/dam/www/public/us/en/documents/product-specifications/ethernet-adaptive-virtual-function-hardware-spec.pdf
-- pgXXX in the comments refers to that page in v1.0 of the specification, released Feb 2018

module(..., package.seeall)

local ffi         = require("ffi")
local lib         = require("core.lib")
local macaddress  = require("lib.macaddress")
local pci         = require("lib.hardware.pci")
local register    = require("lib.hardware.register")
local tophysical  = core.memory.virtual_to_physical
local band        = bit.band
local transmit, receive, empty = link.transmit, link.receive, link.empty
local counter     = require("core.counter")

local bits        = lib.bits
local C           = ffi.C

local MAC_ADDR_BYTE_LEN = 6

Intel_avf = {
   config = {
      pciaddr = { required=true },
      ring_buffer_size = {default=2048}
   }
}

function Intel_avf:load_registers()
   local scalar_registers = [[
      VFGEN_RSTAT       0x00008800 -       RW   VF Reset Status
      VFINT_DYN_CTL0    0x00005C00 -       RW   VF Interrupt Dynamic Control Zero
      VF_ATQBAL         0x00007C00 -       RW   VF MailBox Transmit Queu e Base Address Low
      VF_ATQBAH         0x00007800 -       RW   VF MailBox Transmit Queue Base Address High
      VF_ATQLEN         0x00006800 -       RW   VF MailBox Transmit Queue Length
      VF_ATQH           0x00006400 -       RW   VF MailBox Transmit Head
      VF_ATQT           0x00008400 -       RW   VF MailBox Transmit Tail
      VF_ARQBAL         0x00006C00 -       RW   VF MailBox Receive Queue Base Address Low
      VF_ARQBAH         0x00006000 -       RW   VF MailBox Receive Queue Base Address High
      VF_ARQLEN         0x00008000 -       RW   VF MailBox Receive Queue Length
      VF_ARQH           0x00007400 -       RW   VF MailBox Receive Head
      VF_ARQT           0x00007000 -       RW   VF MailBox Receive Tail
   ]]

   -- VFINT_ITRN[n,m] is not handled well by lib.hardware.register
   local array_registers = [[
      VFINT_DYN_CTLN    0x00003800 +0x4*0..63      RW    VF Interrupt Dynamic Control N
      VFINT_ITR0        0x00004C00 +0x4*0..2       RW    VF Interrupt Throttling Zero
      QTX_TAIL          0x00000000 +0x4*0..255     RW    Transmit Queue Tail
      QRX_TAIL          0x00002000 +0x4*0..255     RW    Receive Queue Tail
   ]]
   register.define(scalar_registers, self.r, self.base)
   register.define_array(array_registers, self.r, self.base)
end

-- Section 2.1.2.1.2 & 2.1.2.2.2 pg12 & pg16
local rxdesc_t = ffi.typeof([[
   union {
      struct {
         uint64_t address;
         uint64_t pad1;
         uint64_t pad2;
         uint64_t pad3;
      } __attribute__((packed)) read;
      struct {
         uint64_t pad0;
         uint64_t status_err_type_len;
         uint64_t pad2;
         uint64_t pad3;
      } __attribute__((packet)) write;
   }
]])
local rxdesc_ptr_t = ffi.typeof("$ *", rxdesc_t)

-- section 2.2.2.2 pg22
local txdesc_t = ffi.typeof([[
   struct {
      uint64_t address;
      uint64_t cmd_type_offset_bsz;
   } __attribute__((packed))
]])
local txdesc_ptr_t = ffi.typeof("$ *", txdesc_t)

local queue_select_t = ffi.typeof([[
   struct {
      uint16_t vsi_id;
      uint16_t pad;
      uint32_t rx_queues;
      uint32_t tx_queues;
   } __attribute__((packed))
]])
local queue_select_ptr_t = ffi.typeof("$ *", queue_select_t)

local virtchnl_msg_t = ffi.typeof([[
   struct {
      uint64_t pad0;
      uint32_t opcode;
      int32_t status;
      uint32_t vfid;
   } __attribute__((packed))
]])
local virtchnl_msg_ptr_t = ffi.typeof("$ *", virtchnl_msg_t)

local virtchnl_q_pair_t = ffi.typeof([[
   struct {
      uint16_t vsi_id;
      uint16_t num_queue_pairs;
      uint32_t pad;

      uint16_t tx_vsi_id;
      uint16_t tx_queue_id;
      uint16_t tx_ring_len;
      uint16_t tx_deprecated0;
      uint64_t tx_dma_ring_addr;
      uint64_t tx_deprecated1;

      uint16_t rx_vsi_id;
      uint16_t rx_queue_id;
      uint32_t rx_ring_len;
      uint16_t rx_hdr_size;
      uint16_t rx_deprecated0;
      uint32_t rx_databuffer_size;
      uint32_t rx_max_pkt_size;
      uint32_t rx_pad0;
      uint64_t rx_dma_ring_addr;
      uint32_t rx_deprecated1;
      uint32_t rx_pad1;
   } __attribute__((packed))
]])
local virtchnl_q_pair_ptr_t = ffi.typeof("$ *", virtchnl_q_pair_t)

local virtchnl_ether_addr_t = ffi.typeof([[
   struct {
      uint16_t vsi;
      uint16_t num_elements;
      uint8_t addr[6]; // MAC_ADDR_BYTE_LEN
      uint8_t pad[2];
   } __attribute__((packed))
]])
local virtchnl_ether_addr_ptr_t = ffi.typeof("$ *", virtchnl_ether_addr_t)

local eth_stats_t = ffi.typeof([[
   struct {
        uint64_t rx_bytes;
        uint64_t rx_unicast;
        uint64_t rx_multicast;
        uint64_t rx_broadcast;
        uint64_t rx_discards;
        uint64_t rx_unknown_protocol;
        uint64_t tx_bytes;
        uint64_t tx_unicast;
        uint64_t tx_multicast;
        uint64_t tx_broadcast;
        uint64_t tx_discards;
        uint64_t tx_errors;
   } __attribute__((packed))
]])
local eth_stats_ptr_t = ffi.typeof("$ *", eth_stats_t)

local virtchnl_vf_resources_t = ffi.typeof([[
   struct {
      uint16_t num_vsis;
      uint16_t num_queue_pairs;
      uint16_t max_vectors;
      uint16_t max_mtu;
      uint32_t vf_offload_flag;
      uint32_t rss_key_size;
      uint32_t rss_lut_size;

      uint16_t vsi_id;
      uint16_t vsi_queue_pairs;
      uint32_t vsi_type;
      uint16_t qset_handle;
      uint8_t default_mac_addr[6];
   } __attribute__((packed))
]])
local virtchnl_vf_resources_ptr_t = ffi.typeof('$*', virtchnl_vf_resources_t)

local virtchnl_version_t = ffi.typeof([[
   struct {
      uint32_t major;
      uint32_t minor;
   } __attribute__((packed))
]])
local virtchnl_version_ptr_t = ffi.typeof('$*', virtchnl_version_t)

function Intel_avf:init_tx_q()
   self.txdesc = ffi.cast(txdesc_ptr_t,
   memory.dma_alloc(ffi.sizeof(txdesc_t) * self.ring_buffer_size))
   ffi.fill(self.txdesc, ffi.sizeof(txdesc_t) * self.ring_buffer_size)
   self.txqueue = ffi.new("struct packet *[?]", self.ring_buffer_size)
   for i=0, self.ring_buffer_size - 1 do
      self.txqueue[i] = nil
      self.txdesc[i].cmd_type_offset_bsz = 0
   end
end

function Intel_avf:init_rx_q()
   self.rxqueue = ffi.new("struct packet *[?]", self.ring_buffer_size)
   self.rxdesc = ffi.cast(rxdesc_ptr_t,
   memory.dma_alloc(ffi.sizeof(rxdesc_t) * self.ring_buffer_size), 128)

   for i = 0, self.ring_buffer_size-1 do
      local p = packet.allocate()
      self.rxqueue[i] = p
   self.rxdesc[i].read.address = tophysical(p.data)
      self.rxdesc[i].write.status_err_type_len = 0
   end
end

function Intel_avf:supported_hardware()
   local vendor = lib.firstline(self.path .. "/vendor")
   local device = lib.firstline(self.path .. "/device")
   local devices = {
      -- Ethernet controller [0200]: Intel Corporation Ethernet Virtual Function 700 Series [8086:154c] (rev 02)
      "0x154c",
      -- pg8
      "0x1889"
   }
   assert(vendor == '0x8086', "unsupported nic vendor: " .. vendor)

   for _,v in pairs(devices) do
      if device == v then return end
   end
   assert(devices[device] == true, "unsupported nic version: " .. device)
end

function Intel_avf:mbox_setup_rxq()
   self.mbox.rxq =
      memory.dma_alloc(self.mbox.q_byte_len, self.mbox.q_alignment)
   ffi.fill(self.mbox.rxq, self.mbox.q_byte_len)
   self.mbox.rxq = ffi.cast(ffi.typeof("$*", self.mbox.q_t), self.mbox.rxq)

   for i=0,self.mbox.q_len-1 do
      local ptr = ffi.cast("uint8_t *", memory.dma_alloc(self.mbox.datalen))
      ffi.fill(ptr, self.mbox.datalen)

      self.mbox.rxq_buffers[i] = ptr

      self.mbox.rxq[i].data_addr_high =
         tophysical(self.mbox.rxq_buffers[i]) / 2^32

      self.mbox.rxq[i].data_addr_low =
         tophysical(self.mbox.rxq_buffers[i]) % 2^32

      self.mbox.rxq[i].datalen = self.mbox.datalen
      self.mbox.rxq[i].flags0 = 0
      self.mbox.rxq[i].flags1 =
         bits({LARGE_BUFFER = 1, BUFFER=4, NO_INTERRUPTS=5})
   end
   self.r.VF_ARQBAL(tophysical(self.mbox.rxq) % 2^32)
   self.r.VF_ARQBAH(tophysical(self.mbox.rxq) / 2^32)
   self.r.VF_ARQH(0)
   self.r.VF_ARQT(self.mbox.q_len-1)
   self.mbox.next_recv_idx = 0

   -- set length and enable the queue
   self.r.VF_ARQLEN(bits({ ENABLE = 31 }) + self.mbox.q_len)
end

function Intel_avf:mbox_setup_txq()
   self.mbox.txq = memory.dma_alloc(self.mbox.q_byte_len, self.mbox.q_alignment)
   ffi.fill(self.mbox.txq, self.mbox.q_byte_len)
   self.mbox.txq = ffi.cast(ffi.typeof("$*", self.mbox.q_t), self.mbox.txq )

   for i=0,self.mbox.q_len-1 do
      local ptr = ffi.cast("uint8_t *", memory.dma_alloc(4096))

      self.mbox.txq_buffers[i] = ptr

      self.mbox.txq[i].data_addr_high =
      tophysical(self.mbox.txq_buffers[i]) / 2^32

      self.mbox.txq[i].data_addr_low =
      tophysical(self.mbox.txq_buffers[i]) % 2^32
   end
   self.r.VF_ATQBAL(tophysical(self.mbox.txq) % 2^32)
   self.r.VF_ATQBAH(tophysical(self.mbox.txq) / 2^32)
   self.r.VF_ATQH(0)
   self.r.VF_ATQT(0)
   self.mbox.next_send_idx = 0

   -- set length and enable the queue
   self.r.VF_ATQLEN(bits({ ENABLE = 31 }) + self.mbox.q_len)
end

function Intel_avf:mbox_sr_q()
   local tt = self:mbox_send_buf(virtchnl_q_pair_ptr_t)

   tt.vsi_id = self.vsi_id
   tt.num_queue_pairs = 1

   tt.tx_vsi_id = self.vsi_id
   tt.tx_queue_id = self.qno
   tt.tx_ring_len = self.ring_buffer_size
   tt.tx_dma_ring_addr = tophysical(self.txdesc)

   tt.rx_vsi_id = self.vsi_id
   tt.rx_queue_id = self.qno
   tt.rx_ring_len = self.ring_buffer_size
   -- Only 32 byte rxdescs are supported, at least by the PF driver in
   -- centos 7 3.10.0-957.1.3.el7.x86_64
   tt.rx_hdr_size = 32
   tt.rx_databuffer_size = core.packet.max_payload
   tt.rx_max_pkt_size = core.packet.max_payload
   tt.rx_dma_ring_addr = tophysical(self.rxdesc)

   self:mbox_sr('VIRTCHNL_OP_CONFIG_VSI_QUEUES', ffi.sizeof(virtchnl_q_pair_t) + 64)

   -- FIXME why do we sleep?
   C.usleep(1000*1000)
   self.r.rx_tail = self.r.QRX_TAIL[self.qno]
   self.r.tx_tail = self.r.QTX_TAIL[self.qno]
   self.rx_tail = 0
   self.r.rx_tail(self.ring_buffer_size - 1)
end

function Intel_avf:mbox_sr_enable_q ()
   local tt = self:mbox_send_buf(queue_select_ptr_t)

   tt.vsi_id = self.vsi_id
   tt.pad = 0
   tt.rx_queues = bits({ ENABLE = self.qno })
   tt.tx_queues = bits({ ENABLE = self.qno })
   self:mbox_sr('VIRTCHNL_OP_ENABLE_QUEUES', ffi.sizeof(queue_select_t))
end

function Intel_avf:ringnext (index)
   return band(index+1, self.ring_buffer_size - 1)
end

function Intel_avf:reclaim_txdesc ()
   local RS = bits({ RS = 5 })
   local COMPLETE = 15

   while band(self.txdesc[ self:ringnext(self.tx_cand) ].cmd_type_offset_bsz, COMPLETE) == COMPLETE
         and self.tx_desc_free < self.ring_buffer_size do
      local c = self.tx_cand
      if self.txqueue[c] ~= nil then
         packet.free(self.txqueue[c])
         self.txqueue[c] = nil
      end
      self.tx_cand = self:ringnext(self.tx_cand)
      self.tx_desc_free = self.tx_desc_free + 1
   end
end

function Intel_avf:push ()
   local li = self.input.input
   if li == nil then return end

   local RS_EOP = bits({ EOP = 4, RS = 5 })
   local SIZE_SHIFT = 34

   self:reclaim_txdesc()
   while not empty(li) and self.tx_desc_free > 0 do
      local p = receive(li)
      self.txdesc[ self.tx_next ].address = tophysical(p.data)
      self.txqueue[ self.tx_next ] = p
      self.txdesc[ self.tx_next ].cmd_type_offset_bsz = RS_EOP + p.length * 2^SIZE_SHIFT
      self.tx_next = self:ringnext(self.tx_next)
      self.tx_desc_free = self.tx_desc_free - 1
   end
   C.full_memory_barrier()
   self.r.tx_tail(band(self.tx_next-1, self.ring_buffer_size - 1))
   -- self:mbox_sr_stats()
end

function Intel_avf:pull()
   local lo = self.output.output
   if lo == nil then return end

   local pkts = 0
   while band(self.rxdesc[self.rx_tail].write.status_err_type_len, 0x01) == 1 and pkts < engine.pull_npackets do
      local p = self.rxqueue[self.rx_tail]
      p.length = bit.rshift(self.rxdesc[self.rx_tail].write.status_err_type_len, 38)
      transmit(lo, p)

      local np = packet.allocate()
      self.rxqueue[self.rx_tail] = np
      self.rxdesc[self.rx_tail].read.address = tophysical(np.data)
      self.rxdesc[self.rx_tail].write.status_err_type_len = 0
      self.rx_tail = band(self.rx_tail + 1, self.ring_buffer_size-1)
      pkts = pkts + 1
   end
   -- This avoids the queue being full / empty when HEAD=TAIL
   C.full_memory_barrier()
   self.r.rx_tail(band(self.rx_tail - 1, self.ring_buffer_size - 1))
end

function Intel_avf:mbox_setup()
   local dlen = 4096
   self.mbox = {
      q_len = 64,
      -- FIXME find reference
      q_alignment = 64,
      datalen = dlen,
      txq_buffers = {},
      rxq_buffers = {},
      send_buf = memory.dma_alloc(dlen)
   }
   self.mbox.q_t = ffi.typeof([[
      struct {
         uint8_t flags0;
         uint8_t flags1;
         uint16_t opcode;
         uint16_t datalen;
         uint16_t return_value;
         uint32_t cookie_high;
         uint32_t cookie_low;
         uint32_t param0;
         uint32_t param1;
         uint32_t data_addr_high;
         uint32_t data_addr_low;
      } __attribute__((packed))
   ]])
   self.mbox.q_byte_len = self.mbox.q_len * ffi.sizeof(self.mbox.q_t)

   self.mbox.hwopcodes = {
      SEND_TO_PF     = 0x0801,
      RECV_FROM_PF   = 0x0802,
      SHUTDOWN_QUEUE = 0x0803
   }
   self.mbox.opcodes = {
      VIRTCHNL_OP_UNKNOWN = 0,
      VIRTCHNL_OP_VERSION = 1,
      VIRTCHNL_OP_RESET_VF = 2,
      VIRTCHNL_OP_GET_VF_RESOURCES = 3,
      -- 4/5 unsupported by CentOS 7 PF
      -- VIRTCHNL_OP_CONFIG_TX_QUEUE = 4,
      -- VIRTCHNL_OP_CONFIG_RX_QUEUE = 5,
      VIRTCHNL_OP_CONFIG_VSI_QUEUES = 6,
      -- VIRTCHNL_OP_CONFIG_IRQ_MAP = 7,
      VIRTCHNL_OP_ENABLE_QUEUES = 8,
      VIRTCHNL_OP_DISABLE_QUEUES = 9,
      -- VIRTCHNL_OP_ADD_ETH_ADDR = 10,
      -- VIRTCHNL_OP_DEL_ETH_ADDR = 11,
      -- VIRTCHNL_OP_ADD_VLAN = 12,
      -- VIRTCHNL_OP_DEL_VLAN = 13,
      -- VIRTCHNL_OP_CONFIG_PROMISCUOUS_MODE = 14,
      VIRTCHNL_OP_GET_STATS = 15,
      -- VIRTCHNL_OP_RSVD = 16,
      VIRTCHNL_OP_EVENT = 17,
      -- VIRTCHNL_OP_IWARP = 20,
      -- VIRTCHNL_OP_CONFIG_IWARP_IRQ_MAP = 21,
      -- VIRTCHNL_OP_RELEASE_IWARP_IRQ_MAP = 22,
      -- VIRTCHNL_OP_CONFIG_RSS_KEY = 23,
      -- VIRTCHNL_OP_CONFIG_RSS_LUT = 24,
      -- VIRTCHNL_OP_GET_RSS_HENA_CAPS = 25,
      -- VIRTCHNL_OP_SET_RSS_HENA = 26
   }
   self:mbox_setup_rxq()
   self:mbox_setup_txq()
end

function Intel_avf:mbox_sr(opcode, datalen)
   opcode = self.mbox.opcodes[opcode]
   self:mbox_send(opcode, datalen)
   return self:mbox_recv()
end

function Intel_avf:mbox_send(opcode, datalen)
   self:mbox_send_p1(opcode, datalen)
   self:mbox_send_p2(opcode, datalen)
end
-- Splitting mbox_send into 2 parts so that each can be called on a
-- different breath reducing the per breath latency
function Intel_avf:mbox_send_p1(opcode, datalen)
   local idx = self.mbox.next_send_idx
   self.mbox.tmp_idx = idx
   self.mbox.next_send_idx = ( idx + 1 ) % self.mbox.q_len

   self.mbox.txq[idx].flags0 = 0
   self.mbox.txq[idx].flags1 = 0

   self.mbox.txq[idx].opcode = self.mbox.hwopcodes['SEND_TO_PF']
   if datalen > 512 then
      self.mbox.txq[idx].flags0 =
         bit.bor(self.mbox.txq[idx].flags0, bits({ LARGE_BUFFER = 1 }))
   end
   self.mbox.txq[idx].flags1
      = bits({ INDIRECT_BUFFER = 2, BUFFER = 4, NO_INTERRUPTS = 5 })
   self.mbox.txq[idx].datalen = datalen
   self.mbox.txq[idx].cookie_high = opcode
   self.mbox.txq[idx].data_addr_high = tophysical(self.mbox.send_buf) / 2^32
   self.mbox.txq[idx].data_addr_low = tophysical(self.mbox.send_buf) % 2^32

   self.r.VF_ATQT(self.mbox.next_send_idx)
   return
end
function Intel_avf:mbox_send_p2()
   -- Wait for the mailbox to process the send
   -- FIXME Wait with timeout ?
   -- FIXME assert on timeout ?

   local idx = self.mbox.tmp_idx
   self.mbox.tmp_idx = nil
   lib.waitfor(function()
      return self.r.VF_ATQT() == self.mbox.next_send_idx
   end)
   lib.waitfor(function()
      -- 1 == bits({ DescriptorDone = 0 })
      -- 2 == bits({ Complete = 1 })
      return band(self.mbox.txq[idx].flags0, 1) == 1 and
         band(self.mbox.txq[idx].flags0, 2) == 2
   end)
   -- assert error bit is not set
   assert(band(self.mbox.txq[idx].flags0, 4) == 0)
   assert(self.mbox.txq[idx].return_value == 0)
   return
end

function Intel_avf:mbox_send_buf (t)
   ffi.fill(self.mbox.send_buf, self.mbox.datalen)
   return ffi.cast(t, self.mbox.send_buf)
end

function Intel_avf:mbox_sr_version()
   local tt = self:mbox_send_buf(virtchnl_version_ptr_t)
   tt[0].major = 1;
   tt[0].minor = 1;
   self:mbox_sr('VIRTCHNL_OP_VERSION', ffi.sizeof(virtchnl_version_t))
end

function Intel_avf:mbox_sr_caps()
   -- FIXME use mbox_send_buf
   -- FIXME move type up top
   -- avf_get_vf_resource(struct avf_adapter *adapter)
   -- in
   -- dpdk/drivers/net/avf/avf_vchnl.c
   local supported_caps = bits({
      VIRTCHNL_VF_OFFLOAD_L2 = 0,
      VIRTCHNL_VF_OFFLOAD_VLAN = 16,
      VIRTCHNL_VF_OFFLOAD_RX_POLLING = 17
   })
   ffi.cast('uint32_t *', self.mbox.send_buf)[0] = supported_caps
   local rcvd = self:mbox_sr('VIRTCHNL_OP_GET_VF_RESOURCES', ffi.sizeof('uint32_t'))

   local tt = ffi.cast(virtchnl_vf_resources_ptr_t, rcvd)[0]

   assert(tt.num_vsis == 1, "Only 1 vsi supported")

   -- pg76
   assert(tt.vsi_type == 6, "vsi_type must be VSI_SRIOV (6)")

   assert(bit.band(tt.vf_offload_flag, supported_caps) == supported_caps,
      "PF driver doesn't support the required capabilities")

   self.vsi_id = tt.vsi_id
   -- FIXME Is this needed?
   self.mac = macaddress:from_bytes(tt.default_mac_addr)
end

function Intel_avf:mbox_recv()
   local idx = self.mbox.next_recv_idx
   self.mbox.next_recv_idx = ( idx + 1 ) % self.mbox.q_len

   lib.waitfor(function()
      return bit.band(self.mbox.rxq[idx].flags0, 1) == 1
   end)

   assert(bit.band(self.mbox.rxq[idx].flags0, bits({ ERR = 2 })) == 0)

   local msg_status = ffi.cast(virtchnl_msg_ptr_t, self.mbox.rxq + idx)[0].status
   assert(msg_status == 0, "failure in PF")
   local opcode = ffi.cast(virtchnl_msg_ptr_t, self.mbox.rxq + idx)[0].opcode

   local bflag = bits({ ExternalBuf = 4 })
   local ptr
   if band(self.mbox.rxq[idx].flags1, bflag) == bflag then
      ptr = ffi.new("uint8_t[?]", self.mbox.rxq[idx].datalen)
      ffi.copy(ptr, self.mbox.rxq_buffers[idx], self.mbox.rxq[idx].datalen)
   end

   self.mbox.rxq[idx].datalen = self.mbox.datalen
   self.mbox.rxq[idx].flags0 = 0
   self.mbox.rxq[idx].flags1 = bits({LARGE_BUFFER = 1, BUFFER=4, NO_INTERRUPTS=5})
   ffi.fill(self.mbox.rxq_buffers[idx], self.mbox.datalen)

   self.r.VF_ARQT( idx )
   if opcode == self.mbox.opcodes['VIRTCHNL_OP_EVENT'] then
      return self:mbox_recv()
   end
   return ptr
end

function Intel_avf:wait_for_vfgen_rstat()
   -- Constant names stolen from DPDK drivers/net/avf/base/virtchnl.h
   -- Section 6.1 on page 51
   local mask0 = bits( { VIRTCHNL_VFR_COMPLETED = 1 })
   local mask1 = bits( { VIRTCHNL_VFR_VFACTIVE = 2 })
   lib.waitfor(function ()
         local v = self.r.VFGEN_RSTAT()
         return bit.band(mask0, v) == mask0 or bit.band(mask1, v) == mask1
   end)
end

function Intel_avf:new(conf)
   local self = {
      pciaddress = conf.pciaddr,
      path = pci.path(conf.pciaddr),
      r = {},
      ring_buffer_size = conf.ring_buffer_size,

      tx_next = 0,
      tx_cand = 0,
      tx_desc_free = conf.ring_buffer_size - 1,
      qno = 0,
      shm = {
         rx_bytes       = {counter},
         rx_unicast     = {counter},
         rx_multicast   = {counter},
         rx_broadcast   = {counter},
         rx_discards    = {counter},
         rx_unknown_protocol = {counter},
         tx_bytes       = {counter},
         tx_unicast     = {counter},
         tx_multicast   = {counter},
         tx_broadcast   = {counter},
         tx_discards    = {counter},
         tx_errors      = {counter}
      },
      throttle = lib.throttle(0.5),
      stats_pos = 0,
   }

   -- pg79 /* number of descriptors, multiple of 32 */
   assert(self.ring_buffer_size % 32 == 0,
      "ring_buffer_size must be a multiple of 32")

   self = setmetatable(self, { __index = Intel_avf })
   self:supported_hardware()
   self.base, self.fd = pci.map_pci_memory_unlocked(self.pciaddress, 0)
   self:load_registers()
   pci.unbind_device_from_linux(self.pciaddress)
   pci.set_bus_master(self.pciaddress, true)
   pci.disable_bus_master_cleanup(self.pciaddress)

   self:wait_for_vfgen_rstat()
   self:mbox_setup()
   self:mbox_sr_version()
   self:mbox_sr_caps()
   self:init_tx_q()
   self:init_rx_q()
   self:mbox_sr_q()
   self:mbox_sr_enable_q()
   return self
end

function Intel_avf:mbox_sr_add_mac()
   -- pg81
   local tt = self:mbox_send_buf(virtchnl_ether_addr_ptr_t)
   tt.vsi = self.vsi_id
   tt.num_elements = 1
   ffi.copy(tt.addr, self.mac, MAC_ADDR_BYTE_LEN)
   self:mbox_sr('VIRTCHNL_OP_ADD_ETH_ADDR', ffi.sizeof(virtchnl_ether_addr_t) + 8)
end

function Intel_avf:mbox_sr_stats()
   if self.throttle() == false then
      return
   end
   if self.stats_pos == 0 then
      local tt = self:mbox_send_buf(queue_select_ptr_t)
      tt.vsi_id = self.vsi_id
      local opcode = self.mbox.opcodes['VIRTCHNL_OP_GET_STATS']
      self:mbox_send_p1(opcode, ffi.sizeof(queue_select_t))
      self.stats_pos = 1
   elseif self.stats_pos == 1 then
      self:mbox_send_p2()
      self.stats_pos = 2
   elseif self.stats_pos == 2 then
      local stats = ffi.cast(eth_stats_ptr_t, self:mbox_recv())
      local set = counter.set
      set(self.shm.rx_bytes,     stats.rx_bytes)
      set(self.shm.rx_unicast,   stats.rx_unicast)
      set(self.shm.rx_multicast, stats.rx_multicast)
      set(self.shm.rx_broadcast, stats.rx_broadcast)
      set(self.shm.rx_discards,  stats.rx_discards)
      set(self.shm.rx_unknown_protocol,   stats.rx_unknown_protocol)

      set(self.shm.tx_bytes,     stats.tx_bytes)
      set(self.shm.tx_unicast,   stats.tx_unicast)
      set(self.shm.tx_multicast, stats.tx_multicast)
      set(self.shm.tx_broadcast, stats.tx_broadcast)
      set(self.shm.tx_discards,  stats.tx_discards)
      set(self.shm.tx_errors,    stats.tx_errors)
      self.stats_pos = 0
   end
end


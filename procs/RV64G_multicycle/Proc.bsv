
// Copyright (c) 2016, 2017 Massachusetts Institute of Technology

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

`include "ProcConfig.bsv"

import BuildVector::*;
import DefaultValue::*;
import ClientServer::*;
import Clocks::*;
import Connectable::*;
import FIFO::*;
import GetPut::*;
import Vector::*;

import ClientServerUtil::*;
import FIFOG::*;
import Port::*;
import PortUtil::*;
import PrintTrace::*;

import Abstraction::*;
import BasicMemorySystemBlocks::*;
import BootRom::*;
import Core::*;
import MemorySystem::*;
import MemoryMappedCSRs::*;
import ProcPins::*;
import RVTypes::*;
import VerificationPacket::*;
import VerificationPacketFilter::*;

// This is used by ProcConnectal
typedef DataSz MainMemoryWidth;

(* synthesize *)
module mkProc(Proc#(DataSz));
    // ROM Addresses
    // 0x0000_0000 - 0x3FFF_FFFF
    Addr romBaseAddr            = 'h0000_0000;
    Addr rstvec                 = 'h0000_1000;
    Addr nmivec                 = 'h0000_1004;
    Addr configStringPtr        = 'h0000_100C;
    Addr mtvecDefault           = 'h0000_1010;
    // Internal Memory-Mapped IO Addresses
    // 0x4000_0000 - 0x5FFF_FFFF
    Addr mmioBaseAddr           = 'h4000_0000;
    Addr rtcBaseAddr            = 'h4000_0000;
    Addr ipiBaseAddr            = 'h4000_1000;
    // External Memory-Mapped IO Addresses
    // 0x6000_0000 - 0x7FFF_FFFF
    Addr externalMMIOBaseAddr   = 'h6000_0000;
    // DRAM Addresses
    // 0x8000_0000 - end of address space
    Addr dramBaseAddr           = 'h8000_0000;

    let clock <- exposeCurrentClock;
    let clockGating <- mkGatedClockFromCC(True);
    let gated_clock = clockGating.new_clk;

    // This function assumes romBaseAddr < mmioBaseAddr < dramBaseAddr
    function PMA getPMA(Addr addr);
        if (addr < mmioBaseAddr) begin
            return IORom;
        end else if (addr < dramBaseAddr) begin
            return IODevice;
        end else begin
            return MainMemory;
        end
    endfunction

    Wire#(Bool) extInterruptWire <- mkDWire(False);

    let bootrom <- mkBasicBootRom(BootRomConfig {
                                    bootrom_addr: rstvec,
                                    start_addr: dramBaseAddr,
                                    config_string_addr: configStringPtr });

    SingleCoreMemorySystem#(DataSz) memorySystem <- mkBasicMemorySystem(getPMA);
    MemoryMappedCSRs#(1) mmcsrs <- mkMemoryMappedCSRs(mmioBaseAddr);
    Core core <- mkMulticycleCore(
                    memorySystem.core[0].ivat,
                    memorySystem.core[0].ifetch,
                    memorySystem.core[0].dvat,
                    memorySystem.core[0].dmem,
                    mmcsrs.ipi[0], // inter-process interrupt
                    mmcsrs.timerInterrupt[0], // timer interrupt
                    mmcsrs.timerValue,
                    extInterruptWire, // external interrupt
                    0, // hart ID
                    clocked_by gated_clock);

    // +----------------+ +---------------+
    // |      Core      | | verification  |
    // |                |-| packet filter |
    // +----------------+ +---------------+
    //   || ||    || |||
    // +----------------+
    // | memory system  |
    // +----------------+

    let core_to_mem <- mkConnection(core, memorySystem.core[0]);

    // Memory Mapped IO connections
    FIFOG#(UncachedMemReq) externalMMIOReqFIFO <- mkFIFOG;
    FIFOG#(UncachedMemResp) externalMMIORespFIFO <- mkFIFOG;
    UncachedMemServerPort externalMMIOServer = toServerPort(externalMMIOReqFIFO, externalMMIORespFIFO);
    UncachedMemClientPort externalMMIOClient = toClientPort(externalMMIOReqFIFO, externalMMIORespFIFO);
    let memoryMappedIO <- mkMemoryBusV2(vec(
                            busItemFromAddrRange( 'h0000_1000, 'h0000_100F, bootrom ),
                            busItemFromAddrRange( 'h4000_0000, 'h5FFF_FFFF, mmcsrs.memifc ),
                            busItemFromAddrRange( 'h6000_0000, 'h7FFF_FFFF, externalMMIOServer )));
    let uncached_mem_connection <- mkConnection(memorySystem.uncachedMemory, memoryMappedIO.procIfc);

    // Cached Memory Connection
    FIFOG#(MainMemReq) ramReqFIFO <- mkFIFOG;
    FIFOG#(MainMemResp) ramRespFIFO <- mkFIFOG;
    MainMemServerPort ramServer = toServerPort(ramReqFIFO, ramRespFIFO);
    MainMemClientPort ramClient = toClientPort(ramReqFIFO, ramRespFIFO);
    function MainMemReq adjustAddress(Addr a, MainMemReq r);
        r.addr = r.addr - a;
        return r;
    endfunction
    Integer maxPendingReq = 2;
    let cachedMemBridge = transformServerPortReq(adjustAddress(dramBaseAddr), ramServer);
    let cached_mem_connection <- mkConnection(memorySystem.cachedMemory, cachedMemBridge);

    // Processor Control
    method Action start();
        core.start(rstvec);
    endmethod
    method Action stop();
        core.stop;
    endmethod

    // Verification
    method Maybe#(VerificationPacket) currVerificationPacket;
        return core.currVerificationPacket;
    endmethod

    // Main Memory Connection
    interface MainMemClientPort ram = ramClient;
    interface UncachedMemClientPort mmio = externalMMIOClient;
    interface GenericMemServerPort extmem = memorySystem.extMemory;

    // Interrupts
    method Action triggerExternalInterrupt;
        extInterruptWire <= True;
    endmethod

    method Action stallPipeline(Bool stall);
        clockGating.setGateCond(!stall);
    endmethod

    interface ProcPins pins;
        interface Clock deleteme_unused_clock = clock;
    endinterface
endmodule


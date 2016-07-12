
// Copyright (c) 2016 Massachusetts Institute of Technology

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

import ClientServer::*;
import Connectable::*;
import DefaultValue::*;
import FIFO::*;
import GetPut::*;
import Vector::*;

import Abstraction::*;
import RegUtil::*;
import RVRFile::*;
import RVCsrFile::*;
import RVExec::*;
import RVFpu::*;
import RVMulDiv::*;
import RVTypes::*;
import VerificationPacket::*;

import RVAlu::*;
import RVControl::*;
import RVDecode::*;
import RVMemory::*;

// This interface is the combination of FrontEnd and BackEnd
interface Core;
    method Action start(Addr startPc);
    method Action stop;

    method Action configure(Data miobase);
    method ActionValue#(VerificationPacket) getVerificationPacket;
    method ActionValue#(VMInfo) updateVMInfoI;
    method ActionValue#(VMInfo) updateVMInfoD;

    method Action triggerExternalInterrupt;

    interface Client#(FenceReq, FenceResp) fence;
    interface Client#(Data, Data) htif;
endinterface

instance Connectable#(Core, MemorySystem);
    module mkConnection#(Core core, MemorySystem mem)(Empty);
        mkConnection(core.fence, mem.fence);
        mkConnection(toGet(core.updateVMInfoI), toPut(mem.updateVMInfoI));
        mkConnection(toGet(core.updateVMInfoD), toPut(mem.updateVMInfoD));
    endmodule
endinstance

typedef enum {
    Wait,
    IMMU,
    IF,
    Dec,
    RegRead,
    Execute,
    Mem,
    WB,
    Trap,
    Trap2
} ProcState deriving (Bits, Eq, FShow);

module mkMulticycleCore#(
        Server#(RVIMMUReq, RVIMMUResp) ivat,
        Server#(RVIMemReq, RVIMemResp) ifetch,
        Server#(RVDMMUReq, RVDMMUResp) dvat,
        Server#(RVDMemReq, RVDMemResp) dmem)
        (Core);
    let verbose = False;
    File fout = stdout;

    ArchRFile rf <- mkArchRFile;
    RVCsrFile csrf <- mkRVCsrFile;
    MulDivExec mulDiv <- mkBoothRoughMulDivExec;
    FpuExec fpu <- mkFpuExecPipeline;

    Reg#(Bool) htifStall <- mkReg(False);
    Reg#(Bool) running <- mkReg(False);
    Reg#(ProcState) state <- mkReg(Wait);

    Reg#(Addr) pc <- mkReg(0);
    Reg#(Maybe#(ExceptionCause)) exception <- mkReg(tagged Invalid);
    Reg#(Instruction) inst <- mkReg(0);
    Reg#(RVDecodedInst) dInst <- mkReg(unpack(0));
    Reg#(FrontEndCsrs) csrState <- mkReadOnlyReg( FrontEndCsrs { vmI: csrf.vmI, state: csrf.csrState } );

    Reg#(Data) rVal1 <- mkReg(0);
    Reg#(Data) rVal2 <- mkReg(0);
    Reg#(Data) rVal3 <- mkReg(0);
    Reg#(Data) data <- mkReg(0);
    Reg#(Data) addr <- mkReg(0);
    Reg#(Data) nextPc <- mkReg(0);

    FIFO#(Data)         toHost <- mkFIFO1;
    FIFO#(Data)         fromHost <- mkFIFO1;

    FIFO#(VerificationPacket) verificationPackets <- mkFIFO1;

    rule doInstMMU(running && state == IMMU);
        // request address translation from MMU
        ivat.request.put(pc);
        // reset states
        inst <= unpack(0);
        dInst <= unpack(0);
        exception <= tagged Invalid;
        // go to InstFetch stage
        state <= IF;
    endrule

    rule doInstFetch(state == IF);
        // I wanted notation like this:
        // let {addr: .phyPc, exception: .exMMU} = mmuResp.first;
        let resp <- ivat.response.get;
        let phyPc = resp.addr;
        let exMMU = resp.exception;

        if (!isValid(exMMU)) begin
            // no translation exception
            ifetch.request.put(phyPc);
            // go to decode stage
            state <= Dec;
        end else begin
            // translation exception (instruction access fault)
            exception <= exMMU;
            // send instruction to backend
            state <= Trap;
        end
    endrule

    rule doDecode(state == Dec);
        let fInst <- ifetch.response.get;

        let decInst = decodeInst(fInst);

        if (decInst matches tagged Valid .validDInst) begin
            // Legal instruction
            dInst <= validDInst;
        end else begin
            // Illegal instruction
            exception <= tagged Valid IllegalInst;
        end

        inst <= fInst;
        state <= isValid(decInst) ? RegRead : Trap;
    endrule

    rule doRegRead(!htifStall && state == RegRead);
        rVal1 <= rf.rd1(toFullRegIndex(dInst.rs1, getInstFields(inst).rs1));
        rVal2 <= rf.rd2(toFullRegIndex(dInst.rs2, getInstFields(inst).rs2));
        rVal3 <= rf.rd3(toFullRegIndex(dInst.rs3, getInstFields(inst).rs3));
        state <= Execute;
    endrule

    rule doExecute(state == Execute);
        let dataEx = 0;
        let addrEx = 0;
        let nextPcEx = pc + 4;

        Maybe#(Data) imm = getImmediate(dInst.imm, dInst.inst);
        case (dInst.execFunc) matches
            tagged Alu    .aluInst:
                begin
                    dataEx = execAluInst(aluInst, rVal1, rVal2, imm, pc);
                end
            tagged Br     .brFunc:
                begin
                    // data for jal
                    dataEx = pc + 4;
                    nextPcEx = execControl(brFunc, rVal1, rVal2, imm, pc);
                end
            tagged Mem    .memInst:
                begin
                    // data for store and AMO
                    dataEx = rVal2;
                    addrEx = addrCalc(rVal1, imm);
                    dvat.request.put(RVDMMUReq {addr: addrEx, size: memInst.size, op: (memInst.op matches tagged Mem .memOp ? memOp : St)});
                end
            tagged MulDiv .mulDivInst: mulDiv.exec(mulDivInst, rVal1, rVal2);
            tagged Fence  .fenceInst:  noAction;
            // TODO: Handle dynamic rounding mode
            tagged Fpu    .fpuInst:    fpu.exec(fpuInst, getInstFields(inst).rm, rVal1, rVal2, rVal3);
            tagged System .systemInst:
                begin
                    // data for CSR instructions
                    dataEx = fromMaybe(rVal1, imm);
                end
        endcase

        data <= dataEx;
        addr <= addrEx;
        nextPc <= nextPcEx;

        state <= dInst.execFunc matches tagged Mem .* ? Mem : WB;
    endrule

    rule doMem(state == Mem);
        let resp <- dvat.response.get;
        let pAddr = resp.addr;
        let exMMU = resp.exception;

        // TODO: make this type safe! get rid of .Mem accesses to tagged union
        if (!isValid(exMMU)) begin
            dmem.request.put( RVDMemReq {
                    op: dInst.execFunc.Mem.op,
                    size: dInst.execFunc.Mem.size,
                    isUnsigned: dInst.execFunc.Mem.isUnsigned,
                    addr: pAddr,
                    data: data } );
            state <= WB;
        end else begin
            exception <= exMMU;
            state <= Trap;
        end
    endrule

    rule doWB(state == WB);
        let dataWb = data;
        let addrWb = addr;
        let nextPcWb = nextPc;
        let fflagsWb = 0;
        let exceptionWB = exception;

        case(dInst.execFunc) matches
            tagged MulDiv .*: begin
                    dataWb = mulDiv.result_data();
                    mulDiv.result_deq;
                end
            tagged Fpu .*: begin
                    let fpuResult = toFullResult(fpu.result_data);
                    dataWb = fpuResult.data;
                    fflagsWb = fpuResult.fflags;
                    fpu.result_deq;
                end
            tagged Mem .memInst:
                begin
                    if (getsResponse(memInst.op)) begin
                        dataWb <- dmem.response.get;
                    end
                end
        endcase

        // TODO: add comment
        Bool checkForInterrupts = dInst.execFunc matches tagged Mem .* ? False : True;
        Bool extensionDirty = False;
        Bool fpuDirty = (dInst.dst == tagged Valid Fpu);
        let {maybeTrap, maybeData, maybeNextPc} <- csrf.wr(
                // performing system instructions
                dInst.execFunc matches tagged System .sysInst ? tagged Valid sysInst : tagged Invalid,
                getInstFields(inst).csr,
                dataWb,  // either rf[rs1] or zimm, computed in basicExec
                // handling exceptions
                exceptionWB,    // exception cause
                checkForInterrupts,
                pc,             // for writing to mepc/sepc
                dInst.execFunc matches tagged Br .* ? True : False, // check inst allignment if Br Func
                dInst.execFunc matches tagged Br .* ? nextPcWb : addrWb, // either data address or next PC, used to detect misaligned instruction addresses
                // indirect writes
                fflagsWb,
                fpuDirty,
                extensionDirty);

        // send verification packet
        verificationPackets.enq( VerificationPacket {
                skippedPackets: 0,
                pc: pc,
                nextPc: fromMaybe(nextPcWb, maybeNextPc),
                data: fromMaybe(dataWb, maybeData),
                addr: addr,
                instruction: inst,
                dst: {pack(dInst.dst), getInstFields(inst).rd},
                trap: isValid(maybeTrap),
                trapType: (case (fromMaybe(unpack(0), maybeTrap)) matches
                        tagged Exception .x: (zeroExtend(pack(x)));
                        tagged Interrupt .x: (zeroExtend(pack(x)) | 8'h80);
                    endcase) });

        if (maybeNextPc matches tagged Valid .replayPc) begin
            // This instruction didn't retire

            // redirect happens in Trap2
            nextPc <= replayPc;
            state <= Trap2;
        end else begin
            // This instruction retired
            // write to the register file
            rf.wr(toFullRegIndex(dInst.dst, getInstFields(inst).rd), fromMaybe(dataWb, maybeData));
            // always redirect
            pc <= nextPc;
            state <= IMMU;
        end
    endrule

    rule doTrap(state == Trap);
        // TODO: move this to WB
        let {maybeTrap, maybeData, maybeNextPc} <- csrf.wr(
                tagged Invalid,
                getInstFields(inst).csr,
                0, // data
                exception, // exception cause
                True,
                pc, // pc
                False, 
                addr, // vaddr
                0,
                False,
                False);

        // send verification packet
        verificationPackets.enq( VerificationPacket {
                skippedPackets: 0,
                pc: pc,
                nextPc: fromMaybe(?, maybeNextPc),
                data: fromMaybe(data, maybeData),
                addr: addr,
                instruction: inst,
                dst: {pack(dInst.dst), getInstFields(inst).rd},
                trap: isValid(maybeTrap),
                trapType: (case (fromMaybe(unpack(0), maybeTrap)) matches
                        tagged Exception .x: (zeroExtend(pack(x)));
                        tagged Interrupt .x: (zeroExtend(pack(x)) | 8'h80);
                    endcase) });

        // redirection will happpen in trap2
        // by construction maybeNextPc is always valid
        nextPc <= fromMaybe(nextPc, maybeNextPc);
        state <= Trap2;
    endrule

    // There is a second trap state to ensure that the frontEndCsrs reflect the updated state of the processor
    rule doTrap2(state == Trap2);
        pc <= nextPc;
        state <= IMMU;
    endrule

    rule htifToHost;
        let msg <- csrf.csrfToHost;
        if (truncateLSB(msg) != 16'h0100) begin
            htifStall <= True;
        end
        toHost.enq(msg);
    endrule

    rule htifFromHost;
        htifStall <= False;
        let msg = fromHost.first;
        fromHost.deq;
        csrf.hostToCsrf(msg);
    endrule

    method Action start(Addr startPc);
        running <= True;
        pc <= startPc;
        state <= IMMU;
        csrState <= defaultValue;
        if (verbose) $fdisplay(fout, "[frontend] starting from pc = 0x%08x", startPc);
    endmethod
    method Action stop;
        running <= False;
        state <= Wait;
    endmethod

    interface Client htif = toGPClient(toHost, fromHost);

    method Action configure(Data miobase);
        csrf.configure(miobase);
    endmethod
    method ActionValue#(VerificationPacket) getVerificationPacket;
        let verificationPacket = verificationPackets.first;
        verificationPackets.deq;
        return verificationPacket;
    endmethod

    method ActionValue#(VMInfo) updateVMInfoI;
        return csrf.vmI;
    endmethod
    method ActionValue#(VMInfo) updateVMInfoD;
        return csrf.vmD;
    endmethod

    method Action triggerExternalInterrupt;
        csrf.triggerExternalInterrupt;
    endmethod
endmodule
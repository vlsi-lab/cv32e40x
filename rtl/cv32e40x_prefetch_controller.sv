// Copyright 2020 Silicon Labs, Inc.
//
// This file, and derivatives thereof are licensed under the
// Solderpad License, Version 2.0 (the "License").
//
// Use of this file means you agree to the terms and conditions
// of the license and are in full compliance with the License.
//
// You may obtain a copy of the License at:
//
//     https://solderpad.org/licenses/SHL-2.0/
//
// Unless required by applicable law or agreed to in writing, software
// and hardware implementations thereof distributed under the License
// is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, EITHER EXPRESSED OR IMPLIED.
//
// See the License for the specific language governing permissions and
// limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Arjan Bink - arjan.bink@silabs.com                         //
//                                                                            //
// Design Name:    Prefetcher Controller                                      //
// Project Name:   CV32E40P                                                   //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Prefetch Controller which receives control flow            //
//                 information (req_i, branch_*) from the Fetch stage         //
//                 and based on that performs transactions requests to the    //
//                 bus interface adapter instructions. Prefetching based on   //
//                 incrementing addressed is performed when no new control    //
//                 flow change is requested. New transaction requests are     //
//                 only performed if it can be guaranteed that the fetch FIFO //
//                 will not overflow (resulting in a maximum of DEPTH         //
//                 outstanding transactions.                                  //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40x_prefetch_controller
#(
  parameter DEPTH           = 4,                                // Prefetch FIFO Depth
  parameter FIFO_ADDR_DEPTH = (DEPTH > 1) ? $clog2(DEPTH) : 1   // Do not override this parameter
)(
  input  logic                     clk,
  input  logic                     rst_n,

  // Fetch stage interface
  input  logic                     req_i,                   // Fetch stage requests instructions
  input  logic                     branch_i,                // Taken branch
  input  logic [31:0]              branch_addr_i,           // Taken branch address (only valid when branch_i = 1)
  output logic                     busy_o,                  // Prefetcher busy

  // Transaction request interface
  output logic                     trans_valid_o,           // Transaction request valid (to bus interface adapter)
  input  logic                     trans_ready_i,           // Transaction request ready (transaction gets accepted when trans_valid_o and trans_ready_i are both 1)
  output logic [31:0]              trans_addr_o,            // Transaction address (only valid when trans_valid_o = 1). No stability requirements.

  // Transaction response interface
  input  logic                     resp_valid_i,            // Note: Consumer is assumed to be 'ready' whenever resp_valid_i = 1

  // Fetch interface
  output logic                     fetch_valid_o,
  input  logic                     trans_req_i,
  output logic                     trans_ack_o
);

  import cv32e40x_pkg::*;

  prefetch_state_e state_q, next_state;

  logic  [FIFO_ADDR_DEPTH:0]     cnt_q;                           // Transaction counter
  logic  [FIFO_ADDR_DEPTH:0]     next_cnt;                        // Next value for cnt_q
  logic                          count_up;                        // Increment outstanding transaction count by 1 (can happen at same time as count_down)
  logic                          count_down;                      // Decrement outstanding transaction count by 1 (can happen at same time as count_up)

  logic  [FIFO_ADDR_DEPTH:0]     flush_cnt_q;                     // Response flush counter (to flush speculative responses after branch)
  logic  [FIFO_ADDR_DEPTH:0]     next_flush_cnt;                  // Next value for flush_cnt_q

  // Transaction address
  logic [31:0]                   trans_addr_q, trans_addr_incr;

  // Word-aligned branch target address
  logic [31:0]                   aligned_branch_addr;             // Word aligned branch target address


  //////////////////////////////////////////////////////////////////////////////
  // Prefetch buffer status
  //////////////////////////////////////////////////////////////////////////////

  // Busy if there are ongoing (or potentially outstanding) transfers
  assign busy_o = (cnt_q != 3'b000) || trans_valid_o;

  //////////////////////////////////////////////////////////////////////////////
  // IF/ID interface
  //////////////////////////////////////////////////////////////////////////////

  // Fectch valid control. Fetch never valid if jumping or flushing responses.
  // Fetch valid if there is an incoming instruction from memory.
  assign fetch_valid_o = (resp_valid_i) && !(branch_i || (flush_cnt_q > 0));

  //////////////////////////////////////////////////////////////////////////////
  // Transaction request generation
  //
  // Assumes that corresponding response is at least 1 cycle after request
  //
  // - Only request transaction when fetch stage requires fetch (trans_req_i)
  //////////////////////////////////////////////////////////////////////////////

  // Prefetcher will only perform word fetches
  assign aligned_branch_addr = {branch_addr_i[31:2], 2'b00};

  // Increment address (always word fetch)
  assign trans_addr_incr = {trans_addr_q[31:2], 2'b00} + 32'd4;

  // Transaction request generation
  // Avoid combinatorial path from instr_rvalid_i to instr_req_o. Multiple trans_* transactions can be 
  // issued (and accepted) before a response (resp_*) is received.
  assign trans_valid_o = req_i && trans_req_i;

  assign trans_ack_o = trans_valid_o && trans_ready_i;

  // FSM (state_q, next_state) to control OBI A channel signals.
  always_comb
  begin
    next_state = state_q;
    trans_addr_o = trans_addr_q;

    case(state_q)
      // Default state (pass on branch target address or transaction with incremented address)
      IDLE:
      begin
        begin
          if (branch_i) begin
            // Jumps must have the highest priority (e.g. an interrupt must
            // have higher priority than a HW-loop branch)
            trans_addr_o = aligned_branch_addr;
          end else begin
            trans_addr_o = trans_addr_incr;
          end
        end
        if ((branch_i) && !(trans_valid_o && trans_ready_i)) begin
          // Taken branch, but transaction not yet accepted by bus interface adapter.
          next_state = BRANCH_WAIT;
        end
      end // case: IDLE

      BRANCH_WAIT:
      begin
        // Replay previous branch target address (trans_addr_q) or new branch address (this can
        // occur if for example an interrupt is taken right after a taken jump which did not
        // yet have its target address accepted by the bus interface adapter.
        trans_addr_o = branch_i ? aligned_branch_addr : trans_addr_q;
        if (trans_valid_o && trans_ready_i) begin
          // Transaction with branch target address has been accepted. Start regular prefetch again.
          next_state = IDLE;
        end
      end // case: BRANCH_WAIT
    endcase
  end

  
  //////////////////////////////////////////////////////////////////////////////
  // Counter (cnt_q, next_cnt) to count number of outstanding OBI transactions
  // (maximum = DEPTH)
  //
  // Counter overflow is prevented by limiting the number of outstanding transactions
  // to DEPTH. Counter underflow is prevented by the assumption that resp_valid_i = 1
  // will only occur in response to accepted transfer request (as per the OBI protocol).
  //////////////////////////////////////////////////////////////////////////////

  assign count_up   = trans_valid_o && trans_ready_i;     // Increment upon accepted transfer request
  assign count_down = resp_valid_i;                       // Decrement upon accepted transfer response

  always_comb begin
    case ({count_up, count_down})
      2'b00  : begin
        next_cnt = cnt_q;
      end
      2'b01  : begin
          next_cnt = cnt_q - 1'b1;
      end
      2'b10  : begin
          next_cnt = cnt_q + 1'b1;
      end
      2'b11  : begin
        next_cnt = cnt_q;
      end
    endcase
  end

  
  
  //////////////////////////////////////////////////////////////////////////////
  // Counter (flush_cnt_q, next_flush_cnt) to count reseponses to be flushed.
  //////////////////////////////////////////////////////////////////////////////

  always_comb begin
    next_flush_cnt = flush_cnt_q;

    // Number of outstanding transfers at time of branch equals the number of
    // responses that will need to be flushed (responses already in the FIFO will
    // be flushed there)
    if (branch_i) begin
      next_flush_cnt = cnt_q;
      if (resp_valid_i && (cnt_q > 0)) begin
        next_flush_cnt = cnt_q - 1'b1;
      end
    end else if (resp_valid_i && (flush_cnt_q > 0)) begin
      next_flush_cnt = flush_cnt_q - 1'b1;
    end
  end

  //////////////////////////////////////////////////////////////////////////////
  // Registers
  //////////////////////////////////////////////////////////////////////////////

  always_ff @(posedge clk, negedge rst_n)
  begin
    if(rst_n == 1'b0)
    begin
      state_q        <= IDLE;
      cnt_q          <= '0;
      flush_cnt_q    <= '0;
      trans_addr_q   <= '0;
    end
    else
    begin
      state_q        <= next_state;
      cnt_q          <= next_cnt;
      flush_cnt_q    <= next_flush_cnt;
      if (branch_i || (trans_valid_o && trans_ready_i)) begin
        trans_addr_q <= trans_addr_o;
      end
    end
  end

endmodule // cv32e40x_prefetch_controller

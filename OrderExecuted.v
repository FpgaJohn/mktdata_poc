// -----------------------------------------------------------------------------
// OrderExecuted.v — Verilog port of message.types/OrderExecuted.vi
//
// Handles Order Executed 0x23 and Order Executed at Price/Size 0x24 from the
// message-aligned buffer. Field layout (CBOE PITCH spec; constant offsets):
//
//   0x23: Time 2,4 | OrderId 6,8 | ExecutedQty 14,4 | ExecutionId 18,8
//   0x24: Time 2,4 | OrderId 6,8 | ExecutedQty 14,4 | RemainingQty 18,4
//         | ExecutionId 22,8 | Price 30,8
//
// ExecutionId is not part of the OrderBook.Command cluster and is not
// extracted. NOTE: the VI's command-flag wiring was not recoverable from the
// printouts — this port emits type ORDER_EXECUTED with 'edit' set (documented
// guess, same as the flattened version).
//
// Purely combinational; the parser samples the outputs only when it
// dispatches a 0x23/0x24 message.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module OrderExecuted (
    input  wire [575:0] buffer_in,
    output wire [7:0]   cmd_type,
    output wire         edit,
    output wire [63:0]  order_id,
    output wire [31:0]  executed_qty,
    output reg  [31:0]  remaining_qty,   // 0x24 only, else 0
    output reg  [63:0]  price,           // 0x24 only, else 0
    output wire [31:0]  nanoseconds      // message Time Offset field
);

    `include "bats.parser.vh"

    wire [63:0] msg_type_w, time_w, order_id_w, exec_qty_w;
    wire [63:0] rem_qty_w, price_w;

    new_uxx_be #(.START(1),  .LEN(1)) u_msg_type (.buffer(buffer_in), .value(msg_type_w));
    new_uxx_be #(.START(2),  .LEN(4)) u_time     (.buffer(buffer_in), .value(time_w));
    new_uxx_be #(.START(6),  .LEN(8)) u_order_id (.buffer(buffer_in), .value(order_id_w));
    new_uxx_be #(.START(14), .LEN(4)) u_exec_qty (.buffer(buffer_in), .value(exec_qty_w));

    // Order Executed at Price/Size 0x24 extras
    new_uxx_be #(.START(18), .LEN(4)) u_rem_qty  (.buffer(buffer_in), .value(rem_qty_w));
    new_uxx_be #(.START(30), .LEN(8)) u_price    (.buffer(buffer_in), .value(price_w));

    always @* begin
        if (msg_type_w[7:0] == MSG_ORDER_EXECUTED_PS) begin
            remaining_qty = rem_qty_w[31:0];
            price         = price_w;
        end else begin           // 0x23
            remaining_qty = 32'd0;
            price         = 64'd0;
        end
    end

    assign cmd_type     = TYPE_ORDER_EXECUTED;
    assign edit         = 1'b1;
    assign order_id     = order_id_w;
    assign executed_qty = exec_qty_w[31:0];
    assign nanoseconds  = time_w[31:0];

endmodule

`default_nettype wire

// -----------------------------------------------------------------------------
// bats.parser.v — Verilog port of bats.parser.vi (hierarchical top level)
//   (Market.Data.Bats.Parser/fpga/bats.parser.vi, "last modified 7/20/2026")
//
// Parses CBOE BATS PITCH Sequenced Unit datagrams from a 64-bit data stream
// and emits normalized OrderBook.Command records, mirroring the LabVIEW
// single-cycle timed-loop implementation. One Verilog file per subVI:
//
//   add.data.to.buffer.v  add_data_to_buffer  — append input word to buffer
//   compress.buffer.v     compress_buffer     — drop consumed front bytes
//   new.uxx.be.v          new_uxx_be          — constant-offset field extract
//   AddOrder.v            AddOrder            — 0x21/0x22/0x2F -> Add command
//   OrderExecuted.v       OrderExecuted       — 0x23/0x24 -> Edit command
//   Time.v                Time                — 0x20 -> latches 'seconds'
//   bats.parser.vh                            — shared message/command codes
//   (zero.out.and.convert.vi / reverse.u64.vi are absorbed into new_uxx_be)
//
//   state machine : Reset -> Read.Sequenced.Unit.Header -> Read.Msg (-> Noop)
//   per cycle     : append the input word to the 72-byte buffer, then consume
//                   the 8-byte unit header or exactly one whole message.
//
// Differences from the VI (deliberate, per recommendations.txt Appendix C/D):
//   * Field offsets are per-instance elaboration constants (new_uxx_be
//     parameters), so no data-dependent barrel shifters are inferred.
//   * The eof TODO in the VI ("If End of Frame Next -> Read SeqUnitHdr") is
//     implemented for eof.bad: flush the buffer and re-arm the header state.
//     A good eof needs no flush — total_counter already returns the state
//     machine to Read.Sequenced.Unit.Header after the unit's last message.
//   * OrderExecuted.vi's command flags were not available in the printouts;
//     0x23/0x24 emit type ORDER_EXECUTED with cmd_edit set (documented guess).
//
// Data packing convention (matches the LabVIEW cluster display):
//   byte k of the wire (k = 0 first) sits in ds_data[63-8*k -: 8] and its
//   enable is ds_byte_enables[7-k]; enables must be contiguous from byte 0.
//   Buffer byte i occupies buffer[575-8*i -: 8], so "compress" is a left shift.
//
// FIFO outputs (TS-Filter.Command / TS-Debug in the VI) are valid-strobe only;
// like the timed loop, the parser does not stall on downstream backpressure.
//
// The original single-file version is archived as bats.parser.flattened.v
// (module bats_parser_flattened).
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module bats_parser (
    input  wire        clk,
    input  wire        reset,             // front-panel 'reset' button

    // data.stream cluster
    input  wire        ds_data_valid,
    input  wire [63:0] ds_data,           // byte 0 in [63:56]
    input  wire [7:0]  ds_byte_enables,   // byte 0 enable in bit [7]
    input  wire        ds_eof_good,
    input  wire        ds_eof_bad,
    input  wire [63:0] ds_timestamp,      // arrival timestamp of this word

    input  wire [63:0] time_in,           // free-running 'time' input

    output wire        ready_for_udp_input,

    // OrderBook.Command (TS-Filter.Command write)
    output reg         cmd_valid,
    output reg  [7:0]  cmd_type,          // see bats.parser.vh TYPE_*
    output reg  [7:0]  cmd_side,          // 'B' / 'S' (AddOrder only)
    output reg  [63:0] cmd_order_id,
    output reg  [31:0] cmd_quantity,
    output reg  [63:0] cmd_symbol,        // ASCII, first char in LSB
    output reg  [63:0] cmd_price,
    output reg  [31:0] cmd_executed_qty,
    output reg  [31:0] cmd_canceled_qty,
    output reg  [31:0] cmd_remaining_qty,
    output reg  [31:0] cmd_seconds,       // from last Time (0x20) message
    output reg  [31:0] cmd_nanoseconds,   // message Time Offset field
    output reg         cmd_add,
    output reg         cmd_edit,
    output reg         cmd_remove,
    output reg  [31:0] cmd_seq_no,
    output reg  [63:0] cmd_recv_time,
    output reg  [63:0] cmd_parse_time,

    // TS-Debug write
    output reg         dbg_valid,
    output reg  [15:0] dbg_data
);

    `include "bats.parser.vh"

    // BATS.Parser.States
    localparam [1:0] ST_NOOP          = 2'd0,
                     ST_RESET         = 2'd1,
                     ST_READ_UNIT_HDR = 2'd2,
                     ST_READ_MSG      = 2'd3;

    // Debug key (from the block diagram): Reset AA00, Read.Seq.Unit.Hdr AA01,
    // Read.Msg AA02; unsupported message type A000.
    localparam [15:0] DBG_RESET       = 16'hAA00,
                      DBG_READ_HDR    = 16'hAA01,
                      DBG_READ_MSG    = 16'hAA02,
                      DBG_UNSUPPORTED = 16'hA000;

    localparam BUF_BYTES = 72;                       // 9 x U64, as in the VI

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    reg [1:0]   state;
    reg [575:0] buffer;                              // byte 0 at [575:568]
    reg [6:0]   buffer_length;                       // bytes currently held
    reg [15:0]  hdr_length;                          // Hdr Length (U16)
    reg [15:0]  total_counter;                       // messages left in unit
    reg [31:0]  next_seq_no;
    reg [31:0]  seconds_r;                           // from Time 0x20
    reg [63:0]  recv_time_r;                         // latched ds_timestamp

    // ------------------------------------------------------------------
    // add.data.to.buffer.vi — append this cycle's input word
    // ------------------------------------------------------------------
    wire [575:0] abuf;                               // buffer after append
    wire [6:0]   alen;

    add_data_to_buffer u_add_data_to_buffer (
        .buffer_in        (buffer),
        .buffer_length_in (buffer_length),
        .data_valid       (ds_data_valid),
        .data             (ds_data),
        .byte_enables     (ds_byte_enables),
        .buffer_out       (abuf),
        .buffer_length_out(alen)
    );

    wire [7:0] msg_length = abuf[575:568];           // message byte 0
    wire [7:0] msg_type   = abuf[567:560];           // message byte 1

    wire hdr_ready     = (alen >= 7'd8);
    wire msg_known     = (alen >= 7'd2);
    wire msg_malformed = msg_known
                         && (msg_length == 8'd0 || msg_length > 8'd72);
    wire msg_ready     = msg_known && !msg_malformed
                         && ({1'b0, alen} >= {1'b0, msg_length[6:0]});

    assign ready_for_udp_input = (state != ST_RESET)
                                 && (buffer_length <= BUF_BYTES - 8);

    // ------------------------------------------------------------------
    // new.uxx.be.vi — Sequenced Unit Header fields:
    // Length U16 @0, Count U8 @2, Unit U8 @3, Sequence U32 @4 — 8 bytes.
    // ------------------------------------------------------------------
    wire [63:0] hdr_length_w, hdr_count_w, hdr_seq_w;

    new_uxx_be #(.START(0), .LEN(2)) u_hdr_length (.buffer(abuf), .value(hdr_length_w));
    new_uxx_be #(.START(2), .LEN(1)) u_hdr_count  (.buffer(abuf), .value(hdr_count_w));
    new_uxx_be #(.START(4), .LEN(4)) u_hdr_seq    (.buffer(abuf), .value(hdr_seq_w));

    // ------------------------------------------------------------------
    // Message-type subVIs (combinational; outputs sampled on dispatch)
    // ------------------------------------------------------------------
    wire [7:0]  ao_type, ao_side;
    wire        ao_add;
    wire [63:0] ao_order_id, ao_symbol, ao_price;
    wire [31:0] ao_quantity, ao_nanoseconds;

    AddOrder u_add_order (
        .buffer_in   (abuf),
        .cmd_type    (ao_type),
        .add         (ao_add),
        .side        (ao_side),
        .order_id    (ao_order_id),
        .quantity    (ao_quantity),
        .symbol      (ao_symbol),
        .price       (ao_price),
        .nanoseconds (ao_nanoseconds)
    );

    wire [7:0]  oe_type;
    wire        oe_edit;
    wire [63:0] oe_order_id, oe_price;
    wire [31:0] oe_executed_qty, oe_remaining_qty, oe_nanoseconds;

    OrderExecuted u_order_executed (
        .buffer_in     (abuf),
        .cmd_type      (oe_type),
        .edit          (oe_edit),
        .order_id      (oe_order_id),
        .executed_qty  (oe_executed_qty),
        .remaining_qty (oe_remaining_qty),
        .price         (oe_price),
        .nanoseconds   (oe_nanoseconds)
    );

    wire [31:0] time_seconds;

    Time u_time (
        .buffer_in (abuf),
        .seconds   (time_seconds)
    );

    // ------------------------------------------------------------------
    // compress.buffer.vi — drop the bytes consumed this cycle
    // ------------------------------------------------------------------
    reg [6:0] consume;
    always @* begin
        consume = 7'd0;
        if (state == ST_READ_UNIT_HDR && hdr_ready)
            consume = 7'd8;
        else if (state == ST_READ_MSG && msg_ready)
            consume = msg_length[6:0];
    end

    wire [575:0] cbuf;
    wire [6:0]   clen;

    compress_buffer u_compress_buffer (
        .buffer_in        (abuf),
        .buffer_length_in (alen),
        .consume          (consume),
        .buffer_out       (cbuf),
        .buffer_length_out(clen)
    );

    // ------------------------------------------------------------------
    // Main state machine — one unit header or one message per cycle.
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        // defaults every cycle
        cmd_valid <= 1'b0;
        dbg_valid <= 1'b0;

        if (ds_data_valid)
            recv_time_r <= ds_timestamp;

        if (reset) begin
            state <= ST_RESET;
        end else begin
            case (state)

                ST_RESET: begin
                    buffer        <= 576'd0;
                    buffer_length <= 7'd0;
                    hdr_length    <= 16'd0;
                    total_counter <= 16'd0;
                    next_seq_no   <= 32'd0;
                    seconds_r     <= 32'd0;
                    dbg_valid     <= 1'b1;
                    dbg_data      <= DBG_RESET;
                    state         <= ST_READ_UNIT_HDR;
                end

                ST_READ_UNIT_HDR: begin
                    if (hdr_ready) begin
                        hdr_length    <= hdr_length_w[15:0];
                        total_counter <= hdr_count_w[15:0];
                        next_seq_no   <= hdr_seq_w[31:0];
                        dbg_valid     <= 1'b1;
                        dbg_data      <= DBG_READ_HDR;
                        state         <= ST_READ_MSG;
                    end
                    buffer        <= cbuf;
                    buffer_length <= clen;
                end

                // "Entire Message should be available now"
                ST_READ_MSG: begin
                    if (msg_malformed) begin
                        // defensive flush and re-arm (the VI would spin here)
                        buffer        <= 576'd0;
                        buffer_length <= 7'd0;
                        state         <= ST_READ_UNIT_HDR;
                    end else begin
                        if (msg_ready) begin
                            dbg_valid <= 1'b1;
                            dbg_data  <= DBG_READ_MSG;

                            // fresh OrderBook.Command each message (unwired
                            // cluster fields default to 0 in the VI)
                            cmd_side          <= 8'd0;
                            cmd_order_id      <= 64'd0;
                            cmd_quantity      <= 32'd0;
                            cmd_symbol        <= 64'd0;
                            cmd_price         <= 64'd0;
                            cmd_executed_qty  <= 32'd0;
                            cmd_canceled_qty  <= 32'd0;
                            cmd_remaining_qty <= 32'd0;
                            cmd_nanoseconds   <= 32'd0;
                            cmd_add           <= 1'b0;
                            cmd_edit          <= 1'b0;
                            cmd_remove        <= 1'b0;
                            cmd_seconds       <= seconds_r;
                            cmd_seq_no        <= next_seq_no;
                            cmd_recv_time     <= recv_time_r;
                            cmd_parse_time    <= time_in;

                            case (msg_type)

                                MSG_TIME: begin              // Time.vi
                                    seconds_r <= time_seconds;
                                end

                                MSG_ADD_ORDER_LONG,          // AddOrder.vi
                                MSG_ADD_ORDER_SHORT,
                                MSG_ADD_ORDER_EXP: begin
                                    cmd_valid       <= 1'b1;
                                    cmd_type        <= ao_type;
                                    cmd_add         <= ao_add;
                                    cmd_side        <= ao_side;
                                    cmd_order_id    <= ao_order_id;
                                    cmd_quantity    <= ao_quantity;
                                    cmd_symbol      <= ao_symbol;
                                    cmd_price       <= ao_price;
                                    cmd_nanoseconds <= ao_nanoseconds;
                                end

                                MSG_ORDER_EXECUTED,          // OrderExecuted.vi
                                MSG_ORDER_EXECUTED_PS: begin
                                    cmd_valid         <= 1'b1;
                                    cmd_type          <= oe_type;
                                    cmd_edit          <= oe_edit;
                                    cmd_order_id      <= oe_order_id;
                                    cmd_executed_qty  <= oe_executed_qty;
                                    cmd_remaining_qty <= oe_remaining_qty;
                                    cmd_price         <= oe_price;
                                    cmd_nanoseconds   <= oe_nanoseconds;
                                end

                                default: begin   // Other/Unsupported
                                    dbg_data <= DBG_UNSUPPORTED;
                                end
                            endcase

                            next_seq_no   <= next_seq_no + 32'd1;
                            total_counter <= total_counter - 16'd1;
                            if (total_counter <= 16'd1)
                                state <= ST_READ_UNIT_HDR;
                        end

                        buffer        <= cbuf;
                        buffer_length <= clen;
                    end
                end

                default: begin       // ST_NOOP — hold state, keep buffering
                    buffer        <= abuf;
                    buffer_length <= alen;
                end
            endcase

            // Bad end of frame: discard the tail so the next datagram starts
            // clean at a Sequenced Unit Header (implements the VI's TODO; a
            // good eof needs no flush — total_counter already returns the
            // state machine to Read.Sequenced.Unit.Header).
            if (ds_data_valid && ds_eof_bad && state != ST_RESET) begin
                buffer        <= 576'd0;
                buffer_length <= 7'd0;
                state         <= ST_READ_UNIT_HDR;
            end
        end
    end

endmodule

`default_nettype wire
